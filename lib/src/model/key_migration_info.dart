/// Status of a database-wide key re-encryption migration.
enum KeyMigrationStatus {
  running,
  completed,
  failed;

  static KeyMigrationStatus fromString(String value) {
    switch (value) {
      case 'running':
        return KeyMigrationStatus.running;
      case 'completed':
        return KeyMigrationStatus.completed;
      case 'failed':
        return KeyMigrationStatus.failed;
      default:
        return KeyMigrationStatus.running;
    }
  }

  String toJsonValue() => name;
}

/// Persisted metadata for an in-progress or completed key migration.
class KeyMigrationInfo {
  final int targetKeyId;
  final KeyMigrationStatus status;
  final String createdAt;

  const KeyMigrationInfo({
    required this.targetKeyId,
    required this.status,
    required this.createdAt,
  });

  bool get isRunning => status == KeyMigrationStatus.running;

  factory KeyMigrationInfo.fromJson(Map<String, dynamic> json) {
    return KeyMigrationInfo(
      targetKeyId: json['targetKeyId'] as int,
      status:
          KeyMigrationStatus.fromString(json['status'] as String? ?? 'running'),
      createdAt: json['createdAt'] as String,
    );
  }

  Map<String, dynamic> toJson() => {
        'targetKeyId': targetKeyId,
        'status': status.toJsonValue(),
        'createdAt': createdAt,
      };

  KeyMigrationInfo copyWith({
    int? targetKeyId,
    KeyMigrationStatus? status,
    String? createdAt,
  }) {
    return KeyMigrationInfo(
      targetKeyId: targetKeyId ?? this.targetKeyId,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}
