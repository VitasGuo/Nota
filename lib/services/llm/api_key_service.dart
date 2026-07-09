import 'package:shared_preferences/shared_preferences.dart';
import 'package:nota/services/llm/ai_providers.dart';

/// API Key 存储管理。
///
/// 以 `api_key_<provider>` 为 key 持久化到 SharedPreferences。
/// 通过 [getEffectiveApiKey] 获取实际生效的 Key，解析顺序：
/// 预设 Key → 用户保存的 Key → 默认兜底 Key。
class ApiKeyService {
  static const String _prefix = 'api_key_';

  /// 获取实际生效的 API Key（preset → saved → default）。
  /// 不需要 Key 的提供商（needsApiKey=false）返回空串。
  static Future<String> getEffectiveApiKey(AiProviderConfig provider) async {
    if (provider.hasPresetKey) return provider.presetApiKey!;
    if (!provider.needsApiKey) return '';
    final savedKey = await getApiKey(provider.type.name);
    if (savedKey != null && savedKey.isNotEmpty) return savedKey;
    return provider.defaultApiKey ?? '';
  }

  static Future<String?> getApiKey(String provider) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString('$_prefix$provider');
  }

  static Future<void> setApiKey(String provider, String apiKey) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('$_prefix$provider', apiKey);
  }

  static Future<void> removeApiKey(String provider) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('$_prefix$provider');
  }

  static Future<Map<String, String>> getAllApiKeys() async {
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith(_prefix));
    final result = <String, String>{};
    for (final key in keys) {
      final provider = key.substring(_prefix.length);
      final value = prefs.getString(key);
      if (value != null && value.isNotEmpty) {
        result[provider] = value;
      }
    }
    return result;
  }

  static Future<bool> hasApiKey(String provider) async {
    final key = await getApiKey(provider);
    return key != null && key.isNotEmpty;
  }
}
