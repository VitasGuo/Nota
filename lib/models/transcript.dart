import 'dart:convert';

/// 转写片段数据模型。
///
/// 表示 ASR 引擎返回的单个转写片段，同时作为持久化存储单元。
/// - 时间以秒（double）存储，便于 SQLite REAL 列与排序；
///   通过 [startDuration] / [endDuration] 提供 Duration 视图供 ASR 引擎使用。
/// - [originalText] 为 ASR 原文，[correctedText] / [translation] 后续填充。
/// - [text] / [speaker] 为兼容 getter，等价于 [originalText] / [speakerId]。
///
/// 由 [AsrEngine.transcribe] 产出，由 TranscriptStorage 持久化。
class TranscriptSegment {
  final int? id;
  final String sessionId;
  final double startTime;
  final double endTime;
  final String? speakerId;
  final String originalText;
  final String? correctedText;
  final String? translation;

  const TranscriptSegment({
    this.id,
    required this.sessionId,
    required this.startTime,
    required this.endTime,
    this.speakerId,
    required this.originalText,
    this.correctedText,
    this.translation,
  });

  // —— 兼容 ASR 引擎的便捷访问 ——

  /// 起始时间（Duration 视图）。
  Duration get startDuration =>
      Duration(milliseconds: (startTime * 1000).round());

  /// 结束时间（Duration 视图）。
  Duration get endDuration =>
      Duration(milliseconds: (endTime * 1000).round());

  /// 起始时间戳（毫秒）。
  int get startMs => (startTime * 1000).round();

  /// 结束时间戳（毫秒）。
  int get endMs => (endTime * 1000).round();

  /// 转写文本（[originalText] 的别名）。
  String get text => originalText;

  /// 说话人标识（[speakerId] 的别名）。
  String? get speaker => speakerId;

  /// 是否已标注说话人。
  bool get hasSpeaker => speakerId != null && speakerId!.isNotEmpty;

  TranscriptSegment copyWith({
    int? id,
    String? sessionId,
    double? startTime,
    double? endTime,
    String? speakerId,
    String? originalText,
    String? correctedText,
    String? translation,
  }) {
    return TranscriptSegment(
      id: id ?? this.id,
      sessionId: sessionId ?? this.sessionId,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      speakerId: speakerId ?? this.speakerId,
      originalText: originalText ?? this.originalText,
      correctedText: correctedText ?? this.correctedText,
      translation: translation ?? this.translation,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'session_id': sessionId,
      'start_time': startTime,
      'end_time': endTime,
      'speaker_id': speakerId,
      'original_text': originalText,
      'corrected_text': correctedText,
      'translation': translation,
    };
  }

  factory TranscriptSegment.fromMap(Map<String, dynamic> map) {
    return TranscriptSegment(
      id: map['id'] as int?,
      sessionId: map['session_id'] as String,
      startTime: (map['start_time'] as num).toDouble(),
      endTime: (map['end_time'] as num).toDouble(),
      speakerId: map['speaker_id'] as String?,
      originalText: map['original_text'] as String,
      correctedText: map['corrected_text'] as String?,
      translation: map['translation'] as String?,
    );
  }

  @override
  String toString() =>
      'TranscriptSegment(${startMs}ms-${endMs}ms${hasSpeaker ? ' [$speakerId]' : ''}: $originalText)';
}

/// 转写结果：一个会话的全部片段集合。
///
/// 不直接持久化为单行，而是由 [TranscriptSegment] 列表聚合而来。
/// 提供 encode/decode 用于内存中的 JSON 序列化（如缓存/传输）。
class Transcript {
  final String sessionId;
  final List<TranscriptSegment> segments;
  final DateTime createdAt;
  final DateTime updatedAt;

  const Transcript({
    required this.sessionId,
    required this.segments,
    required this.createdAt,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() {
    return {
      'session_id': sessionId,
      'segments': segments.map((s) => s.toMap()).toList(),
      'created_at': createdAt.toIso8601String(),
      'updated_at': updatedAt.toIso8601String(),
    };
  }

  factory Transcript.fromMap(Map<String, dynamic> map) {
    return Transcript(
      sessionId: map['session_id'] as String,
      segments: (map['segments'] as List)
          .map((e) => TranscriptSegment.fromMap(e as Map<String, dynamic>))
          .toList(),
      createdAt: DateTime.parse(map['created_at'] as String),
      updatedAt: DateTime.parse(map['updated_at'] as String),
    );
  }

  String encode() => jsonEncode(toMap());

  static Transcript decode(String source) =>
      Transcript.fromMap(jsonDecode(source) as Map<String, dynamic>);
}
