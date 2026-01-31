import 'dart:convert';
import 'dart:collection';
import 'dart:async';
import 'dart:typed_data';

import '../handler/logger.dart';
import '../handler/wal_encoder.dart';
import '../model/data_store_config.dart';
import 'data_store_impl.dart';
import 'storage_adapter.dart';
import '../model/table_op_meta.dart';
import '../model/meta_info.dart';
import '../model/parallel_journal_entry.dart';
import '../model/wal_pointer.dart';
import 'yield_controller.dart';
import 'compute_manager.dart';
import 'compute_tasks.dart';
import '../handler/encoder.dart';

/// Pending parallel batch metadata recorded in WAL meta for recovery
class PendingParallelBatch {
  final String batchId;
  final BatchType batchType;
  final String journalFile; // 'A' or 'B'
  final int recoverStartOffset; // byte offset in journal file to resume reading
  final WalPointer
      start; // WAL start pointer for this batch (-1:-1 for maintenance)
  final WalPointer
      end; // WAL end pointer for this batch (-1:-1 for maintenance)
  final List<String> tables; // tables involved in this batch
  final String createdAt; // ISO8601

  PendingParallelBatch({
    required this.batchId,
    required this.batchType,
    required this.journalFile,
    required this.recoverStartOffset,
    required this.start,
    required this.end,
    required this.tables,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'batchId': batchId,
        'batchType': batchType.value,
        'journalFile': journalFile,
        'recoverStartOffset': recoverStartOffset,
        'start': start.toJson(),
        'end': end.toJson(),
        'tables': tables,
        'createdAt': createdAt,
      };

  static PendingParallelBatch fromJson(Map<String, dynamic> json) =>
      PendingParallelBatch(
        batchId: (json['batchId'] as String?) ?? '',
        batchType: BatchType.fromStringOrFlush(
            (json['batchType'] as String?) ?? (json['scope'] as String?)),
        journalFile: (json['journalFile'] as String?) ?? 'A',
        recoverStartOffset: (json['recoverStartOffset'] as num?)?.toInt() ?? 0,
        start: WalPointer.fromJson(
            ((json['start'] as Map?) ?? const {}).cast<String, dynamic>()),
        end: WalPointer.fromJson(
            ((json['end'] as Map?) ?? const {}).cast<String, dynamic>()),
        tables: ((json['tables'] as List?) ?? const <dynamic>[])
            .map((e) => e.toString())
            .toList(),
        createdAt:
            (json['createdAt'] as String?) ?? DateTime.now().toIso8601String(),
      );
}

/// Large delete operation metadata for WAL meta (single-table delete with checkpoint)
class LargeDeleteMeta {
  final String opId;
  final String table;
  final Map<String, dynamic> condition; // includes where map
  final List<String>? orderBy;
  final int? limit;
  final int? offset;
  int?
      lastProcessedPartitionNo; // null means none processed yet, int is partition number (0-based)
  int deletedSoFar; // cumulative deleted rows (for limit semantics across crashes)
  String status; // 'running' | 'completed'
  final String createdAt; // ISO8601

  LargeDeleteMeta({
    required this.opId,
    required this.table,
    required this.condition,
    this.orderBy,
    this.limit,
    this.offset,
    this.lastProcessedPartitionNo,
    required this.deletedSoFar,
    required this.status,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'opId': opId,
        'table': table,
        'condition': condition,
        if (orderBy != null) 'orderBy': orderBy,
        if (limit != null) 'limit': limit,
        if (offset != null) 'offset': offset,
        if (lastProcessedPartitionNo != null)
          'lastProcessedPartitionNo': lastProcessedPartitionNo,
        'deletedSoFar': deletedSoFar,
        'status': status,
        'createdAt': createdAt,
      };

  static LargeDeleteMeta fromJson(Map<String, dynamic> json) {
    // Backward compatibility: support both old String format and new int format
    int? lastProcessedPartitionNo;
    if (json.containsKey('lastProcessedPartitionNo')) {
      lastProcessedPartitionNo =
          (json['lastProcessedPartitionNo'] as num?)?.toInt();
    }
    return LargeDeleteMeta(
      opId: (json['opId'] as String?) ?? '',
      table: (json['table'] as String?) ?? '',
      condition:
          ((json['condition'] as Map?) ?? const {}).cast<String, dynamic>(),
      orderBy: (json['orderBy'] as List?)?.map((e) => e.toString()).toList(),
      limit: (json['limit'] as num?)?.toInt(),
      offset: (json['offset'] as num?)?.toInt(),
      lastProcessedPartitionNo: lastProcessedPartitionNo,
      deletedSoFar: (json['deletedSoFar'] as num?)?.toInt() ?? 0,
      status: (json['status'] as String?) ?? 'running',
      createdAt:
          (json['createdAt'] as String?) ?? DateTime.now().toIso8601String(),
    );
  }
}

/// Large update operation metadata for WAL meta (single-table update with checkpoint)
class LargeUpdateMeta {
  final String opId;
  final String table;
  final Map<String, dynamic> condition; // includes where map
  final Map<String, dynamic> updateData; // data to update
  final List<String>? orderBy;
  final int? limit;
  final int? offset;
  int? lastProcessedPartitionNo;
  int updatedSoFar; // cumulative updated rows (for limit semantics across crashes)
  String status; // 'running' | 'completed'
  final String createdAt; // ISO8601

  LargeUpdateMeta({
    required this.opId,
    required this.table,
    required this.condition,
    required this.updateData,
    this.orderBy,
    this.limit,
    this.offset,
    this.lastProcessedPartitionNo,
    required this.updatedSoFar,
    required this.status,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'opId': opId,
        'table': table,
        'condition': condition,
        'updateData': updateData,
        if (orderBy != null) 'orderBy': orderBy,
        if (limit != null) 'limit': limit,
        if (offset != null) 'offset': offset,
        if (lastProcessedPartitionNo != null)
          'lastProcessedPartitionNo': lastProcessedPartitionNo,
        'updatedSoFar': updatedSoFar,
        'status': status,
        'createdAt': createdAt,
      };

  static LargeUpdateMeta fromJson(Map<String, dynamic> json) {
    // Backward compatibility: support both old String format and new int format
    int? lastProcessedPartitionNo;
    if (json.containsKey('lastProcessedPartitionNo')) {
      lastProcessedPartitionNo =
          (json['lastProcessedPartitionNo'] as num?)?.toInt();
    }
    return LargeUpdateMeta(
      opId: (json['opId'] as String?) ?? '',
      table: (json['table'] as String?) ?? '',
      condition:
          ((json['condition'] as Map?) ?? const {}).cast<String, dynamic>(),
      updateData:
          ((json['updateData'] as Map?) ?? const {}).cast<String, dynamic>(),
      orderBy: (json['orderBy'] as List?)?.map((e) => e.toString()).toList(),
      limit: (json['limit'] as num?)?.toInt(),
      offset: (json['offset'] as num?)?.toInt(),
      lastProcessedPartitionNo: lastProcessedPartitionNo,
      updatedSoFar: (json['updatedSoFar'] as num?)?.toInt() ?? 0,
      status: (json['status'] as String?) ?? 'running',
      createdAt:
          (json['createdAt'] as String?) ?? DateTime.now().toIso8601String(),
    );
  }
}

/// WAL main metadata
class WalMeta {
  WalPointer checkpoint;
  int existingStartPartitionIndex; // inclusive
  int existingEndPartitionIndex; // inclusive
  String activeParallelJournal; // 'A' or 'B'
  // Pending batches for parallel recovery (supports multiple, flush/maintenance)
  List<PendingParallelBatch> pendingBatches;
  // Running large delete operations keyed by opId
  Map<String, LargeDeleteMeta> largeDeletes;
  // Running large update operations keyed by opId
  Map<String, LargeUpdateMeta> largeUpdates;
  // Table-level maintenance operations (clear/drop) tracked for recovery.
  Map<String, TableOpMeta> tableOps;

  /// Directory mapping for WAL partitions.
  /// Maintains partition index -> directory index mapping and directory file counts.
  final DirectoryMapping? directoryMapping;

  /// Last WAL pointer after a successful recovery; used for fast-path skip on next startup.
  final WalPointer? lastRecoveredPointer;

  /// Tail partition file size when lastRecoveredPointer was set; fast-path only when size unchanged.
  final int? lastRecoveredTailFileSize;

  WalMeta({
    required this.checkpoint,
    required this.existingStartPartitionIndex,
    required this.existingEndPartitionIndex,
    required this.activeParallelJournal,
    required this.pendingBatches,
    required this.largeDeletes,
    required this.largeUpdates,
    required this.tableOps,
    this.directoryMapping,
    this.lastRecoveredPointer,
    this.lastRecoveredTailFileSize,
  });

  /// Returns a copy with the given fields overridden; omitted fields keep current values.
  WalMeta copyWith({
    WalPointer? checkpoint,
    int? existingStartPartitionIndex,
    int? existingEndPartitionIndex,
    String? activeParallelJournal,
    List<PendingParallelBatch>? pendingBatches,
    Map<String, LargeDeleteMeta>? largeDeletes,
    Map<String, LargeUpdateMeta>? largeUpdates,
    Map<String, TableOpMeta>? tableOps,
    DirectoryMapping? directoryMapping,
    WalPointer? lastRecoveredPointer,
    int? lastRecoveredTailFileSize,
  }) {
    return WalMeta(
      checkpoint: checkpoint ?? this.checkpoint,
      existingStartPartitionIndex:
          existingStartPartitionIndex ?? this.existingStartPartitionIndex,
      existingEndPartitionIndex:
          existingEndPartitionIndex ?? this.existingEndPartitionIndex,
      activeParallelJournal:
          activeParallelJournal ?? this.activeParallelJournal,
      pendingBatches: pendingBatches ?? this.pendingBatches,
      largeDeletes: largeDeletes ?? this.largeDeletes,
      largeUpdates: largeUpdates ?? this.largeUpdates,
      tableOps: tableOps ?? this.tableOps,
      directoryMapping: directoryMapping ?? this.directoryMapping,
      lastRecoveredPointer: lastRecoveredPointer ?? this.lastRecoveredPointer,
      lastRecoveredTailFileSize:
          lastRecoveredTailFileSize ?? this.lastRecoveredTailFileSize,
    );
  }

  Map<String, dynamic> toJson() => {
        'checkpoint': checkpoint.toJson(),
        'existingStartPartitionIndex': existingStartPartitionIndex,
        'existingEndPartitionIndex': existingEndPartitionIndex,
        'activeParallelJournal': activeParallelJournal,
        'pendingBatches': pendingBatches.map((e) => e.toJson()).toList(),
        'largeDeletes': largeDeletes.map((k, v) => MapEntry(k, v.toJson())),
        'largeUpdates': largeUpdates.map((k, v) => MapEntry(k, v.toJson())),
        'tableOps': tableOps.map((k, v) => MapEntry(k, v.toJson())),
        if (directoryMapping != null)
          'directoryMapping': directoryMapping!.toJson(),
        if (lastRecoveredPointer != null)
          'lastRecoveredPointer': lastRecoveredPointer!.toJson(),
        if (lastRecoveredTailFileSize != null)
          'lastRecoveredTailFileSize': lastRecoveredTailFileSize,
      };

  static WalMeta initial({required int startPartitionIndex}) => WalMeta(
        checkpoint:
            WalPointer(partitionIndex: startPartitionIndex, entrySeq: 0),
        existingStartPartitionIndex: -1,
        existingEndPartitionIndex: -1,
        activeParallelJournal: 'A',
        pendingBatches: <PendingParallelBatch>[],
        largeDeletes: <String, LargeDeleteMeta>{},
        largeUpdates: <String, LargeUpdateMeta>{},
        tableOps: <String, TableOpMeta>{},
      );

  static WalMeta fromJson(Map<String, dynamic> json) {
    return WalMeta(
      checkpoint: json.containsKey('checkpoint')
          ? WalPointer.fromJson(json['checkpoint'] as Map<String, dynamic>)
          : WalPointer(
              partitionIndex:
                  (json['checkpointPartitionIndex'] as num?)?.toInt() ?? 0,
              entrySeq: (json['checkpointEntrySeq'] as num?)?.toInt() ?? 0,
            ),
      existingStartPartitionIndex:
          (json['existingStartPartitionIndex'] as num?)?.toInt() ?? -1,
      existingEndPartitionIndex:
          (json['existingEndPartitionIndex'] as num?)?.toInt() ?? -1,
      activeParallelJournal: (json['activeParallelJournal'] as String?) ?? 'A',
      pendingBatches: ((json['pendingBatches'] as List?) ?? const <dynamic>[])
          .map((e) => PendingParallelBatch.fromJson(
              ((e as Map?) ?? const {}).cast<String, dynamic>()))
          .toList(),
      largeDeletes:
          ((json['largeDeletes'] as Map?) ?? const <String, dynamic>{}).map(
              (k, v) => MapEntry(
                  k.toString(),
                  LargeDeleteMeta.fromJson(
                      ((v as Map?) ?? const {}).cast<String, dynamic>()))),
      largeUpdates:
          ((json['largeUpdates'] as Map?) ?? const <String, dynamic>{}).map(
              (k, v) => MapEntry(
                  k.toString(),
                  LargeUpdateMeta.fromJson(
                      ((v as Map?) ?? const {}).cast<String, dynamic>()))),
      tableOps: ((json['tableOps'] as Map?) ?? const <String, dynamic>{}).map(
        (k, v) => MapEntry(
          k.toString(),
          TableOpMeta.fromJson(
            ((v as Map?) ?? const <String, dynamic>{}).cast<String, dynamic>(),
          ),
        ),
      ),
      directoryMapping: json['directoryMapping'] != null
          ? DirectoryMapping.fromJson(
              json['directoryMapping'] as Map<String, dynamic>)
          : null,
      lastRecoveredPointer: json['lastRecoveredPointer'] != null
          ? WalPointer.fromJson(
              json['lastRecoveredPointer'] as Map<String, dynamic>)
          : null,
      lastRecoveredTailFileSize:
          (json['lastRecoveredTailFileSize'] as num?)?.toInt(),
    );
  }
}

/// WAL manager: append, rotate, checkpoint, and recovery helpers.
class WalManager {
  final DataStoreImpl _dataStore;
  late final DataStoreConfig _config;

  WalMeta _meta = WalMeta.initial(startPartitionIndex: 0);
  // Current WAL pointer is maintained purely in memory and is not persisted
  // in WAL meta. This avoids high-frequency metadata updates while still
  // providing precise ordering for recovery and batch tracking.
  WalPointer _current = const WalPointer(partitionIndex: 0, entrySeq: 0);
  // Highest WAL pointer that has been physically appended to WAL files
  // (i.e., written to OS buffers). This is maintained separately from
  // [_current] which tracks logical in-memory ordering including queued entries.
  WalPointer _appended = const WalPointer(partitionIndex: 0, entrySeq: 0);
  bool _initialized = false;
  Future<void>? _initFuture;
  // Approximate size (in characters) of the current WAL partition file.
  // Initialized lazily from storage on first append, then maintained purely
  // in memory to avoid per-append getFileSize() calls.
  int _currentPartitionSizeApprox = 0;
  bool _currentPartitionSizeLoaded = false;

  // WAL write queue (path + binary data + pointer) for background persistence.
  final Queue<_QueuedWalEntry> _walQueue = Queue<_QueuedWalEntry>();
  bool _walFlushInProgress = false;
  Future<void>? _walFlushFuture;

  // Directory mapping cache
  DirectoryMapping? _directoryMapping;
  int _currentPartitionDirIndex = 0;

  // Mutex for persistMeta to prevent concurrent writes
  // Use coalescing strategy: only the latest persistMeta needs to execute
  bool _persistMetaInProgress = false;
  Completer<void>? _nextPersistMetaCompleter; // Only the latest waiting request

  WalManager(this._dataStore) {
    _config = _dataStore.config;
  }

  WalMeta get meta => _meta;
  Map<String, TableOpMeta> get tableOps => _meta.tableOps;

  /// In-memory current WAL pointer (not persisted).
  WalPointer get currentPointer => _current;

  /// Last WAL pointer that is known to have been appended to WAL files
  /// (OS buffers). This can lag behind [currentPointer] when there are
  /// queued entries waiting to be written.
  WalPointer get appendedPointer => _appended;

  /// Current in-memory WAL write queue length (pending persistence).
  ///
  /// This is used as a high-load signal for incremental partitioning.
  int get pendingQueueLength => _walQueue.length;

  bool get hasPendingParallelBatches => _meta.pendingBatches.isNotEmpty;

  bool _isPointerNewerThan(WalPointer p, WalPointer snapshot) {
    return p.isNewerThan(snapshot, _config.logPartitionCycle);
  }

  /// Whether [p] is at or before [cutoff] in WAL order.
  bool isAtOrBefore(WalPointer p, WalPointer cutoff) {
    return !_isPointerNewerThan(p, cutoff);
  }

  void _pruneTableOpsUpToCheckpoint() {
    final checkpoint = _meta.checkpoint;
    // Remove only completed ops whose cutoff is at or before checkpoint.
    // Pending (completed=false) ops stay until they are completed and checkpoint passes.
    final entries =
        Map<String, TableOpMeta>.from(_meta.tableOps).entries.toList();
    for (final entry in entries) {
      final op = entry.value;
      if (op.completed && isAtOrBefore(op.cutoff, checkpoint)) {
        _meta.tableOps.remove(entry.key);
      }
    }
  }

  // Whether there exists any WAL entry files (based on meta).
  bool get hasExistingLogs =>
      _meta.existingStartPartitionIndex >= 0 &&
      _meta.existingEndPartitionIndex >= 0;

  /// Destroys all WAL data (files and metadata) permanently.
  /// Used when disabling journaling to ensure no stale data remains.
  Future<void> destroyWal() async {
    // 1. Delete all partition files and metadata
    //    Efficiently delete the entire WAL directory
    try {
      final walRoot = _dataStore.pathManager
          .getWalRootPath(spaceName: _dataStore.currentSpaceName);
      if (await _dataStore.storage.existsDirectory(walRoot)) {
        await _dataStore.storage.deleteDirectory(walRoot);
      }
    } catch (e) {
      Logger.error('Failed to delete WAL directory: $e', label: 'WalManager');
    }

    // 2. Reset in-memory state
    _meta = WalMeta.initial(startPartitionIndex: 0);
    // Reset pointers
    _current = const WalPointer(partitionIndex: 0, entrySeq: 0);
    _appended = const WalPointer(partitionIndex: 0, entrySeq: 0);
    // Reset directory mapping
    _directoryMapping = null;
    _currentPartitionDirIndex = 0;
    _currentPartitionSizeLoaded = false;
    _currentPartitionSizeApprox = 0;

    Logger.info('WAL destroyed.', label: 'WalManager');
  }

  Future<void> initializeAndRecover() async {
    if (_initialized) return;
    if (_initFuture != null) {
      return _initFuture;
    }
    _initFuture = () async {
      try {
        final metaPath = _dataStore.pathManager
            .getWalMainMetaPath(spaceName: _dataStore.currentSpaceName);
        final backupPath = _dataStore.pathManager
            .getWalBackupMetaPath(spaceName: _dataStore.currentSpaceName);

        WalMeta? loaded;
        bool recoveredFromBackup = false;

        // 1) Try primary WAL meta
        try {
          final content = await _dataStore.storage.readAsString(metaPath);
          if (content != null && content.isNotEmpty) {
            final jsonMap = jsonDecode(content) as Map<String, dynamic>;
            loaded = WalMeta.fromJson(jsonMap);
          }
        } catch (e) {
          // Primary meta is corrupted or unreadable; fallback to backup.
          Logger.warn('Primary WAL meta is invalid, will try backup. Error: $e',
              label: 'WalManager');
        }

        // 2) Fallback to backup WAL meta if primary failed
        if (loaded == null) {
          try {
            final content = await _dataStore.storage.readAsString(backupPath);
            if (content != null && content.isNotEmpty) {
              final jsonMap = jsonDecode(content) as Map<String, dynamic>;
              loaded = WalMeta.fromJson(jsonMap);
              recoveredFromBackup = true;
              Logger.warn(
                  'Recovered WAL meta from backup after primary failure.',
                  label: 'WalManager');
            }
          } catch (e) {
            Logger.error('Backup WAL meta is also invalid. Error: $e',
                label: 'WalManager');
          }
        }

        // 3) If both primary and backup are unusable, start with fresh meta
        _meta = loaded ?? WalMeta.initial(startPartitionIndex: 0);

        // Heal primary meta after successfully recovering from backup.
        // Also persist if we loaded a meta but it wasn't valid (implicit heal?)
        // If recovered using backup, force write to primary
        if (recoveredFromBackup) {
          try {
            await persistMeta(flush: true);
          } catch (_) {}
        }

        // Warm directory mapping cache
        if (_meta.directoryMapping != null) {
          _directoryMapping = _meta.directoryMapping;
          if (_directoryMapping!.dirToFileCount.isNotEmpty) {
            _currentPartitionDirIndex = _directoryMapping!.dirToFileCount.keys
                .reduce((a, b) => a > b ? a : b);
          }
        } else {
          _directoryMapping = DirectoryMapping();
        }

        // Initialize in-memory current pointer.
        // Even if journal is disabled, if we have existing logs (loaded from meta),
        // we should initialize pointers correctly so that recovery can read them.
        if (!_config.enableJournal && !hasExistingLogs) {
          _current = const WalPointer(partitionIndex: 0, entrySeq: 0);
        } else {
          // If we know of existing WAL partitions, start from the latest
          // partition index but keep entrySeq aligned with checkpoint.
          final hasPartitions = _meta.existingStartPartitionIndex >= 0 &&
              _meta.existingEndPartitionIndex >= 0;
          final pIdx = hasPartitions
              ? _meta.existingEndPartitionIndex
              : _meta.checkpoint.partitionIndex;
          _current = WalPointer(
            partitionIndex: pIdx,
            entrySeq: _meta.checkpoint.entrySeq,
          );
        }
        _currentPartitionSizeLoaded = false;
        _currentPartitionSizeApprox = 0;

        _ensureCurrentPartitionSizeLoaded();

        // Lazy: do NOT persist or create directories here.
        // We will create WAL directories and persist meta on first actual append or rotation.
        _initialized = true;
      } catch (e, s) {
        Logger.error('Failed to initialize WAL meta: $e\n$s',
            label: 'WalManager');
        rethrow;
      } finally {
        _initFuture = null;
      }
    }();
    return _initFuture;
  }

  /// Get or load directory mapping from cache or metadata.
  DirectoryMapping _getOrLoadDirectoryMapping() {
    if (_directoryMapping != null) return _directoryMapping!;

    if (_meta.directoryMapping != null) {
      _directoryMapping = _meta.directoryMapping;
      if (_directoryMapping!.dirToFileCount.isNotEmpty) {
        _currentPartitionDirIndex = _directoryMapping!.dirToFileCount.keys
            .reduce((a, b) => a > b ? a : b);
      }
      return _directoryMapping!;
    }

    _directoryMapping = DirectoryMapping();
    return _directoryMapping!;
  }

  /// Get directory index for an existing partition.
  int? _getPartitionDirIndexForExistingPartition(int partitionIndex) {
    final mapping = _getOrLoadDirectoryMapping();
    return mapping.getDirIndex(partitionIndex);
  }

  /// Public method to get directory index for a WAL partition (for use by ParallelJournalManager).
  int? getPartitionDirIndex(int partitionIndex) {
    return _getPartitionDirIndexForExistingPartition(partitionIndex);
  }

  /// Get or allocate directory index for a partition.
  int _getOrAllocateDirIndexForPartition(int partitionIndex) {
    final mapping = _getOrLoadDirectoryMapping();

    // Existing mapping
    final existing = mapping.getDirIndex(partitionIndex);
    if (existing != null) return existing;

    // Allocate for new partition
    int currentDir = _currentPartitionDirIndex;
    int currentCount = mapping.getFileCount(currentDir);

    if (currentCount >= _dataStore.maxEntriesPerDir) {
      if (mapping.dirToFileCount.isNotEmpty) {
        currentDir =
            mapping.dirToFileCount.keys.reduce((a, b) => a > b ? a : b) + 1;
      } else {
        currentDir = 0;
      }
      currentCount = 0;
    }

    // Update mapping
    _directoryMapping = mapping.withPartitionAndDirCount(
        partitionIndex, currentDir, currentCount + 1);
    _currentPartitionDirIndex = currentDir;

    _meta = _meta.copyWith(directoryMapping: _directoryMapping);

    return currentDir;
  }

  /// Append one WAL entry. Returns its pointer.
  Future<WalPointer> append(Map<String, dynamic> walEntry) async {
    if (!_initialized) {
      await initializeAndRecover();
    }

    // If journal disabled, still create a pseudo pointer to maintain order in memory
    if (!_config.enableJournal) {
      // In-memory only; WAL meta is not used for recovery when journal is disabled.
      _current = WalPointer(
        partitionIndex: _current.partitionIndex,
        entrySeq: _current.entrySeq + 1,
      );
      return WalPointer(partitionIndex: -1, entrySeq: _current.entrySeq);
    }

    final pIdx = _current.partitionIndex;
    final nextSeq = _current.entrySeq + 1;

    _current = WalPointer(
      partitionIndex: _current.partitionIndex,
      entrySeq: nextSeq,
    );

    // Embed physical WAL pointer into the entry itself so that recovery can
    // efficiently determine the last WAL pointer by reading only the tail of
    // the last partition file.
    final entryWithPtr = Map<String, dynamic>.from(walEntry)
      ..['p'] = pIdx
      ..['seq'] = nextSeq;

    final dirIndex = _getOrAllocateDirIndexForPartition(pIdx);
    final path = _dataStore.pathManager.getWalPartitionLogPath(
      dirIndex,
      pIdx,
      spaceName: _dataStore.currentSpaceName,
    );

    // Enqueue into WAL write queue for background persistence instead of
    // writing synchronously per entry.
    _walQueue.add(_QueuedWalEntry(
      path: path,
      rawEntry: entryWithPtr,
      pointer: _current,
    ));

    // Initialize existing partition range on first write to avoid later scans
    if (_meta.existingStartPartitionIndex < 0 ||
        _meta.existingEndPartitionIndex < 0) {
      _meta.existingStartPartitionIndex = pIdx;
      _meta.existingEndPartitionIndex = pIdx;
      // We can persist update meta asynchronously
      persistMeta(flush: false);
    }

    // Persist meta lazily; rotation/checkpoint will persist. Return the precise
    // in-memory WAL pointer for this entry.
    return WalPointer(partitionIndex: pIdx, entrySeq: _current.entrySeq);
  }

  /// Advance checkpoint after a batch has been safely flushed to data files.
  Future<void> advanceCheckpoint(WalPointer pointer) async {
    _meta.checkpoint = pointer;
    // After advancing checkpoint, remove table-level ops whose cutoff is
    // older than or equal to the new checkpoint; they can no longer affect
    // recovery semantics.
    _pruneTableOpsUpToCheckpoint();
    // At batch commit, also backup previous WAL meta for recovery.
    await persistMeta(flush: false, backupOld: true);
  }

  /// Delete all WAL partition files in the current range and reset meta so that
  /// next startup sees no WAL (existingStart/End = -1). Used when recovery found
  /// no effective entries so WAL can be cleared to avoid repeated full reads.
  Future<void> clearWalPartitionsAndResetMeta() async {
    if (_meta.existingStartPartitionIndex < 0 ||
        _meta.existingEndPartitionIndex < 0) {
      return;
    }
    final start = _meta.existingStartPartitionIndex;
    final end = _meta.existingEndPartitionIndex;
    final cap = _config.logPartitionCycle;

    int idx = start;
    final toDelete = <int>[];
    while (true) {
      toDelete.add(idx);
      if (idx == end) break;
      idx = (idx + 1) % cap;
      if (idx == start) break;
    }

    final partitionToDirIndex = <int, int>{};
    if (_directoryMapping != null) {
      for (final p in toDelete) {
        final dirIndex = _directoryMapping!.getDirIndex(p);
        if (dirIndex != null) partitionToDirIndex[p] = dirIndex;
      }
    }
    for (final p in toDelete) {
      if (partitionToDirIndex.containsKey(p)) continue;
      partitionToDirIndex[p] = p ~/ _dataStore.maxEntriesPerDir;
    }

    final yieldController = YieldController(
        'WalManager.clearWalPartitionsAndResetMeta',
        checkInterval: 1);
    for (final p in toDelete) {
      await yieldController.maybeYield();
      final dirIndex = partitionToDirIndex[p]!;
      final path = _dataStore.pathManager.getWalPartitionLogPath(dirIndex, p,
          spaceName: _dataStore.currentSpaceName);
      try {
        try {
          await _dataStore.storage.flushAll(path: path, closeHandles: true);
        } catch (_) {}
        await _dataStore.storage.deleteFile(path);
      } catch (_) {}
    }

    _directoryMapping = null;
    _current = const WalPointer(partitionIndex: 0, entrySeq: 0);
    _appended = const WalPointer(partitionIndex: 0, entrySeq: 0);
    _meta = WalMeta(
      checkpoint: const WalPointer(partitionIndex: 0, entrySeq: 0),
      existingStartPartitionIndex: -1,
      existingEndPartitionIndex: -1,
      activeParallelJournal: _meta.activeParallelJournal,
      pendingBatches: _meta.pendingBatches,
      largeDeletes: _meta.largeDeletes,
      largeUpdates: _meta.largeUpdates,
      tableOps: _meta.tableOps,
      directoryMapping: null,
      lastRecoveredPointer: null,
      lastRecoveredTailFileSize: null,
    );
    _currentPartitionSizeLoaded = true;
    _currentPartitionSizeApprox = 0;
    await persistMeta(flush: true);
  }

  /// Delete WAL partition files strictly older than checkpoint partition within the existing range (cycle-aware)
  Future<void> cleanupObsoletePartitions() async {
    try {
      if (_meta.existingStartPartitionIndex < 0 ||
          _meta.existingEndPartitionIndex < 0) {
        return;
      }
      final start = _meta.existingStartPartitionIndex;
      final end = _meta.existingEndPartitionIndex;
      final cap = _config.logPartitionCycle;
      final checkpoint = _meta.checkpoint.partitionIndex;

      // Iterate from start → end (cycle-aware)
      int idx = start;
      final toDelete = <int>[];
      final yieldController = YieldController(
          'WalManager.cleanupObsoletePartitions',
          checkInterval: 1);
      while (true) {
        await yieldController.maybeYield();
        if (idx == checkpoint) {
          // Do not delete checkpoint partition or newer
          break;
        }
        toDelete.add(idx);
        if (idx == end) break;
        idx = (idx + 1) % cap;
        if (idx == start) break; // safety
      }

      // First, collect dirIndex for each partition to delete (before updating mapping)
      final partitionToDirIndex = <int, int>{};
      if (_directoryMapping != null && toDelete.isNotEmpty) {
        for (final p in toDelete) {
          final dirIndex = _directoryMapping!.getDirIndex(p);
          if (dirIndex != null) {
            partitionToDirIndex[p] = dirIndex;
          }
        }
      }

      // Delete partition files
      for (final p in toDelete) {
        await yieldController.maybeYield();
        final dirIndex = partitionToDirIndex[p];
        if (dirIndex == null) {
          // Skip partitions without directory mapping (should not happen in normal operation)
          Logger.warn(
            'Cannot find dirIndex for WAL partition $p, skipping deletion',
            label: 'WalManager.cleanupObsoletePartitions',
          );
          continue;
        }
        final path = _dataStore.pathManager.getWalPartitionLogPath(dirIndex, p,
            spaceName: _dataStore.currentSpaceName);
        try {
          // Ensure any pooled handle is flushed and closed before deleting the file
          try {
            await _dataStore.storage.flushAll(path: path, closeHandles: true);
          } catch (_) {}
          await _dataStore.storage.deleteFile(path);
        } catch (_) {}
      }

      // Clean up directory mapping for deleted partitions (after file deletion)
      if (_directoryMapping != null && partitionToDirIndex.isNotEmpty) {
        final updatedMapping = _directoryMapping!;
        final Map<int, int> newP2d = Map.from(updatedMapping.partitionToDir);
        final Map<int, int> newD2c = Map.from(updatedMapping.dirToFileCount);

        for (final entry in partitionToDirIndex.entries) {
          final p = entry.key;
          final dirIndex = entry.value;
          newP2d.remove(p);
          final count = newD2c[dirIndex] ?? 0;
          if (count > 1) {
            newD2c[dirIndex] = count - 1;
          } else {
            // If directory is empty or count would be 0, remove it from mapping
            newD2c.remove(dirIndex);
          }
        }

        _directoryMapping = DirectoryMapping(
          partitionToDir: newP2d,
          dirToFileCount: newD2c,
        );
      }

      // Move start forward
      if (toDelete.isNotEmpty) {
        final newStart = (toDelete.last + 1) % cap;
        _meta = _meta.copyWith(
          existingStartPartitionIndex: newStart,
          directoryMapping: _directoryMapping,
        );
        await persistMeta();
      }
    } catch (e) {
      Logger.error('cleanupObsoletePartitions failed: $e', label: 'WalManager');
    }
  }

  /// Switch A/B active journal file (only when no pending batch)
  Future<void> rotateParallelJournalActive() async {
    if (_meta.pendingBatches.isNotEmpty) return;
    _meta.activeParallelJournal =
        _meta.activeParallelJournal == 'A' ? 'B' : 'A';
    await persistMeta(flush: false);
  }

  /// Update current WAL pointer after a recovery scan has replayed WAL entries.
  /// This is called from the recovery pipeline to avoid an extra WAL scan
  /// during initialization.
  void updateCurrentPointerAfterRecovery(WalPointer pointer) {
    _current = pointer;
    _appended = pointer;
    // Force size to be reloaded lazily on next append to avoid stale estimates.
    _currentPartitionSizeLoaded = false;
    _currentPartitionSizeApprox = 0;
  }

  /// Schedule a background WAL flush if not already running.
  void scheduleFlushIfNeeded() {
    if (!_config.enableJournal) return;
    if (_walFlushInProgress) return;
    if (_walQueue.isEmpty) return;
    // Start a single flush pump; the pump will drain the queue (including
    // small tails after a policy-based delay) before completing.
    _walFlushFuture = _pumpWalFlush();
  }

  /// Flush WAL write queue to files in batches.
  ///
  /// - Normal mode (drainCompletely=false): used for online WAL persistence,
  ///   will stop when queue length drops below a small threshold after the
  ///   first iteration to avoid tiny batches.
  /// - Drain mode (drainCompletely=true): used for shutdown/strong durability,
  ///   will continue until the queue is fully drained.
  Future<void> _pumpWalFlush({bool drainCompletely = false}) async {
    if (!_config.enableJournal) return;
    if (_walQueue.isEmpty) return;
    // If a flush is already running, let that one handle the queue.
    if (_walFlushInProgress) return;
    _walFlushInProgress = true;
    try {
      if (!_currentPartitionSizeLoaded) {
        await _ensureCurrentPartitionSizeLoaded();
      }

      final int batchSize = _config.logWriteBatchSize;
      const int minTail = 100;
      bool firstIteration = true;

      while (_walQueue.isNotEmpty) {
        if (!firstIteration && !drainCompletely) {
          final int remaining = _walQueue.length;
          if (remaining < minTail) {
            // For small tails, wait a short delay based on recoveryFlushPolicy
            // before flushing, to avoid writing every tiny batch immediately.
            final int delayMs = _walTailDelayMs();
            if (delayMs > 0) {
              await Future.delayed(Duration(milliseconds: delayMs));
            }
          }
        }

        firstIteration = false;
        if (_walQueue.isEmpty) break;

        // Take up to batchSize entries from the head of the queue for this batch.
        final int take =
            batchSize < _walQueue.length ? batchSize : _walQueue.length;
        if (take <= 0) break;

        // Aggregate raw entries per path to reduce handle switching, while removing
        // entries from the queue as we go to avoid holding the entire queue.
        final Map<String, List<Map<String, dynamic>>> byPath = {};
        WalPointer lastAppended = _appended;
        for (int i = 0; i < take && _walQueue.isNotEmpty; i++) {
          final _QueuedWalEntry e = _walQueue.removeFirst();
          final list = byPath.putIfAbsent(e.path, () => []);
          list.add(e.rawEntry);
          lastAppended = e.pointer;
        }

        final yieldController = YieldController('WalManager._pumpWalFlush');
        for (final entry in byPath.entries) {
          await yieldController.maybeYield();
          final String path = entry.key;
          final List<Map<String, dynamic>> rawEntries = entry.value;

          // Encode batch
          // Use isolate if batch is large enough, satisfying user requirement
          final useIsolate = rawEntries.length > 100;

          final result = await ComputeManager.run(
            batchEncodeWal,
            BatchWalEncodeRequest(
                entries: rawEntries,
                encoderConfig: EncoderHandler.getCurrentEncodingState()),
            useIsolate: useIsolate,
          );

          final List<Uint8List> chunks = result.encodedChunks;

          // Combine all binary chunks for this path
          int totalLength = 0;
          for (final chunk in chunks) {
            totalLength += chunk.length;
          }

          final combined = Uint8List(totalLength);
          int offset = 0;
          for (final chunk in chunks) {
            combined.setAll(offset, chunk);
            offset += chunk.length;
          }

          try {
            await _dataStore.storage.appendBytes(path, combined, flush: false);

            // Correct the approximate size in memory with actual encoded size
            // Check if we are writing to the current active partition
            final currentPIdx = _current.partitionIndex;
            // Cheap check: path ends with partition index specific suffix or compare full path
            // To be safe and efficient, we recreate the current path.
            final cDir = _getPartitionDirIndexForExistingPartition(currentPIdx);
            if (cDir != null) {
              final cPath = _dataStore.pathManager.getWalPartitionLogPath(
                  cDir, currentPIdx,
                  spaceName: _dataStore.currentSpaceName);
              if (path == cPath) {
                _currentPartitionSizeApprox += combined.length;
              }
            }
          } catch (e, s) {
            Logger.error('WAL append batch failed: $e\n$s',
                label: 'WalManager');
          }

          // Predictive Rotation Logic (Moved inside loop to access rawEntries/combined)
          if (rawEntries.isNotEmpty) {
            final int avgSize = (combined.length / rawEntries.length).ceil();

            // Only attempt predictive rotation if the queue is exclusively for the current partition.
            if (_walQueue.isNotEmpty &&
                _walQueue.first.pointer.partitionIndex ==
                    _current.partitionIndex) {
              final int estimatedBacklog = _walQueue.length * avgSize;
              if (_currentPartitionSizeApprox + estimatedBacklog >
                  _config.maxLogPartitionFileSize) {
                await _rotatePartition();
              }
            }
          }
        }

        // Update appended pointer after this batch.
        _appended = lastAppended;
        // Notify recovery layer that new WAL data has been written so that
        // RecoveryFlushPolicy can decide when to fsync.
        try {
          StorageAdapter.notifyRecoveryWrite();
        } catch (_) {}
      }
    } finally {
      _walFlushInProgress = false;
      _walFlushFuture = null;
    }
  }

  /// Compute a reasonable delay (in milliseconds) for tail WAL flush
  /// based on the configured RecoveryFlushPolicy.
  int _walTailDelayMs() {
    switch (_config.recoveryFlushPolicy) {
      case RecoveryFlushPolicy.high:
      case RecoveryFlushPolicy.adaptive:
        return 200;
      case RecoveryFlushPolicy.medium:
        return 500;
      case RecoveryFlushPolicy.low:
        return 800;
      case RecoveryFlushPolicy.off:
        return 0;
    }
  }

  /// Flush all pending WAL entries in the queue (drain mode).
  Future<void> flushQueueCompletely() async {
    if (!_config.enableJournal) return;
    // Wait for any in-flight WAL flush first.
    final existing = _walFlushFuture;
    if (existing != null) {
      try {
        await existing;
      } catch (_) {}
    }
    // Run drain-mode pump.
    await _pumpWalFlush(drainCompletely: true);
  }

  /// Lazily initialize the approximate size for the current WAL partition
  /// from storage. This is called only once after startup; subsequent appends
  /// maintain the size purely in memory.
  Future<void> _ensureCurrentPartitionSizeLoaded() async {
    if (_currentPartitionSizeLoaded) return;
    final pIdx = _current.partitionIndex;
    final dirIndex = _getOrAllocateDirIndexForPartition(pIdx);
    final path = _dataStore.pathManager.getWalPartitionLogPath(
      dirIndex,
      pIdx,
      spaceName: _dataStore.currentSpaceName,
    );
    int size = 0;
    try {
      size = await _dataStore.storage.getFileSize(path);
    } catch (_) {
      size = 0;
    }
    _currentPartitionSizeApprox = size;
    _currentPartitionSizeLoaded = true;
  }

  /// Fast-path: skip full WAL replay when tail partition is unchanged since last recovery.
  /// Uses only a single getFileSize (no file content read). Returns true if recovery was skipped.
  Future<bool> tryFastPathSkipRecovery() async {
    if (!_config.enableJournal) return false;
    final ptr = _meta.lastRecoveredPointer;
    final savedSize = _meta.lastRecoveredTailFileSize;
    if (ptr == null ||
        savedSize == null ||
        _meta.existingEndPartitionIndex < 0 ||
        ptr.partitionIndex != _meta.existingEndPartitionIndex) {
      return false;
    }
    final pIdx = _meta.existingEndPartitionIndex;
    final dirIndex = getPartitionDirIndex(pIdx);
    if (dirIndex == null) return false;
    final path = _dataStore.pathManager.getWalPartitionLogPath(
      dirIndex,
      pIdx,
      spaceName: _dataStore.currentSpaceName,
    );
    try {
      if (!await _dataStore.storage.existsFile(path)) {
        return false;
      }
      final size = await _dataStore.storage.getFileSize(path);
      if (size != savedSize) return false;
      updateCurrentPointerAfterRecovery(ptr);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Persist last-recovered pointer and tail file size after a successful WAL recovery
  /// so that the next startup can skip replay via tryFastPathSkipRecovery when unchanged.
  Future<void> setLastRecoveredPointer(WalPointer ptr) async {
    final dirIndex = getPartitionDirIndex(ptr.partitionIndex);
    if (dirIndex == null) return;
    final path = _dataStore.pathManager.getWalPartitionLogPath(
      dirIndex,
      ptr.partitionIndex,
      spaceName: _dataStore.currentSpaceName,
    );
    int size = 0;
    try {
      if (await _dataStore.storage.existsFile(path)) {
        size = await _dataStore.storage.getFileSize(path);
      }
    } catch (_) {}
    _meta = _meta.copyWith(
      lastRecoveredPointer: ptr,
      lastRecoveredTailFileSize: size,
    );
    await persistMeta(flush: false);
  }

  /// Efficiently read the last WAL pointer from the logical tail partition.
  /// Reads only the last 64KB of the file to find the last entry, avoiding
  /// the need to read and decode the entire file.
  Future<WalPointer?> readLastWalPointer() async {
    if (!_config.enableJournal) return null;
    if (_meta.existingEndPartitionIndex < 0) return null;

    final pIdx = _meta.existingEndPartitionIndex;
    final dirIndex = _getOrAllocateDirIndexForPartition(pIdx);
    final path = _dataStore.pathManager.getWalPartitionLogPath(
      dirIndex,
      pIdx,
      spaceName: _dataStore.currentSpaceName,
    );
    try {
      final exists = await _dataStore.storage.existsFile(path);
      if (!exists) {
        return WalPointer(partitionIndex: pIdx, entrySeq: 0);
      }
      final size = await _dataStore.storage.getFileSize(path);
      if (size <= 0) {
        return WalPointer(partitionIndex: pIdx, entrySeq: 0);
      }

      // Read only the last 64KB of the file for efficiency
      // This avoids reading hundreds of MB for large WAL files
      const int tailSize = 64 * 1024;
      final int readSize = size < tailSize ? size : tailSize;
      final int offset = size - readSize;

      // Use readAsBytesAt to read only the tail portion directly from storage
      // This is much more efficient than reading the entire file and then slicing
      final tailData = await _dataStore.storage
          .readAsBytesAt(path, offset, length: readSize);
      if (tailData.isEmpty) {
        return WalPointer(partitionIndex: pIdx, entrySeq: 0);
      }

      // Efficiently decode only the last entry from the tail (backward scan)
      // decodeLastEntryFromTail scans backwards from the end to find the last
      // complete record, which works correctly even if we only have the tail
      final lastEntry =
          await WalEncoder.decodeLastEntryFromTail(tailData, pIdx);
      if (lastEntry != null) {
        final p = lastEntry['p'] as int?;
        final seq = (lastEntry['seq'] as num?)?.toInt();
        if (p != null && seq != null) {
          return WalPointer(partitionIndex: p, entrySeq: seq);
        }
      }

      // Fallback: if tail scan failed, try larger tails (256KB then 512KB)
      // before falling back to reading the entire file to avoid 600ms+ startup.
      const int tier2Tail = 256 * 1024;
      const int tier3Tail = 512 * 1024;
      for (final largerTailSize in [tier2Tail, tier3Tail]) {
        if (size <= largerTailSize) continue;
        final largerReadSize = size < largerTailSize ? size : largerTailSize;
        final largerOffset = size - largerReadSize;
        final largerTailData = await _dataStore.storage
            .readAsBytesAt(path, largerOffset, length: largerReadSize);
        if (largerTailData.isEmpty) continue;
        final lastEntryLarger =
            await WalEncoder.decodeLastEntryFromTail(largerTailData, pIdx);
        if (lastEntryLarger != null) {
          final p = lastEntryLarger['p'] as int?;
          final seq = (lastEntryLarger['seq'] as num?)?.toInt();
          if (p != null && seq != null) {
            return WalPointer(partitionIndex: p, entrySeq: seq);
          }
        }
      }

      // Last resort: decode entire file (only if all tail scans failed)
      // This should be rare and only happen if the file structure is unusual
      final fullData = await _dataStore.storage.readAsBytes(path);
      if (fullData.isEmpty) {
        return WalPointer(partitionIndex: pIdx, entrySeq: 0);
      }
      final allEntries = await WalEncoder.decodeFile(fullData, pIdx);
      return WalPointer(partitionIndex: pIdx, entrySeq: allEntries.length);
    } catch (e) {
      Logger.warn('readLastWalPointer failed: $e', label: 'WalManager');
      return WalPointer(partitionIndex: pIdx, entrySeq: 0);
    }
  }

  /// Force rotation of the current partition.
  /// Called by the flush loop when checking partition size limits.
  Future<void> _rotatePartition() async {
    final pIdx = _current.partitionIndex;
    final dirIndex = _getOrAllocateDirIndexForPartition(pIdx);
    final path = _dataStore.pathManager.getWalPartitionLogPath(
      dirIndex,
      pIdx,
      spaceName: _dataStore.currentSpaceName,
    );

    // Move to next partition with cycle
    final next = (_current.partitionIndex + 1) % _config.logPartitionCycle;
    _current = WalPointer(partitionIndex: next, entrySeq: 0);

    // Update existing partition range [start..end] under cycle
    if (_meta.existingStartPartitionIndex == -1) {
      _meta.existingStartPartitionIndex = next;
      _meta.existingEndPartitionIndex = next;
    } else {
      // advance end; if overlaps start, advance start by one (drop oldest)
      final oldStart = _meta.existingStartPartitionIndex;
      _meta.existingEndPartitionIndex = next;
      if (next == oldStart) {
        _meta.existingStartPartitionIndex =
            (oldStart + 1) % _config.logPartitionCycle;
      }
    }

    await persistMeta(flush: true);

    final nextDirIndex = _getOrAllocateDirIndexForPartition(next);
    final newPath = _dataStore.pathManager.getWalPartitionLogPath(
        nextDirIndex, next,
        spaceName: _dataStore.currentSpaceName);

    // Close any stale handle for the new path before delete/truncate
    try {
      await _dataStore.storage.flushAll(path: newPath, closeHandles: true);
    } catch (_) {}
    try {
      await _dataStore.storage.deleteFile(newPath);
    } catch (_) {}

    // Close handle for the old (rotated out) partition to avoid leaking pooled handle
    try {
      await _dataStore.storage.flushAll(path: path, closeHandles: true);
    } catch (_) {}

    // Reset in-memory size approximation for the new active partition.
    _currentPartitionSizeApprox = 0;
    _currentPartitionSizeLoaded = true;
  }

  Future<void> persistMeta({bool flush = false, bool backupOld = false}) async {
    // Coalescing strategy: if persistMeta is already in progress, wait for it to complete.
    // If there's already a waiting request, replace it with this one (only latest matters).
    Completer<void>? myCompleter;

    if (_persistMetaInProgress) {
      // Cancel previous waiting request if exists (coalesce to latest)
      final previousCompleter = _nextPersistMetaCompleter;
      if (previousCompleter != null && !previousCompleter.isCompleted) {
        try {
          previousCompleter.complete();
        } catch (_) {}
      }

      // Create new completer for this request
      myCompleter = Completer<void>();
      _nextPersistMetaCompleter = myCompleter;

      // Wait for current persistMeta to complete (or timeout)
      try {
        await myCompleter.future.timeout(
          const Duration(seconds: 30),
          onTimeout: () {
            Logger.warn('persistMeta wait timeout after 30s, proceeding anyway',
                label: 'WalManager');
          },
        );
      } catch (e) {
        Logger.warn('persistMeta wait error: $e', label: 'WalManager');
      }

      // Check if we were superseded by a newer request
      if (_nextPersistMetaCompleter != myCompleter) {
        // A newer request came in, skip this one (coalesced)
        return;
      }

      // Double-check to prevent race condition
      while (_persistMetaInProgress) {
        await Future.delayed(const Duration(milliseconds: 10));
      }
    }

    _persistMetaInProgress = true;
    _nextPersistMetaCompleter = null; // Clear waiting request

    try {
      // Update directory mapping in meta if cache exists
      if (_directoryMapping != null) {
        _meta = _meta.copyWith(directoryMapping: _directoryMapping);
      }
      try {
        final metaPath = _dataStore.pathManager
            .getWalMainMetaPath(spaceName: _dataStore.currentSpaceName);

        // Optionally backup existing WAL meta before writing a new version.
        if (backupOld) {
          final backupPath = _dataStore.pathManager
              .getWalBackupMetaPath(spaceName: _dataStore.currentSpaceName);
          try {
            // Ensure any pooled handle for WAL meta is flushed and closed
            // before renaming, to avoid platform-specific rename failures.
            try {
              await _dataStore.storage
                  .flushAll(path: metaPath, closeHandles: true);
            } catch (_) {}

            final exists = await _dataStore.storage.existsFile(metaPath);
            if (exists) {
              // Atomically move current meta to backup path.
              await _dataStore.storage.replaceFileAtomic(metaPath, backupPath);
            }
          } catch (e) {
            // Backup failure should not block forward progress; just log it.
            Logger.error('Backup WAL meta failed: $e', label: 'WalManager');
          }
        }

        final jsonStr = jsonEncode(_meta.toJson());
        await _dataStore.storage.writeAsString(metaPath, jsonStr, flush: flush);
      } catch (e, stackTrace) {
        // Log the full error with stack trace for debugging
        Logger.error('Failed to persist WAL meta: $e\n$stackTrace',
            label: 'WalManager');
        // Don't rethrow: allow the operation to fail gracefully.
        // The next persistMeta call will retry, and the in-memory _meta
        // state remains correct even if persistence fails temporarily.
        // This prevents WAL meta write failures from interrupting the main
        // business flow (queries, inserts, updates, deletes).
      }
    } finally {
      _persistMetaInProgress = false;
      // Notify the next waiting request (if any)
      final nextCompleter = _nextPersistMetaCompleter;
      if (nextCompleter != null && !nextCompleter.isCompleted) {
        try {
          nextCompleter.complete();
        } catch (_) {}
        _nextPersistMetaCompleter = null;
      }
    }
  }

  /// Add a pending parallel batch (flush/maintenance)
  Future<void> addPendingParallelBatch(PendingParallelBatch batch) async {
    _meta.pendingBatches.add(batch);
    // Batch is critical for recovery; backup previous WAL meta before
    // persisting the new state that includes this pending batch.
    await persistMeta(flush: false, backupOld: true);
  }

  /// Remove a pending parallel batch by id
  Future<void> removePendingParallelBatch(String batchId) async {
    _meta.pendingBatches.removeWhere((b) => b.batchId == batchId);
    await persistMeta(flush: false);
  }

  /// Begin a large delete operation; opId should be globally unique and generated by caller.
  Future<void> beginLargeDelete({
    required String opId,
    required String table,
    required Map<String, dynamic> condition,
    List<String>? orderBy,
    int? limit,
    int? offset,
    int? startPartitionNo, // null means start from beginning
  }) async {
    if (!_initialized) {
      await initializeAndRecover();
    }
    _meta.largeDeletes[opId] = LargeDeleteMeta(
      opId: opId,
      table: table,
      condition: condition,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      lastProcessedPartitionNo: startPartitionNo,
      deletedSoFar: 0,
      status: 'running',
      createdAt: DateTime.now().toIso8601String(),
    );
    await persistMeta(flush: false);
  }

  /// Update checkpoint for a running large delete operation.
  Future<void> updateLargeDeleteCheckpoint({
    required String opId,
    required int? lastProcessedPartitionNo,
    required int deletedSoFar,
  }) async {
    final m = _meta.largeDeletes[opId];
    if (m == null) return;
    m.lastProcessedPartitionNo = lastProcessedPartitionNo;
    m.deletedSoFar = deletedSoFar;
    await persistMeta(flush: false);
  }

  /// Complete and remove a large delete operation from WAL meta.
  Future<void> completeLargeDelete(String opId) async {
    final m = _meta.largeDeletes[opId];
    if (m == null) return;
    m.status = 'completed';
    // Remove to keep meta compact
    _meta.largeDeletes.remove(opId);
    await persistMeta(flush: false);
  }

  /// Begin a large update operation; opId should be globally unique and generated by caller.
  Future<void> beginLargeUpdate({
    required String opId,
    required String table,
    required Map<String, dynamic> condition,
    required Map<String, dynamic> updateData,
    List<String>? orderBy,
    int? limit,
    int? offset,
    int? startPartitionNo, // null means start from beginning
  }) async {
    if (!_initialized) {
      await initializeAndRecover();
    }
    _meta.largeUpdates[opId] = LargeUpdateMeta(
      opId: opId,
      table: table,
      condition: condition,
      updateData: updateData,
      orderBy: orderBy,
      limit: limit,
      offset: offset,
      lastProcessedPartitionNo: startPartitionNo,
      updatedSoFar: 0,
      status: 'running',
      createdAt: DateTime.now().toIso8601String(),
    );
    await persistMeta(flush: false);
  }

  /// Update checkpoint for a running large update operation.
  Future<void> updateLargeUpdateCheckpoint({
    required String opId,
    required int? lastProcessedPartitionNo,
    required int updatedSoFar,
  }) async {
    final m = _meta.largeUpdates[opId];
    if (m == null) return;
    m.lastProcessedPartitionNo = lastProcessedPartitionNo;
    m.updatedSoFar = updatedSoFar;
    await persistMeta(flush: false);
  }

  /// Complete and remove a large update operation from WAL meta.
  Future<void> completeLargeUpdate(String opId) async {
    final m = _meta.largeUpdates[opId];
    if (m == null) return;
    m.status = 'completed';
    // Remove to keep meta compact
    _meta.largeUpdates.remove(opId);
    await persistMeta(flush: false);
  }

  /// Cancel and remove a large update operation from WAL meta (e.g., on transaction rollback).
  Future<void> cancelLargeUpdate(String opId) async {
    final m = _meta.largeUpdates[opId];
    if (m == null) return;
    // Remove immediately without marking as completed
    _meta.largeUpdates.remove(opId);
    await persistMeta(flush: false);
  }

  /// Register a table-level maintenance operation (clear/drop) into WAL meta.
  ///
  /// The caller is responsible for generating a unique [opId].
  Future<void> registerTableOp(TableOpMeta op) async {
    if (!_initialized) {
      await initializeAndRecover();
    }
    // At most keep one active maintenance op per table. Newer ops (with a
    // later cutoff) completely subsume older ones for the same table, so
    // we safely drop previous entries to keep WAL meta compact and avoid
    // repeated replays on restart.
    _meta.tableOps.removeWhere((_, existing) => existing.table == op.table);
    _meta.tableOps[op.opId] = op;
    await persistMeta(flush: false);
  }

  /// Mark a table-level maintenance operation as completed.
  ///
  /// Called by the clear/drop implementation *after* the physical table
  /// operation has finished successfully. We only set [completed]=true and
  /// persist; the op stays in [tableOps] so that WAL replay can still use
  /// its cutoff to skip obsolete entries. On next startup, [_resumePendingTableOps]
  /// will skip this op (only re-executes when completed==false). The op is
  /// removed later by [_pruneTableOpsUpToCheckpoint] when checkpoint advances
  /// past the cutoff.
  Future<void> completeTableOp(String opId) async {
    final op = _meta.tableOps[opId];
    if (op == null) return;
    _meta.tableOps[opId] = op.copyWith(completed: true);
    await persistMeta(flush: false);
  }
}

/// Internal WAL queue entry used by [WalManager] for background persistence.
class _QueuedWalEntry {
  final String path;
  final Map<String, dynamic> rawEntry;
  final WalPointer pointer;

  _QueuedWalEntry({
    required this.path,
    required this.rawEntry,
    required this.pointer,
  });
}
