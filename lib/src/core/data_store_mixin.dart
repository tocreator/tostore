import 'package:flutter/foundation.dart';

/// data store internal method mixin
mixin DataStoreMixin {
  /// internal update method
  @protected
  Future<void> updateInternal(
      String tableName, Map<String, dynamic> data, Map<String, dynamic> where);

  /// internal delete method
  @protected
  Future<void> deleteInternal(String tableName, Map<String, dynamic> where);

  /// internal query method
  @protected
  Future<List<Map<String, dynamic>>> queryByMap(
    String tableName, {
    Map<String, dynamic>? where,
    List<String>? orderBy,
    int? limit,
    int? offset,
  });

  /// get table path
  @protected
  String getTablePath(String tableName);
}
