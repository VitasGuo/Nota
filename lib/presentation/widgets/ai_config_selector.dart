import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:nota/services/llm/ai_providers.dart';
import 'package:nota/services/llm/api_key_service.dart';

final _apiKeyStatusProvider = FutureProvider.family<bool, String>((ref, provider) async {
  return await ApiKeyService.hasApiKey(provider);
});

class AiConfigSelector extends ConsumerWidget {
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
  Widget build(BuildContext context, WidgetRef ref) {
    final supportedProviders = AiProviders.all
        .where((p) => supportedProviderTypes.contains(p.type.name))
        .toList();

    final selectedProvider = AiProviders.getByName(currentProvider);
    final availableModels = selectedProvider?.availableModels ?? [];

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
              _buildApiKeyStatusChip(context, ref, currentProvider),
            ],
          ),
          const SizedBox(height: 12),
          DropdownButtonFormField<String>(
            value: currentProvider,
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
                onProviderChanged?.call(value);
              }
            },
          ),
          if (availableModels.isNotEmpty) ...[
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: availableModels.contains(currentModel) ? currentModel : availableModels.first,
              isExpanded: true,
              decoration: InputDecoration(
                labelText: '模型',
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
                contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              ),
              items: availableModels.map((model) {
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
                  onModelChanged?.call(value);
                }
              },
            ),
          ],
        ],
      ),
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
        onTap: aiRouterRoute != null ? () => context.push(aiRouterRoute!) : null,
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
