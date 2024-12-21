/// backup info
class BackupInfo {
  final String path;
  final DateTime timestamp;
  final bool isIncremental;
  final int size;

  BackupInfo({
    required this.path,
    required this.timestamp,
    required this.isIncremental,
    required this.size,
  });

  /// get backup type description
  String get type => isIncremental ? 'incremental backup' : 'full backup';

  /// get formatted size
  String get formattedSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(2)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// create from json
  factory BackupInfo.fromJson(Map<String, dynamic> json) {
    return BackupInfo(
      path: json['path'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      isIncremental: json['isIncremental'] as bool,
      size: json['size'] as int,
    );
  }

  /// convert to json
  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'timestamp': timestamp.toIso8601String(),
      'isIncremental': isIncremental,
      'size': size,
    };
  }
}
