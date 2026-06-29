import '../handler/common.dart';

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

  /// Active space name. Default is 'default'. Used on next open when opening with default space.
  final String? activeSpace;

  /// Fast-path flag: true while schema or key migration is still incomplete.
  ///
  /// Authoritative state is in migration_meta.json (task files + keyMigrationInfo).
  final bool hasMigrationTask;

  GlobalConfig({
    int? version,
    int? userVersion,
    int? maxEntriesPerDir,
    Set<String>? spaceNames,
    this.activeSpace,
    this.hasMigrationTask = false,
  })  : version = version ?? InternalConfig.engineVersion,
        userVersion = userVersion ?? 0,
        maxEntriesPerDir =
            maxEntriesPerDir ?? InternalConfig.defaultMaxEntriesPerDir,
        spaceNames = spaceNames ?? {'default'};

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
      activeSpace: json['activeSpace'] as String? ?? 'default',
      hasMigrationTask: json['hasMigrationTask'] as bool? ?? false,
    );
  }

  /// convert to json
  Map<String, dynamic> toJson() {
    return {
      'version': version,
      'userVersion': userVersion,
      'maxEntriesPerDir': maxEntriesPerDir,
      'spaceNames': spaceNames.toList(),
      if (activeSpace != null) 'activeSpace': activeSpace!,
      'hasMigrationTask': hasMigrationTask,
    };
  }

  /// create a copy and modify some fields
  /// [clearActiveSpace] when true, sets [activeSpace] to null (e.g. for logout).
  GlobalConfig copyWith({
    int? version,
    int? userVersion,
    int? maxEntriesPerDir,
    Set<String>? spaceNames,
    String? activeSpace,
    bool clearActiveSpace = false,
    bool? hasMigrationTask,
  }) {
    return GlobalConfig(
      version: version ?? this.version,
      userVersion: userVersion ?? this.userVersion,
      maxEntriesPerDir: maxEntriesPerDir ?? this.maxEntriesPerDir,
      spaceNames: spaceNames ?? this.spaceNames,
      activeSpace: clearActiveSpace ? null : (activeSpace ?? this.activeSpace),
      hasMigrationTask: hasMigrationTask ?? this.hasMigrationTask,
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

  /// Clear active space so next launch uses default (e.g. after logout).
  GlobalConfig clearActiveSpace() {
    if (activeSpace == null) return this;
    return copyWith(clearActiveSpace: true);
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
