import 'dart:convert';
import 'dart:io';

import '../handler/logger.dart';
import '../core/data_store_impl.dart';
import '../model/base_path_changed_event.dart';
import 'table_statistics.dart';

/// 统计信息收集器
class StatisticsCollector {
  final DataStoreImpl _dataStore;
  final Map<String, TableStatistics> _statistics = {};
  final Map<String, DateTime> _lastUpdateTime = {};
  final Duration _cacheTimeout = const Duration(minutes: 5);

  StatisticsCollector(this._dataStore);

  /// 获取表统计信息
  TableStatistics? getTableStatistics(String tableName) {
    final lastUpdate = _lastUpdateTime[tableName];
    if (lastUpdate == null ||
        DateTime.now().difference(lastUpdate) > _cacheTimeout) {
      return null;
    }
    return _statistics[tableName];
  }

  /// 收集表统计信息
  Future<TableStatistics> collectTableStatistics(String tableName) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      final dataPath =
          _dataStore.config.getDataPath(tableName, schema.isGlobal);
      final dataFile = File(dataPath);
      if (!await dataFile.exists()) {
        throw StateError('Table $tableName does not exist');
      }

      final lines = await dataFile.readAsLines();
      final fieldStats = <String, FieldStatistics>{};
      var totalRows = 0;

      // 收集每条的统计信息
      for (var line in lines) {
        if (line.trim().isEmpty) continue;
        totalRows++;

        final record = jsonDecode(line) as Map<String, dynamic>;
        for (var entry in record.entries) {
          final stats = fieldStats.putIfAbsent(
            entry.key,
            () => FieldStatistics(
              distinctValues: 0,
              minValue: null,
              maxValue: null,
              nullPercentage: 0.0,
            ),
          );
          _updateFieldStats(stats, entry.value, totalRows);
        }
      }

      final stats = TableStatistics(
        fieldStats: fieldStats,
        totalRows: totalRows,
      );

      // 更新缓存
      _statistics[tableName] = stats;
      _lastUpdateTime[tableName] = DateTime.now();

      // 保存统计信息到文件
      await _saveStatistics(tableName, stats);

      return stats;
    } catch (e) {
      Logger.error('收集统计信息失败: $e', label: 'StatisticsCollector');
      rethrow;
    }
  }

  /// 保存统计信息到文件
  Future<void> _saveStatistics(String tableName, TableStatistics stats) async {
    try {
      final schema = await _dataStore.getTableSchema(tableName);
      final statsPath =
          _dataStore.config.getStatsPath(tableName, schema.isGlobal);
      final statsFile = File(statsPath);
      await statsFile.writeAsString(jsonEncode(stats.toJson()));
    } catch (e) {
      Logger.error('保存统计信息失败: $e', label: 'StatisticsCollector');
    }
  }

  /// 清除缓存
  void invalidateCache(String tableName) {
    _statistics.remove(tableName);
    _lastUpdateTime.remove(tableName);
  }

  /// 更新字段统计信息
  void _updateFieldStats(
    FieldStatistics stats,
    dynamic value,
    int totalRows,
  ) {
    if (value == null) {
      stats = FieldStatistics(
        distinctValues: stats.distinctValues,
        minValue: stats.minValue,
        maxValue: stats.maxValue,
        nullPercentage:
            (stats.nullPercentage * (totalRows - 1) + 1) / totalRows,
      );
      return;
    }

    // 更新最小值
    if (stats.minValue == null || value.compareTo(stats.minValue) < 0) {
      stats = FieldStatistics(
        distinctValues: stats.distinctValues,
        minValue: value,
        maxValue: stats.maxValue,
        nullPercentage: stats.nullPercentage,
      );
    }

    // 更新最大值
    if (stats.maxValue == null || value.compareTo(stats.maxValue) > 0) {
      stats = FieldStatistics(
        distinctValues: stats.distinctValues,
        minValue: stats.minValue,
        maxValue: value,
        nullPercentage: stats.nullPercentage,
      );
    }
  }

  /// 处理基础空间变更
  void onBasePathChanged(BasePathChangedEvent event) {
    // 清理统计信息缓存
    _statistics.clear();
    _lastUpdateTime.clear();
  }
}
