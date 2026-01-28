part of '../Interface/chain_builder.dart';

/// update builder
class UpdateBuilder extends ChainBuilder<UpdateBuilder>
    with FutureBuilderMixin<DbResult> {
  final Map<String, dynamic> _updateData;
  Future<DbResult>? _future;
  // add flag to indicate whether to allow update without condition
  bool _allowAll = false;
  // add flag to indicate whether to continue on partial errors
  bool _continueOnPartialErrors = false;

  UpdateBuilder(DataStoreImpl db, String tableName,
      [Map<String, dynamic> data = const {}])
      : _updateData = Map.from(data),
        super(db, tableName);

  @override
  void _onChanged() {
    _future = null;
  }

  /// Sets or replaces data for the update operation.
  /// Any existing data in the builder will be merged with the new data.
  ///
  /// You can use ExprNode expressions directly in the Map:
  /// ```dart
  /// updateBuilder.set({
  ///   'total': Expr.field('price') * Expr.field('quantity'),
  ///   'updatedAt': Expr.now(),
  /// });
  /// ```
  UpdateBuilder set(Map<String, dynamic> data) {
    _updateData.addAll(data);
    _onChanged();
    return this;
  }

  /// Sets a single field value.
  ///
  /// You can use ExprNode expressions for atomic operations:
  /// ```dart
  /// updateBuilder.set('balance', Expr.field('balance') + 100);
  /// updateBuilder.set('total', Expr.field('price') * Expr.field('quantity'));
  /// updateBuilder.set('updatedAt', Expr.now());
  /// ```
  UpdateBuilder setField(String field, dynamic value) {
    _updateData[field] = value;
    _onChanged();
    return this;
  }

  /// Atomically increments a numeric field by the given value.
  ///
  /// This is a syntax sugar for: `setField(field, Expr.field(field) + Expr.value(value))`
  ///
  /// If the field does not exist, it will be created and set to the given value.
  /// If the field is not a number, the operation will fail at write time.
  ///
  /// Example:
  /// ```dart
  /// updateBuilder.increment('balance', 100);  // balance = balance + 100
  /// ```
  UpdateBuilder increment(String field, num value) {
    _updateData[field] = Expr.field(field) + Expr.value(value);
    _onChanged();
    return this;
  }

  /// Atomically decrements a numeric field by the given value.
  ///
  /// This is a syntax sugar for: `setField(field, Expr.field(field) - Expr.value(value))`
  ///
  /// If the field does not exist, it will be created and set to the negative of the given value.
  ///
  /// Example:
  /// ```dart
  /// updateBuilder.decrement('balance', 50);  // balance = balance - 50
  /// ```
  UpdateBuilder decrement(String field, num value) {
    _updateData[field] = Expr.field(field) - Expr.value(value);
    _onChanged();
    return this;
  }

  /// Atomically multiplies a numeric field by the given factor.
  ///
  /// This is a syntax sugar for: `setField(field, Expr.field(field) * Expr.value(factor))`
  ///
  /// Example:
  /// ```dart
  /// updateBuilder.multiply('price', 0.9);  // price = price * 0.9 (10% discount)
  /// ```
  UpdateBuilder multiply(String field, num factor) {
    _updateData[field] = Expr.field(field) * Expr.value(factor);
    _onChanged();
    return this;
  }

  /// Atomically divides a numeric field by the given divisor.
  ///
  /// This is a syntax sugar for: `setField(field, Expr.field(field) / Expr.value(divisor))`
  ///
  /// Example:
  /// ```dart
  /// updateBuilder.divide('total', 2);  // total = total / 2
  /// ```
  UpdateBuilder divide(String field, num divisor) {
    _updateData[field] = Expr.field(field) / Expr.value(divisor);
    _onChanged();
    return this;
  }

  /// Atomically sets a field to the minimum of its current value and the given limit.
  ///
  /// This is a syntax sugar for: `setField(field, Expr.min(Expr.field(field), Expr.value(limit)))`
  ///
  /// Example:
  /// ```dart
  /// updateBuilder.min('price', 100);  // price = min(price, 100)
  /// ```
  UpdateBuilder min(String field, num limit) {
    _updateData[field] = Expr.min(Expr.field(field), Expr.value(limit));
    _onChanged();
    return this;
  }

  /// Atomically sets a field to the maximum of its current value and the given limit.
  ///
  /// This is a syntax sugar for: `setField(field, Expr.max(Expr.field(field), Expr.value(limit)))`
  ///
  /// Example:
  /// ```dart
  /// updateBuilder.max('price', 1000);  // price = max(price, 1000)
  /// ```
  UpdateBuilder max(String field, num limit) {
    _updateData[field] = Expr.max(Expr.field(field), Expr.value(limit));
    _onChanged();
    return this;
  }

  /// Atomically clamps a numeric field's value within the given [min, max] range.
  ///
  /// This is a syntax sugar combining min and max operations.
  ///
  /// Example:
  /// ```dart
  /// updateBuilder.clamp('price', 10, 1000);  // price = clamp(price, 10, 1000)
  /// ```
  UpdateBuilder clamp(String field, num min, num max) {
    _updateData[field] = Expr.min(
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
  /// Example:
  /// ```dart
  /// updateBuilder.setServerTimestamp('updatedAt');  // updatedAt = now()
  /// ```
  UpdateBuilder setServerTimestamp(String field) {
    _updateData[field] = Expr.now();
    _onChanged();
    return this;
  }

  /// Atomically computes a field value using a multi-field expression.
  ///
  /// This method enables complex atomic calculations involving multiple fields,
  /// similar to SQL expressions like `UPDATE table SET total = price * quantity + tax`.
  ///
  /// The expression is evaluated atomically using current field values from the record,
  /// preventing race conditions when multiple operations access the same record.
  ///
  /// **Security**: Field names in the expression are validated against the table schema
  /// at evaluation time, preventing injection attacks. Only numeric operations are allowed.
  ///
  /// Example:
  /// ```dart
  /// // Calculate total: price * quantity + tax
  /// updateBuilder.compute('total',
  ///   Expr.field('price') * Expr.field('quantity') + Expr.field('tax')
  /// );
  ///
  /// // Apply discount: price * 0.9
  /// updateBuilder.compute('discountedPrice',
  ///   Expr.field('price') * Expr.value(0.9)
  /// );
  ///
  /// // Complex calculation with min/max
  /// updateBuilder.compute('finalPrice',
  ///   Expr.min(
  ///     Expr.field('price') * Expr.field('quantity'),
  ///     Expr.field('maxPrice')
  ///   )
  /// );
  /// ```
  ///
  /// The expression will be evaluated for each matching record using its current field values.
  UpdateBuilder compute(String field, ExprNode expression) {
    _updateData[field] = expression;
    _onChanged();
    return this;
  }

  /// allow update all records
  ///
  /// this method explicitly indicates that the developer intentionally updates all records in the table.
  /// if there is no query condition and this method is not called, the update operation will be rejected to prevent accidental update.
  UpdateBuilder allowUpdateAll() {
    _allowAll = true;
    _onChanged();
    return this;
  }

  /// allow partial errors
  ///
  /// this method explicitly indicates that the operation should continue when some records fail.
  /// by default, the operation will stop and return an error if any record fails.
  UpdateBuilder allowPartialErrors() {
    _continueOnPartialErrors = true;
    _onChanged();
    return this;
  }

  @override
  Future<DbResult> get future async {
    _future ??= _db.updateInternal(
      _tableName,
      _updateData,
      queryCondition,
      orderBy: _orderBy,
      limit: _limit,
      offset: _offset,
      allowAll: _allowAll,
      continueOnPartialErrors: _continueOnPartialErrors,
    );
    return _future!;
  }
}
