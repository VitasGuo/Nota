import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:nota/core/theme.dart';
import 'package:nota/models/note.dart';
import 'package:nota/models/recording_session.dart';
import 'package:nota/services/storage/data_manager.dart';
import 'package:nota/services/storage/note_storage.dart';
import 'package:nota/services/storage/recording_storage.dart';

/// 数据管理界面（Task 21d）。
///
/// 四大分区：存储用量统计 / 导入 / 导出 / 清理缓存。
/// 统一通过 [DataManager] 单例操作文件系统与 SQLite，
/// 长操作（导入/导出/扫描/清理）均带进度对话框与 SnackBar 反馈。
class DataManagementScreen extends StatefulWidget {
  const DataManagementScreen({super.key});

  @override
  State<DataManagementScreen> createState() => _DataManagementScreenState();
}

class _DataManagementScreenState extends State<DataManagementScreen> {
  final DataManager _dataManager = DataManager();
  final RecordingStorage _recordingStorage = RecordingStorage();
  final NoteStorage _noteStorage = NoteStorage();

  Future<StorageUsage>? _usageFuture;

  /// 孤立文件扫描结果：null 表示尚未扫描，空列表表示已扫描但无孤立文件。
  List<String>? _orphanPaths;
  int _orphanSize = 0;

  @override
  void initState() {
    super.initState();
    _reloadUsage();
  }

  void _reloadUsage() {
    setState(() {
      _usageFuture = _dataManager.getStorageUsage();
    });
  }

  // ============ 通用辅助 ============

  /// 包裹长操作：弹不可关闭的进度对话框，完成后关闭并按结果展示 SnackBar。
  ///
  /// [task] 返回成功消息字符串；抛异常时展示失败消息。
  Future<void> _runWithProgress(
    String message,
    Future<String> Function() task,
  ) async {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Row(
            children: [
              const CircularProgressIndicator(),
              const SizedBox(width: 20),
              Expanded(child: Text(message)),
            ],
          ),
        ),
      ),
    );
    String? success;
    String? error;
    try {
      success = await task();
    } catch (e) {
      error = e.toString();
    }
    if (mounted) Navigator.of(context).pop();
    if (!mounted) return;
    _showSnack(error != null ? '操作失败：$error' : (success ?? '完成'));
  }

  Future<bool?> _confirmDialog(String title, String content) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('确定', style: TextStyle(color: Colors.redAccent)),
          ),
        ],
      ),
    );
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 3)),
    );
  }

  /// 导出输出目录：应用文档目录下的 exports/。
  Future<String> _exportsDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final exportsDir = Directory(p.join(dir.path, 'exports'));
    if (!exportsDir.existsSync()) {
      await exportsDir.create(recursive: true);
    }
    return exportsDir.path;
  }

  /// 递归计算目录大小（字节）。
  ///
  /// 用于扫描孤立文件后估算可清理空间（DataManager 未暴露按路径计大小的公开方法）。
  Future<int> _dirSize(String path) async {
    final dir = Directory(path);
    if (!dir.existsSync()) return 0;
    int total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) total += await entity.length();
    }
    return total;
  }

  String _formatDate(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} '
        '${two(dt.hour)}:${two(dt.minute)}';
  }

  // ============ 导入 ============

  Future<void> _importAudio() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['wav', 'mp3', 'm4a'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    await _runWithProgress('正在导入音频…', () async {
      final session = await _dataManager.importAudioFile(path);
      return '已导入音频：${session.title}';
    });
    _reloadUsage();
  }

  Future<void> _importNotesMd() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['md', 'markdown'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    await _runWithProgress('正在导入笔记…', () async {
      final note = await _dataManager.importNotesFromMarkdown(path);
      return '已导入笔记：${note.title}';
    });
  }

  Future<void> _importHotwords() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['txt'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    await _runWithProgress('正在导入热词…', () async {
      final count = await _dataManager.importHotwordsFromText(path);
      return '已导入 $count 条热词';
    });
  }

  Future<void> _importSpeakerConfig() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['json'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.single.path;
    if (path == null) return;
    await _runWithProgress('正在导入说话人配置…', () async {
      final count = await _dataManager.importSpeakerConfig(path);
      return '已导入 $count 个说话人';
    });
  }

  // ============ 导出 ============

  Future<void> _exportSessionZip() async {
    final sessions = await _recordingStorage.getSessions();
    if (!mounted) return;
    if (sessions.isEmpty) {
      _showSnack('暂无可导出的会话');
      return;
    }
    final selected = await _pickSession(sessions);
    if (selected == null) return;
    final outDir = await _exportsDir();
    await _runWithProgress('正在导出会话…', () async {
      final path = await _dataManager.exportSessionAsZip(selected.id, outDir);
      return '已导出：$path';
    });
  }

  Future<void> _exportNoteMd() async {
    final notes = await _noteStorage.getNotes();
    if (!mounted) return;
    if (notes.isEmpty) {
      _showSnack('暂无可导出的笔记');
      return;
    }
    final selected = await _pickNote(notes);
    if (selected == null || selected.id == null) return;
    final outDir = await _exportsDir();
    await _runWithProgress('正在导出笔记…', () async {
      final path =
          await _dataManager.exportNoteAsMarkdown('${selected.id}', outDir);
      return '已导出：$path';
    });
  }

  Future<void> _exportHotwords() async {
    final outDir = await _exportsDir();
    await _runWithProgress('正在导出热词…', () async {
      final path = await _dataManager.exportHotwordsAsText(outDir);
      return '已导出：$path';
    });
  }

  Future<void> _exportBackup() async {
    final outDir = await _exportsDir();
    await _runWithProgress('正在备份全部数据，请稍候…', () async {
      final path = await _dataManager.exportAllAsBackup(outDir);
      return '备份完成：$path';
    });
  }

  // ============ 选择对话框 ============

  Future<RecordingSession?> _pickSession(List<RecordingSession> sessions) {
    return showDialog<RecordingSession>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择会话'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: sessions.length,
            itemBuilder: (_, i) {
              final s = sessions[i];
              return ListTile(
                title: Text(s.title.isEmpty ? '（无标题）' : s.title),
                subtitle: Text(_formatDate(s.startTime)),
                onTap: () => Navigator.pop(ctx, s),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<Note?> _pickNote(List<Note> notes) {
    return showDialog<Note>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('选择笔记'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: notes.length,
            itemBuilder: (_, i) {
              final n = notes[i];
              return ListTile(
                title: Text(n.title.isEmpty ? '（无标题）' : n.title),
                subtitle: Text(_formatDate(n.createdAt)),
                onTap: () => Navigator.pop(ctx, n),
              );
            },
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  // ============ 清理缓存 ============

  Future<void> _scanOrphans() async {
    await _runWithProgress('正在扫描孤立文件…', () async {
      final orphans = await _dataManager.scanOrphanFiles();
      int size = 0;
      for (final path in orphans) {
        size += await _dirSize(path);
      }
      if (mounted) {
        setState(() {
          _orphanPaths = orphans;
          _orphanSize = size;
        });
      }
      return orphans.isEmpty
          ? '未发现孤立文件'
          : '发现 ${orphans.length} 个孤立文件，共 ${StorageUsage.formatBytes(size)}';
    });
  }

  Future<void> _cleanOrphans() async {
    if (_orphanPaths == null) {
      _showSnack('请先扫描孤立文件');
      return;
    }
    if (_orphanPaths!.isEmpty) {
      _showSnack('无可清理的孤立文件');
      return;
    }
    final confirmed = await _confirmDialog(
      '清理孤立文件',
      '将删除 ${_orphanPaths!.length} 个孤立目录，'
          '释放约 ${StorageUsage.formatBytes(_orphanSize)} 空间。此操作不可撤销。',
    );
    if (confirmed != true) return;
    await _runWithProgress('正在清理…', () async {
      final bytes = await _dataManager.cleanOrphanFiles();
      return '已释放 ${StorageUsage.formatBytes(bytes)} 空间';
    });
    if (mounted) {
      setState(() {
        _orphanPaths = null;
        _orphanSize = 0;
      });
    }
    _reloadUsage();
  }

  // ============ 构建 ============

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('数据管理'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _reloadUsage,
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _buildUsageSection(),
              const SizedBox(height: 16),
              _buildSectionTitle('导入', Icons.file_download_outlined),
              _buildImportCard(),
              const SizedBox(height: 16),
              _buildSectionTitle('导出', Icons.file_upload_outlined),
              _buildExportCard(),
              const SizedBox(height: 16),
              _buildSectionTitle('清理缓存', Icons.cleaning_services_outlined),
              _buildCleanCard(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSectionTitle(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Row(
        children: [
          Icon(icon, size: 20, color: AppTheme.accentColor),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
        ],
      ),
    );
  }

  // —— 存储用量统计 ——

  Widget _buildUsageSection() {
    return FutureBuilder<StorageUsage>(
      future: _usageFuture,
      builder: (ctx, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return Card(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Center(
                child: CircularProgressIndicator(color: AppTheme.accentColor),
              ),
            ),
          );
        }
        if (snap.hasError) {
          return Card(
            child: ListTile(
              leading:
                  const Icon(Icons.error_outline, color: Colors.redAccent),
              title: const Text('加载失败'),
              subtitle: Text('${snap.error}'),
            ),
          );
        }
        return _buildUsageCard(snap.data!);
      },
    );
  }

  Widget _buildUsageCard(StorageUsage usage) {
    final total = usage.totalSize;
    final categories = <(String, int, Color)>[
      ('会话音频', usage.sessionsSize, const Color(0xFF4A90D9)),
      ('ASR 模型', usage.modelsSize, const Color(0xFF52A373)),
      ('缓存', usage.cacheSize, const Color(0xFFE0A23C)),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.storage, color: AppTheme.accentColor),
                const SizedBox(width: 8),
                Text(
                  '存储用量',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: AppTheme.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              StorageUsage.formatBytes(total),
              style: TextStyle(
                fontSize: 30,
                fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary,
              ),
            ),
            const SizedBox(height: 16),
            ...categories.map(
              (c) => _buildCategoryBar(c.$1, c.$2, c.$3, total),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCategoryBar(String label, int size, Color color, int total) {
    final ratio = total > 0 ? (size / total).clamp(0.0, 1.0) : 0.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  color: AppTheme.textSecondary,
                ),
              ),
              const Spacer(),
              Text(
                StorageUsage.formatBytes(size),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppTheme.textPrimary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: ratio,
              minHeight: 8,
              backgroundColor: AppTheme.textSecondary.withValues(alpha: 0.15),
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // —— 导入卡片 ——

  Widget _buildImportCard() {
    return Card(
      child: Column(
        children: [
          _buildActionTile(
            icon: Icons.audio_file_outlined,
            color: const Color(0xFF4A90D9),
            title: '导入音频文件',
            subtitle: 'wav / mp3 / m4a',
            onTap: _importAudio,
          ),
          const Divider(height: 1, indent: 56),
          _buildActionTile(
            icon: Icons.description_outlined,
            color: const Color(0xFF52A373),
            title: '导入笔记',
            subtitle: 'Markdown .md 文件',
            onTap: _importNotesMd,
          ),
          const Divider(height: 1, indent: 56),
          _buildActionTile(
            icon: Icons.spellcheck_outlined,
            color: const Color(0xFFE0A23C),
            title: '导入热词',
            subtitle: '文本 .txt 文件',
            onTap: _importHotwords,
          ),
          const Divider(height: 1, indent: 56),
          _buildActionTile(
            icon: Icons.record_voice_over_outlined,
            color: const Color(0xFFC46B9B),
            title: '导入说话人配置',
            subtitle: 'JSON 配置文件',
            onTap: _importSpeakerConfig,
          ),
        ],
      ),
    );
  }

  // —— 导出卡片 ——

  Widget _buildExportCard() {
    return Card(
      child: Column(
        children: [
          _buildActionTile(
            icon: Icons.folder_zip_outlined,
            color: const Color(0xFF4A90D9),
            title: '按会话导出 zip',
            subtitle: '音频 + 转写 + 笔记 + 元信息',
            onTap: _exportSessionZip,
          ),
          const Divider(height: 1, indent: 56),
          _buildActionTile(
            icon: Icons.article_outlined,
            color: const Color(0xFF52A373),
            title: '导出笔记为 .md',
            subtitle: '选择单条笔记导出',
            onTap: _exportNoteMd,
          ),
          const Divider(height: 1, indent: 56),
          _buildActionTile(
            icon: Icons.spellcheck_outlined,
            color: const Color(0xFFE0A23C),
            title: '导出热词',
            subtitle: '导出为 hotwords.txt',
            onTap: _exportHotwords,
          ),
          const Divider(height: 1, indent: 56),
          _buildActionTile(
            icon: Icons.backup_outlined,
            color: const Color(0xFFC46B9B),
            title: '全量备份',
            subtitle: '所有会话 + 笔记 + 热词打包',
            onTap: _exportBackup,
          ),
        ],
      ),
    );
  }

  // —— 清理卡片 ——

  Widget _buildCleanCard() {
    final hasOrphans = _orphanPaths != null && _orphanPaths!.isNotEmpty;
    return Card(
      child: Column(
        children: [
          _buildActionTile(
            icon: Icons.search_outlined,
            color: AppTheme.accentColor,
            title: '扫描孤立文件',
            subtitle: _orphanPaths == null
                ? '检查 recordings/ 下无数据库记录的残留目录'
                : hasOrphans
                    ? '发现 ${_orphanPaths!.length} 个，'
                        '可清理 ${StorageUsage.formatBytes(_orphanSize)}'
                    : '未发现孤立文件',
            onTap: _scanOrphans,
          ),
          const Divider(height: 1, indent: 56),
          _buildActionTile(
            icon: Icons.delete_sweep_outlined,
            color: Colors.redAccent,
            title: '执行清理',
            subtitle: hasOrphans
                ? '将释放 ${StorageUsage.formatBytes(_orphanSize)} 空间'
                : '需先扫描并发现孤立文件',
            enabled: hasOrphans,
            onTap: _cleanOrphans,
          ),
        ],
      ),
    );
  }

  Widget _buildActionTile({
    required IconData icon,
    required Color color,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
    bool enabled = true,
  }) {
    return ListTile(
      leading: Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: color, size: 20),
      ),
      title: Text(
        title,
        style: TextStyle(
          fontSize: 15,
          fontWeight: FontWeight.w500,
          color: enabled
              ? AppTheme.textPrimary
              : AppTheme.textSecondary.withValues(alpha: 0.5),
        ),
      ),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
      ),
      trailing: Icon(
        Icons.chevron_right,
        color: AppTheme.textSecondary.withValues(alpha: 0.5),
      ),
      enabled: enabled,
      onTap: onTap,
    );
  }
}
