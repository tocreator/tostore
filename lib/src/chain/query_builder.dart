part of '../Interface/chain_builder.dart';

/// query builder
class QueryBuilder extends ChainBuilder<QueryBuilder>
    with FutureBuilderMixin<QueryResult<Map<String, dynamic>>> {
  Future<ExecuteResult>? _future;
  List<String>? _selectedFields;

  // related query related properties
  final List<JoinClause> _joins = [];

  // Pending foreign key joins to be resolved during query execution
  List<PendingForeignKeyJoin>? _pendingForeignKeyJoins;

  // query cache control
  bool _enableQueryCache = false;
  Duration? _queryCacheExpiry;

  QueryBuilder(super.db, super.tableName);

  void _invalidateFuture() {
    _future = null;
  }

  @override
  void _onChanged() {
    _invalidateFuture();
  }

  /// select specific fields to return
  QueryBuilder select(List<String> fields) {
    _selectedFields = fields;
    _onChanged();
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
    _onChanged();
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
    _onChanged();
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
    _onChanged();
    return this;
  }

  /// Automatically join a table based on foreign key relationship
  ///
  /// This method automatically finds the foreign key relationship between
  /// the current table and the specified table, and creates a JOIN clause.
  /// The actual foreign key lookup is performed when the query is executed.
  ///
  /// [tableName] The table to join with
  /// [type] The type of join (default: inner)
  ///
  /// Example:
  /// ```dart
  /// // If orders table has a foreign key to users table
  /// db.query('orders')
  ///   .joinWithForeignKey('users')  // Automatically uses orders.user_id = users.id
  ///   .future;
  /// ```
  ///
  /// Throws [StateError] if no foreign key relationship is found
  QueryBuilder joinWithForeignKey(String tableName,
      {JoinType type = JoinType.inner}) {
    // Store the join request - will be resolved during query execution
    _pendingForeignKeyJoins ??= [];
    _pendingForeignKeyJoins!.add(PendingForeignKeyJoin(
      tableName: tableName,
      type: type,
    ));
    _onChanged();
    return this;
  }

  /// Join with a table that is referenced by the current table (via foreign key)
  ///
  /// This is a convenience method for joining with a parent/referenced table.
  /// It's equivalent to joinWithForeignKey but with clearer semantics.
  ///
  /// Example:
  /// ```dart
  /// // orders table references users table via user_id
  /// db.query('orders')
  ///   .joinReferencedTable('users')  // JOIN users ON orders.user_id = users.id
  ///   .future;
  /// ```
  QueryBuilder joinReferencedTable(String tableName,
      {JoinType type = JoinType.inner}) {
    return joinWithForeignKey(tableName, type: type);
  }

  /// Join with a table that references the current table (reverse foreign key)
  ///
  /// This joins with a child table that has a foreign key pointing to the current table.
  ///
  /// Example:
  /// ```dart
  /// // users table is referenced by orders table
  /// db.query('users')
  ///   .joinReferencingTable('orders')  // JOIN orders ON users.id = orders.user_id
  ///   .future;
  /// ```
  QueryBuilder joinReferencingTable(String tableName,
      {JoinType type = JoinType.left}) {
    return joinWithForeignKey(tableName, type: type);
  }

  /// Enable query result caching for this query
  /// If [expiry] is provided, the cache will be considered stale after this duration
  /// If no expiry is provided, the cache will not expire based on time
  QueryBuilder useQueryCache([Duration? expiry]) {
    _enableQueryCache = true;
    _queryCacheExpiry = expiry;
    _onChanged();
    return this;
  }

  /// Disable query result caching for this query, overriding the global setting.
  QueryBuilder noQueryCache() {
    _enableQueryCache = false;
    _onChanged();
    return this;
  }

  /// Clear the query cache for the current query condition.
  ///
  /// Returns `true` if the operation completes successfully (meaning the cache
  /// is clear, regardless of whether it was present before).
  /// Returns `false` only if an error occurred during the process.
  Future<bool> clearQueryCache() async {
    await _db.ensureInitialized();

    // Build cache key to ensure correct matching
    final cacheKey = QueryCacheKey(
      tableName: _tableName,
      condition: queryCondition,
      orderBy: _orderBy,
      limit: _limit,
      offset: _offset,
      cursor: _cursor,
    );
    return _db.queryExecutor.clearQueryCacheForKey(cacheKey);
  }

  /// get first record
  Future<Map<String, dynamic>?> first() async {
    limit(1);
    final results = await this;
    return results.data.isEmpty ? null : results.data.first;
  }

  /// get record count
  Future<int> count() async {
    // if there are no conditions, get total count from metadata
    if (queryCondition.isEmpty) {
      return await _db.tableDataManager.getTableRecordCount(_tableName);
    }

    // otherwise, execute query and calculate count of records
    final results = await this;
    return results.data.length;
  }

  @override
  Future<QueryResult<Map<String, dynamic>>> get future async {
    if (_future == null) {
      final result = await _executeQuery();
      return QueryResult.success(
        data: result.records,
        prevCursor: result.prevCursor,
        nextCursor: result.nextCursor,
        hasMore: result.hasMore,
        hasPrev: result.hasPrev,
        tableTotalCount: result.tableTotalCount,
        executionTimeMs: result.executionTimeMs,
      );
    }
    final result = await _future!;
    return QueryResult.success(
      data: result.records,
      prevCursor: result.prevCursor,
      nextCursor: result.nextCursor,
      hasMore: result.hasMore,
      hasPrev: result.hasPrev,
      tableTotalCount: result.tableTotalCount,
      executionTimeMs: result.executionTimeMs,
    );
  }

  /// Watch for changes matching this query
  Stream<List<Map<String, dynamic>>> watch() {
    // Create a controller to manage the stream
    late StreamController<List<Map<String, dynamic>>> controller;
    StreamSubscription? subscription;

    controller = StreamController<List<Map<String, dynamic>>>(
      onListen: () async {
        // 1. Emit initial value
        try {
          _invalidateFuture();
          final initialData = await this;
          controller.add(initialData.data);
        } catch (e) {
          controller.addError(e);
        }

        // 2. Subscribe to changes
        // We need to ensure db is initialized before accessing notificationManager
        await _db.ensureInitialized();

        subscription = _db.notificationManager.register(
          _tableName,
          queryCondition,
          (event) async {
            // Re-execute query on change
            try {
              _invalidateFuture();
              final newData = await this;
              controller.add(newData.data);
            } catch (e) {
              controller.addError(e);
            }
          },
        );
      },
      onCancel: () async {
        await subscription?.cancel();
      },
    );

    return controller.stream;
  }

  /// execute query
  Future<ExecuteResult> _executeQuery() async {
    await _db.ensureInitialized();

    // Resolve pending foreign key joins
    if (_pendingForeignKeyJoins != null &&
        _pendingForeignKeyJoins!.isNotEmpty) {
      await _resolveForeignKeyJoins();
    }

    // Directly use QueryExecutor to execute query (optimizer runs inside executor).
    final result = await _db.getQueryExecutor()?.execute(
              _tableName,
              condition: queryCondition,
              orderBy: _orderBy,
              limit: _limit,
              offset: _offset,
              cursor: _cursor,
              joins: _joins,
              enableQueryCache: _enableQueryCache,
              queryCacheExpiry: _queryCacheExpiry,
            ) ??
        const ExecuteResult.empty();

    List<Map<String, dynamic>> results = result.records;

    // process related query results, ensure consistent field naming format
    if (_joins.isNotEmpty) {
      final processed = _processManyTableResults(results);
      return ExecuteResult(
        records: processed,
        nextCursor: result.nextCursor,
        prevCursor: result.prevCursor,
        hasMore: result.hasMore,
        hasPrev: result.hasPrev,
        executionTimeMs: result.executionTimeMs,
        tableTotalCount: result.tableTotalCount,
      );
    }

    // if fields are specified, only return selected fields
    if (_selectedFields != null && _selectedFields!.isNotEmpty) {
      final filtered = results.map((record) {
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
      return ExecuteResult(
        records: filtered,
        nextCursor: result.nextCursor,
        prevCursor: result.prevCursor,
        hasMore: result.hasMore,
        hasPrev: result.hasPrev,
        executionTimeMs: result.executionTimeMs,
        tableTotalCount: result.tableTotalCount,
      );
    }

    return ExecuteResult(
      records: results,
      nextCursor: result.nextCursor,
      prevCursor: result.prevCursor,
      hasMore: result.hasMore,
      hasPrev: result.hasPrev,
      executionTimeMs: result.executionTimeMs,
      tableTotalCount: result.tableTotalCount,
    );
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
            final prefixedKey = '$_tableName.$fieldName';
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

  /// Resolve pending foreign key joins by looking up foreign key relationships
  Future<void> _resolveForeignKeyJoins() async {
    if (_pendingForeignKeyJoins == null || _pendingForeignKeyJoins!.isEmpty) {
      return;
    }

    // Get current table schema
    final currentSchema = await _db.schemaManager?.getTableSchema(_tableName);
    if (currentSchema == null) {
      throw StateError('Current table $_tableName does not exist');
    }

    for (final pendingJoin in _pendingForeignKeyJoins!) {
      final tableName = pendingJoin.tableName;
      final type = pendingJoin.type;

      // Get target table schema
      final targetSchema = await _db.schemaManager?.getTableSchema(tableName);
      if (targetSchema == null) {
        throw StateError('Target table $tableName does not exist');
      }

      // Try to find foreign key from current table to target table
      ForeignKeySchema? fk;
      for (final foreignKey in currentSchema.foreignKeys) {
        if (foreignKey.referencedTable == tableName && foreignKey.enabled) {
          fk = foreignKey;
          break;
        }
      }

      // If not found, try reverse: find foreign key from target table to current table
      if (fk == null) {
        for (final foreignKey in targetSchema.foreignKeys) {
          if (foreignKey.referencedTable == _tableName && foreignKey.enabled) {
            // Reverse the relationship
            // Current table is referenced by target table
            // So we join: current_table.pk = target_table.fk
            if (foreignKey.fields.length == 1 &&
                foreignKey.referencedFields.length == 1) {
              _joins.add(JoinClause(
                type: type,
                table: tableName,
                firstKey: '$_tableName.${foreignKey.referencedFields.first}',
                operator: '=',
                secondKey: '$tableName.${foreignKey.fields.first}',
              ));
              continue;
            }
          }
        }

        // If still not found, throw error
        if (fk == null) {
          throw StateError(
              'No foreign key relationship found between $_tableName and $tableName. '
              'Please use manual join() method instead.');
        }
      }

      // Found foreign key from current table to target table
      // Join: current_table.fk = target_table.pk
      if (fk.fields.length == 1 && fk.referencedFields.length == 1) {
        // Simple foreign key: single field join
        _joins.add(JoinClause(
          type: type,
          table: tableName,
          firstKey: '$_tableName.${fk.fields.first}',
          operator: '=',
          secondKey: '$tableName.${fk.referencedFields.first}',
        ));
      } else {
        // Composite foreign key: join on first field pair
        // Additional field pairs need to be added as WHERE conditions
        // This is a limitation of the current JoinClause design
        if (fk.fields.isNotEmpty && fk.referencedFields.isNotEmpty) {
          _joins.add(JoinClause(
            type: type,
            table: tableName,
            firstKey: '$_tableName.${fk.fields.first}',
            operator: '=',
            secondKey: '$tableName.${fk.referencedFields.first}',
          ));

          // Add additional field pairs as WHERE conditions for composite foreign keys
          // This ensures all fields in the composite key are matched
          for (int i = 1;
              i < fk.fields.length && i < fk.referencedFields.length;
              i++) {
            queryCondition.where(
              '$_tableName.${fk.fields[i]}',
              '=',
              '$tableName.${fk.referencedFields[i]}',
            );
          }
        }
      }
    }

    // Clear pending joins after resolution
    _pendingForeignKeyJoins = null;
  }
}
