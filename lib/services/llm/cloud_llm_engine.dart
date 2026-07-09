import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:nota/services/llm/ai_providers.dart';
import 'package:nota/services/llm/api_key_service.dart';
import 'package:nota/services/llm/llm_engine.dart';

/// 云端 LLM 引擎。
///
/// 基于 OpenAI 兼容的 /chat/completions 接口，通过 SSE 流式接收生成内容。
/// 提供商与默认地址来自 [AiProviders] 内置配置，也可用 [LlmConfig.customUrl]
/// 覆盖；API Key 通过 [ApiKeyService.getEffectiveApiKey] 按
/// preset → saved → default 顺序解析。
class CloudLlmEngine extends LlmEngine {
  CloudLlmEngine();

  final Dio _dio = Dio();

  /// 当前配置（init 后非空）。
  LlmConfig? _config;

  /// 解析出的提供商配置（providerName 为空或未命中内置列表时为 null）。
  AiProviderConfig? _provider;

  /// 生效的 baseUrl（customUrl 优先，否则用提供商默认地址）。
  String _baseUrl = '';

  bool _isReady = false;

  @override
  LlmEngineType get engineType => LlmEngineType.cloud;

  @override
  bool get isReady => _isReady;

  @override
  Future<void> init(LlmConfig config) async {
    _config = config;
    // 通过提供商名（AiProviderType.name 字符串）查找内置配置
    final name = config.providerName;
    _provider = (name != null && name.isNotEmpty)
        ? AiProviders.getByName(name)
        : null;
    // baseUrl：customUrl 优先，否则回退提供商默认地址
    _baseUrl = (config.customUrl != null && config.customUrl!.isNotEmpty)
        ? config.customUrl!
        : (_provider?.defaultBaseUrl ?? '');
    _isReady = true;
  }

  @override
  Future<void> generate({
    required String systemPrompt,
    required String userPrompt,
    void Function(String token)? onToken,
    required void Function(String fullText) onComplete,
    required void Function(String error) onError,
  }) async {
    final config = _config;
    if (!_isReady || config == null) {
      onError('云端引擎未初始化');
      return;
    }

    try {
      // —— 解析模型名：config.modelName 优先，否则用提供商默认 ——
      final modelName =
          (config.modelName != null && config.modelName!.isNotEmpty)
              ? config.modelName!
              : (_provider?.defaultModel ?? '');
      if (modelName.isEmpty) {
        onError('未配置模型名');
        return;
      }

      // —— 解析 API Key（needsApiKey=false 的提供商返回空串）——
      final apiKey = _provider != null
          ? await ApiKeyService.getEffectiveApiKey(_provider!)
          : '';

      // —— 组装请求 URL（去除尾部斜杠避免双斜杠）——
      final base = _baseUrl.endsWith('/')
          ? _baseUrl.substring(0, _baseUrl.length - 1)
          : _baseUrl;
      final url = '$base/chat/completions';

      // —— 请求头 ——
      final headers = <String, String>{
        'Content-Type': 'application/json',
      };
      // needsApiKey=false（如本地无鉴权模型）不设 Authorization
      final needsAuth = _provider?.needsApiKey ?? true;
      if (needsAuth && apiKey.isNotEmpty) {
        headers['Authorization'] = 'Bearer $apiKey';
      }

      // —— 请求体（OpenAI 兼容 /chat/completions）——
      final body = <String, dynamic>{
        'model': modelName,
        'messages': [
          {'role': 'system', 'content': systemPrompt},
          {'role': 'user', 'content': userPrompt},
        ],
        'stream': true,
        'max_tokens': config.maxTokens,
        'temperature': config.temperature,
      };

      // 以流式响应接收 SSE
      final response = await _dio.post<ResponseBody>(
        url,
        data: body,
        options: Options(
          headers: headers,
          responseType: ResponseType.stream,
        ),
      );

      final responseBody = response.data;
      if (responseBody == null) {
        onError('响应体为空');
        return;
      }

      // 用 utf8.decoder 作为流转换器：自动缓冲跨 chunk 的不完整多字节序列，
      // 从根源上避免 UTF-8 字符被截断产生的乱码。
      // stream 为 Stream<Uint8List>，需先 cast 为 Stream<List<int>> 以匹配
      // utf8.decoder 的 StreamTransformer<List<int>, String> 类型。
      final stream =
          responseBody.stream.cast<List<int>>().transform(utf8.decoder);

      final buffer = StringBuffer();
      // leftover 缓冲不完整的行（按 \n 分割后末尾可能不足一行）
      var leftover = '';

      await for (final decoded in stream) {
        leftover += decoded;
        final lines = leftover.split('\n');
        // 最后一行可能不完整，留给下一个 chunk 拼接
        leftover = lines.removeLast();

        for (final rawLine in lines) {
          final line = rawLine.trim();
          if (line.isEmpty) continue;
          if (!line.startsWith('data:')) continue;
          // 提取 data: 之后的内容（兼容 "data:" 与 "data: " 两种写法）
          final data = line.substring(5).trim();
          if (data.isEmpty) continue;
          if (data == '[DONE]') {
            onComplete(buffer.toString());
            return;
          }
          try {
            final json = jsonDecode(data) as Map<String, dynamic>;
            final choices = json['choices'] as List<dynamic>?;
            if (choices == null || choices.isEmpty) continue;
            final choice = choices[0] as Map<String, dynamic>;
            final delta = choice['delta'] as Map<String, dynamic>?;
            final content = delta?['content'] as String?;
            if (content != null && content.isNotEmpty) {
              buffer.write(content);
              onToken?.call(content);
            }
          } catch (_) {
            // 单行 JSON 解析失败不中断整个流，跳过继续
          }
        }
      }

      // 流正常结束但未显式收到 [DONE]，按完成处理
      onComplete(buffer.toString());
    } catch (e) {
      onError(e.toString());
    }
  }

  @override
  Future<void> dispose() async {
    _dio.close();
    _isReady = false;
  }
}
