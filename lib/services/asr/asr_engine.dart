import 'package:nota/models/transcript.dart';

/// ASR 引擎类型。
///
/// - [local]：本地 sherpa-onnx 引擎（离线可用）
/// - [cloud]：云端 OpenAI Whisper 兼容 API
enum AsrEngineType { local, cloud }

/// ASR 引擎配置。
///
/// 同时承载本地与云端引擎所需的全部参数：
/// 本地引擎关注 [modelName] / [language] / [hotwords]；
/// 云端引擎关注 [baseUrl] / [apiKey] / [modelName]。
class AsrConfig {
  /// 引擎类型，决定其余字段的语义。
  final AsrEngineType engineType;

  /// 模型名：本地为模型 id（见 [AsrModelInfo.id]），云端为 API 模型名。
  final String? modelName;

  /// 语言代码（zh / en / multi），本地引擎用于选择对应语言模型。
  final String? language;

  /// 云端 API 地址（OpenAI Whisper 兼容），本地引擎忽略。
  final String? baseUrl;

  /// 云端 API Key，本地引擎忽略。
  final String? apiKey;

  /// 热词列表，传入支持 boosting 的本地模型（如 Paraformer）。
  final List<String>? hotwords;

  /// 是否返回时间戳。默认开启，关闭后引擎可返回纯文本以加速。
  final bool enableTimestamps;

  const AsrConfig({
    required this.engineType,
    this.modelName,
    this.language,
    this.baseUrl,
    this.apiKey,
    this.hotwords,
    this.enableTimestamps = true,
  });

  /// 创建一份副本，仅覆盖传入的字段。
  AsrConfig copyWith({
    AsrEngineType? engineType,
    String? modelName,
    String? language,
    String? baseUrl,
    String? apiKey,
    List<String>? hotwords,
    bool? enableTimestamps,
  }) {
    return AsrConfig(
      engineType: engineType ?? this.engineType,
      modelName: modelName ?? this.modelName,
      language: language ?? this.language,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      hotwords: hotwords ?? this.hotwords,
      enableTimestamps: enableTimestamps ?? this.enableTimestamps,
    );
  }
}

/// ASR 引擎抽象接口。
///
/// 统一本地（sherpa-onnx）与云端（OpenAI Whisper 兼容）转写调用契约。
/// 具体实现见 LocalAsrEngine（Task 8）与 CloudAsrEngine（Task 9）。
abstract class AsrEngine {
  /// 引擎类型。
  AsrEngineType get engineType;

  /// 是否已初始化（模型已加载 / API 已配置）。
  bool get isReady;

  /// 初始化引擎。
  ///
  /// 本地引擎加载模型文件，云端引擎校验 baseUrl + apiKey。
  /// 重复调用应安全（幂等）。
  Future<void> init(AsrConfig config);

  /// 转写音频文件。
  ///
  /// - [audioPath] 音频文件路径（WAV 16kHz 单声道为标准输入）。
  /// - [onProgress] 进度回调（0.0-1.0），长音频分段处理时触发。
  /// - [onSegment] 实时回调，每转写完一段就回调一次，便于 UI 流式展示。
  ///
  /// 返回完整转写结果列表，按时间顺序排列。
  Future<List<TranscriptSegment>> transcribe(
    String audioPath, {
    void Function(double progress)? onProgress,
    void Function(TranscriptSegment segment)? onSegment,
  });

  /// 释放资源（模型句柄、网络连接等）。
  Future<void> dispose();
}
