import '../core/table_data_manager.dart';
import '../handler/logger.dart';
import '../core/data_store_impl.dart';
import '../core/index_manager.dart';
import '../model/buffer_entry.dart';
import '../model/index_search.dart';
import '../model/store_index.dart';
import '../model/file_info.dart';
import '../model/join_clause.dart';
import '../model/table_schema.dart';
import 'query_cache.dart';
import 'query_condition.dart';
import 'query_plan.dart';
import '../handler/parallel_processor.dart';
import '../handler/value_matcher.dart';

/// query executor
class QueryExecutor {
  final DataStoreImpl _dataStore;
  final IndexManager _indexManager;

  QueryExecutor(
    this._dataStore,
    this._indexManager,
  );

  /// execute query
  Future<List<Map<String, dynamic>>> execute(
    QueryPlan plan,
    String tableName, {
    QueryCondition? condition,
    List<String>? orderBy,
    int? limit,
    int? offset,
    List<JoinClause>? joins,
    bool? enableQueryCache,
    Duration? queryCacheExpiry,
  }) async {
    try {
      final schemas = <String, TableSchema>{};
      ConditionRecordMatcher? matcher;
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Table $tableName not found, cannot execute query.',
            label: 'QueryExecutor.execute');
        return [];
      }
      schemas[tableName] = schema;

      if (condition != null && !condition.isEmpty) {
        if (joins != null && joins.isNotEmpty) {
          for (final join in joins) {
            if (schemas.containsKey(join.table)) continue;
            final joinSchema = await _dataStore.getTableSchema(join.table);
            if (joinSchema != null) {
              schemas[join.table] = joinSchema;
            } else {
              Logger.warn('Schema for joined table ${join.table} not found.',
                  label: 'QueryExecutor.execute');
            }
          }
        }
        // Normalize condition values before preparing the matcher or executing the plan.
        condition.normalize(schemas, tableName);

        matcher = ConditionRecordMatcher.prepare(condition, schemas, tableName);
      }

      // Don't use cache when there are join queries
      if (joins != null && joins.isNotEmpty) {
        final results = await _executeQueryPlan(
            plan, tableName, condition, joins, schemas, matcher);
        if (orderBy != null) {
          await _applySort(results, orderBy, schemas, tableName);
        }
        return _paginateResults(results, limit, offset);
      }

      // Determine if query cache should be used
      bool shouldUseQueryCache = enableQueryCache ??
          (_dataStore.config.shouldEnableQueryCache &&
              !_dataStore.dataCacheManager.isAutoCacheDisabled);

      if (shouldUseQueryCache) {
        final cacheKey = QueryCacheKey(
          tableName: tableName,
          condition: condition ?? QueryCondition(),
          orderBy: orderBy,
          limit: limit,
          offset: offset,
          isUserManaged: enableQueryCache == true,
        );

        /// 1、 try query cache
        final queryResult = _dataStore.dataCacheManager.getQuery(cacheKey);
        if (queryResult != null) {
          // convert cache result to Map to update
          final resultMap = <String, Map<String, dynamic>>{};
          for (var record in queryResult) {
            resultMap[record[schema.primaryKey].toString()] =
                Map<String, dynamic>.from(record);
          }

          // convert back to list
          final updatedResults = resultMap.values.toList();
          // apply sort and pagination
          if (orderBy != null) {
            await _applySort(updatedResults, orderBy, schemas, tableName);
          }
          final filteredResults = await _filterPendingBuffer(
              tableName, updatedResults, matcher,
              applyWriteBuffer: true);
          // query cache is already the correct return result, no need to paginate again
          return _paginateResults(filteredResults, limit, offset);
        }
      }

      // 2. try to use cache
      final cache = _dataStore.dataCacheManager.getEntireTable(tableName);
      if (cache != null) {
        // check cache type and query condition
        final isFullCache =
            await _dataStore.dataCacheManager.isTableFullyCached(tableName);
        final isSpecificQuery =
            condition != null && await _isSpecificQuery(tableName, condition);

        // decide whether to use cache
        if (isFullCache || isSpecificQuery) {
          var results = cache;

          bool isPrimaryKeyQuery = false;

          // Check if it is a primary key query, can use O(1) complexity query optimization
          if (condition != null) {
            final conditions = condition.build();

            if (conditions.containsKey(schema.primaryKey)) {
              final pkCondition = conditions[schema.primaryKey];

              // Primary key equal query (=)
              if (pkCondition is Map && pkCondition.containsKey('=')) {
                final pkValue = pkCondition['=']?.toString();
                if (pkValue != null) {
                  final record = _dataStore.dataCacheManager
                      .getRecordByPrimaryKey(tableName, pkValue);
                  if (record != null) {
                    results = [record];
                    isPrimaryKeyQuery = true;
                  }
                }
              }

              // Primary key IN query, batch get multiple records
              else if (pkCondition is Map && pkCondition.containsKey('IN')) {
                final pkValues = (pkCondition['IN'] as List?)
                    ?.map((e) => e.toString())
                    .toList();
                if (pkValues != null && pkValues.isNotEmpty) {
                  results = await _dataStore.dataCacheManager
                      .getRecordsByPrimaryKeys(tableName, pkValues);
                  isPrimaryKeyQuery = results.isNotEmpty;
                }
              }
            }
          }

          if (matcher != null) {
            results = results.where((record) {
              return matcher!.matches(record);
            }).toList();
          }

          if (orderBy != null) {
            await _applySort(results, orderBy, schemas, tableName);
          }

          // Update access time
          _dataStore.dataCacheManager.recordTableAccess(tableName);

          // if not primary key query, cache it
          if (shouldUseQueryCache && !isPrimaryKeyQuery) {
            if (await _dataStore.dataCacheManager
                .shouldCacheQuery(results: results)) {
              // Create query cache key
              final cacheKey = QueryCacheKey(
                tableName: tableName,
                condition: condition ?? QueryCondition(),
                orderBy: orderBy,
                limit: limit,
                offset: offset,
                isUserManaged: enableQueryCache == true,
              );

              await _dataStore.dataCacheManager.cacheQuery(
                cacheKey,
                results,
                {tableName},
                expiryDuration: queryCacheExpiry,
              );
            }
          }
          if (results.isNotEmpty || isFullCache) {
            return _paginateResults(results, limit, offset);
          }
        }
      }

      // 3. execute actual query
      final results = await _executeQueryPlan(
          plan, tableName, condition, joins, schemas, matcher);

      // 4. apply sort
      if (orderBy != null) {
        await _applySort(results, orderBy, schemas, tableName);
      }

      // 5. apply pagination and return results
      final filteredResults = await _filterPendingBuffer(
          tableName, results, matcher,
          applyWriteBuffer: true);

      // 6. Cache results if query cache is enabled
      if (shouldUseQueryCache) {
        if (await _dataStore.dataCacheManager
            .shouldCacheQuery(results: filteredResults)) {
          // Create query cache key
          final cacheKey = QueryCacheKey(
            tableName: tableName,
            condition: condition ?? QueryCondition(),
            orderBy: orderBy,
            limit: limit,
            offset: offset,
            isUserManaged: enableQueryCache == true,
          );

          await _dataStore.dataCacheManager.cacheQuery(
            cacheKey,
            filteredResults,
            {tableName},
            expiryDuration: queryCacheExpiry,
          );
        }
      }

      final paginatedResults = _paginateResults(filteredResults, limit, offset);
      return paginatedResults;
    } catch (e, stackTrace) {
      Logger.error('query execution failed: $e',
          label: 'QueryExecutor.execute');
      Logger.debug('stack trace: $stackTrace');
      rethrow;
    }
  }

  /// execute query plan
  Future<List<Map<String, dynamic>>> _executeQueryPlan(
    QueryPlan plan,
    String tableName,
    QueryCondition? condition,
    List<JoinClause>? joins,
    Map<String, TableSchema> schemas,
    ConditionRecordMatcher? matcher,
  ) async {
    List<Map<String, dynamic>> results = [];
    // Save original conditions to apply after JOIN
    final Map<String, dynamic> originalConditions = condition?.build() ?? {};
    Map<String, dynamic> remainingConditions =
        Map<String, dynamic>.from(originalConditions);

    for (QueryOperation operation in plan.operations) {
      switch (operation.type) {
        case QueryOperationType.tableScan:
          // Scan the main table, only apply main table related conditions
          var mainTableConditions =
              _extractTableConditions(remainingConditions, tableName);
          // Create temporary QueryCondition for main table query
          if (mainTableConditions.isNotEmpty) {
            results = await _performTableScan(tableName, matcher);
            // Remove already applied conditions from remaining conditions
            for (var field in mainTableConditions.keys) {
              if (field.startsWith('$tableName.')) {
                remainingConditions.remove(field);
              }
            }
          } else {
            results = await _performTableScan(tableName, null);
          }
          break;

        case QueryOperationType.indexScan:
          // Index scan also only applies main table conditions
          results = await _performIndexScan(
            tableName,
            operation.indexName!,
            operation.value as Map<String, dynamic>,
            matcher, // Use complete conditions, will handle internally
          );
          break;

        case QueryOperationType.primaryKeyScan:
          // Primary key scan directly locates partition file, skipping index query
          results = await _performPrimaryKeyScan(
            tableName,
            operation.value as Map<String, dynamic>,
            matcher,
          );
          break;

        case QueryOperationType.cacheQuery:
          // Read data directly from cache, no need to access files
          final cache = _dataStore.dataCacheManager.getEntireTable(tableName);
          if (cache != null) {
            results = List<Map<String, dynamic>>.from(cache);

            // Record cache access
            _dataStore.dataCacheManager.recordTableAccess(tableName);
          } else {
            results = await _performTableScan(tableName, null);
          }
          break;

        case QueryOperationType.filter:
          // Apply filter conditions to query results
          if (matcher != null) {
            results = results.where((record) {
              return matcher.matches(record);
            }).toList();
          }
          break;

        case QueryOperationType.sort:
          // Extract sort fields and directions from operation value
          final sortFieldsInput = operation.value as List<String>;
          final List<String> sortFields =
              List.filled(sortFieldsInput.length, '');
          final List<bool> sortDirections =
              List.filled(sortFieldsInput.length, true);

          // Process sortFields that may contain sort direction information
          for (int i = 0; i < sortFieldsInput.length; i++) {
            String field = sortFieldsInput[i];

            // 1. Field with "-" prefix indicates descending order
            if (field.startsWith('-')) {
              sortFields[i] = field.substring(1); // Remove "-" symbol
              sortDirections[i] = false; // Set to descending order
            }
            // 2. Field with DESC/ASC suffix
            else if (field.toUpperCase().endsWith(' DESC')) {
              // Remove DESC and set sort direction to descending
              sortFields[i] = field.substring(0, field.length - 5).trim();
              sortDirections[i] = false;
            } else if (field.toUpperCase().endsWith(' ASC')) {
              // Remove ASC, keep ascending
              sortFields[i] = field.substring(0, field.length - 4).trim();
              sortDirections[i] = true;
            } else {
              // No special marker, use original field name, default ascending
              sortFields[i] = field;
            }
          }

          // Use ValueComparator for sorting
          ValueMatcher.sortMapList(
              results, sortFields, sortDirections, schemas, tableName);
          break;

        case QueryOperationType.join:
          final joinInfo = operation.value as Map<String, dynamic>;
          final joinedResults = await _performJoin(
            results,
            joinInfo['table'] as String,
            joinInfo['firstKey'] as String,
            joinInfo['operator'] as String,
            joinInfo['secondKey'] as String,
            joinInfo['type'] as String,
            schemas,
            tableName,
          );
          results = joinedResults;

          // Extract conditions for the current joined table and apply
          final joinTableName = joinInfo['table'] as String;
          final joinTableConditions =
              _extractTableConditions(remainingConditions, joinTableName);

          // Apply joined table conditions
          if (joinTableConditions.isNotEmpty) {
            if (matcher != null) {
              results = results.where((record) {
                return matcher.matches(record);
              }).toList();
            }

            // Remove applied conditions from remaining conditions
            for (var field in joinTableConditions.keys) {
              if (field.startsWith('$joinTableName.')) {
                remainingConditions.remove(field);
              }
            }
          }
          break;
      }
    }

    // Apply any remaining conditions (may be cross-table or unhandled conditions)
    if (remainingConditions.isNotEmpty) {
      if (matcher != null) {
        results = results.where((record) {
          return matcher.matches(record);
        }).toList();
      }
    }

    return results;
  }

  /// Extract conditions for specified table from condition map
  Map<String, dynamic> _extractTableConditions(
      Map<String, dynamic> conditions, String tableName) {
    final result = <String, dynamic>{};

    // Process non-cascading conditions
    for (var entry in conditions.entries) {
      final field = entry.key;

      // Handle special operators
      if (field == 'OR' || field == 'AND') {
        continue; // Skip complex conditions for now
      }

      // Extract fields with table name prefix
      if (field.startsWith('$tableName.')) {
        result[field] = entry.value;
      }
      // handle fields without table name prefix (only when tableName is main table)
      else if (!field.contains('.')) {
        // fields without table name prefix are considered main table fields
        result[field] = entry.value;
      }
    }

    return result;
  }

  /// Execute table join operation
  Future<List<Map<String, dynamic>>> _performJoin(
    List<Map<String, dynamic>> leftRecords,
    String rightTableName,
    String leftKey,
    String operator,
    String rightKey,
    String joinType,
    Map<String, TableSchema> schemas,
    String mainTableName,
  ) async {
    // Get all records from the right table
    final rightRecords = await _performTableScan(rightTableName, null);
    final resultRecords = <Map<String, dynamic>>[];

    // Determine left table name (main table name)
    String leftTableName = '';
    if (leftKey.contains('.')) {
      leftTableName = leftKey.split('.')[0];
    }

    // Handle different JOIN types
    switch (joinType) {
      case 'inner':
        // Inner join: only return records matching in both tables
        for (var i = 0; i < leftRecords.length; i++) {
          final leftRecord = leftRecords[i];
          // Find all matching right table records
          final matchingRightRecords = rightRecords
              .where((rightRecord) => _matchJoinCondition(
                  leftRecord,
                  rightRecord,
                  leftKey,
                  operator,
                  rightKey,
                  schemas,
                  mainTableName))
              .toList();

          // Only add result if matches found
          for (var i = 0; i < matchingRightRecords.length; i++) {
            final rightRecord = matchingRightRecords[i];
            // Create new record for consistency
            final joinedRecord = <String, dynamic>{};

            // Handle left table fields (main table), keep table prefix if exists, add if not
            for (var entry in leftRecord.entries) {
              final key = entry.key;
              final value = entry.value;

              // If already has table prefix, use as is
              if (key.contains('.')) {
                joinedRecord[key] = value;
              } else if (leftTableName.isNotEmpty) {
                // Add prefix for main table fields (if main table name exists)
                joinedRecord['$leftTableName.$key'] = value;
              } else {
                // Keep as is when main table name is unclear
                joinedRecord[key] = value;
              }
            }

            // Add prefix for right table fields
            for (var entry in rightRecord.entries) {
              final fieldName = entry.key;
              final fieldValue = entry.value;

              // Only add fields with dot format prefix
              joinedRecord['$rightTableName.$fieldName'] = fieldValue;
            }

            resultRecords.add(joinedRecord);
          }
          if (i % 50 == 0) {
            await Future.delayed(Duration.zero);
          }
        }
        break;

      case 'left':
        // Left join: returns all records from left table, even if there are no matches in right table
        for (var i = 0; i < leftRecords.length; i++) {
          final leftRecord = leftRecords[i];
          // Find all matching right table records
          final matchingRightRecords = rightRecords
              .where((rightRecord) => _matchJoinCondition(
                  leftRecord,
                  rightRecord,
                  leftKey,
                  operator,
                  rightKey,
                  schemas,
                  mainTableName))
              .toList();

          if (matchingRightRecords.isNotEmpty) {
            // Has matches, add all matching records
            for (var i = 0; i < matchingRightRecords.length; i++) {
              final rightRecord = matchingRightRecords[i];
              // Create new record
              final joinedRecord = <String, dynamic>{};

              // Process left table fields (main table)
              for (var entry in leftRecord.entries) {
                final key = entry.key;
                final value = entry.value;

                // If already has table prefix, use as is
                if (key.contains('.')) {
                  joinedRecord[key] = value;
                } else if (leftTableName.isNotEmpty) {
                  // Add prefix for main table fields (if main table name exists)
                  joinedRecord['$leftTableName.$key'] = value;
                } else {
                  // Keep as is when main table name is unclear
                  joinedRecord[key] = value;
                }
              }

              // Only add fields with dot format prefix
              for (var entry in rightRecord.entries) {
                final fieldName = entry.key;
                final fieldValue = entry.value;

                joinedRecord['$rightTableName.$fieldName'] = fieldValue;
              }

              resultRecords.add(joinedRecord);
              if (i % 50 == 0) {
                await Future.delayed(Duration.zero);
              }
            }
          } else {
            // No matches, add left record and fill right table fields with null
            // Create new record
            final joinedRecord = <String, dynamic>{};

            // Process left table fields (main table)
            for (var entry in leftRecord.entries) {
              final key = entry.key;
              final value = entry.value;

              // If already has table prefix, use as is
              if (key.contains('.')) {
                joinedRecord[key] = value;
              } else if (leftTableName.isNotEmpty) {
                // Add prefix for main table fields (if main table name exists)
                joinedRecord['$leftTableName.$key'] = value;
              } else {
                // Keep as is when main table name is unclear
                joinedRecord[key] = value;
              }
            }

            // Create an empty right table record (all fields null)
            if (rightRecords.isNotEmpty) {
              for (var entry in rightRecords.first.entries) {
                final fieldName = entry.key;

                // Only add fields with dot format prefix
                joinedRecord['$rightTableName.$fieldName'] = null;
              }
            }

            resultRecords.add(joinedRecord);
          }
          if (i % 50 == 0) {
            await Future.delayed(Duration.zero);
          }
        }
        break;

      case 'right':
        // Right join: returns all records from right table, even if there are no matches in left table
        for (var i = 0; i < rightRecords.length; i++) {
          final rightRecord = rightRecords[i];
          // Find all matching left table records
          final matchingLeftRecords = leftRecords
              .where((leftRecord) => _matchJoinCondition(
                  leftRecord,
                  rightRecord,
                  leftKey,
                  operator,
                  rightKey,
                  schemas,
                  mainTableName))
              .toList();

          if (matchingLeftRecords.isNotEmpty) {
            // Has matches, add all matching records
            for (var i = 0; i < matchingLeftRecords.length; i++) {
              final leftRecord = matchingLeftRecords[i];
              // Create new record
              final joinedRecord = <String, dynamic>{};

              // Process left table fields (main table)
              for (var entry in leftRecord.entries) {
                final key = entry.key;
                final value = entry.value;

                // If already has table prefix, use as is
                if (key.contains('.')) {
                  joinedRecord[key] = value;
                } else if (leftTableName.isNotEmpty) {
                  // Add prefix for main table fields (if main table name exists)
                  joinedRecord['$leftTableName.$key'] = value;
                } else {
                  // Keep as is when main table name is unclear
                  joinedRecord[key] = value;
                }
              }

              // Only add fields with dot format prefix
              for (var entry in rightRecord.entries) {
                final fieldName = entry.key;
                final fieldValue = entry.value;

                joinedRecord['$rightTableName.$fieldName'] = fieldValue;
              }

              resultRecords.add(joinedRecord);
              if (i % 50 == 0) {
                await Future.delayed(Duration.zero);
              }
            }
          } else {
            // No matches, create empty left table record
            final joinedRecord = <String, dynamic>{};

            // Add null values for left table fields
            if (leftRecords.isNotEmpty) {
              for (var entry in leftRecords.first.entries) {
                final key = entry.key;

                // If already has table prefix, use as is
                if (key.contains('.')) {
                  joinedRecord[key] = null;
                } else if (leftTableName.isNotEmpty) {
                  // Add prefix for main table fields (if main table name exists)
                  joinedRecord['$leftTableName.$key'] = null;
                } else {
                  // Keep as is when main table name is unclear
                  joinedRecord[key] = null;
                }
              }
            }

            // Only add fields with dot format prefix
            for (var entry in rightRecord.entries) {
              final fieldName = entry.key;
              final fieldValue = entry.value;

              joinedRecord['$rightTableName.$fieldName'] = fieldValue;
            }

            resultRecords.add(joinedRecord);
            if (i % 50 == 0) {
              await Future.delayed(Duration.zero);
            }
          }
          if (i % 50 == 0) {
            await Future.delayed(Duration.zero);
          }
        }
        break;
    }

    return resultRecords;
  }

  /// Check if two records match the join condition
  bool _matchJoinCondition(
    Map<String, dynamic> leftRecord,
    Map<String, dynamic> rightRecord,
    String leftKey,
    String operator,
    String rightKey,
    Map<String, TableSchema> schemas,
    String mainTableName,
  ) {
    // Handle fields with table names (like 'users.id')
    final leftFieldName =
        leftKey.contains('.') ? leftKey.split('.').last : leftKey;

    final leftSchema = ConditionRecordMatcher.getSchemaForField(
        leftKey, schemas, mainTableName);
    if (leftSchema == null) {
      Logger.warn('Could not find schema for join key $leftKey',
          label: 'QueryExecutor._matchJoinCondition');
      return false;
    }

    final matcher =
        ValueMatcher.getMatcher(leftSchema.getFieldMatcherType(leftFieldName));

    // Try to get left value: first check for complete table name prefix field, then check for non-prefixed field
    dynamic leftValue =
        ConditionRecordMatcher.getFieldValue(leftRecord, leftKey);
    // Try to get right value: first check for complete table name prefix field, then check for non-prefixed field
    dynamic rightValue =
        ConditionRecordMatcher.getFieldValue(rightRecord, rightKey);
    if (leftValue == null || rightValue == null) {
      // If either is null, only '=' or '!=' can be true
      if (operator == '=') return leftValue == rightValue;
      if (operator == '!=' || operator == '<>') return leftValue != rightValue;
      return false;
    }

    final comparison = matcher(leftValue, rightValue);

    // Handle different operators
    switch (operator) {
      case '=':
        return comparison == 0;
      case '<':
        return comparison < 0;
      case '>':
        return comparison > 0;
      case '<=':
        return comparison <= 0;
      case '>=':
        return comparison >= 0;
      case '!=':
      case '<>':
        return comparison != 0;
      default:
        return false;
    }
  }

  /// Attempts to retrieve results from a fully cached table.
  /// Returns the results if the table is fully cached, otherwise returns null.
  Future<List<Map<String, dynamic>>?> _tryGetFromFullTableCache(
    String tableName,
    ConditionRecordMatcher? matcher,
  ) async {
    if (await _dataStore.dataCacheManager.isTableFullyCached(tableName)) {
      final cache = _dataStore.dataCacheManager.getEntireTable(tableName);
      if (cache != null) {
        final cacheTime =
            _dataStore.dataCacheManager.getTableCacheTime(tableName);
        if (cacheTime != null &&
            !_dataStore.tableDataManager.isFileModified(tableName, cacheTime)) {
          var results = cache;
          if (matcher != null) {
            results = results.where((record) {
              return matcher.matches(record);
            }).toList();
          }
          return results;
        }
      }
    }
    return null;
  }

  /// perform table scan with optimized partition loading
  Future<List<Map<String, dynamic>>> _performTableScan(
    String tableName,
    ConditionRecordMatcher? matcher,
  ) async {
    final schema = await _dataStore.getTableSchema(tableName);
    if (schema == null) {
      return [];
    }

    // 1. Check for an existing, valid full cache.
    final cachedResults = await _tryGetFromFullTableCache(tableName, matcher);
    if (cachedResults != null) {
      return cachedResults;
    }

    // 2. Check if another thread is performing a full load. If so, wait.
    if (_dataStore.tableDataManager.isTableInFullLoad(tableName)) {
      final bool cacheWasPopulated =
          await _dataStore.tableDataManager.awaitFullTableLoad(tableName);

      // After waiting, if the leader successfully populated the cache, try reading from it.
      if (cacheWasPopulated) {
        final postWaitResults =
            await _tryGetFromFullTableCache(tableName, matcher);
        if (postWaitResults != null) {
          return postWaitResults;
        }
      }
      // If the cache was NOT populated by the leader, we must perform our own scan.
      // We fall through to the main logic below.
    }

    final primaryKey = schema.primaryKey;
    final isGlobal = schema.isGlobal;
    final fileMeta =
        await _dataStore.tableDataManager.getTableFileMeta(tableName);

    // 3. Handle case where table has no data/partitions.
    if (fileMeta == null ||
        fileMeta.partitions == null ||
        fileMeta.partitions!.isEmpty) {
      // An empty table is considered "fully scanned". Attempt to cache this result.
      final bool canCache =
          await _dataStore.tableDataManager.allowFullTableCache(tableName);
      if (canCache) {
        _dataStore.tableDataManager.snapshotBuffersForFullLoad(tableName);
        try {
          // Cache the empty result and mark as fully cached.
          await _dataStore.dataCacheManager.cacheEntireTable(
              tableName, primaryKey, [],
              isFullTableCache: true);
          // There are no staged changes to merge, but we must clear the snapshot.
          _dataStore.tableDataManager.getAndClearStagedChanges(tableName);
        } finally {
          _dataStore.tableDataManager.completeFullLoad(tableName, true);
        }
      }
      return []; // Return empty result.
    }

    // 4. Determine if this query constitutes a full scan by checking partitions.
    final conditions = matcher?.condition.build();
    final targetPartitions = await _getTargetPartitions(
        tableName, isGlobal, conditions, primaryKey, fileMeta);

    final isFullScanIntent =
        targetPartitions.length == fileMeta.partitions!.length;

    // 5. Decide if this query should become the leader for caching.
    final bool canCacheFullTable =
        await _dataStore.tableDataManager.allowFullTableCache(tableName);
    final bool shouldBecomeLeader = isFullScanIntent && canCacheFullTable;

    // 6. If we become the leader, signal it so others will wait.
    if (shouldBecomeLeader) {
      _dataStore.tableDataManager.snapshotBuffersForFullLoad(tableName);
    }

    bool wasFullTableScan = false;
    try {
      final resultMap = <String, Map<String, dynamic>>{};
      final controller = ParallelController();

      // 7. Execute the scan over the target partitions.
      if (targetPartitions.isNotEmpty) {
        // --- Start: Early Exit Optimization ---
        String? earlyExitField;
        dynamic earlyExitValue;
        MatcherFunction? earlyExitMatcher;

        final exactPkMatch = _getExactPrimaryKeyValue(conditions, primaryKey);
        if (exactPkMatch != null) {
          earlyExitField = primaryKey;
          earlyExitValue = exactPkMatch;
          earlyExitMatcher =
              ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());
        } else if (conditions != null) {
          for (final field in schema.fields) {
            if (field.unique && conditions.containsKey(field.name)) {
              final fieldCondition = conditions[field.name];
              if (fieldCondition is Map && fieldCondition.containsKey('=')) {
                earlyExitField = field.name;
                earlyExitValue = fieldCondition['='];
                earlyExitMatcher =
                    ValueMatcher.getMatcher(field.getMatcherType());
                break;
              }
            }
          }

          // If no direct unique field was found, check for unique indexes.
          if (earlyExitField == null) {
            for (final index in schema.indexes) {
              // The optimization only applies to single-field unique indexes.
              if (index.unique && index.fields.length == 1) {
                final fieldName = index.fields.first;
                if (conditions.containsKey(fieldName)) {
                  final fieldCondition = conditions[fieldName];
                  if (fieldCondition is Map &&
                      fieldCondition.containsKey('=')) {
                    earlyExitField = fieldName;
                    earlyExitValue = fieldCondition['='];
                    final field = schema.fields.firstWhere(
                        (f) => f.name == fieldName,
                        orElse: () => throw Exception(
                            'Field $fieldName from index not found in schema'));
                    earlyExitMatcher =
                        ValueMatcher.getMatcher(field.getMatcherType());
                    break; // Found a usable unique index, stop searching.
                  }
                }
              }
            }
          }
        }
        // --- End: Early Exit Optimization ---

        final tasks = targetPartitions.map((partitionIndex) {
          return () async {
            if (controller.isStopped) {
              return <Map<String, dynamic>>[];
            }
            final records = await _dataStore.tableDataManager
                .readRecordsFromPartition(
                    tableName, isGlobal, partitionIndex, primaryKey);

            final partitionResults = <Map<String, dynamic>>[];
            for (var i = 0; i < records.length; i++) {
              final record = records[i];
              if (isDeletedRecord(record)) continue;
              if (i % 50 == 0) {
                await Future.delayed(Duration.zero);
              }

              // Optimization: If we're looking for a specific unique key, check it first.
              // If it doesn't match, we can skip the more expensive full matcher.
              if (earlyExitField != null &&
                  earlyExitMatcher!(record[earlyExitField], earlyExitValue) !=
                      0) {
                continue;
              }

              if (matcher == null || matcher.matches(record)) {
                partitionResults.add(record);
                // Early exit optimization for PK or Unique Key match
                if (earlyExitField != null) {
                  controller.stop();
                  break;
                }
              }
            }
            return partitionResults;
          };
        }).toList();

        final resultsFromPartitions =
            await ParallelProcessor.execute<List<Map<String, dynamic>>>(tasks,
                controller: controller,
                label: 'QueryExecutor._performTableScan.optimized');

        int processedCount = 0;
        for (final recordList in resultsFromPartitions) {
          for (final record in recordList ?? []) {
            resultMap[record[primaryKey].toString()] = record;
          }
          processedCount++;
          if (processedCount % 50 == 0) {
            await Future.delayed(Duration.zero);
          }
        }
      }

      // 8. Determine if a full scan was actually completed.
      wasFullTableScan = isFullScanIntent && !controller.isStopped;

      // 9. If we were the leader, handle caching.
      if (shouldBecomeLeader) {
        if (wasFullTableScan) {
          // We successfully did a full scan, so cache the results.
          await _dataStore.dataCacheManager.cacheEntireTable(
            tableName,
            primaryKey,
            resultMap.values.toList(),
            isFullTableCache: false, // Don't mark as full yet
          );

          // Merge changes that happened during the scan.
          final stagedChanges =
              _dataStore.tableDataManager.getAndClearStagedChanges(tableName);

          int processedCount = 0;
          for (final entry in stagedChanges.writes.values) {
            final record = entry.data;
            if (entry.operation == BufferOperationType.insert) {
              _dataStore.dataCacheManager.addCachedRecord(tableName, record);
            } else if (entry.operation == BufferOperationType.update) {
              _dataStore.dataCacheManager.updateCachedRecord(tableName, record);
            }
            processedCount++;
            if (processedCount % 50 == 0) {
              await Future.delayed(Duration.zero);
            }
          }

          int deleteProcessedCount = 0;
          for (final key in stagedChanges.deletes) {
            _dataStore.dataCacheManager
                .removeTableCacheForPrimaryKey(tableName, key);
            deleteProcessedCount++;
            if (deleteProcessedCount % 50 == 0) {
              await Future.delayed(Duration.zero);
            }
          }

          // Now mark the cache as full and valid.
          await _dataStore.dataCacheManager.setFullTableCache(tableName, true);
        } else {
          // We were the leader, but we didn't do a full scan (e.g., early exit).
          // Do not cache. Just clean up the staging buffers.
          _dataStore.tableDataManager.getAndClearStagedChanges(tableName);
        }
      }
      return resultMap.values.toList();
    } finally {
      // 10. If we were the leader, signal completion and success status.
      if (shouldBecomeLeader) {
        _dataStore.tableDataManager
            .completeFullLoad(tableName, wasFullTableScan);
      }
    }
  }

  /// Helper class to represent a parsed query range.
  _QueryRange _parsePkRange(dynamic pkCondition) {
    final range = _QueryRange();

    if (pkCondition is Map) {
      // Equality
      if (pkCondition.containsKey('=')) {
        range.min = range.max = pkCondition['='];
        range.includeMin = range.includeMax = true;
        return range;
      }

      // Range operators
      if (pkCondition.containsKey('>')) {
        range.min = pkCondition['>'];
        range.includeMin = false;
      } else if (pkCondition.containsKey('>=')) {
        range.min = pkCondition['>='];
        range.includeMin = true;
      }

      if (pkCondition.containsKey('<')) {
        range.max = pkCondition['<'];
        range.includeMax = false;
      } else if (pkCondition.containsKey('<=')) {
        range.max = pkCondition['<='];
        range.includeMax = true;
      }

      // Between operator
      if (pkCondition.containsKey('BETWEEN')) {
        final between = pkCondition['BETWEEN'] as Map;
        range.min = between['start'];
        range.max = between['end'];
        range.includeMin = range.includeMax = true; // BETWEEN is inclusive
      }
    } else {
      // Direct value match, e.g., where('id', 123)
      range.min = range.max = pkCondition;
      range.includeMin = range.includeMax = true;
    }

    return range;
  }

  /// Determine which partitions to load based on query conditions
  Future<List<int>> _getTargetPartitions(
    String tableName,
    bool isGlobal,
    Map<String, dynamic>? conditions,
    String primaryKey,
    FileMeta fileMeta,
  ) async {
    // If no conditions or no partitions, return all partition indexes
    if (conditions == null ||
        fileMeta.partitions == null ||
        fileMeta.partitions!.isEmpty) {
      return fileMeta.partitions?.map((c) => c.index).toList() ?? [];
    }

    final schema = await _dataStore.getTableSchema(tableName);
    if (schema == null) {
      return fileMeta.partitions?.map((c) => c.index).toList() ?? [];
    }
    final pkMatcher =
        ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());

    // This function only prunes partitions based on the primary key.
    // If there's no condition on the PK, we must scan all partitions.
    if (!conditions.containsKey(primaryKey)) {
      return fileMeta.partitions!.map((c) => c.index).toList()..sort();
    }

    final pkCondition = conditions[primaryKey];

    // Handle the 'IN' operator as a special case first.
    if (pkCondition is Map && pkCondition.containsKey('IN')) {
      final inValues = pkCondition['IN'] as List?;
      if (inValues == null || inValues.isEmpty) {
        return [];
      }
      final targetPartitions = <int>{};
      int processedCount = 0;

      // For each value in the IN list, find which partitions could contain it.
      for (var value in inValues) {
        // Optimization: If partitions are ordered, use binary search for each value.
        if (fileMeta.isOrdered == true) {
          final partitionIndex = await _findPartitionWithBinarySearch(
              fileMeta.partitions!, value, pkMatcher);
          if (partitionIndex != null) {
            targetPartitions.add(partitionIndex);
          }
        } else {
          // Unordered, have to check all partitions for each value.
          int partitionProcessedCount = 0;
          for (var partition in fileMeta.partitions!) {
            if (_isValueInRange(value, partition.minPrimaryKey,
                partition.maxPrimaryKey, pkMatcher)) {
              targetPartitions.add(partition.index);
            }
            partitionProcessedCount++;
            if (partitionProcessedCount % 100 == 0) {
              await Future.delayed(Duration.zero);
            }
          }
        }
        processedCount++;
        if (processedCount % 50 == 0) {
          await Future.delayed(Duration.zero);
        }
      }
      return targetPartitions.toList()..sort();
    }

    // For all other operators (=, >, <, BETWEEN), parse them into a single range.
    final queryRange = _parsePkRange(pkCondition);

    final targetPartitions = <int>[];

    // If this is an exact match on an ordered table, use binary search for a fast path.
    if (fileMeta.isOrdered == true &&
        queryRange.min != null &&
        queryRange.min == queryRange.max) {
      final partitionIndex = await _findPartitionWithBinarySearch(
          fileMeta.partitions!, queryRange.min, pkMatcher);
      if (partitionIndex != null) {
        return [partitionIndex];
      } else {
        // if binary search fails, it means the key is not in any partition range.
        return [];
      }
    }

    int processedCount = 0;
    // For range queries or non-ordered tables, iterate through partitions to find overlaps.
    for (var partition in fileMeta.partitions!) {
      final pMin = partition.minPrimaryKey;
      final pMax = partition.maxPrimaryKey;

      // If a partition has no min/max key info, we must include it as a precaution.
      if (pMin == null || pMax == null) {
        targetPartitions.add(partition.index);
        continue;
      }

      // Logic to check if the query range [queryRange.min, queryRange.max] overlaps with the partition range [pMin, pMax].
      // There is NO overlap if (partition ends before query begins) OR (partition begins after query ends).

      // Condition 1: Partition ends before query begins.
      // e.g., partition is [5, 10] and query is (> 10) or (>= 11)
      bool partitionEndsBeforeQueryStarts = false;
      if (queryRange.min != null) {
        final cmp = pkMatcher(pMax, queryRange.min);
        if (cmp < 0) {
          // pMax < queryRange.min
          partitionEndsBeforeQueryStarts = true;
        }
        if (cmp == 0 && !queryRange.includeMin) {
          // pMax == queryRange.min, but query is exclusive (e.g., >)
          partitionEndsBeforeQueryStarts = true;
        }
      }

      // Condition 2: Partition begins after query ends.
      // e.g., partition is [20, 30] and query is (< 20) or (<= 19)
      bool partitionStartsAfterQueryEnds = false;
      if (queryRange.max != null) {
        final cmp = pkMatcher(pMin, queryRange.max);
        if (cmp > 0) {
          // pMin > queryRange.max
          partitionStartsAfterQueryEnds = true;
        }
        if (cmp == 0 && !queryRange.includeMax) {
          // pMin == queryRange.max, but query is exclusive (e.g., <)
          partitionStartsAfterQueryEnds = true;
        }
      }

      // If there is no gap between the ranges, it's an overlap.
      if (!(partitionEndsBeforeQueryStarts || partitionStartsAfterQueryEnds)) {
        targetPartitions.add(partition.index);
      }
      processedCount++;
      if (processedCount % 50 == 0) {
        await Future.delayed(Duration.zero);
      }
    }

    return targetPartitions..sort();
  }

  /// Check if a value is within a range (inclusive)
  bool _isValueInRange(
      dynamic value, dynamic min, dynamic max, MatcherFunction matcher) {
    if (min == null || max == null || value == null) return true;
    return matcher(value, min) >= 0 && matcher(value, max) <= 0;
  }

  /// Get exact primary key value if condition has a direct equality match
  dynamic _getExactPrimaryKeyValue(
      Map<String, dynamic>? conditions, String primaryKey) {
    if (conditions == null || !conditions.containsKey(primaryKey)) return null;

    final pkCondition = conditions[primaryKey];
    if (pkCondition is! Map) {
      // Direct equality
      return pkCondition;
    }

    if (pkCondition.containsKey('=')) {
      return pkCondition['='];
    }

    return null;
  }

  /// Perform primary key scan, directly locate partition file through primary key range mapping
  ///
  /// This method is optimized for primary key queries, compared to index queries:
  /// 1. Avoid loading large index data
  /// 2. Directly use primary key range mapping in table metadata to find corresponding partition
  /// 3. Only read partition files containing target primary key
  Future<List<Map<String, dynamic>>> _performPrimaryKeyScan(
    String tableName,
    Map<String, dynamic> conditions,
    ConditionRecordMatcher? matcher,
  ) async {
    try {
      // Get table structure information
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return [];
      }

      final primaryKey = schema.primaryKey;
      final pkConditionValue = conditions[primaryKey];

      if (pkConditionValue == null) {
        // If there is no primary key value, fall back to table scan
        return _performTableScan(tableName, matcher);
      }

      // Get table file metadata
      final fileMeta =
          await _dataStore.tableDataManager.getTableFileMeta(tableName);
      if (fileMeta == null ||
          fileMeta.partitions == null ||
          fileMeta.partitions!.isEmpty) {
        // If there is no partition information, fall back to table scan
        return _performTableScan(tableName, matcher);
      }

      // Optimization: Check if this is an exact-match ('=') query.
      // This allows us to stop scanning as soon as we find the unique record.
      final bool isExactMatch =
          pkConditionValue is Map && pkConditionValue.containsKey('=');

      // Reuse _getTargetPartitions for better consistency and to handle all query types (=, IN, BETWEEN, etc.)
      final targetPartitions = await _getTargetPartitions(
          tableName,
          schema.isGlobal,
          {primaryKey: pkConditionValue}, // Only pass the primary key condition
          primaryKey,
          fileMeta);

      if (targetPartitions.isEmpty) {
        // No records found
        return [];
      }

      // Result set
      final resultMap = <String, Map<String, dynamic>>{};

      // Only process target partitions
      await _dataStore.tableDataManager.processTablePartitions(
        tableName: tableName,
        onlyRead: true,
        targetPartitions: targetPartitions,
        processFunction: (records, partitionIndex, controller) async {
          if (controller.isStopped) {
            return records;
          }
          for (var i = 0; i < records.length; i++) {
            final record = records[i];
            // Skip deleted records
            if (isDeletedRecord(record)) continue;

            // CRITICAL: The `matcher.evaluate` method checks the *full* query,
            // including the primary key condition (e.g., '>', '<', 'BETWEEN') AND
            // any other conditions on other fields (e.g., AND status = 'active').
            // This single line correctly handles all operators.
            if (matcher == null || matcher.matches(record)) {
              resultMap[record[primaryKey].toString()] = record;

              // If it was an exact match, we've found our unique record, so we can stop all further scanning.
              if (isExactMatch) {
                controller.stop();
                return records;
              }
            }
            if (i % 50 == 0) {
              await Future.delayed(Duration.zero);
            }
          }
          return records;
        },
      );

      return resultMap.values.toList();
    } catch (e) {
      Logger.error('Primary key scan failed: $e',
          label: 'QueryExecutor._performPrimaryKeyScan');
      // When failed, fall back to table scan
      return _performTableScan(tableName, matcher);
    }
  }

  /// Use binary search to locate the partition containing the target primary key
  ///
  /// When the number of partitions is large, binary search can reduce the query complexity from O(n) to O(log n)
  /// Return the found partition index, if not found, return null
  Future<int?> _findPartitionWithBinarySearch(List<dynamic> partitions,
      dynamic pkValue, MatcherFunction matcher) async {
    if (partitions.isEmpty) return null;

    int left = 0;
    int right = partitions.length - 1;

    while (left <= right) {
      int mid = left + (right - left) ~/ 2;
      var partition = partitions[mid];

      // Handle the case where the boundary is empty
      if (partition.minPrimaryKey == null || partition.maxPrimaryKey == null) {
        return partition.index;
      }

      // Check if the primary key is within the current partition range
      if (_isValueInRange(
          pkValue, partition.minPrimaryKey, partition.maxPrimaryKey, matcher)) {
        return partition.index;
      }

      // Adjust the search range
      if (matcher(pkValue, partition.minPrimaryKey) < 0) {
        right = mid - 1; // Continue searching on the left
      } else {
        left = mid + 1; // Continue searching on the right
      }
      if (mid % 50 == 0) {
        await Future.delayed(Duration.zero);
      }
    }

    return null; // No matching partition found
  }

  /// perform index scan
  Future<List<Map<String, dynamic>>> _performIndexScan(
    String tableName,
    String indexName,
    Map<String, dynamic> conditions,
    ConditionRecordMatcher? matcher,
  ) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return [];
      }
      // get actual index name
      String actualIndexName;
      if (indexName.startsWith('pk_')) {
        // primary key index directly use indexName
        actualIndexName = indexName;
      } else {
        // normal index need to find from schema.indexes
        final indexSchema = schema.indexes.firstWhere(
          (idx) => idx.actualIndexName == indexName,
          orElse: () => throw Exception(
              'Index $indexName not found in schema for table $tableName'),
        );
        actualIndexName = indexSchema.actualIndexName;
      }

      // get search value
      dynamic searchValue;
      // get field name for comparison
      if (actualIndexName.startsWith('pk_')) {
        searchValue = conditions[schema.primaryKey];
      } else {
        // for normal index, find index info from schema.indexes
        final indexSchema = schema.indexes.firstWhere(
          (idx) => idx.actualIndexName == indexName,
        );
        searchValue = conditions[indexSchema.fields.first];
      }
      if (searchValue == null) {
        // Fallback to table scan if the condition value for the index is not provided.
        return _performTableScan(tableName, matcher);
      }

      // Convert the raw map condition to a structured IndexCondition
      IndexCondition indexCondition;
      final indexConditionValue = conditions.values.first;
      if (indexConditionValue is Map<String, dynamic>) {
        indexCondition = IndexCondition.fromMap(indexConditionValue);
      } else {
        // Fallback for simple equality like
        indexCondition = IndexCondition.fromMap({'=': indexConditionValue});
      }

      // use searchIndex to get pointers
      final indexResults = await _indexManager.searchIndex(
          tableName, actualIndexName, indexCondition);

      if (indexResults.requiresTableScan) {
        return _performTableScan(tableName, matcher);
      }

      if (indexResults.isEmpty) {
        // If the index search returns no pointers, it means no records match.
        // There is no need to perform a table scan.
        return [];
      }

      // Group pointers by partition to optimize record fetching
      final pointersByPartition = indexResults.pointersByPartition;
      if (pointersByPartition.isEmpty) {
        return [];
      }

      final results = <Map<String, dynamic>>[];

      // Process each partition's results in batch
      int processedCount = 0;
      for (final entry in pointersByPartition.entries) {
        final partitionId = entry.key;
        final pointers = entry.value;
        if (pointers.isEmpty) continue;

        final storeIndexes = pointers
            .map((p) => StoreIndex.fromString(p))
            .whereType<StoreIndex>()
            .toList();
        if (storeIndexes.isEmpty) continue;

        // Fetch all records for the current partition at once
        final records = await _dataStore.tableDataManager
            .getRecordsByPointers(tableName, partitionId, storeIndexes);

        for (var i = 0; i < records.length; i++) {
          final record = records[i];
          // The index search is the primary filter.
          // Further filtering by matcher ensures all other `AND` clauses are met.
          if (matcher == null || matcher.matches(record)) {
            results.add(record);
          }
          if (i % 50 == 0) {
            await Future.delayed(Duration.zero);
          }
        }
        processedCount++;
        if (processedCount % 50 == 0) {
          await Future.delayed(Duration.zero);
        }
      }

      return results;
    } catch (e) {
      Logger.error('Index scan failed: $e',
          label: 'QueryExecutor._performIndexScan');
      return _performTableScan(tableName, matcher);
    }
  }

  /// apply sort
  Future<void> _applySort(List<Map<String, dynamic>> data, List<String> orderBy,
      Map<String, TableSchema> schemas, String tableName) async {
    try {
      // Create sort directions list with same length as orderBy, default all to ascending (true)
      final List<bool> sortDirections = List.filled(orderBy.length, true);
      final List<String> sortFields = List.filled(orderBy.length, '');

      // Process possible sort direction information in orderBy
      for (int i = 0; i < orderBy.length; i++) {
        String field = orderBy[i];

        // 1. Field with "-" prefix indicates descending order
        if (field.startsWith('-')) {
          sortFields[i] = field.substring(1); // Remove "-" symbol
          sortDirections[i] = false; // Set to descending
        }
        // 2. Field with DESC/ASC suffix
        else if (field.toUpperCase().endsWith(' DESC')) {
          // Remove DESC and set sort direction to descending
          sortFields[i] = field.substring(0, field.length - 5).trim();
          sortDirections[i] = false;
        } else if (field.toUpperCase().endsWith(' ASC')) {
          // Remove ASC, keep ascending
          sortFields[i] = field.substring(0, field.length - 4).trim();
          sortDirections[i] = true;
        } else {
          // No special marker, use original field name, default ascending
          sortFields[i] = field;
        }
        if (i % 50 == 0) {
          await Future.delayed(Duration.zero);
        }
      }

      // Use correct parameters to call sortMapList
      ValueMatcher.sortMapList(
          data, sortFields, sortDirections, schemas, tableName);
    } catch (e) {
      Logger.error('Sort failed: $e', label: "QueryExecutor-_applySort");
      throw StateError('Error applying sort: ${e.toString()}');
    }
  }

  /// paginate results
  List<Map<String, dynamic>> _paginateResults(
    List<Map<String, dynamic>> results,
    int? limit,
    int? offset,
  ) {
    if (offset != null) {
      results = results.skip(offset).toList();
    }
    if (limit != null) {
      results = results.take(limit).toList();
    }
    return results;
  }

  /// check if it is a specific query (like query by primary key or index field)
  Future<bool> _isSpecificQuery(
    String tableName,
    QueryCondition condition,
  ) async {
    try {
      // get table schema
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return false;
      }
      final conditions = condition.build();

      // 1. check if it is primary key query
      if (conditions.containsKey(schema.primaryKey)) {
        final pkCondition = conditions[schema.primaryKey];
        // primary key exact match or IN query are considered specific queries
        if (pkCondition is Map) {
          final operator = pkCondition.keys.first;
          return operator == '=' || operator == 'IN';
        }
        // direct value comparison
        return true;
      }

      // 2. check if index field exact query is used
      for (var index in schema.indexes) {
        // only consider single field index exact query
        if (index.fields.length == 1) {
          final fieldName = index.fields.first;
          if (conditions.containsKey(fieldName)) {
            final fieldCondition = conditions[fieldName];
            if (fieldCondition is Map) {
              final operator = fieldCondition.keys.first;
              // index field exact match or IN query
              return operator == '=' || operator == 'IN';
            }
            // direct value comparison
            return true;
          }
        }
      }

      // 3. check if it is unique field exact query
      for (var field in schema.fields) {
        if (field.unique && conditions.containsKey(field.name)) {
          final fieldCondition = conditions[field.name];
          if (fieldCondition is Map) {
            final operator = fieldCondition.keys.first;
            return operator == '=' || operator == 'IN';
          }
          return true;
        }
      }

      // other cases are not considered specific queries
      return false;
    } catch (e) {
      Logger.error('check specific query failed: $e',
          label: 'QueryExecutor._isSpecificQuery');
      return false;
    }
  }

  /// filter out records that are pending buffer
  Future<List<Map<String, dynamic>>> _filterPendingBuffer(String tableName,
      List<Map<String, dynamic>> results, ConditionRecordMatcher? matcher,
      {bool applyWriteBuffer = false}) async {
    // Get the primary key for the table to identify records.
    final schema = await _dataStore.getTableSchema(tableName);
    if (schema == null) {
      Logger.warn(
          'Could not filter pending buffer for table $tableName because schema was not found.',
          label: 'QueryExecutor._filterPendingBuffer');
      return results;
    }
    final primaryKey = schema.primaryKey;

    final pendingDeleteKeys =
        _dataStore.tableDataManager.getPendingDeletePrimaryKeys(tableName);
    final pendingWrites = _dataStore.tableDataManager.writeBuffer[tableName];

    // Early exit if there's nothing to do from buffers.
    if (results.isEmpty &&
        pendingDeleteKeys.isEmpty &&
        (!applyWriteBuffer || pendingWrites == null || pendingWrites.isEmpty)) {
      return results;
    }

    // Using a map is efficient for merging and filtering.
    final resultMap = <String, Map<String, dynamic>>{};

    // 1. Populate with initial results.
    for (final record in results) {
      final pkValue = record[primaryKey]?.toString();
      if (pkValue != null) {
        resultMap[pkValue] = record;
      }
    }

    // 2. Apply pending writes if requested. This adds new records or updates existing ones.
    if (applyWriteBuffer && pendingWrites != null && pendingWrites.isNotEmpty) {
      int processedCount = 0;
      for (final entry in pendingWrites.values) {
        final record = entry.data;
        // A record in the write buffer must be considered.
        // If a condition is provided, it must match.
        if (matcher == null || matcher.matches(record)) {
          final pkValue = record[primaryKey]?.toString();
          if (pkValue != null) {
            resultMap[pkValue] = record;
          }
        }
        processedCount++;
        if (processedCount % 50 == 0) {
          await Future.delayed(Duration.zero);
        }
      }
    }

    // 3. Apply pending deletions.
    // For efficiency, we choose the smaller collection to iterate over.
    if (pendingDeleteKeys.isNotEmpty) {
      if (resultMap.length > pendingDeleteKeys.length) {
        // If the result map is larger, it's faster to iterate the smaller delete set.
        for (final key in pendingDeleteKeys) {
          resultMap.remove(key);
        }
      } else {
        // If the delete set is larger or equal, it's faster to iterate the map.
        resultMap.removeWhere((key, value) => pendingDeleteKeys.contains(key));
      }
    }

    return resultMap.values.toList();
  }
}

/// Helper class for QueryExecutor to manage parsed ranges.
class _QueryRange {
  dynamic min;
  dynamic max;
  bool includeMin = true;
  bool includeMax = true;
}

/// query range
class QueryRange {
  final dynamic start;
  final dynamic end;

  QueryRange(this.start, this.end);
}
