import 'dart:async';

import '../model/db_result.dart';
import '../model/system_table.dart';
import '../core/data_store_impl.dart';

/// Namespace for Key-Value storage operations.
/// 键值对存储操作命名空间。
class KvStore {
  final DataStoreImpl _db;

  KvStore(this._db);

  /// Get the table name for KV storage.
  /// 获取键值对存储的表名。
  String _getTableName(bool isGlobal) => SystemTable.getKeyValueName(isGlobal);

  /// Set a key-value pair.
  /// 设置一个键值对。
  ///
  /// Parameters:
  /// - [key]: The unique identifier for the value.
  /// - [value]: The data to store (supports simple types, Maps, and Lists).
  /// - [ttl]: Optional relative expiration duration (e.g., Duration(hours: 1)).
  /// - [expiresAt]: Optional absolute expiration time.
  /// - [isGlobal]: If true, stores in the global space (shared across all spaces).
  ///
  /// 参数说明：
  /// - [key]: 值的唯一标识符。
  /// - [value]: 要存储的数据（支持基本类型、Map 和 List）。
  /// - [ttl]: 可选的相对过期时长（例如：Duration(hours: 1)）。
  /// - [expiresAt]: 可选的绝对过期时间点。
  /// - [isGlobal]: 是否存储在全局空间（在所有空间中共享）。
  Future<DbResult> set(
    String key,
    dynamic value, {
    Duration? ttl,
    DateTime? expiresAt,
    bool isGlobal = false,
  }) {
    return _db.setValue(key, value,
        ttl: ttl, expiresAt: expiresAt, isGlobal: isGlobal);
  }

  /// Get a value by key.
  /// 根据键获取值。
  ///
  /// Parameters:
  /// - [key]: The identifier of the value to retrieve.
  /// - [isGlobal]: Whether to look in the global space.
  ///
  /// 参数说明：
  /// - [key]: 要检索的值的标识符。
  /// - [isGlobal]: 是否从全局空间中查找。
  Future<dynamic> get(String key, {bool isGlobal = false}) {
    return _db.getValue(key, isGlobal: isGlobal);
  }

  /// Get value as String.
  /// 获取字符串类型的值。
  ///
  /// Parameters:
  /// - [key]: The identifier of the value to retrieve.
  /// - [isGlobal]: Whether to look in the global space.
  ///
  /// 参数说明：
  /// - [key]: 要检索的值的标识符。
  /// - [isGlobal]: 是否从全局空间中查找。
  Future<String?> getString(String key, {bool isGlobal = false}) async {
    final value = await get(key, isGlobal: isGlobal);
    return value?.toString();
  }

  /// Get value as int.
  /// 获取整数类型的值。
  ///
  /// Parameters:
  /// - [key]: The identifier of the value to retrieve.
  /// - [isGlobal]: Whether to look in the global space.
  ///
  /// 参数说明：
  /// - [key]: 要检索的值的标识符。
  /// - [isGlobal]: 是否从全局空间中查找。
  Future<int?> getInt(String key, {bool isGlobal = false}) async {
    final value = await get(key, isGlobal: isGlobal);
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  /// Get value as bool.
  /// 获取布尔类型的值。
  ///
  /// Parameters:
  /// - [key]: The identifier of the value to retrieve.
  /// - [isGlobal]: Whether to look in the global space.
  ///
  /// 参数说明：
  /// - [key]: 要检索的值的标识符。
  /// - [isGlobal]: 是否从全局空间中查找。
  Future<bool?> getBool(String key, {bool isGlobal = false}) async {
    final value = await get(key, isGlobal: isGlobal);
    if (value is bool) return value;
    if (value is String) {
      final v = value.toLowerCase();
      if (v == 'true') return true;
      if (v == 'false') return false;
    }
    return null;
  }

  /// Get value as Map.
  /// 获取 Map 类型的值。
  ///
  /// Parameters:
  /// - [key]: The identifier of the value to retrieve.
  /// - [isGlobal]: Whether to look in the global space.
  ///
  /// 参数说明：
  /// - [key]: 要检索的值的标识符。
  /// - [isGlobal]: 是否从全局空间中查找。
  Future<Map<String, dynamic>?> getMap(String key,
      {bool isGlobal = false}) async {
    final value = await get(key, isGlobal: isGlobal);
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  /// Get value as List.
  /// 获取 List 类型的值。
  ///
  /// Parameters:
  /// - [key]: The identifier of the value to retrieve.
  /// - [isGlobal]: Whether to look in the global space.
  ///
  /// 参数说明：
  /// - [key]: 要检索的值的标识符。
  /// - [isGlobal]: 是否从全局空间中查找。
  Future<List<T>?> getList<T>(String key, {bool isGlobal = false}) async {
    final value = await get(key, isGlobal: isGlobal);
    if (value is List<T>) return value;
    if (value is List) return value.cast<T>();
    return null;
  }

  /// Get all keys in the specified space, optionally filtered by prefix.
  /// 获取指定空间中的所有键，可选择按前缀过滤。
  ///
  /// Parameters:
  /// - [prefix]: Optional prefix to filter keys.
  /// - [isGlobal]: Whether to scan the global space.
  ///
  /// 参数说明：
  /// - [prefix]: 可选的键前缀过滤条件。
  /// - [isGlobal]: 是否在全局空间中扫描。
  Future<List<String>> getKeys({String? prefix, bool isGlobal = false}) {
    return _db.getKeys(prefix: prefix, isGlobal: isGlobal);
  }

  /// Check if a key exists and is not expired.
  /// 检查键是否存在且未过期。
  ///
  /// Parameters:
  /// - [key]: The identifier to check.
  /// - [isGlobal]: Whether to check in the global space.
  ///
  /// 参数说明：
  /// - [key]: 要检查的标识符。
  /// - [isGlobal]: 是否在全局空间中检查。
  Future<bool> exists(String key, {bool isGlobal = false}) {
    return _db.exists(key, isGlobal: isGlobal);
  }

  /// Remove a key-value pair.
  /// 删除一个键值对。
  ///
  /// Parameters:
  /// - [key]: The identifier of the value to remove.
  /// - [isGlobal]: Whether to remove from the global space.
  ///
  /// 参数说明：
  /// - [key]: 要删除的值的标识符。
  /// - [isGlobal]: 是否从全局空间中删除。
  Future<DbResult> remove(String key, {bool isGlobal = false}) {
    return _db.removeValue(key, isGlobal: isGlobal);
  }

  /// Remove multiple key-value pairs.
  /// 删除多个键值对。
  ///
  /// Parameters:
  /// - [keys]: List of identifiers to remove.
  /// - [isGlobal]: Whether to remove from the global space.
  ///
  /// 参数说明：
  /// - [keys]: 要删除的标识符列表。
  /// - [isGlobal]: 是否从全局空间中删除。
  Future<DbResult> removeKeys(Iterable<String> keys, {bool isGlobal = false}) {
    return _db.removeValues(keys, isGlobal: isGlobal);
  }

  /// Get remaining TTL for a key.
  /// 获取键的剩余过期时间。
  ///
  /// Parameters:
  /// - [key]: The identifier to check.
  /// - [isGlobal]: Whether to check in the global space.
  ///
  /// 参数说明：
  /// - [key]: 要检查的标识符。
  /// - [isGlobal]: 是否在全局空间中检查。
  Future<Duration?> getTtl(String key, {bool isGlobal = false}) {
    return _db.getTtl(key, isGlobal: isGlobal);
  }

  /// Set TTL for an existing key.
  /// 为现有键设置过期时间。
  ///
  /// Parameters:
  /// - [key]: The identifier to update.
  /// - [ttl]: Optional relative expiration duration.
  /// - [expiresAt]: Optional absolute expiration time point.
  /// - [isGlobal]: Whether the key is in the global space.
  ///
  /// 参数说明：
  /// - [key]: 要更新的标识符。
  /// - [ttl]: 可选的相对过期时长。
  /// - [expiresAt]: 可选的绝对过期时间点。
  /// - [isGlobal]: 该键是否处于全局空间。
  Future<DbResult> setTtl(String key, Duration? ttl,
      {DateTime? expiresAt, bool isGlobal = false}) {
    return _db.setTtl(key, ttl, expiresAt: expiresAt, isGlobal: isGlobal);
  }

  /// Atomic increment for a numeric value.
  /// 数字值的原子自增。
  ///
  /// Parameters:
  /// - [key]: The identifier to increment.
  /// - [amount]: The number to add (defaults to 1).
  /// - [isGlobal]: Whether the key is in the global space.
  ///
  /// 参数说明：
  /// - [key]: 要自增的标识符。
  /// - [amount]: 增加的数值（默认为 1）。
  /// - [isGlobal]: 该键是否处于全局空间。
  Future<DbResult> setIncrement(String key,
      {int amount = 1, bool isGlobal = false}) {
    return _db.setIncrement(key, amount: amount, isGlobal: isGlobal);
  }

  /// Watch a single key-value pair for changes.
  /// 监听单个键值对的变化。
  ///
  /// Parameters:
  /// - [key]: The identifier to watch.
  /// - [isGlobal]: Whether to watch in the global space.
  /// - [defaultValue]: Value to emit if the key does not exist.
  /// - [distinct]: If true, only emits when the value actually changes.
  ///
  /// 参数说明：
  /// - [key]: 要监听的标识符。
  /// - [isGlobal]: 是否在全局空间中监听。
  /// - [defaultValue]: 当键不存在时返回的默认值。
  /// - [distinct]: 是否仅在值发生实际变化时才触发监听。
  Stream<T?> watch<T>(
    String key, {
    bool isGlobal = false,
    T? defaultValue,
    bool distinct = true,
  }) {
    return _db.watchValue<T>(key,
        isGlobal: isGlobal, defaultValue: defaultValue, distinct: distinct);
  }

  /// Watch multiple key-value pairs for changes.
  /// 监听多个键值对的变化。
  ///
  /// Parameters:
  /// - [keys]: List of identifiers to watch.
  /// - [isGlobal]: Whether to watch in the global space.
  /// - [distinct]: If true, only emits when the snapshot changes.
  ///
  /// 参数说明：
  /// - [keys]: 要监听的标识符列表。
  /// - [isGlobal]: 是否在全局空间中监听。
  /// - [distinct]: 是否仅在快照内容发生变化时才触发监听。
  Stream<Map<String, dynamic>> watchValues(
    Iterable<String> keys, {
    bool isGlobal = false,
    bool distinct = true,
  }) {
    return _db.watchValues(keys, isGlobal: isGlobal, distinct: distinct);
  }

  /// Clear all key-value pairs in the specified space.
  /// 清空指定空间中的所有键值对格式数据。
  ///
  /// Parameters:
  /// - [isGlobal]: Whether to clear the global space or the current local space.
  ///
  /// 参数说明：
  /// - [isGlobal]: 是清空全局空间还是当前的本地空间。
  Future<DbResult> clear({bool isGlobal = false}) {
    return _db.clear(_getTableName(isGlobal), registerWalOp: true);
  }

  /// Count the number of keys in the specified space.
  /// 统计指定空间中的键总数。
  ///
  /// Parameters:
  /// - [isGlobal]: Whether to count in the global space or current local space.
  ///
  /// 参数说明：
  /// - [isGlobal]: 是统计全局空间还是当前本地空间。
  Future<int> count({bool isGlobal = false}) async {
    await _db.ensureInitialized();
    final tableName = _getTableName(isGlobal);
    return await _db.tableDataManager.getTableRecordCount(tableName);
  }
}
