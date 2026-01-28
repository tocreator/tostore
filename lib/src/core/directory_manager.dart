import '../model/space_config.dart';
import '../model/global_config.dart';
import '../model/meta_info.dart';
import '../handler/common.dart';
import '../handler/logger.dart';
import 'data_store_impl.dart';

/// Directory manager, responsible for table directory allocation and mapping logic
class DirectoryManager {
  final DataStoreImpl _dataStore;

  DirectoryManager(this._dataStore);

  /// Get directory identifier key (for directoryUsageMap)
  String _getDirectoryKey(String spacePrefix, int dirIndex) {
    return '$spacePrefix:$dirIndex';
  }

  /// Get table key (for tableDirectoryMap)
  String _getTableKey(String spacePrefix, String tableName) {
    return '$spacePrefix:$tableName';
  }

  /// Get table directory path based on space name and table name
  /// Returns null if table directory mapping is not found in space configuration
  Future<String?> getTableDirectoryPath(String tableName,
      {String? spaceName}) async {
    final currentSpaceName = spaceName ?? _dataStore.currentSpaceName;

    try {
      // Check if table is global table
      final isGlobal = await isTableGlobal(tableName);
      if (isGlobal == null) {
        // Table does not exist
        return null;
      }

      // Determine space prefix
      final spacePrefix = isGlobal ? 'global' : currentSpaceName;
      final tableKey = _getTableKey(spacePrefix, tableName);

      // Get configuration
      if (isGlobal) {
        final globalConfig = await _dataStore.getGlobalConfig();
        if (globalConfig == null) return null;

        final dirInfo = globalConfig.tableDirectoryMap[tableKey];
        if (dirInfo == null) return null;

        final dirIndex = dirInfo.dirIndex;
        final subDir = pathJoin(
            _dataStore.pathManager.getGlobalPath(), 'tables_$dirIndex');
        return pathJoin(subDir, tableName);
      } else {
        final spaceConfig = await _dataStore.getSpaceConfig();
        if (spaceConfig == null) return null;

        final dirInfo = spaceConfig.tableDirectoryMap[tableKey];
        if (dirInfo == null) return null;

        final dirIndex = dirInfo.dirIndex;
        final subDir =
            pathJoin(_dataStore.pathManager.getSpacePath(), 'tables_$dirIndex');
        return pathJoin(subDir, tableName);
      }
    } catch (e) {
      Logger.error(
        'Failed to get table directory path: $e',
        label: 'DirectoryManager.getTableDirectoryPath',
      );
      return null;
    }
  }

  /// Allocate storage directory index for table
  /// Returns allocated directory index for table
  Future<int> allocateTableDirectory(String tableName, bool isGlobal) async {
    final spacePrefix = isGlobal ? 'global' : _dataStore.config.spaceName;
    final tableKey = _getTableKey(spacePrefix, tableName);

    if (isGlobal) {
      final globalConfig = await _dataStore.getGlobalConfig() ?? GlobalConfig();
      if (globalConfig.tableDirectoryMap.containsKey(tableKey)) {
        final dirInfo = globalConfig.tableDirectoryMap[tableKey]!;
        return dirInfo.dirIndex;
      }

      // Find or create directory
      final selectedDirIndex =
          await _allocateDirectory(globalConfig, spacePrefix);
      final directoryKey = _getDirectoryKey(spacePrefix, selectedDirIndex);
      final currentCount = globalConfig.directoryUsageMap[directoryKey] ?? 0;

      // Update metadata
      final updatedDirectoryMap =
          Map<String, int>.from(globalConfig.directoryUsageMap);
      updatedDirectoryMap[directoryKey] = currentCount + 1;

      final updatedTableDirMap =
          Map<String, TableDirectoryInfo>.from(globalConfig.tableDirectoryMap);
      updatedTableDirMap[tableKey] = TableDirectoryInfo(
        isGlobal: isGlobal,
        dirIndex: selectedDirIndex,
      );

      final updatedConfig = globalConfig.copyWith(
        directoryUsageMap: updatedDirectoryMap,
        tableDirectoryMap: updatedTableDirMap,
      );

      // Save updated configuration
      await _dataStore.saveGlobalConfig(updatedConfig);

      // Ensure directory exists
      final dirPath = _getTableSubDirectoryPath(isGlobal, selectedDirIndex);
      await _dataStore.storage.ensureDirectoryExists(dirPath);

      return selectedDirIndex;
    } else {
      final spaceConfig = await _dataStore.getSpaceConfig() ??
          SpaceConfig(
              current: const EncryptionKeyInfo(key: '', keyId: 0), version: 0);
      if (spaceConfig.tableDirectoryMap.containsKey(tableKey)) {
        final dirInfo = spaceConfig.tableDirectoryMap[tableKey]!;
        return dirInfo.dirIndex;
      }

      // Find or create directory
      final selectedDirIndex =
          await _allocateDirectory(spaceConfig, spacePrefix);
      final directoryKey = _getDirectoryKey(spacePrefix, selectedDirIndex);
      final currentCount = spaceConfig.directoryUsageMap[directoryKey] ?? 0;

      // Update metadata
      final updatedDirectoryMap =
          Map<String, int>.from(spaceConfig.directoryUsageMap);
      updatedDirectoryMap[directoryKey] = currentCount + 1;

      final updatedTableDirMap =
          Map<String, TableDirectoryInfo>.from(spaceConfig.tableDirectoryMap);
      updatedTableDirMap[tableKey] = TableDirectoryInfo(
        isGlobal: isGlobal,
        dirIndex: selectedDirIndex,
      );

      final updatedConfig = spaceConfig.copyWith(
        directoryUsageMap: updatedDirectoryMap,
        tableDirectoryMap: updatedTableDirMap,
      );

      // save updated configuration
      await _dataStore.saveSpaceConfigToFile(updatedConfig);

      // ensure directory exists
      final dirPath = _getTableSubDirectoryPath(isGlobal, selectedDirIndex);
      await _dataStore.storage.ensureDirectoryExists(dirPath);

      return selectedDirIndex;
    }
  }

  /// Find or allocate directory index
  Future<int> _allocateDirectory(dynamic config, String spacePrefix) async {
    // Find directory with least usage
    int selectedDirIndex = 0;
    int minTablesCount = _dataStore.maxEntriesPerDir +
        1; // Set to be larger than max, ensure replacement

    // Iterate through existing directories, find the one with the least tables
    for (var entry in config.directoryUsageMap.entries) {
      final key = entry.key;
      final count = entry.value;

      // Only process directory keys that match the prefix
      if (key.startsWith('$spacePrefix:')) {
        final parts = key.split(':');
        if (parts.length == 2) {
          final dirIndex = int.tryParse(parts[1]);
          if (dirIndex != null &&
              count < minTablesCount &&
              count < _dataStore.maxEntriesPerDir) {
            selectedDirIndex = dirIndex;
            minTablesCount = count;
          }
        }
      }
    }

    // If all directories are full or no directories exist, create a new one
    if (minTablesCount >= _dataStore.maxEntriesPerDir) {
      // Find the largest existing directory index
      int maxDirIndex = -1;
      for (var key in config.directoryUsageMap.keys) {
        if (key.startsWith('$spacePrefix:')) {
          final parts = key.split(':');
          if (parts.length == 2) {
            final dirIndex = int.tryParse(parts[1]);
            if (dirIndex != null && dirIndex > maxDirIndex) {
              maxDirIndex = dirIndex;
            }
          }
        }
      }

      // Use the next available index
      selectedDirIndex = maxDirIndex + 1;
    }

    return selectedDirIndex;
  }

  /// Release table directory, called when table is deleted
  Future<void> releaseTableDirectory(String tableName) async {
    final isGlobal = await isTableGlobal(tableName);
    if (isGlobal == null) return;
    final spacePrefix = isGlobal ? 'global' : _dataStore.config.spaceName;
    final tableKey = _getTableKey(spacePrefix, tableName);

    if (isGlobal) {
      final globalConfig = await _dataStore.getGlobalConfig() ?? GlobalConfig();
      if (!globalConfig.tableDirectoryMap.containsKey(tableKey)) {
        return;
      }

      final dirInfo = globalConfig.tableDirectoryMap[tableKey]!;
      final dirIndex = dirInfo.dirIndex;
      final directoryKey = _getDirectoryKey(spacePrefix, dirIndex);

      // Update directory usage
      final updatedDirectoryMap =
          Map<String, int>.from(globalConfig.directoryUsageMap);
      final currentCount = updatedDirectoryMap[directoryKey] ?? 0;
      if (currentCount > 0) {
        updatedDirectoryMap[directoryKey] = currentCount - 1;
      }

      // Update table mapping
      final updatedTableDirMap =
          Map<String, TableDirectoryInfo>.from(globalConfig.tableDirectoryMap);
      updatedTableDirMap.remove(tableKey);

      final updatedConfig = globalConfig.copyWith(
        directoryUsageMap: updatedDirectoryMap,
        tableDirectoryMap: updatedTableDirMap,
      );

      // Save updated configuration
      await _dataStore.saveGlobalConfig(updatedConfig);
    } else {
      final spaceConfig = await _dataStore.getSpaceConfig() ??
          SpaceConfig(
              current: const EncryptionKeyInfo(key: '', keyId: 0), version: 0);
      if (!spaceConfig.tableDirectoryMap.containsKey(tableKey)) {
        return;
      }

      final dirInfo = spaceConfig.tableDirectoryMap[tableKey]!;
      final dirIndex = dirInfo.dirIndex;
      final directoryKey = _getDirectoryKey(spacePrefix, dirIndex);

      // Update directory usage
      final updatedDirectoryMap =
          Map<String, int>.from(spaceConfig.directoryUsageMap);
      final currentCount = updatedDirectoryMap[directoryKey] ?? 0;
      if (currentCount > 0) {
        updatedDirectoryMap[directoryKey] = currentCount - 1;
      }

      // Update table mapping
      final updatedTableDirMap =
          Map<String, TableDirectoryInfo>.from(spaceConfig.tableDirectoryMap);
      updatedTableDirMap.remove(tableKey);

      final updatedConfig = spaceConfig.copyWith(
        directoryUsageMap: updatedDirectoryMap,
        tableDirectoryMap: updatedTableDirMap,
      );

      // Save updated configuration
      await _dataStore.saveSpaceConfigToFile(updatedConfig);
    }
  }

  /// Get table directory information
  Future<TableDirectoryInfo?> getTableDirectoryInfo(
      String tableName, bool isGlobal) async {
    final spacePrefix = isGlobal ? 'global' : _dataStore.config.spaceName;
    final tableKey = _getTableKey(spacePrefix, tableName);

    if (isGlobal) {
      final globalConfig = await _dataStore.getGlobalConfig() ?? GlobalConfig();
      return globalConfig.tableDirectoryMap[tableKey];
    } else {
      final spaceConfig = await _dataStore.getSpaceConfig() ??
          SpaceConfig(
              current: const EncryptionKeyInfo(key: '', keyId: 0), version: 0);
      return spaceConfig.tableDirectoryMap[tableKey];
    }
  }

  /// Get table directory index
  Future<int?> getTableDirectoryIndex(String tableName, bool isGlobal) async {
    final dirInfo = await getTableDirectoryInfo(tableName, isGlobal);
    if (dirInfo != null) {
      return dirInfo.dirIndex;
    }
    return null;
  }

  /// Get whether the table is a global table
  Future<bool?> isTableGlobal(String tableName) async {
    try {
      // First try to get from table structure
      final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
      if (schema != null) {
        return schema.isGlobal;
      }

      // If table structure is not available, try to find in global configuration
      final globalConfig = await _dataStore.getGlobalConfig();
      if (globalConfig != null) {
        final globalTableKey = _getTableKey('global', tableName);
        if (globalConfig.tableDirectoryMap.containsKey(globalTableKey)) {
          return true; // Found in global configuration, indicating it is a global table
        }
      }

      // Try to find in current space configuration
      final spaceConfig = await _dataStore.getSpaceConfig();
      if (spaceConfig != null) {
        final spaceTableKey =
            _getTableKey(_dataStore.currentSpaceName, tableName);
        if (spaceConfig.tableDirectoryMap.containsKey(spaceTableKey)) {
          return false; // Found in space configuration, indicating it is a space table
        }
      }

      // If not found, return null indicating table does not exist
      return null;
    } catch (e) {
      Logger.error(
        'Failed to get table global property: $e',
        label: 'DirectoryManager.isTableGlobal',
      );
      return null;
    }
  }

  /// Get table subdirectory path
  String _getTableSubDirectoryPath(bool isGlobal, int dirIndex) {
    if (isGlobal) {
      return pathJoin(
          _dataStore.pathManager.getGlobalPath(), 'tables_$dirIndex');
    }
    return pathJoin(_dataStore.pathManager.getSpacePath(), 'tables_$dirIndex');
  }

  /// Get table actual path
  /// If table does not exist, return null
  Future<String?> getTablePathIfExists(String tableName) async {
    final schema = await _dataStore.schemaManager?.getTableSchema(tableName);
    if (schema == null) {
      return null;
    }
    final isGlobal = schema.isGlobal;
    final dirInfo = await getTableDirectoryInfo(tableName, isGlobal);
    if (dirInfo == null) {
      return await createTablePathIfNotExists(tableName, isGlobal);
    }

    final tablePath =
        _getTablePath(tableName, dirInfo.isGlobal, dirInfo.dirIndex);
    await _dataStore.storage.ensureDirectoryExists(tablePath);

    return tablePath;
  }

  /// Get table path (internal method)
  String _getTablePath(String tableName, bool isGlobal, int dirIndex) {
    final subDir = _getTableSubDirectoryPath(isGlobal, dirIndex);
    return pathJoin(subDir, tableName);
  }

  /// Get table path, if table does not exist, allocate directory and create path
  Future<String> createTablePathIfNotExists(
      String tableName, bool isGlobal) async {
    // Allocate directory and create path directly
    final dirIndex = await allocateTableDirectory(tableName, isGlobal);
    final dirInfo = await getTableDirectoryInfo(tableName, isGlobal);
    if (dirInfo == null) {
      throw StateError('Failed to allocate directory for table $tableName');
    }
    final tablePath = _getTablePath(tableName, isGlobal, dirIndex);

    // Ensure directory exists
    await _dataStore.storage.ensureDirectoryExists(tablePath);

    return tablePath;
  }

  /// Remove table directory mapping from space configuration
  /// Returns whether removal was successful
  Future<bool> removeTableDirectoryMapping(String tableName,
      {String? spaceName}) async {
    final currentSpaceName = spaceName ?? _dataStore.currentSpaceName;

    try {
      // Check if table is global table
      final isGlobal = await isTableGlobal(tableName);
      if (isGlobal == null) {
        // Table does not exist
        return false;
      }

      // Determine space prefix
      final spacePrefix = isGlobal ? 'global' : currentSpaceName;
      final tableKey = _getTableKey(spacePrefix, tableName);

      // Update configuration
      if (isGlobal) {
        final globalConfig = await _dataStore.getGlobalConfig();
        if (globalConfig == null) return false;

        if (!globalConfig.tableDirectoryMap.containsKey(tableKey)) {
          return false; // Mapping does not exist
        }

        // Update mapping
        final updatedTableDirMap = Map<String, TableDirectoryInfo>.from(
            globalConfig.tableDirectoryMap);
        updatedTableDirMap.remove(tableKey);

        // Save updated configuration
        final updatedConfig = globalConfig.copyWith(
          tableDirectoryMap: updatedTableDirMap,
        );
        await _dataStore.saveGlobalConfig(updatedConfig);

        return true;
      } else {
        final spaceConfig = await _dataStore.getSpaceConfig();
        if (spaceConfig == null) return false;

        if (!spaceConfig.tableDirectoryMap.containsKey(tableKey)) {
          return false; // Mapping does not exist
        }

        // Update mapping
        final updatedTableDirMap =
            Map<String, TableDirectoryInfo>.from(spaceConfig.tableDirectoryMap);
        updatedTableDirMap.remove(tableKey);

        // Save updated configuration
        final updatedConfig = spaceConfig.copyWith(
          tableDirectoryMap: updatedTableDirMap,
        );
        await _dataStore.saveSpaceConfigToFile(updatedConfig);

        return true;
      }
    } catch (e) {
      Logger.error(
        'Failed to remove table directory mapping: $e',
        label: 'DirectoryManager.removeTableDirectoryMapping',
      );
      return false;
    }
  }
}
