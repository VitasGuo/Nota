// lib/services/asr/realtime_asr_engine.dart
//
// 实时 ASR 引擎：PCM16 音频流 → VAD 分段 → 逐段转写 → 回调。
//
// 与 [AsrEngine]（批量转写完整音频文件）不同，[RealtimeAsrEngine] 面向
// 录音时的实时场景：边录音边 VAD 分段，每段语音结束立即送 ASR 推理，
// 转写文本通过 [onFinal] 回调实时推送到 UI。
//
// 三个实现：
// - [LocalRealtimeAsrEngine]：VAD + llama.cpp Qwen3-ASR（离线，低延迟，需 GGUF ~1-2.4GB）
// - [SherpaRealtimeAsrEngine]：VAD + sherpa-onnx OfflineRecognizer（离线，SenseVoice ~239MB 首选 / Paraformer ~213MB 回退）
// - [CloudRealtimeAsrEngine]：VAD + 云端 Whisper 兼容 API（在线，需网络）

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'package:nota/models/transcript.dart';
import 'package:nota/services/asr/asr_engine.dart';
import 'package:nota/services/asr/asr_model_info.dart';
import 'package:nota/services/asr/asr_model_manager.dart';
import 'package:nota/services/asr/cloud_asr_engine.dart';
import 'package:nota/services/asr/vad_detector.dart';
import 'package:nota/services/llm/llama_cpp_engine.dart';

/// 实时 ASR 引擎类型。
enum RealtimeAsrEngineType { local, cloud }

/// 实时 ASR 引擎抽象接口。
///
/// 工作流程：
/// 1. [init] 加载模型（本地）或配置 API（云端）
/// 2. [start] 订阅 PCM16 音频流 → 喂入 VAD → 语音段出队时送 ASR 推理
/// 3. 每段转写完成 → [onFinal] 回调 [TranscriptSegment]
/// 4. [stop] 取消订阅，flush VAD 尾部残余段
/// 5. [dispose] 释放全部资源
///
/// 回调约定（均在主 isolate 同步触发）：
/// - [onSpeechStart]：VAD 检测到语音开始（可用于 UI 显示"正在说话..."）
/// - [onFinal]：一段语音转写完成，携带完整文本与时间戳
/// - [onError]：转写过程异常（不致命，引擎继续运行）
///
/// 注意：`onPartial`（逐字部分结果）在当前实现中未使用——Qwen3-ASR via
/// mtmd 为整段推理，不支持 token 级流式。UI 可在 [onSpeechStart] 后
/// 显示"正在转写..."占位，[onFinal] 时替换为实际文本。
abstract class RealtimeAsrEngine {
  /// 语音开始回调（VAD 检测到语音活动边沿）。
  void Function()? onSpeechStart;

  /// 一段转写完成回调。
  void Function(TranscriptSegment segment)? onFinal;

  /// 转写异常回调（非致命，引擎继续运行下一段）。
  void Function(Object error, StackTrace stack)? onError;

  /// 引擎类型。
  RealtimeAsrEngineType get engineType;

  /// 是否已初始化（模型已加载 / API 已配置）。
  bool get isReady;

  /// 是否正在运行（已 start 未 stop）。
  bool get isRunning;

  /// 初始化引擎（加载模型 / 配置 API）。幂等。
  Future<void> init();

  /// 开始监听音频流。
  ///
  /// [audioStream] PCM16 小端有符号 16-bit 单声道 16kHz 裸流
  /// （来自 [MicRecorder.startStream]）。
  /// [sessionId] 当前录音会话 ID，用于构建 [TranscriptSegment]。
  Future<void> start(Stream<Uint8List> audioStream, String sessionId);

  /// 停止监听。flush VAD 尾部残余段并完成队列中所有转写。
  Future<void> stop();

  /// 释放全部资源（VAD、ASR 模型等）。释放后不可再使用。
  Future<void> dispose();
}

// ============================================================================
// 内部：待转写的语音段
// ============================================================================

class _PendingSpeech {
  final Float32List samples;
  final double startSec;
  final double endSec;

  _PendingSpeech(this.samples, this.startSec, this.endSec);
}

// ============================================================================
// 本地实时 ASR 引擎（VAD + llama.cpp Qwen3-ASR）
// ============================================================================

/// 本地实时 ASR 引擎。
///
/// 基于 [VadDetector]（sherpa-onnx Silero VAD）分段 + [LlamaCppEngine]
/// （llama.cpp mtmd Qwen3-ASR）逐段转写。完全离线，无网络依赖。
///
/// 转写异步处理：VAD 分段在音频流订阅回调中同步完成（快速），每段送入
/// 待转写队列；后台逐段调用 [LlamaCppEngine.transcribeAudio]（1-3s/段），
/// 完成后触发 [onFinal]。多段累积时按 FIFO 顺序处理。
///
/// 构造时需指定 [ggufModelId]（来自 [GgufAsrModels.available]）与
/// [vadModelPath]（来自 [AsrModelManager.getVadModelPath]）。
class LocalRealtimeAsrEngine extends RealtimeAsrEngine {
  LocalRealtimeAsrEngine({
    required this.ggufModelId,
    required this.vadModelPath,
    this.nThreads = 4,
    this.nCtx = 4096,
    this.vadConfig = const VadConfig(),
  });

  /// GGUF ASR 模型 id（如 `qwen3-asr-1.7b`，见 [GgufAsrModels.available]）。
  final String ggufModelId;

  /// VAD 模型文件路径（silero_vad.onnx）。
  final String vadModelPath;

  /// ASR 推理线程数。
  final int nThreads;

  /// ASR 上下文长度。
  final int nCtx;

  /// VAD 参数配置。
  final VadConfig vadConfig;

  LlamaCppEngine? _llama;
  VadDetector? _vad;

  StreamSubscription<Uint8List>? _sub;
  String? _sessionId;
  bool _isReady = false;
  bool _running = false;
  bool _disposed = false;

  final _pending = <_PendingSpeech>[];
  bool _transcribing = false;

  @override
  RealtimeAsrEngineType get engineType => RealtimeAsrEngineType.local;

  @override
  bool get isReady => _isReady;

  @override
  bool get isRunning => _running;

  @override
  Future<void> init() async {
    if (_disposed) throw StateError('引擎已释放');
    if (_isReady) return;

    // 1. 加载 Qwen3-ASR 模型
    final manager = AsrModelManager();
    if (!await manager.isGgufModelDownloaded(ggufModelId)) {
      throw StateError('GGUF ASR 模型 $ggufModelId 未下载，请先下载');
    }
    final paths = await manager.getGgufModelPaths(ggufModelId);

    _llama = LlamaCppEngine();
    await _llama!.loadAsrModel(
      paths.mainPath,
      paths.mmprojPath,
      nCtx: nCtx,
      nThreads: nThreads,
    );

    // 2. 创建 VAD
    _vad = VadDetector(
      modelPath: vadModelPath,
      threshold: vadConfig.threshold,
      minSilenceDuration: vadConfig.minSilenceDuration,
      minSpeechDuration: vadConfig.minSpeechDuration,
      maxSpeechDuration: vadConfig.maxSpeechDuration,
      windowSize: vadConfig.windowSize,
      sampleRate: vadConfig.sampleRate,
      numThreads: vadConfig.numThreads,
      onSpeechStart: () => onSpeechStart?.call(),
      onSpeechEnd: (startSample, samples, startSec, endSec) {
        _pending.add(_PendingSpeech(samples, startSec, endSec));
        _processQueue();
      },
    );

    _isReady = true;
  }

  @override
  Future<void> start(Stream<Uint8List> audioStream, String sessionId) async {
    if (!_isReady) throw StateError('引擎未初始化，请先调用 init()');
    if (_running) return;

    _sessionId = sessionId;
    _running = true;
    _sub = audioStream.listen(
      (bytes) => _vad?.feedPcm16(bytes),
      onError: (e, st) => onError?.call(e, st),
      onDone: () => stop(),
    );
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;

    await _sub?.cancel();
    _sub = null;

    // flush VAD 尾部残余段
    _vad?.flush();

    // 等待队列中所有段转写完成
    while (_transcribing || _pending.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _vad?.dispose();
    _vad = null;
    _llama?.dispose();
    _llama = null;
    _disposed = true;
  }

  /// 逐段处理待转写队列。
  ///
  /// 串行处理：同一时刻仅一个转写任务在执行，避免 llama.cpp 上下文竞争。
  /// 每段转写完成后触发 [onFinal]，异常触发 [onError]（不中断队列）。
  Future<void> _processQueue() async {
    if (_transcribing) return;
    _transcribing = true;

    while (_pending.isNotEmpty) {
      final seg = _pending.removeAt(0);
      // 跳过过短的音频段（< 0.1s = 1600 样本 @ 16kHz），避免原生库 crash
      if (seg.samples.length < 1600) continue;
      try {
        final text = _llama!.transcribeAudio(seg.samples);
        if (text.isNotEmpty && _sessionId != null) {
          onFinal?.call(TranscriptSegment(
            sessionId: _sessionId!,
            startTime: seg.startSec,
            endTime: seg.endSec,
            originalText: text,
          ));
        }
      } catch (e, st) {
        onError?.call(e, st);
      }
    }

    _transcribing = false;
  }
}

// ============================================================================
// 云端实时 ASR 引擎（VAD + 云端 Whisper 兼容 API）
// ============================================================================

/// 云端实时 ASR 引擎。
///
/// VAD 分段后，每段 PCM 写入临时 WAV 文件，调用 [CloudAsrEngine.transcribe]
/// 上传转写。相比 [LocalRealtimeAsrEngine] 多了网络往返延迟，但无需本地
/// ASR 模型，适合设备算力不足或追求更高精度的场景。
class CloudRealtimeAsrEngine extends RealtimeAsrEngine {
  CloudRealtimeAsrEngine({
    required this.asrConfig,
    this.vadModelPath,
    this.vadConfig = const VadConfig(),
  });

  /// 云端 ASR 配置（baseUrl / apiKey / modelName）。
  final AsrConfig asrConfig;

  /// VAD 模型文件路径。为 null 时不做 VAD 分段（整段上传）。
  final String? vadModelPath;

  /// VAD 参数配置。
  final VadConfig vadConfig;

  CloudAsrEngine? _cloud;
  VadDetector? _vad;

  StreamSubscription<Uint8List>? _sub;
  String? _sessionId;
  bool _isReady = false;
  bool _running = false;
  bool _disposed = false;

  final _pending = <_PendingSpeech>[];
  bool _transcribing = false;

  @override
  RealtimeAsrEngineType get engineType => RealtimeAsrEngineType.cloud;

  @override
  bool get isReady => _isReady;

  @override
  bool get isRunning => _running;

  @override
  Future<void> init() async {
    if (_disposed) throw StateError('引擎已释放');
    if (_isReady) return;

    _cloud = CloudAsrEngine();
    await _cloud!.init(asrConfig);

    if (vadModelPath != null) {
      _vad = VadDetector(
        modelPath: vadModelPath!,
        threshold: vadConfig.threshold,
        minSilenceDuration: vadConfig.minSilenceDuration,
        minSpeechDuration: vadConfig.minSpeechDuration,
        maxSpeechDuration: vadConfig.maxSpeechDuration,
        windowSize: vadConfig.windowSize,
        sampleRate: vadConfig.sampleRate,
        numThreads: vadConfig.numThreads,
        onSpeechStart: () => onSpeechStart?.call(),
        onSpeechEnd: (startSample, samples, startSec, endSec) {
          _pending.add(_PendingSpeech(samples, startSec, endSec));
          _processQueue();
        },
      );
    }

    _isReady = true;
  }

  @override
  Future<void> start(Stream<Uint8List> audioStream, String sessionId) async {
    if (!_isReady) throw StateError('引擎未初始化，请先调用 init()');
    if (_running) return;

    _sessionId = sessionId;
    _running = true;

    if (_vad != null) {
      _sub = audioStream.listen(
        (bytes) => _vad?.feedPcm16(bytes),
        onError: (e, st) => onError?.call(e, st),
        onDone: () => stop(),
      );
    } else {
      // 无 VAD 模式：累积全部 PCM 到单一缓冲，stop 时整段上传
      final buf = <int>[];
      _sub = audioStream.listen(
        (bytes) => buf.addAll(bytes),
        onError: (e, st) => onError?.call(e, st),
        onDone: () {
          _running = false;
          _pending.add(_PendingSpeech(
            convertPcm16ToFloat32(Uint8List.fromList(buf)),
            0,
            buf.length / (vadConfig.sampleRate * 2),
          ));
          _processQueue();
        },
      );
    }
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;

    await _sub?.cancel();
    _sub = null;

    _vad?.flush();

    while (_transcribing || _pending.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _vad?.dispose();
    _vad = null;
    await _cloud?.dispose();
    _cloud = null;
    _disposed = true;
  }

  /// 逐段处理：写临时 WAV → 云端转写 → 回调。
  Future<void> _processQueue() async {
    if (_transcribing) return;
    _transcribing = true;

    while (_pending.isNotEmpty) {
      final seg = _pending.removeAt(0);
      File? tmpFile;
      try {
        // 写临时 WAV 文件
        tmpFile = await _writeTempWav(seg.samples);
        final segments = await _cloud!.transcribe(tmpFile.path);
        if (segments.isNotEmpty && _sessionId != null) {
          // 合并多段为单条文本（VAD 段已是完整语音单元）
          final text = segments.map((s) => s.originalText).join(' ');
          if (text.isNotEmpty) {
            onFinal?.call(TranscriptSegment(
              sessionId: _sessionId!,
              startTime: seg.startSec,
              endTime: seg.endSec,
              originalText: text,
            ));
          }
        }
      } catch (e, st) {
        onError?.call(e, st);
      } finally {
        if (tmpFile != null) {
          try {
            await tmpFile.delete();
          } catch (_) {}
        }
      }
    }

    _transcribing = false;
  }

  /// 将 Float32 PCM 样本写入 16kHz 单声道 WAV 临时文件。
  Future<File> _writeTempWav(Float32List samples) async {
    final tmpDir = await Directory.systemTemp.createTemp('nota_cloud_asr_');
    final wavPath = '${tmpDir.path}/segment.wav';
    final wavFile = File(wavPath);

    // WAV header (44 bytes) + PCM16 data
    final dataSize = samples.length * 2;
    final header = ByteData(44);
    // RIFF header
    header.setUint8(0, 0x52); // 'R'
    header.setUint8(1, 0x49); // 'I'
    header.setUint8(2, 0x46); // 'F'
    header.setUint8(3, 0x46); // 'F'
    header.setUint32(4, 36 + dataSize, Endian.little);
    header.setUint8(8, 0x57); // 'W'
    header.setUint8(9, 0x41); // 'A'
    header.setUint8(10, 0x56); // 'V'
    header.setUint8(11, 0x45); // 'E'
    // fmt chunk
    header.setUint8(12, 0x66); // 'f'
    header.setUint8(13, 0x6D); // 'm'
    header.setUint8(14, 0x74); // 't'
    header.setUint8(15, 0x20); // ' '
    header.setUint32(16, 16, Endian.little); // chunk size
    header.setUint16(20, 1, Endian.little); // audio format = PCM
    header.setUint16(22, 1, Endian.little); // num channels = 1
    header.setUint32(24, vadConfig.sampleRate, Endian.little);
    header.setUint32(28, vadConfig.sampleRate * 2, Endian.little); // byte rate
    header.setUint16(32, 2, Endian.little); // block align
    header.setUint16(34, 16, Endian.little); // bits per sample
    // data chunk
    header.setUint8(36, 0x64); // 'd'
    header.setUint8(37, 0x61); // 'a'
    header.setUint8(38, 0x74); // 't'
    header.setUint8(39, 0x61); // 'a'
    header.setUint32(40, dataSize, Endian.little);

    final raf = await wavFile.open(mode: FileMode.write);
    try {
      await raf.writeFrom(header.buffer.asUint8List());
      // Float32 → PCM16 小端
      final pcm16 = Int16List(samples.length);
      for (int i = 0; i < samples.length; i++) {
        final v = (samples[i] * 32767).round().clamp(-32768, 32767);
        pcm16[i] = v;
      }
      await raf.writeFrom(pcm16.buffer.asUint8List());
    } finally {
      await raf.close();
    }

    return wavFile;
  }
}

// ============================================================================
// sherpa-onnx 实时 ASR 引擎（VAD + OfflineRecognizer，支持 SenseVoice/Paraformer/Whisper）
// ============================================================================

/// 基于 sherpa-onnx 的实时 ASR 引擎。
///
/// 与 [LocalRealtimeAsrEngine]（llama.cpp Qwen3-ASR，需 GGUF ~1-2.4GB）不同，
/// 本引擎使用 sherpa-onnx 的 [sherpa_onnx.OfflineRecognizer] 逐段转写 VAD
/// 分段结果。支持三类模型：
/// - SenseVoice（多语言中英日韩粤，~239MB，从魔搭社区下载，国内首选）
/// - Paraformer（中文，支持热词，~213MB，从 hf-mirror.com 下载）
/// - Whisper（多语言，769M+，从 GitHub 下载）
///
/// 适用场景：用户已下载 sherpa-onnx 模型（推荐 SenseVoice，国内网络最友好），
/// 但未下载 GGUF ASR 模型时的实时转写回退方案。完全离线，无网络依赖。
///
/// 构造时需指定 [sherpaModelId]（来自 [AsrModels.available]，如 `paraformer-zh`）
/// 与 [vadModelPath]（来自 [AsrModelManager.getVadModelPath]）。
class SherpaRealtimeAsrEngine extends RealtimeAsrEngine {
  SherpaRealtimeAsrEngine({
    required this.sherpaModelId,
    required this.vadModelPath,
    this.language = 'zh',
    this.vadConfig = const VadConfig(),
  });

  /// sherpa-onnx 模型 id（如 `paraformer-zh`、`whisper-medium`）。
  final String sherpaModelId;

  /// VAD 模型文件路径（silero_vad.onnx）。
  final String vadModelPath;

  /// 识别语言（Whisper 用，Paraformer 固定中文）。
  final String language;

  /// VAD 参数配置。
  final VadConfig vadConfig;

  sherpa_onnx.OfflineRecognizer? _recognizer;
  VadDetector? _vad;
  bool _bindingsInitialized = false;

  StreamSubscription<Uint8List>? _sub;
  String? _sessionId;
  bool _isReady = false;
  bool _running = false;
  bool _disposed = false;

  final _pending = <_PendingSpeech>[];
  bool _transcribing = false;

  @override
  RealtimeAsrEngineType get engineType => RealtimeAsrEngineType.local;

  @override
  bool get isReady => _isReady;

  @override
  bool get isRunning => _running;

  @override
  Future<void> init() async {
    if (_disposed) throw StateError('引擎已释放');
    if (_isReady) return;

    final info = AsrModels.getById(sherpaModelId);
    if (info == null) {
      throw ArgumentError('未知的 sherpa-onnx 模型 id: $sherpaModelId');
    }

    final manager = AsrModelManager();
    if (!await manager.isModelDownloaded(sherpaModelId)) {
      throw StateError('模型 $sherpaModelId 尚未下载，请先下载模型');
    }

    if (!_bindingsInitialized) {
      sherpa_onnx.initBindings();
      _bindingsInitialized = true;
    }

    final modelDirPath = await manager.getActiveModelPath(sherpaModelId);
    final tokensPath = _findFile(modelDirPath, 'tokens.txt');
    if (tokensPath == null) {
      throw StateError('模型 $sherpaModelId 缺少 tokens.txt');
    }

    final recognizerConfig = _buildRecognizerConfig(
      info: info,
      modelDirPath: modelDirPath,
      tokensPath: tokensPath,
    );
    _recognizer = sherpa_onnx.OfflineRecognizer(recognizerConfig);

    _vad = VadDetector(
      modelPath: vadModelPath,
      threshold: vadConfig.threshold,
      minSilenceDuration: vadConfig.minSilenceDuration,
      minSpeechDuration: vadConfig.minSpeechDuration,
      maxSpeechDuration: vadConfig.maxSpeechDuration,
      windowSize: vadConfig.windowSize,
      sampleRate: vadConfig.sampleRate,
      numThreads: vadConfig.numThreads,
      onSpeechStart: () => onSpeechStart?.call(),
      onSpeechEnd: (startSample, samples, startSec, endSec) {
        _pending.add(_PendingSpeech(samples, startSec, endSec));
        _processQueue();
      },
    );

    _isReady = true;
  }

  @override
  Future<void> start(Stream<Uint8List> audioStream, String sessionId) async {
    if (!_isReady) throw StateError('引擎未初始化，请先调用 init()');
    if (_running) return;

    _sessionId = sessionId;
    _running = true;
    _sub = audioStream.listen(
      (bytes) => _vad?.feedPcm16(bytes),
      onError: (e, st) => onError?.call(e, st),
      onDone: () => stop(),
    );
  }

  @override
  Future<void> stop() async {
    if (!_running) return;
    _running = false;

    await _sub?.cancel();
    _sub = null;

    _vad?.flush();

    while (_transcribing || _pending.isNotEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await stop();
    _vad?.dispose();
    _vad = null;
    if (_recognizer != null) {
      _recognizer!.free();
      _recognizer = null;
    }
    _disposed = true;
  }

  /// 逐段处理待转写队列。
  ///
  /// 串行处理：同一时刻仅一个转写任务在执行。每段转写完成后触发 [onFinal]，
  /// 异常触发 [onError]（不中断队列）。
  Future<void> _processQueue() async {
    if (_transcribing) return;
    _transcribing = true;

    while (_pending.isNotEmpty) {
      final seg = _pending.removeAt(0);
      // 跳过过短的音频段（< 0.1s = 1600 样本 @ 16kHz），避免原生库 crash
      if (seg.samples.length < 1600) continue;
      try {
        final text = _recognizeChunk(seg.samples, vadConfig.sampleRate);
        if (text.isNotEmpty && _sessionId != null) {
          onFinal?.call(TranscriptSegment(
            sessionId: _sessionId!,
            startTime: seg.startSec,
            endTime: seg.endSec,
            originalText: text,
          ));
        }
      } catch (e, st) {
        onError?.call(e, st);
      }
    }

    _transcribing = false;
  }

  /// 识别单个音频分片，返回文本。
  String _recognizeChunk(Float32List samples, int sampleRate) {
    final stream = _recognizer!.createStream();
    try {
      stream.acceptWaveform(samples: samples, sampleRate: sampleRate);
      _recognizer!.decode(stream);
      final result = _recognizer!.getResult(stream);
      return result.text;
    } finally {
      stream.free();
    }
  }

  /// 根据模型类型构建离线识别器配置（参考 [LocalAsrEngine._buildRecognizerConfig]）。
  ///
  /// 支持三类模型：
  /// - SenseVoice（id 以 `sensevoice` 开头）：OfflineSenseVoiceModelConfig
  /// - Whisper（id 以 `whisper` 开头）：OfflineWhisperModelConfig（encoder + decoder）
  /// - Paraformer（id 以 `paraformer` 开头）：OfflineParaformerModelConfig
  /// - 其他：兜底按 paraformer 单文件方式加载
  sherpa_onnx.OfflineRecognizerConfig _buildRecognizerConfig({
    required AsrModelInfo info,
    required String modelDirPath,
    required String tokensPath,
  }) {
    final isSenseVoice = info.id.startsWith('sensevoice');
    final isWhisper = info.id.startsWith('whisper');
    final isParaformer = info.id.startsWith('paraformer');

    sherpa_onnx.OfflineModelConfig modelConfig;
    if (isSenseVoice) {
      final modelPath = _findModelFile(modelDirPath, 'model') ??
          _findFirstOnnx(modelDirPath);
      if (modelPath == null) {
        throw StateError('SenseVoice 模型 ${info.id} 缺少 .onnx 文件');
      }
      modelConfig = sherpa_onnx.OfflineModelConfig(
        senseVoice: sherpa_onnx.OfflineSenseVoiceModelConfig(
          model: modelPath,
          language: _senseVoiceLanguage(language),
          useInverseTextNormalization: true,
        ),
        tokens: tokensPath,
        numThreads: 2,
        debug: false,
      );
    } else if (isWhisper) {
      final encoderPath = _findModelFile(modelDirPath, 'encoder');
      final decoderPath = _findModelFile(modelDirPath, 'decoder');
      if (encoderPath == null || decoderPath == null) {
        throw StateError(
          'Whisper 模型 ${info.id} 缺少 encoder/decoder .onnx 文件',
        );
      }
      modelConfig = sherpa_onnx.OfflineModelConfig(
        whisper: sherpa_onnx.OfflineWhisperModelConfig(
          encoder: encoderPath,
          decoder: decoderPath,
          language: _whisperLanguage(language),
          task: 'transcribe',
          tailPaddings: 1000,
        ),
        tokens: tokensPath,
        numThreads: 2,
        modelType: 'whisper',
        debug: false,
      );
    } else if (isParaformer) {
      final modelPath = _findModelFile(modelDirPath, 'model');
      if (modelPath == null) {
        throw StateError('Paraformer 模型 ${info.id} 缺少 model.onnx 文件');
      }
      modelConfig = sherpa_onnx.OfflineModelConfig(
        paraformer: sherpa_onnx.OfflineParaformerModelConfig(
          model: modelPath,
        ),
        tokens: tokensPath,
        numThreads: 2,
        modelType: 'paraformer',
        debug: false,
      );
    } else {
      // 兜底：尝试按 paraformer 单文件方式加载
      final modelPath = _findModelFile(modelDirPath, 'model') ??
          _findFirstOnnx(modelDirPath);
      if (modelPath == null) {
        throw StateError('模型 ${info.id} 未找到任何 .onnx 文件');
      }
      modelConfig = sherpa_onnx.OfflineModelConfig(
        paraformer: sherpa_onnx.OfflineParaformerModelConfig(
          model: modelPath,
        ),
        tokens: tokensPath,
        numThreads: 2,
        debug: false,
      );
    }

    return sherpa_onnx.OfflineRecognizerConfig(
      model: modelConfig,
      hotwordsFile: '',
      hotwordsScore: 1.5,
    );
  }

  String _whisperLanguage(String lang) {
    switch (lang) {
      case 'zh':
        return 'zh';
      case 'en':
        return 'en';
      default:
        return '';
    }
  }

  /// SenseVoice 语言代码映射。
  ///
  /// SenseVoice 支持：zh / en / yue / ja / ko / auto。
  /// 当 [lang] 为 'multi' 或未识别时返回 'auto'（自动检测）。
  String _senseVoiceLanguage(String lang) {
    switch (lang) {
      case 'zh':
        return 'zh';
      case 'en':
        return 'en';
      case 'yue':
        return 'yue';
      case 'ja':
        return 'ja';
      case 'ko':
        return 'ko';
      default:
        return 'auto';
    }
  }

  // —— 文件定位辅助（与 LocalAsrEngine 一致）——

  /// 在 [dirPath] 及其一级子目录中查找名为 [name] 的文件，返回绝对路径。
  String? _findFile(String dirPath, String name) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return null;

    final direct = p.join(dirPath, name);
    if (File(direct).existsSync()) return direct;

    for (final sub in dir.listSync()) {
      if (sub is Directory) {
        final f = p.join(sub.path, name);
        if (File(f).existsSync()) return f;
      }
    }
    return null;
  }

  /// 在 [dirPath] 及其一级子目录中查找以 [prefix] 开头且 .onnx 结尾的文件。
  String? _findModelFile(String dirPath, String prefix) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return null;

    for (final e in dir.listSync()) {
      if (e is File) {
        final name = p.basename(e.path);
        if (name.startsWith(prefix) && name.endsWith('.onnx')) {
          return e.path;
        }
      }
    }
    // 检查一级子目录
    for (final sub in dir.listSync()) {
      if (sub is Directory) {
        for (final e in sub.listSync()) {
          if (e is File) {
            final name = p.basename(e.path);
            if (name.startsWith(prefix) && name.endsWith('.onnx')) {
              return e.path;
            }
          }
        }
      }
    }
    return null;
  }

  /// 递归查找目录下第一个 .onnx 文件。
  String? _findFirstOnnx(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return null;

    for (final e in dir.listSync(recursive: true)) {
      if (e is File && e.path.endsWith('.onnx')) {
        return e.path;
      }
    }
    return null;
  }
}

// ============================================================================
// VAD 参数配置
// ============================================================================

/// VAD 参数配置（[VadDetector] 的默认值封装）。
class VadConfig {
  final double threshold;
  final double minSilenceDuration;
  final double minSpeechDuration;
  final double maxSpeechDuration;
  final int windowSize;
  final int sampleRate;
  final int numThreads;

  const VadConfig({
    this.threshold = 0.5,
    this.minSilenceDuration = 0.8,
    this.minSpeechDuration = 0.25,
    this.maxSpeechDuration = 30.0,
    this.windowSize = 512,
    this.sampleRate = 16000,
    this.numThreads = 1,
  });
}
