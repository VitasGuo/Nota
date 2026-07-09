import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:nota/core/theme.dart';
import 'package:nota/models/hotword.dart';
import 'package:nota/services/storage/data_manager.dart';
import 'package:nota/services/storage/hotword_storage.dart';

/// 热词词库管理界面（Task 21b）。
///
/// 顶部 AppBar 右侧 PopupMenu：批量导入 / 导出全部 / 新建分组。
/// 分组以可展开 Card 呈现，展开后显示词条列表，支持增删改与权重设置。
/// 数据通过 [HotwordStorage] 读写，导出经 [DataManager] 落盘。
class HotwordScreen extends StatefulWidget {
  const HotwordScreen({super.key});

  @override
  State<HotwordScreen> createState() => _HotwordScreenState();
}

class _HotwordScreenState extends State<HotwordScreen> {
  final HotwordStorage _storage = HotwordStorage();
  final DataManager _dataManager = DataManager();

  final Set<int> _expandedGroupIds = {};
  final Map<int, List<HotwordEntry>> _entriesCache = {};

  List<HotwordGroup> _groups = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadAll();
  }

  // ============ 数据加载 ============

  Future<void> _loadAll() async {
    try {
      final groups = await _storage.getGroups();
      final map = <int, List<HotwordEntry>>{};
      for (final g in groups) {
        final id = g.id;
        if (id != null) map[id] = await _storage.getEntries(id);
      }
      if (mounted) {
        setState(() {
          _groups = groups;
          _entriesCache
            ..clear()
            ..addEntries(map.entries);
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isLoading = false);
        _showSnack('加载失败：$e');
      }
    }
  }

  Future<void> _reloadGroupEntries(int groupId) async {
    try {
      final entries = await _storage.getEntries(groupId);
      if (mounted) setState(() => _entriesCache[groupId] = entries);
    } catch (e) {
      _showSnack('加载词条失败：$e');
    }
  }

  // ============ 分组操作 ============

  Future<void> _showCreateGroupDialog() async {
    final name = await _showTextDialog(
      title: '新建分组',
      hint: '分组名称（如 人名 / 术语 / 常用词）',
      confirmText: '创建',
    );
    if (name == null || name.trim().isEmpty) return;
    final trimmed = name.trim();
    try {
      final id = await _storage.insertGroup(
        HotwordGroup(name: trimmed, createdAt: DateTime.now()),
      );
      _expandedGroupIds.add(id);
      await _loadAll();
      if (mounted) _showSnack('已创建分组「$trimmed」');
    } catch (e) {
      _showSnack('创建失败：$e');
    }
  }

  Future<void> _showRenameGroupDialog(HotwordGroup group) async {
    final name = await _showTextDialog(
      title: '重命名分组',
      hint: '分组名称',
      initial: group.name,
      confirmText: '保存',
    );
    if (name == null || name.trim().isEmpty) return;
    try {
      await _storage.updateGroup(group.copyWith(name: name.trim()));
      await _loadAll();
      if (mounted) _showSnack('已重命名');
    } catch (e) {
      _showSnack('重命名失败：$e');
    }
  }

  Future<void> _confirmDeleteGroup(HotwordGroup group) async {
    final id = group.id;
    if (id == null) return;
    final count = _entriesCache[id]?.length ?? 0;
    final ok = await _showConfirm(
      '删除分组',
      '确定删除分组「${group.name}」？'
      '${count > 0 ? '其中 $count 个词条将一并删除。' : ''}'
      '此操作不可撤销。',
    );
    if (ok != true) return;
    try {
      await _storage.deleteGroup(id);
      _expandedGroupIds.remove(id);
      await _loadAll();
      if (mounted) _showSnack('已删除分组');
    } catch (e) {
      _showSnack('删除失败：$e');
    }
  }

  // ============ 词条操作 ============

  Future<void> _showAddEntryDialog(HotwordGroup group) async {
    final id = group.id;
    if (id == null) return;
    final input = await _showEntryDialog(title: '添加词条');
    if (input == null) return;
    try {
      await _storage.insertEntry(HotwordEntry(
        groupId: id,
        word: input.word,
        weight: input.weight,
        createdAt: DateTime.now(),
      ));
      await _reloadGroupEntries(id);
      if (mounted) _showSnack('已添加「${input.word}」');
    } catch (e) {
      _showSnack('添加失败：$e');
    }
  }

  Future<void> _showEditEntryDialog(HotwordEntry entry) async {
    final id = entry.id;
    if (id == null) return;
    final input = await _showEntryDialog(
      title: '编辑词条',
      initialWord: entry.word,
      initialWeight: entry.weight,
    );
    if (input == null) return;
    if (input.word == entry.word &&
        (input.weight - entry.weight).abs() < 0.001) {
      return;
    }
    try {
      // HotwordStorage 未提供 updateEntry，用 delete + insert 等价实现。
      await _storage.deleteEntry(id);
      await _storage.insertEntry(HotwordEntry(
        groupId: entry.groupId,
        word: input.word,
        weight: input.weight,
        createdAt: DateTime.now(),
      ));
      await _reloadGroupEntries(entry.groupId);
      if (mounted) _showSnack('已更新「${input.word}」');
    } catch (e) {
      _showSnack('更新失败：$e');
      await _reloadGroupEntries(entry.groupId);
    }
  }

  Future<void> _deleteEntry(HotwordEntry entry) async {
    final id = entry.id;
    if (id == null) return;
    try {
      await _storage.deleteEntry(id);
      await _reloadGroupEntries(entry.groupId);
      if (mounted) _showSnack('已删除「${entry.word}」');
    } catch (e) {
      _showSnack('删除失败：$e');
      await _reloadGroupEntries(entry.groupId);
    }
  }

  // ============ 批量导入 / 导出 ============

  Future<void> _showImportDialog() async {
    final groups = await _storage.getGroups();
    if (!mounted) return;
    final result = await showDialog<_ImportResult>(
      context: context,
      builder: (_) => _ImportDialog(groups: groups),
    );
    if (result == null) return;
    try {
      int groupId;
      if (result.newGroupName != null) {
        groupId = await _storage.insertGroup(
          HotwordGroup(
            name: result.newGroupName!.trim(),
            createdAt: DateTime.now(),
          ),
        );
        _expandedGroupIds.add(groupId);
      } else {
        groupId = result.groupId!;
      }
      final count = await _storage.importFromText(groupId, result.text);
      await _loadAll();
      if (mounted) {
        _showSnack(count > 0 ? '已导入 $count 条词条' : '未识别到有效词条');
      }
    } catch (e) {
      _showSnack('导入失败：$e');
    }
  }

  Future<void> _exportAll() async {
    String outputDir;
    try {
      final picked = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择导出目录',
      );
      if (picked == null) return; // 用户取消
      outputDir = picked;
    } catch (_) {
      // 部分平台不支持目录选择，回退到应用文档目录下 exports/
      final appDir = await getApplicationDocumentsDirectory();
      outputDir = p.join(appDir.path, 'exports');
    }
    try {
      final path = await _dataManager.exportHotwordsAsText(outputDir);
      if (mounted) _showSnack('已导出到：$path');
    } catch (e) {
      _showSnack('导出失败：$e');
    }
  }

  // ============ UI 构建 ============

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('热词词库'),
        actions: [
          PopupMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (v) {
              switch (v) {
                case 'import':
                  _showImportDialog();
                case 'export':
                  _exportAll();
                case 'new_group':
                  _showCreateGroupDialog();
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'import',
                child: _MenuItem(icon: Icons.upload_file, label: '批量导入'),
              ),
              const PopupMenuItem(
                value: 'export',
                child: _MenuItem(icon: Icons.download_outlined, label: '导出全部'),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'new_group',
                child: _MenuItem(
                  icon: Icons.create_new_folder_outlined,
                  label: '新建分组',
                ),
              ),
            ],
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _groups.isEmpty
              ? _buildEmpty()
              : RefreshIndicator(
                  onRefresh: _loadAll,
                  child: ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                    itemCount: _groups.length,
                    itemBuilder: (ctx, i) => _buildGroupCard(_groups[i]),
                  ),
                ),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.library_books_outlined,
            size: 64,
            color: AppTheme.textSecondary.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            '暂无热词分组',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '热词可提升语音识别准确率\n点击下方按钮新建第一个分组',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textSecondary, height: 1.5),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _showCreateGroupDialog,
            icon: const Icon(Icons.add),
            label: const Text('新建分组'),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupCard(HotwordGroup group) {
    final id = group.id;
    if (id == null) {
      // 无 id 的分组（理论上不会出现，存储插入后均回填 id）仅展示名称。
      return Card(
        margin: const EdgeInsets.only(bottom: 12),
        child: ListTile(title: Text(group.name)),
      );
    }
    final entries = _entriesCache[id] ?? const [];
    final expanded = _expandedGroupIds.contains(id);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Column(
        children: [
          InkWell(
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
            onTap: () => setState(() {
              if (expanded) {
                _expandedGroupIds.remove(id);
              } else {
                _expandedGroupIds.add(id);
              }
            }),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    expanded ? Icons.expand_less : Icons.chevron_right,
                    color: AppTheme.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  Icon(Icons.folder_outlined,
                      color: AppTheme.accentColor, size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppTheme.textPrimary,
                          ),
                        ),
                        Text(
                          '$entries 个词条',
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    tooltip: '分组操作',
                    onSelected: (v) {
                      switch (v) {
                        case 'rename':
                          _showRenameGroupDialog(group);
                        case 'delete':
                          _confirmDeleteGroup(group);
                      }
                    },
                    itemBuilder: (ctx) => [
                      const PopupMenuItem(
                        value: 'rename',
                        child: _MenuItem(
                          icon: Icons.edit_outlined,
                          label: '重命名',
                        ),
                      ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: _MenuItem(
                          icon: Icons.delete_outline,
                          label: '删除',
                          color: Colors.redAccent,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (expanded) _buildEntriesList(id, entries),
        ],
      ),
    );
  }

  Widget _buildEntriesList(int groupId, List<HotwordEntry> entries) {
    return Column(
      children: [
        const Divider(height: 1),
        if (entries.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
            child: Text(
              '暂无词条，点击下方按钮添加',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
          )
        else
          ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(vertical: 4),
            itemCount: entries.length,
            itemBuilder: (ctx, i) {
              final e = entries[i];
              return Dismissible(
                key: ValueKey('entry_${e.id}'),
                direction: DismissDirection.endToStart,
                background: Container(
                  alignment: Alignment.centerRight,
                  padding: const EdgeInsets.only(right: 24),
                  color: Colors.redAccent.withValues(alpha: 0.15),
                  child: const Icon(Icons.delete_outline,
                      color: Colors.redAccent),
                ),
                onDismissed: (_) => _deleteEntry(e),
                child: ListTile(
                  dense: true,
                  leading: Icon(
                    Icons.tag_outlined,
                    color: AppTheme.textSecondary,
                    size: 18,
                  ),
                  title: Text(
                    e.word,
                    style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
                  ),
                  trailing: _buildWeightChip(e.weight),
                  onTap: () => _showEditEntryDialog(e),
                ),
              );
            },
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 8, 4),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _showAddEntryDialog(
                _groups.firstWhere((g) => g.id == groupId),
              ),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加词条'),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildWeightChip(double weight) {
    final highlighted = (weight - 1.0).abs() > 0.001;
    final color = highlighted ? AppTheme.accentColor : AppTheme.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '×${weight.toStringAsFixed(1)}',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  // ============ 通用对话框 ============

  Future<String?> _showTextDialog({
    required String title,
    required String hint,
    String? initial,
    String confirmText = '确定',
  }) async {
    final controller = TextEditingController(text: initial ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: hint),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: Text(confirmText),
          ),
        ],
      ),
    );
    controller.dispose();
    return result;
  }

  Future<bool?> _showConfirm(String title, String content) {
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
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('确定'),
          ),
        ],
      ),
    );
  }

  Future<_EntryInput?> _showEntryDialog({
    required String title,
    String? initialWord,
    double initialWeight = 1.0,
  }) async {
    final wordCtrl = TextEditingController(text: initialWord ?? '');
    final weightCtrl =
        TextEditingController(text: initialWeight.toStringAsFixed(1));
    final result = await showDialog<_EntryInput>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: wordCtrl,
              autofocus: true,
              decoration: const InputDecoration(hintText: '词条文本'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: weightCtrl,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                hintText: '权重（1.0-10.0，默认 1.0）',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final word = wordCtrl.text.trim();
              if (word.isEmpty) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('请输入词条文本')),
                );
                return;
              }
              final weight = double.tryParse(weightCtrl.text.trim());
              if (weight == null) {
                ScaffoldMessenger.of(ctx).showSnackBar(
                  const SnackBar(content: Text('权重需为数字')),
                );
                return;
              }
              Navigator.pop(
                ctx,
                _EntryInput(word: word, weight: weight.clamp(1.0, 10.0)),
              );
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
    wordCtrl.dispose();
    weightCtrl.dispose();
    return result;
  }

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }
}

/// 词条输入结果（新增 / 编辑对话框）。
class _EntryInput {
  final String word;
  final double weight;
  const _EntryInput({required this.word, required this.weight});
}

/// 批量导入对话框返回结果。
class _ImportResult {
  final int? groupId;
  final String? newGroupName;
  final String text;
  const _ImportResult({this.groupId, this.newGroupName, required this.text});
}

/// "新建分组" 在下拉框中使用的占位 id。
const int _kNewGroupSentinel = -1;

class _ImportDialog extends StatefulWidget {
  final List<HotwordGroup> groups;
  const _ImportDialog({required this.groups});

  @override
  State<_ImportDialog> createState() => _ImportDialogState();
}

class _ImportDialogState extends State<_ImportDialog> {
  final _textCtrl = TextEditingController();
  final _newGroupNameCtrl = TextEditingController();
  late int _target;

  @override
  void initState() {
    super.initState();
    _target = widget.groups.isNotEmpty
        ? widget.groups.first.id ?? _kNewGroupSentinel
        : _kNewGroupSentinel;
  }

  @override
  void dispose() {
    _textCtrl.dispose();
    _newGroupNameCtrl.dispose();
    super.dispose();
  }

  bool get _isNew => _target == _kNewGroupSentinel;

  int _validLineCount() {
    var n = 0;
    for (final raw in _textCtrl.text.split(RegExp(r'\r?\n'))) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      String word;
      final commaIdx = line.lastIndexOf(',');
      if (commaIdx > 0) {
        final maybeW = double.tryParse(line.substring(commaIdx + 1).trim());
        word = maybeW != null
            ? line.substring(0, commaIdx).trim()
            : line;
      } else {
        word = line;
      }
      if (word.isNotEmpty) n++;
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('批量导入词条'),
      content: SizedBox(
        width: double.maxFinite,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<int>(
              initialValue: _target,
              decoration: const InputDecoration(labelText: '目标分组'),
              items: [
                ...widget.groups.map(
                  (g) => DropdownMenuItem(value: g.id, child: Text(g.name)),
                ),
                const DropdownMenuItem(
                  value: _kNewGroupSentinel,
                  child: Text('➕ 新建分组'),
                ),
              ],
              onChanged: (v) => setState(() => _target = v ?? _kNewGroupSentinel),
            ),
            if (_isNew) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _newGroupNameCtrl,
                decoration: const InputDecoration(hintText: '新分组名称'),
              ),
            ],
            const SizedBox(height: 12),
            TextField(
              controller: _textCtrl,
              maxLines: 8,
              minLines: 4,
              decoration: const InputDecoration(
                hintText: '每行一个词，或 词,权重\n例如：\n张三\n人工智能,5.0',
              ),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _textCtrl,
              builder: (_, _, _) => Text(
                '已识别 ${_validLineCount()} 条有效词条',
                style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _onConfirm,
          child: const Text('导入'),
        ),
      ],
    );
  }

  void _onConfirm() {
    final text = _textCtrl.text;
    if (text.trim().isEmpty) return;
    if (_isNew) {
      final name = _newGroupNameCtrl.text.trim();
      if (name.isEmpty) return;
      Navigator.pop(
        context,
        _ImportResult(newGroupName: name, text: text),
      );
    } else {
      Navigator.pop(
        context,
        _ImportResult(groupId: _target, text: text),
      );
    }
  }
}

/// PopupMenuItem 内统一图标 + 文案。
class _MenuItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color? color;
  const _MenuItem({required this.icon, required this.label, this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}
