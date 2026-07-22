import '../handler/common.dart';
import 'backup_scope.dart';

/// Structured backup metadata stored as `meta.tobf` (v2+) inside each backup.
///
/// Legacy packages used `meta.json`; parsing lives in
/// `upgrades/legacy_model/pre_v3.dart` only.
class BackupMetadata {
  final String timestamp; // ISO8601 string (filesystem-safe form)
  final int backupFormatVersion; // backup package format version
  final BackupScope scope; // backup scope
  final bool compressed; // whether the backup entry is a zip archive

  const BackupMetadata({
    required this.timestamp,
    this.backupFormatVersion = InternalConfig.currentBackupFormatVersion,
    required this.scope,
    required this.compressed,
  });
}
