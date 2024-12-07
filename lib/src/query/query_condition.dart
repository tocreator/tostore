import '../handler/logger.dart';

/// 查询条件构造器
class QueryCondition {
  // 存储当前的条件组
  final List<_ConditionGroup> _groups = [];
  // 当前活动的条件组
  _ConditionGroup _currentGroup;
  // 记录条件之间的连接方式
  final List<String> _operators = [];

  QueryCondition() : _currentGroup = _ConditionGroup();

  /// 添加条件
  void where(String field, dynamic operator, [dynamic value]) {
    final condition = _buildCondition(field, operator, value);

    // 如果当前组已有条件，保存并创建新组
    if (_currentGroup.conditions.isNotEmpty) {
      _groups.add(_currentGroup);
      _operators.add('AND'); // 默认使用 AND 连接
      _currentGroup = _ConditionGroup();
    }

    // 添加新条件
    _currentGroup.conditions = condition;
  }

  /// 开始一个新的 OR 组
  void or() {
    if (_currentGroup.conditions.isNotEmpty) {
      _currentGroup.isOr = true;
      _groups.add(_currentGroup);
      _operators.add('OR');
      _currentGroup = _ConditionGroup();
    }
  }

  /// 构建条件
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

    switch (operator.toString().toUpperCase()) {
      case '=':
        return {
          field: {'=': value}
        }; // 始终使用 Map 格式
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
      default:
        return {
          field: {operator: value}
        };
    }
  }

  /// 获取最终的查询条件
  Map<String, dynamic> build() {
    // 保存最后一个组
    if (_currentGroup.conditions.isNotEmpty) {
      _groups.add(_currentGroup);
      _currentGroup = _ConditionGroup();
    }

    if (_groups.isEmpty) {
      return {};
    }

    // 如果只有一个组，直接返回
    if (_groups.length == 1) {
      return _groups[0].conditions;
    }

    // 按 OR 分组处理条件
    final orParts = <Map<String, dynamic>>[];
    var currentAndPart = <Map<String, dynamic>>[
      _groups[0].conditions
    ]; // 从第一个条件开始
    var i = 1; // 从第二个条件开始遍历

    while (i < _groups.length) {
      if (i - 1 < _operators.length && _operators[i - 1] == 'OR') {
        // 检查前一个操作符
        // 保存之前的 AND 组
        if (currentAndPart.isNotEmpty) {
          if (currentAndPart.length == 1) {
            orParts.add(currentAndPart.first);
          } else {
            orParts.add({'AND': currentAndPart});
          }
        }

        // 开始新的 AND 组
        currentAndPart = [_groups[i].conditions];
        i++;

        // 收集后续的 AND 条件
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

    // 处理最后的 AND 组
    if (currentAndPart.isNotEmpty) {
      if (currentAndPart.length == 1) {
        orParts.add(currentAndPart.first);
      } else {
        orParts.add({'AND': currentAndPart});
      }
    }

    // 如果只有一个结果，直接返回
    if (orParts.length == 1) {
      return orParts[0];
    }

    // 返回 OR 组合
    return {'OR': orParts};
  }

  /// 重置状态
  void _reset() {
    _groups.clear();
    _currentGroup = _ConditionGroup();
  }

  /// 清除所有条件
  void clear() {
    _reset();
  }

  /// 检查记录是否匹配条件
  bool matches(Map<String, dynamic> record) {
    try {
      // 如果没有条件，匹配所有记录
      if (_groups.isEmpty && _currentGroup.conditions.isEmpty) {
        return true;
      }

      // 保存当前组
      final allGroups = List<_ConditionGroup>.from(_groups);
      if (_currentGroup.conditions.isNotEmpty) {
        allGroups.add(_currentGroup);
      }

      // 如果只有一个 AND 组，检查所有条件
      if (allGroups.length == 1 && !allGroups[0].isOr) {
        return _matchAllConditions(record, allGroups[0].conditions);
      }

      // 处理多个组的情况
      return allGroups.any((group) => group.isOr
          ? _matchAllConditions(record, group.conditions)
          : _matchAllConditions(record, group.conditions));
    } catch (e) {
      Logger.error('条件匹配失败: $e', label: 'QueryCondition.matches');
      return false;
    }
  }

  /// 匹配所有条件
  bool _matchAllConditions(
      Map<String, dynamic> record, Map<String, dynamic> conditions) {
    for (var entry in conditions.entries) {
      if (!_matchSingleCondition(record[entry.key], entry.value)) {
        return false;
      }
    }
    return true;
  }

  /// 匹配单个条件
  bool _matchSingleCondition(dynamic value, dynamic condition) {
    if (condition == null) return value == null;

    if (condition is Map) {
      // 检查所有操作符条件
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
            matches = value != null && _compareValues(value, compareValue) > 0;
            break;
          case '>=':
            matches = value != null && _compareValues(value, compareValue) >= 0;
            break;
          case '<':
            matches = value != null && _compareValues(value, compareValue) < 0;
            break;
          case '<=':
            matches = value != null && _compareValues(value, compareValue) <= 0;
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
                _compareValues(value, compareValue['start']) >= 0 &&
                _compareValues(value, compareValue['end']) <= 0;
            break;
          case 'LIKE':
            if (value == null || compareValue is! String) return false;
            final pattern = compareValue
                .replaceAll('%', '.*')
                .replaceAll('_', '.')
                .replaceAll('\\', '\\\\');
            matches = RegExp('^$pattern\$', caseSensitive: false)
                .hasMatch(value.toString());
            break;
          case 'IS':
            matches = value == null;
            break;
          case 'IS NOT':
            matches = value != null;
            break;
          default:
            matches = false;
        }

        // 如果任何一个条件不满足，直接返回 false
        if (!matches) return false;
      }
      return true;
    }

    // 简单相等条件
    return value == condition;
  }

  /// 安全的值比较
  int _compareValues(dynamic a, dynamic b) {
    if (a == null || b == null) return 0;

    if (a is num && b is num) {
      return a.compareTo(b);
    }
    if (a is String && b is String) {
      return a.compareTo(b);
    }
    if (a is DateTime && b is DateTime) {
      return a.compareTo(b);
    }
    if (a is bool && b is bool) {
      return a == b ? 0 : (a ? 1 : -1);
    }

    return a.toString().compareTo(b.toString());
  }
}

/// 条件组
class _ConditionGroup {
  Map<String, dynamic> conditions = {};
  bool isOr = false;

  _ConditionGroup();
}
