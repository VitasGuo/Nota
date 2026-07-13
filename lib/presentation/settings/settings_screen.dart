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
import 'package:nota/presentation/settings/asr_settings_screen.dart';
import 'package:nota/presentation/speakers/speaker_screen.dart';
import 'package:nota/presentation/widgets/ai_config_selector.dart';
import 'package:nota/services/llm/ai_providers.dart';
import 'package:nota/services/llm/llm_engine.dart';
import 'package:nota/services/llm/llm_model_info.dart';
import 'package:nota/services/llm/llm_model_manager.dart';
import 'package:nota/services/llm/llm_task_router.dart';
import 'package:nota/services/llm/local_llm_engine.dart';

/// 设置界面 SettingsScreen（Task 22 改造，v0.9.8 抽取 ASR 到子页面）。
///
/// 分区组织：ASR 入口 / LLM 按功能配置 / API Key 管理 / 录音 / 管理入口 /
/// 外观 / 关于。ASR 配置已移至 [AsrSettingsScreen] 独立子页面，主设置页仅保留
/// 一个 ListTile 入口。LLM 按功能（翻译/纪要/笔记/纠错）各自独立配置引擎+提供商+模型，
/// 配置通过 [LlmTaskRouter] 持久化；默认录音源持久化到 `recording_source`。
class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  static const String _kRecordingSource = 'recording_source';

  // —— 加载状态 / 版本 ——
  bool _loaded = false;
  String _version = '';

  // —— 本地 LLM 模型（GGUF 文本 LLM via llama.cpp，v0.9.7 新增）——
  List<GgufLlmModelInfo> _downloadedLlmModels = [];
  String? _downloadingLlmModelId;
  double _llmDownloadProgress = 0;
  bool _testingLlmLoad = false; // 本地模型测试加载中

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

  Future<void> _loadAll() async {
    final info = await PackageInfo.fromPlatform();
    final prefs = await SharedPreferences.getInstance();

    // LLM 按功能配置
    final router = LlmTaskRouter();
    final llmConfigs = <LlmTaskType, LlmConfig>{};
    for (final t in LlmTaskType.values) {
      llmConfigs[t] = await router.getConfig(t);
    }

    // 本地 LLM 模型
    final downloadedLlm = await LlmModelManager().getDownloadedModels();

    // 录音源
    final srcName = prefs.getString(_kRecordingSource);
    final recordingSource = RecordingSource.values.asNameMap()[srcName] ??
        RecordingSource.mic;

    if (mounted) {
      setState(() {
        _version = info.version;
        _downloadedLlmModels = downloadedLlm;
        _llmConfigs.addAll(llmConfigs);
        _recordingSource = recordingSource;
        _loaded = true;
      });
    }
  }

  // —— 持久化辅助 ——

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
                _buildSectionTitle('语音识别'),
                Card(
                  margin: EdgeInsets.zero,
                  child: ListTile(
                    leading: Icon(Icons.mic, color: AppTheme.accentColor),
                    title: const Text('ASR 语音识别'),
                    subtitle: Text('引擎选择、模型下载与管理',
                        style: TextStyle(
                            fontSize: 12, color: AppTheme.textSecondary)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const AsrSettingsScreen()),
                      );
                    },
                  ),
                ),
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
                  _buildLocalLlmConfig(task, config),
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
      aiRouterRoute: '/settings/ai-router',
      onProviderChanged: (p) async {
        final providerConfig = AiProviders.getByName(p);
        final defaultModel = providerConfig?.defaultModel ?? '';
        // 本地/自定义提供商：从 AI Router 保存的 URL 读取，设入 customUrl
        String? customUrl;
        if (providerConfig?.showUrlAndModel ?? false) {
          final prefs = await SharedPreferences.getInstance();
          final savedUrl = prefs.getString('ai_router_url_$p');
          if (savedUrl != null && savedUrl.isNotEmpty) {
            customUrl = savedUrl;
          }
        }
        _updateLlmConfig(task, config.copyWith(
          providerName: p,
          modelName: defaultModel,
          customUrl: customUrl,
        ));
      },
      onModelChanged: (m) {
        _updateLlmConfig(task, config.copyWith(modelName: m));
      },
    );
  }

  /// 本地 LLM 引擎配置（v0.9.7：llama.cpp FFI 已打通，可选/下载/导入 GGUF 模型）。
  ///
  /// 显示已下载的本地文本 LLM 模型，用户可选择一个用于当前任务（翻译/纪要等）。
  /// 支持下载预置模型（Qwen3-0.6B 首选，魔搭源）、导入本地 .gguf 文件、删除模型。
  Widget _buildLocalLlmConfig(LlmTaskType task, LlmConfig config) {
    final currentModel = config.modelName;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 说明
        Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppTheme.accentColor.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(Icons.memory, size: 16, color: AppTheme.accentColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '本地 llama.cpp 推理，离线可用。翻译推荐 Qwen3-0.6B（~640MB）',
                  style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 已下载模型列表
        if (_downloadedLlmModels.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '暂无已下载本地模型，请在下方下载',
              style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
            ),
          )
        else
          ..._downloadedLlmModels.map((m) => RadioListTile<String>(
                dense: true,
                value: m.id,
                groupValue: currentModel,
                title: Text(m.displayName, style: const TextStyle(fontSize: 14)),
                subtitle: Text(m.description,
                    style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                onChanged: (v) => _updateLlmConfig(
                    task, config.copyWith(modelName: v)),
              )),
        // 自定义导入模型提示
        FutureBuilder<List<({String modelId, String path, String filename})>>(
          future: LlmModelManager().getCustomModels(),
          builder: (context, snapshot) {
            if (!snapshot.hasData || snapshot.data!.isEmpty) {
              return const SizedBox.shrink();
            }
            return Column(
              children: snapshot.data!.map((m) => RadioListTile<String>(
                dense: true,
                value: m.modelId,
                groupValue: currentModel,
                title: Text(m.filename, style: const TextStyle(fontSize: 14)),
                subtitle: Text('自定义导入',
                    style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
                onChanged: (v) => _updateLlmConfig(
                    task, config.copyWith(modelName: v)),
              )).toList(),
            );
          },
        ),
        const Divider(height: 1),
        // 测试加载按钮：验证选中模型能否正常加载到 llama.cpp
        if (currentModel != null && currentModel.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _testingLlmLoad ? null : () => _testLocalLlmLoad(currentModel),
                icon: _testingLlmLoad
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.play_circle_outline, size: 18),
                label: Text(_testingLlmLoad ? '加载中...' : '测试加载模型'),
              ),
            ),
          ),
        ],
        // 下载 / 导入入口
        ...GgufLlmModels.available.map((m) {
          final downloaded = _downloadedLlmModels.any((d) => d.id == m.id);
          if (downloaded) return const SizedBox.shrink();
          final downloading = _downloadingLlmModelId == m.id;
          return ListTile(
            dense: true,
            leading: Icon(
              downloading ? Icons.downloading : Icons.download,
              size: 20,
              color: AppTheme.accentColor,
            ),
            title: Text('下载 ${m.displayName}',
                style: const TextStyle(fontSize: 13)),
            subtitle: downloading
                ? LinearProgressIndicator(
                    value: _llmDownloadProgress > 0
                        ? _llmDownloadProgress
                        : null,
                    backgroundColor: AppTheme.accentColor.withValues(alpha: 0.2),
                  )
                : Text(m.description,
                    style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
            trailing: downloading
                ? Text('${(_llmDownloadProgress * 100).round()}%',
                    style: TextStyle(fontSize: 12, color: AppTheme.accentColor))
                : null,
            onTap: downloading ? null : () => _downloadLlmModel(m.id),
          );
        }),
        ListTile(
          dense: true,
          leading: Icon(Icons.file_upload_outlined,
              size: 20, color: AppTheme.accentColor),
          title: const Text('导入本地 .gguf 文件', style: TextStyle(fontSize: 13)),
          subtitle: Text('从手机存储选择任意 GGUF 文本模型',
              style: TextStyle(fontSize: 11, color: AppTheme.textSecondary)),
          onTap: () => _importLlmModel(),
        ),
        // 删除已下载模型
        if (_downloadedLlmModels.isNotEmpty)
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            dense: true,
            title: Text('删除模型',
                style: TextStyle(fontSize: 13, color: AppTheme.textSecondary)),
            children: _downloadedLlmModels
                .map((m) => ListTile(
                      dense: true,
                      leading: const Icon(Icons.delete_outline,
                          size: 18, color: Colors.red),
                      title: Text(m.displayName,
                          style: const TextStyle(fontSize: 13)),
                      onTap: () => _deleteLlmModel(m.id),
                    ))
                .toList(),
          ),
      ],
    );
  }

  Future<void> _downloadLlmModel(String modelId) async {
    setState(() {
      _downloadingLlmModelId = modelId;
      _llmDownloadProgress = 0;
    });
    try {
      await LlmModelManager().downloadModel(modelId, onProgress: (p) {
        if (mounted) setState(() => _llmDownloadProgress = p);
      });
      final downloaded = await LlmModelManager().getDownloadedModels();
      if (mounted) {
        setState(() {
          _downloadedLlmModels = downloaded;
          _downloadingLlmModelId = null;
          _llmDownloadProgress = 0;
        });
        _showSaved();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _downloadingLlmModelId = null);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('下载失败: $e')),
        );
      }
    }
  }

  Future<void> _importLlmModel() async {
    try {
      final modelId = await LlmModelManager().importCustomModel();
      if (!mounted) return;
      setState(() {});
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已导入模型: $modelId')),
      );
    } catch (e) {
      if (e.toString().contains('取消选择')) return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('导入失败: $e')),
        );
      }
    }
  }

  Future<void> _deleteLlmModel(String modelId) async {
    await LlmModelManager().deleteModel(modelId);
    final downloaded = await LlmModelManager().getDownloadedModels();
    if (mounted) {
      setState(() => _downloadedLlmModels = downloaded);
    }
  }

  /// 测试本地 LLM 模型加载：创建临时 LocalLlmEngine → init → 验证成功 → dispose。
  ///
  /// 让用户在设置页就能确认模型文件是否有效、llama.cpp 能否正常加载，
  /// 而不是到录音界面才发现问题。成功显示模型描述，失败显示错误。
  Future<void> _testLocalLlmLoad(String modelId) async {
    setState(() => _testingLlmLoad = true);
    try {
      final engine = LocalLlmEngine();
      await engine.init(LlmConfig(
        engineType: LlmEngineType.local,
        modelName: modelId,
        temperature: 0.1,
        maxTokens: 64,
      ));
      final desc = engine.modelDesc;
      await engine.dispose();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✓ 模型加载成功：$desc'),
            backgroundColor: Colors.green,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('✗ 加载失败: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _testingLlmLoad = false);
    }
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
