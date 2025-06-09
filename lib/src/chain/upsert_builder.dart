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
  // flag to allow update of multiple records if the condition matches multiple records
  bool _allowMultiUpdate = false;
  // flag to indicate whether to continue on partial errors
  bool _continueOnPartialErrors = false;

  UpsertBuilder(super.db, super.tableName, this._data);

  /// Allow updating multiple records if the condition matches multiple records
  ///
  /// By default, upsert will only update one record to avoid accidental batch updates.
  /// This method explicitly indicates that the developer intentionally wants to update all matching records.
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
      final schema = await $db.getTableSchema($tableName);
      if (schema == null) {
        return DbResult.error(
          type: ResultType.notFound,
          message: 'Table does not exist',
        );
      }

      final primaryKey = schema.primaryKey;
      bool recordExists = false;
      Map<String, dynamic>? existingRecord;

      // 1. If there are conditions, check if a matching record exists first
      if (queryCondition.build().isNotEmpty) {
        final existingResult = await $db.executeQuery(
          $tableName,
          queryCondition,
          limit: 1,
        );

        recordExists = existingResult.isNotEmpty;
        if (recordExists) {
          existingRecord = existingResult.first;
        }
      }
      // 2. If the data contains the primary key, use the primary key to check
      else if (_data.containsKey(primaryKey)) {
        final existingResult = await $db.executeQuery(
          $tableName,
          QueryCondition()..where(primaryKey, '=', _data[primaryKey]),
          limit: 1,
        );

        recordExists = existingResult.isNotEmpty;
        if (recordExists) {
          existingRecord = existingResult.first;
        }
      }

      // Decide whether to update or insert based on whether the record exists
      if (recordExists) {
        // Check if we need to update multiple records
        if (_allowMultiUpdate) {
          // Use the original condition and limits for updating potentially multiple records
          return await $db.updateInternal(
            $tableName,
            _data,
            queryCondition,
            orderBy: $orderBy,
            limit: $limit,
            offset: $offset,
            continueOnPartialErrors: _continueOnPartialErrors,
          );
        } else {
          // Default behavior: only update the first found record by its primary key
          // This ensures we don't accidentally update multiple records
          if (existingRecord != null &&
              existingRecord.containsKey(primaryKey)) {
            final specificCondition = QueryCondition()
              ..where(primaryKey, '=', existingRecord[primaryKey]);

            return await $db.updateInternal(
              $tableName,
              _data,
              specificCondition,
              continueOnPartialErrors: _continueOnPartialErrors,
            );
          } else {
            // Fallback if we can't determine primary key (shouldn't happen)
            return await $db.updateInternal(
              $tableName,
              _data,
              queryCondition,
              limit: 1,
              continueOnPartialErrors: _continueOnPartialErrors,
            );
          }
        }
      } else {
        // Perform insert
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
