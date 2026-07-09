import 'package:nota/models/transcript.dart';
import 'package:nota/services/storage/database_helper.dart';

/// 转写段落存储（单例）。
///
/// 负责 transcripts 表 CRUD，按 [sessionId] 关联录音会话。
class TranscriptStorage {
  TranscriptStorage._();
  static final TranscriptStorage _instance = TranscriptStorage._();
  factory TranscriptStorage() => _instance;

  final DatabaseHelper _dbHelper = DatabaseHelper();

  Future<int> insertSegment(TranscriptSegment segment) async {
    final db = await _dbHelper.database;
    return db.insert('transcripts', segment.toMap());
  }

  /// 批量插入转写段落（单事务）。
  Future<void> insertSegments(List<TranscriptSegment> segments) async {
    if (segments.isEmpty) return;
    final db = await _dbHelper.database;
    final batch = db.batch();
    for (final seg in segments) {
      batch.insert('transcripts', seg.toMap());
    }
    await batch.commit(noResult: true);
  }

  /// 按 startTime 升序查询某会话的全部段落。
  Future<List<TranscriptSegment>> getSegments(String sessionId) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'transcripts',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'start_time ASC',
    );
    return rows.map(TranscriptSegment.fromMap).toList();
  }

  Future<int> updateCorrectedText(int id, String correctedText) async {
    final db = await _dbHelper.database;
    return db.update('transcripts', {'corrected_text': correctedText},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<int> updateTranslation(int id, String translation) async {
    final db = await _dbHelper.database;
    return db.update('transcripts', {'translation': translation},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<int> updateSpeakerId(int id, String speakerId) async {
    final db = await _dbHelper.database;
    return db.update('transcripts', {'speaker_id': speakerId},
        where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deleteBySession(String sessionId) async {
    final db = await _dbHelper.database;
    return db.delete('transcripts',
        where: 'session_id = ?', whereArgs: [sessionId]);
  }
}
