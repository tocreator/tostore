import '../handler/logger.dart';
import '../handler/value_comparator.dart';

/// query condition builder
class QueryCondition {
  // current condition group
  final List<_ConditionGroup> _groups = [];
  // current active condition group
  _ConditionGroup _currentGroup;
  // record condition connection method
  final List<String> _operators = [];

  QueryCondition() : _currentGroup = _ConditionGroup();

  /// add condition
  void where(String field, dynamic operator, [dynamic value]) {
    final condition = _buildCondition(field, operator, value);

    // if current group has conditions, save and create new group
    if (_currentGroup.conditions.isNotEmpty) {
      _groups.add(_currentGroup);
      _operators.add('AND'); // default use AND connection
      _currentGroup = _ConditionGroup();
    }

    // add new condition
    _currentGroup.conditions = condition;
  }

  /// start a new OR group
  void or() {
    if (_currentGroup.conditions.isNotEmpty) {
      _currentGroup.isOr = true;
      _groups.add(_currentGroup);
      _operators.add('OR');
      _currentGroup = _ConditionGroup();
    }
  }

  /// build condition
  Map<String, dynamic> _buildCondition(String field, dynamic operator,
      [dynamic value]) {
    if (operator == null) {
      return {field: null};
    }

    if (value == null) {
      if (operator == 'IS' || operator == 'IS NOT') {
        return {
          field: {operator: null}
        };
      }
      return {field: operator};
    }

    final operatorStr = operator.toString().toUpperCase();
    switch (operatorStr) {
      case '=':
        return {
          field: {'=': value}
        }; // always use Map format
      case '>':
      case '<':
      case '>=':
      case '<=':
      case '!=':
      case 'LIKE':
      case 'NOT LIKE':
      case 'IN':
      case 'NOT IN':
        return {
          field: {operator: value}
        };
      case 'BETWEEN':
        return {
          field: {
            'BETWEEN': {'start': value[0], 'end': value[1]}
          }
        };
    }
    return {
      field: {operator: value}
    };
  }

  /// get final query conditions
  Map<String, dynamic> build() {
    // save last group
    if (_currentGroup.conditions.isNotEmpty) {
      _groups.add(_currentGroup);
      _currentGroup = _ConditionGroup();
    }

    if (_groups.isEmpty) {
      return {};
    }

    // if only one group, return directly
    if (_groups.length == 1) {
      return _groups[0].conditions;
    }

    // group conditions by OR
    final orParts = <Map<String, dynamic>>[];
    var currentAndPart = <Map<String, dynamic>>[
      _groups[0].conditions
    ]; // start from first condition
    var i = 1; // start from second condition

    while (i < _groups.length) {
      if (i - 1 < _operators.length && _operators[i - 1] == 'OR') {
        // check previous operator
        // save previous AND group
        if (currentAndPart.isNotEmpty) {
          if (currentAndPart.length == 1) {
            orParts.add(currentAndPart.first);
          } else {
            orParts.add({'AND': currentAndPart});
          }
        }

        // start new AND group
        currentAndPart = [_groups[i].conditions];
        i++;

        // collect subsequent AND conditions
        while (i < _groups.length &&
            (i - 1 >= _operators.length || _operators[i - 1] != 'OR')) {
          currentAndPart.add(_groups[i].conditions);
          i++;
        }
      } else {
        currentAndPart.add(_groups[i].conditions);
        i++;
      }
    }

    // handle last AND group
    if (currentAndPart.isNotEmpty) {
      if (currentAndPart.length == 1) {
        orParts.add(currentAndPart.first);
      } else {
        orParts.add({'AND': currentAndPart});
      }
    }

    // if only one result, return directly
    if (orParts.length == 1) {
      return orParts[0];
    }

    // return OR combination
    return {'OR': orParts};
  }

  /// reset state
  void _reset() {
    _groups.clear();
    _currentGroup = _ConditionGroup();
  }

  /// clear all conditions
  void clear() {
    _reset();
  }

  /// check if record matches conditions
  bool matches(Map<String, dynamic> record) {
    try {
      // if no conditions, match all records
      if (_groups.isEmpty && _currentGroup.conditions.isEmpty) {
        return true;
      }

      // save current group
      final allGroups = List<_ConditionGroup>.from(_groups);
      if (_currentGroup.conditions.isNotEmpty) {
        allGroups.add(_currentGroup);
      }

      // if only one AND group, check all conditions
      if (allGroups.length == 1 && !allGroups[0].isOr) {
        return _matchAllConditions(record, allGroups[0].conditions);
      }

      // handle multiple groups
      return allGroups.any((group) => group.isOr
          ? _matchAllConditions(record, group.conditions)
          : _matchAllConditions(record, group.conditions));
    } catch (e) {
      Logger.error('condition matching failed: $e',
          label: 'QueryCondition.matches');
      return false;
    }
  }

  /// match all conditions
  bool _matchAllConditions(
      Map<String, dynamic> record, Map<String, dynamic> conditions) {
    for (var entry in conditions.entries) {
      if (!_matchSingleCondition(record[entry.key], entry.value)) {
        return false;
      }
    }
    return true;
  }

  /// match single condition
  bool _matchSingleCondition(dynamic value, dynamic condition) {
    if (condition == null) return value == null;

    if (condition is Map) {
      // check all operator conditions
      for (var entry in condition.entries) {
        final operator = entry.key;
        final compareValue = entry.value;

        bool matches = false;
        switch (operator) {
          case '=':
            matches = value == compareValue;
            break;
          case '!=':
          case '<>':
            matches = value != compareValue;
            break;
          case '>':
            matches = value != null &&
                ValueComparator.compare(value, compareValue) > 0;
            break;
          case '>=':
            matches = value != null &&
                ValueComparator.compare(value, compareValue) >= 0;
            break;
          case '<':
            matches = value != null &&
                ValueComparator.compare(value, compareValue) < 0;
            break;
          case '<=':
            matches = value != null &&
                ValueComparator.compare(value, compareValue) <= 0;
            break;
          case 'IN':
            if (compareValue is! List) return false;
            matches = value != null && compareValue.contains(value);
            break;
          case 'NOT IN':
            if (compareValue is! List) return false;
            matches = value != null && !compareValue.contains(value);
            break;
          case 'BETWEEN':
            if (compareValue is! Map ||
                !compareValue.containsKey('start') ||
                !compareValue.containsKey('end')) {
              return false;
            }
            matches = value != null &&
                ValueComparator.compare(value, compareValue['start']) >= 0 &&
                ValueComparator.compare(value, compareValue['end']) <= 0;
            break;
          case 'LIKE':
            if (value == null || compareValue is! String) return false;
            matches = ValueComparator.matchesLikePattern(value, compareValue);
            break;
          case 'IS':
            matches = value == null;
            break;
          case 'IS NOT':
            matches = value != null;
            break;
        }

        // if any condition is not satisfied, return false directly
        if (!matches) return false;
      }
      return true;
    }

    // simple equal condition
    return value == condition;
  }

  // check if there are any conditions
  bool get isEmpty {
    // check if any saved group has conditions
    if (_groups.isNotEmpty) {
      // check if any group contains conditions
      for (var group in _groups) {
        if (group.conditions.isNotEmpty) {
          return false;
        }
      }
    }

    // check current group
    return _currentGroup.conditions.isEmpty;
  }
}

/// condition group
class _ConditionGroup {
  Map<String, dynamic> conditions = {};
  bool isOr = false;

  _ConditionGroup();
}
