import 'package:flutter/foundation.dart';

/// 数据存储内部方法 Mixin
mixin DataStoreMixin {
  /// 内部更新方法
  @protected
  Future<void> updateInternal(
      String tableName, Map<String, dynamic> data, Map<String, dynamic> where);

  /// 内部删除方法
  @protected
  Future<void> deleteInternal(String tableName, Map<String, dynamic> where);

  /// 内部查询方法
  @protected
  Future<List<Map<String, dynamic>>> queryByMap(
    String tableName, {
    Map<String, dynamic>? where,
    List<String>? orderBy,
    int? limit,
    int? offset,
  });

  /// 获取表路径
  @protected
  String getTablePath(String tableName);
}
