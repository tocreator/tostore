import 'backup_scope.dart';

/// Structured backup metadata stored as meta.json inside each backup entry
class BackupMetadata {
  final String timestamp; // ISO8601 string
  final int version; // database version at backup time
  final BackupScope scope; // backup scope
  final bool compressed; // whether the backup entry is a zip archive

  const BackupMetadata({
    required this.timestamp,
    required this.version,
    required this.scope,
    required this.compressed,
  });

  Map<String, dynamic> toJson() => {
        'timestamp': timestamp,
        'version': version,
        'scope': scope.toString().split('.').last,
        'compressed': compressed,
      };

  static BackupMetadata fromJson(Map<String, dynamic> json) {
    final String ts = (json['timestamp'] as String?) ?? '';
    final int ver = (json['version'] as num?)?.toInt() ?? 0;
    final bool comp = (json['compressed'] as bool?) ?? false;

    // Scope: prefer explicit scope; fall back to legacy 'type' (full/partial)
    final String? scopeStr = json['scope'] as String?;
    BackupScope scope;
    if (scopeStr != null) {
      switch (scopeStr) {
        case 'database':
          scope = BackupScope.database;
          break;
        case 'currentSpace':
          scope = BackupScope.currentSpace;
          break;
        case 'currentSpaceWithGlobal':
          scope = BackupScope.currentSpaceWithGlobal;
          break;
        default:
          scope = BackupScope.currentSpaceWithGlobal;
      }
    } else {
      // Legacy compatibility: json['type'] == 'full' => database; otherwise partial
      final String legacyType = (json['type'] as String?) ?? 'partial';
      scope = legacyType == 'full'
          ? BackupScope.database
          : BackupScope.currentSpaceWithGlobal;
    }

    return BackupMetadata(
      timestamp: ts,
      version: ver,
      scope: scope,
      compressed: comp,
    );
  }
}
