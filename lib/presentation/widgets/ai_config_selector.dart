import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nota/services/llm/ai_providers.dart';
import 'package:nota/services/llm/api_key_service.dart';
import 'package:nota/services/llm/ai_router_service.dart';

final _apiKeyStatusProvider = FutureProvider.family<bool, String>((ref, provider) async {
  return await ApiKeyService.hasApiKey(provider);
});

/// AI 提供商 + 模型选择器。
///
/// 模型列表数据源（按优先级合并）：
/// 1. 提供商预设 [AiProviderConfig.availableModels]
/// 2. AI Router 页面测试连接时获取并持久化的模型列表（[AiRouterService.getFetchedModels]）
///
/// 两者合并后仍为空时（如未测试连接的本地/自定义提供商），
/// 显示文本输入框让用户手动输入模型名。
class AiConfigSelector extends ConsumerStatefulWidget {
  final String currentProvider;
  final String currentModel;
  final List<String> supportedProviderTypes;
  final ValueChanged<String>? onProviderChanged;
  final ValueChanged<String>? onModelChanged;
  final String? aiRouterRoute;

  const AiConfigSelector({
    super.key,
    required this.currentProvider,
    required this.currentModel,
    required this.supportedProviderTypes,
    this.onProviderChanged,
    this.onModelChanged,
    this.aiRouterRoute,
  });

  @override
  ConsumerState<AiConfigSelector> createState() => _AiConfigSelectorState();
}

class _AiConfigSelectorState extends ConsumerState<AiConfigSelector> {
  /// 从 SharedPreferences 异步加载的已获取模型列表。
  List<String> _fetchedModels = [];

  /// 手动输入模型名的文本控制器（仅当无可选模型时显示）。
  late final TextEditingController _manualModelController;

  @override
  void initState() {
    super.initState();
    _manualModelController = TextEditingController(text: widget.currentModel);
    _loadFetchedModels(widget.currentProvider);
  }

  @override
  void didUpdateWidget(AiConfigSelector oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 切换提供商时重新加载该提供商的已获取模型
    if (oldWidget.currentProvider != widget.currentProvider) {
      _loadFetchedModels(widget.currentProvider);
    }
    // 外部模型名变更时同步到手动输入框
    if (oldWidget.currentModel != widget.currentModel &&
        _manualModelController.text != widget.currentModel) {
      _manualModelController.text = widget.currentModel;
    }
  }

  @override
  void dispose() {
    _manualModelController.dispose();
    super.dispose();
  }

  Future<void> _loadFetchedModels(String providerName) async {
    final models = await AiRouterService.getFetchedModels(providerName);
    if (mounted) setState(() => _fetchedModels = models);
  }

  /// 合并预设模型 + 已获取模型（去重，保持顺序）。
  List<String> get _allModels {
    final provider = AiProviders.getByName(widget.currentProvider);
    final preset = provider?.availableModels ?? [];
    final combined = <String>[...preset];
    for (final m in _fetchedModels) {
      if (!combined.contains(m)) combined.add(m);
    }
    return combined;
  }

  @override
  Widget build(BuildContext context) {
    final supportedProviders = AiProviders.all
        .where((p) => widget.supportedProviderTypes.contains(p.type.name))
        .toList();

    final allModels = _allModels;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).dividerColor),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.smart_toy_outlined, size: 16, color: Theme.of(context).hintColor),
              const SizedBox(width: 8),
              Text(
                'AI模型',
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Theme.of(context).hintColor,
                ),
              ),
              const Spacer(),
              _buildApiKeyStatusChip(context, ref, widget.currentProvider),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: widget.currentProvider,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: '提供商',
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            ),
            items: supportedProviders.map((provider) {
              return DropdownMenuItem(
                value: provider.type.name,
                child: Text(
                  provider.displayName,
                  style: const TextStyle(fontSize: 14),
                ),
              );
            }).toList(),
            onChanged: (value) {
              if (value != null) {
                widget.onProviderChanged?.call(value);
              }
            },
          ),
          const SizedBox(height: 12),
          if (allModels.isNotEmpty)
            _buildModelDropdown(allModels)
          else
            _buildManualModelInput(),
        ],
      ),
    );
  }

  /// 有可选模型时显示下拉框。
  Widget _buildModelDropdown(List<String> models) {
    final current = widget.currentModel;
    final value = models.contains(current) ? current : models.first;
    return DropdownButtonFormField<String>(
      value: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: '模型',
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      items: models.map((model) {
        return DropdownMenuItem(
          value: model,
          child: Text(
            model,
            style: const TextStyle(fontSize: 14),
            overflow: TextOverflow.ellipsis,
          ),
        );
      }).toList(),
      onChanged: (value) {
        if (value != null) {
          widget.onModelChanged?.call(value);
        }
      },
    );
  }

  /// 无可选模型时显示文本输入框（手动输入模型名）。
  Widget _buildManualModelInput() {
    return TextField(
      controller: _manualModelController,
      decoration: InputDecoration(
        labelText: '模型名',
        hintText: '请先在 AI Router 中测试连接获取模型，或手动输入',
        isDense: true,
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
      onChanged: (value) {
        widget.onModelChanged?.call(value.trim());
      },
    );
  }

  Widget _buildApiKeyStatusChip(BuildContext context, WidgetRef ref, String providerName) {
    final providerConfig = AiProviders.getByName(providerName);

    // 无需 API Key（本地无鉴权模型）
    if (providerConfig?.needsApiKey == false) {
      return _chip(context, Icons.wifi, '无需Key', Colors.blue);
    }

    // 内置预设 Key
    if (providerConfig?.hasPresetKey == true) {
      return _chip(context, Icons.check_circle, '内置Key', Colors.green);
    }

    final hasKeyAsync = ref.watch(_apiKeyStatusProvider(providerName));
    return hasKeyAsync.when(
      data: (hasKey) => GestureDetector(
        onTap: widget.aiRouterRoute != null ? () => context.push(widget.aiRouterRoute!) : null,
        child: hasKey
            ? _chip(context, Icons.check_circle, 'Key已配置', Colors.green)
            : _chip(context, Icons.warning, '未配置Key', Colors.orange),
      ),
      loading: () => const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)),
      error: (_, __) => const SizedBox.shrink(),
    );
  }

  /// 统一的状态小标签。
  Widget _chip(BuildContext context, IconData icon, String label, MaterialColor color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color.shade700),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 11, color: color.shade700)),
        ],
      ),
    );
  }
}
