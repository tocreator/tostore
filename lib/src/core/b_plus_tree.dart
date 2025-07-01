import 'dart:convert';

import '../handler/logger.dart';
import 'dart:math' as math;
import '../handler/platform_handler.dart';
import '../handler/value_comparator.dart';

/// B+ tree implementation with enhanced safety and performance
class BPlusTree {
  /// Order of the B+ tree (maximum number of keys per node)
  final int order;

  /// Indicates whether the index has a uniqueness constraint
  final bool isUnique;

  /// Root node
  BPlusTreeNode? root;

  /// Get safe node size limit based on platform
  static int get maxSafeNodeSize => _getMaxSafeNodeSize();

  /// Calculate max safe node size based on platform and available memory
  static int _getMaxSafeNodeSize() {
    try {
      if (PlatformHandler.isWeb) {
        return 1000; // Increase node size limit for Web platform to support more index data
      } else if (PlatformHandler.isMobile) {
        return 2000; // Increase node size limit for mobile platform
      } else if (PlatformHandler.isServerEnvironment) {
        final cores = PlatformHandler.processorCores;
        // Server environment - scale with CPU cores
        return math.max(5000, cores * 500);
      } else {
        // Desktop environment - scale with CPU cores
        return 3000;
      }
    } catch (e) {
      // Return safe default value on error
      return 1000; // Default value also increased to 1000
    }
  }

  /// Auto-select order based on platform/memory if not specified
  static int _defaultOrder() {
    // Dynamically adjust order parameters based on platform type and memory size
    try {
      // Web platform uses smaller order
      if (PlatformHandler.isWeb) {
        return 256;
      }

      // Mobile platform uses medium order
      if (PlatformHandler.isMobile) {
        return 512;
      }

      // Server environment uses larger order
      if (PlatformHandler.isServerEnvironment) {
        final cores = PlatformHandler.processorCores;
        return math.min(8192, math.max(2048, cores * 512));
      }

      // Desktop platform
      final cores = PlatformHandler.processorCores;
      return math.min(4096, math.max(1024, cores * 256));
    } catch (e) {
      // Return safe default value on error
      Logger.warn('Error determining B+Tree order: $e, using default value',
          label: 'BPlusTree._defaultOrder');
      return 1024;
    }
  }

  /// Create a B+ tree
  BPlusTree({
    int? order,
    this.isUnique = false,
  }) : order = order ?? _defaultOrder();

  /// Create a B+ tree from a serialized string
  static Future<BPlusTree> fromString(String data,
      {int? order,
      bool isUnique = false,
      ComparatorFunction? comparator}) async {
    final tree = BPlusTree(order: order, isUnique: isUnique);
    if (data.isEmpty) return tree;
    try {
      final lines = const LineSplitter().convert(data);
      // Use the same batch size calculation as batchInsert for consistency
      int batchSize = _getDefaultBatchSize();

      // For very large data, reduce batch size to avoid memory issues
      if (data.length > 10 * 1024 * 1024) {
        // >10MB
        batchSize = batchSize ~/ 2;
      }

      for (int i = 0; i < lines.length; i += batchSize) {
        final end = math.min(i + batchSize, lines.length);
        final batch = lines.sublist(i, end);
        for (var line in batch) {
          if (line.trim().isEmpty) continue;
          final parts = line.split('|');
          if (parts.length >= 2) {
            final key = deserializeValue(parts[0]);
            final values = deserializeValues(parts[1]);
            for (var value in values) {
              try {
                await tree.insert(key, value, comparator: comparator);
              } catch (e) {
                Logger.error('Insertion failed: $e, key=$key, value=$value',
                    label: 'BPlusTree.fromString');
              }
            }
          }
        }
        if (end < lines.length) {
          // Dynamically adjust pause duration based on data size
          final pauseDuration = lines.length > 100000
              ? const Duration(
                  milliseconds: 2) // More time for GC with large data
              : Duration.zero;
          await Future.delayed(pauseDuration);
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
  Future<void> batchInsert(List<dynamic> keys, List<dynamic> values,
      {ComparatorFunction? comparator}) async {
    if (keys.length != values.length) {
      throw ArgumentError('The number of keys and values must be the same');
    }

    if (keys.isEmpty) return; // Early return to avoid unnecessary processing

    // Pre-process data by sorting keys to improve B+ tree insertion efficiency
    final sortedIndices = List<int>.generate(keys.length, (i) => i);

    try {
      // When data is large, sorting can improve insertion efficiency (especially sequential insertion is more efficient than random insertion)
      if (keys.length > 1000) {
        sortedIndices.sort((a, b) {
          final keyA = keys[a];
          final keyB = keys[b];
          return _compareKeys(keyA, keyB, comparator: comparator);
        });
      }
    } catch (e) {
      // If sorting fails, keep the original order,不影响正确性，仅优化性能
      Logger.warn(
          'Failed to sort keys for batch insert: $e, continuing with unsorted insertion',
          label: 'BPlusTree.batchInsert');
    }

    // For B+ tree, we use smaller batch size to avoid memory peaks
    int batchSize;
    try {
      // Get configured batch size, but appropriately reduce for B+ tree operations to avoid memory issues
      final configBatchSize = _getDefaultBatchSize();
      // Dynamically adjust batch size based on data size
      if (keys.length > 1000000) {
        // Above 1 million data, use smaller batch to reduce memory pressure
        batchSize = math.min(configBatchSize ~/ 4, 500);
      } else if (keys.length > 100000) {
        // 100,000 data
        batchSize = math.min(configBatchSize ~/ 2, 1000);
      } else {
        // Small data, can use larger batch
        batchSize = math.min(configBatchSize, 2000);
      }
    } catch (e) {
      // Use safe default value on error
      batchSize = 500;
      Logger.warn('Error determining batch size: $e, using default value',
          label: 'BPlusTree.batchInsert');
    }

    // Performance optimization for large data sets
    if (keys.length > 500000) {
      // For extremely large batches, first create an optimized empty tree structure
      root ??= BPlusTreeNode(isLeaf: true);

      // Use hierarchical batch processing strategy
      final totalBatches = (keys.length / batchSize).ceil();

      // Calculate appropriate concurrency level to avoid excessive concurrency
      final processorCount =
          PlatformHandler.isWeb ? 2 : PlatformHandler.processorCores;
      final concurrencyLevel =
          math.min(8, math.min(totalBatches, processorCount));

      if (concurrencyLevel > 1 && !PlatformHandler.isWeb) {
        // Use concurrent batch processing
        final batchesPerWorker = (totalBatches / concurrencyLevel).ceil();
        final workerTasks = <Future<void>>[];

        for (int workerIndex = 0;
            workerIndex < concurrencyLevel;
            workerIndex++) {
          final startBatchIndex = workerIndex * batchesPerWorker;
          final endBatchIndex =
              math.min(startBatchIndex + batchesPerWorker, totalBatches);

          final workerTask = () async {
            for (int batchIndex = startBatchIndex;
                batchIndex < endBatchIndex;
                batchIndex++) {
              final startIdx = batchIndex * batchSize;
              final endIdx = math.min(startIdx + batchSize, keys.length);

              // Process current batch
              for (int j = startIdx; j < endIdx; j++) {
                final sortedIdx = sortedIndices[j];
                await insert(keys[sortedIdx], values[sortedIdx],
                    comparator: comparator);
              }

              // Pause between batches to reduce memory pressure
              if (endIdx < keys.length) {
                await Future.delayed(const Duration(milliseconds: 1));
              }
            }
          }();

          workerTasks.add(workerTask);
        }

        // Wait for all work to complete
        await Future.wait(workerTasks);
        return;
      }
    }

    // Standard processing logic
    for (int i = 0; i < keys.length; i += batchSize) {
      final end = math.min(i + batchSize, keys.length);

      // Process current batch
      for (int j = i; j < end; j++) {
        final sortedIdx = sortedIndices[j];
        await insert(keys[sortedIdx], values[sortedIdx],
            comparator: comparator);
      }

      // Brief pause between batches to allow GC to work and prevent memory spikes
      if (end < keys.length) {
        // Dynamically adjust pause duration based on batch size
        final pauseDuration = keys.length > 100000
            ? const Duration(
                milliseconds: 2) // More time for GC with large data
            : Duration.zero;
        await Future.delayed(pauseDuration);
      }
    }
  }

  /// Get default batch size
  static int _getDefaultBatchSize() {
    // Prioritize using PlatformHandler's recommended concurrency
    try {
      if (PlatformHandler.isWeb) {
        return 500; // Web environment uses smaller batch
      } else if (PlatformHandler.isMobile) {
        return 1000; // Mobile device uses medium batch
      } else if (PlatformHandler.isServerEnvironment) {
        // Server environment adjusts based on core count
        int cpuCount = PlatformHandler.processorCores;
        return 2000 + (cpuCount * 500);
      } else {
        // Desktop environment
        return 2000;
      }
    } catch (e) {
      // Default safe value
      return 1000;
    }
  }

  /// Insert key-value pair - optimized version
  Future<void> insert(dynamic key, dynamic value,
      {ComparatorFunction? comparator}) async {
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

    // Add safety limit to prevent deep paths causing memory issues
    int maxDepth = 50; // B+ tree should not have such deep paths
    int currentDepth = 0;

    try {
      // Locate leaf node
      while (!currentNode.isLeaf) {
        path.add(currentNode);
        currentDepth++;

        // Safety check
        if (currentDepth > maxDepth) {
          Logger.error('B+ tree depth exceeds safe limit: $currentDepth',
              label: 'BPlusTree.insert');
          return; // Avoid potential infinite loop
        }

        // Locate child node
        int i = 0;
        while (i < currentNode.keys.length &&
            _compareKeys(key, currentNode.keys[i], comparator: comparator) >=
                0) {
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
          _compareKeys(key, currentNode.keys[insertPos],
                  comparator: comparator) >
              0) {
        insertPos++;
      }

      // Check if key already exists
      if (insertPos < currentNode.keys.length &&
          _compareKeys(key, currentNode.keys[insertPos],
                  comparator: comparator) ==
              0) {
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

      // Split the node if it's full.
      // This is a more robust condition than using a fraction of the order.
      if (currentNode.keys.length > order - 1) {
        try {
          await _safeSplitNode(currentNode, path);
        } catch (e, stack) {
          Logger.error('Node split failed: $e\n$stack',
              label: 'BPlusTree.insert');

          // If split fails but the node is already very large, try emergency recovery
          if (currentNode.keys.length > order * 0.9) {
            try {
              await _emergencySplitOversizedNode(currentNode, path);
            } catch (emergencyError) {
              Logger.error('Emergency split also failed: $emergencyError',
                  label: 'BPlusTree.insert');
            }
          }
        }
      }
    } catch (e, stack) {
      Logger.error('Insert operation failed: $e\n$stack',
          label: 'BPlusTree.insert');
    }
  }

  /// Emergency procedure to split an oversized node when regular split fails
  /// This is a simplified version that prioritizes stability over optimal structure
  Future<void> _emergencySplitOversizedNode(
      BPlusTreeNode node, List<BPlusTreeNode> path) async {
    try {
      // Simply split the node into two parts
      final splitPoint = node.keys.length ~/ 2;

      // Create a new node
      final rightNode = BPlusTreeNode(isLeaf: node.isLeaf);

      // Copy right half of keys and values to new node
      for (int i = splitPoint; i < node.keys.length; i++) {
        rightNode.keys.add(node.keys[i]);
        rightNode.values.add(List<dynamic>.from(node.values[i]));
      }

      // Handle child nodes (if not leaf node)
      if (!node.isLeaf &&
          node.children.isNotEmpty &&
          splitPoint < node.children.length) {
        for (int i = splitPoint + 1; i < node.children.length; i++) {
          rightNode.children.add(node.children[i]);
          node.children[i].parent = rightNode;
        }
        node.children.removeRange(splitPoint + 1, node.children.length);
      } else if (node.isLeaf) {
        // Handle next pointer for leaf nodes
        rightNode.next = node.next;
        node.next = rightNode;
      }

      // From original node, remove copied keys and values
      node.keys.removeRange(splitPoint, node.keys.length);
      node.values.removeRange(splitPoint, node.values.length);

      // Link new node to parent node
      final promotedKey = rightNode.keys.first;

      if (path.isEmpty) {
        // Create new root node
        final newRoot = BPlusTreeNode(isLeaf: false);
        newRoot.keys.add(promotedKey);
        newRoot.children.add(node);
        newRoot.children.add(rightNode);
        node.parent = newRoot;
        rightNode.parent = newRoot;
        root = newRoot;
      } else {
        // Insert into existing parent node
        final parent = path.last;
        int insertPos = 0;
        while (insertPos < parent.children.length &&
            parent.children[insertPos] != node) {
          insertPos++;
        }

        if (insertPos >= parent.children.length) {
          Logger.error('Cannot find node in parent during emergency split',
              label: 'BPlusTree._emergencySplitOversizedNode');
          return;
        }

        parent.keys.insert(insertPos, promotedKey);
        parent.children.insert(insertPos + 1, rightNode);
        rightNode.parent = parent;
      }
    } catch (e, stack) {
      Logger.error('Emergency split failed: $e\n$stack',
          label: 'BPlusTree._emergencySplitOversizedNode');
      rethrow; // Re-throw exception to inform caller that emergency split also failed
    }
  }

  /// Safe node splitting algorithm - completely reimplemented
  Future<void> _safeSplitNode(
      BPlusTreeNode node, List<BPlusTreeNode> path) async {
    // Safety check, although the caller should ensure this.
    if (node.keys.length <= order - 1) return;

    // Handle oversized nodes with a more robust 3-way split.
    if (node.keys.length > maxSafeNodeSize) {
      await _handleOverSizedNode(node, path);
      return;
    }

    try {
      final rightNode = BPlusTreeNode(isLeaf: node.isLeaf);
      final int splitPoint = node.keys.length ~/ 2;

      dynamic promotedKey;

      if (node.isLeaf) {
        // --- LEAF NODE SPLIT ---
        // The first key of the right half is copied to the parent.
        promotedKey = node.keys[splitPoint];

        // Move the second half of keys and values to the new right node.
        rightNode.keys.addAll(node.keys.sublist(splitPoint));
        rightNode.values.addAll(node.values.sublist(splitPoint));
        node.keys.removeRange(splitPoint, node.keys.length);
        node.values.removeRange(splitPoint, node.values.length);

        // Link the leaf nodes.
        rightNode.next = node.next;
        node.next = rightNode;
      } else {
        // --- INTERNAL NODE SPLIT ---
        // The middle key is moved up to the parent and removed from the children.
        promotedKey = node.keys[splitPoint];

        // Keys to the right of the promoted key move to the new right node.
        rightNode.keys.addAll(node.keys.sublist(splitPoint + 1));

        // Corresponding children move to the new right node.
        rightNode.children.addAll(node.children.sublist(splitPoint + 1));
        for (var child in rightNode.children) {
          child.parent = rightNode;
        }

        // Trim the original node.
        node.keys.removeRange(splitPoint, node.keys.length);
        node.children.removeRange(splitPoint + 1, node.children.length);
      }

      // --- UPDATE PARENT ---
      if (path.isEmpty) {
        // Create a new root if the split node was the root.
        _createNewRoot(node, rightNode, promotedKey);
      } else {
        // Insert the promoted key and the new node into the parent.
        await _insertIntoParent(node, rightNode, promotedKey, path);
      }
    } catch (e, stack) {
      Logger.error('Safe node split failed with detailed error: $e\n$stack',
          label: 'BPlusTree._safeSplitNode');
      // On failure, attempt a last-resort emergency split.
      await _ultraSimpleEmergencySplit(node, path);
    }
  }

  /// Ultra simple emergency node split when normal split fails
  /// This is a last resort method to maintain tree integrity
  Future<void> _ultraSimpleEmergencySplit(
      BPlusTreeNode node, List<BPlusTreeNode> path) async {
    try {
      // Create a new node
      final rightNode = BPlusTreeNode(isLeaf: node.isLeaf);

      // Use simplest possible approach - move last half to new node
      int targetNodeSize = math.max(2, node.keys.length ~/ 3);

      while (node.keys.length > targetNodeSize) {
        // Always move the last element to avoid index issues
        if (node.keys.isNotEmpty) {
          final lastKey = node.keys.last;
          node.keys.removeLast();

          rightNode.keys.insert(0, lastKey);
        }

        if (node.values.isNotEmpty) {
          final lastValue = node.values.last;
          node.values.removeLast();

          rightNode.values.insert(0, lastValue);
        }
      }

      // Handle leaf node pointers
      if (node.isLeaf) {
        rightNode.next = node.next;
        node.next = rightNode;
      }

      // Skip child node handling in emergency mode
      // This might create an invalid tree but prevents crashes

      // Promote first key of right node
      if (rightNode.keys.isEmpty) {
        Logger.error('Emergency split created empty right node',
            label: 'BPlusTree._ultraSimpleEmergencySplit');
        return;
      }

      final promotedKey = rightNode.keys.first;

      // Update tree structure
      if (path.isEmpty) {
        // Create new root
        final newRoot = BPlusTreeNode(isLeaf: false);
        newRoot.keys.add(promotedKey);
        newRoot.children.add(node);
        newRoot.children.add(rightNode);
        node.parent = newRoot;
        rightNode.parent = newRoot;
        root = newRoot;
      } else {
        // Add to parent node at the end to avoid index issues
        final parent = path.last;
        parent.keys.add(promotedKey);
        parent.children.add(rightNode);
        rightNode.parent = parent;
      }
    } catch (e) {
      Logger.error('Emergency split also failed: $e',
          label: 'BPlusTree._ultraSimpleEmergencySplit');
    }
  }

  /// Handle overSized node (completely separated method)
  Future<void> _handleOverSizedNode(
      BPlusTreeNode node, List<BPlusTreeNode> path) async {
    try {
      // Get current safe node size to determine split strategy
      final nodeSize = node.keys.length;

      // Create additional nodes
      final midNode = BPlusTreeNode(isLeaf: node.isLeaf);
      final rightNode = BPlusTreeNode(isLeaf: node.isLeaf);

      // Calculate safe split points to divide the node into three parts.
      final firstSplitPoint = nodeSize ~/ 3;
      final secondSplitPoint = 2 * nodeSize ~/ 3;

      // Safety check: verify split points
      if (firstSplitPoint <= 0 ||
          secondSplitPoint <= firstSplitPoint ||
          secondSplitPoint >= nodeSize) {
        Logger.error(
            'Invalid split points calculated: $firstSplitPoint, $secondSplitPoint for node with $nodeSize keys. Node size might be too small for a 3-way split.',
            label: 'BPlusTree._handleOverSizedNode');

        // Fall back to simpler strategy
        await _ultraSimpleEmergencySplit(node, path);
        return;
      }

      // ------------- MIDDLE NODE FILLING -------------
      // Copy keys and values to the middle node.
      for (int i = firstSplitPoint; i < secondSplitPoint; i++) {
        midNode.keys.add(node.keys[i]);
        if (i < node.values.length) {
          midNode.values.add(List<dynamic>.from(node.values[i]));
        } else {
          midNode.values.add([]);
        }
      }

      // ------------- RIGHT NODE FILLING -------------
      // Copy remaining elements to the right node.
      for (int i = secondSplitPoint; i < nodeSize; i++) {
        rightNode.keys.add(node.keys[i]);
        if (i < node.values.length) {
          rightNode.values.add(List<dynamic>.from(node.values[i]));
        } else {
          rightNode.values.add([]);
        }
      }

      // ------------- HANDLE CHILDREN -------------
      if (!node.isLeaf && node.children.isNotEmpty) {
        // Calculate safe child indices, these should correspond to the keys that are being moved.
        final childFirstSplit = firstSplitPoint;
        final childSecondSplit = secondSplitPoint;

        // Move children to mid node
        if (childFirstSplit < node.children.length) {
          for (int i = childFirstSplit;
              i < childSecondSplit && i < node.children.length;
              i++) {
            final child = node.children[i];
            midNode.children.add(child);
            child.parent = midNode;
          }
        }

        // Move children to right node
        if (childSecondSplit < node.children.length) {
          for (int i = childSecondSplit; i < node.children.length; i++) {
            final child = node.children[i];
            rightNode.children.add(child);
            child.parent = rightNode;
          }
        }
      } else if (node.isLeaf) {
        // Update leaf node links
        rightNode.next = node.next;
        midNode.next = rightNode;
        node.next = midNode;
      }

      // ------------- TRIM ORIGINAL NODE -------------
      // Safe removal from original node using removeRange for efficiency.
      if (firstSplitPoint < node.keys.length) {
        node.keys.removeRange(firstSplitPoint, node.keys.length);
      }
      if (firstSplitPoint < node.values.length) {
        node.values.removeRange(firstSplitPoint, node.values.length);
      }

      // Safe trimming of children if needed
      if (!node.isLeaf) {
        final childSplitPoint = firstSplitPoint;
        if (childSplitPoint < node.children.length) {
          node.children.removeRange(childSplitPoint, node.children.length);
        }
      }

      // ------------- PROMOTE KEYS TO PARENT -------------
      // Get keys to promote
      final promotedKey1 = midNode.keys.isNotEmpty ? midNode.keys.first : null;
      final promotedKey2 =
          rightNode.keys.isNotEmpty ? rightNode.keys.first : null;

      // Safety check - don't promote null keys
      if (promotedKey1 == null || promotedKey2 == null) {
        Logger.error(
            'Null promoted key during oversized node split. Mid has keys: ${midNode.keys.isNotEmpty}, Right has keys: ${rightNode.keys.isNotEmpty}',
            label: 'BPlusTree._handleOverSizedNode');

        // Fall back to emergency split
        await _ultraSimpleEmergencySplit(node, path);
        return;
      }

      // Update tree structure
      if (path.isEmpty) {
        // Create new root
        final newRoot = BPlusTreeNode(isLeaf: false);
        newRoot.keys.add(promotedKey1);
        newRoot.keys.add(promotedKey2);
        newRoot.children.add(node);
        newRoot.children.add(midNode);
        newRoot.children.add(rightNode);
        node.parent = newRoot;
        midNode.parent = newRoot;
        rightNode.parent = newRoot;
        root = newRoot;
      } else {
        // Add to existing parent
        final parent = path.last;

        // Find position for insertion
        int insertPos = 0;
        while (insertPos < parent.children.length &&
            parent.children[insertPos] != node) {
          insertPos++;
        }

        if (insertPos >= parent.children.length) {
          Logger.error(
              'Cannot find current node in parent during oversized node split',
              label: 'BPlusTree._handleOverSizedNode');
          return;
        }

        // Insert new nodes and keys
        parent.keys.insert(insertPos, promotedKey1);
        parent.children.insert(insertPos + 1, midNode);
        midNode.parent = parent;

        parent.keys.insert(insertPos + 1, promotedKey2);
        parent.children.insert(insertPos + 2, rightNode);
        rightNode.parent = parent;

        // Check if parent needs to be split
        if (parent.keys.length > order - 1) {
          await Future.delayed(Duration.zero);
          try {
            await _safeSplitNode(parent, path.sublist(0, path.length - 1));
          } catch (e) {
            Logger.error('Parent node split failed: $e',
                label: 'BPlusTree._handleOverSizedNode');
          }
        }
      }
    } catch (e, stack) {
      Logger.error('Failed to handle oversized node: $e\n$stack',
          label: 'BPlusTree._handleOverSizedNode');

      // Fall back to emergency split
      await _ultraSimpleEmergencySplit(node, path);
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
  int _compareKeys(dynamic key1, dynamic key2,
      {ComparatorFunction? comparator}) {
    if (comparator != null) {
      try {
        return comparator(key1, key2);
      } catch (e) {
        // Fallback to generic comparison if the specific one fails
        return ValueComparator.compare(key1, key2);
      }
    }
    return ValueComparator.compare(key1, key2);
  }

  /// Search for values corresponding to the specified key
  Future<List<dynamic>> search(dynamic key,
      {ComparatorFunction? comparator}) async {
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
      while (i < node.keys.length &&
          _compareKeys(searchKey, node.keys[i], comparator: comparator) >= 0) {
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
        if (_compareKeys(searchKey, node.keys[i], comparator: comparator) ==
            0) {
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
  Future<List<Map<String, dynamic>>> range(dynamic start, dynamic end,
      {ComparatorFunction? comparator}) async {
    final results = <Map<String, dynamic>>[];
    if (root == null) return results;

    // First find the starting leaf node
    BPlusTreeNode? node = root;
    while (node != null && !node.isLeaf) {
      // Find child node containing start value
      int i = 0;
      while (i < node.keys.length &&
          _compareKeys(start, node.keys[i], comparator: comparator) >= 0) {
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
        if (_compareKeys(node.keys[i], start, comparator: comparator) >= 0 &&
            _compareKeys(node.keys[i], end, comparator: comparator) <= 0) {
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
        if (_compareKeys(node.keys[i], end, comparator: comparator) > 0) {
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
      {bool includeStart = true,
      bool includeEnd = true,
      ComparatorFunction? comparator}) async {
    final results = <dynamic>[];
    if (root == null) return results;

    // Handle null values
    bool hasLowerBound = start != null;
    bool hasUpperBound = end != null;

    // Find starting leaf node
    BPlusTreeNode? node = root;
    while (node != null && !node.isLeaf) {
      int i = 0;
      // If no lower bound, start from the leftmost node
      if (hasLowerBound) {
        while (i < node.keys.length &&
            _compareKeys(start, node.keys[i], comparator: comparator) >= 0) {
          i++;
        }
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
        
        // Check lower and upper bounds
        bool passesLowerBound = !hasLowerBound || // If no lower bound, default to pass
            (includeStart 
                ? _compareKeys(key, start, comparator: comparator) >= 0
                : _compareKeys(key, start, comparator: comparator) > 0);
                
        bool passesUpperBound = !hasUpperBound || // If no upper bound, default to pass
            (includeEnd
                ? _compareKeys(key, end, comparator: comparator) <= 0
                : _compareKeys(key, end, comparator: comparator) < 0);

        // Only add results when both lower and upper bounds are satisfied
        if (passesLowerBound && passesUpperBound && i < node.values.length) {
          results.addAll(node.values[i]);
        }

        // If the upper bound is exceeded, stop searching early
        if (hasUpperBound && _compareKeys(key, end, comparator: comparator) > 0) {
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
  Future<bool> delete(dynamic key, dynamic value,
      {ComparatorFunction? comparator}) async {
    if (root == null) return false;

    final path = <BPlusTreeNode>[];
    BPlusTreeNode? currentNode = root;
    bool deleted = false;

    // Find leaf node containing target key
    while (currentNode != null && !currentNode.isLeaf) {
      path.add(currentNode);

      int i = 0;
      while (i < currentNode.keys.length &&
          _compareKeys(key, currentNode.keys[i], comparator: comparator) >= 0) {
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
        if (_compareKeys(key, currentNode.keys[i], comparator: comparator) ==
            0) {
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

  /// Scans all leaf nodes to find keys matching a pattern.
  /// This is used for non-prefix LIKE queries and can be slow.
  Future<List<dynamic>> scanAndMatch(String pattern) async {
    final results = <dynamic>[];
    if (root == null) return results;

    // Find the leftmost leaf node to start the scan
    BPlusTreeNode? node = root;
    while (node != null && !node.isLeaf) {
      if (node.children.isEmpty) break;
      node = node.children[0];
    }

    // Traverse the leaf node chain
    while (node != null) {
      for (int i = 0; i < node.keys.length; i++) {
        final key = node.keys[i];
        // Ensure the key is a string before attempting a pattern match
        if (key is String && ValueComparator.matchesPattern(key, pattern)) {
          if (i < node.values.length) {
            results.addAll(node.values[i]);
          }
        }
      }
      node = node.next; // Move to the next leaf
    }

    return results;
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
