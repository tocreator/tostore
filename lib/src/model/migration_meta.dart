import 'key_migration_info.dart';
import 'meta_info.dart';

/// migration system meta
class MigrationMeta {
  /// Directory mapping for migration tasks.
  /// Maintains taskId -> dirIndex mapping and dirIndex -> fileCount mapping.
  final DirectoryMappingString directoryMapping;

  /// Key re-encryption migration state (authoritative for key migration).
  final KeyMigrationInfo? keyMigrationInfo;

  MigrationMeta({
    DirectoryMappingString? directoryMapping,
    this.keyMigrationInfo,
  }) : directoryMapping = directoryMapping ?? DirectoryMappingString();

  factory MigrationMeta.initial() => MigrationMeta(
        directoryMapping: DirectoryMappingString(),
        keyMigrationInfo: null,
      );

  /// get the task directory path
  String getTaskDir(int dirIndex) => 'dir_$dirIndex';

  /// convert to json
  Map<String, dynamic> toJson() => {
        'directoryMapping': directoryMapping.toJson(),
        if (keyMigrationInfo != null)
          'keyMigrationInfo': keyMigrationInfo!.toJson(),
      };

  /// create from json
  factory MigrationMeta.fromJson(Map<String, dynamic> json) {
    // Handle legacy format (v1) for backward compatibility during upgrade
    if (json.containsKey('dirUsage') || json.containsKey('taskIndex')) {
      // Legacy format: convert to new format
      final Map<String, int> idToDir = <String, int>{};
      final Map<int, int> dirToFileCount = <int, int>{};

      // Convert taskIndex to idToDir
      if (json['taskIndex'] is Map) {
        final taskIndex = json['taskIndex'] as Map<dynamic, dynamic>;
        taskIndex.forEach((key, value) {
          if (key is String && value is int) {
            idToDir[key] = value;
          }
        });
      }

      // Convert dirUsage to dirToFileCount
      if (json['dirUsage'] is Map) {
        final dirUsage = json['dirUsage'] as Map<dynamic, dynamic>;
        dirUsage.forEach((key, value) {
          final idx = int.tryParse(key.toString());
          if (idx != null && value is int) {
            dirToFileCount[idx] = value;
          }
        });
      }

      return MigrationMeta(
        directoryMapping: DirectoryMappingString(
          idToDir: idToDir,
          dirToFileCount: dirToFileCount,
        ),
        keyMigrationInfo: _parseKeyMigrationInfo(json),
      );
    }

    // New format (v2+)
    return MigrationMeta(
      directoryMapping: json['directoryMapping'] != null
          ? DirectoryMappingString.fromJson(
              json['directoryMapping'] as Map<String, dynamic>)
          : DirectoryMappingString(),
      keyMigrationInfo: _parseKeyMigrationInfo(json),
    );
  }

  static KeyMigrationInfo? _parseKeyMigrationInfo(Map<String, dynamic> json) {
    final raw = json['keyMigrationInfo'];
    if (raw is! Map<String, dynamic>) return null;
    return KeyMigrationInfo.fromJson(raw);
  }

  /// create a copy and modify some fields
  MigrationMeta copyWith({
    DirectoryMappingString? directoryMapping,
    KeyMigrationInfo? keyMigrationInfo,
    bool clearKeyMigrationInfo = false,
  }) =>
      MigrationMeta(
        directoryMapping: directoryMapping ?? this.directoryMapping,
        keyMigrationInfo: clearKeyMigrationInfo
            ? null
            : (keyMigrationInfo ?? this.keyMigrationInfo),
      );
}
