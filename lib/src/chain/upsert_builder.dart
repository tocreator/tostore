part of '../Interface/chain_builder.dart';

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

  UpsertBuilder(DataStoreImpl db, String tableName, this._data)
      : super(db, tableName);

  Future<DbResult>? _future;

  @override
  void _onChanged() {
    _future = null;
  }

  /// Sets or replaces data for the upsert operation.
  /// Any existing data in the builder will be merged with the new data.
  UpsertBuilder set(Map<String, dynamic> data) {
    _data.addAll(data);
    _onChanged();
    return this;
  }

  /// Sets a single field value.
  ///
  /// You can use ExprNode expressions for atomic operations:
  /// ```dart
  /// upsertBuilder.setField('balance', Expr.field('balance') + 100);
  /// upsertBuilder.setField('total', Expr.field('price') * Expr.field('quantity'));
  /// upsertBuilder.setField('updatedAt', Expr.now());
  /// ```
  UpsertBuilder setField(String field, dynamic value) {
    _data[field] = value;
    _onChanged();
    return this;
  }

  /// Atomically increments a numeric field by the given value.
  ///
  /// This is a syntax sugar for: `setField(field, Expr.field(field) + Expr.value(value))`
  ///
  /// For update: increments the existing value (or initializes if absent/non-numeric).
  /// For insert: sets the field to the given value.
  UpsertBuilder increment(String field, num value) {
    _data[field] = Expr.field(field) + Expr.value(value);
    _onChanged();
    return this;
  }

  /// Atomically decrements a numeric field by the given value.
  ///
  /// This is a syntax sugar for: `setField(field, Expr.field(field) - Expr.value(value))`
  ///
  /// For update: decrements the existing value.
  /// For insert: sets the field to the negative of the given value.
  UpsertBuilder decrement(String field, num value) {
    _data[field] = Expr.field(field) - Expr.value(value);
    _onChanged();
    return this;
  }

  /// Atomically multiplies a numeric field by the given factor.
  ///
  /// This is a syntax sugar for: `setField(field, Expr.field(field) * Expr.value(factor))`
  UpsertBuilder multiply(String field, num factor) {
    _data[field] = Expr.field(field) * Expr.value(factor);
    _onChanged();
    return this;
  }

  /// Atomically divides a numeric field by the given divisor.
  ///
  /// This is a syntax sugar for: `setField(field, Expr.field(field) / Expr.value(divisor))`
  UpsertBuilder divide(String field, num divisor) {
    _data[field] = Expr.field(field) / Expr.value(divisor);
    _onChanged();
    return this;
  }

  /// Atomically sets a field to the minimum of its current value and the given limit.
  ///
  /// This is a syntax sugar for: `setField(field, Expr.min(Expr.field(field), Expr.value(limit)))`
  UpsertBuilder min(String field, num limit) {
    _data[field] = Expr.min(Expr.field(field), Expr.value(limit));
    _onChanged();
    return this;
  }

  /// Atomically sets a field to the maximum of its current value and the given limit.
  ///
  /// This is a syntax sugar for: `setField(field, Expr.max(Expr.field(field), Expr.value(limit)))`
  UpsertBuilder max(String field, num limit) {
    _data[field] = Expr.max(Expr.field(field), Expr.value(limit));
    _onChanged();
    return this;
  }

  /// Atomically clamps a numeric field's value within the given [min, max] range.
  ///
  /// This is a syntax sugar combining min and max operations.
  UpsertBuilder clamp(String field, num min, num max) {
    _data[field] = Expr.min(
      Expr.max(Expr.field(field), Expr.value(min)),
      Expr.value(max),
    );
    _onChanged();
    return this;
  }

  /// Sets the field to the current server timestamp.
  ///
  /// This is a syntax sugar for: `setField(field, Expr.now())`
  ///
  /// For update and insert: sets to current timestamp.
  UpsertBuilder setServerTimestamp(String field) {
    _data[field] = Expr.now();
    _onChanged();
    return this;
  }

  /// Atomically computes a field value using a multi-field expression.
  ///
  /// This method enables complex atomic calculations involving multiple fields.
  /// The expression is evaluated atomically using current field values from the record.
  ///
  /// Example:
  /// ```dart
  /// upsertBuilder.compute('total',
  ///   Expr.field('price') * Expr.field('quantity') + Expr.field('tax')
  /// );
  /// ```
  UpsertBuilder compute(String field, ExprNode expression) {
    _data[field] = expression;
    _onChanged();
    return this;
  }

  /// Allows the `upsert` operation to update all records that match the `where` clause.
  ///
  /// By default, an `update` with a `where` clause affects all matching records.
  /// This method makes that intent explicit for the `upsert` operation.
  /// If no `where` clause is provided, this method has no effect.
  UpsertBuilder allowUpdateAll() {
    _allowMultiUpdate = true;
    _onChanged();
    return this;
  }

  /// allow partial errors
  ///
  /// this method explicitly indicates that the operation should continue when some records fail.
  /// by default, the operation will stop and return an error if any record fails.
  UpsertBuilder allowPartialErrors() {
    _continueOnPartialErrors = true;
    _onChanged();
    return this;
  }

  @override
  Future<DbResult> get future async {
    _future ??= _executeInternal();
    return _future!;
  }

  Future<DbResult> _executeInternal() async {
    try {
      // Strategy: Try-Update-Then-Insert. This is the most robust approach to avoid race conditions
      // and logical errors from "read-then-write" patterns.

      final schema = await _db.schemaManager?.getTableSchema(_tableName);
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
        final updateResult = await _db.updateInternal(
          _tableName,
          _data,
          queryCondition,
          orderBy: _orderBy,
          limit: _limit,
          offset: _offset,
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
        return await _db.insert(_tableName, _data);
      }

      // Case 2: No `where` clause. The operation depends on the primary key in the data.
      else if (_data.containsKey(primaryKey)) {
        final pkValue = _data[primaryKey];
        // Strategy: Try-Update-Then-Insert, applied to the primary key.
        // This avoids race conditions inherent in a "read-then-write" approach.
        final specificCondition = QueryCondition()
          ..where(primaryKey, '=', pkValue);

        final updateResult = await _db.updateInternal(
          _tableName,
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
        return await _db.insert(_tableName, _data);
      }

      // Case 3: No `where` clause and no primary key in data.
      // This is a straightforward insert. The database will generate a primary key.
      else {
        return await _db.insert(_tableName, _data);
      }
    } catch (e) {
      // Get primary key value if possible
      List<String> failedKeys = [];
      try {
        final schema = await _db.schemaManager?.getTableSchema(_tableName);
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
