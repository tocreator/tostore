import '../handler/logger.dart';

/// B+ 树实现
class BPlusTree {
  final int order;
  final bool isUnique;
  BPlusTreeNode? root;

  BPlusTree({
    required this.order,
    this.isUnique = false,
  });

  /// 插入键值对
  Future<void> insert(dynamic key, dynamic value) async {
    // 处理 null 值
    if (key == null) return;

    if (root == null) {
      root = BPlusTreeNode(isLeaf: true);
      root!.keys.add(key);
      root!.values.add([value]);
      return;
    }

    var node = root!;
    final path = <BPlusTreeNode>[];

    // 查找插入位置
    while (!node.isLeaf) {
      path.add(node);
      int i = 0;
      while (i < node.keys.length && _compareKeys(key, node.keys[i]) >= 0) {
        i++;
      }
      node = node.children[i];
    }

    // 在叶子节点中插入或更新
    int insertPosition = 0;
    while (insertPosition < node.keys.length &&
        _compareKeys(key, node.keys[insertPosition]) > 0) {
      insertPosition++;
    }

    // 检查节点状态
    if (node.keys.length != node.values.length) {
      Logger.error('''插入前节点状态异常:
        keys长度: ${node.keys.length}
        values长度: ${node.values.length}
      ''', label: 'BPlusTree.insert');
      // 修复节点状态
      while (node.values.length < node.keys.length) {
        node.values.add([]);
      }
    }

    try {
      // 检查是否存在相同的键
      if (insertPosition < node.keys.length &&
          _compareKeys(key, node.keys[insertPosition]) == 0) {
        if (isUnique) {
          // 对于唯一索引，更新值
          node.values[insertPosition] = [value];
        } else {
          // 对于非唯一索引，确保值不重复
          final values = node.values[insertPosition];
          if (!values.contains(value)) {
            values.add(value);
          }
        }
      } else {
        // 插入新的键值对
        node.keys.insert(insertPosition, key);
        node.values.insert(insertPosition, [value]);
      }

      // 验证插入后的状态
      if (node.keys.length != node.values.length) {
        Logger.error('''插入后节点状态异常:
          keys长度: ${node.keys.length}
          values长度: ${node.values.length}
          插入位置: $insertPosition
          key: $key
          value: $value
        ''', label: 'BPlusTree.insert');
      }

      // 处理节点分裂
      if (node.keys.length > order) {
        await _split(node, path);
      }
    } catch (e, stack) {
      Logger.error('''插入操作失败:
        error: $e
        stack: $stack
        key: $key
        value: $value
        insertPosition: $insertPosition
      ''', label: 'BPlusTree.insert');
      rethrow;
    }
  }

  /// 安全的键比较方法
  int _compareKeys(dynamic key1, dynamic key2) {
    // 处理 null 值
    if (key1 == null && key2 == null) return 0;
    if (key1 == null) return -1;
    if (key2 == null) return 1;

    // 处理不同类型的比较
    if (key1 is num && key2 is num) {
      return key1.compareTo(key2);
    }

    if (key1 is String && key2 is String) {
      return key1.compareTo(key2);
    }

    if (key1 is DateTime && key2 is DateTime) {
      return key1.compareTo(key2);
    }

    // 转换为字符串进行比较
    return key1.toString().compareTo(key2.toString());
  }

  /// 搜索键对应的值
  Future<List<dynamic>> search(dynamic key) async {
    // 从条件对象中提取实际值
    dynamic searchKey = key;
    if (key is Map) {
      if (key.containsKey('=')) {
        searchKey = key['='];
      } else {
        // 暂不支持其他条件
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

  /// 范围查询
  Future<List<Map<String, dynamic>>> range(dynamic start, dynamic end) async {
    final results = <Map<String, dynamic>>[];
    if (root == null) return results;

    // 找到起始叶子节点
    var node = root!;
    while (!node.isLeaf) {
      int i = 0;
      while (i < node.keys.length && _compareKeys(start, node.keys[i]) >= 0) {
        i++;
      }
      node = node.children[i];
    }

    // 收集范围内的值
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

  /// 节点分裂
  Future<void> _split(BPlusTreeNode node, List<BPlusTreeNode> path) async {
    try {
      // 计算分裂点
      final mid = node.keys.length ~/ 2;

      // 验证并修复节点状态
      while (node.values.length < node.keys.length) {
        node.values.add([]);
      }

      // 创建新节点
      final newNode = BPlusTreeNode(isLeaf: node.isLeaf);

      try {
        // 确保分裂点有效
        if (mid <= 0 || mid >= node.keys.length) {
          return;
        }

        // 先复制要移动的数据（确保长度一致）
        final keysToMove = node.keys.sublist(mid);
        final valuesToMove = node.values.sublist(mid);

        // 复制数据到新节点（保持一一对应）
        for (var i = 0; i < keysToMove.length; i++) {
          newNode.keys.add(keysToMove[i]);
          if (i < valuesToMove.length) {
            final value = valuesToMove[i];
            newNode.values.add(List.from(value));
          }
        }

        // 从原节点移除后半部分（同时移除）
        node.keys.removeRange(mid, node.keys.length);
        node.values.removeRange(mid, node.values.length);

        // 处理子节点
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

        // 处理父节点
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
        Logger.error('''节点分裂操作失败: 
          error: $e
          stack: $stack
        ''', label: 'BPlusTree._split');
        rethrow;
      }
    } catch (e) {
      Logger.error('节点分裂失败: $e', label: 'BPlusTree._split');
      rethrow;
    }
  }

  /// 删除键值对
  Future<void> delete(dynamic key, dynamic value) async {
    if (root == null) return;

    var node = root!;
    final path = <BPlusTreeNode>[];

    // 查找要删除的键
    while (!node.isLeaf) {
      path.add(node);
      int i = 0;
      while (i < node.keys.length && _compareKeys(key, node.keys[i]) >= 0) {
        i++;
      }
      node = node.children[i];
    }

    // 在叶子节点中查找并删除值
    for (int i = 0; i < node.keys.length; i++) {
      if (_compareKeys(key, node.keys[i]) == 0) {
        // 如果是更新操作，只删除匹配的值
        if (value != null) {
          node.values[i].removeWhere((v) {
            if (v is Map && value is Map) {
              return v['id'] == value['id'];
            }
            return v == value;
          });

          // 如果值列表为空，删除整个键
          if (node.values[i].isEmpty) {
            node.keys.removeAt(i);
            node.values.removeAt(i);
          }
        } else {
          // 如果没有指定值，删除整个键值对
          node.keys.removeAt(i);
          node.values.removeAt(i);
        }
        break;
      }
    }

    // 如果节点为空且不是根节点，需要合并或重新分配
    if (node.keys.isEmpty && node != root) {
      await _rebalanceAfterDelete(node, path);
    }

    // 如果根节点为空且有子节点，更新根节点
    if (root!.keys.isEmpty && !root!.isLeaf && root!.children.isNotEmpty) {
      root = root!.children[0];
      root!.parent = null;
    }
  }

  /// 删除后重新平衡树
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

      // 尝试从兄弟节点借键
      if (leftSibling != null && leftSibling.keys.length > minKeys) {
        _borrowFromLeft(node, leftSibling, parent, nodeIndex - 1);
      } else if (rightSibling != null && rightSibling.keys.length > minKeys) {
        _borrowFromRight(node, rightSibling, parent, nodeIndex);
      } else {
        // 需要合并节点
        if (leftSibling != null) {
          _mergeWithLeft(node, leftSibling, parent, nodeIndex - 1);
          node = leftSibling;
        } else if (rightSibling != null) {
          _mergeWithRight(node, rightSibling, parent, nodeIndex);
        }
      }

      // 更新路径
      path.removeLast();
      if (path.isNotEmpty) {
        node = path.last;
      }
    }
  }

  /// 从左兄弟借键
  void _borrowFromLeft(BPlusTreeNode node, BPlusTreeNode leftSibling,
      BPlusTreeNode parent, int parentIndex) {
    if (node.isLeaf) {
      // 从左兄弟借最后一个键值对
      node.keys.insert(0, leftSibling.keys.last);
      node.values.insert(0, leftSibling.values.last);
      leftSibling.keys.removeLast();
      leftSibling.values.removeLast();
      parent.keys[parentIndex] = node.keys.first;
    } else {
      // 非叶子节点的借键操作
      node.keys.insert(0, parent.keys[parentIndex]);
      parent.keys[parentIndex] = leftSibling.keys.last;
      node.children.insert(0, leftSibling.children.last);
      node.children.first.parent = node;
      leftSibling.keys.removeLast();
      leftSibling.children.removeLast();
    }
  }

  /// 从右兄弟借键
  void _borrowFromRight(BPlusTreeNode node, BPlusTreeNode rightSibling,
      BPlusTreeNode parent, int parentIndex) {
    if (node.isLeaf) {
      // 从右兄弟借第一个键值对
      node.keys.add(rightSibling.keys.first);
      node.values.add(rightSibling.values.first);
      rightSibling.keys.removeAt(0);
      rightSibling.values.removeAt(0);
      parent.keys[parentIndex] = rightSibling.keys.first;
    } else {
      // 非叶子节点的借键操作
      node.keys.add(parent.keys[parentIndex]);
      parent.keys[parentIndex] = rightSibling.keys.first;
      node.children.add(rightSibling.children.first);
      node.children.last.parent = node;
      rightSibling.keys.removeAt(0);
      rightSibling.children.removeAt(0);
    }
  }

  /// 与左兄弟合并
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

  /// 与右兄弟合并
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

/// B+ 树节点
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
