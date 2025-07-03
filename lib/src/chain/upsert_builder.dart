import 'dart:async';

import '../Interface/chain_builder.dart';
import '../Interface/future_builder_mixin.dart';
import '../model/db_result.dart';
import '../model/result_type.dart';
import '../query/query_condition.dart';

/// upsert builder for chain operations
class UpsertBuilder extends ChainBuilder<UpsertBuilder>
    with FutureBuilderMixin<DbResult> {
  final Map<String, dynamic> _data;
  // This flag is now used to signal the intent to update all records
  // matching a WHERE clause, which is the default behavior for updates with conditions.
  // Its main purpose is to be explicit and align with the update builder's API.
  bool _allowMultiUpdate = false;
  // flag to indicate whether to continue on partial errors
  bool _continueOnPartialErrors = false;

  UpsertBuilder(super.db, super.tableName, this._data);

  /// Allows the `upsert` operation to update all records that match the `where` clause.
  ///
  /// By default, an `update` with a `where` clause affects all matching records.
  /// This method makes that intent explicit for the `upsert` operation.
  /// If no `where` clause is provided, this method has no effect.
  UpsertBuilder allowUpdateAll() {
    _allowMultiUpdate = true;
    return this;
  }

  /// allow partial errors
  ///
  /// this method explicitly indicates that the operation should continue when some records fail.
  /// by default, the operation will stop and return an error if any record fails.
  UpsertBuilder allowPartialErrors() {
    _continueOnPartialErrors = true;
    return this;
  }

  @override
  Future<DbResult> get future async {
    try {
      // Strategy: Try-Update-Then-Insert. This is the most robust approach to avoid race conditions
      // and logical errors from "read-then-write" patterns.

      final schema = await $db.getTableSchema($tableName);
      if (schema == null) {
        return DbResult.error(
          type: ResultType.notFound,
          message: 'Table does not exist',
        );
      }
      final primaryKey = schema.primaryKey;

      // Case 1: A `where` clause is provided.
      // We first attempt to update all records matching the condition.
      if (queryCondition.build().isNotEmpty) {
        final updateResult = await $db.updateInternal(
          $tableName,
          _data,
          queryCondition,
          orderBy: $orderBy,
          limit: $limit,
          offset: $offset,
          // `allowAll` in updateInternal is for empty conditions, which we have checked against.
          // The presence of a queryCondition means we intend to update matching records.
          allowAll: _allowMultiUpdate,
          continueOnPartialErrors: _continueOnPartialErrors,
        );

        // If the update affected 1 or more rows, the operation is complete.
        // Also, if it failed for any reason other than "not found", we return that result.
        if ((updateResult.isSuccess && updateResult.successKeys.isNotEmpty) ||
            updateResult.type != ResultType.notFound) {
          return updateResult;
        }

        // If updateResult.type is `notFound`, it means no records matched the condition.
        // In this case, we proceed to insert the data as a new record.
        return await $db.insert($tableName, _data);
      }

      // Case 2: No `where` clause. The operation depends on the primary key in the data.
      else if (_data.containsKey(primaryKey)) {
        final pkValue = _data[primaryKey];
        // Strategy: Try-Update-Then-Insert, applied to the primary key.
        // This avoids race conditions inherent in a "read-then-write" approach.
        final specificCondition = QueryCondition()
          ..where(primaryKey, '=', pkValue);

        final updateResult = await $db.updateInternal(
          $tableName,
          _data,
          specificCondition,
          limit: 1, // Ensure we only target this one record
          continueOnPartialErrors: _continueOnPartialErrors,
        );

        // If the update succeeded or failed for a reason other than "not found", return the result.
        if (updateResult.isSuccess ||
            updateResult.type != ResultType.notFound) {
          return updateResult;
        }

        // If the update failed because the record was not found, insert it.
        return await $db.insert($tableName, _data);
      }

      // Case 3: No `where` clause and no primary key in data.
      // This is a straightforward insert. The database will generate a primary key.
      else {
        return await $db.insert($tableName, _data);
      }
    } catch (e) {
      // Get primary key value if possible
      List<String> failedKeys = [];
      try {
        final schema = await $db.getTableSchema($tableName);
        if (schema != null && _data.containsKey(schema.primaryKey)) {
          final keyValue = _data[schema.primaryKey]?.toString();
          if (keyValue != null && keyValue.isNotEmpty) {
            failedKeys = [keyValue];
          }
        }
      } catch (_) {
        // Ignore errors during error handling
      }

      return DbResult.error(
        type: ResultType.dbError,
        message: 'Operation failed: $e',
        failedKeys: failedKeys,
      );
    }
  }
}
