import 'dart:math';

import '../handler/logger.dart';
import '../core/data_store_impl.dart';
import '../model/table_schema.dart';
import 'query_plan.dart';

/// query optimizer
class QueryOptimizer {
  final DataStoreImpl _dataStore;
  static const int _maxDnfClauses = 64;

  QueryOptimizer(
    this._dataStore,
  );

  /// optimize query plan
  Future<QueryPlan> optimize(
    String tableName,
    Map<String, dynamic>? where, {
    List<String>? orderBy,
    int? limit,
    int? offset,
  }) async {
    try {
      // get table schema
      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);

      if (where == null || where.isEmpty) {
        if (schema != null && orderBy != null && orderBy.isNotEmpty) {
          // If no where, check if orderBy can benefit from an index.
          final bestSortingIndex = _findSortingIndex(schema, orderBy);
          if (bestSortingIndex != null) {
            return QueryPlan(
              QueryOperation(
                type: QueryOperationType.indexScan,
                indexName: bestSortingIndex.actualIndexName,
                value: <String, dynamic>{'table': tableName, 'where': null},
              ),
              naturalOrderBy: bestSortingIndex.fields,
            );
          }
        }
        return _createTableScanPlan(tableName, primaryKey: schema?.primaryKey);
      }

      if (schema == null) {
        return _createTableScanPlan(tableName);
      }

      // Reduce the where-clause to conditions relevant to this table only,
      // while preserving AND/OR structure for nested boolean optimization.
      final tableTree =
          _simplifyLogicalTree(_extractTableConditionTree(tableName, where));
      if (tableTree.isEmpty) {
        return _createTableScanPlan(tableName, primaryKey: schema.primaryKey);
      }

      // No OR => keep the fast AND-only optimizer.
      if (!_containsOr(tableTree)) {
        final filterPlan = await _optimizeAndOnly(tableName, tableTree, schema);

        // Cost-based choice between:
        // - Filter-first plan (most selective access path)
        // - Order-by index scan (scan in requested order and stop at limit)
        //
        // This is critical for correctness + performance:
        // if scan order != requested orderBy, the executor must NOT stop after `limit`
        // candidates (it must scan the whole range and do bounded topK). Therefore,
        // when an order-by index exists, scanning it can often be dramatically cheaper.
        if (orderBy == null || orderBy.isEmpty) return filterPlan;

        final sortingIdx = _findSortingIndex(schema, orderBy);
        if (sortingIdx == null) return filterPlan;

        // If already using the same index, keep the filter plan.
        if (filterPlan.operation.type == QueryOperationType.indexScan &&
            filterPlan.operation.indexName == sortingIdx.actualIndexName) {
          return filterPlan;
        }

        final tableWhere = _extractWhereMap(filterPlan);

        // Effective pagination need (offset+limit) used for cost estimation.
        final int effOffset = (offset == null || offset <= 0) ? 0 : offset;
        final int effLimit = (limit == null || limit <= 0)
            ? _dataStore.config.defaultQueryLimit
            : limit;
        final int need = max(1, effOffset + max(1, effLimit));

        final int totalRows = await _estimateTotalRows(tableName);
        final fieldSel = _estimateFieldSelectivity(
          schema: schema,
          where: tableWhere,
          totalRows: totalRows,
        );
        final double overallSel = _combineSelectivity(fieldSel, totalRows);

        final sortPlan = QueryPlan(
          QueryOperation(
            type: QueryOperationType.indexScan,
            indexName: sortingIdx.actualIndexName,
            value: <String, dynamic>{'table': tableName, 'where': tableWhere},
          ),
          naturalOrderBy: sortingIdx.fields,
        );

        final double filterCost = _estimatePlanCost(
          tableName: tableName,
          plan: filterPlan,
          schema: schema,
          orderBy: orderBy,
          need: need,
          totalRows: totalRows,
          overallSelectivity: overallSel,
          fieldSelectivity: fieldSel,
        );

        final double sortCost = _estimatePlanCost(
          tableName: tableName,
          plan: sortPlan,
          schema: schema,
          orderBy: orderBy,
          need: need,
          totalRows: totalRows,
          overallSelectivity: overallSel,
          fieldSelectivity: fieldSel,
        );

        return (sortCost < filterCost) ? sortPlan : filterPlan;
      }

      // OR present: convert to DNF (OR of AND-only clauses), with a strict cap to
      // avoid exponential blow-ups on deeply nested boolean expressions.
      final dnfClauses = _toDnfClauses(tableTree, maxClauses: _maxDnfClauses);
      if (dnfClauses == null || dnfClauses.isEmpty) {
        // Fallback: keep correctness with a table scan (executor will evaluate full predicate).
        return _createTableScanPlan(tableName,
            where: tableTree, primaryKey: schema.primaryKey);
      }
      if (dnfClauses.length == 1) {
        return await _optimizeAndOnly(tableName, dnfClauses.first, schema);
      }

      final children = <QueryPlan>[];
      for (final clause in dnfClauses) {
        if (clause.isEmpty) {
          // Clause is always-true => full scan.
          children.add(
              _createTableScanPlan(tableName, primaryKey: schema.primaryKey));
          continue;
        }
        children.add(await _optimizeAndOnly(tableName, clause, schema));
      }

      return QueryPlan(
        QueryOperation(
          type: QueryOperationType.union,
          value: <String, dynamic>{
            'table': tableName,
            'children': children,
          },
        ),
        naturalOrderBy: <String>[schema.primaryKey],
      );
    } catch (e) {
      Logger.error('query optimization failed: $e', label: 'QueryOptimizer');
      // use full table scan when error occurs
      return _createTableScanPlan(tableName);
    }
  }

  /// create table scan query plan (optionally carrying a table-local predicate)
  QueryPlan _createTableScanPlan(String tableName,
      {Map<String, dynamic>? where, String? primaryKey}) {
    return QueryPlan(
      QueryOperation(
        type: QueryOperationType.tableScan,
        value: <String, dynamic>{
          'table': tableName,
          'where': (where == null || where.isEmpty) ? null : where,
        },
      ),
      naturalOrderBy: (primaryKey == null || primaryKey.isEmpty)
          ? null
          : <String>[primaryKey],
    );
  }

  // ------------------------- AND-only optimizer (no OR) -------------------------

  Future<QueryPlan> _optimizeAndOnly(
    String tableName,
    Map<String, dynamic> where,
    TableSchema schema,
  ) async {
    // Extract conjunctive (AND-only) field conditions for this table.
    final tableWhere = <String, dynamic>{};
    void mergeFieldCond(String field, dynamic v) {
      if (!tableWhere.containsKey(field)) {
        tableWhere[field] = v;
        return;
      }
      final existing = tableWhere[field];
      // Merge operator maps for the same field when possible.
      if (existing is Map && v is Map) {
        final merged = <String, dynamic>{};
        for (final e in existing.entries) {
          merged[e.key.toString()] = e.value;
        }
        for (final e in v.entries) {
          merged[e.key.toString()] = e.value;
        }
        tableWhere[field] = merged;
        return;
      }
      // Prefer explicit operator map over scalar, otherwise last-write-wins.
      if (v is Map) {
        tableWhere[field] = v;
      }
    }

    void visit(Map<String, dynamic> node) {
      final andVal = node['AND'];
      if (andVal is List) {
        for (final c in andVal) {
          if (c is Map<String, dynamic>) visit(c);
        }
        return;
      }
      for (final e in node.entries) {
        final k = e.key;
        final v = e.value;
        if (k == 'AND' || k == 'OR') continue;
        // The tree passed in is already table-local and unprefixed.
        final field = k;
        if (field.isEmpty) continue;
        mergeFieldCond(field, v);
      }
    }

    visit(where);

    if (tableWhere.isEmpty) {
      return _createTableScanPlan(tableName, primaryKey: schema.primaryKey);
    }

    bool isPrefixLike(String pattern) {
      if (pattern.isEmpty) return false;
      // Must start with literal
      if (pattern.startsWith('%')) return false;
      if (pattern.startsWith('_')) return false;
      // We can optimize anything with a fixed prefix
      return true;
    }

    bool isEqualityOrIn(dynamic v) {
      if (v is Map) {
        if (v.containsKey('=')) return true;
        if (v.containsKey('IN')) return true;
        return false;
      }
      return v != null;
    }

    bool isEqualityOnly(dynamic v) {
      if (v is Map) {
        return v.containsKey('=');
      }
      return v != null;
    }

    bool isRangeOrPrefixLike(dynamic v) {
      if (v is! Map) return false;
      for (final k in v.keys) {
        final op = k.toString().toUpperCase();
        if (op == '>' ||
            op == '>=' ||
            op == '<' ||
            op == '<=' ||
            op == 'BETWEEN') {
          return true;
        }
        if (op == 'LIKE') {
          final pat = v[k];
          if (pat is String && isPrefixLike(pat)) return true;
        }
      }
      return false;
    }

    // Priority 1: Primary key '=' / IN (fastest and most selective).
    if (tableWhere.containsKey(schema.primaryKey) &&
        isEqualityOrIn(tableWhere[schema.primaryKey])) {
      return _createTableScanPlan(tableName,
          where: tableWhere, primaryKey: schema.primaryKey);
    }

    // Priority 2: Primary key range / prefix LIKE (range-partition scan on table data).
    if (tableWhere.containsKey(schema.primaryKey) &&
        isRangeOrPrefixLike(tableWhere[schema.primaryKey])) {
      return _createTableScanPlan(tableName,
          where: tableWhere, primaryKey: schema.primaryKey);
    }

    // Priority 3: Unique index '=' / IN (single-field) or full '=' tuple (composite).
    IndexSchema? bestUniqueEq;
    for (final idx in schema.getAllIndexes()) {
      if (!idx.unique) continue;
      bool ok = true;
      if (idx.fields.length == 1) {
        final f = idx.fields.first;
        ok = tableWhere.containsKey(f) && isEqualityOrIn(tableWhere[f]);
      } else {
        for (final f in idx.fields) {
          if (!tableWhere.containsKey(f) || !isEqualityOnly(tableWhere[f])) {
            ok = false;
            break;
          }
        }
      }
      if (!ok) continue;
      bestUniqueEq = idx;
      break;
    }
    if (bestUniqueEq != null) {
      return QueryPlan(
        QueryOperation(
          type: QueryOperationType.indexScan,
          indexName: bestUniqueEq.actualIndexName,
          value: <String, dynamic>{'table': tableName, 'where': tableWhere},
        ),
        naturalOrderBy: bestUniqueEq.fields,
      );
    }

    // Priority 4: Other indexes (equality/range/prefix).
    IndexSchema? bestIndex;
    int bestScore = 0;
    for (final idx in schema.getAllIndexes()) {
      int matched = 0;
      for (final f in idx.fields) {
        if (!tableWhere.containsKey(f)) break;
        final v = tableWhere[f];
        if (!isEqualityOrIn(v) && !isRangeOrPrefixLike(v)) break;
        matched++;
      }
      if (matched <= 0) continue;
      // Composite indexes must be fully matched until tuple-prefix encoding exists.
      if (idx.fields.length > 1 && matched != idx.fields.length) {
        continue;
      }
      final score = matched * 10 + (idx.unique ? 3 : 0);
      if (score > bestScore) {
        bestScore = score;
        bestIndex = idx;
      }
    }

    if (bestIndex != null) {
      return QueryPlan(
        QueryOperation(
          type: QueryOperationType.indexScan,
          indexName: bestIndex.actualIndexName,
          value: <String, dynamic>{'table': tableName, 'where': tableWhere},
        ),
        naturalOrderBy: bestIndex.fields,
      );
    }

    // Fallback: table scan with full predicate (non-indexable operators will be evaluated by the matcher).
    return _createTableScanPlan(tableName,
        where: tableWhere, primaryKey: schema.primaryKey);
  }

  // ------------------------- Boolean tree helpers -------------------------

  bool _containsOr(Map<String, dynamic> node) {
    if (node.containsKey('OR')) return true;
    final andVal = node['AND'];
    if (andVal is List) {
      for (final c in andVal) {
        if (c is Map<String, dynamic> && _containsOr(c)) return true;
      }
    }
    for (final e in node.entries) {
      final v = e.value;
      if (v is Map<String, dynamic>) {
        if (_containsOr(v)) return true;
      } else if (v is List) {
        for (final it in v) {
          if (it is Map<String, dynamic> && _containsOr(it)) return true;
        }
      }
    }
    return false;
  }

  Map<String, dynamic> _extractTableConditionTree(
      String tableName, Map<String, dynamic> node) {
    // Split node into logical children and leaf field predicates.
    final hasAnd = node.containsKey('AND') && node['AND'] is List;
    final hasOr = node.containsKey('OR') && node['OR'] is List;

    final leaf = <String, dynamic>{};
    for (final e in node.entries) {
      final k = e.key;
      if (k == 'AND' || k == 'OR') continue;
      final v = e.value;
      String field;
      if (k.contains('.')) {
        final parts = k.split('.');
        if (parts.length == 2 && parts.first == tableName) {
          field = parts.last;
        } else {
          continue;
        }
      } else {
        field = k;
      }
      if (field.isEmpty) continue;
      leaf[field] = v;
    }

    if (hasAnd) {
      final outChildren = <Map<String, dynamic>>[];
      final list = node['AND'] as List;
      for (final c in list) {
        if (c is Map<String, dynamic>) {
          final sub = _extractTableConditionTree(tableName, c);
          if (sub.isNotEmpty) outChildren.add(sub);
        }
      }
      if (leaf.isNotEmpty) outChildren.add(leaf);
      if (outChildren.isEmpty) return <String, dynamic>{};
      if (outChildren.length == 1) return outChildren.first;
      return <String, dynamic>{'AND': outChildren};
    }

    if (hasOr) {
      final outChildren = <Map<String, dynamic>>[];
      final list = node['OR'] as List;
      for (final c in list) {
        if (c is Map<String, dynamic>) {
          final sub = _extractTableConditionTree(tableName, c);
          if (sub.isNotEmpty) outChildren.add(sub);
        }
      }
      if (outChildren.isEmpty) {
        // OR with no effective children is false; keep leaf part only.
        return leaf;
      }
      if (leaf.isEmpty) {
        if (outChildren.length == 1) return outChildren.first;
        return <String, dynamic>{'OR': outChildren};
      }
      // Mixed node: treat as (OR children) AND (leaf)
      return <String, dynamic>{
        'AND': <Map<String, dynamic>>[
          if (outChildren.length == 1)
            outChildren.first
          else
            {'OR': outChildren},
          leaf,
        ]
      };
    }

    return leaf;
  }

  Map<String, dynamic> _simplifyLogicalTree(Map<String, dynamic> node) {
    if (node.isEmpty) return node;
    if (node.containsKey('AND') && node['AND'] is List) {
      final list = <Map<String, dynamic>>[];
      for (final c in (node['AND'] as List)) {
        if (c is! Map<String, dynamic>) continue;
        final sub = _simplifyLogicalTree(c);
        if (sub.isEmpty) continue;
        if (sub.containsKey('AND') && sub['AND'] is List) {
          for (final g in (sub['AND'] as List)) {
            if (g is Map<String, dynamic> && g.isNotEmpty) list.add(g);
          }
        } else {
          list.add(sub);
        }
      }
      if (list.isEmpty) return <String, dynamic>{};
      if (list.length == 1) return list.first;
      return <String, dynamic>{'AND': list};
    }
    if (node.containsKey('OR') && node['OR'] is List) {
      final list = <Map<String, dynamic>>[];
      for (final c in (node['OR'] as List)) {
        if (c is! Map<String, dynamic>) continue;
        final sub = _simplifyLogicalTree(c);
        if (sub.isEmpty) continue;
        if (sub.containsKey('OR') && sub['OR'] is List) {
          for (final g in (sub['OR'] as List)) {
            if (g is Map<String, dynamic> && g.isNotEmpty) list.add(g);
          }
        } else {
          list.add(sub);
        }
      }
      if (list.isEmpty) return <String, dynamic>{};
      if (list.length == 1) return list.first;
      return <String, dynamic>{'OR': list};
    }
    return node;
  }

  /// Convert an expression into DNF clauses (OR of AND-only clauses).
  ///
  /// Returns null when expansion exceeds [maxClauses].
  List<Map<String, dynamic>>? _toDnfClauses(
    Map<String, dynamic> node, {
    required int maxClauses,
  }) {
    List<List<Map<String, dynamic>>>? dnfList(
        Map<String, dynamic> expr, int cap) {
      if (expr.isEmpty) {
        // Empty map means TRUE for this table-local tree.
        return <List<Map<String, dynamic>>>[<Map<String, dynamic>>[]];
      }
      if (expr.containsKey('OR') && expr['OR'] is List) {
        final out = <List<Map<String, dynamic>>>[];
        for (final c in (expr['OR'] as List)) {
          if (c is! Map<String, dynamic>) continue;
          final sub = dnfList(c, cap);
          if (sub == null) return null;
          out.addAll(sub);
          if (out.length > cap) return null;
        }
        return out;
      }
      if (expr.containsKey('AND') && expr['AND'] is List) {
        List<List<Map<String, dynamic>>> out = <List<Map<String, dynamic>>>[
          <Map<String, dynamic>>[]
        ];
        for (final c in (expr['AND'] as List)) {
          if (c is! Map<String, dynamic>) continue;
          final sub = dnfList(c, cap);
          if (sub == null) return null;
          final next = <List<Map<String, dynamic>>>[];
          for (final a in out) {
            for (final b in sub) {
              final combined = <Map<String, dynamic>>[...a, ...b];
              next.add(combined);
              if (next.length > cap) return null;
            }
          }
          out = next;
          if (out.length > cap) return null;
        }
        return out;
      }
      // Leaf (implicit AND of its fields).
      return <List<Map<String, dynamic>>>[
        <Map<String, dynamic>>[expr]
      ];
    }

    final dnf = dnfList(node, maxClauses);
    if (dnf == null) return null;

    final clauses = <Map<String, dynamic>>[];
    for (final parts in dnf) {
      // Remove empty parts (TRUE).
      final nonEmpty = parts.where((m) => m.isNotEmpty).toList(growable: false);
      if (nonEmpty.isEmpty) {
        clauses.add(<String, dynamic>{});
      } else if (nonEmpty.length == 1) {
        clauses.add(_simplifyLogicalTree(nonEmpty.first));
      } else {
        clauses.add(_simplifyLogicalTree(<String, dynamic>{'AND': nonEmpty}));
      }
      if (clauses.length > maxClauses) return null;
    }
    return clauses;
  }

  Map<String, dynamic> _extractWhereMap(QueryPlan plan) {
    final v = plan.operation.value;
    if (v is Map<String, dynamic>) {
      final w = v['where'];
      if (w is Map<String, dynamic>) {
        return w;
      }
      if (w is Map) {
        return w.cast<String, dynamic>();
      }
    }
    return const <String, dynamic>{};
  }

  Future<int> _estimateTotalRows(String tableName) async {
    try {
      final n =
          await _dataStore.tableDataManager.getTableRecordCount(tableName);
      return max(1, n);
    } catch (_) {
      return 1;
    }
  }

  Map<String, double> _estimateFieldSelectivity({
    required TableSchema schema,
    required Map<String, dynamic> where,
    required int totalRows,
  }) {
    if (where.isEmpty) return const <String, double>{};

    // A conservative default for equality on non-unique fields.
    // We adapt to table size to model the "rare match" risk for large datasets.
    double nonUniqueEqSel() {
      final s = 1.0 / max(100.0, sqrt(totalRows.toDouble()));
      return s.clamp(1.0 / totalRows, 0.1);
    }

    bool isUniqueSingleField(String field) {
      if (field == schema.primaryKey) return true;
      for (final idx in schema.getAllIndexes()) {
        if (!idx.unique) continue;
        if (idx.fields.length == 1 && idx.fields.first == field) return true;
      }
      return false;
    }

    bool isPrefixLike(String pattern) {
      if (pattern.isEmpty) return false;
      if (!pattern.endsWith('%')) return false;
      if (pattern.startsWith('%')) return false;
      if (pattern.contains('_')) return false;
      return pattern.indexOf('%') == pattern.length - 1;
    }

    double eqSel(String field) {
      if (isUniqueSingleField(field)) {
        return 1.0 / totalRows;
      }
      return nonUniqueEqSel();
    }

    bool hasRangeOp(Map m) {
      for (final k in m.keys) {
        final op = k.toString().toUpperCase();
        if (op == '>' ||
            op == '>=' ||
            op == '<' ||
            op == '<=' ||
            op == 'BETWEEN') return true;
      }
      return false;
    }

    final out = <String, double>{};
    for (final e in where.entries) {
      final field = e.key;
      if (field == 'AND' || field == 'OR') continue;
      final cond = e.value;

      if (cond is Map) {
        // Equality / IN
        if (cond.containsKey('=') || cond.containsKey('=')) {
          out[field] = eqSel(field);
          continue;
        }
        if (cond.containsKey('IN')) {
          final v = cond['IN'];
          final int k = (v is List) ? v.length : 1;
          out[field] = min(1.0, k * eqSel(field));
          continue;
        }

        // Range / prefix LIKE
        if (hasRangeOp(cond)) {
          out[field] = 0.3;
          continue;
        }
        if (cond.containsKey('LIKE')) {
          final pat = cond['LIKE'];
          out[field] = (pat is String && isPrefixLike(pat)) ? 0.1 : 0.5;
          continue;
        }

        // Default for complex operators.
        out[field] = 0.5;
        continue;
      }

      // Scalar => implicit equality
      out[field] = eqSel(field);
    }

    return out;
  }

  double _combineSelectivity(Map<String, double> fieldSel, int totalRows) {
    if (fieldSel.isEmpty) return 1.0;
    double sel = 1.0;
    for (final v in fieldSel.values) {
      sel *= v.clamp(0.0, 1.0);
    }
    final double minSel = 1.0 / max(1, totalRows);
    return sel.clamp(minSel, 1.0);
  }

  List<String> _resolveIndexFields(TableSchema schema, String indexName) {
    try {
      final idx = schema
          .getAllIndexes()
          .firstWhere((i) => i.actualIndexName == indexName);
      return idx.fields;
    } catch (_) {
      if (indexName.startsWith('uniq_') && indexName.length > 5) {
        return <String>[indexName.substring(5)];
      }
      return const <String>[];
    }
  }

  double _estimateAccessRangeSelectivity({
    required QueryPlan plan,
    required TableSchema schema,
    required Map<String, double> fieldSelectivity,
  }) {
    final op = plan.operation;
    if (op.type == QueryOperationType.tableScan) {
      final pk = schema.primaryKey;
      return fieldSelectivity[pk] ?? 1.0;
    }
    if (op.type == QueryOperationType.indexScan) {
      final idxName = op.indexName;
      if (idxName == null || idxName.isEmpty) return 1.0;
      final fields = _resolveIndexFields(schema, idxName);
      if (fields.isEmpty) return 1.0;
      double sel = 1.0;
      for (final f in fields) {
        sel *= (fieldSelectivity[f] ?? 1.0);
      }
      return sel.clamp(0.0, 1.0);
    }
    return 1.0;
  }

  bool _canStreamInRequestedOrder({
    required String tableName,
    required QueryPlan plan,
    required TableSchema schema,
    required List<String> orderBy,
  }) {
    if (orderBy.isEmpty) return true;

    // Derive the natural order for this plan.
    final natural = plan.naturalOrderBy.isNotEmpty
        ? plan.naturalOrderBy
        : <String>[schema.primaryKey];

    if (orderBy.length > natural.length) return false;

    bool? firstIsDesc;
    for (int i = 0; i < orderBy.length; i++) {
      String f = orderBy[i].trim();
      bool isDesc = false;
      if (f.startsWith('-')) {
        isDesc = true;
        f = f.substring(1).trim();
      } else if (f.toUpperCase().endsWith(' DESC')) {
        isDesc = true;
        f = f.substring(0, f.length - 5).trim();
      } else if (f.toUpperCase().endsWith(' ASC')) {
        isDesc = false;
        f = f.substring(0, f.length - 4).trim();
      }

      // Normalize possible table prefix.
      if (f.contains('.')) {
        final parts = f.split('.');
        if (parts.length == 2 && parts.first == tableName) {
          f = parts.last;
        } else {
          f = parts.last;
        }
      }

      if (f != natural[i]) return false;
      if (i == 0) {
        firstIsDesc = isDesc;
      } else if (firstIsDesc != isDesc) {
        // Mixed directions cannot be streamed by a single scan direction.
        return false;
      }
    }
    return true;
  }

  double _estimatePlanCost({
    required String tableName,
    required QueryPlan plan,
    required TableSchema schema,
    required List<String> orderBy,
    required int need,
    required int totalRows,
    required double overallSelectivity,
    required Map<String, double> fieldSelectivity,
  }) {
    // Range (scan) size determined by access path key fields.
    final rangeSel = _estimateAccessRangeSelectivity(
      plan: plan,
      schema: schema,
      fieldSelectivity: fieldSelectivity,
    ).clamp(1.0 / max(1, totalRows), 1.0);

    final double rangeSize =
        (totalRows * rangeSel).clamp(1.0, totalRows.toDouble());

    final bool canStream = _canStreamInRequestedOrder(
      tableName: tableName,
      plan: plan,
      schema: schema,
      orderBy: orderBy,
    );

    if (!canStream) {
      // Must scan the full access range to guarantee correct ordering (topK).
      return rangeSize;
    }

    // Selectivity within the access range.
    final double condSel =
        (overallSelectivity / rangeSel).clamp(1.0 / max(1, totalRows), 1.0);

    final double expectedScan = (need / condSel).clamp(1.0, rangeSize);
    return expectedScan;
  }

  /// Find an index that satisfies the ordering requirement (prefix match).
  IndexSchema? _findSortingIndex(TableSchema schema, List<String> orderBy) {
    if (orderBy.isEmpty) return null;

    for (final idx in schema.getAllIndexes()) {
      // For now, we only support single-field orderBy matching the first field of an index
      // OR a composite index where the orderBy prefix matches exactly.
      bool matches = true;
      for (int i = 0; i < orderBy.length; i++) {
        if (i >= idx.fields.length) {
          matches = false;
          break;
        }

        String f = orderBy[i].trim();
        if (f.startsWith('-')) {
          f = f.substring(1).trim();
        }

        // Handle possible table prefix (e.g. "users.id")
        if (f.contains('.')) {
          final parts = f.split('.');
          if (parts.first == schema.name) {
            f = parts.last;
          }
        }

        if (f != idx.fields[i]) {
          matches = false;
          break;
        }
      }

      if (matches) return idx;
    }
    return null;
  }
}
