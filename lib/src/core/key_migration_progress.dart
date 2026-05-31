import '../model/system_table.dart';
import 'data_store_impl.dart';
import 'transaction_context.dart';

/// Persistence helpers for [_system_key_migration] progress rows.
class KeyMigrationProgressStore {
  KeyMigrationProgressStore._();

  static String progressKey(String tableName, String spaceName) =>
      '$tableName|$spaceName';

  static Future<void> ensureTable(DataStoreImpl dataStore) async {
    final schemaManager = dataStore.schemaManager;
    if (schemaManager == null) return;

    final tableName = SystemTable.keyMigrationProgressTableName;
    if (await dataStore.tableExists(tableName)) return;

    await TransactionContext.runAsSystemOperation(() async {
      await dataStore.createTable(
        SystemTable.gettableSchemas.firstWhere((s) => s.name == tableName),
        isSystemTable: true,
      );
    });
  }

  static Future<String?> loadCheckpoint(
    DataStoreImpl dataStore, {
    required String tableName,
    required String spaceName,
  }) async {
    final pk = progressKey(tableName, spaceName);
    final rows = await dataStore.queryBy(
      SystemTable.keyMigrationProgressTableName,
      SystemTable.keyMigrationProgressKeyField,
      pk,
    );

    if (rows.isEmpty) return null;
    final checkpoint = rows.first[SystemTable.keyMigrationCheckpointField];
    if (checkpoint == null) return null;
    return checkpoint.toString();
  }

  static Future<void> upsertRunning(
    DataStoreImpl dataStore, {
    required String tableName,
    required String spaceName,
    String? checkpointKey,
  }) async {
    await _upsert(
      dataStore,
      tableName: tableName,
      spaceName: spaceName,
      status: 'running',
      checkpointKey: checkpointKey,
    );
  }

  static Future<void> markCompleted(
    DataStoreImpl dataStore, {
    required String tableName,
    required String spaceName,
  }) async {
    await _upsert(
      dataStore,
      tableName: tableName,
      spaceName: spaceName,
      status: 'completed',
      clearCheckpoint: true,
    );
  }

  static Future<void> clearAll(DataStoreImpl dataStore) async {
    await TransactionContext.runAsSystemOperation(() async {
      await dataStore.clear(SystemTable.keyMigrationProgressTableName);
    });
  }

  static Future<void> _upsert(
    DataStoreImpl dataStore, {
    required String tableName,
    required String spaceName,
    required String status,
    String? checkpointKey,
    bool clearCheckpoint = false,
  }) async {
    final pk = progressKey(tableName, spaceName);
    final row = <String, dynamic>{
      SystemTable.keyMigrationProgressKeyField: pk,
      SystemTable.keyMigrationTableNameField: tableName,
      SystemTable.keyMigrationSpaceNameField: spaceName,
      SystemTable.keyMigrationStatusField: status,
    };
    if (!clearCheckpoint && checkpointKey != null) {
      row[SystemTable.keyMigrationCheckpointField] = checkpointKey;
    }

    await TransactionContext.runAsSystemOperation(() async {
      await dataStore.upsert(SystemTable.keyMigrationProgressTableName, row);
    });
  }
}
