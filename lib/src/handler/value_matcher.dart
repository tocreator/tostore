import 'dart:typed_data';

import '../core/table_data_manager.dart';
import '../handler/logger.dart';
import '../model/table_schema.dart';
import '../query/query_condition.dart';

// Matches are based on a > b, so 1 means a > b, -1 means a < b, 0 means a == b
typedef MatcherFunction = int Function(dynamic a, dynamic b);

// Define matcher types
enum MatcherType {
  // String-based primary keys
  pkString,
  pkNumericString,
  pkShortCodeString,

  // General fields
  integer,
  integerNullable,
  bigInt,
  bigIntNullable,
  double,
  doubleNullable,
  text,
  textNullable,
  boolean,
  booleanNullable,
  datetime,
  datetimeNullable,
  blob,
  blobNullable,

  // Default/unsupported
  unsupported,
}

class ValueMatcher {
  static void sortMapList(
    List<Map<String, dynamic>> list,
    List<String> sortFields,
    List<bool> sortDirections,
    Map<String, TableSchema> schemas,
    String mainTableName,
  ) {
    if (list.isEmpty || sortFields.isEmpty) {
      return;
    }

    final matchers = <String, MatcherFunction>{};
    for (final field in sortFields) {
      if (!matchers.containsKey(field)) {
        final schema = ConditionRecordMatcher.getSchemaForField(
            field, schemas, mainTableName);
        if (schema != null) {
          final fieldName = field.contains('.') ? field.split('.').last : field;
          matchers[field] =
              ValueMatcher.getMatcher(schema.getFieldMatcherType(fieldName));
        } else {
          matchers[field] = ValueMatcher.getMatcher(MatcherType.unsupported);
        }
      }
    }

    list.sort((a, b) {
      for (int i = 0; i < sortFields.length; i++) {
        final field = sortFields[i];
        final ascending = sortDirections[i];
        final matcher = matchers[field]!;

        final valA = ConditionRecordMatcher.getFieldValue(a, field);
        final valB = ConditionRecordMatcher.getFieldValue(b, field);

        final comparison = matcher(valA, valB);

        if (comparison != 0) {
          return ascending ? comparison : -comparison;
        }
      }
      return 0;
    });
  }

  static MatcherFunction getMatcher(MatcherType type) {
    switch (type) {
      // --- Primary Key Matchers (already robust) ---
      case MatcherType.pkString:
        return (a, b) {
          if (a is String && b is String) {
            if (a.length != b.length) return a.length.compareTo(b.length);
            return a.compareTo(b);
          }
          return a.toString().compareTo(b.toString());
        };
      case MatcherType.pkNumericString:
      case MatcherType.pkShortCodeString:
        return (a, b) {
          // This is the most common case and avoids any type checks below.
          if (a is String && b is String) {
            if (a.length != b.length) return a.length.compareTo(b.length);
            return a.compareTo(b);
          }

          // Handle nulls safely.
          if (a == null || b == null) {
            return (a == b) ? 0 : (a == null ? -1 : 1);
          }

          // Optimized path for mixed types (e.g., String vs BigInt).
          if (a is String) {
            // 'a' is already a string, only convert 'b'.
            final sB = b.toString();
            if (a.length != sB.length) return a.length.compareTo(sB.length);
            return a.compareTo(sB);
          }
          if (b is String) {
            // 'b' is already a string, only convert 'a'.
            final sA = a.toString();
            if (sA.length != b.length) return sA.length.compareTo(b.length);
            return sA.compareTo(b);
          }

          // correctly compare their string representations based on length and content.
          final sA = a.toString();
          final sB = b.toString();
          if (sA.length != sB.length) return sA.length.compareTo(sB.length);
          return sA.compareTo(sB);
        };

      // --- Numeric Types (with safe conversion) ---
      case MatcherType.integer:
      case MatcherType.double:
        return (a, b) {
          if (a is num && b is num) return a.compareTo(b);
          // Slow path with safe conversion
          final numA = (a is num) ? a : (a is String ? num.tryParse(a) : null);
          final numB = (b is num) ? b : (b is String ? num.tryParse(b) : null);
          if (numA != null && numB != null) return numA.compareTo(numB);
          return _unsupportedMatcher(a, b);
        };
      case MatcherType.integerNullable:
      case MatcherType.doubleNullable:
        return (a, b) {
          if (a == null || b == null) {
            return (a == b) ? 0 : (a == null ? -1 : 1);
          }
          if (a is num && b is num) return a.compareTo(b);
          // Slow path with safe conversion
          final numA = (a is num) ? a : (a is String ? num.tryParse(a) : null);
          final numB = (b is num) ? b : (b is String ? num.tryParse(b) : null);
          if (numA != null && numB != null) return numA.compareTo(numB);
          return _unsupportedMatcher(a, b);
        };
      case MatcherType.bigInt:
        return (a, b) {
          if (a is BigInt && b is BigInt) return a.compareTo(b);
          final bigA = (a is BigInt)
              ? a
              : (a is int
                  ? BigInt.from(a)
                  : (a is String ? BigInt.tryParse(a) : null));
          final bigB = (b is BigInt)
              ? b
              : (b is int
                  ? BigInt.from(b)
                  : (b is String ? BigInt.tryParse(b) : null));
          if (bigA != null && bigB != null) return bigA.compareTo(bigB);
          return _unsupportedMatcher(a, b);
        };
      case MatcherType.bigIntNullable:
        return (a, b) {
          if (a == null || b == null) {
            return (a == b) ? 0 : (a == null ? -1 : 1);
          }
          if (a is BigInt && b is BigInt) return a.compareTo(b);
          final bigA = (a is BigInt)
              ? a
              : (a is int
                  ? BigInt.from(a)
                  : (a is String ? BigInt.tryParse(a) : null));
          final bigB = (b is BigInt)
              ? b
              : (b is int
                  ? BigInt.from(b)
                  : (b is String ? BigInt.tryParse(b) : null));
          if (bigA != null && bigB != null) return bigA.compareTo(bigB);
          return _unsupportedMatcher(a, b);
        };

      // --- Other Standard Types ---
      case MatcherType.text:
      case MatcherType.datetime:
        return (a, b) {
          if (a is String && b is String) return a.compareTo(b);
          if (a is String) {
            final sB = b.toString();
            return a.compareTo(sB);
          }
          if (b is String) {
            final sA = a.toString();
            return sA.compareTo(b);
          }
          return _unsupportedMatcher(a, b);
        };
      case MatcherType.textNullable:
      case MatcherType.datetimeNullable:
        return (a, b) {
          if (a == null || b == null) {
            return (a == b) ? 0 : (a == null ? -1 : 1);
          }
          if (a is String && b is String) return a.compareTo(b);
          if (a is String) {
            final sB = b.toString();
            return a.compareTo(sB);
          }
          if (b is String) {
            final sA = a.toString();
            return sA.compareTo(b);
          }
          return _unsupportedMatcher(a, b);
        };
      case MatcherType.boolean:
        return (a, b) {
          if (a is bool && b is bool) return (a == b) ? 0 : (a ? 1 : -1);
          return _unsupportedMatcher(a, b);
        };
      case MatcherType.booleanNullable:
        return (a, b) {
          if (a == null || b == null) {
            return (a == b) ? 0 : (a == null ? -1 : 1);
          }
          if (a is bool && b is bool) return (a == b) ? 0 : (a ? 1 : -1);
          return _unsupportedMatcher(a, b);
        };
      case MatcherType.blob:
        return (a, b) {
          if (a is Uint8List && b is Uint8List) {
            final len1 = a.length;
            final len2 = b.length;
            if (len1 != len2) return len1.compareTo(len2);
            for (int i = 0; i < len1; i++) {
              if (a[i] != b[i]) return a[i].compareTo(b[i]);
            }
            return 0;
          }
          return _unsupportedMatcher(a, b);
        };
      case MatcherType.blobNullable:
        return (a, b) {
          if (a == null || b == null) {
            return (a == b) ? 0 : (a == null ? -1 : 1);
          }
          if (a is Uint8List && b is Uint8List) {
            final len1 = a.length;
            final len2 = b.length;
            if (len1 != len2) return len1.compareTo(len2);
            for (int i = 0; i < len1; i++) {
              if (a[i] != b[i]) return a[i].compareTo(b[i]);
            }
            return 0;
          }
          return _unsupportedMatcher(a, b);
        };

      default:
        return _unsupportedMatcher;
    }
  }

  static int _unsupportedMatcher(dynamic a, dynamic b) {
    // Final fallback for unsupported or mismatched types.
    // Handles nulls first for safety.
    if (a == null || b == null) {
      return (a == b) ? 0 : (a == null ? -1 : 1);
    }
    // If types are different, convert to string for a deterministic comparison.
    try {
      return a.toString().compareTo(b.toString());
    } catch (e) {
      // This should be rare, but as a last resort, we declare them not equal.
      Logger.warn('Unsupported comparison failed between $a and $b. Error: $e',
          label: 'ValueMatcher._unsupportedMatcher');
      return -1;
    }
  }

  static bool isInRange(
      dynamic value, dynamic start, dynamic end, MatcherFunction matcher) {
    if (value == null) {
      return false;
    }
    return matcher(value, start) >= 0 && matcher(value, end) <= 0;
  }

  static bool matchesLike(String value, String pattern) {
    try {
      // Escape special regex characters, then convert SQL wildcards to regex.
      final regexPattern = pattern
          .replaceAllMapped(
              RegExp(r'([.$*+?()\[\]{}|^])'), (match) => '\\${match.group(1)}')
          .replaceAll('%', '.*')
          .replaceAll('_', '.');
      return RegExp('^$regexPattern\$').hasMatch(value);
    } catch (e) {
      Logger.warn('Invalid LIKE pattern: $pattern', label: '_matchesLike');
      return false;
    }
  }
}

/// An internal, optimized evaluator for a query condition.
/// It pre-compiles matcher functions and uses an iterative approach
/// to avoid deep recursion risks.
class ConditionRecordMatcher {
  final QueryCondition _condition;
  final ConditionNode _rootNode;
  final Map<String, MatcherFunction> _matchers;

  ConditionRecordMatcher._(this._condition, this._rootNode, this._matchers);

  /// The original condition, can be used for query planning.
  QueryCondition get condition => _condition;

  /// Prepares an evaluator by creating optimized matcher functions for all
  /// fields involved in the query condition.
  factory ConditionRecordMatcher.prepare(QueryCondition condition,
      Map<String, TableSchema> schemas, String mainTableName) {
    // 1. Always filter out deleted records first.
    if (condition.isEmpty) {
      // Return a dummy evaluator for empty conditions that always returns true.
      return ConditionRecordMatcher._(
          condition, ConditionNode(type: NodeType.and), const {});
    }

    // 2. Prepare an evaluator for the condition and execute.
    // The preparation of matchers is handled internally.
    try {
      final matchers = <String, MatcherFunction>{};
      final conditionMap = condition.build();

      // Use an iterative approach (stack) to avoid deep recursion.
      final List<Map<String, dynamic>> conditionStack = [conditionMap];

      while (conditionStack.isNotEmpty) {
        final current = conditionStack.removeLast();
        for (var entry in current.entries) {
          final field = entry.key;

          if (field == 'AND' || field == 'OR') {
            if (entry.value is List) {
              for (var subCondition in (entry.value as List)) {
                if (subCondition is Map<String, dynamic>) {
                  conditionStack.add(subCondition); // Push to stack
                }
              }
            }
          } else {
            // Prepare matcher for the field if not already done.
            if (!matchers.containsKey(field)) {
              final schema = getSchemaForField(field, schemas, mainTableName);
              if (schema != null) {
                final fieldName =
                    field.contains('.') ? field.split('.').last : field;
                final matcherType = schema.getFieldMatcherType(fieldName);
                matchers[field] = ValueMatcher.getMatcher(matcherType);
              } else {
                // Fallback for safety.
                matchers[field] =
                    ValueMatcher.getMatcher(MatcherType.unsupported);
              }
            }
          }
        }
      }
      return ConditionRecordMatcher._(condition, condition.rootNode, matchers);
    } catch (e, s) {
      Logger.error('Condition evaluation failed: $e\n$s',
          label: 'ValueMatcher.matches');
      // Return a dummy evaluator that will prevent further errors.
      return ConditionRecordMatcher._(
          condition, ConditionNode(type: NodeType.and), const {});
    }
  }

  /// Finds the correct TableSchema for a given field, which may be prefixed
  /// with a table name (e.g., 'users.id').
  static TableSchema? getSchemaForField(
      String field, Map<String, TableSchema> schemas, String mainTableName) {
    if (field.contains('.')) {
      final tableName = field.split('.').first;
      return schemas[tableName];
    }
    return schemas[mainTableName];
  }

  /// Gets the value for a field from a record, handling prefixed names like 'table.field'.
  static dynamic getFieldValue(Map<String, dynamic> record, String field) {
    // Direct match
    if (record.containsKey(field)) {
      return record[field];
    }
    // Prefixed match, e.g., 'users.name'
    if (field.contains('.')) {
      // After joins, keys might be flattened to 'table_field'
      final parts = field.split('.');
      final underscoreField = '${parts[0]}_${parts[1]}';
      if (record.containsKey(underscoreField)) {
        return record[underscoreField];
      }
      // Or the key might just be the field name without prefix
      return record[parts[1]];
    }
    // Unprefixed field, but record key might have a prefix
    // e.g., field is 'name', record key could be 'users.name'
    for (String key in record.keys) {
      if (key.endsWith('.$field')) {
        return record[key];
      }
    }
    return null;
  }

  /// matches the record against the prepared condition tree.
  bool matches(Map<String, dynamic> record) {
    if (isDeletedRecord(record)) {
      return false;
    }
    // Handle the dummy evaluator for empty conditions
    if (_rootNode.children.isEmpty && _matchers.isEmpty) {
      return true;
    }
    return _matchNode(_rootNode, record);
  }

  /// Iteratively evaluates a node in the condition tree.
  bool _matchNode(ConditionNode node, Map<String, dynamic> record) {
    switch (node.type) {
      case NodeType.leaf:
        return _matchAllConditions(record, node.condition);
      case NodeType.custom:
        return node.customMatcher?.call(record) ?? false;
      case NodeType.and:
        // For AND, all children must be true.
        for (final child in node.children) {
          if (!_matchNode(child, record)) return false;
        }
        return true;
      case NodeType.or:
        // For OR, at least one child must be true.
        for (final child in node.children) {
          if (_matchNode(child, record)) return true;
        }
        // If the OR node has no children, it's considered false.
        return node.children.isEmpty ? true : false;
    }
  }

  /// Checks if a record satisfies all conditions in a leaf node.
  bool _matchAllConditions(
      Map<String, dynamic> record, Map<String, dynamic> conditions) {
    if (conditions.containsKey('AND')) {
      return (conditions['AND'] as List)
          .every((c) => _matchAllConditions(record, c as Map<String, dynamic>));
    }
    if (conditions.containsKey('OR')) {
      return (conditions['OR'] as List)
          .any((c) => _matchAllConditions(record, c as Map<String, dynamic>));
    }

    for (var entry in conditions.entries) {
      if (!_matchFieldCondition(record, entry.key, entry.value)) {
        return false;
      }
    }
    return true;
  }

  bool _matchFieldCondition(
      Map<String, dynamic> record, String field, dynamic condition) {
    dynamic fieldValue = getFieldValue(record, field);

    // Handle the special case where the field does not exist in the record.
    if (fieldValue == null && !_recordHasField(record, field)) {
      // IS NULL is true if the field doesn't exist.
      if (condition is Map && condition.containsKey('IS')) {
        return condition['IS'] == null;
      }
      // IS NOT is false if the field doesn't exist.
      if (condition is Map && condition.containsKey('IS NOT')) {
        return condition['IS NOT'] != null;
      }
      // For any other operator, a non-existent field cannot satisfy the condition.
      return false;
    }

    return _matchSingleCondition(field, fieldValue, condition);
  }

  /// Checks if a record contains a field, accounting for prefixed variants.
  bool _recordHasField(Map<String, dynamic> record, String field) {
    if (record.containsKey(field)) return true;
    for (String key in record.keys) {
      if (key.endsWith('.$field') || key.endsWith('_$field')) {
        return true;
      }
    }
    return false;
  }

  /// Matches a single value against a condition (e.g., {'=': 10}).
  bool _matchSingleCondition(String field, dynamic value, dynamic condition) {
    if (condition == null) return value == null;

    final matcher =
        _matchers[field] ?? ValueMatcher.getMatcher(MatcherType.unsupported);

    if (condition is Map) {
      // This is an operator map, e.g., {'>': 10, '<': 20}.
      // To be compatible with old structure, we assume OR between operators in the same map.
      // E.g., where('age', {'>': 60, '<': 10}) is `age > 60 OR age < 10`.
      for (var entry in condition.entries) {
        if (_evaluateOperator(matcher, value, entry.key, entry.value)) {
          return true; // Any matching operator is sufficient.
        }
      }
      return false;
    }

    // Simple equality check.
    return matcher(value, condition) == 0;
  }

  /// Evaluates a single operator (e.g., '>', '=', 'IN').
  bool _evaluateOperator(MatcherFunction matcher, dynamic value,
      String operator, dynamic compareValue) {
    switch (operator.toUpperCase()) {
      case '=':
        return matcher(value, compareValue) == 0;
      case '!=':
      case '<>':
        return matcher(value, compareValue) != 0;
      case '>':
        return value != null && matcher(value, compareValue) > 0;
      case '>=':
        return value != null && matcher(value, compareValue) >= 0;
      case '<':
        return value != null && matcher(value, compareValue) < 0;
      case '<=':
        return value != null && matcher(value, compareValue) <= 0;
      case 'IN':
        if (value == null || compareValue is! List) return false;
        return compareValue.any((item) => matcher(value, item) == 0);
      case 'NOT IN':
        if (value == null || compareValue is! List) return true;
        return !compareValue.any((item) => matcher(value, item) == 0);
      case 'BETWEEN':
        if (value == null ||
            compareValue is! Map ||
            !compareValue.containsKey('start') ||
            !compareValue.containsKey('end')) {
          return false;
        }
        return matcher(value, compareValue['start']) >= 0 &&
            matcher(value, compareValue['end']) <= 0;
      case 'LIKE':
        if (value == null || compareValue is! String) return false;
        return _matchesLike(value.toString(), compareValue);
      case 'NOT LIKE':
        if (value == null || compareValue is! String) return false;
        return !_matchesLike(value.toString(), compareValue);
      case 'IS':
        return value == null && compareValue == null;
      case 'IS NOT':
        return value != null && compareValue == null;
      default:
        Logger.warn('Unknown operator: $operator', label: '_evaluateOperator');
        return false;
    }
  }

  /// Converts a SQL LIKE pattern to a RegExp and executes it.
  bool _matchesLike(String value, String pattern) {
    try {
      // Escape special regex characters, then convert SQL wildcards to regex.
      final regexPattern = pattern
          .replaceAllMapped(
              RegExp(r'([.$*+?()\[\]{}|^])'), (match) => '\\${match.group(1)}')
          .replaceAll('%', '.*')
          .replaceAll('_', '.');
      return RegExp('^$regexPattern\$').hasMatch(value);
    } catch (e) {
      Logger.warn('Invalid LIKE pattern: $pattern', label: '_matchesLike');
      return false;
    }
  }
}

/// Node type enumeration.
enum NodeType {
  /// Leaf node, contains actual conditions.
  leaf,

  /// AND operator node.
  and,

  /// OR operator node.
  or,

  /// Custom function node.
  custom
}

/// Condition node class, used by both QueryCondition and _ConditionEvaluator.
class ConditionNode {
  /// Node type.
  NodeType type;

  /// Condition content (only valid for leaf nodes).
  Map<String, dynamic> condition;

  /// Custom matcher function (only valid for custom nodes).
  bool Function(Map<String, dynamic>)? customMatcher;

  /// Child node list.
  List<ConditionNode> children;

  /// Create a condition node.
  ConditionNode({
    required this.type,
    this.condition = const {},
    this.customMatcher,
  }) : children = [];

  /// Create a deep copy of the node.
  ConditionNode clone() {
    final copy = ConditionNode(
      type: type,
      condition: Map.from(condition),
      customMatcher: customMatcher,
    );

    for (final child in children) {
      copy.children.add(child.clone());
    }

    return copy;
  }
}
