import 'dart:async';

import '../model/config_info.dart';
import '../model/memory_info.dart';
import '../model/migration_task.dart';
import '../model/space_info.dart';
import '../model/table_info.dart';

/// Database status and diagnostics interface
abstract class DbStatus {
  /// Get internal memory and cache status
  Future<MemoryInfo> memory();

  /// Get space-local storage aggregates (record count, table/index data size).
  /// [useCache] Whether to use cached data. Defaults to true.
  Future<SpaceInfo> space({bool useCache = true});

  /// Get specific table information
  Future<TableInfo?> table(String tableName);

  /// Get effective configuration status
  Future<ConfigInfo> config();

  /// Get migration task status
  Future<MigrationStatus?> migration(String taskId);
}
