import '../core/data_store_impl.dart';
import '../core/yield_controller.dart';
import '../interface/future_builder_mixin.dart';
import '../model/query_result.dart';
import '../model/result_type.dart';
import '../model/system_table.dart';
import '../model/table_context.dart';
import '../query/query_condition.dart';
import '../query/query_executor.dart';

/// Chain builder for querying user-facing key-value records.
///
/// Unlike [KvStore.getKeys] (key-name enumeration only), this returns decoded
/// KV records with the same [QueryResult] pagination as [QueryBuilder] /
/// `db.query()`: prefer [QueryResult.next] / [QueryResult.prev].
///
/// Example:
/// ```dart
/// final page = await db.kv.query()
///     .prefix('demo_')
///     .orderByUpdatedAtDesc()
///     .limit(20);
/// if (page.hasMore) {
///   final page2 = await page.next();
/// }
/// ```
class KvQueryBuilder
    with FutureBuilderMixin<QueryResult<Map<String, dynamic>>> {
  final DataStoreImpl _db;
  final bool _isGlobal;

  String? _prefix;
  List<String>? _orderBy;
  int? _limit;
  int? _offset;
  String? _cursor;
  bool _includeExpired = false;

  Future<QueryResult<Map<String, dynamic>>>? _future;

  /// Max engine pages to skip when post-filtering removes an entire page of
  /// expired rows (avoids returning an empty page while hasMore is true).
  static const int _maxEmptyPageSkips = 32;

  KvQueryBuilder(this._db, {required bool isGlobal}) : _isGlobal = isGlobal;

  void _invalidate() {
    _future = null;
  }

  /// Filter keys that start with [prefix].
  KvQueryBuilder prefix(String prefix) {
    _prefix = prefix;
    _invalidate();
    return this;
  }

  /// Order by key ascending (primary key order).
  KvQueryBuilder orderByKeyAsc() {
    _orderBy = [SystemTable.keyValueKeyField];
    _invalidate();
    return this;
  }

  /// Order by key descending.
  KvQueryBuilder orderByKeyDesc() {
    _orderBy = ['-${SystemTable.keyValueKeyField}'];
    _invalidate();
    return this;
  }

  /// Order by [updated_at] ascending.
  KvQueryBuilder orderByUpdatedAtAsc() {
    _orderBy = [SystemTable.keyValueUpdatedAtField];
    _invalidate();
    return this;
  }

  /// Order by [updated_at] descending.
  KvQueryBuilder orderByUpdatedAtDesc() {
    _orderBy = ['-${SystemTable.keyValueUpdatedAtField}'];
    _invalidate();
    return this;
  }

  /// Max records to return for this page.
  KvQueryBuilder limit(int value) {
    _limit = value;
    _invalidate();
    return this;
  }

  /// Offset pagination (clears cursor). Mutually exclusive with [cursor].
  KvQueryBuilder offset(int value) {
    _offset = value;
    _cursor = null;
    _invalidate();
    return this;
  }

  /// Cursor seek using a token from [QueryResult.nextCursorToken] /
  /// [QueryResult.prevCursorToken].
  ///
  /// Prefer [QueryResult.next] / [QueryResult.prev] for in-process paging.
  /// Use this when transferring pagination state across processes or network.
  /// Clears offset when a non-empty token is set.
  KvQueryBuilder cursor(String? value) {
    _cursor = value;
    if (value != null && value.isNotEmpty) {
      _offset = null;
    }
    _invalidate();
    return this;
  }

  /// When true, include expired-but-not-yet-cleaned records.
  ///
  /// Default false: expired rows are dropped after the engine page is fetched
  /// (not in SQL where -- wall-clock predicates break cursor signatures and OR
  /// plans disable cursor mode). A page may therefore contain fewer than
  /// [limit] records when some keys in the window are expired.
  KvQueryBuilder includeExpired([bool value = true]) {
    _includeExpired = value;
    _invalidate();
    return this;
  }

  KvQueryBuilder _clone() {
    final cloned = KvQueryBuilder(_db, isGlobal: _isGlobal);
    cloned._prefix = _prefix;
    cloned._orderBy = _orderBy == null ? null : List<String>.from(_orderBy!);
    cloned._limit = _limit;
    cloned._offset = _offset;
    cloned._cursor = _cursor;
    cloned._includeExpired = _includeExpired;
    return cloned;
  }

  QueryCondition _buildCondition() {
    final condition = QueryCondition();
    if (_prefix != null && _prefix!.isNotEmpty) {
      condition.whereStartsWith(SystemTable.keyValueKeyField, _prefix!);
    }
    return condition;
  }

  /// Record count matching the current filters (not limited by page size).
  ///
  /// Without a [prefix], uses table metadata (O(1); may briefly include
  /// expired keys not yet cleaned). With a prefix, runs a filtered count.
  Future<int> count() async {
    if (!_db.isInitialized) {
      await _db.ensureInitialized();
    }
    final tableName = SystemTable.getKeyValueName(_isGlobal);
    final table = await _db.getTableContext(tableName);

    final hasPrefix = _prefix != null && _prefix!.isNotEmpty;
    if (!hasPrefix) {
      return await _db.tableDataManager.getTableRecordCount(table);
    }

    final result = await _db.queryExecutor.execute(
      table,
      condition: _buildCondition(),
      onlyCount: true,
    );
    return result.count ?? result.records.length;
  }

  /// First matching non-expired record, or null.
  ///
  /// Does not permanently change this builder's [limit].
  Future<Map<String, dynamic>?> first() async {
    final result = await _clone().limit(1);
    return result.data.isEmpty ? null : result.data.first;
  }

  /// Synchronously retrieve query results from pure memory cache.
  ///
  /// Never hits disk/files; returns empty result if memory caches miss.
  /// Expired rows are filtered out (same semantics as [future]).
  QueryResult<Map<String, dynamic>> peek() {
    final result = _executePeekSync();

    return QueryResult.success(
      data: result.records,
      prevCursor: result.prevCursor,
      nextCursor: result.nextCursor,
      hasMore: result.hasMore,
      hasPrev: result.hasPrev,
      executionTimeMs: result.executionTimeMs,
      nextPageExecutor: result.hasMore
          ? () async {
              final cloned = _clone();
              if (result.nextCursor != null) {
                cloned.cursor(result.nextCursor);
              } else {
                final effectiveLimit = _limit ?? _db.config.defaultQueryLimit;
                final currentOffset = _offset ?? 0;
                cloned.offset(currentOffset + effectiveLimit);
              }
              return cloned.future;
            }
          : null,
      prevPageExecutor: result.hasPrev
          ? () async {
              final cloned = _clone();
              if (result.prevCursor != null) {
                cloned.cursor(result.prevCursor);
              } else {
                final effectiveLimit = _limit ?? _db.config.defaultQueryLimit;
                final currentOffset = _offset ?? 0;
                final newOffset = currentOffset - effectiveLimit;
                cloned.offset(newOffset >= 0 ? newOffset : 0);
              }
              return cloned.future;
            }
          : null,
      peekNextPageExecutor: result.hasMore
          ? () {
              final cloned = _clone();
              if (result.nextCursor != null) {
                cloned.cursor(result.nextCursor);
              } else {
                final effectiveLimit = _limit ?? _db.config.defaultQueryLimit;
                final currentOffset = _offset ?? 0;
                cloned.offset(currentOffset + effectiveLimit);
              }
              return cloned.peek();
            }
          : null,
      peekPrevPageExecutor: result.hasPrev
          ? () {
              final cloned = _clone();
              if (result.prevCursor != null) {
                cloned.cursor(result.prevCursor);
              } else {
                final effectiveLimit = _limit ?? _db.config.defaultQueryLimit;
                final currentOffset = _offset ?? 0;
                final newOffset = currentOffset - effectiveLimit;
                cloned.offset(newOffset >= 0 ? newOffset : 0);
              }
              return cloned.peek();
            }
          : null,
    );
  }

  /// Synchronously retrieve the first matching non-expired record from memory.
  ///
  /// Returns null if not found in memory cache.
  Map<String, dynamic>? peekFirst() {
    final result = _clone().limit(1).peek();
    return result.data.isEmpty ? null : result.data.first;
  }

  @override
  Future<QueryResult<Map<String, dynamic>>> get future {
    return _future ??= _execute();
  }

  List<Map<String, dynamic>> _mapPageSync(
    TableContext table,
    List<Map<String, dynamic>> records,
    DateTime now,
  ) {
    final data = <Map<String, dynamic>>[];
    for (final row in records) {
      if (!_includeExpired && _db.isKvRecordExpired(row, now: now)) {
        _db.scheduleExpiredKvCleanup(table, row);
      } else {
        data.add(_db.mapUserFacingKvRecord(row));
      }
    }
    return data;
  }

  ExecuteResult _executePeekSync() {
    if (_limit != null && _limit! <= 0) {
      return const ExecuteResult.empty();
    }
    if (_offset != null && _offset! < 0) {
      return const ExecuteResult.empty();
    }

    final tableName = SystemTable.getKeyValueName(_isGlobal);
    final table = _db.getTableContextSync(tableName);
    if (table == null) {
      return const ExecuteResult.empty();
    }

    final condition = _buildCondition();
    final orderBy = _orderBy ?? [SystemTable.keyValueKeyField];
    final now = DateTime.now();

    var activeCursor = _cursor;
    var activeOffset = _offset;
    var skips = 0;

    while (true) {
      final exec = _db.queryExecutor.executePeek(
        table,
        condition: condition,
        orderBy: orderBy,
        limit: _limit,
        offset: activeOffset,
        cursor: activeCursor,
      );
      final data = _mapPageSync(table, exec.records, now);

      if (data.isEmpty &&
          !_includeExpired &&
          exec.hasMore &&
          exec.nextCursor != null &&
          skips < _maxEmptyPageSkips) {
        skips++;
        activeCursor = exec.nextCursor;
        activeOffset = null;
        continue;
      }

      return ExecuteResult(
        records: data,
        nextCursor: exec.nextCursor,
        prevCursor: exec.prevCursor,
        hasMore: exec.hasMore,
        hasPrev: exec.hasPrev,
        executionTimeMs: exec.executionTimeMs,
      );
    }
  }

  Future<List<Map<String, dynamic>>> _mapPage(
    TableContext table,
    List<Map<String, dynamic>> records,
    DateTime now,
    YieldController yieldController,
  ) async {
    final data = <Map<String, dynamic>>[];
    for (final row in records) {
      if (!_includeExpired && _db.isKvRecordExpired(row, now: now)) {
        _db.scheduleExpiredKvCleanup(table, row);
      } else {
        data.add(_db.mapUserFacingKvRecord(row));
      }
      // Large limit / heavy JSON values: yield so UI stays responsive.
      final y = yieldController.maybeYield();
      if (y != null) await y;
    }
    return data;
  }

  Future<QueryResult<Map<String, dynamic>>> _execute() async {
    try {
      if (_limit != null && _limit! <= 0) {
        return QueryResult.error(
          type: ResultType.devInvalidArgumentFormat,
          message: 'limit must be greater than zero',
        );
      }
      if (_offset != null && _offset! < 0) {
        return QueryResult.error(
          type: ResultType.devInvalidArgumentFormat,
          message: 'offset must be >= 0',
        );
      }

      if (!_db.isInitialized) {
        await _db.ensureInitialized();
      }
      final tableName = SystemTable.getKeyValueName(_isGlobal);
      final table = await _db.getTableContext(tableName);
      final condition = _buildCondition();
      final orderBy = _orderBy ?? [SystemTable.keyValueKeyField];
      final now = DateTime.now();
      final yieldController = YieldController('KvQueryBuilder._execute');

      var activeCursor = _cursor;
      var activeOffset = _offset;
      late ExecuteResult exec;
      var data = <Map<String, dynamic>>[];
      var skips = 0;
      var totalExecMs = 0;

      while (true) {
        exec = await _db.queryExecutor.execute(
          table,
          condition: condition,
          orderBy: orderBy,
          limit: _limit,
          offset: activeOffset,
          cursor: activeCursor,
        );
        totalExecMs += exec.executionTimeMs ?? 0;
        data = await _mapPage(table, exec.records, now, yieldController);

        // Skip wholly-expired engine pages so callers do not see an empty
        // page with a still-valid next cursor.
        if (data.isEmpty &&
            !_includeExpired &&
            exec.hasMore &&
            exec.nextCursor != null &&
            skips < _maxEmptyPageSkips) {
          skips++;
          activeCursor = exec.nextCursor;
          activeOffset = null;
          final y = yieldController.maybeYield();
          if (y != null) await y;
          continue;
        }
        break;
      }

      Future<QueryResult<Map<String, dynamic>>> nextPageExecutor() async {
        final cloned = _clone();
        if (exec.nextCursor != null) {
          cloned.cursor(exec.nextCursor);
        } else {
          final effectiveLimit = _limit ?? _db.config.defaultQueryLimit;
          final currentOffset = _offset ?? 0;
          cloned.offset(currentOffset + effectiveLimit);
        }
        return cloned.future;
      }

      Future<QueryResult<Map<String, dynamic>>> prevPageExecutor() async {
        final cloned = _clone();
        if (exec.prevCursor != null) {
          cloned.cursor(exec.prevCursor);
        } else {
          final effectiveLimit = _limit ?? _db.config.defaultQueryLimit;
          final currentOffset = _offset ?? 0;
          final newOffset = currentOffset - effectiveLimit;
          cloned.offset(newOffset >= 0 ? newOffset : 0);
        }
        return cloned.future;
      }

      return QueryResult.success(
        data: data,
        prevCursor: exec.prevCursor,
        nextCursor: exec.nextCursor,
        hasMore: exec.hasMore,
        hasPrev: exec.hasPrev,
        executionTimeMs: totalExecMs,
        nextPageExecutor: exec.hasMore ? nextPageExecutor : null,
        prevPageExecutor: exec.hasPrev ? prevPageExecutor : null,
      );
    } catch (e) {
      return QueryResult.error(
        type: ResultType.engError,
        message: e.toString(),
      );
    }
  }
}
