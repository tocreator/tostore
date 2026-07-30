import 'encryption_domain.dart';

/// Status of a database-wide key re-encryption migration.
enum KeyMigrationStatus {
  running,
  completed,
  failed;

  static KeyMigrationStatus fromString(String value) {
    switch (value) {
      case 'running':
        return KeyMigrationStatus.running;
      case 'completed':
        return KeyMigrationStatus.completed;
      case 'failed':
        return KeyMigrationStatus.failed;
      default:
        return KeyMigrationStatus.running;
    }
  }

  String toJsonValue() => name;
}

/// Natural-turnover snapshots taken when a key migration starts.
class KeyMigrationDomainSnapshots {
  /// WAL checkpoint pointer string at migration start.
  final String? walCheckpointAtStart;

  /// Active txn partition indexes at start; shrink as partitions retire.
  final List<int> txnActivePartitionsAtStart;

  /// Page-redo batch ids pending at start; shrink as batches are deleted.
  final List<String> pageRedoBatchIdsAtStart;

  const KeyMigrationDomainSnapshots({
    this.walCheckpointAtStart,
    this.txnActivePartitionsAtStart = const [],
    this.pageRedoBatchIdsAtStart = const [],
  });

  KeyMigrationDomainSnapshots copyWith({
    String? walCheckpointAtStart,
    List<int>? txnActivePartitionsAtStart,
    List<String>? pageRedoBatchIdsAtStart,
    bool clearWalCheckpoint = false,
  }) {
    return KeyMigrationDomainSnapshots(
      walCheckpointAtStart: clearWalCheckpoint
          ? null
          : (walCheckpointAtStart ?? this.walCheckpointAtStart),
      txnActivePartitionsAtStart:
          txnActivePartitionsAtStart ?? this.txnActivePartitionsAtStart,
      pageRedoBatchIdsAtStart:
          pageRedoBatchIdsAtStart ?? this.pageRedoBatchIdsAtStart,
    );
  }
}

/// Persisted metadata for an in-progress or completed key migration.
class KeyMigrationInfo {
  final int targetKeyId;
  final KeyMigrationStatus status;
  final String createdAt;

  /// Per-[EncryptionDomain] completion flags.
  final Map<EncryptionDomain, bool> domainCompleted;

  /// Snapshots for natural-turnover domains. Non-null once primed.
  final KeyMigrationDomainSnapshots? snapshots;

  const KeyMigrationInfo({
    required this.targetKeyId,
    required this.status,
    required this.createdAt,
    this.domainCompleted = const {},
    this.snapshots,
  });

  bool get isRunning => status == KeyMigrationStatus.running;

  bool isDomainDone(EncryptionDomain domain) => domainCompleted[domain] == true;

  KeyMigrationInfo markDomainDone(EncryptionDomain domain) {
    if (isDomainDone(domain)) return this;
    return copyWith(
      domainCompleted: {
        ...domainCompleted,
        domain: true,
      },
    );
  }

  /// True when every [EncryptionDomain] relevant to this run is done.
  bool get allDomainsComplete {
    for (final domain in EncryptionDomain.values) {
      if (!isDomainDone(domain)) return false;
    }
    return true;
  }

  /// Fresh running info with all domains marked incomplete.
  factory KeyMigrationInfo.start({
    required int targetKeyId,
    KeyMigrationDomainSnapshots? snapshots,
  }) {
    final completed = <EncryptionDomain, bool>{};
    for (final d in EncryptionDomain.values) {
      completed[d] = false;
    }
    return KeyMigrationInfo(
      targetKeyId: targetKeyId,
      status: KeyMigrationStatus.running,
      createdAt: DateTime.now().toUtc().toIso8601String(),
      domainCompleted: completed,
      snapshots: snapshots,
    );
  }

  KeyMigrationInfo copyWith({
    int? targetKeyId,
    KeyMigrationStatus? status,
    String? createdAt,
    Map<EncryptionDomain, bool>? domainCompleted,
    KeyMigrationDomainSnapshots? snapshots,
    bool clearSnapshots = false,
  }) {
    return KeyMigrationInfo(
      targetKeyId: targetKeyId ?? this.targetKeyId,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      domainCompleted: domainCompleted ?? this.domainCompleted,
      snapshots: clearSnapshots ? null : (snapshots ?? this.snapshots),
    );
  }
}
