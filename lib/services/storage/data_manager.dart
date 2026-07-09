import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import 'package:nota/models/hotword.dart';
import 'package:nota/models/note.dart';
import 'package:nota/models/recording_session.dart';
import 'package:nota/models/speaker_profile.dart';
import 'package:nota/services/storage/database_helper.dart';
import 'package:nota/services/storage/hotword_storage.dart';
import 'package:nota/services/storage/note_storage.dart';
import 'package:nota/services/storage/recording_storage.dart';
import 'package:nota/services/storage/speaker_storage.dart';
import 'package:nota/services/storage/transcript_storage.dart';

/// 存储用量统计。
///
/// [sessionsSize] 所有会话目录总大小，[modelsSize] 模型文件总大小，
/// [cacheSize] 缓存总大小，[totalSize] 为三者之和。
class StorageUsage {
  final int sessionsSize;
  final int modelsSize;
  final int cacheSize;

  const StorageUsage({
    required this.sessionsSize,
    required this.modelsSize,
    required this.cacheSize,
  });

  int get totalSize => sessionsSize + modelsSize + cacheSize;

  /// 将总字节数格式化为人类可读的 B/KB/MB/GB 字符串。
  String formattedSize() => formatBytes(totalSize);

  /// 将字节数格式化为人类可读的 B/KB/MB/GB 字符串。
  static String formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }
}

/// 统一数据管理器（单例）。
///
/// 覆盖文件导入 / 导出 / 级联删除 / 存储清理 / 用量统计全生命周期，
/// 协调 RecordingStorage / TranscriptStorage / NoteStorage / SpeakerStorage /
/// HotwordStorage 五大存储类，并直接操作文件系统与 SQLite。
class DataManager {
  DataManager._();
  static final DataManager _instance = DataManager._();
  factory DataManager() => _instance;

  final RecordingStorage _recordingStorage = RecordingStorage();
  final TranscriptStorage _transcriptStorage = TranscriptStorage();
  final NoteStorage _noteStorage = NoteStorage();
  final SpeakerStorage _speakerStorage = SpeakerStorage();
  final HotwordStorage _hotwordStorage = HotwordStorage();
  final DatabaseHelper _dbHelper = DatabaseHelper();

  // ============ 导入 ============

  /// 从外部音频文件导入。
  ///
  /// [sourceFilePath] 外部音频文件路径（由调用方通过 file_picker 选择）。
  /// [title] 可选标题，为空时用文件名（去扩展名）。
  /// 创建会话目录 → 复制音频 → 写入 sessions 表 → 返回 RecordingSession。
  Future<RecordingSession> importAudioFile(
    String sourceFilePath, {
    String? title,
  }) async {
    final sourceFile = File(sourceFilePath);
    if (!sourceFile.existsSync()) {
      throw FileSystemException('源音频文件不存在', sourceFilePath);
    }

    final now = DateTime.now();
    final effectiveTitle = (title != null && title.isNotEmpty)
        ? title
        : p.basenameWithoutExtension(sourceFilePath);

    // 创建会话目录（复用 RecordingStorage 的命名逻辑）
    final sessionDirPath =
        await _recordingStorage.createSessionDir(now, effectiveTitle);

    // 复制音频文件到会话目录，保留原文件名
    final destPath = p.join(sessionDirPath, p.basename(sourceFilePath));
    await sourceFile.copy(destPath);

    final session = RecordingSession(
      id: now.millisecondsSinceEpoch.toString(),
      title: effectiveTitle,
      startTime: now,
      endTime: null,
      source: RecordingSource.mic,
      micAudioPath: destPath,
      speakerAudioPath: null,
      sessionDirPath: sessionDirPath,
      isPinned: false,
      createdAt: now,
    );
    await _recordingStorage.insertSession(session);
    return session;
  }

  /// 从 Markdown 文件导入笔记。
  ///
  /// 第一行 `# 标题` 提取为 title（无则用文件名），content 为全文。
  /// Note type=note, sessionId=""（独立笔记）。
  Future<Note> importNotesFromMarkdown(String mdFilePath) async {
    final file = File(mdFilePath);
    if (!file.existsSync()) {
      throw FileSystemException('Markdown 文件不存在', mdFilePath);
    }

    final content = await file.readAsString();
    final lines = content.split(RegExp(r'\r?\n'));

    String title;
    if (lines.isNotEmpty && lines[0].trimLeft().startsWith('# ')) {
      title = lines[0].trimLeft().substring(2).trim();
    } else {
      title = p.basenameWithoutExtension(mdFilePath);
    }

    final now = DateTime.now();
    final note = Note(
      sessionId: '',
      title: title.isEmpty ? p.basenameWithoutExtension(mdFilePath) : title,
      content: content,
      type: NoteType.note,
      createdAt: now,
      updatedAt: now,
    );
    await _noteStorage.insertNote(note);
    return note;
  }

  /// 从文本文件导入热词。
  ///
  /// 读取文件内容，创建以文件名（去扩展名）命名的新分组，
  /// 调用 HotwordStorage.importFromText 批量导入。返回导入条数。
  Future<int> importHotwordsFromText(String txtFilePath) async {
    final file = File(txtFilePath);
    if (!file.existsSync()) {
      throw FileSystemException('热词文件不存在', txtFilePath);
    }

    final content = await file.readAsString();
    final groupName = p.basenameWithoutExtension(txtFilePath);
    final groupId = await _hotwordStorage.insertGroup(
      HotwordGroup(name: groupName, createdAt: DateTime.now()),
    );
    return _hotwordStorage.importFromText(groupId, content);
  }

  /// 从 JSON 文件导入说话人配置。
  ///
  /// JSON 格式：对象数组，每个对象含 speaker_id / label? / embedding（数组或 JSON 字符串）/
  /// session_count?。返回导入条数。
  Future<int> importSpeakerConfig(String jsonFilePath) async {
    final file = File(jsonFilePath);
    if (!file.existsSync()) {
      throw FileSystemException('说话人配置文件不存在', jsonFilePath);
    }

    final content = await file.readAsString();
    final data = jsonDecode(content);
    final now = DateTime.now();

    List<Map<String, dynamic>> items;
    if (data is List) {
      items = data.cast<Map<String, dynamic>>();
    } else if (data is Map<String, dynamic>) {
      items = [data];
    } else {
      return 0;
    }

    for (final item in items) {
      final speaker = _parseSpeaker(item, now);
      await _speakerStorage.insertSpeaker(speaker);
    }
    return items.length;
  }

  /// 解析单个说话人 JSON 对象为 SpeakerProfile。
  ///
  /// embedding 支持数组（`[0.1, 0.2]`）或 JSON 字符串（`"[0.1,0.2]"`）两种格式。
  SpeakerProfile _parseSpeaker(Map<String, dynamic> m, DateTime now) {
    final rawEmbedding = m['embedding'];
    List<double> embedding;
    if (rawEmbedding is String) {
      embedding = (jsonDecode(rawEmbedding) as List)
          .map((e) => (e as num).toDouble())
          .toList();
    } else if (rawEmbedding is List) {
      embedding = rawEmbedding.map((e) => (e as num).toDouble()).toList();
    } else {
      embedding = const [];
    }

    return SpeakerProfile(
      speakerId: m['speaker_id'] as String,
      label: m['label'] as String?,
      embedding: embedding,
      sessionCount: m['session_count'] as int? ?? 0,
      createdAt: now,
      updatedAt: now,
    );
  }

  // ============ 导出 ============

  /// 导出单会话为 zip。
  ///
  /// 包含会话目录下所有文件（音频等）+ 转写 JSON + 关联笔记 MD + 会话元信息。
  /// 保存到 outputDir/{sessionTitle}.zip，返回 zip 文件路径。
  Future<String> exportSessionAsZip(
    String sessionId,
    String outputDir,
  ) async {
    final session = await _recordingStorage.getSession(sessionId);
    if (session == null) {
      throw ArgumentError('会话不存在: $sessionId');
    }

    await Directory(outputDir).create(recursive: true);
    final zipPath = p.join(outputDir, '${_sanitizeName(session.title)}.zip');

    final archive = Archive();

    // 1. 会话目录下的所有文件
    if (session.sessionDirPath != null) {
      final dir = Directory(session.sessionDirPath!);
      if (dir.existsSync()) {
        await for (final entity
            in dir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            final relative = p.relative(entity.path, from: dir.path);
            final bytes = await entity.readAsBytes();
            archive.addFile(ArchiveFile(relative, bytes.length, bytes));
          }
        }
      }
    }

    // 2. 转写段落 JSON
    final segments = await _transcriptStorage.getSegments(sessionId);
    if (segments.isNotEmpty) {
      final transcriptJson = const JsonEncoder.withIndent('  ').convert({
        'session_id': sessionId,
        'segments': segments.map((s) => s.toMap()).toList(),
      });
      final bytes = utf8.encode(transcriptJson);
      archive.addFile(ArchiveFile('transcript.json', bytes.length, bytes));
    }

    // 3. 关联笔记
    final notes = await _noteStorage.getNotesBySession(sessionId);
    for (final note in notes) {
      final bytes = utf8.encode(_noteToMarkdown(note));
      archive.addFile(ArchiveFile(
        p.join('notes', '${_sanitizeName(note.title)}.md'),
        bytes.length,
        bytes,
      ));
    }

    // 4. 会话元信息
    final metaBytes = utf8.encode(
      const JsonEncoder.withIndent('  ').convert(session.toMap()),
    );
    archive.addFile(ArchiveFile('session.json', metaBytes.length, metaBytes));

    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes != null) {
      await File(zipPath).writeAsBytes(zipBytes);
    }
    return zipPath;
  }

  /// 导出笔记为 Markdown 文件。
  ///
  /// 写入 outputDir/{title}.md，返回文件路径。
  Future<String> exportNoteAsMarkdown(String noteId, String outputDir) async {
    final id = int.parse(noteId);
    final note = await _noteStorage.getNote(id);
    if (note == null) {
      throw ArgumentError('笔记不存在: $noteId');
    }

    await Directory(outputDir).create(recursive: true);
    final filePath = p.join(outputDir, '${_sanitizeName(note.title)}.md');
    await File(filePath).writeAsString(_noteToMarkdown(note));
    return filePath;
  }

  /// 导出热词为文本文件。
  ///
  /// 调用 HotwordStorage.exportAsText，写入 outputDir/hotwords.txt。
  Future<String> exportHotwordsAsText(String outputDir) async {
    await Directory(outputDir).create(recursive: true);
    final text = await _hotwordStorage.exportAsText();
    final filePath = p.join(outputDir, 'hotwords.txt');
    await File(filePath).writeAsString(text);
    return filePath;
  }

  /// 全量备份。
  ///
  /// 遍历所有会话导出为 zip 内容 + 所有笔记为 MD + 热词文本，
  /// 打包为一个 backup_{timestamp}.zip。返回 zip 文件路径。
  Future<String> exportAllAsBackup(String outputDir) async {
    await Directory(outputDir).create(recursive: true);
    final stamp = _formatStamp(DateTime.now());
    final zipPath = p.join(outputDir, 'backup_$stamp.zip');

    final archive = Archive();

    // 1. 所有会话（音频 + 转写 + 元信息）
    final sessions = await _recordingStorage.getSessions();
    for (final session in sessions) {
      final prefix = 'sessions/${_sanitizeName(session.title)}_${session.id}';

      // 会话目录文件
      if (session.sessionDirPath != null) {
        final dir = Directory(session.sessionDirPath!);
        if (dir.existsSync()) {
          await for (final entity
              in dir.list(recursive: true, followLinks: false)) {
            if (entity is File) {
              final relative = p.relative(entity.path, from: dir.path);
              final bytes = await entity.readAsBytes();
              archive.addFile(
                ArchiveFile('$prefix/$relative', bytes.length, bytes),
              );
            }
          }
        }
      }

      // 转写段落
      final segments = await _transcriptStorage.getSegments(session.id);
      if (segments.isNotEmpty) {
        final j = const JsonEncoder.withIndent('  ')
            .convert(segments.map((s) => s.toMap()).toList());
        final bytes = utf8.encode(j);
        archive.addFile(
          ArchiveFile('$prefix/transcript.json', bytes.length, bytes),
        );
      }

      // 会话元信息
      final metaBytes = utf8.encode(
        const JsonEncoder.withIndent('  ').convert(session.toMap()),
      );
      archive.addFile(
        ArchiveFile('$prefix/session.json', metaBytes.length, metaBytes),
      );
    }

    // 2. 所有笔记为 MD
    final notes = await _noteStorage.getNotes();
    for (final note in notes) {
      final bytes = utf8.encode(_noteToMarkdown(note));
      archive.addFile(
        ArchiveFile(
          p.join('notes', '${_sanitizeName(note.title)}.md'),
          bytes.length,
          bytes,
        ),
      );
    }

    // 3. 热词
    final hotwordText = await _hotwordStorage.exportAsText();
    final hotwordBytes = utf8.encode(hotwordText);
    archive.addFile(
      ArchiveFile('hotwords.txt', hotwordBytes.length, hotwordBytes),
    );

    final zipBytes = ZipEncoder().encode(archive);
    if (zipBytes != null) {
      await File(zipPath).writeAsBytes(zipBytes);
    }
    return zipPath;
  }

  // ============ 级联删除 ============

  /// 级联删除会话及所有关联数据。
  ///
  /// 删除会话目录及文件 → 删除转写段落 → 删除关联笔记 → 删除会话记录。
  /// 返回删除的文件数。
  Future<int> cascadeDeleteSession(String sessionId) async {
    final session = await _recordingStorage.getSession(sessionId);
    int deletedFiles = 0;

    // 1. 删除会话目录及所有文件
    if (session?.sessionDirPath != null) {
      final dir = Directory(session!.sessionDirPath!);
      if (dir.existsSync()) {
        await for (final entity
            in dir.list(recursive: true, followLinks: false)) {
          if (entity is File) {
            deletedFiles++;
          }
        }
        await dir.delete(recursive: true);
      }
    }

    // 2. 删除转写段落
    await _transcriptStorage.deleteBySession(sessionId);

    // 3. 删除关联笔记（NoteStorage 无 deleteBySession，直接 SQL）
    final db = await _dbHelper.database;
    await db.delete('notes', where: 'session_id = ?', whereArgs: [sessionId]);

    // 4. 删除会话记录
    await _recordingStorage.deleteSession(sessionId);

    return deletedFiles;
  }

  // ============ 存储清理 ============

  /// 扫描孤立文件。
  ///
  /// 遍历 recordings/ 目录下所有子目录，检查是否在 sessions 表中有对应记录。
  /// 返回孤立目录路径列表。
  Future<List<String>> scanOrphanFiles() async {
    final rootPath = await _recordingsRootPath();
    final root = Directory(rootPath);
    if (!root.existsSync()) return [];

    // 获取所有有效的会话目录路径
    final sessions = await _recordingStorage.getSessions();
    final validPaths = sessions
        .where((s) => s.sessionDirPath != null)
        .map((s) => s.sessionDirPath!)
        .toSet();

    final orphans = <String>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is Directory && !validPaths.contains(entity.path)) {
        orphans.add(entity.path);
      }
    }
    return orphans;
  }

  /// 清理孤立文件。
  ///
  /// 调用 scanOrphanFiles，删除所有孤立目录。返回清理的字节数。
  Future<int> cleanOrphanFiles() async {
    final orphans = await scanOrphanFiles();
    int totalBytes = 0;
    for (final path in orphans) {
      totalBytes += await _getDirectorySize(path);
      final dir = Directory(path);
      if (dir.existsSync()) {
        await dir.delete(recursive: true);
      }
    }
    return totalBytes;
  }

  /// 扫描模型缓存大小（models/ 目录）。
  Future<int> scanModelCache() async {
    final path = await _modelsRootPath();
    final dir = Directory(path);
    if (!dir.existsSync()) return 0;
    return _getDirectorySize(path);
  }

  /// 清理模型缓存。
  ///
  /// 删除 models/ 目录及全部内容。返回清理的字节数。
  Future<int> cleanModelCache() async {
    final path = await _modelsRootPath();
    final dir = Directory(path);
    if (!dir.existsSync()) return 0;
    final size = await _getDirectorySize(path);
    await dir.delete(recursive: true);
    return size;
  }

  // ============ 存储用量统计 ============

  /// 获取存储用量统计。
  Future<StorageUsage> getStorageUsage() async {
    // 会话目录总大小
    final recordingsPath = await _recordingsRootPath();
    final recordingsDir = Directory(recordingsPath);
    int sessionsSize = 0;
    if (recordingsDir.existsSync()) {
      sessionsSize = await _getDirectorySize(recordingsPath);
    }

    // 模型文件总大小
    final modelsSize = await scanModelCache();

    // 缓存总大小
    final cachePath = await _cacheRootPath();
    final cacheDir = Directory(cachePath);
    int cacheSize = 0;
    if (cacheDir.existsSync()) {
      cacheSize = await _getDirectorySize(cachePath);
    }

    return StorageUsage(
      sessionsSize: sessionsSize,
      modelsSize: modelsSize,
      cacheSize: cacheSize,
    );
  }

  /// 递归计算目录大小（字节）。
  Future<int> _getDirectorySize(String path) async {
    final dir = Directory(path);
    if (!dir.existsSync()) return 0;
    int total = 0;
    await for (final entity in dir.list(recursive: true, followLinks: false)) {
      if (entity is File) {
        total += await entity.length();
      }
    }
    return total;
  }

  // ============ 私有辅助 ============

  /// 获取录音根目录路径（与 RecordingStorage 一致：dirname(getDatabasesPath)/recordings）。
  Future<String> _recordingsRootPath() async {
    final dbPath = await getDatabasesPath();
    return p.join(p.dirname(dbPath), 'recordings');
  }

  /// 获取模型目录路径（应用文档目录/models）。
  Future<String> _modelsRootPath() async {
    final appDir = await getApplicationDocumentsDirectory();
    return p.join(appDir.path, 'models');
  }

  /// 获取缓存目录路径（应用文档目录/cache）。
  Future<String> _cacheRootPath() async {
    final appDir = await getApplicationDocumentsDirectory();
    return p.join(appDir.path, 'cache');
  }

  /// 将笔记转换为 Markdown 文本。
  ///
  /// 若 content 已以 `# ` 开头则直接返回（避免重复标题），否则前置 `# {title}`。
  String _noteToMarkdown(Note note) {
    if (note.content.trimLeft().startsWith('# ')) {
      return note.content;
    }
    return '# ${note.title}\n\n${note.content}';
  }

  /// 替换文件名非法字符为下划线。
  String _sanitizeName(String name) {
    return name.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  }

  /// 格式化时间戳为 YYYYMMDD_HHmmss。
  String _formatStamp(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${t.year}${two(t.month)}${two(t.day)}_'
        '${two(t.hour)}${two(t.minute)}${two(t.second)}';
  }
}
