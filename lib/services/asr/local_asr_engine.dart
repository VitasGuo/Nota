import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa_onnx;

import 'package:nota/models/transcript.dart';
import 'package:nota/services/asr/asr_engine.dart';
import 'package:nota/services/asr/asr_model_info.dart';
import 'package:nota/services/asr/asr_model_manager.dart';

/// 本地 ASR 引擎（基于 sherpa-onnx，离线可用）。
///
/// 实现 [AsrEngine] 接口，使用 sherpa-onnx 的 **离线识别器**（OfflineRecognizer）
/// 完成非流式转写。支持 Whisper（多语言）与 Paraformer（中文，支持热词）两类模型。
///
/// 工作流程：
/// 1. [init] 校验模型已下载 → 调用 `sherpa_onnx.initBindings()` →
///    定位 tokens / encoder / decoder / model 文件 → 构建
///    [sherpa_onnx.OfflineRecognizerConfig] → 创建识别器。
/// 2. [transcribe] 读取 WAV（16kHz 单声道）→ 超过 30 秒按窗口切片 →
///    逐段 `createStream` + `acceptWaveform` + `decode` + `getResult` →
///    构建 [TranscriptSegment] 并回调。
/// 3. [dispose] 释放识别器与热词临时文件。
///
/// 长音频分段策略：固定 30 秒窗口无重叠切片（v1）。
/// TODO: 词级时间戳聚合为更细粒度片段；分段重叠以避免切词。
class LocalAsrEngine extends AsrEngine {
  LocalAsrEngine._();
  static final LocalAsrEngine _instance = LocalAsrEngine._();
  factory LocalAsrEngine() => _instance;

  /// 长音频分段窗口（秒）。Whisper 单次处理上限约 30 秒。
  static const double _segmentWindowSeconds = 30.0;

  bool _isReady = false;
  bool _bindingsInitialized = false;

  sherpa_onnx.OfflineRecognizer? _recognizer;
  AsrConfig? _config;

  /// 热词临时文件路径（Paraformer 启用热词时生成，dispose 时清理）。
  String? _hotwordsFilePath;

  @override
  AsrEngineType get engineType => AsrEngineType.local;

  @override
  bool get isReady => _isReady;

  @override
  Future<void> init(AsrConfig config) async {
    // 幂等：相同模型已加载则直接返回
    if (_isReady && _config?.modelName == config.modelName) return;

    // 切换模型：先释放旧资源
    if (_recognizer != null) {
      _recognizer!.free();
      _recognizer = null;
      _isReady = false;
    }
    await _cleanupHotwordsFile();

    if (config.modelName == null || config.modelName!.isEmpty) {
      throw StateError('本地 ASR 引擎需要 modelName（模型 id）');
    }

    final modelId = config.modelName!;
    final info = AsrModels.getById(modelId);
    if (info == null) {
      throw ArgumentError('未知的模型 id: $modelId');
    }

    final manager = AsrModelManager();
    if (!await manager.isModelDownloaded(modelId)) {
      throw StateError('模型 $modelId 尚未下载，请先下载模型');
    }

    // 初始化 native 绑定（进程生命周期内仅一次）
    if (!_bindingsInitialized) {
      sherpa_onnx.initBindings();
      _bindingsInitialized = true;
    }

    final modelDirPath = await manager.getActiveModelPath(modelId);
    final tokensPath = _findFile(modelDirPath, 'tokens.txt');
    if (tokensPath == null) {
      throw StateError('模型 $modelId 缺少 tokens.txt');
    }

    // 处理热词（仅支持热词的模型生效）
    String hotwordsFile = '';
    if (info.supportsHotwords &&
        config.hotwords != null &&
        config.hotwords!.isNotEmpty) {
      hotwordsFile = await _writeHotwordsFile(config.hotwords!) ?? '';
      _hotwordsFilePath = hotwordsFile.isEmpty ? null : hotwordsFile;
    }

    final recognizerConfig = _buildRecognizerConfig(
      info: info,
      modelDirPath: modelDirPath,
      tokensPath: tokensPath,
      config: config,
      hotwordsFile: hotwordsFile,
    );

    _recognizer = sherpa_onnx.OfflineRecognizer(recognizerConfig);
    _config = config;
    _isReady = true;
  }

  @override
  Future<List<TranscriptSegment>> transcribe(
    String audioPath, {
    void Function(double progress)? onProgress,
    void Function(TranscriptSegment segment)? onSegment,
  }) async {
    if (!_isReady || _recognizer == null) {
      throw StateError('ASR 引擎未初始化，请先调用 init()');
    }

    final file = File(audioPath);
    if (!file.existsSync()) {
      throw FileSystemException('音频文件不存在', audioPath);
    }

    // 读取 WAV（期望 16kHz 单声道）
    final wave = sherpa_onnx.readWave(audioPath);
    if (wave.samples.isEmpty) {
      throw StateError('音频读取失败或为空: $audioPath');
    }

    final sampleRate = wave.sampleRate;
    final samples = wave.samples;
    final totalSamples = samples.length;

    // 分段：超过窗口则按 30 秒切片，否则整段处理
    final segmentSamples = (_segmentWindowSeconds * sampleRate).round();
    final chunks = <_AudioChunk>[];
    for (var i = 0; i < totalSamples; i += segmentSamples) {
      final end = (i + segmentSamples > totalSamples)
          ? totalSamples
          : i + segmentSamples;
      chunks.add(_AudioChunk(
        samples: Float32List.fromList(samples.sublist(i, end)),
        startSec: i / sampleRate,
        endSec: end / sampleRate,
      ));
    }

    final segments = <TranscriptSegment>[];
    for (var i = 0; i < chunks.length; i++) {
      final chunk = chunks[i];
      final text = _recognizeChunk(chunk.samples, sampleRate);
      final cleaned = text.trim();

      if (cleaned.isNotEmpty) {
        final seg = TranscriptSegment(
          sessionId: '',
          startTime: chunk.startSec,
          endTime: chunk.endSec,
          originalText: cleaned,
        );
        segments.add(seg);
        onSegment?.call(seg);
      }

      onProgress?.call((i + 1) / chunks.length);
    }

    return segments;
  }

  @override
  Future<void> dispose() async {
    if (_recognizer != null) {
      _recognizer!.free();
      _recognizer = null;
    }
    _isReady = false;
    _config = null;
    await _cleanupHotwordsFile();
  }

  // —— 内部：识别器配置 ——

  /// 根据模型类型构建离线识别器配置。
  sherpa_onnx.OfflineRecognizerConfig _buildRecognizerConfig({
    required AsrModelInfo info,
    required String modelDirPath,
    required String tokensPath,
    required AsrConfig config,
    required String hotwordsFile,
  }) {
    final isWhisper = info.id.startsWith('whisper');
    final isParaformer = info.id.startsWith('paraformer');

    sherpa_onnx.OfflineModelConfig modelConfig;
    if (isWhisper) {
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
          language: _whisperLanguage(config.language),
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
      // TODO: 新增模型族时在此补充对应配置
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
      hotwordsFile: hotwordsFile,
      hotwordsScore: 1.5,
    );
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

  // —— 内部：文件定位 ——

  /// 在 [dir] 及其一级子目录中查找名为 [name] 的文件，返回绝对路径。
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

  /// 在 [dirPath] 中查找以 [baseName] 开头且以 `.onnx` 结尾的模型文件。
  ///
  /// 优先返回 int8 量化版本（体积小、速度快），其次原版。
  String? _findModelFile(String dirPath, String baseName) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return null;

    File? int8File;
    File? plainFile;
    for (final e in dir.listSync()) {
      if (e is File) {
        final name = p.basename(e.path);
        if (name.startsWith(baseName) && name.endsWith('.onnx')) {
          if (name.contains('int8')) {
            int8File = e;
          } else {
            plainFile = e;
          }
        }
      }
    }
    return (int8File ?? plainFile)?.path;
  }

  /// 返回目录下第一个 `.onnx` 文件路径（兜底用）。
  String? _findFirstOnnx(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return null;

    for (final e in dir.listSync()) {
      if (e is File && e.path.endsWith('.onnx')) {
        return e.path;
      }
    }
    return null;
  }

  // —— 内部：热词 ——

  /// 将热词列表写入临时文件（每行一个词），返回文件路径。
  ///
  /// sherpa-onnx 热词文件格式：每行一个词，可选 `词:权重`。
  Future<String?> _writeHotwordsFile(List<String> hotwords) async {
    if (hotwords.isEmpty) return null;
    final tempDir = await Directory.systemTemp.createTemp('nota_hotwords_');
    final path = p.join(tempDir.path, 'hotwords.txt');
    final f = File(path);
    await f.writeAsString(hotwords.join('\n'));
    return path;
  }

  /// 清理热词临时文件及其父目录。
  Future<void> _cleanupHotwordsFile() async {
    final path = _hotwordsFilePath;
    _hotwordsFilePath = null;
    if (path == null) return;

    final f = File(path);
    if (f.existsSync()) {
      try {
        await f.delete();
      } catch (_) {}
    }
    // 删除临时父目录（仅清理本引擎创建的）
    final parent = f.parent;
    if (parent.existsSync() &&
        parent.path.contains('nota_hotwords_')) {
      try {
        await parent.delete(recursive: true);
      } catch (_) {}
    }
  }

  /// 将 AsrConfig.language 映射为 Whisper 语言代码。
  ///
  /// - `zh` / `en` 等两位代码原样返回；
  /// - `multi` / null / 空串 返回空串（Whisper 自动检测）。
  String _whisperLanguage(String? language) {
    if (language == null || language.isEmpty || language == 'multi') {
      return '';
    }
    return language;
  }
}

/// 音频分片（内部用）。
class _AudioChunk {
  _AudioChunk({
    required this.samples,
    required this.startSec,
    required this.endSec,
  });

  final Float32List samples;
  final double startSec;
  final double endSec;
}
