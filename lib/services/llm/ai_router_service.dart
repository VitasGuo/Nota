import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:nota/services/llm/ai_providers.dart';
import 'package:nota/services/llm/api_key_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 连接测试与模型获取服务。
///
/// 面向 OpenAI 兼容接口（`/models`、`/chat/completions`）。
/// 对不支持 `/models` 的接口会回退到 `/chat/completions` 探活。
class AiRouterService {
  /// SharedPreferences key 前缀（持久化已获取的模型列表）。
  static const String _modelsKeyPrefix = 'ai_router_models_';

  /// 拉取提供商可用模型列表。
  ///
  /// [customUrl] 覆盖默认地址（本地/自定义提供商需传入）。
  /// [apiKeyOverride] 覆盖 [ApiKeyService.getEffectiveApiKey] 解析出的 Key。
  static Future<List<String>> fetchModels(
    String providerName, {
    String? customUrl,
    String? apiKeyOverride,
  }) async {
    final provider = AiProviders.getByName(providerName);
    if (provider == null) return [];

    final baseUrl = _resolveBaseUrl(provider, customUrl);
    if (baseUrl.isEmpty) return provider.availableModels;

    final apiKey = apiKeyOverride ?? await ApiKeyService.getEffectiveApiKey(provider);

    try {
      final dio = _buildDio(baseUrl, apiKey);
      final response = await dio.get('/models');
      if (response.statusCode == 200) {
        final data = response.data;
        if (data is Map && data.containsKey('data')) {
          final models = data['data'] as List;
          final result = models
              .map((m) => (m['id'] as String?) ?? (m['name'] as String?) ?? '')
              .where((s) => s.isNotEmpty)
              .toList();
          if (result.isNotEmpty) return result;
        }
      }
    } catch (_) {
      // 拉取失败时回退到预设模型列表
    }

    return provider.availableModels;
  }

  /// 测试与提供商的连通性。
  ///
  /// 先尝试 `GET /models`，失败再尝试 `POST /chat/completions`（max_tokens=5）。
  /// 返回 `true` 仅表示接口可达且鉴权通过。
  static Future<bool> testConnection(
    String providerName, {
    String? customUrl,
    String? apiKeyOverride,
  }) async {
    final provider = AiProviders.getByName(providerName);
    if (provider == null) return false;

    final baseUrl = _resolveBaseUrl(provider, customUrl);
    if (baseUrl.isEmpty) return false;

    final apiKey = apiKeyOverride ?? await ApiKeyService.getEffectiveApiKey(provider);
    final dio = _buildDio(baseUrl, apiKey);

    try {
      final response = await dio.get('/models');
      if (response.statusCode == 200) return true;
    } catch (_) {
      // 回退到 chat/completions 探活
    }

    try {
      final response = await dio.post(
        '/chat/completions',
        data: {
          'messages': [
            {'role': 'user', 'content': 'hi'}
          ],
          'max_tokens': 5,
        },
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// 持久化已获取的模型列表到 SharedPreferences。
  static Future<void> saveFetchedModels(
      String providerName, List<String> models) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_modelsKeyPrefix$providerName', jsonEncode(models));
  }

  /// 读取已持久化的模型列表（测试连接时获取并保存的）。
  ///
  /// 用于 LLM 按功能配置中选择 LM Studio / 自定义接口的模型。
  static Future<List<String>> getFetchedModels(String providerName) async {
    final prefs = await SharedPreferences.getInstance();
    final json = prefs.getString('$_modelsKeyPrefix$providerName');
    if (json == null) return [];
    try {
      final list = jsonDecode(json) as List;
      return list.cast<String>();
    } catch (_) {
      return [];
    }
  }

  /// 解析实际生效的 baseUrl：优先 customUrl，其次默认地址。
  static String _resolveBaseUrl(AiProviderConfig provider, String? customUrl) {
    if (customUrl != null && customUrl.isNotEmpty) return customUrl;
    return provider.defaultBaseUrl;
  }

  static Dio _buildDio(String baseUrl, String apiKey) {
    final headers = <String, String>{
      'Content-Type': 'application/json',
    };
    if (apiKey.isNotEmpty) {
      headers['Authorization'] = 'Bearer $apiKey';
    }
    return Dio(BaseOptions(
      baseUrl: baseUrl,
      headers: headers,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
    ));
  }
}
