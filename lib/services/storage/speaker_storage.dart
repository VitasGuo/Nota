import 'dart:convert';
import 'dart:math';

import 'package:nota/models/speaker_profile.dart';
import 'package:nota/services/storage/database_helper.dart';

/// 说话人声纹存储（单例）。
///
/// 负责 speakers 表 CRUD 与跨会话余弦相似度匹配。
/// [embedding] 以 JSON 文本持久化。
class SpeakerStorage {
  SpeakerStorage._();
  static final SpeakerStorage _instance = SpeakerStorage._();
  factory SpeakerStorage() => _instance;

  final DatabaseHelper _dbHelper = DatabaseHelper();

  Future<int> insertSpeaker(SpeakerProfile speaker) async {
    final db = await _dbHelper.database;
    return db.insert('speakers', speaker.toMap());
  }

  Future<List<SpeakerProfile>> getSpeakers() async {
    final db = await _dbHelper.database;
    final rows =
        await db.query('speakers', orderBy: 'created_at DESC');
    return rows.map(SpeakerProfile.fromMap).toList();
  }

  Future<SpeakerProfile?> getSpeaker(String speakerId) async {
    final db = await _dbHelper.database;
    final rows = await db.query(
      'speakers',
      where: 'speaker_id = ?',
      whereArgs: [speakerId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return SpeakerProfile.fromMap(rows.first);
  }

  Future<int> updateLabel(String speakerId, String label) async {
    final db = await _dbHelper.database;
    return db.update('speakers', {
      'label': label,
      'updated_at': DateTime.now().toIso8601String(),
    }, where: 'speaker_id = ?', whereArgs: [speakerId]);
  }

  Future<int> updateEmbedding(
      String speakerId, List<double> embedding) async {
    final db = await _dbHelper.database;
    return db.update('speakers', {
      'embedding': _encodeEmbedding(embedding),
      'updated_at': DateTime.now().toIso8601String(),
    }, where: 'speaker_id = ?', whereArgs: [speakerId]);
  }

  Future<int> incrementSessionCount(String speakerId) async {
    final speaker = await getSpeaker(speakerId);
    if (speaker == null) return 0;
    final db = await _dbHelper.database;
    return db.update('speakers', {
      'session_count': speaker.sessionCount + 1,
      'updated_at': DateTime.now().toIso8601String(),
    }, where: 'speaker_id = ?', whereArgs: [speakerId]);
  }

  Future<int> deleteSpeaker(int id) async {
    final db = await _dbHelper.database;
    return db.delete('speakers', where: 'id = ?', whereArgs: [id]);
  }

  /// 在声纹库中查找与给定向量余弦相似度最高且超过 [threshold] 的说话人。
  ///
  /// 返回匹配到的 [SpeakerProfile]，无满足阈值者返回 null。
  Future<SpeakerProfile?> findBestMatch(
      List<double> embedding, double threshold) async {
    final speakers = await getSpeakers();
    SpeakerProfile? best;
    double bestScore = -1.0;
    for (final sp in speakers) {
      if (sp.embedding.isEmpty) continue;
      final score = _cosineSimilarity(embedding, sp.embedding);
      if (score > bestScore) {
        bestScore = score;
        best = sp;
      }
    }
    if (best != null && bestScore >= threshold) return best;
    return null;
  }

  /// 余弦相似度：a·b / (|a|·|b|)。
  double _cosineSimilarity(List<double> a, List<double> b) {
    if (a.length != b.length || a.isEmpty) return 0.0;
    double dot = 0.0;
    double normA = 0.0;
    double normB = 0.0;
    for (var i = 0; i < a.length; i++) {
      dot += a[i] * b[i];
      normA += a[i] * a[i];
      normB += b[i] * b[i];
    }
    if (normA == 0.0 || normB == 0.0) return 0.0;
    return dot / (sqrt(normA) * sqrt(normB));
  }

  String _encodeEmbedding(List<double> embedding) => jsonEncode(embedding);
}
