import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:nota/core/theme.dart';
import 'package:nota/models/note.dart';
import 'package:nota/services/storage/note_storage.dart';

/// 笔记详情页。
///
/// 接收 [noteId]，支持 Markdown 渲染、可交互 checklist 勾选、查看/编辑模式切换、
/// 导出为 .md / 复制到剪贴板，以及关联转写跳转（sessionId 非空时）。
class NoteDetailScreen extends StatefulWidget {
  final int noteId;

  const NoteDetailScreen({super.key, required this.noteId});

  @override
  State<NoteDetailScreen> createState() => _NoteDetailScreenState();
}

class _NoteDetailScreenState extends State<NoteDetailScreen> {
  final NoteStorage _storage = NoteStorage();
  final TextEditingController _editController = TextEditingController();
  final ScrollController _editScrollController = ScrollController();
  final ScrollController _viewScrollController = ScrollController();

  Note? _note;
  bool _loading = true;
  bool _isEditing = false;

  /// 待办事项行匹配：`[空格]` 或 `- [x]`/`- [X]`，支持 `-`/`*`/`+` 与缩进。
  static final _checklistRegex =
      RegExp(r'^(\s*)([-*+])\s+\[([ xX])\]\s*(.*)$');

  @override
  void initState() {
    super.initState();
    _loadNote();
  }

  @override
  void dispose() {
    _editController.dispose();
    _editScrollController.dispose();
    _viewScrollController.dispose();
    super.dispose();
  }

  Future<void> _loadNote() async {
    try {
      final note = await _storage.getNote(widget.noteId);
      if (mounted) {
        setState(() {
          _note = note;
          _loading = false;
          if (note != null) _editController.text = note.content;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _loading = false);
        _showSnack('加载失败：$e');
      }
    }
  }

  Future<void> _persistContent(String newContent) async {
    final n = _note;
    if (n == null) return;
    final updated = n.copyWith(
      content: newContent,
      updatedAt: DateTime.now(),
    );
    await _storage.updateNote(updated);
    setState(() => _note = updated);
  }

  /// 切换某行的 checklist 状态并持久化。
  Future<void> _toggleChecklist(int lineIndex) async {
    final n = _note;
    if (n == null) return;
    final lines = n.content.split('\n');
    if (lineIndex < 0 || lineIndex >= lines.length) return;
    final line = lines[lineIndex];
    if (line.contains('[ ]')) {
      lines[lineIndex] = line.replaceFirst('[ ]', '[x]');
    } else {
      lines[lineIndex] = line.replaceFirst(RegExp(r'\[[xX]\]'), '[ ]');
    }
    await _persistContent(lines.join('\n'));
  }

  void _toggleEditMode() {
    setState(() {
      _isEditing = !_isEditing;
      if (_isEditing && _note != null) {
        _editController.text = _note!.content;
      } else if (!_isEditing && _note != null) {
        // 退出编辑时若内容变化则持久化
        if (_editController.text != _note!.content) {
          _persistContent(_editController.text);
        }
      }
    });
  }

  Future<void> _exportMarkdown() async {
    final n = _note;
    if (n == null) return;
    final md = _noteToMarkdown(n);
    final fileName = _sanitizeName(n.title);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final exportsDir = Directory(p.join(dir.path, 'exports'));
      if (!exportsDir.existsSync()) {
        await exportsDir.create(recursive: true);
      }
      final path = p.join(exportsDir.path, '$fileName.md');
      await File(path).writeAsString(md);
      _showSnack('已导出到：$path');
    } catch (e) {
      _showSnack('导出失败：$e');
    }
  }

  Future<void> _copyToClipboard() async {
    final n = _note;
    if (n == null) return;
    await Clipboard.setData(ClipboardData(text: _noteToMarkdown(n)));
    _showSnack('已复制到剪贴板');
  }

  void _viewTranscript() {
    // TranscriptScreen 尚未实现，先提示用户。
    _showSnack('转写界面开发中');
  }

  String _noteToMarkdown(Note note) {
    if (note.content.trimLeft().startsWith('# ')) return note.content;
    return '# ${note.title}\n\n${note.content}';
  }

  String _sanitizeName(String name) =>
      name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');

  void _showSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: _buildAppBar(),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _note == null
              ? _buildNotFound()
              : _isEditing
                  ? _buildEditMode()
                  : _buildViewMode(),
    );
  }

  PreferredSizeWidget _buildAppBar() {
    return AppBar(
      title: Text(
        _note?.title ?? '笔记详情',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      actions: [
        if (_note != null) ...[
          IconButton(
            icon: Icon(_isEditing ? Icons.visibility : Icons.edit),
            tooltip: _isEditing ? '查看' : '编辑',
            onPressed: _toggleEditMode,
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            onSelected: (v) {
              switch (v) {
                case 'export':
                  _exportMarkdown();
                case 'copy':
                  _copyToClipboard();
                case 'transcript':
                  _viewTranscript();
              }
            },
            itemBuilder: (_) {
              final items = <PopupMenuEntry<String>>[
                const PopupMenuItem(
                  value: 'export',
                  child: ListTile(
                    leading: Icon(Icons.download_outlined),
                    title: Text('导出为 .md'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                const PopupMenuItem(
                  value: 'copy',
                  child: ListTile(
                    leading: Icon(Icons.copy_outlined),
                    title: Text('复制到剪贴板'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ];
              if (_note != null && _note!.sessionId.isNotEmpty) {
                items.add(const PopupMenuDivider());
                items.add(const PopupMenuItem(
                  value: 'transcript',
                  child: ListTile(
                    leading: Icon(Icons.record_voice_over_outlined),
                    title: Text('查看转写'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ));
              }
              return items;
            },
          ),
        ],
      ],
    );
  }

  Widget _buildNotFound() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.inbox_outlined,
              size: 64, color: AppTheme.textSecondary.withValues(alpha: 0.4)),
          const SizedBox(height: 16),
          Text('笔记不存在或已被删除',
              style: TextStyle(color: AppTheme.textSecondary)),
        ],
      ),
    );
  }

  // ============ 查看模式 ============

  Widget _buildViewMode() {
    final note = _note!;
    return ListView(
      controller: _viewScrollController,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        _buildMeta(note),
        const SizedBox(height: 16),
        ..._buildContentBlocks(note.content),
      ],
    );
  }

  Widget _buildMeta(Note note) {
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _buildTypeBadge(note.type),
        Text(
          _formatDate(note.createdAt),
          style: TextStyle(fontSize: 12, color: AppTheme.textSecondary),
        ),
        if (note.tags.isNotEmpty)
          Wrap(
            spacing: 6,
            runSpacing: 4,
            children: note.tags
                .map((t) => Text(
                      '# $t',
                      style: TextStyle(
                        fontSize: 12,
                        color: AppTheme.accentColor,
                      ),
                    ))
                .toList(),
          ),
      ],
    );
  }

  Widget _buildTypeBadge(NoteType type) {
    final (color, label) = _typeColorLabel(type);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(label,
          style: TextStyle(
              fontSize: 11, color: color, fontWeight: FontWeight.w600)),
    );
  }

  /// 渲染正文：按行拆分，checklist 行渲染为可交互项，其余行分组用 Markdown 渲染。
  List<Widget> _buildContentBlocks(String content) {
    if (content.trim().isEmpty) {
      return [
        Center(
          child: Padding(
            padding: const EdgeInsets.only(top: 60),
            child: Text('（空笔记）',
                style: TextStyle(color: AppTheme.textSecondary)),
          ),
        ),
      ];
    }

    final lines = content.split('\n');
    final blocks = <Widget>[];
    final buffer = <String>[];

    void flushBuffer() {
      if (buffer.isEmpty) return;
      final text = buffer.join('\n');
      buffer.clear();
      if (text.trim().isEmpty) return;
      blocks.add(MarkdownBody(
        data: text,
        styleSheet: _markdownStyle(),
        shrinkWrap: true,
      ));
      blocks.add(const SizedBox(height: 8));
    }

    for (var i = 0; i < lines.length; i++) {
      final match = _checklistRegex.firstMatch(lines[i]);
      if (match != null) {
        flushBuffer();
        blocks.add(_buildChecklistItem(i, match));
        blocks.add(const SizedBox(height: 4));
      } else {
        buffer.add(lines[i]);
      }
    }
    flushBuffer();

    if (blocks.isNotEmpty && blocks.last is SizedBox) {
      blocks.removeLast();
    }
    return blocks;
  }

  Widget _buildChecklistItem(int lineIndex, RegExpMatch match) {
    final indent = match.group(1) ?? '';
    final checked = (match.group(3) ?? ' ').toLowerCase() == 'x';
    final text = match.group(4) ?? '';
    return Padding(
      padding: EdgeInsets.only(left: indent.length * 8.0),
      child: InkWell(
        onTap: () => _toggleChecklist(lineIndex),
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 4),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(
                  checked
                      ? Icons.check_box
                      : Icons.check_box_outline_blank,
                  size: 20,
                  color: checked
                      ? AppTheme.accentColor
                      : AppTheme.textSecondary,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: MarkdownBody(
                  data: text,
                  styleSheet: _markdownStyle().copyWith(
                    p: TextStyle(
                      color: checked
                          ? AppTheme.textSecondary
                          : AppTheme.textPrimary,
                      fontSize: 15,
                      decoration:
                          checked ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  shrinkWrap: true,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  MarkdownStyleSheet _markdownStyle() {
    final isLight = AppTheme.currentBrightness == Brightness.light;
    return MarkdownStyleSheet(
      p: TextStyle(
        color: AppTheme.textPrimary,
        fontSize: 15,
        height: 1.6,
      ),
      h1: TextStyle(
        color: AppTheme.textPrimary,
        fontSize: 24,
        fontWeight: FontWeight.bold,
      ),
      h2: TextStyle(
        color: AppTheme.textPrimary,
        fontSize: 20,
        fontWeight: FontWeight.bold,
      ),
      h3: TextStyle(
        color: AppTheme.textPrimary,
        fontSize: 17,
        fontWeight: FontWeight.w600,
      ),
      listBullet: TextStyle(color: AppTheme.textSecondary),
      blockquote: TextStyle(
        color: AppTheme.textSecondary,
        fontSize: 14,
      ),
      blockquoteDecoration: BoxDecoration(
        color: AppTheme.accentColor.withValues(alpha: 0.08),
        border: Border(
          left: BorderSide(color: AppTheme.accentColor, width: 3),
        ),
        borderRadius: BorderRadius.circular(4),
      ),
      code: TextStyle(
        color: AppTheme.accentColor,
        backgroundColor: (isLight ? const Color(0xFFEEE6F5) : const Color(0xFF241F30)),
        fontSize: 13,
        fontFamily: 'monospace',
      ),
      codeblockDecoration: BoxDecoration(
        color: isLight ? const Color(0xFFF3EEF8) : const Color(0xFF1A1625),
        borderRadius: BorderRadius.circular(8),
      ),
      codeblockPadding: const EdgeInsets.all(12),
      tableHead: TextStyle(
        color: AppTheme.textPrimary,
        fontWeight: FontWeight.w600,
      ),
      tableBody: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
      tableBorder: TableBorder.all(
        color: AppTheme.textSecondary.withValues(alpha: 0.3),
        width: 0.5,
      ),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          top: BorderSide(
            color: AppTheme.textSecondary.withValues(alpha: 0.3),
            width: 0.5,
          ),
        ),
      ),
    );
  }

  // ============ 编辑模式：上方编辑 40% + 下方预览 60% ============

  Widget _buildEditMode() {
    return Column(
      children: [
        Expanded(
          flex: 2,
          child: _buildEditor(),
        ),
        const Divider(height: 1),
        Expanded(
          flex: 3,
          child: _buildLivePreview(),
        ),
      ],
    );
  }

  Widget _buildEditor() {
    return Container(
      color: AppTheme.surfaceColor,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: TextField(
        controller: _editController,
        scrollController: _editScrollController,
        maxLines: null,
        expands: true,
        style: TextStyle(
          color: AppTheme.textPrimary,
          fontSize: 14,
          fontFamily: 'monospace',
          height: 1.5,
        ),
        decoration: InputDecoration(
          hintText: '输入 Markdown 内容…',
          border: InputBorder.none,
          contentPadding: EdgeInsets.zero,
        ),
        onChanged: (_) => setState(() {}),
      ),
    );
  }

  Widget _buildLivePreview() {
    final text = _editController.text;
    return Container(
      color: AppTheme.cardColor,
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(
            '预览',
            style: TextStyle(
              fontSize: 12,
              color: AppTheme.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 8),
          if (text.trim().isEmpty)
            Text('（无内容）', style: TextStyle(color: AppTheme.textSecondary))
          else
            MarkdownBody(
              data: text,
              styleSheet: _markdownStyle(),
              shrinkWrap: true,
            ),
        ],
      ),
    );
  }

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

  String _formatDate(DateTime dt) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${dt.year}-${two(dt.month)}-${two(dt.day)} ${two(dt.hour)}:${two(dt.minute)}';
  }
}
