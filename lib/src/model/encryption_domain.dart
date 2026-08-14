/// Exhaustive set of on-disk domains that participate in encodingKey migration.
///
/// No `default` in switches: adding a member forces migration + completion logic updates.
enum EncryptionDomain {
  /// Table B+Tree data pages (fine-grained checkpoint in `_system_key_migration`).
  tableData,

  /// Non-vector B+Tree index pages (sync overwrite with table rewrite; no isBuilding).
  btreeIndex,

  /// Vector / NGH pages when encrypted under [EncryptionScope.full].
  vectorIndex,

  /// Table partition page0 TableDataMeta shells (incl. empty trees).
  tableMeta,

  /// B+Tree index partition page0 IndexMeta shells (incl. empty indexes).
  indexMeta,

  /// `migration_meta.tobf` under full scope.
  migrationMeta,

  /// WAL partitions -- natural turnover via checkpoint watermark.
  wal,

  /// Parallel-journal page redo logs -- natural turnover.
  pageRedoLog,

  /// Transaction log partitions -- natural turnover via activePartitions diff.
  transactionLog,
}

/// Classification helpers -- keep switches exhaustive (no default).
abstract final class EncryptionDomainPolicy {
  EncryptionDomainPolicy._();

  /// Long-lived domains that must be actively rewritten on encodingKey change.
  static bool requiresRewrite(EncryptionDomain domain) {
    switch (domain) {
      case EncryptionDomain.tableData:
      case EncryptionDomain.btreeIndex:
      case EncryptionDomain.vectorIndex:
      case EncryptionDomain.tableMeta:
      case EncryptionDomain.indexMeta:
      case EncryptionDomain.migrationMeta:
        return true;
      case EncryptionDomain.wal:
      case EncryptionDomain.pageRedoLog:
      case EncryptionDomain.transactionLog:
        return false;
    }
  }

  /// Short-lived domains completed by waiting for natural turnover.
  static bool isNaturalTurnover(EncryptionDomain domain) {
    switch (domain) {
      case EncryptionDomain.wal:
      case EncryptionDomain.pageRedoLog:
      case EncryptionDomain.transactionLog:
        return true;
      case EncryptionDomain.tableData:
      case EncryptionDomain.btreeIndex:
      case EncryptionDomain.vectorIndex:
      case EncryptionDomain.tableMeta:
      case EncryptionDomain.indexMeta:
      case EncryptionDomain.migrationMeta:
        return false;
    }
  }

  /// Domains that use `_system_key_migration` fine-grained checkpoints.
  static bool usesTableProgressStore(EncryptionDomain domain) {
    switch (domain) {
      case EncryptionDomain.tableData:
      case EncryptionDomain.btreeIndex:
      case EncryptionDomain.vectorIndex:
        return true;
      case EncryptionDomain.tableMeta:
      case EncryptionDomain.indexMeta:
      case EncryptionDomain.migrationMeta:
      case EncryptionDomain.wal:
      case EncryptionDomain.pageRedoLog:
      case EncryptionDomain.transactionLog:
        return false;
    }
  }

  /// Meta-style domains: domain-level done flag; incomplete -> whole-domain rewrite.
  static bool isCoarseMetaDomain(EncryptionDomain domain) {
    switch (domain) {
      case EncryptionDomain.tableMeta:
      case EncryptionDomain.indexMeta:
      case EncryptionDomain.migrationMeta:
        return true;
      case EncryptionDomain.tableData:
      case EncryptionDomain.btreeIndex:
      case EncryptionDomain.vectorIndex:
      case EncryptionDomain.wal:
      case EncryptionDomain.pageRedoLog:
      case EncryptionDomain.transactionLog:
        return false;
    }
  }
}
