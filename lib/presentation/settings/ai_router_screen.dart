import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nota/services/llm/ai_providers.dart';
import 'package:nota/services/llm/api_key_service.dart';
import 'package:nota/services/llm/ai_router_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// AI Router 管理页面：集中管理各平台 API Key、测试连通性、拉取可用模型。
///
/// 对不同类型提供商展示不同 UI：
/// - 内置 Key（hasPresetKey）：提示开箱即用，无需配置。
/// - 无需 Key（needsApiKey=false）：提示无需 API Key。
/// - 本地/自定义（showUrlAndModel）：额外提供 URL、Model 输入框用于探活。
final _aiRouterProvider =
    StateNotifierProvider<_AiRouterNotifier, _AiRouterState>((ref) {
  return _AiRouterNotifier();
});

class _AiRouterState {
  final Map<String, String> apiKeys;
  final Map<String, bool> testResults;
  final Map<String, List<String>> fetchedModels;
  final Set<String> testingProviders;
  final bool isLoading;

  _AiRouterState({
    this.apiKeys = const {},
    this.testResults = const {},
    this.fetchedModels = const {},
    this.testingProviders = const {},
    this.isLoading = true,
  });

  _AiRouterState copyWith({
    Map<String, String>? apiKeys,
    Map<String, bool>? testResults,
    Map<String, List<String>>? fetchedModels,
    Set<String>? testingProviders,
    bool? isLoading,
  }) {
    return _AiRouterState(
      apiKeys: apiKeys ?? this.apiKeys,
      testResults: testResults ?? this.testResults,
      fetchedModels: fetchedModels ?? this.fetchedModels,
      testingProviders: testingProviders ?? this.testingProviders,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class _AiRouterNotifier extends StateNotifier<_AiRouterState> {
  _AiRouterNotifier() : super(_AiRouterState()) {
    _load();
  }

  Future<void> _load() async {
    final keys = await ApiKeyService.getAllApiKeys();
    state = state.copyWith(apiKeys: keys, isLoading: false);
  }

  Future<void> setKey(String provider, String key) async {
    await ApiKeyService.setApiKey(provider, key);
    state = state.copyWith(
      apiKeys: {...state.apiKeys, provider: key},
      testResults: {...state.testResults}..remove(provider),
      fetchedModels: {...state.fetchedModels}..remove(provider),
    );
  }

  Future<void> removeKey(String provider) async {
    await ApiKeyService.removeApiKey(provider);
    final newKeys = Map<String, String>.from(state.apiKeys);
    newKeys.remove(provider);
    final newResults = Map<String, bool>.from(state.testResults);
    newResults.remove(provider);
    final newModels = Map<String, List<String>>.from(state.fetchedModels);
    newModels.remove(provider);
    state = state.copyWith(
      apiKeys: newKeys,
      testResults: newResults,
      fetchedModels: newModels,
    );
  }

  Future<void> testProvider(
    String provider, {
    String? customUrl,
    String? apiKeyOverride,
  }) async {
    final testing = Set<String>.from(state.testingProviders);
    testing.add(provider);
    state = state.copyWith(testingProviders: testing);

    try {
      final success = await AiRouterService.testConnection(
        provider,
        customUrl: customUrl,
        apiKeyOverride: apiKeyOverride,
      );
      List<String> models = [];
      if (success) {
        models = await AiRouterService.fetchModels(
          provider,
          customUrl: customUrl,
          apiKeyOverride: apiKeyOverride,
        );
      }

      final newTesting = Set<String>.from(state.testingProviders);
      newTesting.remove(provider);
      state = state.copyWith(
        testingProviders: newTesting,
        testResults: {...state.testResults, provider: success},
        fetchedModels: {...state.fetchedModels, provider: models},
      );
      // 持久化获取到的模型列表，供 LLM 按功能配置页选择
      await AiRouterService.saveFetchedModels(provider, models);
    } catch (e) {
      final newTesting = Set<String>.from(state.testingProviders);
      newTesting.remove(provider);
      state = state.copyWith(
        testingProviders: newTesting,
        testResults: {...state.testResults, provider: false},
      );
    }
  }

  /// 一键测试所有已配置 Key 且有默认地址的云提供商。
  /// 本地/自定义提供商（无默认地址）需在卡片中手动填 URL 后单独测试。
  Future<void> testAll() async {
    for (final provider in AiProviders.all) {
      final hasKey = provider.hasPresetKey ||
          (state.apiKeys[provider.type.name]?.isNotEmpty ?? false);
      final hasUrl = provider.defaultBaseUrl.isNotEmpty;
      if (hasKey && hasUrl) {
        await testProvider(provider.type.name);
      }
    }
  }
}

class AiRouterScreen extends ConsumerWidget {
  const AiRouterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(_aiRouterProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('AI Router'),
        leading: IconButton(
          onPressed: () => context.pop(),
          icon: const Icon(Icons.arrow_back),
        ),
        actions: [
          TextButton.icon(
            onPressed: () => ref.read(_aiRouterProvider.notifier).testAll(),
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('一键测试'),
          ),
        ],
      ),
      body: state.isLoading
          ? const Center(child: CircularProgressIndicator())
          : ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: AiProviders.all.length,
              itemBuilder: (context, index) {
                final provider = AiProviders.all[index];
                return _ProviderCard(
                  provider: provider,
                  apiKey: state.apiKeys[provider.type.name] ?? '',
                  isTesting:
                      state.testingProviders.contains(provider.type.name),
                  testResult: state.testResults[provider.type.name],
                  fetchedModels:
                      state.fetchedModels[provider.type.name] ?? [],
                  onSetKey: (key) => ref
                      .read(_aiRouterProvider.notifier)
                      .setKey(provider.type.name, key),
                  onRemoveKey: () => ref
                      .read(_aiRouterProvider.notifier)
                      .removeKey(provider.type.name),
                  onTest: ({customUrl, apiKeyOverride}) => ref
                      .read(_aiRouterProvider.notifier)
                      .testProvider(provider.type.name,
                          customUrl: customUrl,
                          apiKeyOverride: apiKeyOverride),
                );
              },
            ),
    );
  }
}

typedef _TestCallback = Future<void> Function({
  String? customUrl,
  String? apiKeyOverride,
});

class _ProviderCard extends StatefulWidget {
  final AiProviderConfig provider;
  final String apiKey;
  final bool isTesting;
  final bool? testResult;
  final List<String> fetchedModels;
  final Future<void> Function(String) onSetKey;
  final VoidCallback onRemoveKey;
  final _TestCallback onTest;

  const _ProviderCard({
    required this.provider,
    required this.apiKey,
    required this.isTesting,
    this.testResult,
    required this.fetchedModels,
    required this.onSetKey,
    required this.onRemoveKey,
    required this.onTest,
  });

  @override
  State<_ProviderCard> createState() => _ProviderCardState();
}

class _ProviderCardState extends State<_ProviderCard> {
  late final TextEditingController _apiKeyController;
  late final TextEditingController _urlController;
  Timer? _apiKeySaveDebounce;

  @override
  void initState() {
    super.initState();
    _apiKeyController = TextEditingController(text: widget.apiKey);
    _urlController = TextEditingController(text: widget.provider.defaultBaseUrl);
    _loadSavedValues();
  }

  /// URL 持久化 key：按 provider type 独立存储，互不覆盖。
  String get _urlKey => 'ai_router_url_${widget.provider.type.name}';

  /// 从 SharedPreferences 加载已保存的 URL，覆盖默认值。
  Future<void> _loadSavedValues() async {
    final prefs = await SharedPreferences.getInstance();
    final savedUrl = prefs.getString(_urlKey);
    if (!mounted) return;
    if (savedUrl != null && savedUrl.isNotEmpty) {
      _urlController.text = savedUrl;
    }
  }

  Future<void> _saveUrl(String value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_urlKey, value);
  }

  @override
  void didUpdateWidget(_ProviderCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.apiKey != widget.apiKey &&
        _apiKeyController.text != widget.apiKey) {
      _apiKeyController.text = widget.apiKey;
    }
  }

  @override
  void dispose() {
    _apiKeySaveDebounce?.cancel();
    _apiKeyController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  bool get _hasKey =>
      widget.provider.hasPresetKey || widget.apiKey.isNotEmpty;

  @override
  Widget build(BuildContext context) {
    final p = widget.provider;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: ExpansionTile(
        leading: _buildStatusIcon(),
        title: Text(p.displayName),
        subtitle: Text(_buildSubtitle()),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (p.showUrlAndModel) ...[
                  _buildUrlField(),
                  const SizedBox(height: 8),
                ],
                _buildApiKeyArea(),
                const SizedBox(height: 8),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _canTest() && !widget.isTesting ? _doTest : null,
                    icon: widget.isTesting
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.network_check, size: 18),
                    label: Text(widget.isTesting ? '测试中...' : '测试连接并获取模型'),
                  ),
                ),
                if (widget.fetchedModels.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(
                    '可用模型 (${widget.fetchedModels.length})',
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: widget.fetchedModels
                        .map((model) => Chip(
                              label: Text(model,
                                  style: const TextStyle(fontSize: 12)),
                            ))
                        .toList(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _buildSubtitle() {
    if (!_hasKey && widget.provider.needsApiKey) return '未配置';
    if (widget.testResult == true) return '连接正常';
    if (widget.testResult == false) return '连接失败';
    return '待测试';
  }

  bool _canTest() {
    final p = widget.provider;
    // 需要地址：本地/自定义必须有 URL，云提供商用默认地址
    if (p.showUrlAndModel && _urlController.text.trim().isEmpty) return false;
    // 需要 Key 的提供商必须配置或内置 Key（以输入框当前值为准，未保存也可测试）
    if (p.needsApiKey &&
        !p.hasPresetKey &&
        _apiKeyController.text.trim().isEmpty) {
      return false;
    }
    return true;
  }

  Future<void> _doTest() async {
    final p = widget.provider;
    // 测试前自动保存 URL，确保测试使用已持久化值且退出后不丢失
    if (p.showUrlAndModel) {
      await _saveUrl(_urlController.text.trim());
    }
    if (p.needsApiKey &&
        !p.hasPresetKey &&
        _apiKeyController.text.trim().isNotEmpty) {
      await widget.onSetKey(_apiKeyController.text.trim());
    }
    await widget.onTest(
      customUrl: p.showUrlAndModel ? _urlController.text.trim() : null,
      apiKeyOverride: p.needsApiKey && !p.hasPresetKey
          ? _apiKeyController.text.trim()
          : null,
    );
  }

  Widget _buildUrlField() {
    return TextField(
      controller: _urlController,
      decoration: const InputDecoration(
        labelText: 'API 地址',
        hintText: '如 http://192.168.1.10:1234/v1',
        isDense: true,
        border: OutlineInputBorder(),
      ),
      onChanged: (value) => _saveUrl(value.trim()),
    );
  }

  Widget _buildApiKeyArea() {
    final p = widget.provider;

    // 无需 API Key
    if (!p.needsApiKey) {
      return _hintRow(Icons.wifi, '本地模型无需 API Key');
    }

    // 内置 Key
    if (p.hasPresetKey) {
      return _hintRow(Icons.check_circle, '已内置 API Key，无需配置');
    }

    // 用户输入 Key
    return TextField(
      controller: _apiKeyController,
      decoration: InputDecoration(
        labelText: 'API Key',
        hintText: 'sk-...',
        isDense: true,
        border: const OutlineInputBorder(),
        suffixIcon: widget.apiKey.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.clear),
                onPressed: () {
                  _apiKeyController.clear();
                  widget.onRemoveKey();
                },
              )
            : null,
      ),
      obscureText: true,
      onSubmitted: (value) {
        if (value.trim().isNotEmpty) {
          widget.onSetKey(value.trim());
        }
      },
      onChanged: (value) {
        final trimmed = value.trim();
        if (trimmed.isEmpty) return;
        _apiKeySaveDebounce?.cancel();
        _apiKeySaveDebounce = Timer(const Duration(milliseconds: 500), () {
          if (mounted) unawaited(widget.onSetKey(trimmed));
        });
      },
    );
  }

  Widget _hintRow(IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.primaryContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: const TextStyle(fontSize: 13))),
        ],
      ),
    );
  }

  Widget _buildStatusIcon() {
    if (widget.testResult == true) {
      return const Icon(Icons.check_circle, color: Colors.green);
    } else if (widget.testResult == false) {
      return const Icon(Icons.error, color: Colors.red);
    } else if (_hasKey || !widget.provider.needsApiKey) {
      return const Icon(Icons.circle, color: Colors.grey);
    } else {
      return const Icon(Icons.circle_outlined, color: Colors.grey);
    }
  }
}
