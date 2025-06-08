import '../handler/logger.dart';
import '../core/data_store_impl.dart';
import '../core/index_manager.dart';
import '../model/store_index.dart';
import '../model/file_info.dart';
import '../model/join_clause.dart';
import 'query_cache.dart';
import 'query_condition.dart';
import 'query_plan.dart';
import '../handler/value_comparator.dart';

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
  }) async {
    try {
      // Don't use cache when there are join queries
      if (joins != null && joins.isNotEmpty) {
        final results =
            await _executeQueryPlan(plan, tableName, condition, joins);
        if (orderBy != null) {
          _applySort(results, orderBy);
        }
        return _paginateResults(results, limit, offset);
      }

      final cacheKey = QueryCacheKey(
        tableName: tableName,
        condition: condition ?? QueryCondition(),
        orderBy: orderBy,
        limit: limit,
        offset: offset,
      );

      /// 1、 try query cache
      final queryResult = _dataStore.dataCacheManager.getQuery(cacheKey);
      if (queryResult != null) {
        // get table schema to get primary key field
        final schema = await _dataStore.getTableSchema(tableName);
        if (schema == null) {
          return [];
        }
        final primaryKey = schema.primaryKey;

        // convert cache result to Map to update
        final resultMap = <String, Map<String, dynamic>>{};
        for (var record in queryResult) {
          resultMap[record[primaryKey].toString()] =
              Map<String, dynamic>.from(record);
        }

        // Process records in write queue that match the condition
        final pendingData =
            _dataStore.tableDataManager.writeBuffer[tableName] ?? {};
        if (condition != null) {
          for (var record in pendingData.entries) {
            if (condition.matches(record.value.data)) {
              resultMap[record.value.data[primaryKey].toString()] =
                  Map<String, dynamic>.from(record.value.data);
            }
          }
        } else {
          // Add all pending records
          for (var record in pendingData.entries) {
            resultMap[record.value.data[primaryKey].toString()] =
                Map<String, dynamic>.from(record.value.data);
          }
        }

        // convert back to list
        final updatedResults = resultMap.values.toList();
        // apply sort and pagination
        if (orderBy != null) {
          _applySort(updatedResults, orderBy);
        }
        // query cache is already the correct return result, no need to paginate again
        return _paginateResults(updatedResults, limit, offset);
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

          // Get table schema, used to get primary key field name
          final schema = await _dataStore.getTableSchema(tableName);

          // Check if it is a primary key query, can use O(1) complexity query optimization
          if (condition != null && schema != null) {
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
                  }
                }
              }

              // Primary key IN query, batch get multiple records
              else if (pkCondition is Map && pkCondition.containsKey('IN')) {
                final pkValues = (pkCondition['IN'] as List?)
                    ?.map((e) => e.toString())
                    .toList();
                if (pkValues != null && pkValues.isNotEmpty) {
                  results = _dataStore.dataCacheManager
                      .getRecordsByPrimaryKeys(tableName, pkValues);
                }
              }
            }
          }

          if (condition != null) {
            results =
                results.where((record) => condition.matches(record)).toList();
          }

          if (orderBy != null) {
            _applySort(results, orderBy);
          }

          // Update access time
          _dataStore.dataCacheManager.recordTableAccess(tableName);

          return _paginateResults(results, limit, offset);
        }
      }

      // 3. execute actual query
      final results =
          await _executeQueryPlan(plan, tableName, condition, joins);

      // 4. apply sort
      if (orderBy != null) {
        _applySort(results, orderBy);
      }

      // 5. first cache the complete result, then paginate
      final shouldCache = condition == null ||
          (await _isSpecificQuery(tableName, condition)) ||
          (results.length < _dataStore.config.maxQueryCacheSize);

      if (shouldCache && results.isNotEmpty) {
        _dataStore.dataCacheManager.cacheQuery(cacheKey, results, {tableName});
      }

      // 6. apply pagination and return results
      final paginatedResults = _paginateResults(results, limit, offset);
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
            // Create QueryCondition and add conditions
            final mainTableQueryCondition = QueryCondition();
            for (var entry in mainTableConditions.entries) {
              _addConditionToQuery(
                  mainTableQueryCondition, entry.key, entry.value);
            }
            results =
                await _performTableScan(tableName, mainTableQueryCondition);
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
            condition, // Use complete conditions, will handle internally
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
          results = results
              .where((record) => condition?.matches(record) ?? false)
              .toList();
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
          ValueComparator.sortMapList(results, sortFields, sortDirections);
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
          );
          results = joinedResults;

          // Extract conditions for the current joined table and apply
          final joinTableName = joinInfo['table'] as String;
          final joinTableConditions =
              _extractTableConditions(remainingConditions, joinTableName);

          // Apply joined table conditions
          if (joinTableConditions.isNotEmpty) {
            results = results
                .where((record) => condition?.matches(record) ?? false)
                .toList();

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
      results = results
          .where((record) => condition?.matches(record) ?? false)
          .toList();
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

  /// Helper to add a condition to QueryCondition
  void _addConditionToQuery(
      QueryCondition queryCondition, String field, dynamic value) {
    if (value is Map) {
      // Process operators
      for (var opEntry in value.entries) {
        final operator = opEntry.key;
        final compareValue = opEntry.value;
        queryCondition.where(field, operator, compareValue);
      }
    } else {
      // Simple equality
      queryCondition.where(field, '=', value);
    }
  }

  /// Execute table join operation
  Future<List<Map<String, dynamic>>> _performJoin(
    List<Map<String, dynamic>> leftRecords,
    String rightTableName,
    String leftKey,
    String operator,
    String rightKey,
    String joinType,
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
        for (var leftRecord in leftRecords) {
          // Find all matching right table records
          final matchingRightRecords = rightRecords
              .where((rightRecord) => _matchJoinCondition(
                  leftRecord, rightRecord, leftKey, operator, rightKey))
              .toList();

          // Only add result if matches found
          for (var rightRecord in matchingRightRecords) {
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
        }
        break;

      case 'left':
        // Left join: returns all records from left table, even if there are no matches in right table
        for (var leftRecord in leftRecords) {
          // Find all matching right table records
          final matchingRightRecords = rightRecords
              .where((rightRecord) => _matchJoinCondition(
                  leftRecord, rightRecord, leftKey, operator, rightKey))
              .toList();

          if (matchingRightRecords.isNotEmpty) {
            // Has matches, add all matching records
            for (var rightRecord in matchingRightRecords) {
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
        }
        break;

      case 'right':
        // Right join: returns all records from right table, even if there are no matches in left table
        for (var rightRecord in rightRecords) {
          // Find all matching left table records
          final matchingLeftRecords = leftRecords
              .where((leftRecord) => _matchJoinCondition(
                  leftRecord, rightRecord, leftKey, operator, rightKey))
              .toList();

          if (matchingLeftRecords.isNotEmpty) {
            // Has matches, add all matching records
            for (var leftRecord in matchingLeftRecords) {
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
  ) {
    // Handle fields with table names (like 'users.id')
    String leftFieldName = leftKey;
    String leftTableName = '';
    if (leftKey.contains('.')) {
      final parts = leftKey.split('.');
      leftTableName = parts[0];
      leftFieldName = parts[1];
    }

    String rightFieldName = rightKey;
    String rightTableName = '';
    if (rightKey.contains('.')) {
      final parts = rightKey.split('.');
      rightTableName = parts[0];
      rightFieldName = parts[1];
    }

    // Try to get left value: first check for complete table name prefix field, then check for non-prefixed field
    dynamic leftValue;
    final leftPrefixedKey = '$leftTableName.$leftFieldName';
    if (leftRecord.containsKey(leftPrefixedKey)) {
      leftValue = leftRecord[leftPrefixedKey];
    } else {
      leftValue = leftRecord[leftFieldName];
    }

    // Try to get right value: first check for complete table name prefix field, then check for non-prefixed field
    dynamic rightValue;
    final rightPrefixedKey = '$rightTableName.$rightFieldName';
    if (rightRecord.containsKey(rightPrefixedKey)) {
      rightValue = rightRecord[rightPrefixedKey];
    } else {
      rightValue = rightRecord[rightFieldName];
    }

    // Handle different operators
    switch (operator) {
      case '=':
        return leftValue == rightValue;
      case '<':
        return leftValue != null &&
            rightValue != null &&
            leftValue < rightValue;
      case '>':
        return leftValue != null &&
            rightValue != null &&
            leftValue > rightValue;
      case '<=':
        return leftValue != null &&
            rightValue != null &&
            leftValue <= rightValue;
      case '>=':
        return leftValue != null &&
            rightValue != null &&
            leftValue >= rightValue;
      case '!=':
      case '<>':
        return leftValue != rightValue;
      default:
        return false;
    }
  }

  /// perform table scan with optimized partition loading
  Future<List<Map<String, dynamic>>> _performTableScan(
    String tableName,
    QueryCondition? condition,
  ) async {
    final schema = await _dataStore.getTableSchema(tableName);
    if (schema == null) {
      return [];
    }
    final primaryKey = schema.primaryKey;
    final isGlobal = schema.isGlobal;
    bool shouldMarkAsFullTableCache = false;

    // 1. check if there is full table cache
    if (await _dataStore.dataCacheManager.isTableFullyCached(tableName)) {
      // check if file is modified
      final cache = _dataStore.dataCacheManager.getEntireTable(tableName);
      if (cache != null) {
        final cacheTime =
            _dataStore.dataCacheManager.getTableCacheTime(tableName);
        if (cacheTime != null &&
            !_dataStore.tableDataManager.isFileModified(tableName, cacheTime)) {
          var results = cache;
          if (condition != null) {
            results =
                results.where((record) => condition.matches(record)).toList();
          }
          return results;
        }
      }
    }

    // Result map
    final resultMap = <String, Map<String, dynamic>>{};

    // 2. Get file meta to check for partitions
    final fileMeta =
        await _dataStore.tableDataManager.getTableFileMeta(tableName);

    // If file metadata doesn't exist, empty table or new table, can be marked as full table data
    if (fileMeta == null ||
        fileMeta.partitions == null ||
        fileMeta.partitions!.isEmpty) {
      // Empty or new table, directly mark as full table cache (if no filter conditions)
      shouldMarkAsFullTableCache = condition == null;
    }
    // 3. If partitioned storage is used
    else if (fileMeta.partitions!.isNotEmpty) {
      final conditions = condition?.build();
      final targetPartitions = await _getTargetPartitions(
          tableName, isGlobal, conditions, primaryKey, fileMeta);

      // Determine if we need to scan all partitions (equivalent to full table scan)
      bool scanAllPartitions =
          targetPartitions.length == fileMeta.partitions!.length;

      if (targetPartitions.isNotEmpty) {
        // Check for early return in case of exact primary key match
        final exactPkMatch = _getExactPrimaryKeyValue(conditions, primaryKey);
        bool foundExactMatch = false;

        // Process only target partitions
        for (var partitionIndex in targetPartitions) {
          final partitionRecords = await _dataStore.tableDataManager
              .readRecordsFromPartition(
                  tableName, isGlobal, partitionIndex, primaryKey);

          if (condition != null) {
            // Filter records based on condition
            for (var record in partitionRecords) {
              if (condition.matches(record)) {
                resultMap[record[primaryKey].toString()] = record;

                // If looking for exact primary key match and found it, we can stop
                if (exactPkMatch != null &&
                    record[primaryKey] == exactPkMatch) {
                  foundExactMatch = true;
                  break;
                }
              }
            }
          } else {
            // No filter, add all records
            for (var record in partitionRecords) {
              resultMap[record[primaryKey].toString()] = record;
            }
          }

          // Early return if exact match found
          if (foundExactMatch) {
            break;
          }
        }

        // Process records in write queue that match the condition
        final pendingData =
            _dataStore.tableDataManager.writeBuffer[tableName] ?? {};
        if (condition != null) {
          for (var record in pendingData.entries) {
            if (condition.matches(record.value.data)) {
              resultMap[record.value.data[primaryKey].toString()] =
                  Map<String, dynamic>.from(record.value.data);
            }
          }
        } else {
          // Add all pending records
          for (var record in pendingData.entries) {
            resultMap[record.value.data[primaryKey].toString()] =
                Map<String, dynamic>.from(record.value.data);
          }
        }

        // If full table scan with no filter conditions, and record count within limit, mark as full table data
        if (scanAllPartitions && condition == null) {
          shouldMarkAsFullTableCache = true;
        }

        return resultMap.values.toList();
      }
    }

    // Process records using streaming
    if (fileMeta != null &&
        fileMeta.totalRecords > 0 &&
        fileMeta.partitions!.isNotEmpty) {
      // Use streaming to process partitions without loading all at once
      final stream = _dataStore.tableDataManager.streamRecords(tableName);
      await for (var record in stream) {
        if (condition == null || condition.matches(record)) {
          resultMap[record[primaryKey].toString()] = record;
        }
      }
    }

    // Process records in write queue that match the condition
    final pendingData =
        _dataStore.tableDataManager.writeBuffer[tableName] ?? {};
    if (condition != null) {
      for (var record in pendingData.entries) {
        if (condition.matches(record.value.data)) {
          resultMap[record.value.data[primaryKey].toString()] =
              Map<String, dynamic>.from(record.value.data);
        }
      }
    } else {
      // Add all pending records
      for (var record in pendingData.entries) {
        resultMap[record.value.data[primaryKey].toString()] =
            Map<String, dynamic>.from(record.value.data);
      }
    }

    // Cache entire table if we should mark as full table cache
    if (shouldMarkAsFullTableCache) {
      final recordCount = resultMap.values.length;

      // Determine if full table caching is allowed
      if (await _dataStore.tableDataManager.allowFullTableCache(tableName)) {
        await _dataStore.dataCacheManager.cacheEntireTable(
          tableName,
          resultMap.values.toList(),
          primaryKey,
        );
        Logger.debug(
          'Full table scan updated table $tableName cache, record count: $recordCount, marked as full table cache',
          label: 'QueryExecutor._performTableScan',
        );
      }
    }

    return resultMap.values.toList();
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

    // Check if conditions include primary key constraints
    dynamic pkMin, pkMax;
    bool hasPkRange = false;

    // Check for direct primary key match or ranges
    if (conditions.containsKey(primaryKey)) {
      final pkCondition = conditions[primaryKey];

      if (pkCondition is Map) {
        // Check for operators like >, >=, <, <=, BETWEEN
        if (pkCondition.containsKey('>') || pkCondition.containsKey('>=')) {
          pkMin = pkCondition['>'] ?? pkCondition['>='];
          hasPkRange = true;
        }

        if (pkCondition.containsKey('<') || pkCondition.containsKey('<=')) {
          pkMax = pkCondition['<'] ?? pkCondition['<='];
          hasPkRange = true;
        }

        if (pkCondition.containsKey('BETWEEN')) {
          final between = pkCondition['BETWEEN'] as Map;
          pkMin = between['start'];
          pkMax = between['end'];
          hasPkRange = true;
        }

        // Check for exact match (=)
        if (pkCondition.containsKey('=')) {
          pkMin = pkMax = pkCondition['='];
          hasPkRange = true;
        }

        // Check for IN operator
        if (pkCondition.containsKey('IN')) {
          // For IN operator, we need to find the partitions containing any of the values
          final inValues = pkCondition['IN'] as List;
          if (inValues.isNotEmpty) {
            final targetPartitions = <int>{};

            for (var value in inValues) {
              for (var partition in fileMeta.partitions!) {
                if (_isValueInRange(
                    value, partition.minPrimaryKey, partition.maxPrimaryKey)) {
                  targetPartitions.add(partition.index);
                }
              }
            }

            return targetPartitions.toList()..sort();
          }
        }
      } else {
        // Direct value match
        pkMin = pkMax = pkCondition;
        hasPkRange = true;
      }
    }

    if (hasPkRange) {
      // Find partitions within the range
      final targetPartitions = <int>[];

      for (var partition in fileMeta.partitions!) {
        // If min/max are not set, consider the partition
        if (partition.minPrimaryKey == null ||
            partition.maxPrimaryKey == null) {
          targetPartitions.add(partition.index);
          continue;
        }

        bool include = true;

        // Check if partition's range overlaps with query range
        if (pkMin != null) {
          include = _compareValues(partition.maxPrimaryKey, pkMin) >= 0;
        }

        if (include && pkMax != null) {
          include = _compareValues(partition.minPrimaryKey, pkMax) <= 0;
        }

        if (include) {
          targetPartitions.add(partition.index);
        }
      }

      return targetPartitions..sort();
    }

    // If no primary key constraints, but we have conditions on other fields,
    // we need to check all partitions
    return fileMeta.partitions!.map((c) => c.index).toList()..sort();
  }

  /// Check if a value is within a range (inclusive)
  bool _isValueInRange(dynamic value, dynamic min, dynamic max) {
    if (min == null || max == null) return true;
    return _compareValues(value, min) >= 0 && _compareValues(value, max) <= 0;
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

  /// perform index scan
  Future<List<Map<String, dynamic>>> _performIndexScan(
    String tableName,
    String indexName,
    Map<String, dynamic> conditions,
    QueryCondition? queryCondition,
  ) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      if (schema == null) {
        return [];
      }
      final index = await _indexManager.getIndex(tableName, indexName);
      if (index == null) {
        return _performTableScan(tableName, queryCondition);
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
        );
        actualIndexName = indexSchema.actualIndexName;
      }

      // get search value
      dynamic searchValue;
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
        return _performTableScan(tableName, queryCondition);
      }

      // use index partitions for search
      final indexResults = await index.search(searchValue);
      if (indexResults.isEmpty) {
        return _performTableScan(tableName, queryCondition);
      }
      // get full records
      final results = <Map<String, dynamic>>[];

      // handle primary key index and normal index results
      for (var pointer in indexResults) {
        // handle String and StoreIndex types
        StoreIndex storeIndex;
        if (pointer is String) {
          final storeIndexTemp = StoreIndex.fromString(pointer);
          if (storeIndexTemp == null) {
            Logger.debug(
              'Skipped invalid index result: $pointer',
              label: 'QueryExecutor._performIndexScan',
            );
            continue;
          }
          storeIndex = storeIndexTemp;
        } else if (pointer is StoreIndex) {
          storeIndex = pointer;
        } else {
          // skip unrecognized format
          Logger.debug(
              'Skipped unrecognized index result format: ${pointer.runtimeType}',
              label: 'QueryExecutor._performIndexScan');
          continue;
        }

        // get record by store index
        final record = await _dataStore.tableDataManager
            .getRecordByPointer(tableName, storeIndex);

        if (record != null) {
          // apply additional conditions (if any)
          if (queryCondition != null) {
            if (queryCondition.matches(record)) {
              results.add(record);
            }
          } else {
            results.add(record);
          }
        } else {
          // record not found, index expired, add to delete buffer
          Logger.debug(
            'Detected expired index, adding to delete buffer: $tableName.$indexName: $searchValue -> $storeIndex',
            label: 'QueryExecutor._performIndexScan',
          );

          dynamic actualValue = searchValue;
          if (searchValue is Map && searchValue.containsKey('=')) {
            actualValue = searchValue['='];
          }

          // add to delete buffer for later cleanup
          await _indexManager.addToDeleteBuffer(
              tableName, actualIndexName, actualValue, storeIndex.toString());
        }
      }

      return results;
    } catch (e) {
      Logger.error('Index scan failed: $e',
          label: 'QueryExecutor._performIndexScan');
      return _performTableScan(tableName, queryCondition);
    }
  }

  /// safe value comparison
  int _compareValues(dynamic a, dynamic b) {
    return ValueComparator.compare(a, b);
  }

  /// apply sort
  void _applySort(List<Map<String, dynamic>> data, List<String> orderBy) {
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
      }

      // Use correct parameters to call sortMapList
      ValueComparator.sortMapList(data, sortFields, sortDirections);
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
}

/// query range
class QueryRange {
  final dynamic start;
  final dynamic end;

  QueryRange(this.start, this.end);
}
