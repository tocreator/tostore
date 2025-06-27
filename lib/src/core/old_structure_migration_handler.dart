import 'dart:convert';

import '../handler/common.dart';
import '../handler/logger.dart';
import '../model/buffer_entry.dart';
import 'data_store_impl.dart';
import 'path_manager.dart';
import 'storage_adapter.dart';

/// Old path structure migration handler
/// Handles the logic for migrating from the old version database path structure to the new version
/// This class can be removed after a complete migration is done
class OldStructureMigrationHandler {
  final DataStoreImpl _dataStore;
  final StorageAdapter _storage;

  OldStructureMigrationHandler({
    required DataStoreImpl dataStore,
    required PathManager pathManager,
    required StorageAdapter storage,
  })  : _dataStore = dataStore,
        _storage = storage;

  /// Check if old structure migration is needed
  /// If the version file exists in the root directory, it indicates an old structure database that needs migration
  Future<bool> needsMigration() async {
    final versionPath = pathJoin(_dataStore.config.dbPath!, 'version');
    final exists = await _storage.existsFile(versionPath);
    return exists; // if version file exists, it indicates that the database needs migration
  }

  /// Execute migration
  /// This method will block the main thread until migration is complete
  Future<void> migrate() async {
    if (!await needsMigration()) {
      return;
    }
    try {
      // get all space names
      List<String> allSpaces = await _getAllSpaceNames();
      Logger.info(
          'Detected ${allSpaces.length} spaces need to migrate old path structure: $allSpaces',
          label: 'OldStructureMigrationHandler.migrate');

      // migrate each space one by one
      for (final spaceName in allSpaces) {
        Logger.info('Starting to migrate space: $spaceName',
            label: 'OldStructureMigrationHandler.migrate');

        // create a migration instance for a specific space
        final migrationInstance = DataStoreImpl(
            dbPath: _dataStore.config.dbPath,
            config: _dataStore.config.copyWith(spaceName: spaceName),
            isMigrationInstance: true);
        await migrationInstance.initialize();

        // check if old structure directory exists
        final oldGlobalPath =
            pathJoin(migrationInstance.config.dbPath!, 'global');
        final oldBasesPath =
            pathJoin(migrationInstance.config.dbPath!, 'bases');
        final oldBasePath = pathJoin(oldBasesPath, spaceName);

        bool hasOldStructure = false;

        // check if old global directory exists
        if (await _storage.existsDirectory(oldGlobalPath)) {
          hasOldStructure = true;
          await _migrateOldPathStructure(
              oldGlobalPath, true, migrationInstance);
        }

        // check if old base space directory exists
        if (await _storage.existsDirectory(oldBasePath)) {
          hasOldStructure = true;
          await _migrateOldPathStructure(oldBasePath, false, migrationInstance);
        }

        if (!hasOldStructure) {
          Logger.info(
              'Space $spaceName did not detect old path structure, will create initial configuration',
              label: 'OldStructureMigrationHandler.migrate');
        } else {
          Logger.info('Space $spaceName old path structure migration completed',
              label: 'OldStructureMigrationHandler.migrate');
        }

        // close migration instance
        await migrationInstance.close();
      }

      // after all spaces migration completed, delete version file
      final versionPath = pathJoin(_dataStore.config.dbPath!, 'version');
      if (await _storage.existsFile(versionPath)) {
        await _storage.deleteFile(versionPath);
      }

      Logger.info(
          'All space old file structure migration and cleanup completed',
          label: 'OldStructureMigrationHandler.migrate');
    } catch (e) {
      Logger.error(
          'Error occurred during old directory structure migration: $e',
          label: 'OldStructureMigrationHandler.migrate');
    }
  }

  /// Get all space names
  Future<List<String>> _getAllSpaceNames() async {
    try {
      // check if global config exists
      final globalConfig = await _dataStore.getGlobalConfig();
      if (globalConfig != null && globalConfig.spaceNames.isNotEmpty) {
        return globalConfig.spaceNames.toList();
      }

      // if no global config exists, get space names from old directory structure
      final oldBasesPath = pathJoin(_dataStore.config.dbPath!, 'bases');
      if (await _storage.existsDirectory(oldBasesPath)) {
        final spaces = await _storage.listDirectory(oldBasesPath);
        // extract space names from path
        return spaces.map((path) {
          final parts = path.split(RegExp(r'[/\\]'));
          return parts.last;
        }).toList();
      }
    } catch (e) {
      Logger.error('Failed to get space names: $e',
          label: 'OldStructureMigrationHandler._getAllSpaceNames');
    }

    // if failed to get space names, return default space
    return ['default'];
  }

  /// Migrate data under the old path structure
  /// [oldPath] old path
  /// [isGlobal] whether it is a global table
  /// [dataStore] DataStore instance for migration
  Future<void> _migrateOldPathStructure(
      String oldPath, bool isGlobal, DataStoreImpl dataStore) async {
    try {
      // get all files in the directory
      final files = await _storage.listDirectory(oldPath);

      // extract table names (exclude files with extension .schema, .dat)
      final Set<String> tableNames = {};
      for (final file in files) {
        // get file name in a platform-independent way
        final parts = file.split(RegExp(r'[/\\]'));
        final fileName = parts.isNotEmpty ? parts.last : file;

        if (!fileName.contains('.')) {
          // if it is a directory, it may be a table directory
          tableNames.add(fileName);
        } else {
          // if it is a file, check the extension
          final baseName = fileName.split('.').first;
          if (fileName.endsWith('.schema') || fileName.endsWith('.dat')) {
            tableNames.add(baseName);
          }
        }
      }

      // migrate each table one by one
      for (final tableName in tableNames) {
        await _migrateTable(tableName, oldPath, isGlobal, dataStore);

        // clean old table files and directories
        final tableDir = pathJoin(oldPath, tableName);

        final dirSchemaFile = pathJoin(tableDir, '$tableName.schema');
        final dirDataFile = pathJoin(tableDir, '$tableName.dat');
        final dirMaxIdFile = pathJoin(tableDir, '$tableName.maxid');

        // delete all possible table files
        for (final path in [dirSchemaFile, dirDataFile, dirMaxIdFile]) {
          if (await _storage.existsFile(path)) {
            await _storage.deleteFile(path);
          }
        }

        // check if table directory exists
        if (await _storage.existsDirectory(tableDir)) {
          // check if table name starts with 'tables_'
          if (!tableName.startsWith('tables_')) {
            await _storage.deleteDirectory(tableDir);
          } else {
            Logger.warn(
                'Skipping deletion of directories that may conflict with the new structure: $tableName',
                label: 'OldStructureMigrationHandler._migrateOldPathStructure');
          }
        }
      }
    } catch (e) {
      Logger.error(
          'Error occurred during old path structure data migration: $e',
          label: 'OldStructureMigrationHandler._migrateOldPathStructure');
    }
  }

  /// Migrate data of a single table
  /// [tableName] table name
  /// [oldPath] old path
  /// [isGlobal] whether it is a global table
  /// [dataStore] DataStore instance for migration
  Future<void> _migrateTable(String tableName, String oldPath, bool isGlobal,
      DataStoreImpl dataStore) async {
    try {
      Logger.info(
          'Starting to migrate table: $tableName (${isGlobal ? 'Global Table' : 'Normal Table'})',
          label: 'OldStructureMigrationHandler._migrateTable');

      // build old file paths
      final oldTablePath = pathJoin(oldPath, tableName);
      final oldSchemaPath = '$oldTablePath.schema';
      final oldDataPath = '$oldTablePath.dat';
      final oldMaxIdPath = '$oldTablePath.maxid';

      // check if table structure file exists
      if (!await _storage.existsFile(oldSchemaPath)) {
        Logger.warn(
            'Table $tableName structure file does not exist, skipping migration',
            label: 'OldStructureMigrationHandler._migrateTable');
        return;
      }

      // 1. Migrate table structure (.schema)
      final schemaContent = await _storage.readAsString(oldSchemaPath);
      if (schemaContent != null && schemaContent.isNotEmpty) {
        // parse table structure
        try {
          final schemaJson = jsonDecode(schemaContent);
          // create new table using SchemaManager
          await dataStore.schemaManager!.saveTableSchema(
            tableName,
            schemaJson,
          );
          Logger.info('Table $tableName structure migration succeeded',
              label: 'OldStructureMigrationHandler._migrateTable');
        } catch (e) {
          Logger.error(
              'Error occurred during parsing table $tableName structure: $e',
              label: 'OldStructureMigrationHandler._migrateTable');
          return; // if table structure migration failed, skip this table
        }
      }

      // 2. Migrate table data (.dat)
      if (await _storage.existsFile(oldDataPath)) {
        final dataContent = await _storage.readAsString(oldDataPath);
        if (dataContent != null && dataContent.isNotEmpty) {
          // parse each line of data as JSON and write to new table
          final lines = dataContent.split('\n');
          final List<Map<String, dynamic>> records = [];

          for (final line in lines) {
            if (line.isNotEmpty) {
              try {
                final record = jsonDecode(line) as Map<String, dynamic>;
                records.add(record);
              } catch (e) {
                Logger.error(
                    'Error occurred during parsing table $tableName data line: $e',
                    label: 'OldStructureMigrationHandler._migrateTable');
                // continue to process the next line
              }
            }
          }

          // write all collected records in batch
          if (records.isNotEmpty) {
            try {
              await dataStore.tableDataManager.writeRecords(
                tableName: tableName,
                records: records,
                operationType: BufferOperationType.insert,
              );
            } catch (e) {
              Logger.error(
                  'Error occurred during writing table $tableName data: $e',
                  label: 'OldStructureMigrationHandler._migrateTable');
            }
          } else {
            Logger.info('Table $tableName has no valid data to migrate',
                label: 'OldStructureMigrationHandler._migrateTable');
          }
        }
      }

      // 3. Migrate auto increment ID (.maxid)
      if (await _storage.existsFile(oldMaxIdPath)) {
        final maxIdContent = await _storage.readAsString(oldMaxIdPath);
        if (maxIdContent != null && maxIdContent.isNotEmpty) {
          try {
            final maxId = int.parse(maxIdContent.trim());
            // get new table auto increment ID file path
            final newAutoIncrementPath =
                await dataStore.pathManager.getAutoIncrementPath(tableName);
            // write auto increment ID
            await _storage.writeAsString(
                newAutoIncrementPath, maxId.toString());
          } catch (e) {
            Logger.error(
                'Error occurred during migrating table $tableName auto increment ID: $e',
                label: 'OldStructureMigrationHandler._migrateTable');
          }
        }
      }

      Logger.info('Table $tableName migration completed',
          label: 'OldStructureMigrationHandler._migrateTable');
    } catch (e) {
      Logger.error('Error occurred during migrating table $tableName: $e',
          label: 'OldStructureMigrationHandler._migrateTable');
    }
  }
}
