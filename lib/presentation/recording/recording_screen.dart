// lib/presentation/recording/recording_screen.dart
//
// 实时转写笔记界面（重构自旧版录音控制台）。
//
// 定位：笔记软件而非录音软件——主体为实时转写文本展示区，底部为紧凑
// 录音控制栏。录音时 VAD 分段 → 本地 Qwen3-ASR 实时转写 → 文字逐句出现，
// 可选实时翻译（云端 LLM 流式）。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nota/models/recording_session.dart';
import 'package:nota/models/transcript.dart';
import 'package:nota/presentation/transcripts/transcript_screen.dart';
import 'package:nota/services/asr/asr_engine.dart';
import 'package:nota/services/asr/asr_model_manager.dart';
import 'package:nota/services/asr/realtime_asr_engine.dart';
import 'package:nota/services/audio/mic_recorder.dart';
import 'package:nota/services/llm/llm_engine.dart';
import 'package:nota/services/llm/llm_task_router.dart';
import 'package:nota/services/storage/recording_storage.dart';
import 'package:nota/services/storage/transcript_storage.dart';

/// 实时转写笔记界面。
///
/// 录音时麦克风 PCM16 流 → VAD 分段 → Qwen3-ASR 本地转写（或云端备选）
/// → 文字逐句实时显示。可选实时翻译：每段转写完成后送 LLM 流式翻译，
/// 译文显示在原文下方。停止后自动保存转写段落 + 音频文件 + 会话记录。
class RecordingScreen extends ConsumerStatefulWidget {
  const RecordingScreen({super.key});

  @override
  ConsumerState<RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends ConsumerState<RecordingScreen>
    with SingleTickerProviderStateMixin {
  final _titleController = TextEditingController();
  final _recordingStorage = RecordingStorage();
  final _transcriptStorage = TranscriptStorage();
  final _micRecorder = MicRecorder();
  final _asrModelManager = AsrModelManager();
  final _scrollController = ScrollController();

  RealtimeAsrEngine? _asrEngine;
  StreamSubscription<Uint8List>? _streamSub;

  // 录音状态
  bool _isPreparing = false;
  bool _isRecording = false;
  int _elapsedSeconds = 0;
  Timer? _timer;

  // 转写段落实时列表（UI 展示用，含临时翻译状态）
  final List<TranscriptSegment> _segments = [];
  final List<String?> _partialTranslations = []; // 流式翻译中间态
  final Set<int> _translatingIndices = {}; // 正在翻译的段落索引（含模型加载阶段）

  // 正在聆听/转写指示
  bool _isListening = false; // VAD onSpeechStart 触发
  // 流式 ASR 部分识别结果（仅 OnlineSherpaRealtimeAsrEngine 触发，
  // 实时显示正在识别的文本，onFinal 后清空）
  String? _partialAsrText;

  // 实时翻译开关
  bool _realtimeTranslationEnabled = false;

  // 翻译目标语言（默认中文），持久化到 SharedPreferences
  String _translationTargetLang = '中文';

  // 当前会话
  String? _currentSessionId;
  String? _currentSessionDir;

  // PCM 缓冲（用于停止时写 WAV 备份文件）
  final _pcmBuffer = <int>[];

  // 脉冲动画
  late final AnimationController _pulseController;

  // ASR 引擎状态
  String? _asrStatusHint; // null=就绪，非空=提示信息

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _loadTranslationTargetLang();
  }

  Future<void> _loadTranslationTargetLang() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('translation_target_lang');
    if (saved != null && mounted) {
      setState(() => _translationTargetLang = saved);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulseController.dispose();
    _titleController.dispose();
    _scrollController.dispose();
    _streamSub?.cancel();
    _micRecorder.dispose();
    _asrEngine?.dispose();
    super.dispose();
  }

  // ==========================================================================
  // ASR 引擎初始化
  // ==========================================================================

  /// 检测并初始化 ASR 引擎。
  ///
  /// 引擎选择三级优先级：
  /// 1. 流式优先：paraformer-streaming-zh-en（OnlineRecognizer，无 VAD 边界丢字，首选）
  /// 2. 离线回退：sensevoice-zh / paraformer-zh（OfflineRecognizer + VAD）
  /// 3. 云端回退：CloudRealtimeAsrEngine（VAD + 云端 Whisper 兼容 API）
  Future<void> _initAsrEngine() async {
    if (_asrEngine != null && _asrEngine!.isReady) return;

    // VAD 模型已内置到 assets/models/silero_vad.onnx，首次调用自动释放。
    // 仅离线/云端回退引擎需要 VAD，流式引擎（OnlineRecognizer）内置端点检测无需 VAD。
    final asrConfig = await _loadAsrConfig();
    final sherpaModels = await _asrModelManager.getDownloadedModels();

    // 1. 流式引擎优先（paraformer-streaming-zh-en）
    final hasStreaming =
        sherpaModels.any((m) => m.id == 'paraformer-streaming-zh-en');
    if (hasStreaming) {
      _asrEngine = OnlineSherpaRealtimeAsrEngine(
        sherpaModelId: 'paraformer-streaming-zh-en',
      );
      _asrStatusHint = '使用流式识别（Paraformer 中英双语，无吞字）';
      await _asrEngine!.init();
      return;
    }

    // 2. 离线引擎回退（需 VAD）
    final offlineModels = sherpaModels
        .where((m) => m.id != 'paraformer-streaming-zh-en')
        .toList();
    if (offlineModels.isNotEmpty) {
      final vadReady = await _asrModelManager.isVadModelDownloaded();
      if (!vadReady) {
        throw StateError('VAD 模型未就绪，请重新安装应用或联系开发者');
      }
      final vadPath = await _asrModelManager.getVadModelPath();
      // 优先 sensevoice-zh（多语言），其次 paraformer-zh（中文+热词），否则取第一个
      final chosen = offlineModels.firstWhere(
        (m) => m.id == 'sensevoice-zh',
        orElse: () => offlineModels.firstWhere(
          (m) => m.id == 'paraformer-zh',
          orElse: () => offlineModels.first,
        ),
      );
      _asrEngine = SherpaRealtimeAsrEngine(
        sherpaModelId: chosen.id,
        vadModelPath: vadPath,
        language: asrConfig?.language ?? 'zh',
      );
      _asrStatusHint = '使用本地 sherpa-onnx（${chosen.displayName}）';
      await _asrEngine!.init();
      return;
    }

    // 3. 云端 ASR 回退（需 VAD）
    if (asrConfig != null &&
        asrConfig.engineType == AsrEngineType.cloud &&
        (asrConfig.baseUrl?.isNotEmpty ?? false) &&
        (asrConfig.apiKey?.isNotEmpty ?? false)) {
      final vadReady = await _asrModelManager.isVadModelDownloaded();
      if (!vadReady) {
        throw StateError('VAD 模型未就绪，请重新安装应用或联系开发者');
      }
      final vadPath = await _asrModelManager.getVadModelPath();
      _asrEngine = CloudRealtimeAsrEngine(
        asrConfig: asrConfig,
        vadModelPath: vadPath,
      );
      _asrStatusHint = '使用云端 ASR（${asrConfig.modelName ?? '默认'}）';
      await _asrEngine!.init();
      return;
    }

    throw StateError(
      '未配置可用的 ASR 引擎。\n'
      '请在设置中下载 sherpa-onnx 模型（推荐流式 Paraformer ~237MB，'
      '从魔搭社区下载，无吞字），或配置云端 ASR',
    );
  }

  /// 从 SharedPreferences 读取 ASR 配置（与 settings_screen 逻辑一致）。
  Future<AsrConfig?> _loadAsrConfig() async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString('asr_config');
    if (json == null) return null;
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return AsrConfig(
        engineType: map['engineType'] == 'cloud'
            ? AsrEngineType.cloud
            : AsrEngineType.local,
        modelName: map['modelName'] as String?,
        language: map['language'] as String?,
        baseUrl: map['baseUrl'] as String?,
        apiKey: map['apiKey'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

  // ==========================================================================
  // 录音生命周期
  // ==========================================================================

  /// 开始录音 + 实时转写。
  Future<void> _startRecording() async {
    if (_isRecording || _isPreparing) return;

    setState(() => _isPreparing = true);

    final startTime = DateTime.now();
    final sessionId = startTime.millisecondsSinceEpoch.toString();
    final title = _titleController.text.trim().isEmpty
        ? _defaultTitle(startTime)
        : _titleController.text.trim();

    try {
      // 1. 初始化 ASR 引擎（懒加载，首次启动时）
      await _initAsrEngine();

      // 2. 配置 ASR 回调
      _asrEngine!.onSpeechStart = () {
        if (mounted) {
          setState(() {
            _isListening = true;
            _partialAsrText = null; // 新段开始，清空上一段的中间结果
          });
        }
      };
      // 流式引擎的部分识别结果（仅 OnlineSherpaRealtimeAsrEngine 触发）：
      // 实时显示"正在识别..."的累积文本，让用户看到识别进度而非干等
      _asrEngine!.onPartial = (text) {
        if (mounted) setState(() => _partialAsrText = text);
      };
      _asrEngine!.onFinal = _onAsrFinal;
      _asrEngine!.onError = (e, st) {
        debugPrint('[RealtimeASR] error: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('转写异常: $e'), duration: const Duration(seconds: 2)),
          );
        }
      };

      // 3. 创建会话目录与记录
      final sessionDir = await _recordingStorage.createSessionDir(startTime, title);
      final session = RecordingSession(
        id: sessionId,
        title: title,
        startTime: startTime,
        source: RecordingSource.mic,
        sessionDirPath: sessionDir,
        createdAt: startTime,
      );
      await _recordingStorage.insertSession(session);

      _currentSessionId = sessionId;
      _currentSessionDir = sessionDir;
      _pcmBuffer.clear();
      _segments.clear();
      _partialTranslations.clear();
      _isListening = false;
      _partialAsrText = null;

      // 4. 启动麦克风流（转广播流，ASR 引擎与界面各订阅一次）
      final stream = _micRecorder.startStream().asBroadcastStream();

      // 先订阅 PCM 累积（确保不丢首包），再启动 ASR 引擎
      _streamSub = stream.listen(
        (bytes) => _pcmBuffer.addAll(bytes),
        onError: (e, st) => debugPrint('[MicStream] error: $e'),
      );
      await _asrEngine!.start(stream, sessionId);

      // 6. 启动计时与脉冲
      _elapsedSeconds = 0;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) setState(() => _elapsedSeconds++);
      });
      _pulseController.repeat(reverse: true);

      if (mounted) {
        setState(() {
          _isPreparing = false;
          _isRecording = true;
        });
      }
    } catch (e) {
      // 启动失败：清理 ASR 引擎与麦克风流状态，避免残留导致后续无法重试
      await _asrEngine?.stop();
      await _micRecorder.stopStream();
      await _streamSub?.cancel();
      _streamSub = null;
      if (mounted) {
        setState(() => _isPreparing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('启动失败: $e')),
        );
      }
    }
  }

  /// 停止录音，保存音频与转写。
  Future<void> _stopRecording() async {
    if (!_isRecording) return;

    _timer?.cancel();
    _timer = null;
    _pulseController.stop();
    _pulseController.reset();

    // 1. 停止麦克风流
    await _micRecorder.stopStream();
    await _streamSub?.cancel();
    _streamSub = null;

    // 2. 停止 ASR 引擎（等待队列中所有段转写完成）
    await _asrEngine?.stop();

    // 3. 写 WAV 备份文件
    String? micPath;
    if (_currentSessionDir != null && _pcmBuffer.isNotEmpty) {
      micPath = await _writePcmBufferToWav(_currentSessionDir!, _pcmBuffer);
    }

    // 4. 更新会话记录
    final sessionId = _currentSessionId;
    if (sessionId != null) {
      final existing = await _recordingStorage.getSession(sessionId);
      if (existing != null) {
        await _recordingStorage.updateSession(
          existing.copyWith(
            endTime: DateTime.now(),
            micAudioPath: micPath ?? existing.micAudioPath,
          ),
        );
      }
    }

    if (mounted) {
      setState(() {
        _isRecording = false;
        _isListening = false;
        _partialAsrText = null;
      });
      if (sessionId != null) _showPostRecordOptions(sessionId);
    }
  }

  // ==========================================================================
  // ASR 回调处理
  // ==========================================================================

  /// 一段转写完成：加入列表 + 持久化 + 自动滚动 + 可选翻译。
  void _onAsrFinal(TranscriptSegment segment) {
    if (!mounted) return;

    setState(() {
      _segments.add(segment);
      _partialTranslations.add(null);
      _isListening = false;
      _partialAsrText = null; // 最终结果已产出，清空中间态
    });

    // 持久化到数据库（fire-and-forget：实时转写回调中不阻塞流式体验，
    // 失败兜底打印日志，seg.id 为 null 时由 catch 路径处理）
    unawaited(_transcriptStorage.insertSegment(segment).catchError((e) {
      debugPrint('[TranscriptStorage] insert failed: $e');
      return -1;
    }));

    // 自动滚动到底部
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });

    // 实时翻译（fire-and-forget：不阻塞 onFinal 回调链）
    if (_realtimeTranslationEnabled) {
      unawaited(_translateSegment(_segments.length - 1));
    }
  }

  /// 翻译指定段落（流式，更新 _partialTranslations）。
  Future<void> _translateSegment(int index) async {
    if (index < 0 || index >= _segments.length) return;

    if (mounted) setState(() => _translatingIndices.add(index));
    try {
      final engine = await LlmTaskRouter().getEngine(LlmTaskType.translation);
      if (engine == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('翻译引擎未配置，请在设置中配置翻译功能'),
              duration: Duration(seconds: 3),
            ),
          );
        }
        return;
      }

      final originalText = _segments[index].originalText;
      final systemPrompt = _buildTranslationPrompt(_translationTargetLang);

      final partialBuf = StringBuffer();
      await engine.generate(
        systemPrompt: systemPrompt,
        userPrompt: originalText,
        enableThinking: false, // 翻译是简单任务，关闭思考模式加速生成
        onToken: (token) {
          partialBuf.write(token);
          if (mounted) {
            setState(() {
              _partialTranslations[index] = partialBuf.toString();
            });
          }
        },
        onComplete: (fullText) {
          if (mounted) {
            setState(() {
              _partialTranslations[index] = fullText.trim();
            });
          }
          // 持久化译文（fire-and-forget）
          final segId = _segments[index].id;
          if (segId != null) {
            unawaited(_transcriptStorage
                .updateTranslation(segId, fullText.trim())
                .catchError((e) {
              debugPrint('[Translation] persist failed: $e');
              return -1;
            }));
          }
        },
        onError: (err) {
          debugPrint('[Translation] error: $err');
          if (mounted) {
            setState(() => _partialTranslations[index] = '⚠ 翻译失败: $err');
          }
        },
      );
    } catch (e) {
      debugPrint('[Translation] exception: $e');
      if (mounted) {
        setState(() => _partialTranslations[index] = '⚠ 翻译失败: $e');
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('翻译失败: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _translatingIndices.remove(index));
    }
  }

  // ==========================================================================
  // WAV 写入
  // ==========================================================================

  /// 将 PCM16 字节缓冲写入 16kHz 单声道 WAV 文件。
  Future<String> _writePcmBufferToWav(String dir, List<int> pcmBytes) async {
    final wavPath = p.join(dir, 'mic.wav');
    final wavFile = File(wavPath);

    const sampleRate = 16000;
    final dataSize = pcmBytes.length;
    final header = ByteData(44);
    // RIFF
    header.setUint8(0, 0x52); header.setUint8(1, 0x49);
    header.setUint8(2, 0x46); header.setUint8(3, 0x46);
    header.setUint32(4, 36 + dataSize, Endian.little);
    header.setUint8(8, 0x57); header.setUint8(9, 0x41);
    header.setUint8(10, 0x56); header.setUint8(11, 0x45);
    // fmt
    header.setUint8(12, 0x66); header.setUint8(13, 0x6D);
    header.setUint8(14, 0x74); header.setUint8(15, 0x20);
    header.setUint32(16, 16, Endian.little);
    header.setUint16(20, 1, Endian.little);
    header.setUint16(22, 1, Endian.little);
    header.setUint32(24, sampleRate, Endian.little);
    header.setUint32(28, sampleRate * 2, Endian.little);
    header.setUint16(32, 2, Endian.little);
    header.setUint16(34, 16, Endian.little);
    // data
    header.setUint8(36, 0x64); header.setUint8(37, 0x61);
    header.setUint8(38, 0x74); header.setUint8(39, 0x61);
    header.setUint32(40, dataSize, Endian.little);

    final raf = await wavFile.open(mode: FileMode.write);
    try {
      await raf.writeFrom(header.buffer.asUint8List());
      await raf.writeFrom(Uint8List.fromList(pcmBytes));
    } finally {
      await raf.close();
    }
    return wavPath;
  }

  // ==========================================================================
  // UI 辅助
  // ==========================================================================

  String _formatTime(int seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  String _defaultTitle(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    final stamp =
        '${t.year}${two(t.month)}${two(t.day)}_${two(t.hour)}${two(t.minute)}${two(t.second)}';
    return '实时转写_$stamp';
  }

  String _formatSegmentTime(double sec) {
    final m = (sec ~/ 60).toString().padLeft(2, '0');
    final s = (sec % 60).toStringAsFixed(0).padLeft(2, '0');
    return '$m:$s';
  }

  void _showPostRecordOptions(String sessionId) {
    showModalBottomSheet(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.transcribe_outlined),
                title: const Text('查看转写'),
                subtitle: const Text('进入转写界面查看/编辑逐字稿'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  Navigator.of(context, rootNavigator: true).push(
                    MaterialPageRoute(
                      builder: (_) => TranscriptScreen(sessionId: sessionId),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.auto_awesome_outlined),
                title: const Text('一键整理'),
                subtitle: const Text('自动生成结构化笔记'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  Navigator.of(context, rootNavigator: true).push(
                    MaterialPageRoute(
                      builder: (_) => TranscriptScreen(
                        sessionId: sessionId,
                        autoOrganize: true,
                      ),
                    ),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.arrow_back),
                title: const Text('返回'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  context.pop();
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  // ==========================================================================
  // UI 构建
  // ==========================================================================

  /// 构建单个转写段落卡片。
  Widget _buildSegmentCard(int index) {
    final seg = _segments[index];
    final translation = _partialTranslations[index];
    final colorScheme = Theme.of(context).colorScheme;

    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 时间戳
            Row(
              children: [
                Icon(Icons.schedule, size: 14, color: colorScheme.onSurfaceVariant),
                const SizedBox(width: 4),
                Text(
                  _formatSegmentTime(seg.startTime),
                  style: TextStyle(
                    fontSize: 12,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            // 原文
            SelectableText(
              seg.originalText,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            // 译文（流式更新中 / 翻译中 / 失败）
            if (_translatingIndices.contains(index) &&
                (translation == null || translation.isEmpty)) ...[
              // 模型加载中或翻译中（尚无 token 输出）
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '正在翻译...',
                      style: TextStyle(
                        fontSize: 13,
                        color: colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
            ] else if (translation != null && translation.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: translation.startsWith('⚠')
                      ? colorScheme.errorContainer.withValues(alpha: 0.3)
                      : colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  translation,
                  style: TextStyle(
                    fontSize: 13,
                    color: translation.startsWith('⚠')
                        ? colorScheme.error
                        : colorScheme.onSurfaceVariant,
                    height: 1.4,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 构建"正在聆听..."指示器。
  Widget _buildListeningIndicator() {
    // 流式引擎已产出部分识别文本时，显示实时识别内容（而非固定"正在聆听..."），
    // 让用户看到识别进度。无部分结果时回退到固定文案。
    final partial = _partialAsrText;
    final hasPartial = partial != null && partial.isNotEmpty;
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          AnimatedBuilder(
            animation: _pulseController,
            builder: (_, child) => Opacity(
              opacity: 0.5 + _pulseController.value * 0.5,
              child: child,
            ),
            child: Icon(
              Icons.graphic_eq,
              size: 18,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hasPartial ? partial : '正在聆听...',
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建空状态提示。
  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.edit_note,
            size: 64,
            color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            '点击下方按钮开始录音',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '说话时文字会实时出现',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.6),
              fontSize: 13,
            ),
          ),
          if (_asrStatusHint != null) ...[
            const SizedBox(height: 12),
            Text(
              _asrStatusHint!,
              style: TextStyle(
                fontSize: 11,
                color: Theme.of(context).colorScheme.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 构建底部控制栏。
  Widget _buildControlBar() {
    final colorScheme = Theme.of(context).colorScheme;
    final baseColor = _isRecording ? Colors.red : colorScheme.primary;
    final onColor = _isRecording ? Colors.white : colorScheme.onPrimary;

    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        decoration: BoxDecoration(
          color: colorScheme.surface,
          border: Border(
            top: BorderSide(color: colorScheme.outlineVariant, width: 0.5),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 计时器 + 状态
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: _isRecording ? Colors.red : colorScheme.onSurfaceVariant,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _isRecording ? _formatTime(_elapsedSeconds) : '准备就绪',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: _isRecording ? Colors.red : colorScheme.onSurfaceVariant,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            // 控制按钮行
            Row(
              children: [
                // 实时翻译开关
                _buildTranslationToggle(),
                const Spacer(),
                // 录音/停止按钮
                AnimatedBuilder(
                  animation: _pulseController,
                  builder: (_, child) {
                    final scale = _isRecording ? 1.0 + _pulseController.value * 0.1 : 1.0;
                    final glowAlpha = _isRecording ? 0.3 + _pulseController.value * 0.2 : 0.2;
                    return Transform.scale(
                      scale: scale,
                      child: Container(
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: baseColor.withValues(alpha: glowAlpha),
                              blurRadius: 12,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: child,
                      ),
                    );
                  },
                  child: Material(
                    color: baseColor,
                    shape: const CircleBorder(),
                    clipBehavior: Clip.antiAlias,
                    child: InkWell(
                      onTap: _isPreparing
                          ? null
                          : (_isRecording ? _stopRecording : _startRecording),
                      child: SizedBox(
                        width: 64,
                        height: 64,
                        child: _isPreparing
                            ? const Padding(
                                padding: EdgeInsets.all(18),
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Icon(
                                _isRecording ? Icons.stop_rounded : Icons.mic_rounded,
                                color: onColor,
                                size: 30,
                              ),
                      ),
                    ),
                  ),
                ),
                const Spacer(),
                // 占位（保持按钮居中）
                SizedBox(width: _translationToggleWidth),
              ],
            ),
          ],
        ),
      ),
    );
  }

  static const double _translationToggleWidth = 96.0; // 开关 + 语言下拉框

  /// 可选翻译目标语言列表。
  ///
  /// "自动（中英互译）"为双向互译模式：检测原文是中文则翻译为英语，
  /// 原文是英语则翻译为中文，其他语言保持原文。
  static const List<String> _targetLanguages = [
    '自动（中英互译）', '中文', '英语', '日语', '韩语', '法语', '德语', '西班牙语', '俄语',
  ];

  /// 构建翻译 system prompt。
  ///
  /// 工具型应用要求译文确定、忠实、零发散，prompt 显式约束：
  /// - 仅输出译文，禁止解释/注释/前后缀/思考过程
  /// - 保留原文段落结构与标点风格
  /// - 数字、专有名词、代码、URL 保持原样
  /// - 互译模式：自动检测中英双向翻译；普通模式：翻译到指定目标语言
  String _buildTranslationPrompt(String targetLang) {
    const baseConstraints = '严格规则：\n'
        '1) 只输出译文正文，不要输出思考过程、解释、注释、引号或任何前后缀\n'
        '2) 禁止任何对话式回复——不得出现"好的"、"以下是翻译"、"我来帮你"等寒暄或元话语，'
        '输出的第一个字必须是译文的第一个字\n'
        '3) 保留原文的段落结构与标点风格\n'
        '4) 数字、专有名词、人名、代码、URL、文件路径保持原样不翻译\n'
        '5) 忠于原文含义，不增删信息，不意译发挥\n'
        '6) 译文需自然流畅，符合目标语言习惯';
    if (targetLang == '自动（中英互译）') {
      return '你是专业翻译引擎（非对话助手）。任务：检测用户提供的文本语言——'
          '若为中文翻译为英语，若为英语翻译为中文，其他语言原样输出。\n'
          '$baseConstraints';
    }
    return '你是专业翻译引擎（非对话助手）。任务：将用户提供的文本翻译为$targetLang。'
        '若原文已是$targetLang则原样输出。\n'
        '$baseConstraints';
  }

  Widget _buildTranslationToggle() {
    return SizedBox(
      width: _translationToggleWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: _realtimeTranslationEnabled,
            // 录音中也可切换：开启时翻译已有段落，关闭时仅停止后续翻译
            onChanged: (v) {
              setState(() => _realtimeTranslationEnabled = v);
              if (v && _isRecording && _segments.isNotEmpty) {
                // 录音中开启翻译：补译已有但未翻译的段落
                // fire-and-forget：并发触发多段翻译（LlmTaskRouter 缓存引擎，
                // 翻译任务串行排队由引擎内部处理，此处不阻塞 UI）
                for (var i = 0; i < _segments.length; i++) {
                  if (_partialTranslations.length <= i ||
                      _partialTranslations[i] == null) {
                    unawaited(_translateSegment(i));
                  }
                }
              }
            },
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          // 目标语言下拉框（随时可选，录音中切换不影响已翻译段落）
          DropdownButton<String>(
            value: _translationTargetLang,
            isExpanded: true,
            underline: const SizedBox(),
            style: TextStyle(
              fontSize: 11,
              color: _realtimeTranslationEnabled
                  ? Theme.of(context).colorScheme.primary
                  : Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            items: _targetLanguages
                .map((lang) => DropdownMenuItem(value: lang, child: Text(lang)))
                .toList(),
            onChanged: (value) async {
              if (value == null) return;
              setState(() => _translationTargetLang = value);
              final prefs = await SharedPreferences.getInstance();
              await prefs.setString('translation_target_lang', value);
            },
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _titleController,
          enabled: !_isRecording && !_isPreparing,
          decoration: const InputDecoration(
            hintText: '笔记标题（可选）',
            border: InputBorder.none,
            isDense: true,
          ),
          style: Theme.of(context).appBarTheme.titleTextStyle ??
              Theme.of(context).textTheme.titleLarge,
        ),
        actions: [
          if (_isRecording)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '取消录音',
              onPressed: _cancelRecording,
            ),
        ],
      ),
      body: Column(
        children: [
          // 转写文本展示区（主体）
          Expanded(
            child: _segments.isEmpty && !_isListening
                ? _buildEmptyState()
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: _segments.length + (_isListening ? 1 : 0),
                    itemBuilder: (ctx, i) {
                      if (i < _segments.length) {
                        return _buildSegmentCard(i);
                      }
                      return _buildListeningIndicator();
                    },
                  ),
          ),
          // 底部控制栏
          _buildControlBar(),
        ],
      ),
    );
  }

  /// 取消录音：删除会话与已保存的转写段落。
  Future<void> _cancelRecording() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('取消录音'),
        content: const Text('将丢弃当前录音与转写内容，确定取消？'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('继续录音')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('取消录音', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final sessionId = _currentSessionId;
    final sessionDir = _currentSessionDir;

    // 停止录音：先停麦克风与流订阅，再 await ASR 引擎 stop 等待转写队列
    // 排空，避免后续删除 session 时仍有 onFinal 回调在写孤儿段落。
    _timer?.cancel();
    _timer = null;
    _pulseController.stop();
    _pulseController.reset();
    await _micRecorder.stopStream();
    await _streamSub?.cancel();
    _streamSub = null;
    await _asrEngine?.stop();

    // 清理数据
    if (sessionId != null) {
      await _transcriptStorage.deleteBySession(sessionId);
      await _recordingStorage.deleteSession(sessionId);
    }
    if (sessionDir != null) {
      final dir = Directory(sessionDir);
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    }

    if (mounted) {
      setState(() {
        _isRecording = false;
        _isListening = false;
        _partialAsrText = null;
        _segments.clear();
        _partialTranslations.clear();
        _pcmBuffer.clear();
        _currentSessionId = null;
        _currentSessionDir = null;
      });
      context.pop();
    }
  }
}
