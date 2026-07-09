import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart' as p;

/// SQLite 数据库管理（单例）。
///
/// 负责数据库创建、版本管理与 schema 初始化。
/// 数据库文件 `nota.db`，当前版本 1，包含 6 张表：
/// sessions / transcripts / notes / speakers / hotword_groups / hotwords。
class DatabaseHelper {
  DatabaseHelper._();
  static final DatabaseHelper _instance = DatabaseHelper._();
  factory DatabaseHelper() => _instance;

  static const String _dbName = 'nota.db';
  static const int _dbVersion = 1;

  Database? _db;

  /// 获取数据库实例（懒加载）。
  Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dbPath = await getDatabasesPath();
    final path = p.join(dbPath, _dbName);
    return openDatabase(
      path,
      version: _dbVersion,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    final batch = db.batch();
    // 录音会话
    batch.execute('''
      CREATE TABLE sessions (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        start_time TEXT NOT NULL,
        end_time TEXT,
        source TEXT NOT NULL,
        mic_audio_path TEXT,
        speaker_audio_path TEXT,
        session_dir_path TEXT,
        is_pinned INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL
      )
    ''');
    // 转写段落
    batch.execute('''
      CREATE TABLE transcripts (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        start_time REAL NOT NULL,
        end_time REAL NOT NULL,
        speaker_id TEXT,
        original_text TEXT NOT NULL,
        corrected_text TEXT,
        translation TEXT
      )
    ''');
    // 笔记
    batch.execute('''
      CREATE TABLE notes (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        session_id TEXT NOT NULL,
        title TEXT NOT NULL,
        content TEXT NOT NULL,
        summary TEXT,
        type TEXT NOT NULL,
        tags TEXT NOT NULL,
        category TEXT,
        is_pinned INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    // 说话人声纹
    batch.execute('''
      CREATE TABLE speakers (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        speaker_id TEXT NOT NULL,
        label TEXT,
        embedding TEXT NOT NULL,
        session_count INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      )
    ''');
    // 热词分组
    batch.execute('''
      CREATE TABLE hotword_groups (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        description TEXT,
        created_at TEXT NOT NULL
      )
    ''');
    // 热词词条
    batch.execute('''
      CREATE TABLE hotwords (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        group_id INTEGER NOT NULL,
        word TEXT NOT NULL,
        weight REAL NOT NULL DEFAULT 1.0,
        created_at TEXT NOT NULL,
        FOREIGN KEY (group_id) REFERENCES hotword_groups(id)
      )
    ''');
    await batch.commit(noResult: true);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // 预留：后续版本在此追加迁移 SQL。
  }
}
