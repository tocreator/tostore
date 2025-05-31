import 'dart:convert';

import 'cache.dart';

/// Database structure cache
/// Used to store index data
class StructureCache {
  /// Index data cache - Map<cache key(tableName:indexName), index data>
  final Map<String, Map<String, dynamic>> indices;

  /// Creation time
  final DateTime createTime;

  /// Cache type
  final CacheType cacheType;

  StructureCache({
    Map<String, Map<String, dynamic>>? indices,
    DateTime? createTime,
    this.cacheType = CacheType.runtime,
  })  : indices = indices ?? {},
        createTime = createTime ?? DateTime.now();

  /// Create startup cache instance
  factory StructureCache.startup({
    Map<String, Map<String, dynamic>>? indices,
    DateTime? createTime,
  }) {
    return StructureCache(
      indices: indices,
      createTime: createTime,
      cacheType: CacheType.startup,
    );
  }

  /// Create runtime cache instance
  factory StructureCache.runtime({
    Map<String, Map<String, dynamic>>? indices,
    DateTime? createTime,
  }) {
    return StructureCache(
      indices: indices,
      createTime: createTime,
      cacheType: CacheType.runtime,
    );
  }

  /// Add index data
  void addIndexData(
      String tableName, String indexName, Map<String, dynamic> indexData) {
    final key = '$tableName:$indexName';
    indices[key] = indexData;
  }

  /// Get index data
  Map<String, dynamic>? getIndexData(String tableName, String indexName) {
    final key = '$tableName:$indexName';
    return indices[key];
  }

  /// Serialize to JSON string
  String toJson() {
    final data = {
      'indices': indices,
      'createTime': createTime.toIso8601String(),
      'cacheType': cacheType.index,
    };
    return jsonEncode(data);
  }

  /// Deserialize from JSON string
  factory StructureCache.fromJson(String jsonString) {
    try {
      final data = jsonDecode(jsonString) as Map<String, dynamic>;

      final indicesData = data['indices'] as Map<String, dynamic>? ?? {};
      final indices = <String, Map<String, dynamic>>{};
      for (final entry in indicesData.entries) {
        indices[entry.key] = Map<String, dynamic>.from(entry.value);
      }

      // Parse cache type, default to runtime cache
      final cacheTypeIndex =
          data['cacheType'] as int? ?? CacheType.runtime.index;
      final cacheType = CacheType.values[cacheTypeIndex];

      return StructureCache(
        indices: indices,
        createTime: DateTime.parse(data['createTime'] as String),
        cacheType: cacheType,
      );
    } catch (e) {
      return StructureCache();
    }
  }

  /// Copy cache and optionally modify some properties
  StructureCache copyWith({
    Map<String, Map<String, dynamic>>? indices,
    DateTime? createTime,
    CacheType? cacheType,
  }) {
    // Deep copy index data
    final newIndices = <String, Map<String, dynamic>>{};
    for (final entry in this.indices.entries) {
      newIndices[entry.key] = Map<String, dynamic>.from(entry.value);
    }

    return StructureCache(
      indices: indices ?? newIndices,
      createTime: createTime ?? this.createTime,
      cacheType: cacheType ?? this.cacheType,
    );
  }

  /// Clear cache
  void clear() {
    indices.clear();
  }

  /// Count number of indices
  int get indexCount => indices.length;

  /// Check if it's a startup cache
  bool get isStartupCache => cacheType == CacheType.startup;

  @override
  String toString() {
    return 'DbStructureCache{Type: ${cacheType == CacheType.startup ? "Startup Cache" : "Runtime Cache"}, Indexes: $indexCount}';
  }
}
