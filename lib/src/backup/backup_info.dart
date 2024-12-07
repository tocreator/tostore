/// 备份信息
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

  /// 获取备份类型描述
  String get type => isIncremental ? '增量备份' : '完整备份';

  /// 获取格式化的大小
  String get formattedSize {
    if (size < 1024) return '$size B';
    if (size < 1024 * 1024) return '${(size / 1024).toStringAsFixed(2)} KB';
    if (size < 1024 * 1024 * 1024) {
      return '${(size / (1024 * 1024)).toStringAsFixed(2)} MB';
    }
    return '${(size / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
  }

  /// 从 JSON 创建
  factory BackupInfo.fromJson(Map<String, dynamic> json) {
    return BackupInfo(
      path: json['path'] as String,
      timestamp: DateTime.parse(json['timestamp'] as String),
      isIncremental: json['isIncremental'] as bool,
      size: json['size'] as int,
    );
  }

  /// 转换为 JSON
  Map<String, dynamic> toJson() {
    return {
      'path': path,
      'timestamp': timestamp.toIso8601String(),
      'isIncremental': isIncremental,
      'size': size,
    };
  }
}
