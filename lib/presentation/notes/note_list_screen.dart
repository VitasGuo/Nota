import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:nota/core/theme.dart';
import 'package:nota/models/note.dart';
import 'package:nota/presentation/notes/note_detail_screen.dart';
import 'package:nota/services/storage/note_storage.dart';

/// 笔记列表页。
///
/// 顶部搜索栏（title/content/tags）+ 分类筛选（全部/笔记/纪要）+ 笔记卡片列表。
/// 置顶笔记置顶显示，其余按创建时间倒序。点击进入详情，长按弹出操作菜单。
class NoteListScreen extends StatefulWidget {
  const NoteListScreen({super.key});

  @override
  State<NoteListScreen> createState() => _NoteListScreenState();
}

class _NoteListScreenState extends State<NoteListScreen> {
  final NoteStorage _storage = NoteStorage();
  final TextEditingController _searchController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  List<Note> _allNotes = [];
  List<Note> _filteredNotes = [];
  bool _isLoading = true;
  String _query = '';
  /// null = 全部；NoteType.note = 笔记；NoteType.summary = 纪要
  NoteType? _filter;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _loadNotes();
  }

  @override
  void dispose() {
    _searchController.dispose();
    _scrollController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  Future<void> _loadNotes() async {
    try {
      final notes = _query.isEmpty
          ? await _storage.getNotes()
          : await _storage.searchNotes(_query);
      if (mounted) {
        setState(() {
          _allNotes = notes;
          _applyFilter();
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

  /// 应用分类筛选并排序：置顶在前，其余按 createdAt 倒序。
  void _applyFilter() {
    var list = _allNotes.where((n) {
      if (_filter == null) return true;
      return n.type == _filter;
    }).toList();
    list.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      return b.createdAt.compareTo(a.createdAt);
    });
    _filteredNotes = list;
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (_query != value.trim()) {
        _query = value.trim();
        _loadNotes();
      }
    });
  }

  void _setFilter(NoteType? filter) {
    setState(() {
      _filter = filter;
      _applyFilter();
    });
  }

  Future<void> _togglePin(Note note) async {
    await _storage.togglePin(note.id!);
    _loadNotes();
    _showSnack(note.isPinned ? '已取消置顶' : '已置顶');
  }

  Future<void> _deleteNote(Note note) async {
    final confirmed = await _confirmDialog('删除笔记', '确定删除「${note.title}」？此操作不可撤销。');
    if (confirmed != true) return;
    await _storage.deleteNote(note.id!);
    _loadNotes();
    _showSnack('已删除');
  }

  Future<void> _exportMarkdown(Note note) async {
    final md = _noteToMarkdown(note);
    final fileName = _sanitizeName(note.title);
    String? savedPath;

    // 优先保存到应用文档目录（跨平台稳定），并通过 SnackBar 展示路径
    try {
      final dir = await getApplicationDocumentsDirectory();
      final exportsDir = Directory(p.join(dir.path, 'exports'));
      if (!exportsDir.existsSync()) {
        await exportsDir.create(recursive: true);
      }
      final path = p.join(exportsDir.path, '$fileName.md');
      await File(path).writeAsString(md);
      savedPath = path;
    } catch (e) {
      _showSnack('导出失败：$e');
      return;
    }
    _showSnack('已导出到：$savedPath');
  }

  String _noteToMarkdown(Note note) {
    if (note.content.trimLeft().startsWith('# ')) return note.content;
    return '# ${note.title}\n\n${note.content}';
  }

  String _sanitizeName(String name) =>
      name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  void _openDetail(Note note) {
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => NoteDetailScreen(noteId: note.id!),
      ),
    ).then((_) => _loadNotes());
  }

  void _showCardMenu(Note note) {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(note.isPinned
                  ? Icons.bookmark_border
                  : Icons.bookmark),
              title: Text(note.isPinned ? '取消置顶' : '置顶'),
              onTap: () {
                Navigator.pop(ctx);
                _togglePin(note);
              },
            ),
            ListTile(
              leading: const Icon(Icons.download_outlined),
              title: const Text('导出为 .md'),
              onTap: () {
                Navigator.pop(ctx);
                _exportMarkdown(note);
              },
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline, color: Colors.redAccent),
              title: const Text('删除', style: TextStyle(color: Colors.redAccent)),
              onTap: () {
                Navigator.pop(ctx);
                _deleteNote(note);
              },
            ),
          ],
        ),
      ),
    );
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
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            _buildSearchBar(),
            _buildFilterChips(),
            const Divider(height: 1),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 32, 24, 8),
      child: Row(
        children: [
          Text(
            '笔记',
            style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary,
            ),
          ),
          const Spacer(),
          IconButton(
            icon: const Icon(Icons.refresh),
            color: AppTheme.textSecondary,
            onPressed: _loadNotes,
          ),
        ],
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: TextField(
        controller: _searchController,
        onChanged: _onSearchChanged,
        style: TextStyle(color: AppTheme.textPrimary),
        decoration: InputDecoration(
          hintText: '搜索标题、正文、标签…',
          prefixIcon: Icon(Icons.search, color: AppTheme.textSecondary),
          suffixIcon: _query.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () {
                    _searchController.clear();
                    _query = '';
                    _loadNotes();
                  },
                ),
        ),
      ),
    );
  }

  Widget _buildFilterChips() {
    final chips = <(String, NoteType?)>[
      ('全部', null),
      ('笔记', NoteType.note),
      ('纪要', NoteType.summary),
    ];
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: chips.map((c) {
          final selected = _filter == c.$2;
          return Padding(
            padding: const EdgeInsets.only(right: 8),
            child: FilterChip(
              label: Text(c.$1),
              selected: selected,
              onSelected: (_) => _setFilter(c.$2),
              selectedColor: AppTheme.accentColor,
              labelStyle: TextStyle(
                color: selected ? Colors.white : AppTheme.textSecondary,
              ),
              backgroundColor: AppTheme.cardColor,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_filteredNotes.isEmpty) {
      return _buildEmpty();
    }
    return ListView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: _filteredNotes.length,
      itemBuilder: (ctx, i) => _buildNoteCard(_filteredNotes[i]),
    );
  }

  Widget _buildEmpty() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.note_add_outlined,
            size: 64,
            color: AppTheme.textSecondary.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 16),
          Text(
            '暂无笔记',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: AppTheme.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _query.isEmpty ? '录音转写后会自动生成笔记' : '没有匹配的笔记，换个关键词试试',
            style: TextStyle(color: AppTheme.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildNoteCard(Note note) {
    final colorLabel = _typeColorLabel(note.type);
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: () => _openDetail(note),
        onLongPress: () => _showCardMenu(note),
        child: Row(
          children: [
            // 左侧分类色条
            Container(
              width: 4,
              height: 88,
              decoration: BoxDecoration(
                color: colorLabel.$1,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(4),
                  bottomLeft: Radius.circular(4),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (note.isPinned)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Icon(
                              Icons.push_pin,
                              size: 14,
                              color: AppTheme.accentColor,
                            ),
                          ),
                        Expanded(
                          child: Text(
                            note.title.isEmpty ? '（无标题）' : note.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: AppTheme.textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        _buildTypeBadge(colorLabel),
                        const SizedBox(width: 8),
                        Text(
                          _formatDate(note.createdAt),
                          style: TextStyle(
                            fontSize: 12,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _preview(note.content),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 13,
                        color: AppTheme.textSecondary,
                        height: 1.4,
                      ),
                    ),
                    if (note.tags.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: note.tags
                            .map((t) => _buildTagChip(t))
                            .toList(),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeBadge((Color, String) cl) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: cl.$1.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        cl.$2,
        style: TextStyle(fontSize: 11, color: cl.$1, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildTagChip(String tag) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: AppTheme.accentColor.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '# $tag',
        style: TextStyle(
          fontSize: 11,
          color: AppTheme.accentColor,
        ),
      ),
    );
  }

  /// 笔记类型 → (颜色, 中文标签)。
  (Color, String) _typeColorLabel(NoteType type) {
    switch (type) {
      case NoteType.note:
        return (const Color(0xFF4A90D9), '笔记');
      case NoteType.summary:
        return (const Color(0xFF52A373), '纪要');
      case NoteType.todo:
        return (const Color(0xFFE0A23C), '待办');
    }
  }

  /// 提取正文预览：去除 Markdown 标记，截取前 100 字。
  String _preview(String content) {
    var text = content
        .replaceAll(RegExp(r'^#+\s*', multiLine: true), '')
        .replaceAll(RegExp(r'\*\*([^*]+)\*\*'), r'$1')
        .replaceAll(RegExp(r'\*([^*]+)\*'), r'$1')
        .replaceAll(RegExp(r'`([^`]+)`'), r'$1')
        .replaceAll(RegExp(r'^[-*+]\s+', multiLine: true), '')
        .replaceAll(RegExp(r'^>\s*', multiLine: true), '')
        .replaceAll(RegExp(r'^\s*\[[ xX]\]\s*', multiLine: true), '')
        .replaceAll(RegExp(r'\n+'), ' ')
        .trim();
    if (text.length > 100) text = '${text.substring(0, 100)}…';
    return text;
  }

  String _formatDate(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }
}
