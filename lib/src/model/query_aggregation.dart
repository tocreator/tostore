enum QueryAggregationType {
  count,
  sum,
  avg,
  min,
  max,
}

class QueryAggregation {
  final QueryAggregationType type;
  final String field;
  final String? alias;

  const QueryAggregation({
    required this.type,
    required this.field,
    this.alias,
  });

  String get outputName => alias ?? '${type.name}($field)';
}

/// A helper class to construct aggregations for select clauses.
class Agg {
  static QueryAggregation count(String field, {String? alias}) =>
      QueryAggregation(
          type: QueryAggregationType.count, field: field, alias: alias);

  static QueryAggregation sum(String field, {String? alias}) =>
      QueryAggregation(
          type: QueryAggregationType.sum, field: field, alias: alias);

  static QueryAggregation avg(String field, {String? alias}) =>
      QueryAggregation(
          type: QueryAggregationType.avg, field: field, alias: alias);

  static QueryAggregation min(String field, {String? alias}) =>
      QueryAggregation(
          type: QueryAggregationType.min, field: field, alias: alias);

  static QueryAggregation max(String field, {String? alias}) =>
      QueryAggregation(
          type: QueryAggregationType.max, field: field, alias: alias);
}

class _AggState {
  num sumVal = 0;
  num minVal = double.infinity;
  num maxVal = double.negativeInfinity;
  int countAgg = 0;
}

class QueryAggregator {
  final List<QueryAggregation> aggregations;
  final List<String>? groupBy;

  // Single group state (when no groupBy is used)
  final List<_AggState> _singleState;

  // Grouped state
  final Map<String, List<_AggState>> _groupedState = {};

  // Keep track of the first row of each group to retain group keys
  final Map<String, Map<String, dynamic>> _groupKeys = {};

  QueryAggregator(this.aggregations, {this.groupBy})
      : _singleState = List.generate(aggregations.length, (_) => _AggState());

  void accumulate(Map<String, dynamic> row) {
    if (groupBy == null || groupBy!.isEmpty) {
      _accumulateState(_singleState, row);
    } else {
      final String groupKey = _buildGroupKey(row);
      if (!_groupedState.containsKey(groupKey)) {
        _groupedState[groupKey] =
            List.generate(aggregations.length, (_) => _AggState());

        // Store the grouped fields from the first row of this group
        final Map<String, dynamic> keyData = {};
        for (final field in groupBy!) {
          keyData[field] = _extractValue(row, field);
        }
        _groupKeys[groupKey] = keyData;
      }
      _accumulateState(_groupedState[groupKey]!, row);
    }
  }

  String _buildGroupKey(Map<String, dynamic> row) {
    return groupBy!
        .map((f) => _extractValue(row, f)?.toString() ?? 'null')
        .join('|');
  }

  void _accumulateState(List<_AggState> states, Map<String, dynamic> row) {
    for (int i = 0; i < aggregations.length; i++) {
      final agg = aggregations[i];
      final state = states[i];

      if (agg.type == QueryAggregationType.count) {
        state.countAgg++;
        continue;
      }

      final val = _extractNumValue(row, agg.field);
      if (val != null) {
        if (agg.type == QueryAggregationType.sum ||
            agg.type == QueryAggregationType.avg) {
          state.sumVal += val;
        }
        if (agg.type == QueryAggregationType.min && val < state.minVal) {
          state.minVal = val;
        }
        if (agg.type == QueryAggregationType.max && val > state.maxVal) {
          state.maxVal = val;
        }
        state.countAgg++;
      }
    }
  }

  static dynamic _extractValue(Map<String, dynamic> row, String fieldName) {
    if (fieldName.contains('.')) {
      Map<String, dynamic>? current = row;
      final parts = fieldName.split('.');
      for (int i = 0; i < parts.length - 1; i++) {
        final p = parts[i];
        if (current![p] is Map) {
          current = current[p] as Map<String, dynamic>;
        } else {
          return null;
        }
      }
      return current?[parts.last];
    }
    return row[fieldName];
  }

  static num? _extractNumValue(Map<String, dynamic> row, String fieldName) {
    final val = _extractValue(row, fieldName);
    if (val is num) return val;
    return null;
  }

  // Used for single aggregation (backward compatibility)
  dynamic get result {
    if (aggregations.length == 1 && (groupBy == null || groupBy!.isEmpty)) {
      return _getResultValue(aggregations.first, _singleState.first);
    }
    return getGroupedResults();
  }

  dynamic _getResultValue(QueryAggregation agg, _AggState state) {
    if (state.countAgg == 0 && agg.type != QueryAggregationType.count) {
      return null;
    }
    switch (agg.type) {
      case QueryAggregationType.sum:
        return state.sumVal;
      case QueryAggregationType.avg:
        return state.sumVal / state.countAgg;
      case QueryAggregationType.min:
        return state.minVal;
      case QueryAggregationType.max:
        return state.maxVal;
      case QueryAggregationType.count:
        return state.countAgg;
    }
  }

  // Get list of results with field names and grouped keys
  List<Map<String, dynamic>> getGroupedResults() {
    if (groupBy == null || groupBy!.isEmpty) {
      final Map<String, dynamic> row = {};
      for (int i = 0; i < aggregations.length; i++) {
        row[aggregations[i].outputName] =
            _getResultValue(aggregations[i], _singleState[i]);
      }
      return [row];
    }

    final List<Map<String, dynamic>> results = [];
    _groupedState.forEach((key, states) {
      final Map<String, dynamic> row = Map.from(_groupKeys[key]!);
      for (int i = 0; i < aggregations.length; i++) {
        row[aggregations[i].outputName] =
            _getResultValue(aggregations[i], states[i]);
      }
      results.add(row);
    });
    return results;
  }
}
