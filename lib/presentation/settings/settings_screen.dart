import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nota/core/theme.dart';
import 'package:nota/main.dart';
import 'package:nota/models/recording_session.dart';
import 'package:nota/presentation/data/data_management_screen.dart';
import 'package:nota/presentation/hotwords/hotword_screen.dart';
import 'package:nota/presentation/settings/ai_router_screen.dart';
import 'package:nota/presentation/speakers/speaker_screen.dart';
import 'package:nota/presentation/widgets/ai_config_selector.dart';
import 'package:nota/services/asr/asr_engine.dart';
import 'package:nota/services/asr/asr_model_info.dart';
import 'package:nota/services/asr/asr_model_manager.dart';
import 'package:nota/services/llm/ai_providers.dart';
import 'package:nota/services/llm/llm_engine.dart';
import 'package:nota/services/llm/llm_task_router.dart';

/// 设置界面 SettingsScreen（Task 22 改造）。
///
/// 分区组织：ASR 引擎 / LLM 按功能配置 / API Key 管理 / 录音 / 管理入口 /
/// 外观 / 关于。LLM 按功能（翻译/纪要/笔记/纠错）各自独立配置引擎+提供商+模型，
/// 配置通过 [LlmTaskRouter] 持久化；ASR 配置持久化到 SharedPreferences
/// （key: `asr_config`）；默认录音源持久化到 `recording_source`。
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  static const String _kAsrConfig = 'asr_config';
  static const String _kRecordingSource = 'recording_source';

  // —— 加载状态 / 版本 ——
  bool _loaded = false;
  String _version = '';

  // —— ASR 配置 ——
  AsrConfig? _asrConfig;
  List<AsrModelInfo> _downloadedModels = [];
  String? _downloadingModelId;
  double _downloadProgress = 0;
  final TextEditingController _asrBaseUrlController = TextEditingController();
  final TextEditingController _asrApiKeyController = TextEditingController();
  final TextEditingController _asrModelNameController = TextEditingController();

  // —— GGUF ASR 模型（Qwen3-ASR via llama.cpp mtmd）——
  List<GgufAsrModelInfo> _downloadedGgufModels = [];
  String? _downloadingGgufModelId;
  double _ggufDownloadProgress = 0;
  String? _ggufDownloadStage;

  // —— VAD 模型 ——
  bool _vadReady = false;

  // —— LLM 按功能配置 ——
  final Map<LlmTaskType, LlmConfig> _llmConfigs = {};

  // —— 录音 ——
  RecordingSource _recordingSource = RecordingSource.mic;

  /// LLM 任务可用的云端提供商类型（排除纯文生图的 tongyi / jimeng）。
  late final List<String> _textProviderTypes = AiProviders.all
      .where((p) => p.type.name != 'tongyi' && p.type.name != 'jimeng')
      .map((p) => p.type.name)
      .toList();

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  @override
  void dispose() {
    _asrBaseUrlController.dispose();
    _asrApiKeyController.dispose();
    _asrModelNameController.dispose();
    super.dispose();
  }

  Future<void> _loadAll() async {
    final info = await PackageInfo.fromPlatform();
    final prefs = await SharedPreferences.getInstance();

    // ASR 配置
    final asrJson = prefs.getString(_kAsrConfig);
    final asrConfig = asrJson != null
        ? _asrConfigFromJson(asrJson)
        : const AsrConfig(
            engineType: AsrEngineType.local,
            modelName: 'paraformer-zh',
            language: 'zh',
          );
    final downloaded = await AsrModelManager().getDownloadedModels();
    final downloadedGguf = await AsrModelManager().getDownloadedGgufModels();
    final vadReady = await AsrModelManager().isVadModelDownloaded();

    // LLM 按功能配置
    final router = LlmTaskRouter();
    final llmConfigs = <LlmTaskType, LlmConfig>{};
    for (final t in LlmTaskType.values) {
      llmConfigs[t] = await router.getConfig(t);
    }

    // 录音源
    final srcName = prefs.getString(_kRecordingSource);
    final recordingSource = RecordingSource.values.asNameMap()[srcName] ??
        RecordingSource.mic;

    if (mounted) {
      setState(() {
        _version = info.version;
        _asrConfig = asrConfig;
        _asrBaseUrlController.text = asrConfig.baseUrl ?? '';
        _asrApiKeyController.text = asrConfig.apiKey ?? '';
        _asrModelNameController.text = asrConfig.modelName ?? '';
        _downloadedModels = downloaded;
        _downloadedGgufModels = downloadedGguf;
        _vadReady = vadReady;
        _llmConfigs.addAll(llmConfigs);
        _recordingSource = recordingSource;
        _loaded = true;
      });
    }
  }

  // —— 持久化辅助 ——

  /// AsrConfig 无内置 toJson（不可改 services/），在此内联序列化。
  /// hotwords 为运行时注入，不持久化。
  Map<String, dynamic> _asrConfigToJson(AsrConfig c) => {
        'engineType': c.engineType.name,
        'modelName': c.modelName,
        'language': c.language,
        'baseUrl': c.baseUrl,
        'apiKey': c.apiKey,
        'enableTimestamps': c.enableTimestamps,
      };

  AsrConfig _asrConfigFromJson(String s) {
    final m = jsonDecode(s) as Map<String, dynamic>;
    final engineName = m['engineType'] as String? ?? 'local';
    final engine = AsrEngineType.values.asNameMap()[engineName] ??
        AsrEngineType.local;
    return AsrConfig(
      engineType: engine,
      modelName: m['modelName'] as String?,
      language: m['language'] as String?,
      baseUrl: m['baseUrl'] as String?,
      apiKey: m['apiKey'] as String?,
      enableTimestamps: (m['enableTimestamps'] as bool?) ?? true,
    );
  }

  Future<void> _saveAsrConfig(AsrConfig c) async {
    _asrConfig = c;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kAsrConfig, jsonEncode(_asrConfigToJson(c)));
    if (mounted) setState(() {});
  }

  Future<void> _updateLlmConfig(LlmTaskType task, LlmConfig config) async {
    _llmConfigs[task] = config;
    if (mounted) setState(() {});
    await LlmTaskRouter().setConfig(task, config);
  }

  Future<void> _setRecordingSource(RecordingSource src) async {
    _recordingSource = src;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kRecordingSource, src.name);
    if (mounted) setState(() {});
  }

  void _showSaved() {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
      );
    }
  }

  void _pushScreen(Widget screen) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(builder: (_) => screen),
    );
  }

  // —— 构建 ——

  @override
  Widget build(BuildContext context) {
    final currentTheme = ref.watch(themeModeProvider);

    return Scaffold(
      appBar: AppBar(title: const Text('设置')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildSectionTitle('ASR 引擎'),
                _buildAsrSection(),
                const SizedBox(height: 24),
                _buildSectionTitle('Qwen3-ASR GGUF 模型（高质量实时转写）'),
                _buildGgufAsrSection(),
                const SizedBox(height: 24),
                _buildSectionTitle('LLM 按功能配置'),
                _buildLlmSection(),
                const SizedBox(height: 24),
                _buildSectionTitle('API Key 管理'),
                _buildAiRouterEntry(),
                const SizedBox(height: 24),
                _buildSectionTitle('录音'),
                _buildRecordingSection(),
                const SizedBox(height: 24),
                _buildSectionTitle('管理入口'),
                _buildManagementEntries(),
                const SizedBox(height: 24),
                _buildSectionTitle('外观'),
                _buildThemeSelector(currentTheme),
                const SizedBox(height: 8),
                _buildAccentColorPicker(),
                const SizedBox(height: 24),
                _buildSectionTitle('关于'),
                _buildAboutButton(),
              ],
            ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          color: AppTheme.textPrimary,
        ),
      ),
    );
  }

  Widget _sectionCard(List<Widget> children) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  // —— 1. ASR 引擎配置 ——

  Widget _buildAsrSection() {
    final config = _asrConfig!;
    return _sectionCard([
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        child: SegmentedButton<AsrEngineType>(
          segments: const [
            ButtonSegment(value: AsrEngineType.local, label: Text('本地')),
            ButtonSegment(value: AsrEngineType.cloud, label: Text('云端')),
          ],
          selected: {config.engineType},
          onSelectionChanged: (s) =>
              _saveAsrConfig(config.copyWith(engineType: s.first)),
        ),
      ),
      // VAD 状态（所有实时 ASR 引擎均依赖 VAD 分段，已内置到 APK）
      _buildVadStatusRow(),
      const Divider(height: 1),
      if (config.engineType == AsrEngineType.local) ...[
        _buildLocalAsrModels(),
        if (AsrModels.available
            .any((m) => !_downloadedModels.any((d) => d.id == m.id)))
          _buildDownloadList(),
      ] else
        _buildCloudAsrFields(),
      const Divider(height: 1),
      _buildLanguageRow(config),
    ]);
  }

  /// VAD 模型状态行。
  ///
  /// VAD 模型（silero_vad.onnx ~2.2MB）已内置到 APK assets，首次使用时
  /// 自动释放到应用文档目录。状态行显示就绪状态，让用户知道 VAD 不需要
  /// 额外下载。
  Widget _buildVadStatusRow() {
    return ListTile(
      dense: true,
      leading: Icon(
        _vadReady ? Icons.check_circle : Icons.warning_amber_rounded,
        color: _vadReady ? Colors.green : Colors.orange,
        size: 20,
      ),
      title: const Text('VAD 语音活动检测', style: TextStyle(fontSize: 13)),
      subtitle: Text(
        _vadReady
            ? '已就绪（内置 silero_vad.onnx ~2MB）'
            : '未就绪，请重新安装应用',
        style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
      ),
    );
  }

  Widget _buildLocalAsrModels() {
    if (_downloadedModels.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Text(
          '暂无已下载模型，请在下方下载',
          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
        ),
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '已下载模型（点选激活）',
              style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
            ),
          ),
        ),
        ..._downloadedModels.map((m) {
              final active = _asrConfig?.modelName == m.id;
              return ListTile(
                leading: Icon(
                  active ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: active ? AppTheme.accentColor : AppTheme.textSecondary,
                  size: 22,
                ),
                title: Text(m.displayName),
                subtitle: Text(
                  '${m.sizeMb.toStringAsFixed(0)}MB · ${_langLabel(m.language)}'
                  '${m.supportsHotwords ? ' · 支持热词' : ''}',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
                trailing: IconButton(
                  icon: const Icon(Icons.delete_outline, size: 20),
                  tooltip: '删除模型',
                  onPressed: () => _deleteModel(m.id),
                ),
                onTap: () =>
                    _saveAsrConfig(_asrConfig!.copyWith(modelName: m.id)),
              );
            }),
      ],
    );
  }

  Widget _buildCloudAsrFields() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
      child: Column(
        children: [
          TextField(
            controller: _asrBaseUrlController,
            decoration: InputDecoration(
              labelText: 'API 地址',
              hintText: '如 https://api.openai.com/v1',
              isDense: true,
              suffixIcon: IconButton(
                icon: const Icon(Icons.save, size: 18),
                onPressed: () {
                  _saveAsrConfig(_asrConfig!.copyWith(
                    baseUrl: _asrBaseUrlController.text.trim(),
                  ));
                  _showSaved();
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _asrApiKeyController,
            obscureText: true,
            decoration: InputDecoration(
              labelText: 'API Key',
              hintText: 'sk-...',
              isDense: true,
              suffixIcon: IconButton(
                icon: const Icon(Icons.save, size: 18),
                onPressed: () {
                  _saveAsrConfig(_asrConfig!.copyWith(
                    apiKey: _asrApiKeyController.text,
                  ));
                  _showSaved();
                },
              ),
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _asrModelNameController,
            decoration: InputDecoration(
              labelText: '模型名',
              hintText: '如 whisper-1',
              isDense: true,
              suffixIcon: IconButton(
                icon: const Icon(Icons.save, size: 18),
                onPressed: () {
                  _saveAsrConfig(_asrConfig!.copyWith(
                    modelName: _asrModelNameController.text.trim(),
                  ));
                  _showSaved();
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLanguageRow(AsrConfig config) {
    final lang = (config.language == null || config.language!.isEmpty)
        ? 'multi'
        : config.language!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(Icons.language, size: 18, color: AppTheme.textSecondary),
          const SizedBox(width: 8),
          Text('识别语言',
              style: TextStyle(fontSize: 14, color: AppTheme.textPrimary)),
          const Spacer(),
          DropdownButton<String>(
            value: lang,
            underline: const SizedBox(),
            items: const [
              DropdownMenuItem(value: 'zh', child: Text('中文')),
              DropdownMenuItem(value: 'en', child: Text('英文')),
              DropdownMenuItem(value: 'multi', child: Text('多语言')),
            ],
            onChanged: (v) {
              if (v != null) {
                _saveAsrConfig(config.copyWith(language: v));
              }
            },
          ),
        ],
      ),
    );
  }

  String _langLabel(String code) {
    switch (code) {
      case 'zh':
        return '中文';
      case 'en':
        return '英文';
      default:
        return '多语言';
    }
  }

  Future<void> _downloadModel(String id) async {
    setState(() {
      _downloadingModelId = id;
      _downloadProgress = 0;
    });
    try {
      await AsrModelManager().downloadModel(id, onProgress: (p) {
        if (mounted) setState(() => _downloadProgress = p);
      });
      final downloaded = await AsrModelManager().getDownloadedModels();
      if (mounted) {
        setState(() {
          _downloadedModels = downloaded;
          _downloadingModelId = null;
        });
        // 首次下载自动激活
        final active = _asrConfig?.modelName;
        if (active == null || active.isEmpty) {
          await _saveAsrConfig(_asrConfig!.copyWith(modelName: id));
        }
        _showSaved();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('下载失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() => _downloadingModelId = null);
      }
    }
  }

  Future<void> _deleteModel(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型'),
        content: Text('确认删除模型 $id？此操作不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await AsrModelManager().deleteModel(id);
      final downloaded = await AsrModelManager().getDownloadedModels();
      if (mounted) {
        setState(() => _downloadedModels = downloaded);
        // 若删除的是当前激活模型，清空引用
        if (_asrConfig?.modelName == id) {
          await _saveAsrConfig(_asrConfig!.copyWith(modelName: null));
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('删除失败: $e'), backgroundColor: Colors.red),
        );
      }
    }
  }

  Widget _buildDownloadList() {
    final pending = AsrModels.available
        .where((m) => !_downloadedModels.any((d) => d.id == m.id))
        .toList();
    if (pending.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
        child: Text(
          '所有预置模型均已下载',
          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
        ),
      );
    }
    return ExpansionTile(
      tilePadding: const EdgeInsets.symmetric(horizontal: 16),
      title: Text('下载模型 (${pending.length})',
          style: const TextStyle(fontSize: 14)),
      leading: Icon(Icons.download, size: 20, color: AppTheme.accentColor),
      children: pending.map((m) {
        final isDownloading = _downloadingModelId == m.id;
        return ListTile(
          dense: true,
          title: Text(m.displayName, style: const TextStyle(fontSize: 13)),
          subtitle: Text(
            '${m.sizeMb.toStringAsFixed(0)}MB · ${_langLabel(m.language)}',
            style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
          ),
          trailing: isDownloading
              ? SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    value: _downloadProgress > 0 ? _downloadProgress : null,
                    strokeWidth: 2,
                  ),
                )
              : TextButton(
                  onPressed: () => _downloadModel(m.id),
                  child: const Text('下载'),
                ),
        );
      }).toList(),
    );
  }

  // —— 1b. Qwen3-ASR GGUF 模型管理（基于 llama.cpp mtmd）——

  /// GGUF ASR 模型管理区域。
  ///
  /// Qwen3-ASR 基于 llama.cpp mtmd 接口，质量最优但体积较大（1-2.4GB）。
  /// 从 hf-mirror.com 下载（国内网络友好），也支持本地导入。
  /// 下载后录音界面优先使用此引擎（优先级高于 sherpa-onnx Paraformer）。
  Widget _buildGgufAsrSection() {
    final pending = GgufAsrModels.available
        .where((m) => !_downloadedGgufModels.any((d) => d.id == m.id))
        .toList();

    return _sectionCard([
      // 说明
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.info_outline, size: 14, color: AppTheme.textSecondary),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                'Qwen3-ASR 基于 llama.cpp mtmd 接口，质量最优但体积较大。'
                '下载后录音将优先使用此引擎。从 hf-mirror.com 下载，国内网络友好。',
                style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
              ),
            ),
          ],
        ),
      ),
      // 已下载模型
      ..._downloadedGgufModels.map((m) => ListTile(
            dense: true,
            leading:
                Icon(Icons.check_circle, color: Colors.green.shade600, size: 20),
            title: Text(m.displayName, style: const TextStyle(fontSize: 13)),
            subtitle: Text(
              '${m.totalSizeMb.toStringAsFixed(0)}MB · ${m.language}',
              style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: '删除模型',
              onPressed: () => _deleteGgufModel(m.id),
            ),
          )),
      // 下载/导入列表
      ...pending.map((m) {
        final isDownloading = _downloadingGgufModelId == m.id;
        return ListTile(
          dense: true,
          title: Text(m.displayName, style: const TextStyle(fontSize: 13)),
          subtitle: isDownloading && _ggufDownloadStage != null
              ? Text(
                  _ggufDownloadStage == 'main'
                      ? '正在下载主模型...'
                      : '正在下载音频投影器...',
                  style: TextStyle(fontSize: 11, color: AppTheme.accentColor),
                )
              : Text(
                  '${m.totalSizeMb.toStringAsFixed(0)}MB · ${m.language}',
                  style:
                      TextStyle(fontSize: 11, color: AppTheme.textSecondary),
                ),
          trailing: isDownloading
              ? SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    value:
                        _ggufDownloadProgress > 0 ? _ggufDownloadProgress : null,
                    strokeWidth: 2,
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => _downloadGgufModel(m.id),
                      child: const Text('下载'),
                    ),
                    TextButton(
                      onPressed: () => _importGgufModel(m.id),
                      child: const Text('导入'),
                    ),
                  ],
                ),
        );
      }),
      if (_downloadedGgufModels.isEmpty && pending.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(
            '暂无可用 GGUF ASR 模型',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          ),
        ),
    ]);
  }

  Future<void> _downloadGgufModel(String id) async {
    setState(() {
      _downloadingGgufModelId = id;
      _ggufDownloadProgress = 0;
      _ggufDownloadStage = null;
    });
    try {
      await AsrModelManager().downloadGgufModel(
        id,
        onProgress: (p) {
          if (mounted) setState(() => _ggufDownloadProgress = p);
        },
        onStage: (stage) {
          if (mounted) setState(() => _ggufDownloadStage = stage);
        },
      );
      final downloaded = await AsrModelManager().getDownloadedGgufModels();
      if (mounted) {
        setState(() {
          _downloadedGgufModels = downloaded;
          _downloadingGgufModelId = null;
          _ggufDownloadStage = null;
        });
        _showSaved();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('下载失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
        setState(() {
          _downloadingGgufModelId = null;
          _ggufDownloadStage = null;
        });
      }
    }
  }

  Future<void> _importGgufModel(String id) async {
    try {
      final success = await AsrModelManager().importGgufModel(id);
      if (success) {
        final downloaded = await AsrModelManager().getDownloadedGgufModels();
        if (mounted) {
          setState(() => _downloadedGgufModels = downloaded);
          _showSaved();
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('导入失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  Future<void> _deleteGgufModel(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型'),
        content: const Text('确认删除此 GGUF ASR 模型？此操作不可恢复。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('删除')),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await AsrModelManager().deleteGgufModel(id);
      final downloaded = await AsrModelManager().getDownloadedGgufModels();
      if (mounted) {
        setState(() => _downloadedGgufModels = downloaded);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('删除失败: $e'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  // —— 2. LLM 按功能配置 ——

  Widget _buildLlmSection() {
    // 每个功能一个 ExpansionTile，独立配置引擎+提供商+模型+高级参数
    final tiles = <Widget>[];
    for (final entry in [
      (LlmTaskType.translation, '翻译', Icons.translate),
      (LlmTaskType.summary, '会议纪要', Icons.summarize),
      (LlmTaskType.noteOrganize, '笔记整理', Icons.note_alt_outlined),
      (LlmTaskType.correction, '纠错', Icons.spellcheck),
    ]) {
      tiles.add(_buildLlmTaskTile(entry.$1, entry.$2, entry.$3));
    }
    return Column(children: tiles);
  }

  Widget _buildLlmTaskTile(LlmTaskType task, String displayName, IconData icon) {
    final config = _llmConfigs[task];
    if (config == null) {
      return const SizedBox.shrink();
    }
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 16),
        leading: Icon(icon, color: AppTheme.accentColor),
        title: Text(displayName),
        subtitle: Text(
          '${config.engineType == LlmEngineType.cloud ? "云端" : "本地"} · '
          '${config.providerName ?? "未选择提供商"}',
          style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
        ),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<LlmEngineType>(
                  segments: const [
                    ButtonSegment(value: LlmEngineType.local, label: Text('本地')),
                    ButtonSegment(value: LlmEngineType.cloud, label: Text('云端')),
                  ],
                  selected: {config.engineType},
                  onSelectionChanged: (s) => _updateLlmConfig(
                      task, config.copyWith(engineType: s.first)),
                ),
                const SizedBox(height: 12),
                if (config.engineType == LlmEngineType.cloud)
                  _buildCloudLlmConfig(task, config)
                else
                  _buildLocalLlmHint(),
                const SizedBox(height: 8),
                _buildAdvancedParams(task, config),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCloudLlmConfig(LlmTaskType task, LlmConfig config) {
    final provider = config.providerName ?? 'deepseek';
    final model = (config.modelName != null && config.modelName!.isNotEmpty)
        ? config.modelName!
        : (AiProviders.getByName(provider)?.defaultModel ?? '');
    return AiConfigSelector(
      currentProvider: provider,
      currentModel: model,
      supportedProviderTypes: _textProviderTypes,
      onProviderChanged: (p) {
        final defaultModel = AiProviders.getByName(p)?.defaultModel ?? '';
        _updateLlmConfig(
            task, config.copyWith(providerName: p, modelName: defaultModel));
      },
      onModelChanged: (m) {
        _updateLlmConfig(task, config.copyWith(modelName: m));
      },
    );
  }

  Widget _buildLocalLlmHint() {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.accentColor.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(Icons.construction, size: 16, color: AppTheme.accentColor),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '本地 LLM 引擎尚在开发中（llama.cpp FFI），暂时请使用云端',
              style: TextStyle(fontSize: 13, color: AppTheme.accentColor),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAdvancedParams(LlmTaskType task, LlmConfig config) {
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      dense: true,
      title: Text('高级参数',
          style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('最大 Token',
                      style: TextStyle(
                          fontSize: 13, color: AppTheme.textPrimary)),
                  Text('${config.maxTokens}',
                      style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.accentColor,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              Slider(
                value: config.maxTokens.toDouble().clamp(512, 8192),
                min: 512,
                max: 8192,
                divisions: 30,
                activeColor: AppTheme.accentColor,
                onChanged: (v) => _updateLlmConfig(
                    task, config.copyWith(maxTokens: v.round())),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text('温度',
                      style: TextStyle(
                          fontSize: 13, color: AppTheme.textPrimary)),
                  Text(config.temperature.toStringAsFixed(1),
                      style: TextStyle(
                          fontSize: 12,
                          color: AppTheme.accentColor,
                          fontWeight: FontWeight.w600)),
                ],
              ),
              Slider(
                value: config.temperature.clamp(0.0, 2.0),
                min: 0,
                max: 2,
                divisions: 20,
                activeColor: AppTheme.accentColor,
                onChanged: (v) => _updateLlmConfig(
                    task, config.copyWith(temperature: v)),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // —— 3. API Key 管理入口 ——

  Widget _buildAiRouterEntry() {
    return _sectionCard([
      ListTile(
        leading: Icon(Icons.vpn_key, color: AppTheme.accentColor),
        title: const Text('API Key 管理'),
        subtitle: Text('集中配置各平台 API Key 与连通性测试',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        trailing: Icon(Icons.chevron_right, color: AppTheme.textSecondary),
        onTap: () => _pushScreen(const AiRouterScreen()),
      ),
    ]);
  }

  // —— 4. 录音配置 ——

  Widget _buildRecordingSection() {
    return _sectionCard([
      ListTile(
        leading: Icon(Icons.mic, color: AppTheme.accentColor),
        title: const Text('默认录音源'),
        trailing: DropdownButton<RecordingSource>(
          value: _recordingSource,
          underline: const SizedBox(),
          items: const [
            DropdownMenuItem(
                value: RecordingSource.mic, child: Text('麦克风')),
            DropdownMenuItem(
                value: RecordingSource.speaker, child: Text('扬声器内录')),
            DropdownMenuItem(
                value: RecordingSource.dual, child: Text('双轨')),
          ],
          onChanged: (v) {
            if (v != null) _setRecordingSource(v);
          },
        ),
      ),
      const Divider(height: 1),
      ListTile(
        leading: Icon(Icons.graphic_eq, color: AppTheme.textSecondary),
        title: const Text('采样率'),
        trailing: Text('16 kHz（ASR 标准，只读）',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
        enabled: false,
      ),
    ]);
  }

  // —— 5. 管理入口 ——

  Widget _buildManagementEntries() {
    return _sectionCard([
      ListTile(
        leading: Icon(Icons.spellcheck, color: AppTheme.accentColor),
        title: const Text('热词管理'),
        subtitle: Text('ASR 识别热词词库',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        trailing: Icon(Icons.chevron_right, color: AppTheme.textSecondary),
        onTap: () => _pushScreen(const HotwordScreen()),
      ),
      const Divider(height: 1),
      ListTile(
        leading: Icon(Icons.speaker, color: AppTheme.accentColor),
        title: const Text('说话人管理'),
        subtitle: Text('声纹档案与说话人区分',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        trailing: Icon(Icons.chevron_right, color: AppTheme.textSecondary),
        onTap: () => _pushScreen(const SpeakerScreen()),
      ),
      const Divider(height: 1),
      ListTile(
        leading: Icon(Icons.storage, color: AppTheme.accentColor),
        title: const Text('数据管理'),
        subtitle: Text('导入导出 / 清理 / 存储用量',
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary)),
        trailing: Icon(Icons.chevron_right, color: AppTheme.textSecondary),
        onTap: () => _pushScreen(const DataManagementScreen()),
      ),
    ]);
  }

  // —— 关于 ——

  Widget _buildAboutButton() {
    return GestureDetector(
      onTap: () => context.push('/about'),
      child: _sectionCard([
        Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.info_outline, color: AppTheme.textSecondary, size: 20),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('关于 NOTA',
                        style: TextStyle(
                            fontSize: 14, color: AppTheme.textPrimary)),
                    const SizedBox(height: 2),
                    Text('v$_version · MIT 开源协议',
                        style: TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary)),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: AppTheme.textSecondary, size: 18),
            ],
          ),
        ),
      ]),
    );
  }

  // —— 外观（沿用原实现） ——

  Widget _buildThemeSelector(AppThemeMode currentTheme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).dividerColor, width: 0.5),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<AppThemeMode>(
          value: currentTheme,
          isExpanded: true,
          dropdownColor: AppTheme.cardColor,
          style: TextStyle(color: AppTheme.textPrimary),
          items: const [
            DropdownMenuItem(value: AppThemeMode.dark, child: Text('深色模式')),
            DropdownMenuItem(value: AppThemeMode.light, child: Text('浅色模式')),
            DropdownMenuItem(value: AppThemeMode.system, child: Text('跟随系统')),
          ],
          onChanged: (value) {
            if (value != null) {
              ref.read(themeModeProvider.notifier).state = value;
              ThemeService.setThemeMode(value);
            }
          },
        ),
      ),
    );
  }

  Widget _buildAccentColorPicker() {
    final colors = [
      {'name': '薰衣草紫', 'color': const Color(0xFF9B8EC4)},
      {'name': '海洋蓝', 'color': const Color(0xFF5B9BD5)},
      {'name': '森林绿', 'color': const Color(0xFF6BAF6D)},
      {'name': '珊瑚红', 'color': const Color(0xFFE8735A)},
      {'name': '琥珀橙', 'color': const Color(0xFFE8A44C)},
    ];

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.cardColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Theme.of(context).dividerColor, width: 0.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('主题色', style: TextStyle(fontSize: 14, color: AppTheme.textPrimary)),
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: colors.map((c) {
              return GestureDetector(
                onTap: () async {
                  await ThemeService.setAccentColor(c['color'] as Color);
                  setState(() {});
                  if (mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('主题色已更新')),
                    );
                  }
                },
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: c['color'] as Color,
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: Theme.of(context).dividerColor,
                      width: 2,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }
}
