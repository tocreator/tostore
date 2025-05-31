import 'dart:async';
import '../handler/logger.dart';
import '../core/data_store_impl.dart';

/// Web stub implementation for BackupManager
/// Only implements minimal functionality needed for web compatibility
class BackupManager {
  final DataStoreImpl _dataStore;

  BackupManager(this._dataStore);

  /// Create backup for web platform (limited functionality)
  Future<String> createBackup(
      {bool compress = false, bool fullBackup = false}) async {
    Logger.warn('Full backup functionality is limited on web platform',
        label: 'BackupManager.createBackup');

    return 'web-backup-not-supported';
  }

  /// Restore backup - not fully supported on web
  Future<bool> restore(String backupPath) async {
    Logger.warn('Backup restoration is not supported on web platform',
        label: 'BackupManager.restore');
    return false;
  }

  /// Get backup size - stubbed implementation
  Future<int> getBackupSize(String backupPath) async {
    _dataStore.config.spaceName;
    return 0;
  }
}
