import 'dart:async';

import '../Interface/chain_builder.dart';
import '../Interface/future_builder_mixin.dart';
import '../model/db_result.dart';
import '../model/result_code.dart';
import '../query/query_condition.dart';

/// upsert builder for chain operations
class UpsertBuilder extends ChainBuilder<UpsertBuilder>
    with FutureBuilderMixin<DbResult> {
  final Map<String, dynamic> _data;

  UpsertBuilder(super.db, super.tableName, this._data);

  @override
  Future<DbResult> get future async {
    try {
      final schema = await $db.getTableSchema($tableName);
      if (schema == null) {
        return DbResult.error(
          code: ResultCode.notFound,
          message: 'Table does not exist',
        );
      }

      final primaryKey = schema.primaryKey;
      bool recordExists = false;

      // 1. If there are conditions, check if a matching record exists first
      if (condition.build().isNotEmpty) {
        final existingResult = await $db.executeQuery(
          $tableName,
          condition,
          limit: 1,
        );

        recordExists = existingResult.isNotEmpty;
      }
      // 2. If the data contains the primary key, use the primary key to check
      else if (_data.containsKey(primaryKey)) {
        final existingResult = await $db.executeQuery(
          $tableName,
          QueryCondition()..where(primaryKey, '=', _data[primaryKey]),
          limit: 1,
        );

        recordExists = existingResult.isNotEmpty;
      }

      // Decide whether to update or insert based on whether the record exists
      if (recordExists) {
        return await $db.updateInternal(
          $tableName,
          _data,
          condition,
          orderBy: $orderBy,
          limit: $limit,
          offset: $offset,
        );
      } else {
        // Perform insert
        return await $db.insert($tableName, _data);
      }
    } catch (e) {
      return DbResult.error(
        code: ResultCode.dbError,
        message: 'Operation failed: $e',
      );
    }
  }
}
