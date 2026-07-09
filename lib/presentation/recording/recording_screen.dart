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

  // 正在聆听/转写指示
  bool _isListening = false; // VAD onSpeechStart 触发

  // 实时翻译开关
  bool _realtimeTranslationEnabled = false;

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
  /// 优先级：
  /// 1. 本地 sherpa-onnx ASR（SenseVoice/Paraformer/Whisper，移动端稳定）
  ///    → SherpaRealtimeAsrEngine（优先 SenseVoice > Paraformer > 其他）
  /// 2. 本地 GGUF ASR（Qwen3-ASR via llama.cpp，质量优但同步 FFI 可能阻塞）
  ///    → LocalRealtimeAsrEngine
  /// 3. 云端 ASR（需配置 baseUrl + apiKey）→ CloudRealtimeAsrEngine
  /// 4. 均不可用 → 抛 StateError，UI 提示去设置页配置
  Future<void> _initAsrEngine() async {
    if (_asrEngine != null && _asrEngine!.isReady) return;

    // 检查 VAD 模型（本地与云端实时 ASR 均依赖）
    // VAD 模型已内置到 assets/models/silero_vad.onnx，首次调用自动释放
    final vadReady = await _asrModelManager.isVadModelDownloaded();
    if (!vadReady) {
      throw StateError('VAD 模型未就绪，请重新安装应用或联系开发者');
    }
    final vadPath = await _asrModelManager.getVadModelPath();
    final asrConfig = await _loadAsrConfig();

    // 优先 1：本地 sherpa-onnx ASR（移动端稳定，ONNX 运行时成熟）
    final sherpaModels = await _asrModelManager.getDownloadedModels();
    if (sherpaModels.isNotEmpty) {
      // 优先 sensevoice-zh（多语言，魔搭下载，国内首选），
      // 其次 paraformer-zh（中文，支持热词），否则取第一个
      final chosen = sherpaModels.firstWhere(
        (m) => m.id == 'sensevoice-zh',
        orElse: () => sherpaModels.firstWhere(
          (m) => m.id == 'paraformer-zh',
          orElse: () => sherpaModels.first,
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

    // 优先 2：本地 GGUF ASR（Qwen3-ASR，质量优但同步 FFI 可能阻塞主线程）
    final ggufModels = await _asrModelManager.getDownloadedGgufModels();
    if (ggufModels.isNotEmpty) {
      // 优先 1.7B（质量更好），否则取第一个
      final chosen = ggufModels.firstWhere(
        (m) => m.id == 'qwen3-asr-1.7b',
        orElse: () => ggufModels.first,
      );
      _asrEngine = LocalRealtimeAsrEngine(
        ggufModelId: chosen.id,
        vadModelPath: vadPath,
      );
      _asrStatusHint = '使用本地 GGUF ASR（${chosen.displayName}）';
      await _asrEngine!.init();
      return;
    }

    // 优先 3：云端 ASR
    if (asrConfig != null &&
        asrConfig.engineType == AsrEngineType.cloud &&
        (asrConfig.baseUrl?.isNotEmpty ?? false) &&
        (asrConfig.apiKey?.isNotEmpty ?? false)) {
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
      '请在设置中下载 SenseVoice 模型（~239MB，从魔搭社区下载，国内首选），'
      '或配置云端 ASR',
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
        if (mounted) setState(() => _isListening = true);
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
    });

    // 持久化到数据库
    _transcriptStorage.insertSegment(segment).catchError((e) {
      debugPrint('[TranscriptStorage] insert failed: $e');
      return -1;
    });

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

    // 实时翻译
    if (_realtimeTranslationEnabled) {
      _translateSegment(_segments.length - 1);
    }
  }

  /// 翻译指定段落（流式，更新 _partialTranslations）。
  Future<void> _translateSegment(int index) async {
    if (index < 0 || index >= _segments.length) return;

    try {
      final engine = await LlmTaskRouter().getEngine(LlmTaskType.translation);
      if (engine == null) {
        // 本地引擎未实现，静默跳过
        return;
      }

      final originalText = _segments[index].originalText;
      const systemPrompt = '你是专业翻译。将用户提供的文本翻译为中文。'
          '只输出译文，不要解释或添加额外内容。如果原文已是中文，原样输出。';

      final partialBuf = StringBuffer();
      await engine.generate(
        systemPrompt: systemPrompt,
        userPrompt: originalText,
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
          // 持久化译文
          final segId = _segments[index].id;
          if (segId != null) {
            _transcriptStorage
                .updateTranslation(segId, fullText.trim())
                .catchError((e) {
              debugPrint('[Translation] persist failed: $e');
              return -1;
            });
          }
        },
        onError: (err) {
          debugPrint('[Translation] error: $err');
        },
      );
    } catch (e) {
      debugPrint('[Translation] exception: $e');
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
            // 译文（流式更新中）
            if (translation != null && translation.isNotEmpty) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: SelectableText(
                  translation,
                  style: TextStyle(
                    fontSize: 13,
                    color: colorScheme.onSurfaceVariant,
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
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
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
          Text(
            '正在聆听...',
            style: TextStyle(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w500,
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

  static const double _translationToggleWidth = 48 + 32.0; // 开关 + 文字估算

  Widget _buildTranslationToggle() {
    return SizedBox(
      width: _translationToggleWidth,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch(
            value: _realtimeTranslationEnabled,
            onChanged: _isRecording
                ? null
                : (v) => setState(() => _realtimeTranslationEnabled = v),
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          Text(
            '翻译',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
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

    // 停止录音（不等待转写队列）
    _timer?.cancel();
    _timer = null;
    _pulseController.stop();
    _pulseController.reset();
    await _micRecorder.stopStream();
    await _streamSub?.cancel();
    _streamSub = null;
    _asrEngine?.stop();

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
