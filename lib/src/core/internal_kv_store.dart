import 'dart:typed_data';

import '../handler/logger.dart';
import '../model/db_exception.dart';
import '../model/db_result.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/system_table.dart';
import '../model/table_context.dart';
import '../query/query_condition.dart';
import 'data_store_impl.dart';
import 'transaction_context.dart';

/// Engine-only key-value access for
/// [SystemTable.getInternalKeyValueName] tables.
///
/// Not user-facing. Backed by normal table CRUD
/// (`upsert` / `queryById` / `deleteInternal`).
/// Values are opaque [Uint8List] — callers own serialization.
///
/// Key naming: use a short module prefix to avoid collisions, e.g.
/// `meta.`, `cfg.`, `stats.` (prefer [tableUid] over tableName in keys).
class InternalKvStore {
  final DataStoreImpl _db;

  InternalKvStore(this._db);

  Future<TableContext> _table({required bool isGlobal}) async {
    await _db.ensureInitialized();
    final tableName = SystemTable.getInternalKeyValueName(isGlobal);
    return _db.getTableContext(tableName);
  }

  /// Point-get by primary key. Returns `null` when the key is absent.
  Future<Uint8List?> get(String key, {bool isGlobal = false}) async {
    _validateKey(key);
    final table = await _table(isGlobal: isGlobal);
    final row = await _db.queryById(table, key);
    if (row == null) return null;
    return _asBytes(row[SystemTable.keyValueValueField]);
  }

  /// Upsert a blob value for [key] (primary-key conflict overwrites).
  ///
  /// Throws [DbException] on write failure.
  Future<void> set(
    String key,
    Uint8List value, {
    bool isGlobal = false,
  }) async {
    _validateKey(key);
    final tableName = SystemTable.getInternalKeyValueName(isGlobal);
    await _db.ensureInitialized();

    final row = <String, dynamic>{
      SystemTable.keyValueKeyField: key,
      SystemTable.keyValueValueField: value,
      SystemTable.keyValueUpdatedAtField: DateTime.now().toIso8601String(),
    };

    final result = await TransactionContext.runAsSystemOperation(() async {
      return await _db.upsert(tableName, row);
    });
    _throwIfFailed(result);
  }

  /// Delete by primary key. Internally uses [DataStoreImpl.deleteInternal].
  ///
  /// Idempotent: missing key is a silent no-op. Engine-internal cleanup must
  /// not interrupt callers — write failures are logged, not thrown.
  Future<void> remove(String key, {bool isGlobal = false}) async {
    if (key.isEmpty) return;
    try {
      final table = await _table(isGlobal: isGlobal);
      final condition =
          QueryCondition()..where(SystemTable.keyValueKeyField, '=', key);

      final result = await TransactionContext.runAsSystemOperation(() async {
        return await _db.deleteInternal(table, condition);
      });
      // deleteInternal already returns success when no row matches; only
      // surface real write failures via log.
      if (result.hasErrors) {
        Logger.warn(
          'Internal KV remove failed for key "$key" '
          '(${SystemTable.getInternalKeyValueName(isGlobal)})',
          rawError: result.message,
        );
      }
    } on DbClosedException {
      return;
    } catch (e) {
      Logger.warn(
        'Internal KV remove failed for key "$key"',
        rawError: e,
      );
    }
  }

  void _throwIfFailed(DbResult result) {
    if (!result.hasErrors) return;
    throw DbException(result.statuses);
  }

  void _validateKey(String key) {
    if (key.isEmpty) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.devInvalidArgumentFormat,
          message: 'Internal KV key must not be empty',
          parameterName: 'key',
          passedValue: key,
        ),
      ]);
    }
  }

  Uint8List? _asBytes(dynamic raw) {
    if (raw == null) return null;
    if (raw is Uint8List) return raw;
    if (raw is List<int>) return Uint8List.fromList(raw);
    return null;
  }
}
