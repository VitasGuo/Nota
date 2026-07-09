import 'dart:convert';

/// 说话人声纹档案。
///
/// [speakerId] 为逻辑标识（speaker_0、speaker_1 等），[label] 为用户自定义标签名。
/// [embedding] 为声纹嵌入向量，持久化时序列化为 JSON 文本，用于跨会话余弦相似度匹配。
class SpeakerProfile {
  final int? id;
  final String speakerId;
  final String? label;
  final List<double> embedding;
  final int sessionCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  const SpeakerProfile({
    this.id,
    required this.speakerId,
    this.label,
    this.embedding = const [],
    this.sessionCount = 0,
    required this.createdAt,
    required this.updatedAt,
  });

  SpeakerProfile copyWith({
    int? id,
    String? speakerId,
    String? label,
    List<double>? embedding,
    int? sessionCount,
    DateTime? createdAt,
    DateTime? updatedAt,
  }) {
    return SpeakerProfile(
      id: id ?? this.id,
      speakerId: speakerId ?? this.speakerId,
      label: label ?? this.label,
      embedding: embedding ?? this.embedding,
      sessionCount: sessionCount ?? this.sessionCount,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'speaker_id': speakerId,
      'label': label,
      'embedding': jsonEncode(embedding),
      'session_count': sessionCount,
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory SpeakerProfile.fromMap(Map<String, dynamic> map) {
    return SpeakerProfile(
      id: map['id'] as int?,
      speakerId: map['speaker_id'] as String,
      label: map['label'] as String?,
      embedding: (jsonDecode(map['embedding'] as String) as List)
          .map((e) => (e as num).toDouble())
          .toList(),
      sessionCount: map['session_count'] as int,
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  String encode() => jsonEncode(toMap());

  static SpeakerProfile decode(String source) =>
      SpeakerProfile.fromMap(jsonDecode(source) as Map<String, dynamic>);
}
