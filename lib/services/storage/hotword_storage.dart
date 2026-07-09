import 'package:nota/models/hotword.dart';
import 'package:nota/services/storage/database_helper.dart';

/// 热词词库存储（单例）。
///
/// 负责 hotword_groups / hotwords 两表 CRUD，支持文本批量导入导出。
/// 删除分组时级联删除其下全部词条。
class HotwordStorage {
  HotwordStorage._();
  static final HotwordStorage _instance = HotwordStorage._();
  factory HotwordStorage() => _instance;

  final DatabaseHelper _dbHelper = DatabaseHelper();

  // —— 分组 ——

  Future<int> insertGroup(HotwordGroup group) async {
    final db = await _dbHelper.database;
    return db.insert('hotword_groups', group.toMap());
  }

  Future<List<HotwordGroup>> getGroups() async {
    final db = await _dbHelper.database;
    final rows =
        await db.query('hotword_groups', orderBy: 'created_at DESC');
    return rows.map(HotwordGroup.fromMap).toList();
  }

  Future<int> updateGroup(HotwordGroup group) async {
    final db = await _dbHelper.database;
    return db.update('hotword_groups', group.toMap(),
        where: 'id = ?', whereArgs: [group.id]);
  }

  /// 删除分组并级联删除其下全部词条。
  Future<void> deleteGroup(int id) async {
    final db = await _dbHelper.database;
    final batch = db.batch();
    batch.delete('hotwords', where: 'group_id = ?', whereArgs: [id]);
    batch.delete('hotword_groups', where: 'id = ?', whereArgs: [id]);
    await batch.commit(noResult: true);
  }

  // —— 词条 ——

  Future<int> insertEntry(HotwordEntry entry) async {
    final db = await _dbHelper.database;
    return db.insert('hotwords', entry.toMap());
  }

  Future<List<HotwordEntry>> getEntries(int groupId) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'hotwords',
      where: 'group_id = ?',
      whereArgs: [groupId],
      orderBy: 'created_at ASC',
    );
    return rows.map(HotwordEntry.fromMap).toList();
  }

  /// 全部热词，用于 ASR boosting / 纠错参考。
  Future<List<HotwordEntry>> getAllEntries() async {
    final db = await _dbHelper.database;
    final rows = await db.query('hotwords', orderBy: 'created_at ASC');
    return rows.map(HotwordEntry.fromMap).toList();
  }

  Future<int> deleteEntry(int id) async {
    final db = await _dbHelper.database;
    return db.delete('hotwords', where: 'id = ?', whereArgs: [id]);
  }

  // —— 导入导出 ——

  /// 导出为文本格式：每行一个词，权重非 1.0 时写 "词,权重"。
  ///
  /// 仅导出词条（不含分组信息），适合跨设备迁移词库。
  Future<String> exportAsText() async {
    final entries = await getAllEntries();
    final lines = <String>[];
    for (final e in entries) {
      if ((e.weight - 1.0).abs() < 0.001) {
        lines.add(e.word);
      } else {
        lines.add('${e.word},${e.weight}');
      }
    }
    return lines.join('\n');
  }

  /// 从文本批量导入词条到指定分组。
  ///
  /// 每行一个词，可选 "词,权重" 格式；空行跳过。
  /// 返回导入条数。
  Future<int> importFromText(int groupId, String text) async {
    final lines = text.split(RegExp(r'\r?\n'));
    final now = DateTime.now();
    final entries = <HotwordEntry>[];
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      String word;
      double weight = 1.0;
      final commaIdx = line.lastIndexOf(',');
      if (commaIdx > 0) {
        final maybeWeight = double.tryParse(line.substring(commaIdx + 1).trim());
        if (maybeWeight != null) {
          word = line.substring(0, commaIdx).trim();
          weight = maybeWeight;
        } else {
          word = line;
        }
      } else {
        word = line;
      }
      if (word.isEmpty) continue;
      entries.add(HotwordEntry(
        groupId: groupId,
        word: word,
        weight: weight,
        createdAt: now,
      ));
    }
    if (entries.isEmpty) return 0;
    final db = await _dbHelper.database;
    final batch = db.batch();
    for (final e in entries) {
      batch.insert('hotwords', e.toMap());
    }
    await batch.commit(noResult: true);
    return entries.length;
  }
}
