import 'dart:convert';

import '../handler/logger.dart';
import 'data_store_impl.dart';
import '../model/space_path_changed_event.dart';
import '../model/table_statistics.dart';

/// statistics collector
class StatisticsCollector {
  final DataStoreImpl _dataStore;
  final Map<String, TableStatistics> _statistics = {};
  final Map<String, DateTime> _lastUpdateTime = {};
  final Duration _cacheTimeout = const Duration(minutes: 5);

  StatisticsCollector(this._dataStore);

  /// get table statistics
  TableStatistics? getTableStatistics(String tableName) {
    final lastUpdate = _lastUpdateTime[tableName];
    if (lastUpdate == null ||
        DateTime.now().difference(lastUpdate) > _cacheTimeout) {
      return null;
    }
    return _statistics[tableName];
  }

  /// collect table statistics
  Future<TableStatistics> collectTableStatistics(String tableName) async {
    try {
      final dataPath = await _dataStore.pathManager.getDataMetaPath(tableName);

      if (!await _dataStore.storage.existsFile(dataPath)) {
        throw StateError('Table $tableName does not exist');
      }

      final fieldStats = <String, FieldStatistics>{};
      var totalRows = 0;

      // collect statistics using stream
      await for (final record
          in _dataStore.tableDataManager.streamRecords(tableName)) {
        totalRows++;
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

          var value = entry.value;
          if (value is DateTime) {
            value = value.toIso8601String();
          }

          _updateFieldStats(stats, value, totalRows);
        }
      }

      final stats = TableStatistics(
        fieldStats: fieldStats,
        totalRows: totalRows,
      );

      // update cache
      _statistics[tableName] = stats;
      _lastUpdateTime[tableName] = DateTime.now();

      // save statistics to file
      await _saveStatistics(tableName, stats);

      return stats;
    } catch (e) {
      Logger.error('collect statistics failed: $e',
          label: 'StatisticsCollector');
      rethrow;
    }
  }

  /// save statistics to file
  Future<void> _saveStatistics(String tableName, TableStatistics stats) async {
    try {
      final statsPath = await _dataStore.pathManager.getStatsPath(tableName);

      await _dataStore.storage
          .writeAsString(statsPath, jsonEncode(stats.toJson()));
    } catch (e) {
      Logger.error('save statistics failed: $e', label: 'StatisticsCollector');
    }
  }

  /// invalidate cache
  void invalidateCache(String tableName) {
    _statistics.remove(tableName);
    _lastUpdateTime.remove(tableName);
  }

  /// update field statistics
  void _updateFieldStats(
    FieldStatistics stats,
    dynamic value,
    int totalRows,
  ) {
    if (value is DateTime) {
      value = value.toIso8601String();
    }

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

    // update min value
    if (stats.minValue == null || value.compareTo(stats.minValue) < 0) {
      stats = FieldStatistics(
        distinctValues: stats.distinctValues,
        minValue: value,
        maxValue: stats.maxValue,
        nullPercentage: stats.nullPercentage,
      );
    }

    // update max value
    if (stats.maxValue == null || value.compareTo(stats.maxValue) > 0) {
      stats = FieldStatistics(
        distinctValues: stats.distinctValues,
        minValue: stats.minValue,
        maxValue: value,
        nullPercentage: stats.nullPercentage,
      );
    }
  }

  /// handle base path changed
  void onBasePathChanged(SpacePathChangedEvent event) {
    // clear statistics cache
    _statistics.clear();
    _lastUpdateTime.clear();
  }
}
