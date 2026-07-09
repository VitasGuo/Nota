import 'dart:convert';

/// 笔记类型：纪要 / 普通笔记 / 待办。
enum NoteType { summary, note, todo }

/// 笔记。
///
/// 由 LLM 整理或用户手写，正文为 Markdown。
/// [tags] 存为 `List<String>`，持久化时序列化为 JSON 文本。
class Note {
  final int? id;
  final String sessionId;
  final String title;
  final String content;
  final String? summary;
  final NoteType type;
  final List<String> tags;
  final String? category;
  final bool isPinned;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Note({
    this.id,
    required this.sessionId,
    required this.title,
    required this.content,
    this.summary,
    required this.type,
    this.tags = const [],
    this.category,
    this.isPinned = false,
    required this.createdAt,
    required this.updatedAt,
  });

  Note copyWith({
    int? id,
    String? sessionId,
    String? title,
    String? content,
    String? summary,
    NoteType? type,
    List<String>? tags,
    String? category,
    bool? isPinned,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return Note(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      title: title ?? this.title,
      content: content ?? this.content,
      summary: summary ?? this.summary,
      type: type ?? this.type,
      tags: tags ?? this.tags,
      category: category ?? this.category,
      isPinned: isPinned ?? this.isPinned,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'session_id': sessionId,
      'title': title,
      'content': content,
      'summary': summary,
      'type': type.name,
      'tags': jsonEncode(tags),
      'category': category,
      'is_pinned': isPinned ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Note.fromMap(Map<String, dynamic> map) {
    return Note(
      id: map['id'] as int?,
      sessionId: map['session_id'] as String,
      title: map['title'] as String,
      content: map['content'] as String,
      summary: map['summary'] as String?,
      type: NoteType.values.byName(map['type'] as String),
      tags: (jsonDecode(map['tags'] as String) as List)
          .map((e) => e as String)
          .toList(),
      category: map['category'] as String?,
      isPinned: (map['is_pinned'] as int) == 1,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  String encode() => jsonEncode(toMap());

  static Note decode(String source) =>
      Note.fromMap(jsonDecode(source) as Map<String, dynamic>);
}
