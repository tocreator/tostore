import '../model/system_table.dart';
import '../model/table_context.dart';
import '../query/query_condition.dart';
import 'data_store_impl.dart';
import 'transaction_context.dart';
import '../model/table_identity.dart';

/// Persistence helpers for [_system_key_migration] progress rows.
class KeyMigrationProgressStore {
  KeyMigrationProgressStore._();

  static String progressKey(TableUid tableUid, String spaceName) =>
      '$tableUid|$spaceName';

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

  static Future<TableContext?> _progressTableContext(
      DataStoreImpl dataStore) async {
    final uid = dataStore.schemaManager
        ?.getUidByName(TableName(SystemTable.keyMigrationProgressTableName));
    if (uid == null) return null;
    return dataStore.schemaManager?.getTableContext(uid);
  }

  static Future<String?> loadCheckpoint(
    DataStoreImpl dataStore, {
    required TableContext table,
    required String spaceName,
  }) async {
    final progressTable = await _progressTableContext(dataStore);
    if (progressTable == null) return null;
    final pk = progressKey(table.tableUid, spaceName);
    final rows = await dataStore.queryBy(
      progressTable,
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
    required TableContext table,
    required String spaceName,
    String? checkpointKey,
  }) async {
    await _upsert(
      dataStore,
      table: table,
      spaceName: spaceName,
      status: 'running',
      checkpointKey: checkpointKey,
    );
  }

  static Future<void> markCompleted(
    DataStoreImpl dataStore, {
    required TableContext table,
    required String spaceName,
  }) async {
    await _upsert(
      dataStore,
      table: table,
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

  static Future<void> renameTableProgress(
    DataStoreImpl dataStore, {
    required TableContext table,
    required String oldTableName,
    required String newTableName,
    required String spaceName,
  }) async {
    final progressTable = await _progressTableContext(dataStore);
    if (progressTable == null) return;
    final oldPk = progressKey(table.tableUid, spaceName);
    final rows = await dataStore.queryBy(
      progressTable,
      SystemTable.keyMigrationProgressKeyField,
      oldPk,
    );

    if (rows.isNotEmpty) {
      final oldRow = rows.first;
      final status =
          oldRow[SystemTable.keyMigrationStatusField]?.toString() ?? 'running';
      final checkpoint =
          oldRow[SystemTable.keyMigrationCheckpointField]?.toString();

      // Delete old progress row
      await TransactionContext.runAsSystemOperation(() async {
        await dataStore.deleteInternal(
          progressTable,
          QueryCondition.fromMap({
            SystemTable.keyMigrationProgressKeyField: oldPk,
          }),
        );
      });

      // Insert new progress row
      table.tableName = TableName(newTableName);
      await _upsert(
        dataStore,
        table: table,
        spaceName: spaceName,
        status: status,
        checkpointKey: checkpoint,
      );
    }
  }

  static Future<void> _upsert(
    DataStoreImpl dataStore, {
    required TableContext table,
    required String spaceName,
    required String status,
    String? checkpointKey,
    bool clearCheckpoint = false,
  }) async {
    final pk = progressKey(table.tableUid, spaceName);
    final row = <String, dynamic>{
      SystemTable.keyMigrationProgressKeyField: pk,
      SystemTable.keyMigrationTableNameField: table.tableName,
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
