import 'dart:async';

import '../core/data_store_impl.dart';
import '../query/query_condition.dart';
import '../handler/logger.dart';

// List of valid operators for validation
const List<String> _validOperators = [
  '=',
  '!=',
  '<>',
  '>',
  '>=',
  '<',
  '<=',
  'IN',
  'NOT IN',
  'BETWEEN',
  'LIKE',
  'NOT LIKE',
  'IS',
  'IS NOT',
];

/// A builder for creating streaming queries with a fluent API
class StreamQueryBuilder {
  final DataStoreImpl _db;
  final String _tableName;
  final QueryCondition _condition = QueryCondition();
  List<String>? _selectedFields;
  Stream<Map<String, dynamic>>? _stream;

  // Track operators that have already been warned about
  static final Set<String> _warnedInvalidOperators = {};

  StreamQueryBuilder(this._db, this._tableName);

  /// Select specific fields to include in the results
  StreamQueryBuilder select(List<String> fields) {
    _selectedFields = fields;
    _invalidateStream();
    return this;
  }

  /// Add a where condition to filter records
  StreamQueryBuilder where(String field, String operator, dynamic value) {
    // Validate the operator before passing to the query condition
    if (!_validOperators.contains(operator.toUpperCase())) {
      // Only warn about each invalid operator once
      if (!_warnedInvalidOperators.contains(operator)) {
        Logger.error(
            'Invalid operator: "$operator". Valid operators are: ${_validOperators.join(', ')}',
            label: 'StreamQueryBuilder.where');
        _warnedInvalidOperators.add(operator);
      }
      // Use equals as a safe fallback
      operator = '=';
    }
    _condition.where(field, operator, value);
    _invalidateStream();
    return this;
  }

  /// Add a whereIn condition to filter records
  StreamQueryBuilder whereIn(String field, List values) {
    _condition.where(field, 'IN', values);
    _invalidateStream();
    return this;
  }

  /// Add a whereBetween condition to filter records
  StreamQueryBuilder whereBetween(String field, dynamic start, dynamic end) {
    _condition.where(field, 'BETWEEN', [start, end]);
    _invalidateStream();
    return this;
  }

  /// Add a whereNull condition to filter records
  StreamQueryBuilder whereNull(String field) {
    _condition.where(field, 'IS', null);
    _invalidateStream();
    return this;
  }

  /// Add a whereNotNull condition to filter records
  StreamQueryBuilder whereNotNull(String field) {
    _condition.where(field, 'IS NOT', null);
    _invalidateStream();
    return this;
  }

  /// Add an OR condition
  StreamQueryBuilder or() {
    _condition.or();
    _invalidateStream();
    return this;
  }

  /// Invalidates the cached stream when query parameters change
  void _invalidateStream() {
    _stream = null;
  }

  /// Execute the streaming query and return a Stream of results
  Stream<Map<String, dynamic>> execute() {
    return _getStream();
  }

  /// Get (or create) the underlying stream
  Stream<Map<String, dynamic>> _getStream() {
    _stream ??= _db.streamRecords(
      _tableName,
      condition: _condition,
      selectedFields: _selectedFields,
    );
    return _stream!;
  }

  /// Makes the StreamQueryBuilder act like a Stream
  Stream<Map<String, dynamic>> asStream() => _getStream();

  /// Allows this class to be used anywhere a Stream is expected
  /// without explicit conversion
  StreamSubscription<Map<String, dynamic>> listen(
    void Function(Map<String, dynamic> event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _getStream().listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  /// Enables using await for directly on this object
  Stream<Map<String, dynamic>> get stream => _getStream();
}
