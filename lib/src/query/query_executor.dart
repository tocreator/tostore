import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import '../core/tree_cache.dart';
import '../handler/logger.dart';
import '../handler/memcomparable.dart';
import '../core/data_store_impl.dart';
import '../core/index_manager.dart';
import '../core/transaction_context.dart';

import '../model/index_search.dart';
import '../model/business_error.dart';

import '../model/join_clause.dart';
import '../model/buffer_entry.dart';
import '../model/table_schema.dart';
import 'query_cache.dart';
import 'query_condition.dart';
import 'query_plan.dart';
import '../handler/topk_heap.dart';
import '../handler/value_matcher.dart';
import '../handler/parallel_processor.dart';
import '../core/yield_controller.dart';
import '../core/workload_scheduler.dart';

/// query executor
class QueryExecutor {
  final DataStoreImpl _dataStore;
  final IndexManager _indexManager;

  // Query result hotspot cache (MemoryQuotaType.queryResult).
  late final TreeCache<_QueryCacheEntry> _queryCache;
  final Map<String, int> _tableQueryGenerations = <String, int>{};

  QueryExecutor(
    this._dataStore,
    this._indexManager,
  ) {
    final mem = _dataStore.memoryManager;
    final int maxBytes = mem?.getQueryCacheSize() ?? (50 * 1024 * 1024);
    _queryCache = TreeCache<_QueryCacheEntry>(
      sizeCalculator: (e) => e.sizeBytes,
      maxByteThreshold: maxBytes,
      minByteThreshold: 20 * 1024 * 1024,
      debugLabel: 'QueryResult',
    );
  }

  /// Execute query with optional cursor/keyset pagination.
  ///
  /// - When [cursor] is provided, cursor pagination is used (mutually exclusive with [offset]).
  /// - Returns [ExecuteResult] containing records, nextCursor, and hasMore.
  /// - Supports:
  ///   - Table scan ordered by primary key (default / explicit PK orderBy, ASC/DESC)
  ///   - Index scan ordered by index key (when orderBy matches index fields, ASC/DESC)
  /// - Not supported:
  ///   - UNION/OR plans
  ///   - JOINs (cursor semantics become ambiguous due to row multiplication)
  Future<ExecuteResult> execute(
    String tableName, {
    QueryCondition? condition,
    List<String>? orderBy,
    int? limit,
    int? offset,
    String? cursor,
    List<JoinClause>? joins,
    bool enableQueryCache = false,
    Duration? queryCacheExpiry,
  }) async {
    final optimizer = _dataStore.getQueryOptimizer();
    if (optimizer == null) {
      throw StateError('Query optimizer not initialized');
    }

    Map<String, dynamic>? where = condition?.build();
    if (where != null &&
        where.isNotEmpty &&
        joins != null &&
        joins.isNotEmpty) {
      // For JOIN queries, unprefixed fields are assumed to belong to the main table.
      // This preserves existing QueryBuilder behavior while centralizing planning here.
      where = _prefixMainTableForJoinWhere(tableName, where);
    }

    final plan = await optimizer.optimize(
      tableName,
      where,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
    );

    return _executeWithPlan(
      plan,
      tableName,
      condition: condition,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      cursor: cursor,
      joins: joins,
      enableQueryCache: enableQueryCache,
      queryCacheExpiry: queryCacheExpiry,
    );
  }

  /// Prefix unqualified where-clause fields with main table name for JOIN queries.
  Map<String, dynamic> _prefixMainTableForJoinWhere(
    String mainTableName,
    Map<String, dynamic> conditions,
  ) {
    Map<String, dynamic> convert(Map<String, dynamic> node) {
      final out = <String, dynamic>{};
      for (final entry in node.entries) {
        final k = entry.key;
        final v = entry.value;
        if (k == 'OR' || k == 'AND') {
          if (v is List) {
            final converted = <Map<String, dynamic>>[];
            for (final it in v) {
              if (it is Map<String, dynamic>) {
                converted.add(convert(it));
              }
            }
            out[k] = converted;
          } else {
            out[k] = v;
          }
          continue;
        }

        if (k.contains('.')) {
          out[k] = v;
          continue;
        }

        // Default: apply to main table.
        out['$mainTableName.$k'] = v;
      }
      return out;
    }

    return convert(conditions);
  }

  /// Extract a main-table-only condition tree for pre-JOIN scanning.
  ///
  /// This function is intentionally **superset-preserving** for JOIN queries:
  /// predicates that reference other tables are rewritten to `TRUE` (empty map)
  /// so we won't accidentally drop rows that could match after JOIN.
  Map<String, dynamic> _extractTableConditionTreeForExecution(
    String mainTableName,
    Map<String, dynamic> node,
  ) {
    Map<String, dynamic> extract(Map<String, dynamic> n) {
      final hasAnd = n.containsKey('AND') && n['AND'] is List;
      final hasOr = n.containsKey('OR') && n['OR'] is List;

      // Leaf predicates for this node (main table only).
      final leaf = <String, dynamic>{};
      for (final e in n.entries) {
        final k = e.key;
        if (k == 'AND' || k == 'OR') continue;
        final v = e.value;

        if (k.contains('.')) {
          final parts = k.split('.');
          if (parts.length == 2 && parts.first == mainTableName) {
            leaf[parts.last] = v;
          }
          // Other-table predicate => ignored here (handled by post-join matcher).
          continue;
        }

        // Unprefixed => main table.
        leaf[k] = v;
      }

      if (hasOr) {
        final outChildren = <Map<String, dynamic>>[];
        final list = n['OR'] as List;
        for (final c in list) {
          if (c is! Map<String, dynamic>) continue;
          final sub = extract(c);
          // Any TRUE branch makes the whole OR TRUE (superset).
          if (sub.isEmpty) return <String, dynamic>{};
          outChildren.add(sub);
        }

        if (outChildren.isEmpty) {
          // OR with no effective children: reduce to leaf.
          return leaf;
        }

        final orNode =
            (outChildren.length == 1) ? outChildren.first : {'OR': outChildren};
        if (leaf.isEmpty) return orNode;
        return {
          'AND': <Map<String, dynamic>>[
            orNode,
            leaf,
          ]
        };
      }

      if (hasAnd) {
        final outChildren = <Map<String, dynamic>>[];
        final list = n['AND'] as List;
        for (final c in list) {
          if (c is! Map<String, dynamic>) continue;
          final sub = extract(c);
          // TRUE child does not constrain AND.
          if (sub.isEmpty) continue;
          outChildren.add(sub);
        }
        if (leaf.isNotEmpty) outChildren.add(leaf);
        if (outChildren.isEmpty) return <String, dynamic>{};
        if (outChildren.length == 1) return outChildren.first;
        return <String, dynamic>{'AND': outChildren};
      }

      return leaf;
    }

    return extract(node);
  }

  Future<ExecuteResult> _executeWithPlan(
    QueryPlan plan,
    String tableName, {
    QueryCondition? condition,
    List<String>? orderBy,
    int? limit,
    int? offset,
    String? cursor,
    List<JoinClause>? joins,
    bool enableQueryCache = false,
    Duration? queryCacheExpiry,
  }) async {
    try {
      // Cursor and offset are mutually exclusive at the API level.
      // We implicitly use cursor mode if no token is provided but offset is 0/null.
      final bool hasToken = cursor != null && cursor.trim().isNotEmpty;
      final bool isCursorIntent = hasToken || (offset == null || offset <= 0);

      bool useCursor = isCursorIntent;

      if (useCursor && offset != null && offset > 0) {
        throw BusinessError(
          'Cursor pagination and offset are mutually exclusive. Use cursor() or offset(), not both.',
          type: BusinessErrorType.invalidData,
          data: {'cursor': cursor, 'offset': offset},
        );
      }

      if (useCursor) {
        bool supported = true;
        String? reason;

        // JOIN constraint: only allow sorting by main table fields
        if (joins != null && joins.isNotEmpty) {
          if (orderBy != null && orderBy.isNotEmpty) {
            for (final f in orderBy) {
              final field = f.startsWith('-') ? f.substring(1) : f;
              if (field.contains('.') && !field.startsWith('$tableName.')) {
                supported = false;
                reason =
                    'Cursor pagination with JOIN only supports ordering by main table fields.';
                break;
              }
            }
          }
        }

        if (!supported) {
          if (hasToken) {
            throw BusinessError(
              reason ??
                  'Cursor pagination is not supported for this query type.',
              type: BusinessErrorType.dbError,
              data: {'table': tableName},
            );
          } else {
            useCursor = false;
          }
        }
      }

      final bool hasCursor = useCursor;

      // Apply global pagination safety defaults (configurable).
      int effectiveOffset = hasCursor ? 0 : (offset ?? 0);
      if (effectiveOffset < 0) effectiveOffset = 0;
      final int maxOffset = _dataStore.config.maxQueryOffset;
      if (maxOffset > 0 && effectiveOffset > maxOffset && !hasCursor) {
        throw BusinessError(
          'Query offset ($effectiveOffset) exceeds maxQueryOffset ($maxOffset). '
          'Use keyset pagination (primaryKey/index range) instead of deep offset pagination.',
          type: BusinessErrorType.dbError,
          data: {'offset': effectiveOffset, 'maxQueryOffset': maxOffset},
        );
      }

      bool isDefaultLimitApplied = false;
      final int effectiveLimit;
      if (limit != null) {
        effectiveLimit = limit;
      } else {
        final int defaultLimit = _dataStore.config.defaultQueryLimit;
        if (defaultLimit <= 0) {
          // Safety: never allow unbounded reads in ultra-large datasets.
          // Caller must specify limit() or configure defaultQueryLimit (> 0).
          throw BusinessError(
            'Unbounded queries are not allowed. Please specify .limit() or set DataStoreConfig.defaultQueryLimit (> 0).',
            type: BusinessErrorType.dbError,
            data: {
              'table': tableName,
              'defaultQueryLimit': _dataStore.config.defaultQueryLimit,
            },
          );
        }
        effectiveLimit = defaultLimit;
        isDefaultLimitApplied = true;
      }
      if (effectiveLimit <= 0) {
        return const ExecuteResult.empty();
      }

      // Fetch one extra record to detect whether there are more results.
      // This is valuable even when cursor pagination is not supported, so the caller
      // can still know if there is another page beyond [limit].
      final int fetchLimit = effectiveLimit + 1;

      final stopwatch = Stopwatch()..start();

      final schemas = <String, TableSchema>{};
      ConditionRecordMatcher? matcher;
      ConditionRecordMatcher? postJoinMatcher;
      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        Logger.error('Table $tableName not found, cannot execute query.',
            label: 'QueryExecutor.execute');
        return const ExecuteResult.empty();
      }
      schemas[tableName] = schema;

      // Decode cursor token if provided.
      final _QueryCursorToken? cursorToken =
          hasCursor ? _QueryCursorToken.tryDecode(cursor) : null;
      if (cursorToken != null && cursorToken.tableName != tableName) {
        throw BusinessError(
          'Cursor does not match target table.',
          type: BusinessErrorType.dbError,
          data: {
            'table': tableName,
            'cursorTable': cursorToken.tableName,
          },
        );
      }

      if (condition != null && !condition.isEmpty) {
        if (joins != null && joins.isNotEmpty) {
          for (final join in joins) {
            if (schemas.containsKey(join.table)) continue;
            final joinSchema =
                await _dataStore.schemaManager?.getTableSchema(join.table);
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

        final fullMatcher =
            ConditionRecordMatcher.prepare(condition, schemas, tableName);

        // JOIN queries may include conditions on joined tables (e.g. users.age),
        // which cannot be evaluated against the main-table records before JOIN.
        // For correctness, use a main-table-only matcher for the base scan, and
        // apply the full matcher after JOIN as a final filter.
        if (joins != null && joins.isNotEmpty) {
          final mainOnlyTree = _extractTableConditionTreeForExecution(
              tableName, condition.build());
          final mainOnlyCondition = QueryCondition.fromMap(mainOnlyTree);
          // Values are already normalized in [condition], but running normalize again is safe.
          mainOnlyCondition.normalize(schemas, tableName);
          matcher = ConditionRecordMatcher.prepare(
              mainOnlyCondition, schemas, tableName);
          postJoinMatcher = fullMatcher;
        } else {
          matcher = fullMatcher;
        }
      }

      // Determine cursor mode (for building next/prev cursors even on first page)
      // Returns null if the query configuration does not support cursor-based pagination.
      final bool effectiveIsBackward = cursorToken?.isBackward ?? false;
      // Do NOT blindly default to PK ordering for index scans:
      // - It disables index-key cursor pagination
      // - It can trigger incorrect/inefficient execution paths for large datasets
      final List<String> userOrderBy =
          (orderBy != null && orderBy.isNotEmpty) ? orderBy : const <String>[];

      List<String> effectiveOrderBy = userOrderBy;
      if (effectiveOrderBy.isEmpty) {
        final natural = plan.naturalOrderBy;
        effectiveOrderBy = natural.isNotEmpty
            ? natural
            : _defaultOrderByForPlan(schema: schema, plan: plan);
      }

      // Backward fetch logic: reverse all orderBy directions to scan in opposite direction
      if (effectiveIsBackward) {
        final actualOrderBy = effectiveOrderBy;
        effectiveOrderBy = actualOrderBy.map((f) {
          final parsed = _parseSortField(f);
          return parsed.descending ? parsed.field : '-${parsed.field}';
        }).toList();
      }

      final _CursorMode? cursorMode = _determineCursorMode(
        tableName: tableName,
        schema: schema,
        plan: plan,
        orderBy: effectiveOrderBy,
        cursorToken: cursorToken,
      );

      // Execute query plan
      final planResult = await _executeQueryPlan(
        plan,
        tableName,
        condition,
        schemas,
        matcher,
        limit: fetchLimit,
        offset: effectiveOffset,
        orderBy: effectiveOrderBy,
        enableQueryCache: enableQueryCache,
        queryCacheExpiry: queryCacheExpiry,
        cursor: cursor,
        cursorToken: cursorToken,
        cursorMode: cursorMode,
      );

      List<Map<String, dynamic>> results = planResult.records.toList();

      // Manual Offset skip if not applied at lower level (e.g. table scans with matcher)
      if (effectiveOffset > 0) {
        if (results.length > effectiveOffset) {
          results = results.sublist(effectiveOffset);
        } else {
          results = [];
        }
      }

      // If joins are present, chain join operations
      if (joins != null && joins.isNotEmpty) {
        for (final join in joins) {
          results = await _performJoin(
            results,
            join.table,
            join.firstKey,
            join.operator,
            join.secondKey,
            join.type.toString().split('.').last,
            schemas,
            tableName,
            enableQueryCache: enableQueryCache,
            limit: effectiveLimit,
            offset: effectiveOffset,
            queryCacheExpiry: queryCacheExpiry,
          );
        }

        // Apply deferred predicates that reference joined tables.
        if (postJoinMatcher != null && results.isNotEmpty) {
          final filtered = <Map<String, dynamic>>[];
          final yieldController =
              YieldController('QueryExecutor._postJoinFilter');
          for (final r in results) {
            await yieldController.maybeYield();
            if (postJoinMatcher.matches(r)) {
              filtered.add(r);
            }
          }
          results = filtered;
        }
      }

      // Final sort: single place after offset/joins, before limit truncation.
      // mergeConsistency does not sort; buffer-unordered inserts can break order for custom PK.
      // One _applySort here covers both single-table (buffer merge) and join/union—no redundant sort.
      final bool needPostSort = effectiveOrderBy.isNotEmpty;

      if (needPostSort) {
        // For index cursor mode, validate orderBy matches index key order.
        if (cursorMode == _CursorMode.indexKey) {
          _validateIndexOrderByForCursor(
            tableName: tableName,
            schema: schema,
            plan: plan,
            orderBy: effectiveOrderBy,
          );
        }
        results =
            await _applySort(results, effectiveOrderBy, schemas, tableName);
      }

      // CRITICAL: Apply limit truncation BEFORE pagination status check.
      // Buffer merging may have returned more records than needed, so we must truncate here.
      // Always keep at most (limit+1) records for hasMore/hasPrev detection.
      final int targetLimit = effectiveLimit + 1;
      if (results.length > targetLimit) {
        results = results.take(targetLimit).toList();
      }

      // If we reached the default limit and have extra records, warn the user about truncation.
      if (isDefaultLimitApplied && results.length > effectiveLimit) {
        Logger.info(
          'Query results for table "$tableName" reached the default limit of $effectiveLimit. '
          'Some records may have been truncated. To prevent memory issues with many records, '
          'please explicitly call .limit() if you need more data.',
          label: 'QueryExecutor',
        );
      }

      // Pagination status (internal use for cursor generation)
      String? nextCursor;
      String? prevCursor;
      bool hasMore = false;
      bool hasPrev = false;

      if (effectiveIsBackward) {
        // Backward scan: was there more "above" the cursor?
        hasPrev = results.length > effectiveLimit;
        if (hasPrev) {
          results
              .removeLast(); // Remove the extra record (furthest from cursor)
        }

        // Reverse results back to requested order (scan was reverse direction)
        results = results.reversed.toList();
        // If we came from a cursor, we know there's record forward.
        hasMore = hasToken || (effectiveOffset > 0);
      } else {
        // Forward scan: was there more "below"?
        hasMore = results.length > effectiveLimit;
        if (hasMore) {
          results.removeLast(); // Remove the extra record
        }
        hasPrev = hasToken || (effectiveOffset > 0);
      }

      // Build cursors if supported and records exist
      if (cursorMode != null && results.isNotEmpty) {
        final firstRec = results.first;
        final lastRec = results.last;

        try {
          if (hasMore) {
            nextCursor = _buildNextCursor(
              mode: cursorMode,
              tableName: tableName,
              schema: schema,
              plan: plan,
              orderBy: orderBy,
              lastRecord: lastRec,
              isBackward: false,
            );
          }

          if (hasPrev) {
            prevCursor = _buildNextCursor(
              mode: cursorMode,
              tableName: tableName,
              schema: schema,
              plan: plan,
              orderBy: orderBy,
              lastRecord: firstRec,
              isBackward: true,
            );
          }
        } catch (e) {
          if (hasCursor) rethrow;
          Logger.debug('Implicit cursor building failed: $e');
        }
      }

      // Use getTableRecordCount for accurate, buffer-aware record count (O(1) approach).
      int? tableTotalCount;
      try {
        tableTotalCount =
            await _dataStore.tableDataManager.getTableRecordCount(tableName);
      } catch (_) {}

      stopwatch.stop();

      return ExecuteResult(
        records: results,
        nextCursor: nextCursor,
        prevCursor: prevCursor,
        hasMore: hasMore,
        hasPrev: hasPrev,
        executionTimeMs: stopwatch.elapsedMilliseconds,
        tableTotalCount: tableTotalCount,
      );
    } on BusinessError catch (e) {
      // Business/Validation errors should not clutter logs with stack traces.
      Logger.error(e.message, label: 'QueryExecutor.execute');
      rethrow;
    } catch (e, stackTrace) {
      Logger.error('query execution failed: $e',
          label: 'QueryExecutor.execute');
      Logger.debug('stack trace: $stackTrace');
      rethrow;
    }
  }

  /// execute query plan
  Future<PlanExecutionResult> _executeQueryPlan(
    QueryPlan plan,
    String tableName,
    QueryCondition? condition,
    Map<String, TableSchema> schemas,
    ConditionRecordMatcher? matcher, {
    int? limit,
    int? offset,
    List<String>? orderBy,
    bool enableQueryCache = false,
    Duration? queryCacheExpiry,
    String? cursor,
    _QueryCursorToken? cursorToken,
    _CursorMode? cursorMode,
  }) async {
    final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) {
      return PlanExecutionResult([]);
    }

    // For sort-key cursor mode, build a keyset filter that will be applied during
    // base scan selection (and also used to pre-filter buffer inserts).
    bool Function(Map<String, dynamic>)? cursorFilter;
    if (cursorToken != null &&
        cursorMode == _CursorMode.sortKey &&
        cursorToken.mode == _CursorMode.sortKey) {
      cursorFilter = _buildSortKeyCursorFilter(
        tableName: tableName,
        schema: schema,
        schemas: schemas,
        orderBy: orderBy ?? const <String>[],
        cursorToken: cursorToken,
      );
    }

    // Query cache
    if (enableQueryCache) {
      final cacheKey = QueryCacheKey(
        tableName: tableName,
        condition: condition ?? QueryCondition(),
        orderBy: orderBy,
        limit: limit,
        offset: offset,
        cursor: cursor,
      );
      final ck = _buildQueryCacheKey(cacheKey);
      final entry = _queryCache.get(ck);
      if (entry != null) {
        if (entry.isExpired()) {
          _queryCache.remove(ck);
        } else {
          final queryResult = entry.results;
          final resultMap = <String, Map<String, dynamic>>{};
          final yieldController =
              YieldController('QueryExecutor._executeQueryPlan.cacheCopy');

          for (var record in queryResult) {
            await yieldController.maybeYield();
            resultMap[record[schema.primaryKey].toString()] =
                Map<String, dynamic>.from(record);
          }
          final updatedResults = resultMap.values.toList();
          final filteredResults = await _dataStore.tableDataManager
              .mergeConsistency(tableName, updatedResults,
                  matcher: matcher, limit: limit);
          return PlanExecutionResult(filteredResults);
        }
      }
    }

    // Execute actual operation (range-partitioned IO; no full-table caching here)
    // Capture snapshot for consistency (Local View)
    final int? localViewId = _dataStore.readViewManager.registerReadView();
    try {
      List<Map<String, dynamic>> results;
      final operation = plan.operation;
      switch (operation.type) {
        case QueryOperationType.tableScan:
          final String? startAfterPk = (cursorMode == _CursorMode.primaryKey &&
                  cursorToken != null &&
                  cursorToken.mode == _CursorMode.primaryKey)
              ? cursorToken.primaryKey
              : null;
          final scanRes = await _performTableScan(
            tableName,
            matcher,
            limit: limit,
            offset: offset,
            orderBy: orderBy,
            startAfterPrimaryKey: startAfterPk,
            filter: cursorFilter,
          );
          results = scanRes.records;
          break;
        case QueryOperationType.indexScan:
          final opVal = operation.value;
          final Map<String, dynamic> cond = (opVal is Map<String, dynamic> &&
                  opVal['where'] is Map<String, dynamic>)
              ? (opVal['where'] as Map<String, dynamic>)
              : const <String, dynamic>{};
          final Uint8List? startAfterIndexKey =
              (cursorMode == _CursorMode.indexKey &&
                      cursorToken != null &&
                      cursorToken.mode == _CursorMode.indexKey)
                  ? cursorToken.indexKey
                  : null;
          final bool reverse = _parseIndexOrderByForCursor(
            schema: schemas[tableName]!,
            plan: plan,
            orderBy: orderBy,
          );
          results = await _performIndexScan(
            tableName,
            operation.indexName!,
            cond,
            matcher,
            limit: limit,
            offset: offset,
            orderBy: orderBy,
            startAfterIndexKey: startAfterIndexKey,
            reverse: reverse,
            filter: cursorFilter,
          );
          break;
        case QueryOperationType.union:
          final opVal = operation.value;
          final children = (opVal is Map<String, dynamic>)
              ? (opVal['children'] as List?)
              : null;
          if (children == null || children.isEmpty) {
            results = const [];
            break;
          }
          final plans = <QueryPlan>[];
          for (final c in children) {
            if (c is QueryPlan) plans.add(c);
          }
          final Uint8List? startAfterIndexKey =
              (cursorMode == _CursorMode.indexKey &&
                      cursorToken != null &&
                      cursorToken.mode == _CursorMode.indexKey)
                  ? cursorToken.indexKey
                  : null;
          final String? startAfterPk = (cursorMode == _CursorMode.primaryKey &&
                  cursorToken != null &&
                  cursorToken.mode == _CursorMode.primaryKey)
              ? cursorToken.primaryKey
              : null;
          final bool reverse = _parseIndexOrderByForCursor(
            schema: schemas[tableName]!,
            plan: plan,
            orderBy: orderBy,
          );

          final unionRecords = await _performUnionPlans(
            tableName,
            plans,
            schemas,
            limit: limit,
            offset: offset,
            orderBy: orderBy,
            startAfterPrimaryKey: startAfterPk,
            startAfterIndexKey: startAfterIndexKey,
            reverse: reverse,
          );
          results = unionRecords;
          break;
      }

      final bool hasSorting = orderBy != null && orderBy.isNotEmpty;
      bool isPkSort = true;
      if (hasSorting) {
        final parsed = _parseSortField(orderBy.first);
        if (parsed.field != schema.primaryKey) {
          isPkSort = false;
        }
      }

      // Determine sort direction for buffer scan (assuming PK-ish order in buffer)
      bool reverseBuffer = false;

      if (hasSorting) {
        final parsed = _parseSortField(orderBy.first);
        if (parsed.descending) {
          reverseBuffer = true;
        }
      }

      // Create filter for cursor-based pagination to apply during buffer scan
      bool Function(Map<String, dynamic>)? bufferFilter;
      if (cursorFilter != null) {
        bufferFilter = cursorFilter;
      } else if (cursorToken != null) {
        final pivotValues = <Object?>[];
        final matchers = <MatcherFunction>[];
        final fields = <String>[];

        try {
          if (cursorToken.mode == _CursorMode.primaryKey) {
            fields.add(schema.primaryKey);
            pivotValues.add(cursorToken.primaryKey);
            // ValueMatcher handles String vs Int comparison if needed (e.g. pkNumericString)
            matchers.add(
                ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType()));
          } else if (cursorToken.mode == _CursorMode.indexKey) {
            // Decode index key tuple to native values
            pivotValues
                .addAll(MemComparableKey.decodeTuple(cursorToken.indexKey!));

            final idxName = cursorToken.indexName!;
            // Find index schema match.
            // Note: indexName in token is the actual name.
            IndexSchema? idx;
            try {
              // Use getAllIndexes to ensure we find implicit unique/FK indexes too.
              idx = schema
                  .getAllIndexes()
                  .firstWhere((i) => i.actualIndexName == idxName);
            } catch (_) {
              // Not found
            }

            if (idx != null) {
              for (var f in idx.fields) {
                fields.add(f);
                matchers.add(
                    ValueMatcher.getMatcher(schema.getFieldMatcherType(f)));
              }
              if (!idx.unique) {
                fields.add(schema.primaryKey);
                matchers.add(
                    ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType()));
              }
            }
          }

          if (pivotValues.isNotEmpty &&
              pivotValues.length == matchers.length &&
              pivotValues.length == fields.length) {
            bufferFilter = (record) {
              // Component-wise comparison
              int cmp = 0;
              for (int i = 0; i < pivotValues.length; i++) {
                final val = record[fields[i]];
                // If field is missing, treat as null? ValueMatcher handles null.
                cmp = matchers[i](val, pivotValues[i]);
                if (cmp != 0) break;
              }

              // Cursor token represents the LAST returned record.
              // We want records AFTER the cursor.
              // ASC: Record > Cursor  (cmp > 0)
              // DESC: Record < Cursor (cmp < 0)
              return reverseBuffer ? cmp < 0 : cmp > 0;
            };
          }
        } catch (e) {
          // Log warning but safe fallthrough (buffer records won't be pre-filtered,
          // will be filtered by query plan merge later presumably, or just returning extra records is safeish)
          Logger.warn('Failed to build buffer cursor filter: $e',
              label: 'QueryExecutor');
        }
      }

      final int? bufferMergeLimit;
      if (isPkSort && limit != null) {
        // If cursor is used, we only need 'limit' records AFTER the cursor.
        // Without cursor, we might need offset + limit.
        if (cursorToken != null) {
          bufferMergeLimit = limit;
        } else {
          bufferMergeLimit = (offset ?? 0) + limit;
        }
      } else {
        bufferMergeLimit = null;
      }

      results = await _dataStore.tableDataManager.mergeConsistency(
        tableName,
        results,
        matcher: matcher,
        limit: bufferMergeLimit,
        orderBy: orderBy,
        filter: bufferFilter,
        reverse: reverseBuffer, // Pass reverse flag
      );

      // Cache query results (skip if already full-table cached)

      if (enableQueryCache &&
          TransactionContext.getCurrentTransactionId() == null) {
        final cacheKey = QueryCacheKey(
          tableName: tableName,
          condition: condition ?? QueryCondition(),
          orderBy: orderBy,
          limit: limit,
          offset: offset,
          cursor: cursor,
        );

        final int maxBytes = _queryCache.maxByteThreshold;
        if (_shouldCacheQueryResults(results, maxBytes: maxBytes)) {
          final copied = _copyResultList(results);
          final size = _estimateQueryResultSizeBytes(copied);
          final entry = _QueryCacheEntry(
            results: copied,
            createdAt: DateTime.now(),
            expiry: queryCacheExpiry,
            sizeBytes: size,
          );
          _queryCache.put(_buildQueryCacheKey(cacheKey), entry, size: size);
        }
      }

      return PlanExecutionResult(results);
    } finally {
      if (localViewId != null) {
        _dataStore.readViewManager.releaseReadView(localViewId);
      }
    }
  }

  /// Execute a UNION plan (OR / DNF), de-duplicating by primary key.
  ///
  /// Each child plan is executed with its own predicate matcher so that range-partition
  /// pruning remains effective even when the original query contains nested OR.
  Future<List<Map<String, dynamic>>> _performUnionPlans(
    String tableName,
    List<QueryPlan> plans,
    Map<String, TableSchema> schemas, {
    int? limit,
    int? offset,
    List<String>? orderBy,
    String? startAfterPrimaryKey,
    Uint8List? startAfterIndexKey,
    bool reverse = false,
  }) async {
    final tblSchema = schemas[tableName] ??
        await _dataStore.schemaManager?.getTableSchema(tableName);
    if (tblSchema == null) return const [];

    int effectiveOffset = offset ?? 0;
    if (effectiveOffset < 0) effectiveOffset = 0;

    final resultByPk = <String, Map<String, dynamic>>{};

    // Execute UNION branches in parallel (I/O-bound). This significantly improves
    // OR/DNF performance on large datasets with many branches.
    final int maxIo = _dataStore.config.maxIoConcurrency > 0
        ? _dataStore.config.maxIoConcurrency
        : plans.length;
    final int desiredConc = min(plans.length, max(1, maxIo));
    final int capTok =
        _dataStore.workloadScheduler.capacityTokens(WorkloadType.query);
    final int needTok = (desiredConc * 3 + 9) ~/ 10; // ceil(desiredConc * 0.3)
    final int requestTok = min(capTok, max(1, needTok));
    final lease = await _dataStore.workloadScheduler.tryAcquire(
      WorkloadType.query,
      requestedTokens: requestTok,
      minTokens: 1,
      label: 'QueryExecutor._performUnionPlans',
    );

    try {
      final int conc =
          min(plans.length, min(desiredConc, lease?.asConcurrency(0.3) ?? 1));

      final tasks = <Future<List<Map<String, dynamic>>> Function()>[
        for (final p in plans)
          () async {
            final op = p.operation;

            ConditionRecordMatcher? clauseMatcher;
            Map<String, dynamic>? clauseWhere;
            final v = op.value;
            if (v is Map<String, dynamic>) {
              final w = v['where'];
              if (w is Map<String, dynamic> && w.isNotEmpty) {
                clauseWhere = w;
              }
            }
            if (clauseWhere != null) {
              final qc = QueryCondition.fromMap(clauseWhere);
              // Normalize values for correct matcher behavior and pruning logic downstream.
              qc.normalize(schemas, tableName);
              if (!qc.isEmpty) {
                clauseMatcher =
                    ConditionRecordMatcher.prepare(qc, schemas, tableName);
              }
            }

            switch (op.type) {
              case QueryOperationType.tableScan:
                final scan = await _performTableScan(
                  tableName,
                  clauseMatcher,
                  limit: limit,
                  offset: 0,
                  orderBy: orderBy,
                  startAfterPrimaryKey: startAfterPrimaryKey,
                );
                return scan.records;
              case QueryOperationType.indexScan:
                final vv = op.value;
                final Map<String, dynamic> cond = (vv is Map<String, dynamic> &&
                            vv['where'] is Map<String, dynamic> ||
                        vv is Map<String, dynamic> &&
                            vv.containsKey(
                                'OR')) // OR in index scan? unexpected but handle op.value correctly
                    ? (vv['where'] ?? vv) as Map<String, dynamic>
                    : const <String, dynamic>{};
                return await _performIndexScan(
                  tableName,
                  op.indexName!,
                  cond,
                  clauseMatcher,
                  limit: limit,
                  offset: 0,
                  orderBy: orderBy,
                  startAfterIndexKey: startAfterIndexKey,
                  reverse: reverse,
                );
              case QueryOperationType.union:
                final vv = op.value;
                final children = (vv is Map<String, dynamic>)
                    ? (vv['children'] as List?)
                    : null;
                if (children == null || children.isEmpty) return const [];
                final subPlans = <QueryPlan>[];
                for (final c in children) {
                  if (c is QueryPlan) subPlans.add(c);
                }
                if (subPlans.isEmpty) return const [];
                return await _performUnionPlans(
                  tableName,
                  subPlans,
                  schemas,
                  limit: limit,
                  offset: 0,
                  orderBy: orderBy,
                  startAfterPrimaryKey: startAfterPrimaryKey,
                  startAfterIndexKey: startAfterIndexKey,
                  reverse: reverse,
                );
            }
          },
      ];

      final branchResults =
          await ParallelProcessor.execute<List<Map<String, dynamic>>>(
        tasks,
        concurrency: conc,
        label: 'QueryExecutor._performUnionPlans',
      );

      final yieldController =
          YieldController('QueryExecutor._performUnionPlans.merge');
      for (final records in branchResults) {
        final list = records ?? const <Map<String, dynamic>>[];
        for (final r in list) {
          await yieldController.maybeYield();
          final pk = r[tblSchema.primaryKey]?.toString();
          if (pk == null || pk.isEmpty) continue;
          resultByPk[pk] = r;
        }
      }
    } finally {
      lease?.release();
    }

    var out = resultByPk.values.toList(growable: true);

    // Preserve deterministic default order (PK asc) when caller didn't specify orderBy.
    if (orderBy == null || orderBy.isEmpty) {
      final pk = tblSchema.primaryKey;
      out =
          await ValueMatcher.sortMapList(out, [pk], [true], schemas, tableName);
    }

    return out;
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
      {bool enableQueryCache = false,
      int? limit,
      int? offset,
      Duration? queryCacheExpiry}) async {
    // Optimization: Instead of a full table scan, collect join keys from the left
    // records and perform a selective query on the right table.
    final leftKeyName =
        leftKey.contains('.') ? leftKey.split('.').last : leftKey;

    final leftJoinKeys = <dynamic>{};
    final yieldControllerKeys =
        YieldController('QueryExecutor._performJoin.keys');
    for (final r in leftRecords) {
      await yieldControllerKeys.maybeYield();
      final k = r[leftKeyName];
      if (k != null) leftJoinKeys.add(k);
    }

    if (leftJoinKeys.isEmpty && joinType != 'right') {
      // If there are no keys to join on, for INNER and LEFT joins,
      // the result depends on the join type.
      if (joinType == 'inner') {
        return []; // No keys, so no matches possible.
      }
      if (joinType == 'left') {
        // Return all left records with nulls for the right.
        final rightSchema = schemas[rightTableName];
        if (rightSchema == null) return leftRecords;
        return leftRecords.map((leftRecord) {
          final joinedRecord = Map<String, dynamic>.from(leftRecord);
          for (var field in rightSchema.fields) {
            joinedRecord['$rightTableName.${field.name}'] = null;
          }
          return joinedRecord;
        }).toList();
      }
    }

    final rightKeyName =
        rightKey.contains('.') ? rightKey.split('.').last : rightKey;
    List<Map<String, dynamic>> rightRecords;

    if (leftJoinKeys.isNotEmpty) {
      final rightTableCondition =
          QueryCondition().where(rightKeyName, 'IN', leftJoinKeys.toList());
      final rightSchema =
          await _dataStore.schemaManager?.getTableSchema(rightTableName);
      if (rightSchema == null) {
        return [];
      }
      final rightMatcher = ConditionRecordMatcher.prepare(
          rightTableCondition, {rightTableName: rightSchema}, rightTableName);
      // Use optimizer + full single-table pipeline (with caches)
      final rightPlan = await _dataStore
          .getQueryOptimizer()
          ?.optimize(rightTableName, rightTableCondition.build());
      if (rightPlan == null) {
        return [];
      }
      final rightPlanResult = await _executeQueryPlan(
        rightPlan,
        rightTableName,
        rightTableCondition,
        {rightTableName: rightSchema},
        rightMatcher,
        enableQueryCache: enableQueryCache,
        queryCacheExpiry: queryCacheExpiry,
      );
      rightRecords = rightPlanResult.records;
    } else {
      // LEFT keys empty (e.g., RIGHT JOIN needs full right scan): route through normal pipeline
      final rightCondition = QueryCondition(); // full scan
      final rightSchema = schemas[rightTableName] ??
          await _dataStore.schemaManager?.getTableSchema(rightTableName);
      if (rightSchema == null) {
        return [];
      }
      final rightPlan = await _dataStore
          .getQueryOptimizer()
          ?.optimize(rightTableName, rightCondition.build());
      if (rightPlan != null) {
        // Use full pipeline (with overlay application)
        final rightPlanResult = await _executeQueryPlan(
          rightPlan,
          rightTableName,
          rightCondition,
          {rightTableName: rightSchema},
          null,
          enableQueryCache: enableQueryCache,
          limit: limit,
          offset: offset,
          queryCacheExpiry: queryCacheExpiry,
        );
        rightRecords = rightPlanResult.records;
      } else {
        // Fallback: perform raw scan then apply overlays manually
        final int? localViewId = _dataStore.readViewManager.registerReadView();
        try {
          final scanRes = await _performTableScan(rightTableName, null);
          rightRecords = scanRes.records;
          rightRecords = await _dataStore.tableDataManager.mergeConsistency(
            rightTableName,
            rightRecords,
          );
        } finally {
          if (localViewId != null) {
            _dataStore.readViewManager.releaseReadView(localViewId);
          }
        }
      }
    }

    // Get all records from the right table
    final resultRecords = <Map<String, dynamic>>[];

    // Determine left table name (main table name)
    String leftTableName = mainTableName;
    if (leftKey.contains('.')) {
      leftTableName = leftKey.split('.')[0];
    }

    // Pre-compiled matchers and accessors for performance
    final leftFieldName =
        leftKey.contains('.') ? leftKey.split('.').last : leftKey;
    final leftSchema = ConditionRecordMatcher.getSchemaForField(
        leftKey, schemas, mainTableName);
    final matcher = leftSchema != null
        ? ValueMatcher.getMatcher(leftSchema.getFieldMatcherType(leftFieldName))
        : ValueMatcher.getMatcher(MatcherType.unsupported);

    // Closures to avoid repeated string parsing/key hunting in getFieldValue
    final leftValGetter = (Map<String, dynamic> r) =>
        ConditionRecordMatcher.getFieldValue(r, leftKey);
    final rightValGetter = (Map<String, dynamic> r) =>
        ConditionRecordMatcher.getFieldValue(r, rightKey);

    final isEquality = operator == '=';

    // Helper to canonicalize values for Hash Join (supports loose equality like int vs String)
    dynamic _canonicalizeKey(dynamic val) {
      if (val == null) return null;
      // Convert primitives to string to ensure 1 == "1" matches
      if (val is num || val is String || val is bool) {
        return val.toString();
      }
      return val;
    }

    // Build lookup table if equality join for O(N+M)
    Map<dynamic, List<Map<String, dynamic>>>? rightLookup;
    if (isEquality) {
      rightLookup = {};
      final yieldBuild =
          YieldController('QueryExecutor._performJoin.rightLookup');
      for (final rr in rightRecords) {
        await yieldBuild.maybeYield();
        final val = rightValGetter(rr);
        final key = _canonicalizeKey(val);
        rightLookup.putIfAbsent(key, () => []).add(rr);
      }
    }

    // Helper to merge records
    void mergeAndAdd(
        Map<String, dynamic> left, Map<String, dynamic> right, bool isInner) {
      final joinedRecord = <String, dynamic>{};

      // Process left table fields
      for (var entry in left.entries) {
        final key = entry.key;
        if (key.contains('.')) {
          joinedRecord[key] = entry.value;
        } else if (leftTableName.isNotEmpty) {
          joinedRecord['$leftTableName.$key'] = entry.value;
        } else {
          joinedRecord[key] = entry.value;
        }
      }

      // Process right table fields
      if (right.isNotEmpty) {
        for (var entry in right.entries) {
          joinedRecord['$rightTableName.${entry.key}'] = entry.value;
        }
      } else {
        // Null right record (LEFT/RIGHT JOIN mismatch)
        for (var field in (schemas[rightTableName]?.fields ?? [])) {
          joinedRecord['$rightTableName.${field.name}'] = null;
        }
      }
      resultRecords.add(joinedRecord);
    }

    final yieldController = YieldController('QueryExecutor._performJoin');

    // Handle Join Logic
    if (joinType == 'inner') {
      for (final lr in leftRecords) {
        await yieldController.maybeYield();
        final lVal = leftValGetter(lr);

        if (isEquality && rightLookup != null) {
          final lKey = _canonicalizeKey(lVal);
          final matches = rightLookup[lKey];
          if (matches != null) {
            for (final mr in matches) {
              await yieldController.maybeYield();
              mergeAndAdd(lr, mr, true);
            }
          }
        } else {
          // Fallback to O(N*M) for non-equality or failed lookup
          for (final rr in rightRecords) {
            await yieldController.maybeYield();
            final rVal = rightValGetter(rr);
            if (_evaluateJoinMatch(matcher, lVal, operator, rVal)) {
              mergeAndAdd(lr, rr, true);
            }
          }
        }
      }
    } else if (joinType == 'left') {
      for (final lr in leftRecords) {
        await yieldController.maybeYield();
        final lVal = leftValGetter(lr);
        bool hasMatch = false;

        if (isEquality && rightLookup != null) {
          final lKey = _canonicalizeKey(lVal);
          final matches = rightLookup[lKey];
          if (matches != null) {
            hasMatch = true;
            for (final mr in matches) {
              mergeAndAdd(lr, mr, false);
            }
          }
        } else {
          for (final rr in rightRecords) {
            await yieldController.maybeYield();
            final rVal = rightValGetter(rr);
            if (_evaluateJoinMatch(matcher, lVal, operator, rVal)) {
              hasMatch = true;
              mergeAndAdd(lr, rr, false);
            }
          }
        }

        if (!hasMatch) {
          // Left record with null right record
          mergeAndAdd(lr, const {}, false);
        }
      }
    } else if (joinType == 'right') {
      // Build left lookup for right join equality
      Map<dynamic, List<Map<String, dynamic>>>? leftLookupMap;
      if (isEquality) {
        leftLookupMap = {};
        for (final lr in leftRecords) {
          await yieldController.maybeYield();
          final val = leftValGetter(lr);
          final key = _canonicalizeKey(val);
          leftLookupMap.putIfAbsent(key, () => []).add(lr);
        }
      }

      for (final rr in rightRecords) {
        await yieldController.maybeYield();
        final rVal = rightValGetter(rr);
        bool hasMatch = false;

        if (isEquality && leftLookupMap != null) {
          final rKey = _canonicalizeKey(rVal);
          final matches = leftLookupMap[rKey];
          if (matches != null) {
            hasMatch = true;
            for (final ml in matches) {
              await yieldController.maybeYield();
              mergeAndAdd(ml, rr, false);
            }
          }
        } else {
          for (final lr in leftRecords) {
            await yieldController.maybeYield();
            final lVal = leftValGetter(lr);
            if (_evaluateJoinMatch(matcher, lVal, operator, rVal)) {
              hasMatch = true;
              mergeAndAdd(lr, rr, false);
            }
          }
        }

        if (!hasMatch) {
          _mergeRightWithNullLeft(rr, rightTableName, leftTableName,
              schemas[leftTableName], resultRecords);
        }
      }
    }

    return resultRecords;
  }

  void _mergeRightWithNullLeft(
      Map<String, dynamic> right,
      String rightTableName,
      String leftTableName,
      TableSchema? leftSchema,
      List<Map<String, dynamic>> target) {
    final joinedRecord = <String, dynamic>{};
    if (leftSchema != null) {
      for (var f in leftSchema.fields) {
        joinedRecord['$leftTableName.${f.name}'] = null;
      }
    }
    for (var entry in right.entries) {
      joinedRecord['$rightTableName.${entry.key}'] = entry.value;
    }
    target.add(joinedRecord);
  }

  bool _evaluateJoinMatch(MatcherFunction matcher, dynamic leftVal,
      String operator, dynamic rightVal) {
    if (leftVal == null || rightVal == null) {
      if (operator == '=') return leftVal == rightVal;
      if (operator == '!=' || operator == '<>') return leftVal != rightVal;
      return false;
    }
    final comparison = matcher(leftVal, rightVal);
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

  /// Perform table scan using the range-partition manager (incremental-first,
  /// footer + sparse index + binaryfuse filter + grouped IO) to avoid read amplification.
  ///
  /// Note: full-table caching and leader/wait synchronization have been intentionally
  /// retired in favor of precise range-partition reads + default limits to avoid
  /// read amplification and cross-query blocking.
  Future<TableScanResult> _performTableScan(
    String tableName,
    ConditionRecordMatcher? matcher, {
    int? limit,
    int? offset,
    List<String>? orderBy,
    String? startAfterPrimaryKey,
    bool Function(Map<String, dynamic>)? filter,
  }) async {
    try {
      return await _dataStore.tableDataManager.searchTableData(
        tableName,
        matcher,
        limit: limit,
        offset: offset,
        orderBy: orderBy,
        startAfterPrimaryKey: startAfterPrimaryKey,
        filter: filter,
      );
    } catch (e) {
      Logger.error('Table scan failed: $e',
          label: 'QueryExecutor._performTableScan');
      return TableScanResult(records: []);
    }
  }

  /// perform index scan
  Future<List<Map<String, dynamic>>> _performIndexScan(
    String tableName,
    String indexName,
    Map<String, dynamic> conditions,
    ConditionRecordMatcher? matcher, {
    int? limit,
    int? offset,
    List<String>? orderBy,
    Uint8List? startAfterIndexKey,
    bool reverse = false,
    bool Function(Map<String, dynamic>)? filter,
  }) async {
    try {
      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        return [];
      }

      // Index name used by storage is already the actual index name.
      final String actualIndexName = indexName;

      // get search value
      dynamic searchValue;
      String? fieldName;
      IndexSchema? indexSchema;
      try {
        indexSchema = schema.getAllIndexes().firstWhere(
              (idx) => idx.actualIndexName == actualIndexName,
            );
      } catch (_) {
        indexSchema = null;
      }
      if (indexSchema != null && indexSchema.fields.isNotEmpty) {
        fieldName = indexSchema.fields.first;
      } else if (actualIndexName.startsWith('uniq_')) {
        fieldName = actualIndexName.substring(5);
      } else if (conditions.isNotEmpty) {
        fieldName = conditions.keys.first;
      }
      if (fieldName != null) {
        searchValue = conditions[fieldName];
      }
      IndexCondition indexCondition;
      if (searchValue == null) {
        if (indexSchema != null) {
          // Full index scan required (e.g. for orderBy optimization)
          indexCondition = IndexCondition.fromMap({'SCAN': true});
        } else {
          // Fallback to table scan if the condition value for the index is not provided.
          final res = await _performTableScan(tableName, matcher,
              limit: limit, offset: offset, orderBy: orderBy, filter: filter);
          return res.records;
        }
      } else {
        final indexConditionValue =
            fieldName != null ? conditions[fieldName] : searchValue;
        if (indexConditionValue is Map<String, dynamic>) {
          indexCondition = IndexCondition.fromMap(indexConditionValue);
        } else {
          indexCondition = IndexCondition.fromMap({'=': indexConditionValue});
        }
      }

      // use searchIndex to get pointers
      // IMPORTANT: offset is applied by the final pagination step in QueryExecutor.
      // Therefore, we must request at least (offset + limit) candidates here to avoid returning
      // too few records for index-based pagination.
      final int effectiveOffset = (offset == null || offset <= 0) ? 0 : offset;

      // Safety: avoid unbounded index reads that can OOM on large tables.
      // Higher-level executor applies default limits; if it doesn't, we fall back to a bounded table scan.
      if (limit == null) {
        final res = await _performTableScan(tableName, matcher,
            limit: limit, offset: offset, orderBy: orderBy, filter: filter);
        return res.records;
      }
      if (limit <= 0) return const [];

      final targetNeed = effectiveOffset + limit;
      if (targetNeed <= 0) return const [];

      final tblSchema =
          await _dataStore.schemaManager?.getTableSchema(tableName);
      if (tblSchema == null) return [];
      final pkMatcher =
          ValueMatcher.getMatcher(tblSchema.getPrimaryKeyMatcherType());

      // Decide whether the requested order can be produced directly by this index scan.
      // If orderBy does NOT match this index, we must scan the full index range and keep
      // only the topK (offset+limit) records in memory to guarantee correct ordering.
      final List<String> ob = orderBy ?? const <String>[];
      final bool hasOrderBy = ob.isNotEmpty;
      bool orderByAligned = true;
      if (hasOrderBy) {
        try {
          final spec = _resolveIndexSpecForCursor(schema, actualIndexName);
          if (ob.length > spec.fields.length) {
            orderByAligned = false;
          } else {
            bool? firstIsDesc;
            for (int i = 0; i < ob.length; i++) {
              final parsed = _parseSortField(ob[i]);
              final f = parsed.field.contains('.')
                  ? parsed.field.split('.').last
                  : parsed.field;
              if (f != spec.fields[i]) {
                orderByAligned = false;
                break;
              }
              if (i == 0) {
                firstIsDesc = parsed.descending;
              } else if (firstIsDesc != parsed.descending) {
                // Mixed directions cannot be satisfied by a single index scan.
                orderByAligned = false;
                break;
              }
            }
          }
        } catch (_) {
          orderByAligned = false;
        }
      }

      final yieldController =
          YieldController('QueryExecutor._performIndexScan');

      // Hard guard against pathological non-progress loops.
      const int maxLoops = 1000000;

      Uint8List? resumeKey = startAfterIndexKey;

      // -------------------- Case A: orderBy aligns with index => streaming, can stop early --------------------
      if (!hasOrderBy || orderByAligned) {
        final out = <Map<String, dynamic>>[];
        int loops = 0;
        while (out.length < targetNeed) {
          await yieldController.maybeYield();
          loops++;
          if (loops > maxLoops) break;

          final int remaining = targetNeed - out.length;
          final int batch = remaining;

          final indexResults = await _indexManager.searchIndex(
            tableName,
            actualIndexName,
            indexCondition,
            limit: batch,
            offset: null,
            startAfterKey: resumeKey,
            reverse: reverse,
            orderBy: orderBy,
          );

          if (indexResults.requiresTableScan) {
            final res = await _performTableScan(tableName, matcher,
                limit: limit, offset: offset, orderBy: orderBy, filter: filter);
            return res.records;
          }

          final pks = indexResults.primaryKeys;
          final lastKey = indexResults.lastKey;

          // End reached: no more index entries to scan.
          if ((pks.isEmpty) && (lastKey == null)) break;

          // Fetch records for this index page (order is restored using pk list).
          final records = pks.isEmpty
              ? const <Map<String, dynamic>>[]
              : (await _dataStore.tableDataManager.queryRecordsBatch(
                  tableName,
                  pks,
                ))
                  .records;

          final recordByPk = <String, Map<String, dynamic>>{};
          for (final r in records) {
            final pk = r[tblSchema.primaryKey]?.toString();
            if (pk != null && pk.isNotEmpty) {
              recordByPk[pk] = r;
            }
          }

          if (pks.isNotEmpty) {
            for (final pk in pks) {
              if (out.length >= targetNeed) break;
              final rec = recordByPk[pk];
              if (rec == null) continue;

              final be = _dataStore.writeBufferManager
                  .getBufferedRecord(tableName, pk);
              if (be != null && be.operation == BufferOperationType.delete) {
                continue;
              }
              if ((matcher == null || matcher.matches(rec)) &&
                  (filter == null || filter(rec))) {
                out.add(rec);
              }
            }
          }

          // Progress cursor.
          if (lastKey != null && lastKey.isNotEmpty) {
            if (resumeKey != null &&
                resumeKey.isNotEmpty &&
                MemComparableKey.compare(lastKey, resumeKey) == 0) {
              break;
            }
            resumeKey = lastKey;
          } else {
            if (pks.isEmpty) break;
            // Best-effort: compute a resume key from the last fetched record.
            final lastPk = pks.last;
            final lastRec = recordByPk[lastPk];
            if (lastRec == null) break;
            try {
              final spec = _resolveIndexSpecForCursor(schema, actualIndexName);
              final comps = <Uint8List>[];
              final bool truncateText = !spec.isUnique;
              for (final f in spec.fields) {
                final v = lastRec[f];
                final c = schema.encodeFieldComponentToMemComparable(
                  f,
                  v,
                  truncateText: truncateText,
                );
                if (c == null) throw StateError('Missing index field $f');
                comps.add(c);
              }
              if (!spec.isUnique) {
                comps.add(schema.encodePrimaryKeyComponent(lastPk));
              }
              final computed = MemComparableKey.encodeTuple(comps);
              if (computed.isNotEmpty) {
                resumeKey = computed;
              } else {
                break;
              }
            } catch (_) {
              break;
            }
          }
        }
        return out;
      }

      // -------------------- Case B: orderBy does NOT align with index => full scan + topK --------------------
      // Parse orderBy into comparable fields and directions.
      final sortFields = <String>[];
      final sortDirections = <bool>[]; // true=ASC, false=DESC
      for (final raw in ob) {
        String f = raw.trim();
        bool asc = true;
        if (f.startsWith('-')) {
          asc = false;
          f = f.substring(1).trim();
        } else if (f.toUpperCase().endsWith(' DESC')) {
          asc = false;
          f = f.substring(0, f.length - 5).trim();
        } else if (f.toUpperCase().endsWith(' ASC')) {
          asc = true;
          f = f.substring(0, f.length - 4).trim();
        }
        sortFields.add(f);
        sortDirections.add(asc);
      }

      // Pre-build matchers for topK compare (critical for performance).
      final schemas = <String, TableSchema>{tableName: schema};
      final orderMatchers = <MatcherFunction>[];
      for (final f in sortFields) {
        final s =
            ConditionRecordMatcher.getSchemaForField(f, schemas, tableName);
        final fieldName = f.contains('.') ? f.split('.').last : f;
        orderMatchers.add(
          ValueMatcher.getMatcher(
              s?.getFieldMatcherType(fieldName) ?? MatcherType.unsupported),
        );
      }

      int compareRecords(Map<String, dynamic> a, Map<String, dynamic> b) {
        for (int i = 0; i < sortFields.length; i++) {
          final f = sortFields[i];
          final asc = sortDirections[i];
          final matcherFn = orderMatchers[i];
          final va = ConditionRecordMatcher.getFieldValue(a, f);
          final vb = ConditionRecordMatcher.getFieldValue(b, f);
          final c = matcherFn(va, vb);
          if (c != 0) return asc ? c : -c;
        }
        // Stable tie-breaker: primary key ASC.
        final ka = a[tblSchema.primaryKey];
        final kb = b[tblSchema.primaryKey];
        return pkMatcher(ka, kb);
      }

      final selector = TopKHeap<Map<String, dynamic>>(
          k: targetNeed, compare: compareRecords);

      int loops = 0;
      while (true) {
        await yieldController.maybeYield();
        loops++;
        if (loops > maxLoops) break;

        final int batch = targetNeed;

        final indexResults = await _indexManager.searchIndex(
          tableName,
          actualIndexName,
          indexCondition,
          limit: batch,
          offset: null,
          startAfterKey: resumeKey,
          reverse: reverse,
          orderBy: orderBy,
        );

        if (indexResults.requiresTableScan) {
          final res = await _performTableScan(tableName, matcher,
              limit: limit, offset: offset, orderBy: orderBy, filter: filter);
          return res.records;
        }

        final pks = indexResults.primaryKeys;
        final lastKey = indexResults.lastKey;
        if ((pks.isEmpty) && (lastKey == null)) break;

        final records = pks.isEmpty
            ? const <Map<String, dynamic>>[]
            : (await _dataStore.tableDataManager.queryRecordsBatch(
                tableName,
                pks,
              ))
                .records;

        final recordByPk = <String, Map<String, dynamic>>{};
        for (final r in records) {
          final pk = r[tblSchema.primaryKey]?.toString();
          if (pk != null && pk.isNotEmpty) {
            recordByPk[pk] = r;
          }
        }

        if (pks.isNotEmpty) {
          for (final pk in pks) {
            final rec = recordByPk[pk];
            if (rec == null) continue;

            final be =
                _dataStore.writeBufferManager.getBufferedRecord(tableName, pk);
            if (be != null && be.operation == BufferOperationType.delete) {
              continue;
            }
            if ((matcher == null || matcher.matches(rec)) &&
                (filter == null || filter(rec))) {
              selector.offer(rec);
            }
          }
        }

        if (lastKey != null && lastKey.isNotEmpty) {
          if (resumeKey != null &&
              resumeKey.isNotEmpty &&
              MemComparableKey.compare(lastKey, resumeKey) == 0) {
            break;
          }
          resumeKey = lastKey;
        } else {
          if (pks.isEmpty) break;
          // Without lastKey we cannot reliably continue a full scan.
          break;
        }
      }

      return selector.toSortedList();
    } catch (e) {
      Logger.error('Index scan failed: $e',
          label: 'QueryExecutor._performIndexScan');
      final res = await _performTableScan(tableName, matcher,
          limit: limit, offset: offset, orderBy: orderBy, filter: filter);
      return res.records;
    }
  }

  /// apply sort
  Future<List<Map<String, dynamic>>> _applySort(
      List<Map<String, dynamic>> data,
      List<String> orderBy,
      Map<String, TableSchema> schemas,
      String tableName) async {
    try {
      if (data.isEmpty) return data;

      // Create sort directions list with same length as orderBy, default all to ascending (true)
      final List<bool> sortDirections = List.filled(orderBy.length, true);
      final List<String> sortFields = List.filled(orderBy.length, '');

      // Process possible sort direction information in orderBy
      final yieldController = YieldController('QueryExecutor._applySort');
      for (int i = 0; i < orderBy.length; i++) {
        await yieldController.maybeYield();
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

      // Offload sorting to isolate
      await yieldController.maybeYield(); // Keep the yield
      data = await ValueMatcher.sortMapList(
          data, sortFields, sortDirections, schemas, tableName);
      return data;
    } catch (e) {
      Logger.error('Sort failed: $e', label: "QueryExecutor-_applySort");
      throw StateError('Error applying sort: ${e.toString()}');
    }
  }

  /// Parse a sort field string into its field name and direction.
  ({String field, bool descending}) _parseSortField(String sortField) {
    sortField = sortField.trim();
    if (sortField.startsWith('-')) {
      return (field: sortField.substring(1).trim(), descending: true);
    }
    final upper = sortField.toUpperCase();
    if (upper.endsWith(' DESC')) {
      return (
        field: sortField.substring(0, sortField.length - 5).trim(),
        descending: true
      );
    }
    if (upper.endsWith(' ASC')) {
      return (
        field: sortField.substring(0, sortField.length - 4).trim(),
        descending: false
      );
    }
    return (field: sortField, descending: false);
  }

  String _normalizeCursorFieldName(String field) {
    final f = field.trim();
    final dot = f.lastIndexOf('.');
    return dot == -1 ? f : f.substring(dot + 1);
  }

  /// Parse primary key order from orderBy list.
  ({bool isPkOrder, bool reverse}) _parsePrimaryKeyOrder(
      List<String>? orderBy, String primaryKey) {
    bool isPkOrder = true;
    bool reverse = false;
    if (orderBy != null && orderBy.isNotEmpty) {
      if (orderBy.length == 1) {
        String f = orderBy[0];
        final parsed = _parseSortField(f);
        f = parsed.field;
        final isDesc = parsed.descending;
        isPkOrder = (f == primaryKey);
        reverse = isPkOrder && isDesc;
      } else {
        isPkOrder = false;
      }
    }
    return (isPkOrder: isPkOrder, reverse: reverse);
  }

  /// Default ordering when caller does not provide [orderBy].
  ///
  /// IMPORTANT: If the plan is an INDEX SCAN, default to index-field order
  /// instead of primary key order. This enables index-key cursor pagination
  /// and avoids forcing expensive post-sorts on large datasets.
  List<String> _defaultOrderByForPlan({
    required TableSchema schema,
    required QueryPlan plan,
  }) {
    final op = plan.operation;
    if (op.type == QueryOperationType.indexScan) {
      final idxName = op.indexName;
      if (idxName != null && idxName.isNotEmpty) {
        try {
          final spec = _resolveIndexSpecForCursor(schema, idxName);
          if (spec.fields.isNotEmpty) {
            return List<String>.from(spec.fields, growable: false);
          }
        } catch (_) {}
      }
    }
    // UNION and TABLE SCAN default to PK ordering.
    return <String>[schema.primaryKey];
  }

  /// Parse index orderBy to determine reverse flag for index cursor.
  bool _parseIndexOrderByForCursor({
    required TableSchema schema,
    required QueryPlan plan,
    required List<String>? orderBy,
  }) {
    if (orderBy == null || orderBy.isEmpty) return false;
    final idxName = plan.operation.indexName;
    if (idxName == null) return false;
    try {
      final idx = schema
          .getAllIndexes()
          .firstWhere((i) => i.actualIndexName == idxName);
      if (orderBy.length != idx.fields.length) return false;

      // We assume validation has already passed and all fields have uniform direction.
      final parsed = _parseSortField(orderBy[0]);
      return parsed.descending;
    } catch (_) {
      return false;
    }
  }

  /// Resolve index spec for cursor building.
  ({List<String> fields, bool isUnique}) _resolveIndexSpecForCursor(
      TableSchema schema, String indexName) {
    try {
      final idx = schema
          .getAllIndexes()
          .firstWhere((i) => i.actualIndexName == indexName);
      return (fields: idx.fields, isUnique: idx.unique);
    } catch (_) {
      // Fallback for implicit unique single-field indexes (uniq_field).
      if (indexName.startsWith('uniq_') && indexName.length > 5) {
        return (fields: <String>[indexName.substring(5)], isUnique: true);
      }
      throw BusinessError(
        'Index schema not found for cursor pagination.',
        type: BusinessErrorType.dbError,
        data: {'index': indexName},
      );
    }
  }

  /// Validate that orderBy matches index key order for cursor pagination.
  void _validateIndexOrderByForCursor({
    required String tableName,
    required TableSchema schema,
    required QueryPlan plan,
    required List<String> orderBy,
  }) {
    final idxName = plan.operation.indexName;
    if (idxName == null) {
      throw BusinessError(
        'Index scan plan is missing indexName for cursor pagination.',
        type: BusinessErrorType.dbError,
        data: {'table': tableName},
      );
    }
    final spec = _resolveIndexSpecForCursor(schema, idxName);
    if (orderBy.length != spec.fields.length) {
      throw BusinessError(
        'Index-key cursor pagination requires orderBy to match index fields exactly.',
        type: BusinessErrorType.dbError,
        data: {
          'table': tableName,
          'index': idxName,
          'orderBy': orderBy,
          'indexFields': spec.fields,
        },
      );
    }
    bool firstIsDesc = false;
    for (int i = 0; i < orderBy.length; i++) {
      String f = orderBy[i];
      final parsed = _parseSortField(f);
      f = parsed.field;
      final isDesc = parsed.descending;

      if (f != spec.fields[i]) {
        throw BusinessError(
          'Index-key cursor pagination requires orderBy to match index fields in the same order.',
          type: BusinessErrorType.dbError,
          data: {
            'table': tableName,
            'index': idxName,
            'orderBy': orderBy,
            'indexFields': spec.fields,
            'mismatchAt': i,
          },
        );
      }

      if (i == 0) {
        firstIsDesc = isDesc;
      } else if (isDesc != firstIsDesc) {
        throw BusinessError(
          'Cursor pagination for multi-field indexes requires a uniform sort direction (all ASC or all DESC).',
          type: BusinessErrorType.dbError,
          data: {
            'table': tableName,
            'index': idxName,
            'orderBy': orderBy,
          },
        );
      }
    }
  }

  /// Validate index cursor support: all where conditions must be covered by index fields.
  ///
  /// Note: OR queries are converted to UNION plans by the optimizer, and UNION plans
  /// are rejected before this validation. AND nodes are flattened by _optimizeAndOnly
  /// into a flat field-to-condition map. The AND/OR check here is defensive programming
  /// to handle edge cases or future code changes.
  void _validateIndexCursorSupported({
    required String tableName,
    required TableSchema schema,
    required String indexName,
    required Map<String, dynamic> where,
  }) {
    final spec = _resolveIndexSpecForCursor(schema, indexName);
    final fieldSet = spec.fields.toSet();
    for (final e in where.entries) {
      final k = e.key;
      // Defensive: skip AND/OR nodes (should not appear in index scan where conditions
      // as optimizer flattens them, but keep for robustness).
      if (k == 'AND' || k == 'OR') continue;
      if (!fieldSet.contains(k)) {
        throw BusinessError(
          'Cursor pagination for index scans requires that all query conditions are covered by the index fields.',
          type: BusinessErrorType.dbError,
          data: {
            'table': tableName,
            'index': indexName,
            'unsupportedField': k,
            'indexFields': spec.fields,
          },
        );
      }
    }
  }

  bool _sameStringList(List<String> a, List<String> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  List<String> _extractOrderByFieldNamesForCursor(List<String> orderBy) {
    if (orderBy.isEmpty) return const <String>[];
    final out = <String>[];
    for (final raw in orderBy) {
      final parsed = _parseSortField(raw);
      out.add(_normalizeCursorFieldName(parsed.field));
    }
    return out;
  }

  bool Function(Map<String, dynamic>) _buildSortKeyCursorFilter({
    required String tableName,
    required TableSchema schema,
    required Map<String, TableSchema> schemas,
    required List<String> orderBy,
    required _QueryCursorToken cursorToken,
  }) {
    if (cursorToken.mode != _CursorMode.sortKey) {
      throw BusinessError(
        'Cursor token mode mismatch (expected sortKey).',
        type: BusinessErrorType.dbError,
        data: {'table': tableName},
      );
    }
    final tokenFields = cursorToken.sortFields;
    final keyBytes = cursorToken.sortKey;
    if (tokenFields == null ||
        tokenFields.isEmpty ||
        keyBytes == null ||
        keyBytes.isEmpty) {
      throw BusinessError(
        'Invalid sort-key cursor token.',
        type: BusinessErrorType.dbError,
        data: {'table': tableName},
      );
    }
    if (orderBy.isEmpty) {
      throw BusinessError(
        'Sort-key cursor requires explicit orderBy.',
        type: BusinessErrorType.dbError,
        data: {'table': tableName},
      );
    }

    final orderFieldsRaw = <String>[];
    final orderDesc = <bool>[];
    final normalizedFields = <String>[];
    for (final raw in orderBy) {
      final parsed = _parseSortField(raw);
      orderFieldsRaw.add(parsed.field);
      orderDesc.add(parsed.descending);
      normalizedFields.add(_normalizeCursorFieldName(parsed.field));
    }

    if (!_sameStringList(normalizedFields, tokenFields)) {
      throw BusinessError(
        'Cursor orderBy fields do not match current query orderBy.',
        type: BusinessErrorType.dbError,
        data: {
          'table': tableName,
          'cursorFields': tokenFields,
          'orderByFields': normalizedFields,
        },
      );
    }

    final tokenDesc = cursorToken.sortDesc;
    if (tokenDesc == null || tokenDesc.length != tokenFields.length) {
      throw BusinessError(
        'Invalid sort-key cursor token (missing direction).',
        type: BusinessErrorType.dbError,
        data: {'table': tableName},
      );
    }
    for (int i = 0; i < orderDesc.length; i++) {
      final expected = tokenDesc[i] ^ cursorToken.isBackward;
      if (orderDesc[i] != expected) {
        throw BusinessError(
          'Cursor orderBy direction does not match current orderBy.',
          type: BusinessErrorType.dbError,
          data: {
            'table': tableName,
            'cursorDesc': tokenDesc,
            'orderByDesc': orderDesc,
            'isBackward': cursorToken.isBackward,
          },
        );
      }
    }

    final pivotValues = MemComparableKey.decodeTuple(keyBytes);
    final expectedLen = tokenFields.length + 1; // + primary key tie-breaker
    if (pivotValues.length != expectedLen) {
      throw BusinessError(
        'Invalid sort-key cursor payload.',
        type: BusinessErrorType.dbError,
        data: {
          'table': tableName,
          'expected': expectedLen,
          'actual': pivotValues.length,
        },
      );
    }

    final matchers = <MatcherFunction>[];
    for (int i = 0; i < tokenFields.length; i++) {
      final schemaForField = ConditionRecordMatcher.getSchemaForField(
              orderFieldsRaw[i], schemas, tableName) ??
          schema;
      matchers.add(
        ValueMatcher.getMatcher(
            schemaForField.getFieldMatcherType(tokenFields[i])),
      );
    }

    final pkName = schema.primaryKey;
    final pkMatcher =
        ValueMatcher.getMatcher(schema.getPrimaryKeyMatcherType());
    final pivotPk = pivotValues.last;

    return (record) {
      int cmp = 0;
      for (int i = 0; i < tokenFields.length; i++) {
        final val =
            ConditionRecordMatcher.getFieldValue(record, orderFieldsRaw[i]);
        final c0 = matchers[i](val, pivotValues[i]);
        if (c0 != 0) {
          cmp = orderDesc[i] ? -c0 : c0;
          break;
        }
      }
      if (cmp == 0) {
        final pkVal = record[pkName] ?? record['$tableName.$pkName'];
        cmp = pkMatcher(pkVal, pivotPk);
      }
      // Cursor token represents the last returned record in the scan direction.
      // We want records strictly AFTER the cursor in the same direction.
      return cmp > 0;
    };
  }

  /// Determine cursor mode based on plan and orderBy.
  /// Returns null if the current query configuration (e.g. non-indexed orderBy)
  /// does not support cursor-based pagination.
  _CursorMode? _determineCursorMode({
    required String tableName,
    required TableSchema schema,
    required QueryPlan plan,
    required List<String> orderBy,
    required _QueryCursorToken? cursorToken,
  }) {
    final op = plan.operation;
    final pkOrder = _parsePrimaryKeyOrder(orderBy, schema.primaryKey);

    if (cursorToken != null) {
      if (cursorToken.mode == _CursorMode.primaryKey) {
        if (op.type != QueryOperationType.tableScan) {
          throw BusinessError(
            'Primary-key cursor requires a TABLE SCAN plan.',
            type: BusinessErrorType.dbError,
            data: {'table': tableName, 'plan': op.type.toString()},
          );
        }
        if (!pkOrder.isPkOrder) {
          throw BusinessError(
            'Primary-key cursor requires ordering by primary key.',
            type: BusinessErrorType.dbError,
            data: {'table': tableName, 'orderBy': orderBy},
          );
        }
        // When navigating backward (isBackward=true), we reverse the scan direction,
        // so pkOrder.reverse will be the opposite of the original cursor's reverse.
        // The expected relationship is: pkOrder.reverse == (cursorToken.reverse XOR isBackward)
        final bool expectedReverse =
            cursorToken.reverse ^ cursorToken.isBackward;
        if (expectedReverse != pkOrder.reverse) {
          throw BusinessError(
            'Cursor order does not match current orderBy.',
            type: BusinessErrorType.dbError,
            data: {
              'table': tableName,
              'orderBy': orderBy,
              'cursorReverse': cursorToken.reverse,
              'isBackward': cursorToken.isBackward,
            },
          );
        }
        return _CursorMode.primaryKey;
      }

      if (cursorToken.mode == _CursorMode.sortKey) {
        if (op.type != QueryOperationType.tableScan &&
            op.type != QueryOperationType.indexScan) {
          throw BusinessError(
            'Sort-key cursor requires a TABLE/INDEX scan plan.',
            type: BusinessErrorType.dbError,
            data: {'table': tableName, 'plan': op.type.toString()},
          );
        }
        if (orderBy.isEmpty) {
          throw BusinessError(
            'Sort-key cursor requires explicit orderBy.',
            type: BusinessErrorType.dbError,
            data: {'table': tableName},
          );
        }
        final tokenFields = cursorToken.sortFields ?? const <String>[];
        final curFields = _extractOrderByFieldNamesForCursor(orderBy);
        final curDesc =
            orderBy.map((e) => _parseSortField(e).descending).toList();
        if (tokenFields.isEmpty || !_sameStringList(curFields, tokenFields)) {
          throw BusinessError(
            'Cursor orderBy fields do not match current query orderBy.',
            type: BusinessErrorType.dbError,
            data: {
              'table': tableName,
              'cursorFields': tokenFields,
              'orderByFields': curFields,
            },
          );
        }
        final tokenDesc = cursorToken.sortDesc ?? const <bool>[];
        if (tokenDesc.length == curDesc.length) {
          for (int i = 0; i < curDesc.length; i++) {
            final expected = tokenDesc[i] ^ cursorToken.isBackward;
            if (curDesc[i] != expected) {
              throw BusinessError(
                'Cursor orderBy direction does not match current orderBy.',
                type: BusinessErrorType.dbError,
                data: {
                  'table': tableName,
                  'cursorDesc': tokenDesc,
                  'orderByDesc': curDesc,
                  'isBackward': cursorToken.isBackward,
                },
              );
            }
          }
        }
        return _CursorMode.sortKey;
      }

      // indexKey mode
      if (op.type != QueryOperationType.indexScan) {
        throw BusinessError(
          'Index-key cursor requires an INDEX SCAN plan.',
          type: BusinessErrorType.dbError,
          data: {'table': tableName, 'plan': op.type.toString()},
        );
      }
      final idxName = op.indexName ?? '';
      if (idxName.isEmpty || cursorToken.indexName != idxName) {
        throw BusinessError(
          'Cursor does not match the index used by the query plan.',
          type: BusinessErrorType.dbError,
          data: {
            'table': tableName,
            'planIndex': idxName,
            'cursorIndex': cursorToken.indexName,
          },
        );
      }
      final opVal = op.value;
      final Map<String, dynamic> where = (opVal is Map<String, dynamic> &&
              opVal['where'] is Map<String, dynamic>)
          ? (opVal['where'] as Map<String, dynamic>)
          : const <String, dynamic>{};
      _validateIndexCursorSupported(
        tableName: tableName,
        schema: schema,
        indexName: idxName,
        where: where,
      );
      if (orderBy.isNotEmpty) {
        _validateIndexOrderByForCursor(
          tableName: tableName,
          schema: schema,
          plan: plan,
          orderBy: orderBy,
        );
      }
      return _CursorMode.indexKey;
    }

    // First page: choose based on plan type.
    if (op.type == QueryOperationType.tableScan) {
      if (!pkOrder.isPkOrder) {
        // Sorting by non-primary key: fall back to sort-key cursor (orderBy + PK).
        return orderBy.isNotEmpty ? _CursorMode.sortKey : null;
      }
      return _CursorMode.primaryKey;
    }

    if (op.type == QueryOperationType.indexScan) {
      final idxName = op.indexName ?? '';
      if (idxName.isEmpty) {
        throw BusinessError(
          'Index scan plan is missing indexName for cursor pagination.',
          type: BusinessErrorType.dbError,
          data: {'table': tableName},
        );
      }
      final opVal = op.value;
      final Map<String, dynamic> where = (opVal is Map<String, dynamic> &&
              opVal['where'] is Map<String, dynamic>)
          ? (opVal['where'] as Map<String, dynamic>)
          : const <String, dynamic>{};

      if (where.isNotEmpty) {
        try {
          _validateIndexCursorSupported(
            tableName: tableName,
            schema: schema,
            indexName: idxName,
            where: where,
          );
        } catch (e) {
          // Even if index-key cursor is not supported, we can still provide
          // sort-key cursor as long as results are ordered by [orderBy].
          return orderBy.isNotEmpty ? _CursorMode.sortKey : null;
        }
      }
      if (orderBy.isNotEmpty) {
        try {
          _validateIndexOrderByForCursor(
            tableName: tableName,
            schema: schema,
            plan: plan,
            orderBy: orderBy,
          );
        } catch (e) {
          // If orderBy doesn't match the index, fall back to sort-key cursor.
          return _CursorMode.sortKey;
        }
      }
      return _CursorMode.indexKey;
    }

    return null;
  }

  String _buildNextCursor({
    required _CursorMode mode,
    required String tableName,
    required TableSchema schema,
    required QueryPlan plan,
    required List<String>? orderBy,
    required Map<String, dynamic> lastRecord,
    bool isBackward = false,
  }) {
    if (mode == _CursorMode.primaryKey) {
      final pkName = schema.primaryKey;
      final pkVal =
          (lastRecord[pkName] ?? lastRecord['$tableName.$pkName'])?.toString();
      if (pkVal == null || pkVal.isEmpty) {
        throw BusinessError(
          'Cannot build next cursor: primary key is missing from the last record.',
          type: BusinessErrorType.dbError,
          data: {'table': tableName, 'primaryKey': pkName},
        );
      }
      final pkOrder = _parsePrimaryKeyOrder(orderBy, pkName);
      if (!pkOrder.isPkOrder) {
        throw BusinessError(
          'Cannot build primary-key cursor when orderBy is not primary key.',
          type: BusinessErrorType.dbError,
          data: {'table': tableName, 'orderBy': orderBy},
        );
      }
      return _QueryCursorToken.primaryKey(
        tableName: tableName,
        primaryKey: pkVal,
        reverse: pkOrder.reverse,
        isBackward: isBackward,
      ).encode();
    }

    if (mode == _CursorMode.sortKey) {
      final ob = orderBy ?? const <String>[];
      if (ob.isEmpty) {
        throw BusinessError(
          'Cannot build sort-key cursor without orderBy.',
          type: BusinessErrorType.dbError,
          data: {'table': tableName},
        );
      }

      final sortFields = <String>[];
      final sortDesc = <bool>[];
      final comps = <Uint8List>[];
      for (final raw in ob) {
        final parsed = _parseSortField(raw);
        final rawField = parsed.field;
        final fieldName = _normalizeCursorFieldName(rawField);
        sortFields.add(fieldName);
        sortDesc.add(parsed.descending);

        final v = ConditionRecordMatcher.getFieldValue(lastRecord, rawField);
        final c = (v == null)
            ? MemComparableKey.encodeNull()
            : schema.encodeFieldComponentToMemComparable(
                  fieldName,
                  v,
                  truncateText: false,
                ) ??
                MemComparableKey.encodeTextLex(v.toString());
        comps.add(c);
      }

      final pkName = schema.primaryKey;
      final pkVal =
          (lastRecord[pkName] ?? lastRecord['$tableName.$pkName'])?.toString();
      if (pkVal == null || pkVal.isEmpty) {
        throw BusinessError(
          'Cannot build sort-key cursor: primary key is missing from the last record.',
          type: BusinessErrorType.dbError,
          data: {'table': tableName, 'primaryKey': pkName},
        );
      }
      comps.add(schema.encodePrimaryKeyComponent(pkVal));

      return _QueryCursorToken.sortKey(
        tableName: tableName,
        sortFields: sortFields,
        sortDesc: sortDesc,
        sortKey: MemComparableKey.encodeTuple(comps),
        isBackward: isBackward,
      ).encode();
    }

    // indexKey cursor
    final idxName = plan.operation.indexName;
    if (idxName == null || idxName.isEmpty) {
      throw BusinessError(
        'Cannot build next cursor: missing indexName from query plan.',
        type: BusinessErrorType.dbError,
        data: {'table': tableName},
      );
    }
    final spec = _resolveIndexSpecForCursor(schema, idxName);
    if (spec.fields.isEmpty) {
      throw BusinessError(
        'Cannot build next cursor: index has no fields.',
        type: BusinessErrorType.dbError,
        data: {'table': tableName, 'index': idxName},
      );
    }

    final bool truncateText = !spec.isUnique;
    final comps = <Uint8List>[];
    for (final f in spec.fields) {
      final v = lastRecord[f] ?? lastRecord['$tableName.$f'];
      final c = schema.encodeFieldComponentToMemComparable(
        f,
        v,
        truncateText: truncateText,
      );
      if (c == null) {
        throw BusinessError(
          'Cannot build next cursor: missing or unsupported index field value in the last record.',
          type: BusinessErrorType.dbError,
          data: {'table': tableName, 'index': idxName, 'field': f},
        );
      }
      comps.add(c);
    }
    if (!spec.isUnique) {
      final pkName = schema.primaryKey;
      final pkVal =
          (lastRecord[pkName] ?? lastRecord['$tableName.$pkName'])?.toString();
      if (pkVal == null) {
        throw BusinessError(
          'Cannot build next cursor: primary key is missing for non-unique index cursor.',
          type: BusinessErrorType.dbError,
          data: {'table': tableName, 'index': idxName},
        );
      }
      comps.add(schema.encodePrimaryKeyComponent(pkVal));
    }

    return _QueryCursorToken.indexKey(
      tableName: tableName,
      indexName: idxName,
      indexKey: MemComparableKey.encodeTuple(comps),
      isBackward: isBackward,
    ).encode();
  }

  int _getTableQueryGeneration(String tableName) {
    return _tableQueryGenerations[tableName] ?? 0;
  }

  List<Object> _buildQueryCacheKey(QueryCacheKey key) {
    final gen = _getTableQueryGeneration(key.tableName);
    // Use hierarchical key [tableName, gen, queryStr] for efficient table-wide purging.
    return [key.tableName, gen, key.toString()];
  }

  /// Invalidate query cache for a table (best-effort, O(1)).
  void invalidateQueryCacheForTable(String tableName) {
    final cur = _tableQueryGenerations[tableName] ?? 0;
    // Keep it positive and bounded.
    _tableQueryGenerations[tableName] = (cur + 1) & 0x7fffffff;
    // Explicitly purge all query cache entries for this table using hierarchical prefix.
    _queryCache.remove([tableName]);
  }

  /// Clear a specific cached query entry for the current generation.
  bool clearQueryCacheForKey(QueryCacheKey key) {
    _queryCache.remove(_buildQueryCacheKey(key));
    return true;
  }

  /// Clear all cached query entries.
  Future<void> clearAllQueryCache() async {
    _queryCache.clear();
    _tableQueryGenerations.clear();
  }

  /// Clear all cached query entries synchronously (used on shutdown).
  void clearAllQueryCacheSync() {
    _queryCache.clear();
    _tableQueryGenerations.clear();
  }

  /// Evict a ratio of cached query entries under memory pressure.
  Future<void> evictQueryCache({double ratio = 0.3}) async {
    await _queryCache.cleanup(removeRatio: ratio);
  }

  /// Get current query cache size in bytes.
  int getCurrentQueryCacheSizeBytes() => _queryCache.estimatedTotalSizeBytes;

  bool _shouldCacheQueryResults(
    List<Map<String, dynamic>> results, {
    required int maxBytes,
  }) {
    if (results.isEmpty) return false;
    if (maxBytes <= 0) return false;

    // Avoid caching extremely large result sets (usually scans).
    if (results.length > 5000) return false;

    // If cache is already highly utilized, avoid churn.
    if (_queryCache.estimatedTotalSizeBytes > (maxBytes * 0.9).toInt()) {
      return false;
    }

    // A single query result should not occupy more than 25% of total query cache.
    final estimated = _estimateQueryResultSizeBytes(results);
    final singleThreshold = (maxBytes * 0.25).toInt();
    if (estimated >= singleThreshold) return false;

    return true;
  }

  List<Map<String, dynamic>> _copyResultList(
      List<Map<String, dynamic>> results) {
    if (results.isEmpty) return const <Map<String, dynamic>>[];
    return List<Map<String, dynamic>>.generate(
      results.length,
      (i) => Map<String, dynamic>.from(results[i]),
      growable: true,
    );
  }

  int _estimateQueryResultSizeBytes(List<Map<String, dynamic>> records) {
    if (records.isEmpty) return 0;
    const int sample = 6;
    final int take = min(sample, records.length);
    int sum = 0;
    for (int i = 0; i < take; i++) {
      sum += _estimateRecordSizeBytes(records[i]);
    }
    final int avg = (sum / take).ceil();
    return avg * records.length;
  }

  int _estimateRecordSizeBytes(Map<String, dynamic> record) {
    int size = 64; // base overhead
    if (record.isEmpty) return size;

    const int maxFieldsSample = 24;
    int sampled = 0;
    for (final e in record.entries) {
      size += 16;
      size += e.key.length * 2;
      size += _estimateDynamicSizeBytes(e.value, depth: 0);
      sampled++;
      if (sampled >= maxFieldsSample) break;
    }

    if (record.length > sampled && sampled > 0) {
      final int per = ((size - 64) / sampled).ceil().clamp(0, 1024 * 1024);
      size = 64 + per * record.length;
    }
    return size;
  }

  int _estimateDynamicSizeBytes(dynamic v, {required int depth}) {
    if (v == null) return 0;
    if (v is bool) return 1;
    if (v is int) return 8;
    if (v is double) return 8;
    if (v is num) return 16;
    if (v is DateTime) return 16;
    if (v is Uint8List) return v.length;
    if (v is String) return v.length * 2;

    // Bound recursion depth.
    if (depth >= 2) return 32;

    if (v is List) {
      const int sample = 6;
      int size = 24;
      final int n = v.length;
      final int take = n < sample ? n : sample;
      for (int i = 0; i < take; i++) {
        size += _estimateDynamicSizeBytes(v[i], depth: depth + 1);
      }
      if (n > take && take > 0) {
        final int per = ((size - 24) / take).ceil().clamp(0, 1024 * 1024);
        size = 24 + per * n;
      }
      return size;
    }

    if (v is Map) {
      const int sample = 6;
      int size = 48;
      int taken = 0;
      for (final e in v.entries) {
        size += 16;
        final k = e.key;
        if (k is String) {
          size += k.length * 2;
        } else {
          size += 16;
        }
        size += _estimateDynamicSizeBytes(e.value, depth: depth + 1);
        taken++;
        if (taken >= sample) break;
      }
      if (v.length > taken && taken > 0) {
        final int per = ((size - 48) / taken).ceil().clamp(0, 1024 * 1024);
        size = 48 + per * v.length;
      }
      return size;
    }

    return 64;
  }
}

final class _QueryCacheEntry {
  final List<Map<String, dynamic>> results;
  final DateTime createdAt;
  final Duration? expiry;
  final int sizeBytes;

  _QueryCacheEntry({
    required this.results,
    required this.createdAt,
    required this.expiry,
    required this.sizeBytes,
  });

  bool isExpired() {
    final e = expiry;
    if (e == null) return false;
    return DateTime.now().difference(createdAt) >= e;
  }
}

class TableScanResult {
  final List<Map<String, dynamic>> records;

  TableScanResult({
    required this.records,
  });
}

class PlanExecutionResult {
  final List<Map<String, dynamic>> records;
  PlanExecutionResult(this.records);
}

class ExecuteResult {
  final List<Map<String, dynamic>> records;
  final String? nextCursor;
  final String? prevCursor;
  final bool hasMore;
  final bool hasPrev;

  final int? executionTimeMs;
  final int? tableTotalCount;

  const ExecuteResult({
    required this.records,
    this.nextCursor,
    this.prevCursor,
    this.hasMore = false,
    this.hasPrev = false,
    this.executionTimeMs,
    this.tableTotalCount,
  });

  const ExecuteResult.empty()
      : records = const [],
        nextCursor = null,
        prevCursor = null,
        hasMore = false,
        hasPrev = false,
        executionTimeMs = null,
        tableTotalCount = null;
}

enum _CursorMode {
  primaryKey,
  indexKey,
  sortKey,
}

final class _QueryCursorToken {
  static const int _currentVersion = 1;

  final int version;
  final _CursorMode mode;
  final String tableName;

  // primaryKey mode
  final String? primaryKey;
  final bool reverse;

  // indexKey mode
  final String? indexName;
  final Uint8List? indexKey;

  // sortKey mode (orderBy fields + primary key tie-breaker)
  final List<String>? sortFields;
  final List<bool>? sortDesc;
  final Uint8List? sortKey;

  // pagination direction
  final bool isBackward;

  const _QueryCursorToken._({
    required this.version,
    required this.mode,
    required this.tableName,
    required this.primaryKey,
    required this.reverse,
    required this.indexName,
    required this.indexKey,
    required this.sortFields,
    required this.sortDesc,
    required this.sortKey,
    this.isBackward = false,
  });

  factory _QueryCursorToken.primaryKey({
    required String tableName,
    required String primaryKey,
    required bool reverse,
    bool isBackward = false,
  }) {
    return _QueryCursorToken._(
      version: _currentVersion,
      mode: _CursorMode.primaryKey,
      tableName: tableName,
      primaryKey: primaryKey,
      reverse: reverse,
      indexName: null,
      indexKey: null,
      sortFields: null,
      sortDesc: null,
      sortKey: null,
      isBackward: isBackward,
    );
  }

  factory _QueryCursorToken.indexKey({
    required String tableName,
    required String indexName,
    required Uint8List indexKey,
    bool isBackward = false,
  }) {
    return _QueryCursorToken._(
      version: _currentVersion,
      mode: _CursorMode.indexKey,
      tableName: tableName,
      primaryKey: null,
      reverse: false,
      indexName: indexName,
      indexKey: indexKey,
      sortFields: null,
      sortDesc: null,
      sortKey: null,
      isBackward: isBackward,
    );
  }

  factory _QueryCursorToken.sortKey({
    required String tableName,
    required List<String> sortFields,
    required List<bool> sortDesc,
    required Uint8List sortKey,
    bool isBackward = false,
  }) {
    return _QueryCursorToken._(
      version: _currentVersion,
      mode: _CursorMode.sortKey,
      tableName: tableName,
      primaryKey: null,
      reverse: false,
      indexName: null,
      indexKey: null,
      sortFields: List<String>.from(sortFields, growable: false),
      sortDesc: List<bool>.from(sortDesc, growable: false),
      sortKey: sortKey,
      isBackward: isBackward,
    );
  }

  String encode() {
    final Map<String, dynamic> payload = <String, dynamic>{
      'v': version,
      't': tableName,
      'm': mode == _CursorMode.primaryKey
          ? 'pk'
          : (mode == _CursorMode.indexKey ? 'idx' : 'sk'),
      'b': isBackward,
    };

    if (mode == _CursorMode.primaryKey) {
      payload['pk'] = primaryKey;
      payload['r'] = reverse;
    } else if (mode == _CursorMode.indexKey) {
      payload['i'] = indexName;
      payload['k'] = base64Url.encode(indexKey ?? Uint8List(0));
    } else {
      payload['f'] = sortFields ?? const <String>[];
      payload['d'] = sortDesc ?? const <bool>[];
      payload['k'] = base64Url.encode(sortKey ?? Uint8List(0));
    }

    final jsonStr = jsonEncode(payload);
    return base64Url.encode(utf8.encode(jsonStr));
  }

  static _QueryCursorToken? tryDecode(String? token) {
    final raw = (token ?? '').trim();
    if (raw.isEmpty) return null;
    try {
      final decoded = utf8.decode(base64Url.decode(base64Url.normalize(raw)));
      final obj = jsonDecode(decoded);
      if (obj is! Map) {
        throw BusinessError(
          'Invalid cursor token payload.',
          type: BusinessErrorType.dbError,
        );
      }
      final int v = (obj['v'] is int) ? (obj['v'] as int) : -1;
      if (v != _currentVersion) {
        throw BusinessError(
          'Unsupported cursor token version.',
          type: BusinessErrorType.dbError,
          data: {'version': v},
        );
      }
      final String t = (obj['t'] ?? '').toString();
      final String m = (obj['m'] ?? '').toString();
      if (t.isEmpty || m.isEmpty) {
        throw BusinessError(
          'Invalid cursor token.',
          type: BusinessErrorType.dbError,
        );
      }

      if (m == 'pk') {
        final pk = (obj['pk'] ?? '').toString();
        if (pk.isEmpty) {
          throw BusinessError(
            'Invalid primary-key cursor token.',
            type: BusinessErrorType.dbError,
          );
        }
        final bool reverse = obj['r'] == true;
        final bool isBackward = obj['b'] == true;
        return _QueryCursorToken.primaryKey(
          tableName: t,
          primaryKey: pk,
          reverse: reverse,
          isBackward: isBackward,
        );
      }

      if (m == 'idx') {
        final idx = (obj['i'] ?? '').toString();
        final k = (obj['k'] ?? '').toString();
        if (idx.isEmpty || k.isEmpty) {
          throw BusinessError(
            'Invalid index-key cursor token.',
            type: BusinessErrorType.dbError,
          );
        }
        final keyBytes =
            Uint8List.fromList(base64Url.decode(base64Url.normalize(k)));
        if (keyBytes.isEmpty) {
          throw BusinessError(
            'Invalid index-key cursor token (empty key).',
            type: BusinessErrorType.dbError,
          );
        }
        final bool isBackward = obj['b'] == true;
        return _QueryCursorToken.indexKey(
          tableName: t,
          indexName: idx,
          indexKey: keyBytes,
          isBackward: isBackward,
        );
      }

      if (m == 'sk') {
        final f = obj['f'];
        final d = obj['d'];
        final k = (obj['k'] ?? '').toString();
        if (f is! List || d is! List || k.isEmpty) {
          throw BusinessError(
            'Invalid sort-key cursor token.',
            type: BusinessErrorType.dbError,
          );
        }
        final fields =
            f.map((e) => e.toString()).where((e) => e.isNotEmpty).toList();
        if (fields.isEmpty) {
          throw BusinessError(
            'Invalid sort-key cursor token (empty fields).',
            type: BusinessErrorType.dbError,
          );
        }
        final desc = d.map((e) => e == true).toList(growable: false);
        if (desc.length != fields.length) {
          throw BusinessError(
            'Invalid sort-key cursor token (direction length mismatch).',
            type: BusinessErrorType.dbError,
            data: {'fields': fields.length, 'desc': desc.length},
          );
        }
        final keyBytes =
            Uint8List.fromList(base64Url.decode(base64Url.normalize(k)));
        if (keyBytes.isEmpty) {
          throw BusinessError(
            'Invalid sort-key cursor token (empty key).',
            type: BusinessErrorType.dbError,
          );
        }
        final bool isBackward = obj['b'] == true;
        return _QueryCursorToken.sortKey(
          tableName: t,
          sortFields: fields,
          sortDesc: desc,
          sortKey: keyBytes,
          isBackward: isBackward,
        );
      }

      throw BusinessError(
        'Unknown cursor token mode.',
        type: BusinessErrorType.dbError,
        data: {'mode': m},
      );
    } catch (e) {
      if (e is BusinessError) rethrow;
      throw BusinessError(
        'Failed to decode cursor token.',
        type: BusinessErrorType.dbError,
        data: {'error': e.toString()},
      );
    }
  }
}
