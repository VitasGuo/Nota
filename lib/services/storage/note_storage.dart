import 'package:nota/models/note.dart';
import 'package:nota/services/storage/database_helper.dart';

/// 笔记存储（单例）。
///
/// 负责 notes 表 CRUD，支持标签 / 分类 / 全文搜索。
/// [tags] 以 JSON 文本持久化，标签查询用 LIKE 近似匹配。
class NoteStorage {
  NoteStorage._();
  static final NoteStorage _instance = NoteStorage._();
  factory NoteStorage() => _instance;

  final DatabaseHelper _dbHelper = DatabaseHelper();

  Future<int> insertNote(Note note) async {
    final db = await _dbHelper.database;
    return db.insert('notes', note.toMap());
  }

  /// 全部笔记，按 updated_at 倒序。
  Future<List<Note>> getNotes() async {
    final db = await _dbHelper.database;
    final rows = await db.query('notes', orderBy: 'updated_at DESC');
    return rows.map(Note.fromMap).toList();
  }

  Future<Note?> getNote(int id) async {
    final db = await _dbHelper.database;
    final rows =
        await db.query('notes', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return Note.fromMap(rows.first);
  }

  Future<List<Note>> getNotesBySession(String sessionId) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'notes',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'updated_at DESC',
    );
    return rows.map(Note.fromMap).toList();
  }

  Future<int> updateNote(Note note) async {
    final db = await _dbHelper.database;
    return db.update('notes', note.toMap(),
        where: 'id = ?', whereArgs: [note.id]);
  }

  Future<int> deleteNote(int id) async {
    final db = await _dbHelper.database;
    return db.delete('notes', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> togglePin(int id) async {
    final note = await getNote(id);
    if (note == null) return 0;
    final db = await _dbHelper.database;
    return db.update('notes', {'is_pinned': note.isPinned ? 0 : 1},
        where: 'id = ?', whereArgs: [id]);
  }

  /// 在 title / content / tags 中 LIKE 搜索。
  Future<List<Note>> searchNotes(String query) async {
    final db = await _dbHelper.database;
    final pattern = '%$query%';
    final rows = await db.query(
      'notes',
      where: 'title LIKE ? OR content LIKE ? OR tags LIKE ?',
      whereArgs: [pattern, pattern, pattern],
      orderBy: 'updated_at DESC',
    );
    return rows.map(Note.fromMap).toList();
  }

  Future<List<Note>> getNotesByCategory(String category) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'notes',
      where: 'category = ?',
      whereArgs: [category],
      orderBy: 'updated_at DESC',
    );
    return rows.map(Note.fromMap).toList();
  }

  /// 按标签查询（tags 为 JSON 文本，用 LIKE 近似匹配）。
  Future<List<Note>> getNotesByTag(String tag) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'notes',
      where: 'tags LIKE ?',
      whereArgs: ['%"$tag"%'],
      orderBy: 'updated_at DESC',
    );
    return rows.map(Note.fromMap).toList();
  }
}
