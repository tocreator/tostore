import 'dart:async';
import '../Interface/chain_builder.dart';
import '../Interface/future_builder_mixin.dart';
import '../model/join_clause.dart';
import '../model/query_result.dart';

/// query builder
class QueryBuilder extends ChainBuilder<QueryBuilder>
    with FutureBuilderMixin<QueryResult<Map<String, dynamic>>> {
  Future<List<Map<String, dynamic>>>? _future;
  List<String>? _selectedFields;

  // related query related properties
  final List<JoinClause> _joins = [];

  QueryBuilder(super.db, super.tableName);

  void _invalidateFuture() {
    _future = null;
  }

  /// select specific fields to return
  QueryBuilder select(List<String> fields) {
    _selectedFields = fields;
    _invalidateFuture();
    return this;
  }

  /// join another table
  QueryBuilder join(
      String table, String firstKey, String operator, String secondKey) {
    _joins.add(JoinClause(
      type: JoinType.inner,
      table: table,
      firstKey: firstKey,
      operator: operator,
      secondKey: secondKey,
    ));
    _invalidateFuture();
    return this;
  }

  /// left join another table
  QueryBuilder leftJoin(
      String table, String firstKey, String operator, String secondKey) {
    _joins.add(JoinClause(
      type: JoinType.left,
      table: table,
      firstKey: firstKey,
      operator: operator,
      secondKey: secondKey,
    ));
    _invalidateFuture();
    return this;
  }

  /// right join another table
  QueryBuilder rightJoin(
      String table, String firstKey, String operator, String secondKey) {
    _joins.add(JoinClause(
      type: JoinType.right,
      table: table,
      firstKey: firstKey,
      operator: operator,
      secondKey: secondKey,
    ));
    _invalidateFuture();
    return this;
  }

  /// get first record
  Future<Map<String, dynamic>?> first() async {
    limit(1);
    _invalidateFuture();
    final results = await this;
    return results.data.isEmpty ? null : results.data.first;
  }

  /// get record count
  Future<int> count() async {
    // if there are no conditions, get total count from metadata
    if (queryCondition.isEmpty) {
      return await $db.tableDataManager.getTableRecordCount($tableName);
    }

    // otherwise, execute query and calculate count of records
    final results = await this;
    return results.data.length;
  }

  @override
  Future<QueryResult<Map<String, dynamic>>> get future async {
    if (_future == null) {
      final results = await _executeQuery();
      return QueryResult.success(data: results);
    }
    final results = await _future!;
    return QueryResult.success(data: results);
  }

  /// modify conditions, add table name prefix (if needed)
  Map<String, dynamic> _convertWhereClauses(
      Map<String, dynamic> conditions, List<JoinClause> joins) {
    if (joins.isEmpty) return conditions;

    // collect all related table names for field processing
    final Set<String> allTableNames = {$tableName};
    for (var join in joins) {
      allTableNames.add(join.table);
    }

    // process field prefix
    var result = <String, dynamic>{};
    for (var entry in conditions.entries) {
      final field = entry.key;
      // special operators not processed
      if (field == 'OR' || field == 'AND') {
        if (entry.value is List) {
          final List<Map<String, dynamic>> convertedConditions = [];
          for (var condition in entry.value as List) {
            if (condition is Map<String, dynamic>) {
              convertedConditions.add(_convertWhereClauses(condition, joins));
            }
          }
          result[field] = convertedConditions;
        }
        continue;
      }

      // if field already has table prefix, use directly
      if (field.contains('.')) {
        result[field] = entry.value;
        continue;
      }

      // for fields without prefix, default add main table prefix
      // this logic ensures where conditions apply to main table and related tables
      result['${$tableName}.$field'] = entry.value;
    }

    return result;
  }

  /// execute query
  Future<List<Map<String, dynamic>>> _executeQuery() async {
    // convert where conditions, add table prefix to fields
    var whereConditions = queryCondition.build();
    if (_joins.isNotEmpty) {
      whereConditions = _convertWhereClauses(whereConditions, _joins);
    }
    await $db.ensureInitialized();
    // build query plan
    final queryPlan = await $db.getQueryOptimizer()?.optimize(
          $tableName,
          whereConditions,
          $orderBy,
          joins: _joins,
        );

    if (queryPlan == null) {
      throw StateError('Query optimizer not initialized');
    }

    // directly use QueryExecutor to execute query
    final results = await $db.getQueryExecutor()?.execute(
              queryPlan,
              $tableName,
              condition: queryCondition,
              orderBy: $orderBy,
              limit: $limit,
              offset: $offset,
              joins: _joins,
            ) ??
        [];

    // process related query results, ensure consistent field naming format
    if (_joins.isNotEmpty) {
      return _processManyTableResults(results);
    }

    // if fields are specified, only return selected fields
    if (_selectedFields != null && _selectedFields!.isNotEmpty) {
      return results.map((record) {
        final filteredRecord = <String, dynamic>{};
        for (final field in _selectedFields!) {
          // handle field alias (e.g. "name as username")
          final fieldName =
              field.contains(' as ') ? field.split(' as ')[0].trim() : field;
          final aliasName = _getFieldAlias(field);

          // handle field with table name prefix (e.g. "users.id")
          if (fieldName.contains('.')) {
            final parts = fieldName.split('.');
            final tableName = parts[0];
            final columnName = parts[1];

            // try to match complete table name.field name format
            if (record.containsKey(fieldName)) {
              filteredRecord[aliasName] = record[fieldName];
              continue;
            }

            // try using table name_field name format
            final prefixedKey = '${tableName}_$columnName';
            if (record.containsKey(prefixedKey)) {
              filteredRecord[aliasName] = record[prefixedKey];
              continue;
            }

            // if the field name itself exists and has no ambiguity, use it directly
            if (record.containsKey(columnName)) {
              filteredRecord[aliasName] = record[columnName];
              continue;
            }
          } else {
            // handle normal field without table name prefix
            if (record.containsKey(fieldName)) {
              filteredRecord[aliasName] = record[fieldName];
            }
          }
        }
        return filteredRecord;
      }).toList();
    }

    return results;
  }

  /// Process multiple table query results, ensure consistent field naming format
  List<Map<String, dynamic>> _processManyTableResults(
      List<Map<String, dynamic>> results) {
    final processedResults = <Map<String, dynamic>>[];

    // if fields are specified, use field selection processing
    if (_selectedFields != null && _selectedFields!.isNotEmpty) {
      for (final record in results) {
        final filteredRecord = <String, dynamic>{};
        for (final field in _selectedFields!) {
          // handle field alias (e.g. "name as username")
          // detect AS keyword in case-insensitive way
          final asPattern = RegExp(r'\s+[aA][sS]\s+');
          final hasAlias = asPattern.hasMatch(field);
          final fieldName = hasAlias ? field.split(asPattern)[0].trim() : field;
          final aliasName = _getFieldAlias(field);

          dynamic fieldValue;

          // handle field with table name prefix (e.g. "users.id")
          if (fieldName.contains('.')) {
            final parts = fieldName.split('.');
            final tableName = parts[0];
            final columnName = parts[1];

            // find dot separated format
            final dotFormat = '$tableName.$columnName';
            if (record.containsKey(dotFormat)) {
              fieldValue = record[dotFormat];
            } else if (record.containsKey(columnName)) {
              // if the field name itself exists and has no ambiguity, use it directly
              fieldValue = record[columnName];
            }
          } else {
            // for fields without prefix, try main table name prefix first
            final prefixedKey = '${$tableName}.$fieldName';
            if (record.containsKey(prefixedKey)) {
              fieldValue = record[prefixedKey];
            } else if (record.containsKey(fieldName)) {
              // no prefix form
              fieldValue = record[fieldName];
            }
          }

          if (fieldValue != null) {
            filteredRecord[aliasName] = fieldValue;
          }
        }
        processedResults.add(filteredRecord);
      }
    } else {
      // when no fields are specified, collect and process field name conflicts
      for (final record in results) {
        // create new record
        final normalizedRecord = <String, dynamic>{};

        // collect all field names and corresponding table names
        final Map<String, Set<String>> fieldToTablesMap = {};
        for (final key in record.keys) {
          if (key.contains('.')) {
            final parts = key.split('.');
            final tableName = parts[0];
            final columnName = parts[1];

            if (!fieldToTablesMap.containsKey(columnName)) {
              fieldToTablesMap[columnName] = {};
            }
            fieldToTablesMap[columnName]!.add(tableName);
          }
        }

        // find fields with conflicts (a field name appears in multiple tables)
        final Set<String> conflictFields = {};
        for (final entry in fieldToTablesMap.entries) {
          if (entry.value.length > 1) {
            conflictFields.add(entry.key);
          }
        }

        //  handle all fields, keep table name prefix for conflict fields
        for (final key in record.keys) {
          if (key.contains('.')) {
            // handle field with table name prefix
            final parts = key.split('.');
            final columnName = parts[1];

            if (conflictFields.contains(columnName)) {
              // field has conflict, keep table name prefix
              normalizedRecord[key] = record[key];
            } else {
              // no conflict, use field name without prefix
              normalizedRecord[columnName] = record[key];
            }
          } else {
            // copy field without prefix
            normalizedRecord[key] = record[key];
          }
        }

        processedResults.add(normalizedRecord);
      }
    }

    return processedResults;
  }

  /// Get field alias, support "field as alias" or "table.field as alias" format
  /// Support any case format of AS keyword
  String _getFieldAlias(String field) {
    // Use regular expression to match AS keyword case-insensitively
    final asPattern = RegExp(r'\s+[aA][sS]\s+');
    if (asPattern.hasMatch(field)) {
      final parts = field.split(asPattern);
      if (parts.length > 1) {
        final alias = parts[1].trim();
        // Validate alias format, only allow letters, numbers, and underscores
        if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(alias)) {
          throw ArgumentError('Invalid alias format: $alias');
        }
        return alias;
      }
    }

    // If the field contains a table name, return the field part as the default alias
    if (field.contains('.')) {
      return field.split('.')[1];
    }

    return field;
  }
}
