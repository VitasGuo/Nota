import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:nota/models/transcript.dart';
import 'package:nota/services/asr/asr_engine.dart';

/// 云端 ASR 引擎（OpenAI Whisper 兼容 API）。
///
/// 通过 HTTP `multipart/form-data` 调用兼容 OpenAI `/audio/transcriptions`
/// 的云端服务，将音频文件转写为带时间戳的 [TranscriptSegment] 列表。
///
/// 配置依赖 [AsrConfig.baseUrl] / [AsrConfig.apiKey] / [AsrConfig.modelName]，
/// 初始化前需保证前两者非空，否则 [init] 抛出 [ArgumentError]。
///
/// - [AsrConfig.enableTimestamps] 为 true 时使用 `response_format=verbose_json`
///   以获取分段时间戳；为 false 时使用 `json` 仅返回整段文本。
/// - [AsrConfig.language] 非空时作为 language 字段传入，引导模型识别语言。
class CloudAsrEngine extends AsrEngine {
  CloudAsrEngine();

  /// 当前配置，[init] 成功后非空。
  AsrConfig? _config;

  /// Dio 实例，[init] 时创建，[dispose] 时关闭。
  Dio? _dio;

  /// 是否已初始化。
  bool _isReady = false;

  @override
  AsrEngineType get engineType => AsrEngineType.cloud;

  @override
  bool get isReady => _isReady;

  @override
  Future<void> init(AsrConfig config) async {
    if (config.baseUrl == null || config.baseUrl!.trim().isEmpty) {
      throw ArgumentError('config.baseUrl 不能为空');
    }
    if (config.apiKey == null || config.apiKey!.trim().isEmpty) {
      throw ArgumentError('config.apiKey 不能为空');
    }
    // 幂等：重复调用时先释放旧实例，再以新配置重建。
    _dio?.close();
    _config = config;
    _dio = Dio(
      BaseOptions(
        baseUrl: config.baseUrl!.replaceAll(RegExp(r'/+$'), ''),
        connectTimeout: const Duration(seconds: 30),
        receiveTimeout: const Duration(minutes: 10),
      ),
    );
    _isReady = true;
  }

  @override
  Future<List<TranscriptSegment>> transcribe(
    String audioPath, {
    void Function(double progress)? onProgress,
    void Function(TranscriptSegment segment)? onSegment,
  }) async {
    if (!_isReady || _config == null || _dio == null) {
      throw StateError('CloudAsrEngine 未初始化，请先调用 init()');
    }

    final config = _config!;
    final formData = await _buildFormData(audioPath, config);

    // 网络错误（DioException）自然向上传播，由调用方处理。
    final response = await _dio!.post(
      '/audio/transcriptions',
      data: formData,
      options: Options(
        headers: {'Authorization': 'Bearer ${config.apiKey}'},
      ),
      onSendProgress: (int sent, int total) {
        if (onProgress != null && total > 0) {
          onProgress(sent / total);
        }
      },
    );

    return _parseResponse(response.data, onSegment);
  }

  @override
  Future<void> dispose() async {
    _isReady = false;
    _config = null;
    _dio?.close();
    _dio = null;
  }

  /// 构建 multipart/form-data 请求体。
  Future<FormData> _buildFormData(String audioPath, AsrConfig config) async {
    final map = <String, dynamic>{
      'file': await MultipartFile.fromFile(audioPath),
      'model': config.modelName ?? 'whisper-1',
      'response_format': config.enableTimestamps ? 'verbose_json' : 'json',
    };
    if (config.language != null && config.language!.trim().isNotEmpty) {
      map['language'] = config.language;
    }
    return FormData.fromMap(map);
  }

  /// 解析响应为 [TranscriptSegment] 列表，并对每段调用 [onSegment]。
  ///
  /// - 响应包含 `segments` 数组时：逐段转换为 [TranscriptSegment]，
  ///   startTime/endTime 取自 start/end（秒），originalText 取自 text.trim()。
  /// - 响应仅包含 `text` 时：创建单个 [TranscriptSegment]（起止均为 0）。
  /// - 解析失败抛出 [FormatException]。
  List<TranscriptSegment> _parseResponse(
    dynamic data,
    void Function(TranscriptSegment segment)? onSegment,
  ) {
    Map<String, dynamic> json;
    if (data is Map) {
      json = data.cast<String, dynamic>();
    } else if (data is String) {
      try {
        json = jsonDecode(data) as Map<String, dynamic>;
      } catch (e) {
        throw FormatException('响应解析失败：非法 JSON（$e）');
      }
    } else {
      throw FormatException('响应解析失败：未知响应类型 ${data.runtimeType}');
    }

    final segmentsJson = json['segments'];
    if (segmentsJson is List && segmentsJson.isNotEmpty) {
      final segments = <TranscriptSegment>[];
      for (final seg in segmentsJson) {
        if (seg is! Map) continue;
        final start = (seg['start'] as num?)?.toDouble() ?? 0.0;
        final end = (seg['end'] as num?)?.toDouble() ?? 0.0;
        final text = (seg['text'] as String?)?.trim() ?? '';
        final segment = TranscriptSegment(
          sessionId: '',
          startTime: start,
          endTime: end,
          originalText: text,
        );
        segments.add(segment);
        onSegment?.call(segment);
      }
      if (segments.isNotEmpty) {
        return segments;
      }
    }

    // 仅 text 字段，或 segments 解析为空时回退为单段。
    final text = (json['text'] as String?)?.trim() ?? '';
    final segment = TranscriptSegment(
      sessionId: '',
      startTime: 0.0,
      endTime: 0.0,
      originalText: text,
    );
    onSegment?.call(segment);
    return [segment];
  }
}
