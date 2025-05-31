/// migration system meta
class MigrationMeta {
  /// current available directory index
  final int currentDirIndex;

  /// directory file count statistics {dirIndex: fileCount}
  final Map<int, int> dirUsage;

  /// task location index {taskId: dirIndex}
  final Map<String, int> taskIndex;

  const MigrationMeta({
    required this.currentDirIndex,
    required this.dirUsage,
    required this.taskIndex,
  });

  factory MigrationMeta.initial() => const MigrationMeta(
        currentDirIndex: 0,
        dirUsage: {0: 0},
        taskIndex: {},
      );

  /// get the task directory path
  String getTaskDir(int dirIndex) => 'migration_$dirIndex';

  /// convert to json
  Map<String, dynamic> toJson() => {
        'currentDirIndex': currentDirIndex,
        'dirUsage': Map<String, dynamic>.from(
            dirUsage.map((k, v) => MapEntry(k.toString(), v))),
        'taskIndex': Map<String, dynamic>.from(taskIndex),
      };

  /// create from json
  factory MigrationMeta.fromJson(Map<String, dynamic> json) => MigrationMeta(
        currentDirIndex: json['currentDirIndex'] as int,
        dirUsage: (json['dirUsage'] as Map<dynamic, dynamic>)
            .map((k, v) => MapEntry(int.parse(k.toString()), v as int)),
        taskIndex: (json['taskIndex'] as Map<dynamic, dynamic>)
            .map((k, v) => MapEntry(k as String, v as int)),
      );

  /// create a copy and modify some fields
  MigrationMeta copyWith({
    int? currentDirIndex,
    Map<int, int>? dirUsage,
    Map<String, int>? taskIndex,
  }) =>
      MigrationMeta(
        currentDirIndex: currentDirIndex ?? this.currentDirIndex,
        dirUsage: dirUsage ?? this.dirUsage,
        taskIndex: taskIndex ?? this.taskIndex,
      );
}
