import '../handler/logger.dart';
import 'dart:math' as math;

/// B+ tree implementation with enhanced safety and performance
class BPlusTree {
  /// Order of the B+ tree (maximum number of keys per node)
  final int order;

  /// Indicates whether the index has a uniqueness constraint
  final bool isUnique;

  /// Root node
  BPlusTreeNode? root;

  /// Safe node size limit, special handling is used when exceeded
  static const int maxSafeNodeSize = 500;

  /// Create a B+ tree
  BPlusTree({
    required this.order,
    this.isUnique = false,
  });

  /// Create a B+ tree from a serialized string
  factory BPlusTree.fromString(String data,
      {int order = 100, bool isUnique = false}) {
    final tree = BPlusTree(order: order, isUnique: isUnique);
    if (data.isEmpty) return tree;

    try {
      final lines = data.split('\n');

      // Process in batches to avoid handling too much data at once
      const batchSize = 1000;
      for (int i = 0; i < lines.length; i += batchSize) {
        final end = math.min(i + batchSize, lines.length);
        final batch = lines.sublist(i, end);

        for (var line in batch) {
          if (line.trim().isEmpty) continue;
          final parts = line.split('|');
          if (parts.length >= 2) {
            final key = deserializeValue(parts[0]);
            final values = deserializeValues(parts[1]);

            // Insert each value individually
            for (var value in values) {
              try {
                tree.insert(key, value);
              } catch (e) {
                Logger.error('Insertion failed: $e, key=$key, value=$value',
                    label: 'BPlusTree.fromString');
              }
            }
          }
        }

        // Add a tiny delay between batches to avoid memory spikes
        if (end < lines.length) {
          Future.delayed(Duration.zero);
        }
      }
    } catch (e) {
      Logger.error('Failed to load B+ tree from string: $e',
          label: 'BPlusTree.fromString');
    }
    return tree;
  }

  /// Serialize the B+ tree to a string
  String toStringHandle() {
    final buffer = StringBuffer();
    if (root == null) return '';

    // Start from the leftmost leaf node
    BPlusTreeNode? node = root;
    while (node != null && !node.isLeaf) {
      if (node.children.isEmpty) break;
      node = node.children[0];
    }

    // Traverse the leaf node chain
    while (node != null) {
      for (var i = 0; i < node.keys.length; i++) {
        if (i < node.values.length) {
          // Ensure index is valid
          buffer.write(serializeValue(node.keys[i]));
          buffer.write('|');
          buffer.write(serializeValues(node.values[i]));
          buffer.write('\n');
        }
      }
      node = node.next;
    }

    return buffer.toString();
  }

  /// Serialize a value to string
  static String serializeValue(dynamic value) {
    if (value == null) return '';

    if (value is num) return 'n:$value';
    if (value is bool) return 'b:$value';
    if (value is DateTime) return 'd:${value.toIso8601String()}';
    return 's:$value';
  }

  /// Serialize a list of values to string
  static String serializeValues(List<dynamic> values) {
    return values.map((v) => serializeValue(v)).join(',');
  }

  /// Deserialize a value from string
  static dynamic deserializeValue(String value) {
    if (value.isEmpty) return null;

    final type = value[0];
    final data = value.substring(2);

    switch (type) {
      case 'n': // number
        return num.tryParse(data);
      case 'b': // boolean
        return data == 'true';
      case 'd': // datetime
        return DateTime.tryParse(data);
      case 's': // string
        return data;
    }
  }

  /// Deserialize a list of values from string
  static List<dynamic> deserializeValues(String value) {
    if (value.isEmpty) return [];

    try {
      final values = value.split(',');
      return values
          .map((v) => deserializeValue(v))
          .where((v) => v != null)
          .toList();
    } catch (e) {
      Logger.error('Failed to deserialize values: $e',
          label: 'BPlusTree.deserializeValues');
      return [];
    }
  }

  /// Batch insert key-value pairs - method for improved efficiency
  Future<void> batchInsert(List<dynamic> keys, List<dynamic> values) async {
    if (keys.length != values.length) {
      throw ArgumentError('The number of keys and values must be the same');
    }

    // Process 500 items per batch to avoid memory spikes
    const batchSize = 500;
    for (int i = 0; i < keys.length; i += batchSize) {
      final end = math.min(i + batchSize, keys.length);

      // Process current batch
      for (int j = i; j < end; j++) {
        await insert(keys[j], values[j]);
      }

      // Brief pause between batches to allow GC to work and prevent memory spikes
      if (end < keys.length) {
        await Future.delayed(Duration.zero);
      }
    }
  }

  /// Insert key-value pair - optimized version
  Future<void> insert(dynamic key, dynamic value) async {
    // Handle null key
    if (key == null) return;

    // Initialize tree
    if (root == null) {
      root = BPlusTreeNode(isLeaf: true);
      root!.keys.add(key);
      root!.values.add([value]);
      return;
    }

    // Search for insertion position
    var currentNode = root!;
    final path = <BPlusTreeNode>[];

    // Locate leaf node
    while (!currentNode.isLeaf) {
      path.add(currentNode);

      // Locate child node
      int i = 0;
      while (i < currentNode.keys.length &&
          _compareKeys(key, currentNode.keys[i]) >= 0) {
        i++;
      }

      // Safety check
      if (i >= currentNode.children.length) {
        Logger.error(
            'Invalid B+ tree structure: key count=${currentNode.keys.length}, child node count=${currentNode.children.length}',
            label: 'BPlusTree.insert');
        if (currentNode.children.isEmpty) return; // Cannot continue
        i = currentNode.children.length - 1; // Use the last child node
      }

      currentNode = currentNode.children[i];
    }

    // Find exact insertion position in leaf node
    int insertPos = 0;
    while (insertPos < currentNode.keys.length &&
        _compareKeys(key, currentNode.keys[insertPos]) > 0) {
      insertPos++;
    }

    // Check if key already exists
    if (insertPos < currentNode.keys.length &&
        _compareKeys(key, currentNode.keys[insertPos]) == 0) {
      // Update existing key
      if (isUnique) {
        // Unique index, replace value
        currentNode.values[insertPos] = [value];
      } else {
        // Non-unique index, add value (avoid duplicates)
        if (!currentNode.values[insertPos].contains(value)) {
          currentNode.values[insertPos].add(value);
        }
      }
      return;
    }

    // Insert new key-value pair
    currentNode.keys.insert(insertPos, key);
    currentNode.values.insert(insertPos, [value]);

    // Check earlier if node needs to be split
    if (currentNode.keys.length > order * 0.7) {
      // Reduced to 0.7 from 0.8
      try {
        await _safeSplitNode(currentNode, path);
      } catch (e, stack) {
        Logger.error('Node split failed: $e\n$stack',
            label: 'BPlusTree.insert');
      }
    }
  }

  /// Safe node splitting algorithm - completely reimplemented
  Future<void> _safeSplitNode(
      BPlusTreeNode node, List<BPlusTreeNode> path) async {
    // Safety check
    if (node.keys.length <= order - 1) return;

    try {
      // Node size graded processing
      if (node.keys.length > maxSafeNodeSize) {
        await _handleOversizedNode(node, path);
        return;
      }

      // Normal split logic - create a new node
      final rightNode = BPlusTreeNode(isLeaf: node.isLeaf);

      // Use dynamic split point, don't set a fixed upper limit
      int splitPoint = node.keys.length ~/ 2;

      // Safety check
      if (splitPoint <= 0 || splitPoint >= node.keys.length) {
        splitPoint =
            math.max(1, math.min(node.keys.length - 1, node.keys.length ~/ 2));
      }

      // Copy right half of keys and values to new node
      final rightKeys = node.keys.sublist(splitPoint);
      final rightValues = node.values.sublist(splitPoint);

      // Add keys and values to right node
      for (int i = 0; i < rightKeys.length; i++) {
        rightNode.keys.add(rightKeys[i]);
        if (i < rightValues.length) {
          rightNode.values.add(List<dynamic>.from(rightValues[i]));
        } else {
          rightNode.values.add([]);
        }
      }

      // Handle children (for non-leaf nodes)
      if (!node.isLeaf) {
        _handleNonLeafSplit(node, rightNode, splitPoint);
      } else {
        // Leaf node: connect linked list
        rightNode.next = node.next;
        node.next = rightNode;
      }

      // Remove transferred keys and values from left node
      node.keys.removeRange(splitPoint, node.keys.length);
      node.values.removeRange(splitPoint, node.values.length);

      // Key to promote to parent node (for searching, separating left and right subtrees)
      final promotedKey = rightNode.keys.first;

      // Handle parent node
      if (path.isEmpty) {
        _createNewRoot(node, rightNode, promotedKey);
      } else {
        await _insertIntoParent(node, rightNode, promotedKey, path);
      }
    } catch (e, stack) {
      Logger.error('Safe node split failed: $e\n$stack',
          label: 'BPlusTree._safeSplitNode');
      // Catch errors but don't rethrow to avoid cascade failures
    }
  }

  /// Handle oversized node (completely separated method)
  Future<void> _handleOversizedNode(
      BPlusTreeNode node, List<BPlusTreeNode> path) async {
    Logger.warn(
        'Node too large(${node.keys.length}), using multi-stage splitting',
        label: 'BPlusTree._handleOversizedNode');

    // For oversized nodes, we split into three parts instead of two to reduce node size faster
    int firstSplitPoint = node.keys.length ~/ 3;
    int secondSplitPoint = firstSplitPoint * 2;

    // Create a temporary node to store the remaining 2/3 of the data
    final tempNode = BPlusTreeNode(isLeaf: node.isLeaf);

    // Move middle 1/3 to temporary node
    final midKeys = node.keys.sublist(firstSplitPoint, secondSplitPoint);
    final midValues = node.values.sublist(firstSplitPoint, secondSplitPoint);

    for (int i = 0; i < midKeys.length; i++) {
      tempNode.keys.add(midKeys[i]);
      if (i < midValues.length) {
        tempNode.values.add(List<dynamic>.from(midValues[i]));
      } else {
        tempNode.values.add([]);
      }
    }

    // Create a third node for the last 1/3 of data
    final lastNode = BPlusTreeNode(isLeaf: node.isLeaf);
    final lastKeys = node.keys.sublist(secondSplitPoint);
    final lastValues = node.values.sublist(secondSplitPoint);

    for (int i = 0; i < lastKeys.length; i++) {
      lastNode.keys.add(lastKeys[i]);
      if (i < lastValues.length) {
        lastNode.values.add(List<dynamic>.from(lastValues[i]));
      } else {
        lastNode.values.add([]);
      }
    }

    // Handle children (for non-leaf nodes)
    if (!node.isLeaf && node.children.isNotEmpty) {
      // Assign children to middle node
      if (node.children.length > firstSplitPoint) {
        final midChildren = node.children.sublist(firstSplitPoint,
            math.min(secondSplitPoint + 1, node.children.length));
        for (var child in midChildren) {
          tempNode.children.add(child);
          child.parent = tempNode;
        }
      }

      // Assign children to last node
      if (node.children.length > secondSplitPoint) {
        final lastChildren = node.children.sublist(secondSplitPoint);
        for (var child in lastChildren) {
          lastNode.children.add(child);
          child.parent = lastNode;
        }
      }

      // Adjust children of first node
      if (node.children.length > firstSplitPoint) {
        node.children.removeRange(firstSplitPoint, node.children.length);
      }
    } else if (node.isLeaf) {
      // Leaf node linked list connection
      lastNode.next = node.next;
      node.next = tempNode;
      tempNode.next = lastNode;
    }

    // Keep first 1/3 of data in first node
    node.keys.removeRange(firstSplitPoint, node.keys.length);
    node.values.removeRange(firstSplitPoint, node.values.length);

    // Select keys to promote
    final promotedKey1 = tempNode.keys.first;
    final promotedKey2 = lastNode.keys.first;

    // Create or update parent node
    if (path.isEmpty) {
      // Create new root node
      final newRoot = BPlusTreeNode(isLeaf: false);
      newRoot.keys.add(promotedKey1);
      newRoot.keys.add(promotedKey2);
      newRoot.children.add(node);
      newRoot.children.add(tempNode);
      newRoot.children.add(lastNode);

      node.parent = newRoot;
      tempNode.parent = newRoot;
      lastNode.parent = newRoot;

      root = newRoot;
    } else {
      // Insert two new nodes into parent node
      final parent = path.last;
      int insertPos = 0;

      // Find current node's position in parent
      while (insertPos < parent.children.length &&
          parent.children[insertPos] != node) {
        insertPos++;
      }

      if (insertPos >= parent.children.length) {
        Logger.error('Cannot find current node in parent',
            label: 'BPlusTree._handleOversizedNode');
        return;
      }

      // Insert middle node and its key
      parent.keys.insert(insertPos, promotedKey1);
      parent.children.insert(insertPos + 1, tempNode);
      tempNode.parent = parent;

      // Insert last node and its key
      parent.keys.insert(insertPos + 1, promotedKey2);
      parent.children.insert(insertPos + 2, lastNode);
      lastNode.parent = parent;

      // Check if parent node needs to be split
      if (parent.keys.length > order - 1) {
        await Future.delayed(Duration.zero); // Avoid deep recursion
        try {
          await _safeSplitNode(parent, path.sublist(0, path.length - 1));
        } catch (e) {
          Logger.error('Parent node split failed: $e',
              label: 'BPlusTree._handleOversizedNode(recursive)');
        }
      }
    }
  }

  /// Handle non-leaf node splitting (child node assignment)
  void _handleNonLeafSplit(
      BPlusTreeNode node, BPlusTreeNode rightNode, int splitPoint) {
    if (node.children.isEmpty) return;

    // Ensure sufficient number of child nodes
    if (node.children.length > splitPoint) {
      // Transfer some child nodes to right node
      final childrenToMove = node.children.sublist(splitPoint);
      for (var child in childrenToMove) {
        rightNode.children.add(child);
        child.parent = rightNode;
      }

      // Remove transferred child nodes from original node
      node.children.removeRange(splitPoint, node.children.length);
    } else {
      // Special handling for insufficient child nodes
      Logger.warn(
          'Insufficient child nodes: ${node.children.length}, split point: $splitPoint',
          label: 'BPlusTree._handleNonLeafSplit');

      // Use available child node count for allocation
      if (node.children.isNotEmpty) {
        int safeChildSplitPoint = node.children.length ~/ 2;

        if (safeChildSplitPoint > 0) {
          // Move half of child nodes to new node
          final childrenToMove = node.children.sublist(safeChildSplitPoint);
          for (var child in childrenToMove) {
            rightNode.children.add(child);
            child.parent = rightNode;
          }

          // Remove transferred child nodes from original node
          node.children.removeRange(safeChildSplitPoint, node.children.length);
        }
      }
    }
  }

  /// Create new root node
  void _createNewRoot(
      BPlusTreeNode leftNode, BPlusTreeNode rightNode, dynamic promotedKey) {
    final newRoot = BPlusTreeNode(isLeaf: false);
    newRoot.keys.add(promotedKey);
    newRoot.children.add(leftNode);
    newRoot.children.add(rightNode);

    leftNode.parent = newRoot;
    rightNode.parent = newRoot;

    root = newRoot;
  }

  /// Insert split result into parent node
  Future<void> _insertIntoParent(BPlusTreeNode node, BPlusTreeNode rightNode,
      dynamic promotedKey, List<BPlusTreeNode> path) async {
    final parent = path.last;
    int parentInsertPos = 0;

    // Find insertion position in parent node
    while (parentInsertPos < parent.children.length &&
        parent.children[parentInsertPos] != node) {
      parentInsertPos++;
    }

    // Safety check
    if (parentInsertPos >= parent.children.length) {
      Logger.error('Cannot find current node in parent',
          label: 'BPlusTree._insertIntoParent');
      return;
    }

    // Insert key and new child node at corresponding position in parent
    parent.keys.insert(parentInsertPos, promotedKey);
    parent.children.insert(parentInsertPos + 1, rightNode);
    rightNode.parent = parent;

    // Check if parent node needs to be split
    if (parent.keys.length > order - 1) {
      // Add delay to avoid deep recursion causing stack overflow
      await Future.delayed(Duration.zero);

      try {
        await _safeSplitNode(parent, path.sublist(0, path.length - 1));
      } catch (e) {
        Logger.error('Parent node split failed: $e',
            label: 'BPlusTree._insertIntoParent(recursive)');
      }
    }
  }

  /// Safe key comparison method
  int _compareKeys(dynamic key1, dynamic key2) {
    // Handle null cases
    if (key1 == null && key2 == null) return 0;
    if (key1 == null) return -1;
    if (key2 == null) return 1;

    // Compare same types
    if (key1 is num && key2 is num) {
      return key1.compareTo(key2);
    }

    if (key1 is String && key2 is String) {
      return key1.compareTo(key2);
    }

    if (key1 is DateTime && key2 is DateTime) {
      return key1.compareTo(key2);
    }

    // Convert different types to string for comparison
    return key1.toString().compareTo(key2.toString());
  }

  /// Search for values corresponding to the specified key
  Future<List<dynamic>> search(dynamic key) async {
    // Handle condition object
    dynamic searchKey = key;
    if (key is Map) {
      if (key.containsKey('=')) {
        searchKey = key['='];
      } else {
        return []; // Other conditions not supported
      }
    }

    if (root == null) return [];

    // Find leaf node containing target key
    BPlusTreeNode? node = root;
    while (node != null && !node.isLeaf) {
      // Binary search for child node
      int i = 0;
      while (
          i < node.keys.length && _compareKeys(searchKey, node.keys[i]) >= 0) {
        i++;
      }

      // Safety check: prevent index out of bounds
      if (i >= node.children.length) {
        Logger.error(
            'B+ tree structure inconsistency: index=$i, key count=${node.keys.length}, child node count=${node.children.length}',
            label: 'BPlusTree.search');
        if (node.children.isEmpty) return [];
        i = node.children.length - 1;
      }

      node = node.children[i];
    }

    // Search for key in leaf node
    if (node != null) {
      for (int i = 0; i < node.keys.length; i++) {
        if (_compareKeys(searchKey, node.keys[i]) == 0) {
          // Ensure index is valid
          if (i < node.values.length) {
            // Return a copy to prevent modification
            return List<dynamic>.from(node.values[i]);
          }
        }
      }
    }

    return [];
  }

  /// Range query (satisfying index manager requirements)
  Future<List<Map<String, dynamic>>> range(dynamic start, dynamic end) async {
    final results = <Map<String, dynamic>>[];
    if (root == null) return results;

    // First find the starting leaf node
    BPlusTreeNode? node = root;
    while (node != null && !node.isLeaf) {
      // Find child node containing start value
      int i = 0;
      while (i < node.keys.length && _compareKeys(start, node.keys[i]) >= 0) {
        i++;
      }

      // Safety check
      if (i >= node.children.length) {
        if (node.children.isEmpty) return results;
        i = node.children.length - 1;
      }

      node = node.children[i];
    }

    // Traverse leaf nodes collecting values in range
    while (node != null) {
      for (int i = 0; i < node.keys.length; i++) {
        // Check if key is in range
        if (_compareKeys(node.keys[i], start) >= 0 &&
            _compareKeys(node.keys[i], end) <= 0) {
          // Ensure value index is valid
          if (i < node.values.length) {
            // Try to extract Map<String, dynamic> type values
            for (var value in node.values[i]) {
              if (value is Map<String, dynamic>) {
                results.add(value);
              } else if (value is Map) {
                // Convert other Map types
                final convertedMap = <String, dynamic>{};
                value.forEach((k, v) {
                  convertedMap[k.toString()] = v;
                });
                results.add(convertedMap);
              }
            }
          }
        }

        // If exceeded upper range limit, stop searching
        if (_compareKeys(node.keys[i], end) > 0) {
          return results;
        }
      }

      // Move to next leaf node
      node = node.next;
    }

    return results;
  }

  /// Range query (returns all types of values)
  Future<List<dynamic>> searchRange(dynamic start, dynamic end,
      {bool includeStart = true, bool includeEnd = true}) async {
    final results = <dynamic>[];
    if (root == null) return results;

    // Find starting leaf node
    BPlusTreeNode? node = root;
    while (node != null && !node.isLeaf) {
      int i = 0;
      while (i < node.keys.length && _compareKeys(start, node.keys[i]) >= 0) {
        i++;
      }

      // Safety check
      if (i >= node.children.length) {
        if (node.children.isEmpty) return results;
        i = node.children.length - 1;
      }

      node = node.children[i];
    }

    // Traverse leaf nodes collecting values in range
    while (node != null) {
      for (int i = 0; i < node.keys.length; i++) {
        final key = node.keys[i];
        final startCompare = _compareKeys(key, start);
        final endCompare = _compareKeys(key, end);

        // Check if key is in range (considering include/exclude boundaries)
        final inRange = (includeStart ? startCompare >= 0 : startCompare > 0) &&
            (includeEnd ? endCompare <= 0 : endCompare < 0);

        if (inRange && i < node.values.length) {
          results.addAll(node.values[i]);
        }

        // If exceeded upper range limit, stop searching
        if (endCompare > 0) {
          return results;
        }
      }

      // Move to next leaf node
      node = node.next;
    }

    return results;
  }

  /// Get all keys
  Future<List<dynamic>> getKeys() async {
    final keys = <dynamic>[];
    if (root == null) return keys;

    // Find leftmost leaf node
    BPlusTreeNode? nodeRef = root;
    while (nodeRef != null && !nodeRef.isLeaf) {
      if (nodeRef.children.isEmpty) break;
      nodeRef = nodeRef.children[0];
    }

    // Traverse all leaf nodes
    while (nodeRef != null) {
      keys.addAll(nodeRef.keys);
      nodeRef = nodeRef.next;
    }

    return keys;
  }

  /// Count the number of key-value pairs in the B+ tree
  int count() {
    if (root == null) return 0;

    int entryCount = 0;

    // Find leftmost leaf node
    BPlusTreeNode? leafNode = root;
    while (leafNode != null && !leafNode.isLeaf) {
      if (leafNode.children.isEmpty) break;
      leafNode = leafNode.children[0];
    }

    // Traverse all leaf nodes counting keys
    while (leafNode != null) {
      entryCount += leafNode.keys.length;
      leafNode = leafNode.next;
    }

    return entryCount;
  }

  /// Search for a value (recordPointer) directly
  /// This is optimized for index operations that need to find entries by recordPointer only
  Future<List<dynamic>> searchByRecordPointer(dynamic recordPointer) async {
    if (root == null) return [];
    final results = <dynamic>[];
    final recordPointerStr = recordPointer.toString();

    // Find leftmost leaf node
    BPlusTreeNode? node = root;
    while (node != null && !node.isLeaf) {
      if (node.children.isEmpty) break;
      node = node.children[0];
    }

    // Traverse all leaf nodes
    while (node != null) {
      for (int i = 0; i < node.keys.length; i++) {
        // Check if recordPointer exists in values
        if (i < node.values.length) {
          for (final value in node.values[i]) {
            if (value == recordPointer ||
                value.toString() == recordPointerStr ||
                value.toString() == recordPointerStr.toString()) {
              // Found a match, add the key and value to results
              results.add({'key': node.keys[i], 'value': value});
            }
          }
        }
      }
      node = node.next;
    }

    return results;
  }

  /// Delete key-value pair and return whether deletion was successful
  Future<bool> delete(dynamic key, dynamic value) async {
    if (root == null) return false;

    final path = <BPlusTreeNode>[];
    BPlusTreeNode? currentNode = root;
    bool deleted = false;

    // Find leaf node containing target key
    while (currentNode != null && !currentNode.isLeaf) {
      path.add(currentNode);

      int i = 0;
      while (i < currentNode.keys.length &&
          _compareKeys(key, currentNode.keys[i]) >= 0) {
        i++;
      }

      // Safety check
      if (i >= currentNode.children.length) {
        if (currentNode.children.isEmpty) return false;
        i = currentNode.children.length - 1;
      }

      currentNode = currentNode.children[i];
    }

    // Find and delete key or value in leaf node
    if (currentNode != null) {
      for (int i = 0; i < currentNode.keys.length; i++) {
        if (_compareKeys(key, currentNode.keys[i]) == 0) {
          if (value != null) {
            // Convert both to string for comparison if needed
            final valueStr = value.toString();

            // Check values to find the match
            int initialLength = currentNode.values[i].length;
            currentNode.values[i].removeWhere((v) {
              if (v is Map && value is Map) {
                return _mapsEqual(v, value);
              }
              return v == value ||
                  v.toString() == valueStr ||
                  v.toString() == valueStr.toString();
            });

            // If items were removed
            if (currentNode.values[i].length < initialLength) {
              deleted = true;

              // If value list is empty, delete entire key-value pair
              if (currentNode.values[i].isEmpty) {
                currentNode.keys.removeAt(i);
                currentNode.values.removeAt(i);
              }
            }
          } else {
            // Delete entire key-value pair
            currentNode.keys.removeAt(i);
            currentNode.values.removeAt(i);
            deleted = true;
          }
          break;
        }
      }
    }

    // Return whether deletion was successful
    return deleted;
  }

  /// Compare if two Maps are equal
  bool _mapsEqual(Map map1, Map map2) {
    if (map1.length != map2.length) return false;

    for (final key in map1.keys) {
      if (!map2.containsKey(key) || map1[key] != map2[key]) {
        return false;
      }
    }

    return true;
  }
}

/// B+ tree node
class BPlusTreeNode {
  /// List storing keys
  final List<dynamic> keys;

  /// List storing values (corresponding to each key)
  final List<List<dynamic>> values;

  /// List of child nodes (internal nodes)
  final List<BPlusTreeNode> children;

  /// Parent node reference
  BPlusTreeNode? parent;

  /// Leaf node linked list (points to next leaf)
  BPlusTreeNode? next;

  /// Whether it is a leaf node
  final bool isLeaf;

  /// Create B+ tree node
  BPlusTreeNode({
    required this.isLeaf,
  })  : keys = [],
        values = [],
        children = [];
}
