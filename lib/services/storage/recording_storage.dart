import 'dart:io';

import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

import 'package:nota/models/recording_session.dart';
import 'package:nota/services/storage/database_helper.dart';

/// 录音会话存储（单例）。
///
/// 负责 sessions 表 CRUD 与会话目录管理。
/// 会话目录命名：`recordings/{YYYYMMDD_HHmmss}_{title}/`。
class RecordingStorage {
  RecordingStorage._();
  static final RecordingStorage _instance = RecordingStorage._();
  factory RecordingStorage() => _instance;

  final DatabaseHelper _dbHelper = DatabaseHelper();

  /// 获取录音根目录（app 数据目录下的 recordings/），不存在则创建。
  Future<Directory> _recordingsRoot() async {
    final dbPath = await getDatabasesPath();
    final root = Directory(p.join(p.dirname(dbPath), 'recordings'));
    if (!root.existsSync()) await root.create(recursive: true);
    return root;
  }

  /// 创建会话目录并返回绝对路径。
  ///
  /// 命名格式：`{YYYYMMDD_HHmmss}_{title}`，title 中的非法文件名字符会被替换为下划线。
  Future<String> createSessionDir(DateTime startTime, String title) async {
    final root = await _recordingsRoot();
    final stamp = _formatStamp(startTime);
    final safeTitle = _sanitize(title);
    final dir = Directory(p.join(root.path, '${stamp}_$safeTitle'));
    if (!dir.existsSync()) await dir.create(recursive: true);
    return dir.path;
  }

  String _formatStamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}_'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }

  String _sanitize(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  Future<int> insertSession(RecordingSession session) async {
    final db = await _dbHelper.database;
    return db.insert('sessions', session.toMap(),
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<RecordingSession>> getSessions() async {
    final db = await _dbHelper.database;
    final rows = await db.query('sessions', orderBy: 'created_at DESC');
    return rows.map(RecordingSession.fromMap).toList();
  }

  Future<RecordingSession?> getSession(String id) async {
    final db = await _dbHelper.database;
    final rows =
        await db.query('sessions', where: 'id = ?', whereArgs: [id], limit: 1);
    if (rows.isEmpty) return null;
    return RecordingSession.fromMap(rows.first);
  }

  Future<int> updateSession(RecordingSession session) async {
    final db = await _dbHelper.database;
    return db.update('sessions', session.toMap(),
        where: 'id = ?', whereArgs: [session.id]);
  }

  Future<int> deleteSession(String id) async {
    final db = await _dbHelper.database;
    return db.delete('sessions', where: 'id = ?', whereArgs: [id]);
  }

  Future<int> updateTitle(String id, String title) async {
    final db = await _dbHelper.database;
    return db.update('sessions', {'title': title},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<int> togglePin(String id) async {
    final session = await getSession(id);
    if (session == null) return 0;
    final db = await _dbHelper.database;
    return db.update('sessions', {'is_pinned': session.isPinned ? 0 : 1},
        where: 'id = ?', whereArgs: [id]);
  }
}
