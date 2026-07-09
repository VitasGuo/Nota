/// 热词分组（人名 / 术语 / 常用词）。
class HotwordGroup {
  final int? id;
  final String name;
  final String? description;
  final DateTime createdAt;

  const HotwordGroup({
    this.id,
    required this.name,
    this.description,
    required this.createdAt,
  });

  HotwordGroup copyWith({
    int? id,
    String? name,
    String? description,
    DateTime? createdAt,
  }) {
    return HotwordGroup(
      id: id ?? this.id,
      name: name ?? this.name,
      description: description ?? this.description,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'description': description,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory HotwordGroup.fromMap(Map<String, dynamic> map) {
    return HotwordGroup(
      id: map['id'] as int?,
      name: map['name'] as String,
      description: map['description'] as String?,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}

/// 热词词条。
///
/// [weight] 取值 1.0-10.0，默认 1.0，用于 ASR boosting。
class HotwordEntry {
  final int? id;
  final int groupId;
  final String word;
  final double weight;
  final DateTime createdAt;

  const HotwordEntry({
    this.id,
    required this.groupId,
    required this.word,
    this.weight = 1.0,
    required this.createdAt,
  });

  HotwordEntry copyWith({
    int? id,
    int? groupId,
    String? word,
    double? weight,
    DateTime? createdAt,
  }) {
    return HotwordEntry(
      id: id ?? this.id,
      groupId: groupId ?? this.groupId,
      word: word ?? this.word,
      weight: weight ?? this.weight,
      createdAt: createdAt ?? this.createdAt,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'group_id': groupId,
      'word': word,
      'weight': weight,
      'created_at': createdAt.toIso8601String(),
    };
  }

  factory HotwordEntry.fromMap(Map<String, dynamic> map) {
    return HotwordEntry(
      id: map['id'] as int?,
      groupId: map['group_id'] as int,
      word: map['word'] as String,
      weight: (map['weight'] as num).toDouble(),
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }
}
