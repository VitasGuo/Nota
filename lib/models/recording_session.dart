import 'dart:convert';

/// 录音来源：麦克风 / 扬声器内录 / 双轨。
enum RecordingSource { mic, speaker, dual }

/// 录音会话。
///
/// 一次录音对应一条会话记录，id 为时间戳字符串，
/// 关联 mic/speaker 两路音频文件与会话目录。
class RecordingSession {
  final String id;
  final String title;
  final DateTime startTime;
  final DateTime? endTime;
  final RecordingSource source;
  final String? micAudioPath;
  final String? speakerAudioPath;
  final String? sessionDirPath;
  final bool isPinned;
  final DateTime createdAt;

  const RecordingSession({
    required this.id,
    required this.title,
    required this.startTime,
    this.endTime,
    required this.source,
    this.micAudioPath,
    this.speakerAudioPath,
    this.sessionDirPath,
    this.isPinned = false,
    required this.createdAt,
  });

  RecordingSession copyWith({
    String? id,
    String? title,
    DateTime? startTime,
    DateTime? endTime,
    RecordingSource? source,
    String? micAudioPath,
    String? speakerAudioPath,
    String? sessionDirPath,
    bool? isPinned,
    DateTime? createdAt,
  }) {
    return RecordingSession(
      id: id ?? this.id,
      title: title ?? this.title,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
      source: source ?? this.source,
      micAudioPath: micAudioPath ?? this.micAudioPath,
      speakerAudioPath: speakerAudioPath ?? this.speakerAudioPath,
      sessionDirPath: sessionDirPath ?? this.sessionDirPath,
      isPinned: isPinned ?? this.isPinned,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'start_time': startTime.toIso8601String(),
      'end_time': endTime?.toIso8601String(),
      'source': source.name,
      'mic_audio_path': micAudioPath,
      'speaker_audio_path': speakerAudioPath,
      'session_dir_path': sessionDirPath,
      'is_pinned': isPinned ? 1 : 0,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory RecordingSession.fromMap(Map<String, dynamic> map) {
    return RecordingSession(
      id: map['id'] as String,
      title: map['title'] as String,
      startTime: DateTime.parse(map['start_time'] as String),
      endTime: map['end_time'] == null
          ? null
          : DateTime.parse(map['end_time'] as String),
      source: RecordingSource.values.byName(map['source'] as String),
      micAudioPath: map['mic_audio_path'] as String?,
      speakerAudioPath: map['speaker_audio_path'] as String?,
      sessionDirPath: map['session_dir_path'] as String?,
      isPinned: (map['is_pinned'] as int) == 1,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  String encode() => jsonEncode(toMap());

  static RecordingSession decode(String source) =>
      RecordingSession.fromMap(jsonDecode(source) as Map<String, dynamic>);
}
