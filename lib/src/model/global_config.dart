import '../handler/common.dart';
import 'meta_info.dart';

/// global config model
class GlobalConfig {
  /// database version
  final int version;

  /// user defined database version
  final int userVersion;

  /// Engine-managed directory sharding parameter persisted for compatibility.
  ///
  /// Used for deterministic sharding:
  /// `dirIndex = partitionIndex ~/ maxEntriesPerDir`.
  ///
  /// Do NOT expose this as a user-facing knob; changing it requires an explicit
  /// migration for on-disk directory layout.
  final int maxEntriesPerDir;

  /// all created space names
  final Set<String> spaceNames;

  /// whether there is a pending migration task
  final bool hasMigrationTask;

  /// table directory mapping - record the directory index of each table
  /// the key format is "spaceName:tableName", for global space use "global:tableName"
  final Map<String, TableDirectoryInfo> tableDirectoryMap;

  /// directory usage - record the number of tables in each directory
  /// the key format is "spaceName:dirIndex", for global space use "global:dirIndex"
  final Map<String, int> directoryUsageMap;

  GlobalConfig({
    int? version,
    int? userVersion,
    int? maxEntriesPerDir,
    Set<String>? spaceNames,
    this.hasMigrationTask = false,
    Map<String, TableDirectoryInfo>? tableDirectoryMap,
    Map<String, int>? directoryUsageMap,
  })  : version = version ?? InternalConfig.engineVersion,
        userVersion = userVersion ?? 0,
        maxEntriesPerDir =
            maxEntriesPerDir ?? InternalConfig.defaultMaxEntriesPerDir,
        spaceNames = spaceNames ?? {'default'},
        tableDirectoryMap = tableDirectoryMap ?? {},
        directoryUsageMap = directoryUsageMap ?? {};

  /// create from json
  factory GlobalConfig.fromJson(Map<String, dynamic> json) {
    return GlobalConfig(
      version: resolveVersionValue(
          json['version'], InternalConfig.legacyEngineVersion),
      userVersion: resolveVersionValue(json['userVersion'], 0),
      maxEntriesPerDir: resolveVersionValue(
          json['maxEntriesPerDir'], InternalConfig.defaultMaxEntriesPerDir),
      spaceNames: (json['spaceNames'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toSet() ??
          {'default'},
      hasMigrationTask: json['hasMigrationTask'] as bool? ?? false,
      tableDirectoryMap: json.containsKey('tableDirectoryMap')
          ? (json['tableDirectoryMap'] as Map<String, dynamic>).map(
              (key, value) => MapEntry(
                key,
                TableDirectoryInfo.fromJson(value as Map<String, dynamic>),
              ),
            )
          : {},
      directoryUsageMap: json.containsKey('directoryUsageMap')
          ? (json['directoryUsageMap'] as Map<String, dynamic>).map(
              (key, value) => MapEntry(key, value as int),
            )
          : {},
    );
  }

  /// convert to json
  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'userVersion': userVersion,
      'maxEntriesPerDir': maxEntriesPerDir,
      'spaceNames': spaceNames.toList(),
      'hasMigrationTask': hasMigrationTask,
      'tableDirectoryMap':
          tableDirectoryMap.map((key, value) => MapEntry(key, value.toJson())),
      'directoryUsageMap': directoryUsageMap,
    };
  }

  /// create a copy and modify some fields
  GlobalConfig copyWith({
    int? version,
    int? userVersion,
    int? maxEntriesPerDir,
    Set<String>? spaceNames,
    bool? hasMigrationTask,
    Map<String, TableDirectoryInfo>? tableDirectoryMap,
    Map<String, int>? directoryUsageMap,
  }) {
    return GlobalConfig(
      version: version ?? this.version,
      userVersion: userVersion ?? this.userVersion,
      maxEntriesPerDir: maxEntriesPerDir ?? this.maxEntriesPerDir,
      spaceNames: spaceNames ?? this.spaceNames,
      hasMigrationTask: hasMigrationTask ?? this.hasMigrationTask,
      tableDirectoryMap: tableDirectoryMap ?? this.tableDirectoryMap,
      directoryUsageMap: directoryUsageMap ?? this.directoryUsageMap,
    );
  }

  /// add space name
  GlobalConfig addSpace(String spaceName) {
    if (spaceNames.contains(spaceName)) return this;
    return copyWith(spaceNames: {...spaceNames, spaceName});
  }

  /// remove space name
  GlobalConfig removeSpace(String spaceName) {
    if (!spaceNames.contains(spaceName)) return this;
    final newSpaces = {...spaceNames}..remove(spaceName);
    return copyWith(spaceNames: newSpaces);
  }

  /// set whether there is a migration task
  GlobalConfig setHasMigrationTask(bool hasMigrationTask) {
    return copyWith(hasMigrationTask: hasMigrationTask);
  }

  GlobalConfig setVersion(int newVersion) {
    return copyWith(version: newVersion);
  }

  GlobalConfig setUserVersion(int newVersion) {
    return copyWith(userVersion: newVersion);
  }
}
