import '../handler/value_matcher.dart';
import '../model/table_schema.dart';

/// Query Condition Builder
class QueryCondition {
  // Condition tree root node (lazily created)
  ConditionNode? _root;
  // Current active node (for building conditions)
  ConditionNode? _current;
  bool _isNormalized = false;
  int _conditionCount = 0;
  String? _fastSingleEqField;
  dynamic _fastSingleEqVal;
  String? _singleOp;

  // Memoized single equality fast-path cache
  ({String field, dynamic value})? _cachedSingleEq;
  bool _hasCalculatedSingleEq = false;

  void _invalidateSingleEqCache() {
    _hasCalculatedSingleEq = false;
    _cachedSingleEq = null;
    _cachedBuiltMap = null;
  }

  // Order by, limit, offset related properties
  List<String>? _orderBy;
  int? _limit;
  int? _offset;
  String? _cursor;

  /// Create a new query condition builder
  QueryCondition();

  /// Creates a QueryCondition from a map representation.
  factory QueryCondition.fromMap(Map<String, dynamic> map) {
    final qc = QueryCondition();
    qc._root = ConditionNode(type: NodeType.and);
    qc._root!.children.add(_nodeFromMap(map));
    qc._current = qc._root;
    return qc;
  }

  void _ensureTreeInitialized() {
    if (_root != null) return;
    _root = ConditionNode(type: NodeType.and);
    _current = ConditionNode(type: NodeType.and);
    _root!.children.add(_current!);
    if (_conditionCount == 1 && _fastSingleEqField != null) {
      final condition = _buildCondition(
          _fastSingleEqField!, _singleOp ?? '=', _fastSingleEqVal);
      final leafNode = ConditionNode(type: NodeType.leaf, condition: condition);
      _current!.children.add(leafNode);
      _fastSingleEqField = null;
      _fastSingleEqVal = null;
    }
  }

  static ConditionNode _nodeFromMap(Map<String, dynamic> map) {
    if (map.containsKey('AND')) {
      final node = ConditionNode(type: NodeType.and);
      final conditions = map['AND'] as List;
      for (final condition in conditions) {
        node.children.add(_nodeFromMap(condition as Map<String, dynamic>));
      }
      return node;
    } else if (map.containsKey('OR')) {
      final node = ConditionNode(type: NodeType.or);
      final conditions = map['OR'] as List;
      for (final condition in conditions) {
        node.children.add(_nodeFromMap(condition as Map<String, dynamic>));
      }
      return node;
    } else {
      // It's a leaf node (a simple condition)
      return ConditionNode(type: NodeType.leaf, condition: map);
    }
  }

  /// Expose the root for external evaluators
  ConditionNode get rootNode {
    _ensureTreeInitialized();
    return _root!;
  }

  /// Check if a single record matches this query condition
  bool matches(Map<String, dynamic> record) {
    if (isEmpty) return true;
    final matcher = ConditionRecordMatcher.prepare(this, {}, '');
    return matcher.matches(record);
  }

  /// Create a copy of a query condition
  QueryCondition clone() {
    final copy = QueryCondition();
    copy._conditionCount = _conditionCount;
    copy._fastSingleEqField = _fastSingleEqField;
    copy._fastSingleEqVal = _fastSingleEqVal;
    copy._singleOp = _singleOp;
    copy._isNormalized = _isNormalized;

    if (_root != null) {
      copy._root = ConditionNode(type: _root!.type);
      for (var child in _root!.children) {
        copy._root!.children.add(child.clone());
      }
      if (_current == _root) {
        copy._current = copy._root;
      } else {
        copy._current =
            _findCorrespondingNode(copy._root!, _root!, _current!) ??
                copy._root;
      }
    }

    // Copy sorting and pagination parameters
    copy._orderBy = _orderBy != null ? List.from(_orderBy!) : null;
    copy._limit = _limit;
    copy._offset = _offset;
    copy._cursor = _cursor;
    return copy;
  }

  /// Find the corresponding node in two trees
  ConditionNode? _findCorrespondingNode(
      ConditionNode newRoot, ConditionNode oldRoot, ConditionNode target) {
    if (oldRoot == target) {
      return newRoot;
    }

    for (int i = 0;
        i < oldRoot.children.length && i < newRoot.children.length;
        i++) {
      final result = _findCorrespondingNode(
          newRoot.children[i], oldRoot.children[i], target);
      if (result != null) {
        return result;
      }
    }

    return null;
  }

  /// Add a basic condition
  QueryCondition where(String field, dynamic operator, dynamic value) {
    _conditionCount++;
    _invalidateSingleEqCache();
    final cleanField = field.contains('.') ? field.split('.').last : field;
    if (_conditionCount == 1 &&
        _root == null &&
        (operator == '=' || operator == '==')) {
      _fastSingleEqField = cleanField;
      _fastSingleEqVal = value;
      _singleOp = '=';
      _cachedSingleEq = (field: cleanField, value: value);
      _hasCalculatedSingleEq = true;
      return this;
    }
    _ensureTreeInitialized();
    _fastSingleEqField = null;
    _fastSingleEqVal = null;
    final condition = _buildCondition(field, operator, value);

    // If the current node is an AND node, add a new leaf node as a child
    if (_current!.type == NodeType.and) {
      final leafNode = ConditionNode(type: NodeType.leaf, condition: condition);
      _current!.children.add(leafNode);
    }
    // If the current node is an OR node, special handling is needed to maintain correct grouping
    else if (_current!.type == NodeType.or) {
      // Create a new AND node under the OR node
      final andNode = ConditionNode(type: NodeType.and);

      // If the last child node of the OR node is a leaf node, it can be merged with the new condition into an AND node
      if (_current!.children.isNotEmpty &&
          _current!.children.last.type == NodeType.leaf) {
        // Remove the last leaf node
        final lastLeaf = _current!.children.removeLast();

        // Add the leaf node to the new AND node
        andNode.children.add(lastLeaf);

        // Add the new condition as a leaf node
        final leafNode =
            ConditionNode(type: NodeType.leaf, condition: condition);
        andNode.children.add(leafNode);

        // Add the AND node to the OR node
        _current!.children.add(andNode);

        // Update the current node to the AND node, so that subsequent conditions can be added to this AND group correctly
        _current = andNode;
      } else {
        // If the last child node is not a leaf node or has no children, add a new leaf node directly
        final leafNode =
            ConditionNode(type: NodeType.leaf, condition: condition);
        _current!.children.add(leafNode);
      }
    }
    // If the current node is a leaf node, create a new AND node as a parent
    else if (_current!.type == NodeType.leaf) {
      // Find the parent node of the leaf node
      final parent = _findParent(_root!, _current!);

      if (parent != null) {
        // Create a new AND node
        final andNode = ConditionNode(type: NodeType.and);

        // Replace the current leaf node with the AND node
        final index = parent.children.indexOf(_current!);
        parent.children[index] = andNode;

        // Add
        final newLeaf =
            ConditionNode(type: NodeType.leaf, condition: condition);
        andNode.children.add(newLeaf);

        // Update the current node to the AND node
        _current = andNode;
      }
    }

    return this;
  }

  /// Find the parent node of a node
  ConditionNode? _findParent(ConditionNode root, ConditionNode target) {
    for (var child in root.children) {
      if (child == target) {
        return root;
      }

      final parent = _findParent(child, target);
      if (parent != null) {
        return parent;
      }
    }

    return null;
  }

  /// Start an OR condition
  QueryCondition or() {
    _ensureTreeInitialized();
    // If the current node is already an OR node, keep using that node
    if (_current!.type == NodeType.or) {
      return this;
    }

    // If the current node is a leaf node
    if (_current!.type == NodeType.leaf) {
      // Find the parent node of the current node
      final parent = _findParent(_root!, _current!);

      if (parent != null) {
        // If the parent node is an AND node, we need to create a new OR node
        if (parent.type == NodeType.and) {
          // Create a new OR node
          final orNode = ConditionNode(type: NodeType.or);

          // Remove the current leaf node from the parent node
          final index = parent.children.indexOf(_current!);
          if (index >= 0) {
            parent.children.removeAt(index);

            // Add the leaf node as a child of the OR node
            orNode.children.add(_current!);

            // Add the OR node to the parent AND node
            parent.children.add(orNode);

            // Update the current node to the OR node
            _current = orNode;
          }
        }
        // If the parent node is an OR node, we don't need to create a new OR node
        else if (parent.type == NodeType.or) {
          // Update the current node to the parent OR node
          _current = parent;
        }
      }
    }
    // If the current node is an AND node
    else if (_current!.type == NodeType.and) {
      // Find the parent node of the current AND node
      final parent = _findParent(_root!, _current!);

      if (parent != null) {
        // If the parent node is an AND node
        if (parent.type == NodeType.and) {
          // Create a new OR node
          final orNode = ConditionNode(type: NodeType.or);

          // Remove the current AND node from the parent node
          final index = parent.children.indexOf(_current!);
          if (index >= 0) {
            parent.children.removeAt(index);

            // Add the current AND node as a child of the OR node
            orNode.children.add(_current!);

            // Add the OR node to the parent AND node
            parent.children.add(orNode);

            // Update the current node to the OR node
            _current = orNode;
          }
        }
        // If the parent node is an OR node
        else if (parent.type == NodeType.or) {
          // Update the current node to the parent OR node
          _current = parent;
        }
      }
      // If there is no parent node (the current node is the root node)
      else if (_current == _root) {
        // Create a new OR node
        final orNode = ConditionNode(type: NodeType.or);

        // Move all child nodes to the OR node
        orNode.children.addAll(_current!.children);
        _current!.children.clear();

        // Add the OR node to the root node
        _root!.children.add(orNode);

        // Update the current node to the OR node
        _current = orNode;
      }
    }

    return this;
  }

  /// Add another condition as an AND condition
  QueryCondition condition(QueryCondition other) {
    if (other.isEmpty) return this;
    _ensureTreeInitialized();
    other._ensureTreeInitialized();

    // Clone the condition tree of other
    final otherRoot = other._root!.clone();

    // If the current condition is empty, use the condition tree of other
    if (isEmpty) {
      _root!.children.clear();
      for (var child in otherRoot.children) {
        _root!.children.add(child);
      }
      _current = _root;
      return this;
    }

    // If the current node is an OR node, special handling is needed
    if (_current!.type == NodeType.or) {
      // Create a new AND node
      final andNode = ConditionNode(type: NodeType.and);

      // Add the conditions of other to the AND node
      if (otherRoot.children.length == 1 &&
          otherRoot.children[0].type == NodeType.and) {
        // If other is a single AND node, use its children directly
        andNode.children.addAll(otherRoot.children[0].children);
      } else {
        // Otherwise, add the entire other as a child
        andNode.children.add(otherRoot);
      }

      // Add the AND node to the OR node, not directly to otherRoot
      _current!.children.add(andNode);

      // Update the current node to the new AND node, so that subsequent conditions will be added to this AND group
      _current = andNode;

      return this;
    }

    // If the current node is a leaf node, create a new AND node
    if (_current!.type == NodeType.leaf) {
      final andNode = ConditionNode(type: NodeType.and);

      // Find the parent node of the current node
      final parent = _findParent(_root!, _current!);

      if (parent != null) {
        // Replace the current node with the AND node in the parent node
        final index = parent.children.indexOf(_current!);
        parent.children[index] = andNode;

        // Add the current node as a child of the AND node
        andNode.children.add(_current!);

        // Update the current node to the AND node
        _current = andNode;
      }
    }

    // Now the current node should be an AND node

    // Add the conditions of other as a whole as a child node
    // This ensures that the entire condition structure of other is treated as a single "bracket"
    if (otherRoot.children.length == 1 &&
        otherRoot.children[0].type == NodeType.and) {
      // If other is a single AND node, its children can be added directly to avoid unnecessary nesting
      for (var child in otherRoot.children[0].children) {
        _current!.children.add(child);
      }
    } else {
      // Otherwise, add the entire other as a child
      _current!.children.add(otherRoot);
    }

    return this;
  }

  /// Add another condition as an OR condition
  QueryCondition orCondition(QueryCondition other) {
    if (other.isEmpty) return this;
    _ensureTreeInitialized();
    other._ensureTreeInitialized();

    // First call or() to ensure that the current node uses OR connection
    or();

    // If the current node is an OR node
    if (_current!.type == NodeType.or) {
      // Directly access the root node structure of other
      final otherRoot = other._root!;

      // If other is a simple condition (the root node has only one child)
      if (otherRoot.children.length == 1) {
        // Use clone to create a copy of the child nodes to prevent modifying the original conditions
        _current!.children.add(otherRoot.children[0].clone());
      } else {
        // For complex conditions, the entire structure needs to be cloned
        _current!.children.add(otherRoot.clone());
      }
    } else {
      final orNode = ConditionNode(type: NodeType.or);

      // Add the current node as a child of the OR node
      orNode.children.add(_current!);

      // Add the cloned root node of other as a child of the OR node
      orNode.children.add(other._root!.clone());

      // Replace the root node
      _root!.children.clear();
      _root!.children.add(orNode);

      // Update the current node to the OR node
      _current = orNode;
    }

    return this;
  }

  Map<String, dynamic>? _cachedBuiltMap;

  /// Build the query condition
  Map<String, dynamic> build() {
    if (_cachedBuiltMap != null) return _cachedBuiltMap!;
    if (_conditionCount == 1 && _fastSingleEqField != null && _root == null) {
      return _cachedBuiltMap = _buildCondition(
          _fastSingleEqField!, _singleOp ?? '=', _fastSingleEqVal);
    }
    if (_root == null) return _cachedBuiltMap = const <String, dynamic>{};
    // Optimize the condition tree, merge unnecessary nested nodes
    _optimizeTree(_root!);

    // Build the final condition structure
    return _cachedBuiltMap = _nodeToCondition(_root!);
  }

  /// Optimize the condition tree
  void _optimizeTree(ConditionNode node) {
    // First recursively optimize all child nodes
    for (int i = 0; i < node.children.length; i++) {
      _optimizeTree(node.children[i]);
    }

    // Remove empty AND/OR nodes
    node.children.removeWhere((child) =>
        (child.type == NodeType.and || child.type == NodeType.or) &&
        child.children.isEmpty);

    // Merge same type parent and child nodes
    // For example, if an AND node has only one AND child node, the child's children can be moved directly to the parent node
    if (node.children.length == 1 &&
        node.children[0].type == node.type &&
        node.type != NodeType.leaf) {
      final child = node.children[0];
      node.children.clear();
      node.children.addAll(child.children);
    }
  }

  /// Convert the node to a condition structure
  Map<String, dynamic> _nodeToCondition(ConditionNode node) {
    // Handle leaf nodes
    if (node.type == NodeType.leaf) {
      return node.condition;
    }

    // If the node has no children, return an empty object
    if (node.children.isEmpty) {
      return {};
    }

    // If there is only one child node, return the condition of that child node
    if (node.children.length == 1) {
      return _nodeToCondition(node.children[0]);
    }

    // Handle AND/OR nodes
    final List<Map<String, dynamic>> childConditions = [];
    for (var child in node.children) {
      childConditions.add(_nodeToCondition(child));
    }

    // Create a condition structure based on the node type
    if (node.type == NodeType.and) {
      return {'AND': childConditions};
    } else if (node.type == NodeType.or) {
      return {'OR': childConditions};
    }

    // Default case (should not reach here)
    return {};
  }

  /// Build basic conditions
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
          field: {operatorStr: value}
        };
      case 'BETWEEN':
        return {
          field: {
            'BETWEEN': {'start': value[0], 'end': value[1]}
          }
        };
    }
    return {
      field: {operatorStr: value}
    };
  }

  /// Check if the condition is empty
  bool get isEmpty {
    if (_conditionCount == 0 && _root == null) return true;
    if (_root == null) return _conditionCount == 0;
    return !_hasMeaningfulPredicate(_root!);
  }

  /// Determine if the condition tree contains any effective predicate
  /// (leaf node with non-empty condition).
  bool _hasMeaningfulPredicate(ConditionNode node) {
    // A leaf node is meaningful only when it carries a condition
    if (node.type == NodeType.leaf) {
      return node.condition.isNotEmpty;
    }
    // For AND/OR nodes, check children recursively
    for (final child in node.children) {
      if (_hasMeaningfulPredicate(child)) {
        return true;
      }
    }
    return false;
  }

  /// orWhere condition - add OR logic
  QueryCondition orWhere(String field, String operator, dynamic value) {
    return or().where(field, operator, value);
  }

  /// whereIn condition
  QueryCondition whereIn(String field, List values) {
    return where(field, 'IN', values);
  }

  /// whereNotIn condition
  QueryCondition whereNotIn(String field, List values) {
    return where(field, 'NOT IN', values);
  }

  /// whereBetween condition
  QueryCondition whereBetween(String field, dynamic start, dynamic end) {
    return where(field, 'BETWEEN', [start, end]);
  }

  /// whereNull condition
  QueryCondition whereNull(String field) {
    return where(field, 'IS', null);
  }

  /// whereNotNull condition
  QueryCondition whereNotNull(String field) {
    return where(field, 'IS NOT', null);
  }

  /// whereLike condition
  QueryCondition whereLike(String field, String pattern) {
    return where(field, 'LIKE', pattern);
  }

  /// whereNotLike condition
  QueryCondition whereNotLike(String field, String pattern) {
    return where(field, 'NOT LIKE', pattern);
  }

  /// Set the condition to be any of the specified values
  QueryCondition whereContainsAny(String field, List values) {
    if (values.isEmpty) return this;

    // Create a nested OR condition, where any value matches
    final condition = QueryCondition();

    for (var i = 0; i < values.length; i++) {
      if (i > 0) condition.or();
      condition.where(field, 'LIKE', '%${values[i]}%');
    }

    return orCondition(condition);
  }

  /// Equal value condition
  QueryCondition whereEqual(String field, dynamic value) {
    return where(field, '=', value);
  }

  /// Not equal value condition
  QueryCondition whereNotEqual(String field, dynamic value) {
    return where(field, '!=', value);
  }

  /// Greater than condition
  QueryCondition whereGreaterThan(String field, dynamic value) {
    return where(field, '>', value);
  }

  /// Greater than or equal condition
  QueryCondition whereGreaterThanOrEqualTo(String field, dynamic value) {
    return where(field, '>=', value);
  }

  /// Less than condition
  QueryCondition whereLessThan(String field, dynamic value) {
    return where(field, '<', value);
  }

  /// Less than or equal condition
  QueryCondition whereLessThanOrEqualTo(String field, dynamic value) {
    return where(field, '<=', value);
  }

  /// Contains condition
  ///
  /// **[PERFORMANCE WARNING]** Full substring matching ('%value%') will ALWAYS trigger a
  /// full table scan even if an index is present. For large-scale data, consider using
  QueryCondition whereContains(String field, String value) {
    return where(field, 'LIKE', '%$value%');
  }

  /// Not contains condition
  ///
  /// **[PERFORMANCE WARNING]** Full substring matching ('%value%') will ALWAYS trigger a
  /// full table scan.
  QueryCondition whereNotContains(String field, String value) {
    return where(field, 'NOT LIKE', '%$value%');
  }

  /// Starts with condition (literal prefix; `%` / `_` in [prefix] are escaped).
  ///
  /// Still emitted as a `LIKE` predicate so query plans/results stay consistent.
  /// Engine path can push a simple escaped prefix LIKE down to a PK/index range.
  QueryCondition whereStartsWith(String field, String prefix) {
    if (prefix.isEmpty) {
      return where(field, 'LIKE', '%');
    }
    return where(field, 'LIKE', '${ValueMatcher.escapeLikeLiteral(prefix)}%');
  }

  /// Ends with condition
  ///
  /// **[PERFORMANCE WARNING]** Suffix matching ('%suffix') will ALWAYS trigger a
  /// full table scan even if an index is present.
  QueryCondition whereEndsWith(String field, String suffix) {
    return where(field, 'LIKE', '%$suffix');
  }

  /// whereEmpty condition - matches null or empty string
  QueryCondition whereEmpty(String field) {
    final sub = QueryCondition();
    sub.whereNull(field).or().where(field, '=', '');
    return condition(sub);
  }

  /// whereNotEmpty condition - matches non-null and non-empty string
  QueryCondition whereNotEmpty(String field) {
    return whereNotNull(field).where(field, '!=', '');
  }

  /// whereTrue condition - matches true
  QueryCondition whereTrue(String field) {
    return where(field, '=', true);
  }

  /// whereFalse condition - matches false
  QueryCondition whereFalse(String field) {
    return where(field, '=', false);
  }

  /// set order by (asc)
  QueryCondition orderByAsc(String field) {
    _orderBy = _orderBy ?? [];
    _orderBy!.add(field);
    return this;
  }

  /// set order by (desc)
  QueryCondition orderByDesc(String field) {
    _orderBy = _orderBy ?? [];
    _orderBy!.add('-$field');
    return this;
  }

  /// set limit
  QueryCondition limit(int value) {
    _limit = value;
    return this;
  }

  /// set offset
  QueryCondition offset(int value) {
    _offset = value;
    _cursor = null;
    return this;
  }

  /// set cursor
  QueryCondition cursor(String? value) {
    _cursor = value;
    if (value != null && value.isNotEmpty) {
      _offset = null;
    }
    return this;
  }

  /// Internal method: apply order by, limit, offset settings to ChainBuilder
  void $internalApplySettings(
      List<String>? Function() getOrderBy,
      void Function(List<String>) setOrderBy,
      void Function(int) setLimit,
      void Function(int) setOffset,
      void Function(String?) setCursor) {
    if (_orderBy != null && _orderBy!.isNotEmpty) {
      final existingOrderBy = getOrderBy() ?? [];
      existingOrderBy.addAll(_orderBy!);
      setOrderBy(existingOrderBy);
    }

    if (_limit != null) {
      setLimit(_limit!);
    }

    if (_offset != null) {
      setOffset(_offset!);
    }

    if (_cursor != null) {
      setCursor(_cursor);
    }
  }

  /// Normalizes all values in the condition tree according to the table schemas.
  void normalize(Map<String, TableSchema> schemas, String mainTableName) {
    if (isEmpty || _isNormalized) return;
    _isNormalized = true;
    if (_conditionCount == 1 && _fastSingleEqField != null && _root == null) {
      final fieldSchema =
          _getFieldSchema(_fastSingleEqField!, schemas, mainTableName);
      if (fieldSchema != null) {
        _fastSingleEqVal = fieldSchema.convertValue(_fastSingleEqVal);
      }
      return;
    }
    if (_root != null) {
      _normalizeNode(_root!, schemas, mainTableName);
    }
  }

  void _normalizeNode(ConditionNode node, Map<String, TableSchema> schemas,
      String mainTableName) {
    if (node.type == NodeType.leaf && node.condition.isNotEmpty) {
      node.condition =
          _normalizeConditionMap(node.condition, schemas, mainTableName);
    } else {
      for (final child in node.children) {
        _normalizeNode(child, schemas, mainTableName);
      }
    }
  }

  Map<String, dynamic> _normalizeConditionMap(Map<String, dynamic> conditionMap,
      Map<String, TableSchema> schemas, String mainTableName) {
    final newMap = <String, dynamic>{};
    conditionMap.forEach((key, value) {
      if (key == 'AND' || key == 'OR') {
        if (value is List) {
          newMap[key] = value
              .map((e) => _normalizeConditionMap(
                  e as Map<String, dynamic>, schemas, mainTableName))
              .toList();
        } else {
          newMap[key] = value;
        }
      } else {
        // This is a field condition
        final fieldSchema = _getFieldSchema(key, schemas, mainTableName);
        if (fieldSchema != null) {
          newMap[key] = _convertConditionValue(value, fieldSchema);
        } else {
          newMap[key] = value; // Keep original if no schema found
        }
      }
    });
    return newMap;
  }

  dynamic _convertConditionValue(dynamic value, FieldSchema fieldSchema) {
    if (value is Map) {
      // It's an operator map like {'>': 10} or {'BETWEEN': {'start': 1, 'end': 5}}
      final newMap = <String, dynamic>{};
      value.forEach((op, opValue) {
        if (op.toUpperCase() == 'BETWEEN' && opValue is Map) {
          newMap[op] = {
            'start': fieldSchema.convertValue(opValue['start']),
            'end': fieldSchema.convertValue(opValue['end']),
          };
        } else if (op.toUpperCase() == 'IN' || op.toUpperCase() == 'NOT IN') {
          if (opValue is List) {
            newMap[op] =
                opValue.map((v) => fieldSchema.convertValue(v)).toList();
          } else {
            newMap[op] = opValue;
          }
        } else {
          newMap[op] = fieldSchema.convertValue(opValue);
        }
      });
      return newMap;
    } else {
      // It's a direct equality value, e.g., where('name', 'John')
      return fieldSchema.convertValue(value);
    }
  }

  FieldSchema? _getFieldSchema(
      String field, Map<String, TableSchema> schemas, String mainTableName) {
    final tableName =
        field.contains('.') ? field.split('.').first : mainTableName;
    final schema = schemas[tableName];
    if (schema == null) return null;

    final fieldName = field.contains('.') ? field.split('.').last : field;

    if (fieldName == schema.primaryKey) {
      return FieldSchema(
          name: schema.primaryKey,
          type: schema.primaryKeyConfig.getDefaultDataType());
    }

    try {
      return schema.fields.firstWhere((f) => f.name == fieldName);
    } catch (_) {
      return null;
    }
  }

  /// Fast check if this query condition is a single equality condition:
  /// `where field = value` or `where field == value` (with no other conditions, no OR).
  ///
  /// Returns a record `(field: String, value: dynamic)?` if it matches, or null otherwise.
  /// Results are memoized in O(1) time after the first calculation.
  ({String field, dynamic value})? extractSingleEquality() {
    if (_hasCalculatedSingleEq) return _cachedSingleEq;
    _hasCalculatedSingleEq = true;

    if (_conditionCount == 1 &&
        _fastSingleEqField != null &&
        (_singleOp == null || _singleOp == '=' || _singleOp == '==')) {
      return _cachedSingleEq =
          (field: _fastSingleEqField!, value: _fastSingleEqVal);
    }
    if (_root == null) return _cachedSingleEq = null;
    ConditionNode? leaf;
    if (_root!.type == NodeType.leaf) {
      leaf = _root;
    } else if (_root!.type == NodeType.and) {
      if (_root!.children.length == 1) {
        final c1 = _root!.children.first;
        if (c1.type == NodeType.leaf) {
          leaf = c1;
        } else if (c1.type == NodeType.and &&
            c1.children.length == 1 &&
            c1.children.first.type == NodeType.leaf) {
          leaf = c1.children.first;
        }
      }
    }

    if (leaf == null || leaf.condition.isEmpty) return _cachedSingleEq = null;
    final cond = leaf.condition;
    if (cond.length != 1) return _cachedSingleEq = null;

    final entry = cond.entries.first;
    final field = entry.key;
    if (field == 'AND' || field == 'OR') return _cachedSingleEq = null;

    final rawVal = entry.value;
    if (rawVal is Map) {
      if (rawVal.length == 1 && rawVal.containsKey('=')) {
        return _cachedSingleEq = (field: field, value: rawVal['=']);
      }
      return _cachedSingleEq = null;
    } else {
      return _cachedSingleEq = (field: field, value: rawVal);
    }
  }
}
