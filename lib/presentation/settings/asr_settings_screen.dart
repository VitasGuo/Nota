import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:nota/core/theme.dart';
import 'package:nota/services/asr/asr_engine.dart';
import 'package:nota/services/asr/asr_model_info.dart';
import 'package:nota/services/asr/asr_model_manager.dart';

/// ASR 语音识别设置子页面（v0.9.8 从 settings_screen.dart 抽取）。
///
/// 包含 ASR 引擎配置（本地/云端切换 + 模型激活/下载/删除）、whisper.cpp
/// ggml 模型管理、Qwen3-ASR GGUF 模型管理三个区块。主设置页仅保留一个
/// ListTile 入口跳转到此页面。
class AsrSettingsScreen extends StatefulWidget {
  const AsrSettingsScreen({super.key});

  @override
  State<AsrSettingsScreen> createState() => _AsrSettingsScreenState();
}

class _AsrSettingsScreenState extends State<AsrSettingsScreen> {
  static const String _kAsrConfig = 'asr_config';

  // —— 加载状态 ——
  bool _loaded = false;

  // —— ASR 配置 ——
  AsrConfig? _asrConfig;
  List<AsrModelInfo> _downloadedModels = [];
  String? _downloadingModelId;
  double _downloadProgress = 0;
  final TextEditingController _asrBaseUrlController = TextEditingController();
  final TextEditingController _asrApiKeyController = TextEditingController();
  final TextEditingController _asrModelNameController = TextEditingController();

  /// 本地 ASR 引擎偏好：`whisper`（默认，v0.9.6 新增，稳定且质量优）/
  /// `sherpa`（sherpa-onnx 稳定）/ `gguf`（Qwen3-ASR 质量优但可能闪退）。
  String _asrLocalEnginePref = 'whisper';

  // —— GGUF ASR 模型（Qwen3-ASR via llama.cpp mtmd）——
  List<GgufAsrModelInfo> _downloadedGgufModels = [];
  String? _downloadingGgufModelId;
  double _ggufDownloadProgress = 0;
  String? _ggufDownloadStage;

  // —— whisper.cpp ASR 模型（ggml .bin 单文件，v0.9.6 新增）——
  List<WhisperModelInfo> _downloadedWhisperModels = [];
  String? _downloadingWhisperModelId;
  double _whisperDownloadProgress = 0;

  // —— VAD 模型 ——
  bool _vadReady = false;

  @override
  void initState() {
    super.initState();
    _loadAsrData();
  }

  @override
  void dispose() {
    _asrBaseUrlController.dispose();
    _asrApiKeyController.dispose();
    _asrModelNameController.dispose();
    super.dispose();
  }

  Future<void> _loadAsrData() async {
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
    final downloadedWhisper = await AsrModelManager().getDownloadedWhisperModels();
    final vadReady = await AsrModelManager().isVadModelDownloaded();
    final asrEnginePref = prefs.getString('asr_local_engine_pref') ?? 'whisper';

    if (mounted) {
      setState(() {
        _asrConfig = asrConfig;
        _asrBaseUrlController.text = asrConfig.baseUrl ?? '';
        _asrApiKeyController.text = asrConfig.apiKey ?? '';
        _asrModelNameController.text = asrConfig.modelName ?? '';
        _downloadedModels = downloaded;
        _downloadedGgufModels = downloadedGguf;
        _downloadedWhisperModels = downloadedWhisper;
        _vadReady = vadReady;
        _asrLocalEnginePref = asrEnginePref;
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

  void _showSaved() {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已保存'), duration: Duration(seconds: 1)),
      );
    }
  }

  // —— 构建 ——

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ASR 语音识别')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _buildSectionTitle('ASR 引擎'),
                _buildAsrSection(),
                const SizedBox(height: 24),
                _buildSectionTitle('whisper.cpp 模型（推荐，稳定本地实时转写）'),
                _buildWhisperAsrSection(),
                const SizedBox(height: 24),
                _buildSectionTitle('Qwen3-ASR GGUF 模型（高质量实时转写）'),
                _buildGgufAsrSection(),
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
        _buildLocalAsrEnginePref(),
        const Divider(height: 1),
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

  /// 本地 ASR 引擎偏好选择（whisper.cpp 推荐 / sherpa-onnx 稳定 / GGUF ASR 质量优）。
  ///
  /// whisper.cpp（ggml 模型，v0.9.6 新增）为默认，移动端成熟稳定且质量优；
  /// sherpa-onnx（SenseVoice/Paraformer/Whisper）ONNX 运行时稳定；
  /// GGUF ASR（Qwen3-ASR via llama.cpp）质量最优但同步 FFI 有阻塞主线程风险。
  /// 用户已下载对应模型后可在此切换。
  Widget _buildLocalAsrEnginePref() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: DropdownButtonFormField<String>(
        initialValue: _asrLocalEnginePref,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: '本地 ASR 引擎',
          isDense: true,
          border: OutlineInputBorder(),
          helperText: 'whisper.cpp 推荐（默认） / sherpa-onnx 稳定 / GGUF ASR 质量优（可能闪退）',
          helperMaxLines: 2,
        ),
        items: const [
          DropdownMenuItem(
            value: 'whisper',
            child: Text('whisper.cpp（推荐）', overflow: TextOverflow.ellipsis),
          ),
          DropdownMenuItem(
            value: 'sherpa',
            child: Text('sherpa-onnx（稳定）', overflow: TextOverflow.ellipsis),
          ),
          DropdownMenuItem(
            value: 'gguf',
            child: Text('GGUF ASR（质量优）', overflow: TextOverflow.ellipsis),
          ),
        ],
        onChanged: (value) async {
          if (value == null) return;
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString('asr_local_engine_pref', value);
          setState(() => _asrLocalEnginePref = value);
        },
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

  // —— 1a. whisper.cpp ASR 模型管理（ggml .bin 单文件，v0.9.6 新增）——

  /// whisper.cpp ASR 模型管理区域。
  ///
  /// whisper.cpp 使用原生 ggml 格式（.bin 单文件），移动端成熟稳定，
  /// 质量优于 sherpa-onnx Whisper 且比 Qwen3-ASR 更稳定（无同步 FFI 阻塞）。
  /// 推荐下载 ggml-small.bin（~466MB，中文最小可用）。
  /// 从 hf-mirror.com 下载（国内网络友好），也支持本地导入。
  /// 下载后录音界面默认使用此引擎（v0.9.6 起为默认 ASR）。
  Widget _buildWhisperAsrSection() {
    final pending = WhisperModels.available
        .where((m) => !_downloadedWhisperModels.any((d) => d.id == m.id))
        .toList();

    return _sectionCard([
      // 国内网络下载警告
      Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.orange.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, size: 16, color: Colors.orange[700]),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '国内网络下载 whisper ggml 模型可能失败（403），建议从电脑浏览器下载后点"导入"，或使用 sherpa-onnx 模型',
                style: TextStyle(fontSize: 12, color: Colors.orange[700]),
              ),
            ),
          ],
        ),
      ),
      const SizedBox(height: 8),
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
                'whisper.cpp 基于 ggml 格式，移动端成熟稳定，质量优且无闪退风险。'
                '推荐 ggml-small.bin（~466MB，中文最小可用）。从 hf-mirror.com 下载，国内网络友好。',
                style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
              ),
            ),
          ],
        ),
      ),
      // 已下载模型
      ..._downloadedWhisperModels.map((m) => ListTile(
            dense: true,
            leading:
                Icon(Icons.check_circle, color: Colors.green.shade600, size: 20),
            title: Text(m.displayName, style: const TextStyle(fontSize: 13)),
            subtitle: Text(
              '${m.sizeMb.toStringAsFixed(0)}MB · ${m.language}',
              style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline, size: 18),
              tooltip: '删除模型',
              onPressed: () => _deleteWhisperModel(m.id),
            ),
          )),
      // 下载/导入列表
      ...pending.map((m) {
        final isDownloading = _downloadingWhisperModelId == m.id;
        return ListTile(
          dense: true,
          title: Text(m.displayName, style: const TextStyle(fontSize: 13)),
          subtitle: Text(
            '${m.sizeMb.toStringAsFixed(0)}MB · ${m.language}',
            style: TextStyle(fontSize: 11, color: AppTheme.textSecondary),
          ),
          trailing: isDownloading
              ? SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(
                    value: _whisperDownloadProgress > 0
                        ? _whisperDownloadProgress
                        : null,
                    strokeWidth: 2,
                  ),
                )
              : Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextButton(
                      onPressed: () => _downloadWhisperModel(m.id),
                      child: const Text('下载'),
                    ),
                    TextButton(
                      onPressed: () => _importWhisperModel(m.id),
                      child: const Text('导入'),
                    ),
                  ],
                ),
        );
      }),
      if (_downloadedWhisperModels.isEmpty && pending.isEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text(
            '暂无可用 whisper.cpp 模型',
            style: TextStyle(fontSize: 13, color: AppTheme.textSecondary),
          ),
        ),
    ]);
  }

  Future<void> _downloadWhisperModel(String id) async {
    setState(() {
      _downloadingWhisperModelId = id;
      _whisperDownloadProgress = 0;
    });
    try {
      await AsrModelManager().downloadWhisperModel(
        id,
        onProgress: (p) {
          if (mounted) setState(() => _whisperDownloadProgress = p);
        },
      );
      final downloaded = await AsrModelManager().getDownloadedWhisperModels();
      if (mounted) {
        setState(() {
          _downloadedWhisperModels = downloaded;
          _downloadingWhisperModelId = null;
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
          _downloadingWhisperModelId = null;
        });
      }
    }
  }

  Future<void> _importWhisperModel(String id) async {
    try {
      final success = await AsrModelManager().importWhisperModel(id);
      if (success) {
        final downloaded = await AsrModelManager().getDownloadedWhisperModels();
        if (mounted) {
          setState(() => _downloadedWhisperModels = downloaded);
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

  Future<void> _deleteWhisperModel(String id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型'),
        content: const Text('确认删除此 whisper.cpp 模型？此操作不可恢复。'),
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
      await AsrModelManager().deleteWhisperModel(id);
      final downloaded = await AsrModelManager().getDownloadedWhisperModels();
      if (mounted) {
        setState(() => _downloadedWhisperModels = downloaded);
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
}
