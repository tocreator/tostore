import '../handler/logger.dart';

/// B+ tree implementation
class BPlusTree {
  final int order;
  final bool isUnique;
  BPlusTreeNode? root;

  BPlusTree({
    required this.order,
    this.isUnique = false,
  });

  /// insert key-value pair
  Future<void> insert(dynamic key, dynamic value) async {
    // handle null value
    if (key == null) return;

    if (root == null) {
      root = BPlusTreeNode(isLeaf: true);
      root!.keys.add(key);
      root!.values.add([value]);
      return;
    }

    var node = root!;
    final path = <BPlusTreeNode>[];

    // find insert position
    while (!node.isLeaf) {
      path.add(node);
      int i = 0;
      while (i < node.keys.length && _compareKeys(key, node.keys[i]) >= 0) {
        i++;
      }
      node = node.children[i];
    }

    // insert or update in leaf node
    int insertPosition = 0;
    while (insertPosition < node.keys.length &&
        _compareKeys(key, node.keys[insertPosition]) > 0) {
      insertPosition++;
    }

    // check node state
    if (node.keys.length != node.values.length) {
      Logger.error('''insert before node state exception:
        keys length: ${node.keys.length}
        values length: ${node.values.length}
      ''', label: 'BPlusTree.insert');
      // fix node state
      while (node.values.length < node.keys.length) {
        node.values.add([]);
      }
    }

    try {
      // check if key exists
      if (insertPosition < node.keys.length &&
          _compareKeys(key, node.keys[insertPosition]) == 0) {
        if (isUnique) {
          // for unique index, update value
          node.values[insertPosition] = [value];
        } else {
          // for non-unique index, ensure value is not duplicate
          final values = node.values[insertPosition];
          if (!values.contains(value)) {
            values.add(value);
          }
        }
      } else {
        // insert new key-value pair
        node.keys.insert(insertPosition, key);
        node.values.insert(insertPosition, [value]);
      }

      // check insert after state
      if (node.keys.length != node.values.length) {
        Logger.error('''insert after node state exception:
          keys length: ${node.keys.length}
          values length: ${node.values.length}
          insert position: $insertPosition
          key: $key
          value: $value
        ''', label: 'BPlusTree.insert');
      }

      // handle node split
      if (node.keys.length > order) {
        await _split(node, path);
      }
    } catch (e, stack) {
      Logger.error('''insert operation failed:
        error: $e
        stack: $stack
        key: $key
        value: $value
        insertPosition: $insertPosition
      ''', label: 'BPlusTree.insert');
      rethrow;
    }
  }

  /// safe key comparison method
  int _compareKeys(dynamic key1, dynamic key2) {
    // handle null value
    if (key1 == null && key2 == null) return 0;
    if (key1 == null) return -1;
    if (key2 == null) return 1;

    // handle different type comparison
    if (key1 is num && key2 is num) {
      return key1.compareTo(key2);
    }

    if (key1 is String && key2 is String) {
      return key1.compareTo(key2);
    }

    if (key1 is DateTime && key2 is DateTime) {
      return key1.compareTo(key2);
    }

    // convert to string for comparison
    return key1.toString().compareTo(key2.toString());
  }

  /// search key corresponding value
  Future<List<dynamic>> search(dynamic key) async {
    // extract actual value from condition object
    dynamic searchKey = key;
    if (key is Map) {
      if (key.containsKey('=')) {
        searchKey = key['='];
      } else {
        // not support other conditions
        return [];
      }
    }

    if (root == null) return [];

    var node = root!;
    while (!node.isLeaf) {
      int i = 0;
      while (
          i < node.keys.length && _compareKeys(searchKey, node.keys[i]) >= 0) {
        i++;
      }
      node = node.children[i];
    }

    for (int i = 0; i < node.keys.length; i++) {
      if (_compareKeys(searchKey, node.keys[i]) == 0) {
        return node.values[i];
      }
    }
    return [];
  }

  /// range search
  Future<List<Map<String, dynamic>>> range(dynamic start, dynamic end) async {
    final results = <Map<String, dynamic>>[];
    if (root == null) return results;

    // find start leaf node
    var node = root!;
    while (!node.isLeaf) {
      int i = 0;
      while (i < node.keys.length && _compareKeys(start, node.keys[i]) >= 0) {
        i++;
      }
      node = node.children[i];
    }

    // collect values in range
    BPlusTreeNode? currentNode = node;
    while (currentNode != null) {
      for (int i = 0; i < currentNode.keys.length; i++) {
        if (_compareKeys(currentNode.keys[i], start) >= 0 &&
            _compareKeys(currentNode.keys[i], end) <= 0) {
          results.addAll(currentNode.values[i].cast<Map<String, dynamic>>());
        }
        if (_compareKeys(currentNode.keys[i], end) > 0) {
          return results;
        }
      }
      currentNode = currentNode.next;
    }

    return results;
  }

  /// node split
  Future<void> _split(BPlusTreeNode node, List<BPlusTreeNode> path) async {
    try {
      // calculate split point
      final mid = node.keys.length ~/ 2;

      // check and fix node state
      while (node.values.length < node.keys.length) {
        node.values.add([]);
      }

      // create new node
      final newNode = BPlusTreeNode(isLeaf: node.isLeaf);

      try {
        // ensure split point is valid
        if (mid <= 0 || mid >= node.keys.length) {
          return;
        }

        // copy data to move (ensure length consistent)
        final keysToMove = node.keys.sublist(mid);
        final valuesToMove = node.values.sublist(mid);

        // copy data to new node (ensure one-to-one correspondence)
        for (var i = 0; i < keysToMove.length; i++) {
          newNode.keys.add(keysToMove[i]);
          if (i < valuesToMove.length) {
            final value = valuesToMove[i];
            newNode.values.add(List.from(value));
          }
        }

        // remove back half from original node (also remove)
        node.keys.removeRange(mid, node.keys.length);
        node.values.removeRange(mid, node.values.length);

        // handle child node
        if (!node.isLeaf && node.children.isNotEmpty) {
          final childrenToMove = List.from(node.children.sublist(mid));
          for (var child in childrenToMove) {
            newNode.children.add(child);
            child.parent = newNode;
          }
          node.children.removeRange(mid, node.children.length);
        } else {
          newNode.next = node.next;
          node.next = newNode;
        }

        // handle parent node
        if (path.isEmpty) {
          final newRoot = BPlusTreeNode(isLeaf: false);
          if (newNode.keys.isNotEmpty) {
            newRoot.keys.add(newNode.keys.first);
            newRoot.children.add(node);
            newRoot.children.add(newNode);
            node.parent = newRoot;
            newNode.parent = newRoot;
            root = newRoot;
          }
        } else {
          final parent = path.last;
          if (newNode.keys.isNotEmpty) {
            final insertPos = parent.children.indexOf(node);
            if (insertPos >= 0) {
              parent.keys.insert(insertPos, newNode.keys.first);
              parent.children.insert(insertPos + 1, newNode);
              newNode.parent = parent;

              if (parent.keys.length > order) {
                await _split(parent, path.sublist(0, path.length - 1));
              }
            }
          }
        }
      } catch (e, stack) {
        Logger.error('''node split operation failed: 
          error: $e
          stack: $stack
        ''', label: 'BPlusTree._split');
        rethrow;
      }
    } catch (e) {
      Logger.error('node split operation failed: $e',
          label: 'BPlusTree._split');
      rethrow;
    }
  }

  /// delete key-value pair
  Future<void> delete(dynamic key, dynamic value) async {
    if (root == null) return;

    var node = root!;
    final path = <BPlusTreeNode>[];

    // find key to delete
    while (!node.isLeaf) {
      path.add(node);
      int i = 0;
      while (i < node.keys.length && _compareKeys(key, node.keys[i]) >= 0) {
        i++;
      }
      node = node.children[i];
    }

    // find and delete value in leaf node
    for (int i = 0; i < node.keys.length; i++) {
      if (_compareKeys(key, node.keys[i]) == 0) {
        // if update operation, only delete matching value
        if (value != null) {
          node.values[i].removeWhere((v) {
            if (v is Map && value is Map) {
              return v['id'] == value['id'];
            }
            return v == value;
          });

          // if value list is empty, delete whole key
          if (node.values[i].isEmpty) {
            node.keys.removeAt(i);
            node.values.removeAt(i);
          }
        } else {
          // if no value specified, delete whole key-value pair
          node.keys.removeAt(i);
          node.values.removeAt(i);
        }
        break;
      }
    }

    // if node is empty and not root, need merge or reallocate
    if (node.keys.isEmpty && node != root) {
      await _rebalanceAfterDelete(node, path);
    }

    // if root node is empty and has child node, update root node
    if (root!.keys.isEmpty && !root!.isLeaf && root!.children.isNotEmpty) {
      root = root!.children[0];
      root!.parent = null;
    }
  }

  /// rebalance tree after delete
  Future<void> _rebalanceAfterDelete(
      BPlusTreeNode node, List<BPlusTreeNode> path) async {
    final minKeys = (order / 2).ceil() - 1;

    while (node.keys.length < minKeys && path.isNotEmpty) {
      final parent = path.last;
      final nodeIndex = parent.children.indexOf(node);

      BPlusTreeNode? leftSibling;
      BPlusTreeNode? rightSibling;

      if (nodeIndex > 0) {
        leftSibling = parent.children[nodeIndex - 1];
      }
      if (nodeIndex < parent.children.length - 1) {
        rightSibling = parent.children[nodeIndex + 1];
      }

      // try borrow key from sibling node
      if (leftSibling != null && leftSibling.keys.length > minKeys) {
        _borrowFromLeft(node, leftSibling, parent, nodeIndex - 1);
      } else if (rightSibling != null && rightSibling.keys.length > minKeys) {
        _borrowFromRight(node, rightSibling, parent, nodeIndex);
      } else {
        // need merge node
        if (leftSibling != null) {
          _mergeWithLeft(node, leftSibling, parent, nodeIndex - 1);
          node = leftSibling;
        } else if (rightSibling != null) {
          _mergeWithRight(node, rightSibling, parent, nodeIndex);
        }
      }

      // update path
      path.removeLast();
      if (path.isNotEmpty) {
        node = path.last;
      }
    }
  }

  /// borrow key from left sibling
  void _borrowFromLeft(BPlusTreeNode node, BPlusTreeNode leftSibling,
      BPlusTreeNode parent, int parentIndex) {
    if (node.isLeaf) {
      // borrow last key-value pair from left sibling
      node.keys.insert(0, leftSibling.keys.last);
      node.values.insert(0, leftSibling.values.last);
      leftSibling.keys.removeLast();
      leftSibling.values.removeLast();
      parent.keys[parentIndex] = node.keys.first;
    } else {
      // borrow key from non-leaf node
      node.keys.insert(0, parent.keys[parentIndex]);
      parent.keys[parentIndex] = leftSibling.keys.last;
      node.children.insert(0, leftSibling.children.last);
      node.children.first.parent = node;
      leftSibling.keys.removeLast();
      leftSibling.children.removeLast();
    }
  }

  /// borrow key from right sibling
  void _borrowFromRight(BPlusTreeNode node, BPlusTreeNode rightSibling,
      BPlusTreeNode parent, int parentIndex) {
    if (node.isLeaf) {
      // borrow first key-value pair from right sibling
      node.keys.add(rightSibling.keys.first);
      node.values.add(rightSibling.values.first);
      rightSibling.keys.removeAt(0);
      rightSibling.values.removeAt(0);
      parent.keys[parentIndex] = rightSibling.keys.first;
    } else {
      // borrow key from non-leaf node
      node.keys.add(parent.keys[parentIndex]);
      parent.keys[parentIndex] = rightSibling.keys.first;
      node.children.add(rightSibling.children.first);
      node.children.last.parent = node;
      rightSibling.keys.removeAt(0);
      rightSibling.children.removeAt(0);
    }
  }

  /// merge with left sibling
  void _mergeWithLeft(BPlusTreeNode node, BPlusTreeNode leftSibling,
      BPlusTreeNode parent, int parentIndex) {
    if (node.isLeaf) {
      leftSibling.keys.addAll(node.keys);
      leftSibling.values.addAll(node.values);
      leftSibling.next = node.next;
    } else {
      leftSibling.keys.add(parent.keys[parentIndex]);
      leftSibling.keys.addAll(node.keys);
      leftSibling.children.addAll(node.children);
      for (var child in node.children) {
        child.parent = leftSibling;
      }
    }
    parent.keys.removeAt(parentIndex);
    parent.children.removeAt(parentIndex + 1);
  }

  /// merge with right sibling
  void _mergeWithRight(BPlusTreeNode node, BPlusTreeNode rightSibling,
      BPlusTreeNode parent, int parentIndex) {
    if (node.isLeaf) {
      node.keys.addAll(rightSibling.keys);
      node.values.addAll(rightSibling.values);
      node.next = rightSibling.next;
    } else {
      node.keys.add(parent.keys[parentIndex]);
      node.keys.addAll(rightSibling.keys);
      node.children.addAll(rightSibling.children);
      for (var child in rightSibling.children) {
        child.parent = node;
      }
    }
    parent.keys.removeAt(parentIndex);
    parent.children.removeAt(parentIndex + 1);
  }
}

/// B+ tree node
class BPlusTreeNode {
  final List<dynamic> keys;
  final List<List<dynamic>> values;
  final List<BPlusTreeNode> children;
  BPlusTreeNode? parent;
  BPlusTreeNode? next;
  final bool isLeaf;

  BPlusTreeNode({
    required this.isLeaf,
  })  : keys = [],
        values = [],
        children = [];
}
