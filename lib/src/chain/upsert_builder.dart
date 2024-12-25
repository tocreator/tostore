import 'dart:async';

import 'chain_builder.dart';
import 'future_builder_mixin.dart';

/// upsert builder for chain operations
class UpsertBuilder extends ChainBuilder<UpsertBuilder>
    with FutureBuilderMixin<bool> {
  final Map<String, dynamic> _data;
  Future<bool>? _future;

  UpsertBuilder(super.db, super.tableName, this._data);

  @override
  Future<bool> get future async {
    final schema = await $db.getTableSchema($tableName);
    final primaryKey = schema.primaryKey;

    // 1. Prefer using chained conditions.
    if (condition.build().isNotEmpty) {
      final existing = await $db.queryByMap(
        $tableName,
        where: condition.build(),
        orderBy: $orderBy,
        limit: $limit,
        offset: $offset,
      );
      if (existing.isNotEmpty) {
        _future ??= $db.updateInternal(
          $tableName,
          _data,
          condition,
          orderBy: $orderBy,
          limit: $limit,
          offset: $offset,
        );
        return _future!;
      }
      return await $db.insert($tableName, _data);
    }

    // 2. if the data contains a primary key,use it for judgment
    if (_data.containsKey(primaryKey)) {
      final existing = await $db.queryByMap(
        $tableName,
        where: {primaryKey: _data[primaryKey]},
        limit: 1,
      );
      if (existing.isNotEmpty) {
        _future ??= $db.updateInternal(
          $tableName,
          _data,
          condition,
          orderBy: $orderBy,
          limit: $limit,
          offset: $offset,
        );
        return _future!;
      }
    }

    return await $db.insert($tableName, _data);
  }
}
