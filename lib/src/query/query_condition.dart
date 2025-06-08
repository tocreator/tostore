import '../handler/logger.dart';
import '../handler/value_comparator.dart';

/// Query Condition Builder
class QueryCondition {
  // Condition tree root node
  final _ConditionNode _root = _ConditionNode(type: _NodeType.and);
  // Current active node (for building conditions)
  _ConditionNode _current;

  /// Create a new query condition builder
  QueryCondition() : _current = _ConditionNode(type: _NodeType.and) {
    _root.children.add(_current);
  }

  /// Create a copy of a query condition
  QueryCondition clone() {
    final copy = QueryCondition();

    // Clear default created nodes
    copy._root.children.clear();

    // Deep copy the entire condition tree
    copy._root.type = _root.type;
    for (var child in _root.children) {
      copy._root.children.add(child.clone());
    }

    // Set the current node to the corresponding node in the copied tree
    if (_current == _root) {
      copy._current = copy._root;
    } else {
      // Find the corresponding current node position in the copied tree
      copy._current =
          _findCorrespondingNode(copy._root, _root, _current) ?? copy._root;
    }

    return copy;
  }

  /// Find the corresponding node in two trees
  _ConditionNode? _findCorrespondingNode(
      _ConditionNode newRoot, _ConditionNode oldRoot, _ConditionNode target) {
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
    final condition = _buildCondition(field, operator, value);

    // If the current node is an AND node, add a new leaf node as a child
    if (_current.type == _NodeType.and) {
      final leafNode =
          _ConditionNode(type: _NodeType.leaf, condition: condition);
      _current.children.add(leafNode);
    }
    // If the current node is an OR node, special handling is needed to maintain correct grouping
    else if (_current.type == _NodeType.or) {
      // Create a new AND node under the OR node
      final andNode = _ConditionNode(type: _NodeType.and);

      // If the last child node of the OR node is a leaf node, it can be merged with the new condition into an AND node
      if (_current.children.isNotEmpty &&
          _current.children.last.type == _NodeType.leaf) {
        // Remove the last leaf node
        final lastLeaf = _current.children.removeLast();

        // Add the leaf node to the new AND node
        andNode.children.add(lastLeaf);

        // Add the new condition as a leaf node
        final leafNode =
            _ConditionNode(type: _NodeType.leaf, condition: condition);
        andNode.children.add(leafNode);

        // Add the AND node to the OR node
        _current.children.add(andNode);

        // Update the current node to the AND node, so that subsequent conditions can be added to this AND group correctly
        _current = andNode;
      } else {
        // If the last child node is not a leaf node or has no children, add a new leaf node directly
        final leafNode =
            _ConditionNode(type: _NodeType.leaf, condition: condition);
        _current.children.add(leafNode);
      }
    }
    // If the current node is a leaf node, create a new AND node as a parent
    else if (_current.type == _NodeType.leaf) {
      // Find the parent node of the leaf node
      final parent = _findParent(_root, _current);

      if (parent != null) {
        // Create a new AND node
        final andNode = _ConditionNode(type: _NodeType.and);

        // Replace the current leaf node with the AND node
        final index = parent.children.indexOf(_current);
        parent.children[index] = andNode;

        // Add
        final newLeaf =
            _ConditionNode(type: _NodeType.leaf, condition: condition);
        andNode.children.add(newLeaf);

        // Update the current node to the AND node
        _current = andNode;
      }
    }

    return this;
  }

  /// Find the parent node of a node
  _ConditionNode? _findParent(_ConditionNode root, _ConditionNode target) {
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
    // If the current node is already an OR node, keep using that node
    if (_current.type == _NodeType.or) {
      return this;
    }

    // If the current node is a leaf node
    if (_current.type == _NodeType.leaf) {
      // Find the parent node of the current node
      final parent = _findParent(_root, _current);

      if (parent != null) {
        // If the parent node is an AND node, we need to create a new OR node
        if (parent.type == _NodeType.and) {
          // Create a new OR node
          final orNode = _ConditionNode(type: _NodeType.or);

          // Remove the current leaf node from the parent node
          final index = parent.children.indexOf(_current);
          if (index >= 0) {
            parent.children.removeAt(index);

            // Add the leaf node as a child of the OR node
            orNode.children.add(_current);

            // Add the OR node to the parent AND node
            parent.children.add(orNode);

            // Update the current node to the OR node
            _current = orNode;
          }
        }
        // If the parent node is an OR node, we don't need to create a new OR node
        else if (parent.type == _NodeType.or) {
          // Update the current node to the parent OR node
          _current = parent;
        }
      }
    }
    // If the current node is an AND node
    else if (_current.type == _NodeType.and) {
      // Find the parent node of the current AND node
      final parent = _findParent(_root, _current);

      if (parent != null) {
        // If the parent node is an AND node
        if (parent.type == _NodeType.and) {
          // Create a new OR node
          final orNode = _ConditionNode(type: _NodeType.or);

          // Remove the current AND node from the parent node
          final index = parent.children.indexOf(_current);
          if (index >= 0) {
            parent.children.removeAt(index);

            // Add the current AND node as a child of the OR node
            orNode.children.add(_current);

            // Add the OR node to the parent AND node
            parent.children.add(orNode);

            // Update the current node to the OR node
            _current = orNode;
          }
        }
        // If the parent node is an OR node
        else if (parent.type == _NodeType.or) {
          // Update the current node to the parent OR node
          _current = parent;
        }
      }
      // If there is no parent node (the current node is the root node)
      else if (_current == _root) {
        // Create a new OR node
        final orNode = _ConditionNode(type: _NodeType.or);

        // Move all child nodes to the OR node
        orNode.children.addAll(_current.children);
        _current.children.clear();

        // Add the OR node to the root node
        _current.children.add(orNode);

        // Update the current node to the OR node
        _current = orNode;
      }
    }

    return this;
  }

  /// Add another condition as an AND condition
  QueryCondition andCondition(QueryCondition other) {
    if (other.isEmpty) return this;

    // Clone the condition tree of other
    final otherRoot = other._root.clone();

    // If the current condition is empty, use the condition tree of other
    if (isEmpty) {
      _root.children.clear();
      for (var child in otherRoot.children) {
        _root.children.add(child);
      }
      _current = _root;
      return this;
    }

    // If the current node is an OR node, special handling is needed
    if (_current.type == _NodeType.or) {
      // Create a new AND node
      final andNode = _ConditionNode(type: _NodeType.and);

      // Add the conditions of other to the AND node
      if (otherRoot.children.length == 1 &&
          otherRoot.children[0].type == _NodeType.and) {
        // If other is a single AND node, use its children directly
        andNode.children.addAll(otherRoot.children[0].children);
      } else {
        // Otherwise, add the entire other as a child
        andNode.children.add(otherRoot);
      }

      // Add the AND node to the OR node, not directly to otherRoot
      _current.children.add(andNode);

      // Update the current node to the new AND node, so that subsequent conditions will be added to this AND group
      _current = andNode;

      return this;
    }

    // If the current node is a leaf node, create a new AND node
    if (_current.type == _NodeType.leaf) {
      final andNode = _ConditionNode(type: _NodeType.and);

      // Find the parent node of the current node
      final parent = _findParent(_root, _current);

      if (parent != null) {
        // Replace the current node with the AND node in the parent node
        final index = parent.children.indexOf(_current);
        parent.children[index] = andNode;

        // Add the current node as a child of the AND node
        andNode.children.add(_current);

        // Update the current node to the AND node
        _current = andNode;
      }
    }

    // Now the current node should be an AND node

    // Add the conditions of other as a whole as a child node
    // This ensures that the entire condition structure of other is treated as a single "bracket"
    if (otherRoot.children.length == 1 &&
        otherRoot.children[0].type == _NodeType.and) {
      // If other is a single AND node, its children can be added directly to avoid unnecessary nesting
      for (var child in otherRoot.children[0].children) {
        _current.children.add(child);
      }
    } else {
      // Otherwise, add the entire other as a child
      _current.children.add(otherRoot);
    }

    return this;
  }

  /// Add another condition as an OR condition
  QueryCondition orCondition(QueryCondition other) {
    if (other.isEmpty) return this;

    // First call or() to ensure that the current node uses OR connection
    or();

    // If the current node is an OR node
    if (_current.type == _NodeType.or) {
      // Directly access the root node structure of other
      final otherRoot = other._root;

      // If other is a simple condition (the root node has only one child)
      if (otherRoot.children.length == 1) {
        // Use clone to create a copy of the child nodes to prevent modifying the original conditions
        _current.children.add(otherRoot.children[0].clone());
      } else {
        // For complex conditions, the entire structure needs to be cloned
        _current.children.add(otherRoot.clone());
      }
    } else {
      // Theoretically, this should not be reached, because or() should ensure that the current node is an OR node
      // But for safety, add a backup logic

      final orNode = _ConditionNode(type: _NodeType.or);

      // Add the current node as a child of the OR node
      orNode.children.add(_current);

      // Add the cloned root node of other as a child of the OR node
      orNode.children.add(other._root.clone());

      // Replace the root node
      _root.children.clear();
      _root.children.add(orNode);

      // Update the current node to the OR node
      _current = orNode;
    }

    return this;
  }

  /// Build the query condition
  Map<String, dynamic> build() {
    // Optimize the condition tree, merge unnecessary nested nodes
    _optimizeTree(_root);

    // Build the final condition structure
    return _nodeToCondition(_root);
  }

  /// Optimize the condition tree
  void _optimizeTree(_ConditionNode node) {
    // First recursively optimize all child nodes
    for (int i = 0; i < node.children.length; i++) {
      _optimizeTree(node.children[i]);
    }

    // Remove empty AND/OR nodes
    node.children.removeWhere((child) =>
        (child.type == _NodeType.and || child.type == _NodeType.or) &&
        child.children.isEmpty);

    // Merge same type parent and child nodes
    // For example, if an AND node has only one AND child node, the child's children can be moved directly to the parent node
    if (node.children.length == 1 &&
        node.children[0].type == node.type &&
        node.type != _NodeType.leaf) {
      final child = node.children[0];
      node.children.clear();
      node.children.addAll(child.children);
    }
  }

  /// Convert the node to a condition structure
  Map<String, dynamic> _nodeToCondition(_ConditionNode node) {
    // Handle leaf nodes
    if (node.type == _NodeType.leaf) {
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
    if (node.type == _NodeType.and) {
      return {'AND': childConditions};
    } else if (node.type == _NodeType.or) {
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

  /// Reset the query condition
  QueryCondition clear() {
    _root.children.clear();
    _current = _ConditionNode(type: _NodeType.and);
    _root.children.add(_current);
    return this;
  }

  /// Check if the condition is empty
  bool get isEmpty {
    return _root.children.isEmpty ||
        (_root.children.length == 1 &&
            _root.children[0].type != _NodeType.leaf &&
            _root.children[0].children.isEmpty);
  }

  /// Check if the record matches the condition
  bool matches(Map<String, dynamic> record) {
    try {
      // If there is no condition, match all records
      if (isEmpty) {
        return true;
      }

      // Directly use the condition tree for matching, rather than building an intermediate condition Map
      return _matchNode(_root, record);
    } catch (e) {
      Logger.error('condition matching failed: $e',
          label: 'QueryCondition.matches');
      return false;
    }
  }

  /// Match the node and its children
  bool _matchNode(_ConditionNode node, Map<String, dynamic> record) {
    // Handle leaf nodes
    if (node.type == _NodeType.leaf) {
      return _matchAllConditions(record, node.condition);
    }
    
    // Handle custom function nodes
    if (node.type == _NodeType.custom) {
      if (node.customMatcher != null) {
        return node.customMatcher!(record);
      }
      return false;
    }

    // If the node has no children, match all records
    if (node.children.isEmpty) {
      return true;
    }

    // Handle AND nodes
    if (node.type == _NodeType.and) {
      // All child nodes must match
      for (var child in node.children) {
        if (!_matchNode(child, record)) {
          return false;
        }
      }
      return true;
    }

    // Handle OR nodes
    if (node.type == _NodeType.or) {
      // Any child node matches
      for (var child in node.children) {
        if (_matchNode(child, record)) {
          return true;
        }
      }
      return false;
    }

    // Default case (should not reach here)
    return false;
  }

  /// Match all conditions
  bool _matchAllConditions(
      Map<String, dynamic> record, Map<String, dynamic> conditions) {
    // Handle special AND/OR conditions
    if (conditions.containsKey('AND')) {
      final andConditions = conditions['AND'] as List;
      return andConditions.every((condition) =>
          _matchAllConditions(record, condition as Map<String, dynamic>));
    }

    if (conditions.containsKey('OR')) {
      final orConditions = conditions['OR'] as List;
      return orConditions.any((condition) =>
          _matchAllConditions(record, condition as Map<String, dynamic>));
    }

    // Handle normal field conditions
    for (var entry in conditions.entries) {
      final field = entry.key;
      final value = entry.value;

      // Handle fields with table name prefixes (e.g. 'users.id')
      dynamic fieldValue;
      if (field.contains('.')) {
        // First try to match fields with prefixes directly
        if (record.containsKey(field)) {
          fieldValue = record[field];
        } else {
          // Try
          final parts = field.split('.');
          final underscoreField = '${parts[0]}_${parts[1]}';
          if (record.containsKey(underscoreField)) {
            fieldValue = record[underscoreField];
          } else {
            // If not found, try to get the field value without prefix
            final fieldName = parts[1];
            fieldValue = record[fieldName];
          }
        }
      } else {
        // Normal field without table name prefix
        fieldValue = record[field];
      }

      // Handle the special case where the field does not exist
      if (fieldValue == null && !record.containsKey(field)) {
        // Special case: IS NULL condition
        if (value is Map &&
            (value.containsKey('IS') || value.containsKey('IS NOT'))) {
          if ((value.containsKey('IS') && value['IS'] == null) ||
              (value.containsKey('IS NOT') && value['IS NOT'] != null)) {
            continue; // If the field does not exist, the IS NULL condition is satisfied
          }
        }

        // Check if any variant with table prefix exists
        bool prefixFound = false;
        for (String key in record.keys) {
          if (key.contains('.') && key.endsWith('.$field')) {
            fieldValue = record[key];
            prefixFound = true;
            break;
          } else if (key.contains('_') && key.endsWith('_$field')) {
            fieldValue = record[key];
            prefixFound = true;
            break;
          }
        }

        if (!prefixFound) {
          return false; // The field does not exist
        }
      }

      if (!_matchSingleCondition(fieldValue, value)) {
        return false;
      }
    }
    return true;
  }

  /// Match a single condition
  bool _matchSingleCondition(dynamic value, dynamic condition) {
    if (condition == null) return value == null;

    if (condition is Map) {
      // Handle operator conditions
      bool matchedAny = false;
      for (var entry in condition.entries) {
        final operator = entry.key;
        final compareValue = entry.value;

        bool matches = false;
        switch (operator) {
          case '=':
            // Use ValueComparator for intelligent type comparison
            matches = ValueComparator.compare(value, compareValue) == 0;
            break;
          case '!=':
          case '<>':
            // Use ValueComparator for inequality comparison
            matches = ValueComparator.compare(value, compareValue) != 0;
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
            // Use ValueComparator to enhance the IN operator
            if (value == null) return false;

            // Check if any value in the list equals the field value
            for (var item in compareValue) {
              if (ValueComparator.compare(value, item) == 0) {
                matches = true;
                break;
              }
            }
            break;
          case 'NOT IN':
            if (compareValue is! List) return false;
            // Use ValueComparator to enhance the NOT IN operator
            if (value == null) return true; // NULL NOT IN any list is true

            matches = true; // Assume true until proven false

            // Check if any value in the list equals the field value
            for (var item in compareValue) {
              if (ValueComparator.compare(value, item) == 0) {
                matches = false;
                break;
              }
            }
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
            matches =
                ValueComparator.matchesPattern(value.toString(), compareValue);
            break;
          case 'NOT LIKE':
            if (value == null || compareValue is! String) return false;
            matches =
                !ValueComparator.matchesPattern(value.toString(), compareValue);
            break;
          case 'IS':
            matches = value == null;
            break;
          case 'IS NOT':
            matches = value != null;
            break;
          default:
            Logger.error('Unknown operator: $operator',
                label: 'QueryCondition._matchSingleCondition');
            return false;
        }

        if (matches) {
          matchedAny = true;
          break;
        }
      }
      return matchedAny;
    }

    // Use ValueComparator for simple equality conditions
    return ValueComparator.compare(value, condition) == 0;
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

  /// Contains condition
  QueryCondition whereContains(String field, String value) {
    return where(field, 'LIKE', '%$value%');
  }

  /// Not contains condition
  QueryCondition whereNotContains(String field, String value) {
    return where(field, 'NOT LIKE', '%$value%');
  }



  /// Add a custom condition using a user-provided function
  /// Example:
  /// whereCustom((record) => record['is_active'] == true)
  QueryCondition whereCustom(bool Function(Map<String, dynamic>) record) {
    final customNode = _ConditionNode(
      type: _NodeType.custom,
      customMatcher: record,
    );
    
    // If the current node is an AND node, add the custom node as a child
    if (_current.type == _NodeType.and) {
      _current.children.add(customNode);
    }
    // If the current node is an OR node
    else if (_current.type == _NodeType.or) {
      _current.children.add(customNode);
    }
    // If the current node is a leaf or custom node, create a new AND node as a parent
    else {
      // Find the parent node of the current node
      final parent = _findParent(_root, _current);
      
      if (parent != null) {
        // Create a new AND node
        final andNode = _ConditionNode(type: _NodeType.and);
        
        // Replace the current node with the AND node
        final index = parent.children.indexOf(_current);
        parent.children[index] = andNode;
        
        // Add the current node and the custom node as children of the AND node
        andNode.children.add(_current);
        andNode.children.add(customNode);
        
        // Update the current node to the AND node
        _current = andNode;
      }
    }
    
    return this;
  }

  /// Add a custom condition using a user-provided function with OR logic
  /// Example:
  /// orWhereCustom((record) => record['is_active'] == true)
  QueryCondition orWhereCustom(bool Function(Map<String, dynamic>) record) {
    return or().whereCustom(record);
  }
}

/// Node type enumeration
enum _NodeType {
  /// Leaf node, contains actual conditions
  leaf,

  /// AND operator node
  and,

  /// OR operator node
  or,
  
  /// Custom function node
  custom
}

/// Condition node class
class _ConditionNode {
  /// Node type
  _NodeType type;

  /// Condition content (only valid for leaf nodes)
  Map<String, dynamic> condition;
  
  /// Custom matcher function (only valid for custom nodes)
  bool Function(Map<String, dynamic>)? customMatcher;

  /// Child node list
  List<_ConditionNode> children;

  /// Create a condition node
  _ConditionNode({
    required this.type,
    this.condition = const {},
    this.customMatcher,
  }) : children = [];

  /// Create a deep copy of the node
  _ConditionNode clone() {
    final copy = _ConditionNode(
      type: type,
      condition: Map.from(condition),
      customMatcher: customMatcher,
    );

    // Recursively clone all child nodes
    for (final child in children) {
      copy.children.add(child.clone());
    }

    return copy;
  }
}
