import 'dart:async';
import 'dart:collection';

import '../handler/encryption.dart';
import '../handler/fast_wal_encoder.dart';
import '../handler/logger.dart';
import '../handler/platform_handler.dart';
import '../handler/wal_encoder.dart';
import '../handler/wal_meta_codec.dart';
import '../model/buffer_entry.dart' show BufferOperationType;
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/meta_info.dart';
import '../model/parallel_journal_entry.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/table_op_meta.dart';
import '../model/table_schema.dart' show TableSchema;
import '../model/wal_pointer.dart';
import 'compute/wal_decode_batch_runner.dart';
import 'cpu_work_chunk.dart';
import 'data_store_impl.dart';
import 'path_manager.dart';
import 'storage_adapter.dart';
import 'yield_controller.dart';

/// Pending parallel batch metadata recorded in WAL meta for recovery.
///
/// Batch lifecycle is entirely in WAL meta (present = incomplete). Per-partition
/// durable progress uses page0 `lastFlushBatchKey` / `lastMaintenanceBatchKey`.
class PendingParallelBatch {
  final String batchId;
  final BatchType batchType;
  final WalPointer
      start; // WAL start pointer for this batch (-1:-1 for maintenance)
  final WalPointer
      end; // WAL end pointer for this batch (-1:-1 for maintenance)
  final Map<TableUid, BatchTablePlan> tablePlans;
  final String createdAt; // ISO8601

  PendingParallelBatch({
    required this.batchId,
    required this.batchType,
    required this.start,
    required this.end,
    required this.tablePlans,
    required this.createdAt,
  });

  Iterable<TableUid> get tableUids => tablePlans.keys;

  Map<String, dynamic> toJson() => {
        'batchId': batchId,
        'batchType': batchType.value,
        'start': start.toJson(),
        'end': end.toJson(),
        'tablePlans': tablePlans.map((k, v) => MapEntry(k.value, v.toJson())),
        'createdAt': createdAt,
      };

  static PendingParallelBatch fromJson(Map<String, dynamic> json) {
    final rawPlans = (json['tablePlans'] as Map?) ??
        (json['tablePlan'] as Map?) ??
        const <String, dynamic>{};
    final tablePlans = <TableUid, BatchTablePlan>{};
    rawPlans.forEach((k, v) {
      tablePlans[TableUid(k.toString())] = BatchTablePlan.fromJson(
          ((v as Map?) ?? const {}).cast<String, dynamic>());
    });

    // Legacy: tables list without plans -- synthesize empty plans so keys exist.
    if (tablePlans.isEmpty) {
      final tables = ((json['tables'] as List?) ?? const <dynamic>[])
          .map((e) => e.toString())
          .where((e) => e.isNotEmpty);
      for (final t in tables) {
        tablePlans.putIfAbsent(
          TableUid(t),
          () => const BatchTablePlan(
            willUpdateTableDataMeta: true,
            indexes: <IndexUid>[],
            willUpdateIndexMeta: false,
          ),
        );
      }
    }

    return PendingParallelBatch(
      batchId: (json['batchId'] as String?) ?? '',
      batchType: BatchType.fromStringOrFlush(
          (json['batchType'] as String?) ?? (json['scope'] as String?)),
      start: WalPointer.fromJson(
          ((json['start'] as Map?) ?? const {}).cast<String, dynamic>()),
      end: WalPointer.fromJson(
          ((json['end'] as Map?) ?? const {}).cast<String, dynamic>()),
      tablePlans: tablePlans,
      createdAt:
          (json['createdAt'] as String?) ?? DateTime.now().toIso8601String(),
    );
  }

  PendingParallelBatch copyWith({
    String? batchId,
    BatchType? batchType,
    WalPointer? start,
    WalPointer? end,
    Map<TableUid, BatchTablePlan>? tablePlans,
    String? createdAt,
  }) {
    return PendingParallelBatch(
      batchId: batchId ?? this.batchId,
      batchType: batchType ?? this.batchType,
      start: start ?? this.start,
      end: end ?? this.end,
      tablePlans: tablePlans ?? this.tablePlans,
      createdAt: createdAt ?? this.createdAt,
    );
  }
}

/// WAL main metadata
class WalMeta {
  WalPointer checkpoint;
  int existingStartPartitionIndex; // inclusive
  int existingEndPartitionIndex; // inclusive
  // Pending batches for parallel recovery (supports multiple, flush/maintenance)
  List<PendingParallelBatch> pendingBatches;
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
    required this.pendingBatches,
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
    List<PendingParallelBatch>? pendingBatches,
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
      pendingBatches: pendingBatches ?? this.pendingBatches,
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
        'pendingBatches': pendingBatches.map((e) => e.toJson()).toList(),
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
        pendingBatches: <PendingParallelBatch>[],
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
      pendingBatches: ((json['pendingBatches'] as List?) ?? const <dynamic>[])
          .map((e) => PendingParallelBatch.fromJson(
              ((e as Map?) ?? const {}).cast<String, dynamic>()))
          .toList(),
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
  // Approximate size in bytes of the current WAL partition file (encoded
  // binary length on disk). Initialized lazily from storage on first append,
  // then maintained in memory to avoid per-append getFileSize() calls.
  int _currentPartitionSizeApprox = 0;
  bool _currentPartitionSizeLoaded = false;

  // WAL write queue (path + binary data + pointer) for background persistence.
  final Queue<_QueuedWalEntry> _walQueue = Queue<_QueuedWalEntry>();
  bool _walFlushInProgress = false;
  Future<void>? _walFlushFuture;

  // Reusable zero-allocation buffers for direct-to-OS synchronous appends.
  final FastWalBuffer _directSyncBuffer = FastWalBuffer(capacity: 64 * 1024);
  final FastWalBuffer _batchSyncBuffer = FastWalBuffer(capacity: 512 * 1024);
  bool _batchSyncBufferInUse = false;
  bool _directBatchInProgress = false;

  /// Physical fsync for [RecoveryDurability.durable]. Failures must surface —
  /// swallowing them would acknowledge a false durability guarantee.
  void _flushDurableSync(String path) {
    try {
      _dataStore.storage.flushFileSync(path);
    } catch (e) {
      Logger.error('Durable WAL flush failed for path: $path', rawError: e);
      if (e is DbException) rethrow;
      throw DbException([
        GeneralStatus(
          type: ResultType.sysIoGeneric,
          message: 'Durable WAL flush failed for path: $path, error: $e',
        ),
      ]);
    }
  }

  /// Claim [count] contiguous entrySeq values on the current partition.
  ///
  /// Advances [_current] **before** any await/yield so concurrent
  /// [appendDirectSync] / other batches cannot reuse the same seq range.
  /// Returns the first claimed seq (caller uses first..first+count-1).
  int _claimEntrySeqRange(int count) {
    assert(count > 0);
    final pIdx = _current.partitionIndex;
    final first = _current.entrySeq + 1;
    _current = WalPointer(
      partitionIndex: pIdx,
      entrySeq: _current.entrySeq + count,
    );
    return first;
  }

  /// Synchronously drain [_walQueue] into OS page cache (and fsync when durable).
  /// Returns `true` only when the queue is empty afterwards.
  ///
  /// Safe to call ONLY when `!_walFlushInProgress` to avoid out-of-order writes
  /// and concurrent file handle conflicts with background flushes.
  bool _drainWalQueueSync({required RecoveryDurability durability}) {
    if (_walQueue.isEmpty) return true;
    if (_walFlushInProgress) return false;

    FastWalBuffer? customBuf;
    FastWalBuffer buf;
    if (!_batchSyncBufferInUse) {
      _batchSyncBufferInUse = true;
      buf = _batchSyncBuffer;
      buf.reset();
    } else {
      buf = customBuf = FastWalBuffer(capacity: 64 * 1024);
    }

    final paths = <String>{};
    try {
      while (_walQueue.isNotEmpty && !_walFlushInProgress) {
        final currentPath = _walQueue.first.path;
        buf.reset();
        int lastPartition = _walQueue.first.pointer.partitionIndex;
        WalPointer? lastPointer;

        // Chunk contiguous entries targeting the same path into buf (up to 512KB)
        while (_walQueue.isNotEmpty &&
            _walQueue.first.path == currentPath &&
            buf.length < 512 * 1024) {
          final qEntry = _walQueue.removeFirst();
          FastWalEncoder.encodeEntryIntoBuffer(qEntry.rawEntry, buf);
          lastPartition = qEntry.pointer.partitionIndex;
          lastPointer = qEntry.pointer;
        }

        if (buf.length > 0) {
          final off = _dataStore.storage.appendBytesSync(
            currentPath,
            buf.bytesView,
          );
          if (off < 0) {
            return false;
          }
          final int written = buf.length;
          _durableDirtyPartitions.add(lastPartition);
          if (lastPartition == _current.partitionIndex) {
            _currentPartitionSizeApprox += written;
          }
          if (lastPointer != null) {
            _appended = lastPointer;
          }
          paths.add(currentPath);
        }
      }
    } catch (e) {
      Logger.error('Sync WAL queue drain failed', rawError: e);
      return false;
    } finally {
      if (customBuf == null) {
        _batchSyncBufferInUse = false;
      }
    }

    try {
      StorageAdapter.notifyRecoveryWrite();
    } catch (_) {}
    if (durability == RecoveryDurability.durable) {
      for (final path in paths) {
        _flushDurableSync(path);
      }
    }
    return _walQueue.isEmpty;
  }

  // Directory mapping cache
  DirectoryMapping? _directoryMapping;
  int _currentPartitionDirIndex = 0;

  String? _cachedWalPartitionPath;
  int _cachedWalPartitionIndex = -1;
  String? _cachedWalSpaceName;

  String _getWalPartitionLogPathCached(int pIdx) {
    final currentSpace = _dataStore.currentSpaceName;
    if (pIdx == _cachedWalPartitionIndex &&
        _cachedWalPartitionPath != null &&
        identical(currentSpace, _cachedWalSpaceName)) {
      return _cachedWalPartitionPath!;
    }
    final dirIndex = _getOrAllocateDirIndexForPartition(pIdx);
    final path = _dataStore.pathManager.getWalPartitionLogPath(
      dirIndex,
      pIdx,
      spaceName: currentSpace,
    );
    _cachedWalPartitionIndex = pIdx;
    _cachedWalSpaceName = currentSpace;
    _cachedWalPartitionPath = path;
    return path;
  }

  // Mutex for persistMeta to prevent concurrent writes
  // Use coalescing strategy: only the latest persistMeta needs to execute
  bool _persistMetaInProgress = false;
  Completer<void>? _nextPersistMetaCompleter; // Only the latest waiting request

  /// Partition rotation mutex and in-flight future
  bool _rotateInProgress = false;
  Future<void>? _rotateFuture;

  /// WAL partition indices with bytes written since last durable storage flush.
  Set<int> _durableDirtyPartitions = <int>{};

  /// Whether WAL main meta was written without a durable flush.
  bool _walMetaDurableDirty = false;

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

  /// Returns `true` if [pointer] has already been flushed into OS file buffers.
  bool isPointerFlushed(WalPointer pointer) {
    if (!_config.enableJournal) return true;
    if (pointer.partitionIndex < 0) return true;
    return isAtOrBefore(pointer, _appended);
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
      Logger.error('Failed to delete WAL directory', rawError: e);
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
    _clearDurableDirtyState();

    Logger.info('WAL destroyed.');
  }

  Future<void> initializeAndRecover() async {
    if (_initialized) return;
    if (_initFuture != null) {
      return _initFuture;
    }
    _initFuture = () async {
      try {
        // Web storage cannot rely on append-style WAL durability when journaling
        // is disabled, so startup should ignore stale recovery metadata entirely.
        if (!_config.enableJournal && PlatformHandler.isWeb) {
          _meta = WalMeta.initial(startPartitionIndex: 0);
          _directoryMapping = null;
          _currentPartitionDirIndex = 0;
          _current = const WalPointer(partitionIndex: 0, entrySeq: 0);
          _appended = const WalPointer(partitionIndex: 0, entrySeq: 0);
          _currentPartitionSizeLoaded = true;
          _currentPartitionSizeApprox = 0;
          _initialized = true;
          return;
        }

        final metaPath = _dataStore.pathManager
            .getWalMainMetaPath(spaceName: _dataStore.currentSpaceName);
        final backupPath = _dataStore.pathManager
            .getWalBackupMetaPath(spaceName: _dataStore.currentSpaceName);

        WalMeta? loaded;
        bool recoveredFromBackup = false;

        // 1) Try primary WAL meta (.tobf)
        try {
          if (await _dataStore.storage.existsFile(metaPath)) {
            final bytes = await _dataStore.storage.readAsBytes(metaPath);
            if (bytes.isNotEmpty) {
              loaded = WalMetaCodec.decodeFile(bytes);
            }
          }
        } catch (e) {
          // Primary meta is corrupted or unreadable; try temp file before backup.
          Logger.warn('Primary WAL meta is invalid, trying temp fallback.',
              rawError: e);
          try {
            final tempPath = PathManager.buildTempPath(metaPath);
            if (await _dataStore.storage.existsFile(tempPath)) {
              final tempBytes = await _dataStore.storage.readAsBytes(tempPath);
              if (tempBytes.isNotEmpty) {
                loaded = WalMetaCodec.decodeFile(tempBytes);
                recoveredFromBackup = true;
                // Self-heal: rewrite valid meta back
                unawaited(
                  _dataStore.storage
                      .writeAsBytes(metaPath, tempBytes, flush: true)
                      .catchError((_) {}),
                );
                Logger.info(
                    'WalMeta auto-recovered from temp file ($tempPath)');
              }
            }
          } catch (tempErr) {
            Logger.warn('Fallback to temp WalMeta failed, will try backup.',
                rawError: tempErr);
          }
        }

        // 2) Fallback to backup WAL meta if primary failed
        if (loaded == null) {
          try {
            if (await _dataStore.storage.existsFile(backupPath)) {
              final bytes = await _dataStore.storage.readAsBytes(backupPath);
              if (bytes.isNotEmpty) {
                loaded = WalMetaCodec.decodeFile(bytes);
                recoveredFromBackup = true;
                Logger.warn(
                    'Recovered WAL meta from backup after primary failure.');
              }
            }
          } catch (e) {
            Logger.error('Backup WAL meta is also invalid.', rawError: e);
          }
        }

        // 3) If both primary and backup are unusable, start with fresh meta
        _meta = loaded ?? WalMeta.initial(startPartitionIndex: 0);

        // Heal checkpoint poisoned by legacy bg-only flushes (sentinel -1).
        if (_meta.checkpoint.partitionIndex < 0) {
          Logger.warn(
            'Healing poisoned WAL checkpoint ${_meta.checkpoint} -> (0,0)',
          );
          _meta = _meta.copyWith(
            checkpoint: const WalPointer(partitionIndex: 0, entrySeq: 0),
          );
          try {
            await persistMeta(flush: true);
          } catch (_) {}
        }

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
      } catch (e) {
        Logger.error('Failed to initialize WAL meta', rawError: e);
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

  @pragma('vm:prefer-inline')
  bool get _needsPartitionRotation =>
      !_currentPartitionSizeLoaded ||
      _currentPartitionSizeApprox >= _config.maxLogPartitionFileSize;

  /// Rotate before assigning path/seq when the active partition already meets
  /// [DataStoreConfig.maxLogPartitionFileSize], so new entries land on a
  /// writable partition instead of growing an already-full file.
  Future<void> _ensureWritablePartition() async {
    if (!_currentPartitionSizeLoaded) {
      await _ensureCurrentPartitionSizeLoaded();
    }
    if (_currentPartitionSizeApprox >= _config.maxLogPartitionFileSize) {
      await _rotatePartition();
    }
  }

  /// Hard + predictive rotation after a flush batch lands on disk.
  ///
  /// - Hard: current partition encoded size already >= limit.
  /// - Predictive: remaining queue for this partition would push us over;
  ///   rotate so subsequent [append]/[appendBatch] use the next file.
  /// Already-queued entries keep their assigned path/p/seq (soft overrun).
  Future<void> _maybeRotateAfterAppend({
    required int writtenBytes,
    required int entryCount,
    required bool wroteToCurrentPartition,
  }) async {
    if (wroteToCurrentPartition &&
        _currentPartitionSizeApprox >= _config.maxLogPartitionFileSize) {
      await _rotatePartition();
      return;
    }
    if (entryCount <= 0 || _walQueue.isEmpty) return;
    if (_walQueue.first.pointer.partitionIndex != _current.partitionIndex) {
      return;
    }
    final int avgSize = (writtenBytes / entryCount).ceil();
    final int estimatedBacklog = _walQueue.length * avgSize;
    if (_currentPartitionSizeApprox + estimatedBacklog >
        _config.maxLogPartitionFileSize) {
      await _rotatePartition();
    }
  }

  /// Append one WAL entry. Returns its pointer.
  Future<WalPointer> append(
    Map<String, dynamic> walEntry, {
    RecoveryDurability? durability,
  }) async {
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

    if (_needsPartitionRotation) {
      await _ensureWritablePartition();
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
    // Mutate in place -- same ownership contract as appendBatch: callers own
    // the map and must not reuse it after enqueue.
    walEntry['p'] = pIdx;
    walEntry['seq'] = nextSeq;

    final path = _getWalPartitionLogPathCached(pIdx);

    // Initialize existing partition range on first write to avoid later scans
    if (_meta.existingStartPartitionIndex < 0 ||
        _meta.existingEndPartitionIndex < 0) {
      _meta.existingStartPartitionIndex = pIdx;
      _meta.existingEndPartitionIndex = pIdx;
      // We can persist update meta asynchronously
      persistMeta(flush: false);
    }

    final effDurability = durability ?? _config.defaultRecoveryDurability;

    // Fast path for async durability:
    // enqueue to memory queue and return immediately
    if (effDurability == RecoveryDurability.async) {
      _walQueue.add(_QueuedWalEntry(
        path: path,
        rawEntry: walEntry,
        pointer: _current,
      ));
      scheduleFlushIfNeeded();
      return WalPointer(partitionIndex: pIdx, entrySeq: _current.entrySeq);
    }

    // Direct-to-OS fast path: synchronous write into OS page cache
    bool directWritten = false;
    if (_walQueue.isEmpty) {
      try {
        final buf = _directSyncBuffer;
        buf.reset();
        FastWalEncoder.encodeEntryIntoBuffer(walEntry, buf);
        final writtenOffset = _dataStore.storage.appendBytesSync(
          path,
          buf.bytesView,
        );
        if (writtenOffset >= 0) {
          final int writtenBytes = buf.length;
          _durableDirtyPartitions.add(pIdx);
          _currentPartitionSizeApprox += writtenBytes;
          _appended = _current;
          directWritten = true;
          try {
            StorageAdapter.notifyRecoveryWrite();
          } catch (_) {}
        }
      } catch (e) {
        Logger.error('Direct sync WAL append failed for path: $path',
            rawError: e);
        directWritten = false;
      }
      if (directWritten) {
        if (effDurability == RecoveryDurability.durable) {
          _flushDurableSync(path);
        }
        if (_currentPartitionSizeApprox >= _config.maxLogPartitionFileSize) {
          await _rotatePartition();
        }
      }
    }

    if (!directWritten) {
      // Enqueue into WAL write queue for background persistence as fallback
      _walQueue.add(_QueuedWalEntry(
        path: path,
        rawEntry: walEntry,
        pointer: _current,
      ));
      if (effDurability != RecoveryDurability.async) {
        await flushQueueCompletely();
        if (effDurability == RecoveryDurability.durable) {
          _flushDurableSync(path);
        }
      } else {
        scheduleFlushIfNeeded();
      }
    }

    // Persist meta lazily; rotation/checkpoint will persist. Return the precise
    // in-memory WAL pointer for this entry.
    return WalPointer(partitionIndex: pIdx, entrySeq: _current.entrySeq);
  }

  String _cachedTimestampIso = DateTime.now().toIso8601String();
  int _lastTimestampUpdateMs = DateTime.now().millisecondsSinceEpoch;

  @pragma('vm:prefer-inline')
  String get _currentTimestampIso {
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    if (nowMs - _lastTimestampUpdateMs > 10) {
      _lastTimestampUpdateMs = nowMs;
      _cachedTimestampIso =
          DateTime.fromMillisecondsSinceEpoch(nowMs).toIso8601String();
    }
    return _cachedTimestampIso;
  }

  /// Direct synchronous WAL append for single records.
  WalPointer appendDirectSync({
    required TableContext table,
    required BufferOperationType operation,
    required Map<String, dynamic> data,
    Map<String, dynamic>? oldValues,
    String? transactionId,
    RecoveryDurability? durability,
    String? tsIso,
  }) {
    if (!_initialized) {
      throw DbException([
        GeneralStatus(
          type: ResultType.engError,
          message: 'WalManager must be initialized before appendDirectSync',
        ),
      ]);
    }

    if (!_config.enableJournal) {
      _current = WalPointer(
        partitionIndex: _current.partitionIndex,
        entrySeq: _current.entrySeq + 1,
      );
      return WalPointer(partitionIndex: -1, entrySeq: _current.entrySeq);
    }

    final pIdx = _current.partitionIndex;
    final nextSeq = _claimEntrySeqRange(1);
    final path = _getWalPartitionLogPathCached(pIdx);
    final pointer = WalPointer(partitionIndex: pIdx, entrySeq: nextSeq);

    if (_meta.existingStartPartitionIndex < 0 ||
        _meta.existingEndPartitionIndex < 0) {
      _meta.existingStartPartitionIndex = pIdx;
      _meta.existingEndPartitionIndex = pIdx;
      persistMeta(flush: false);
    }

    final effDurability = durability ?? _config.defaultRecoveryDurability;
    final actualTsIso = tsIso ?? _currentTimestampIso;

    Map<String, dynamic> buildEntry() => <String, dynamic>{
          'op': operation.index,
          'table': table.tableUid,
          'data': data,
          'ts': actualTsIso,
          'p': pIdx,
          'seq': nextSeq,
          if (transactionId != null) 'txId': transactionId,
          if (oldValues != null) 'oldValues': oldValues,
        };

    if (effDurability == RecoveryDurability.async) {
      _walQueue.add(_QueuedWalEntry(
        path: path,
        rawEntry: buildEntry(),
        pointer: pointer,
      ));
      scheduleFlushIfNeeded();
      return pointer;
    }

    // Direct-to-OS fast path: synchronous write into OS page cache
    // Only attempt direct write if queue is empty, no async flush is in progress, and no batch direct write is running.
    if (_walQueue.isEmpty && !_walFlushInProgress && !_directBatchInProgress) {
      try {
        final buf = _directSyncBuffer;
        buf.reset();
        FastWalEncoder.encodeDirectEntryIntoBuffer(
          buf,
          op: operation.index,
          tableUid: table.tableUid,
          data: data,
          tsIso: actualTsIso,
          partitionIndex: pIdx,
          seq: nextSeq,
          txId: transactionId,
          oldValues: oldValues,
        );
        final writtenOffset = _dataStore.storage.appendBytesSync(
          path,
          buf.bytesView,
        );
        if (writtenOffset >= 0) {
          final int writtenBytes = buf.length;
          _durableDirtyPartitions.add(pIdx);
          _currentPartitionSizeApprox += writtenBytes;
          _appended = pointer;
          try {
            StorageAdapter.notifyRecoveryWrite();
          } catch (_) {}
          if (effDurability == RecoveryDurability.durable) {
            _flushDurableSync(path);
          }
          if (_currentPartitionSizeApprox >= _config.maxLogPartitionFileSize) {
            _rotatePartitionSync(pIdx, path);
          }
          // Soft overrun OK: next append()/appendBatch or background rotation will rotate.
          return pointer;
        }
      } catch (e) {
        Logger.error('Direct sync WAL append failed for path: $path',
            rawError: e);
        if (effDurability == RecoveryDurability.durable) {
          if (e is DbException) rethrow;
          throw DbException([
            GeneralStatus(
              type: ResultType.sysIoGeneric,
              message:
                  'Direct sync durable append failed for path: $path, error: $e',
            ),
          ]);
        }
      }
    }

    // Queued / fallback path: enqueue this entry
    _walQueue.add(_QueuedWalEntry(
      path: path,
      rawEntry: buildEntry(),
      pointer: pointer,
    ));

    // Attempt synchronous drain only when no background pump is actively running
    if (!_walFlushInProgress) {
      _drainWalQueueSync(durability: effDurability);
    }

    // Ensure pump is scheduled if entries remain in queue.
    // Callers in data_store_impl inspect isPointerFlushed(pointer) and await
    // ensureAppendedUpTo if standard/durable persistence has not yet landed.
    if (_walQueue.isNotEmpty) {
      scheduleFlushIfNeeded();
    }
    return pointer;
  }

  /// Append multiple WAL entries in a single batch. Returns their pointers.
  ///
  /// This is significantly faster than calling [append] in a loop for large
  /// datasets (10k+ entries) because it minimizes microtask yields and allows
  /// the background flush pump to process the entries more efficiently.
  Future<List<WalPointer>> appendBatch(
    List<Map<String, dynamic>> walEntries, {
    RecoveryDurability? durability,
  }) async {
    if (!_initialized) {
      await initializeAndRecover();
    }

    if (walEntries.isEmpty) return const <WalPointer>[];

    // If journal disabled, still create pseudo pointers to maintain order in memory
    if (!_config.enableJournal) {
      final count = walEntries.length;
      final pIdx = _current.partitionIndex;
      final firstSeq = _current.entrySeq + 1;
      _current = WalPointer(
        partitionIndex: pIdx,
        entrySeq: _current.entrySeq + count,
      );
      final result = List<WalPointer>.filled(count, _current, growable: false);
      for (int i = 0; i < count; i++) {
        result[i] = WalPointer(partitionIndex: -1, entrySeq: firstSeq + i);
      }
      return result;
    }

    if (_needsPartitionRotation ||
        _currentPartitionSizeApprox >= _config.maxLogPartitionFileSize) {
      await _ensureWritablePartition();
    }

    int pIdx = _current.partitionIndex;
    int dirIndex = _getOrAllocateDirIndexForPartition(pIdx);
    String path = _dataStore.pathManager.getWalPartitionLogPath(
      dirIndex,
      pIdx,
      spaceName: _dataStore.currentSpaceName,
    );

    // Publish range before the yield loop so a concurrent flush rotate cannot
    // treat existingStart as uninitialized and drop the first partition.
    if (_meta.existingStartPartitionIndex < 0 ||
        _meta.existingEndPartitionIndex < 0) {
      _meta.existingStartPartitionIndex = pIdx;
      _meta.existingEndPartitionIndex = pIdx;
      persistMeta(flush: false);
    }

    final yieldController =
        _dataStore.parallelJournalManager.activeBatchOperationCount > 0
            ? YieldController(
                'WalManager.appendBatch',
                minCheckInterval: EngineCpuChunk.fastPathMinCheckInterval,
              )
            : YieldController('WalManager.appendBatch');

    final effDurability = durability ?? _config.defaultRecoveryDurability;
    final int count = walEntries.length;
    final int firstSeq = _claimEntrySeqRange(count);
    final List<WalPointer> pointers =
        List<WalPointer>.filled(count, _current, growable: false);

    // Fast path for async durability:
    // enqueue to memory queue and return immediately
    if (effDurability == RecoveryDurability.async) {
      for (int i = 0; i < count; i++) {
        final y = yieldController.maybeYield();
        if (y != null) await y;

        final pointer =
            WalPointer(partitionIndex: pIdx, entrySeq: firstSeq + i);
        pointers[i] = pointer;
        final entry = walEntries[i];
        entry['p'] = pIdx;
        entry['seq'] = pointer.entrySeq;

        _walQueue.add(_QueuedWalEntry(
          path: path,
          rawEntry: entry,
          pointer: pointer,
        ));
      }

      scheduleFlushIfNeeded();
      return pointers;
    }

    // Direct-to-OS fast path: encode into buffer and write synchronously
    if (!_walFlushInProgress && !_directBatchInProgress && _walQueue.isEmpty) {
      _directBatchInProgress = true;
      FastWalBuffer? customBuf;
      FastWalBuffer buf;
      if (!_batchSyncBufferInUse) {
        _batchSyncBufferInUse = true;
        buf = _batchSyncBuffer;
        buf.reset();
      } else {
        buf = customBuf = FastWalBuffer(capacity: 64 * 1024);
      }

      try {
        for (int i = 0; i < count; i++) {
          final y = yieldController.maybeYield();
          if (y != null) await y;

          final pointer =
              WalPointer(partitionIndex: pIdx, entrySeq: firstSeq + i);
          pointers[i] = pointer;
          final entry = walEntries[i];
          entry['p'] = pIdx;
          entry['seq'] = pointer.entrySeq;

          FastWalEncoder.encodeEntryIntoBuffer(entry, buf);
        }

        bool directSuccess = false;
        if (buf.length > 0) {
          try {
            final off = _dataStore.storage.appendBytesSync(path, buf.bytesView);
            if (off >= 0) {
              _durableDirtyPartitions.add(pIdx);
              _currentPartitionSizeApprox += buf.length;
              _appended = pointers.last;
              directSuccess = true;
              try {
                StorageAdapter.notifyRecoveryWrite();
              } catch (_) {}
            }
          } catch (e) {
            Logger.error('Direct sync batch WAL append failed for path: $path',
                rawError: e);
            directSuccess = false;
          }
        } else {
          directSuccess = true;
        }

        if (directSuccess) {
          if (effDurability == RecoveryDurability.durable) {
            _flushDurableSync(path);
          }
          if (_currentPartitionSizeApprox >= _config.maxLogPartitionFileSize) {
            try {
              await _rotatePartition();
            } catch (e) {
              Logger.warn('WAL post-batch partition rotation failed',
                  rawError: e);
            }
          }
          return pointers;
        }
      } finally {
        _directBatchInProgress = false;
        if (customBuf == null) {
          _batchSyncBufferInUse = false;
        }
      }

      // Fallback: enqueue on failure (entries already have p/seq assigned)
      for (int i = 0; i < count; i++) {
        final entry = walEntries[i];
        entry['p'] = pointers[i].partitionIndex;
        entry['seq'] = pointers[i].entrySeq;
        _walQueue.add(_QueuedWalEntry(
          path: path,
          rawEntry: entry,
          pointer: pointers[i],
        ));
      }
      await ensureAppendedUpTo(
        pointers.last,
        flushToStorage: effDurability == RecoveryDurability.durable,
      );
      if (effDurability == RecoveryDurability.durable) {
        _flushDurableSync(path);
      }
      return pointers;
    }

    // Standard queued fallback path if _walQueue already has pending entries
    for (int i = 0; i < count; i++) {
      final y = yieldController.maybeYield();
      if (y != null) await y;

      final pointer = WalPointer(partitionIndex: pIdx, entrySeq: firstSeq + i);
      pointers[i] = pointer;
      final entry = walEntries[i];
      entry['p'] = pIdx;
      entry['seq'] = pointer.entrySeq;

      _walQueue.add(_QueuedWalEntry(
        path: path,
        rawEntry: entry,
        pointer: pointer,
      ));
    }

    await ensureAppendedUpTo(
      pointers.last,
      flushToStorage: effDurability == RecoveryDurability.durable,
    );
    if (effDurability == RecoveryDurability.durable) {
      _flushDurableSync(path);
    }

    return pointers;
  }

  /// Direct streaming batch WAL append avoiding intermediate wrapper Maps and redundant lookups.
  ///
  /// Serializes records directly into contiguous partition byte buffer and writes to OS synchronously.
  Future<List<WalPointer>> appendBatchDirect({
    required TableContext table,
    required BufferOperationType operation,
    required String tsIso,
    required List<Map<String, dynamic>> records,
    TableSchema? schema,
    String? transactionId,
    List<Map<String, dynamic>?>? oldValuesList,
    RecoveryDurability? durability,
  }) async {
    if (!_initialized) {
      await initializeAndRecover();
    }

    final int count = records.length;
    if (count == 0) return const <WalPointer>[];

    // If journal disabled, still create pseudo pointers to maintain order in memory
    // If journal disabled, still create pseudo pointers to maintain order in memory
    if (!_config.enableJournal) {
      final pIdx = _current.partitionIndex;
      final firstSeq = _current.entrySeq + 1;
      _current = WalPointer(
        partitionIndex: pIdx,
        entrySeq: _current.entrySeq + count,
      );
      final result = List<WalPointer>.filled(count, _current, growable: false);
      for (int i = 0; i < count; i++) {
        result[i] = WalPointer(partitionIndex: -1, entrySeq: firstSeq + i);
      }
      return result;
    }

    if (_needsPartitionRotation) {
      await _ensureWritablePartition();
    }

    int pIdx = _current.partitionIndex;
    int dirIndex = _getOrAllocateDirIndexForPartition(pIdx);
    String path = _dataStore.pathManager.getWalPartitionLogPath(
      dirIndex,
      pIdx,
      spaceName: _dataStore.currentSpaceName,
    );

    if (_meta.existingStartPartitionIndex < 0 ||
        _meta.existingEndPartitionIndex < 0) {
      _meta.existingStartPartitionIndex = pIdx;
      _meta.existingEndPartitionIndex = pIdx;
      persistMeta(flush: false);
    }

    final yieldController = YieldController(
      'WalManager.appendBatchDirect',
      minCheckInterval: EngineCpuChunk.fastPathMinCheckInterval,
    );

    final effDurability = durability ?? _config.defaultRecoveryDurability;
    final bool hasOldValues = oldValuesList != null && oldValuesList.isNotEmpty;

    final int firstSeq = _claimEntrySeqRange(count);
    final List<WalPointer> pointers =
        List<WalPointer>.filled(count, _current, growable: false);

    // Fast path for async durability:
    // enqueue to memory queue and return immediately
    if (effDurability == RecoveryDurability.async) {
      for (int i = 0; i < count; i++) {
        final y = yieldController.maybeYield();
        if (y != null) await y;

        final pointer =
            WalPointer(partitionIndex: pIdx, entrySeq: firstSeq + i);
        pointers[i] = pointer;
        final entry = <String, dynamic>{
          'op': operation.index,
          'table': table.tableUid,
          'ts': tsIso,
          'p': pIdx,
          'seq': pointer.entrySeq,
          'data': records[i],
        };
        if (transactionId != null) entry['txId'] = transactionId;
        if (hasOldValues &&
            i < oldValuesList.length &&
            oldValuesList[i] != null) {
          entry['oldValues'] = oldValuesList[i];
        }

        _walQueue.add(_QueuedWalEntry(
          path: path,
          rawEntry: entry,
          pointer: pointer,
        ));
      }
      scheduleFlushIfNeeded();
      return pointers;
    }

    // Direct-to-OS fast path: encode into buffer and write synchronously
    if (!_walFlushInProgress && !_directBatchInProgress && _walQueue.isEmpty) {
      _directBatchInProgress = true;
      FastWalBuffer? customBuf;
      FastWalBuffer buf;
      if (!_batchSyncBufferInUse) {
        _batchSyncBufferInUse = true;
        buf = _batchSyncBuffer;
        buf.reset();
      } else {
        buf = customBuf = FastWalBuffer(capacity: 64 * 1024);
      }

      try {
        final effectiveSchema = schema ?? table.schema;
        final bool useSchemaSession = effectiveSchema.fields.isNotEmpty;

        FastWalTableSession? tableSession;
        FastWalBatchSession? batchSession;
        if (useSchemaSession) {
          tableSession = FastWalTableSession.create(
            op: operation.index,
            tableUid: table.tableUid,
            tsIso: tsIso,
            partitionIndex: pIdx,
            schema: effectiveSchema,
            txId: transactionId,
            hasOldValues: hasOldValues,
          );
        } else {
          batchSession = FastWalBatchSession.create(
            op: operation.index,
            tableUid: table.tableUid,
            tsIso: tsIso,
            partitionIndex: pIdx,
            txId: transactionId,
            hasOldValues: hasOldValues,
          );
        }

        int recEst = tableSession?.estimatedRecordBytes ?? 128;
        final avgDataBytes =
            _dataStore.tableDataManager.averageTableRecordSizeBytes;
        if (avgDataBytes != null && avgDataBytes > 0) {
          final int adjusted = avgDataBytes + 64;
          if (adjusted > recEst) {
            recEst = adjusted;
          }
        }
        buf.ensureAvailable(count * recEst + 4096);

        for (int i = 0; i < count; i++) {
          final y = yieldController.maybeYield();
          if (y != null) await y;

          final pointer =
              WalPointer(partitionIndex: pIdx, entrySeq: firstSeq + i);
          pointers[i] = pointer;
          final r = records[i];
          final oldR = (hasOldValues && i < oldValuesList.length)
              ? oldValuesList[i]
              : null;

          if (tableSession != null) {
            tableSession.encodeRecordDirect(
              buf,
              r,
              pointer.entrySeq,
              oldR,
              true,
            );
          } else {
            batchSession!.encodeRecordDirect(buf, r, pointer.entrySeq, oldR);
          }
        }

        bool directSuccess = false;
        if (buf.length > 0) {
          try {
            final off = _dataStore.storage.appendBytesSync(path, buf.bytesView);
            if (off >= 0) {
              _durableDirtyPartitions.add(pIdx);
              _currentPartitionSizeApprox += buf.length;
              _appended = pointers.last;
              directSuccess = true;
              try {
                StorageAdapter.notifyRecoveryWrite();
              } catch (_) {}
            }
          } catch (e) {
            Logger.error('Direct sync batch WAL append failed for path: $path',
                rawError: e);
            directSuccess = false;
          }
        } else {
          directSuccess = true;
        }

        if (directSuccess) {
          if (effDurability == RecoveryDurability.durable) {
            _flushDurableSync(path);
          }
          if (_currentPartitionSizeApprox >= _config.maxLogPartitionFileSize) {
            try {
              await _rotatePartition();
            } catch (e) {
              Logger.warn('WAL post-batch partition rotation failed',
                  rawError: e);
            }
          }
          return pointers;
        }
      } finally {
        _directBatchInProgress = false;
        if (customBuf == null) {
          _batchSyncBufferInUse = false;
        }
      }

      // Fallback: enqueue on failure
      for (int i = 0; i < count; i++) {
        final fallbackEntry = <String, dynamic>{
          'op': operation.index,
          'table': table.tableUid,
          'ts': tsIso,
          'p': pointers[i].partitionIndex,
          'seq': pointers[i].entrySeq,
          'data': records[i],
        };
        if (transactionId != null) fallbackEntry['txId'] = transactionId;
        if (hasOldValues &&
            i < oldValuesList.length &&
            oldValuesList[i] != null) {
          fallbackEntry['oldValues'] = oldValuesList[i];
        }
        _walQueue.add(_QueuedWalEntry(
          path: path,
          rawEntry: fallbackEntry,
          pointer: pointers[i],
        ));
      }
      await ensureAppendedUpTo(
        pointers.last,
        flushToStorage: effDurability == RecoveryDurability.durable,
      );
      if (effDurability == RecoveryDurability.durable) {
        _flushDurableSync(path);
      }
      return pointers;
    }

    // Standard queued fallback path if _walQueue already has pending entries
    for (int i = 0; i < count; i++) {
      final y = yieldController.maybeYield();
      if (y != null) await y;

      final pointer = WalPointer(partitionIndex: pIdx, entrySeq: firstSeq + i);
      pointers[i] = pointer;
      final entry = <String, dynamic>{
        'op': operation.index,
        'table': table.tableUid,
        'ts': tsIso,
        'p': pIdx,
        'seq': pointer.entrySeq,
        'data': records[i],
      };
      if (transactionId != null) entry['txId'] = transactionId;
      if (hasOldValues &&
          i < oldValuesList.length &&
          oldValuesList[i] != null) {
        entry['oldValues'] = oldValuesList[i];
      }

      _walQueue.add(_QueuedWalEntry(
        path: path,
        rawEntry: entry,
        pointer: pointer,
      ));
    }

    await ensureAppendedUpTo(
      pointers.last,
      flushToStorage: effDurability == RecoveryDurability.durable,
    );
    if (effDurability == RecoveryDurability.durable) {
      _flushDurableSync(path);
    }

    return pointers;
  }

  /// Advance checkpoint after a batch has been safely flushed to data files.
  Future<void> advanceCheckpoint(WalPointer pointer) async {
    // Pseudo pointers (partitionIndex < 0) are used for journal-disabled / bg-only
    // batches and must never poison the durable checkpoint.
    if (pointer.partitionIndex < 0) {
      Logger.warn(
        'Ignoring advanceCheckpoint with pseudo WAL pointer $pointer',
      );
      return;
    }
    if (_meta.checkpoint == pointer && !_walMetaDurableDirty) {
      return;
    }
    _meta.checkpoint = pointer;
    // After advancing checkpoint, remove table-level ops whose cutoff is
    // older than or equal to the new checkpoint; they can no longer affect
    // recovery semantics.
    _pruneTableOpsUpToCheckpoint();
    // At batch commit, also backup previous WAL meta for recovery.
    await persistMeta(flush: false, backupOld: true);
  }

  /// Gracefully synchronize checkpoint and recovery hint on shutdown.
  ///
  /// Zero-I/O Optimization:
  /// When database is clean (checkpoint and recovery pointers are already aligned
  /// with [currentPtr], tail partition file size is unchanged, and meta is not dirty),
  /// this method returns immediately with ZERO disk writes, renames, or fsyncs.
  ///
  /// Dirty Consolidation:
  /// If state has changed, all updates (checkpoint advancement, table op pruning,
  /// recovery pointer and tail file size) are consolidated in-memory and persisted
  /// in a SINGLE atomic write with flush: true (reducing 3 serial writes down to 1).
  Future<void> syncCheckpointOnClose(WalPointer currentPtr) async {
    if (!_config.enableJournal) return;

    // Ensure any in-flight background rotation completes before inspecting or synchronizing checkpoint
    while (_rotateInProgress && _rotateFuture != null) {
      try {
        await _rotateFuture;
      } catch (_) {}
    }

    // Ensure any in-flight background persistMeta finishes before we inspect or persist
    while (_persistMetaInProgress) {
      await Future.delayed(const Duration(milliseconds: 5));
    }

    if (currentPtr.partitionIndex < 0) {
      if (_walMetaDurableDirty) {
        await persistMeta(flush: true);
      }
      return;
    }

    final bool checkpointChanged = _meta.checkpoint != currentPtr;
    final bool recoveryPtrChanged = _meta.lastRecoveredPointer != currentPtr;
    final bool metaDirty = _walMetaDurableDirty;

    // 1. Fast-path Zero-I/O check for clean shutdown:
    if (!checkpointChanged &&
        !recoveryPtrChanged &&
        !metaDirty &&
        _meta.lastRecoveredTailFileSize != null) {
      // Pointers are already aligned and meta is durable on disk.
      // If no partitions exist, return immediately with 0 I/O.
      if (_meta.existingEndPartitionIndex < 0) {
        return;
      }
      // If partitions exist, verify whether tail file size matches.
      if (_currentPartitionSizeLoaded &&
          _current.partitionIndex == currentPtr.partitionIndex) {
        if (_meta.lastRecoveredTailFileSize == _currentPartitionSizeApprox) {
          return; // 0 disk I/O!
        }
      } else {
        // Fallback file size check only if not tracked in memory
        final pIdx = currentPtr.partitionIndex;
        final dirIndex = getPartitionDirIndex(pIdx);
        if (dirIndex != null) {
          final path = _dataStore.pathManager.getWalPartitionLogPath(
            dirIndex,
            pIdx,
            spaceName: _dataStore.currentSpaceName,
          );
          try {
            if (await _dataStore.storage.existsFile(path)) {
              final currentSize = await _dataStore.storage.getFileSize(path);
              if (_meta.lastRecoveredTailFileSize == currentSize) {
                return; // 0 disk writes!
              }
            }
          } catch (_) {}
        }
      }
    }

    // 2. State is dirty or pointers need update:
    int tailSize = 0;
    if (_currentPartitionSizeLoaded &&
        _current.partitionIndex == currentPtr.partitionIndex) {
      tailSize = _currentPartitionSizeApprox;
    } else {
      final pIdx = currentPtr.partitionIndex;
      final dirIndex = getPartitionDirIndex(pIdx);
      if (dirIndex != null) {
        final path = _dataStore.pathManager.getWalPartitionLogPath(
          dirIndex,
          pIdx,
          spaceName: _dataStore.currentSpaceName,
        );
        try {
          if (await _dataStore.storage.existsFile(path)) {
            tailSize = await _dataStore.storage.getFileSize(path);
          }
        } catch (_) {}
      }
    }

    // Double check if tail file size check revealed no actual changes
    if (!checkpointChanged &&
        !recoveryPtrChanged &&
        !metaDirty &&
        _meta.lastRecoveredTailFileSize == tailSize) {
      return; // 0 disk writes!
    }

    // Consolidate updates in memory
    _meta.checkpoint = currentPtr;
    _pruneTableOpsUpToCheckpoint();
    _meta = _meta.copyWith(
      lastRecoveredPointer: currentPtr,
      lastRecoveredTailFileSize: tailSize,
    );

    // Exactly 1 atomic disk write with durable flush
    await persistMeta(flush: true, backupOld: checkpointChanged);
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
      final y2 = yieldController.maybeYield();
      if (y2 != null) await y2;
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
      pendingBatches: _meta.pendingBatches,
      tableOps: _meta.tableOps,
      directoryMapping: null,
      lastRecoveredPointer: null,
      lastRecoveredTailFileSize: null,
    );
    _currentPartitionSizeLoaded = true;
    _currentPartitionSizeApprox = 0;
    _clearDurableDirtyState();
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
      final checkpoint = _meta.checkpoint.partitionIndex;

      if (start == checkpoint) {
        return;
      }

      // Only partitions on [start, checkpoint) within [start..end] are obsolete.
      // Scan directoryMapping keys instead of walking every index in the ring --
      // when start=0 and checkpoint~=899999 that would iterate ~900k slots even
      // though almost none have files or mapping entries.
      bool isInExistingRange(int p) {
        if (start <= end) return p >= start && p <= end;
        return p >= start || p <= end;
      }

      bool isOnForwardArc(int p, int from, int toExclusive) {
        if (from <= toExclusive) return p >= from && p < toExclusive;
        return p >= from || p < toExclusive;
      }

      bool isObsoletePartition(int p) {
        if (p == checkpoint) return false;
        return isInExistingRange(p) && isOnForwardArc(p, start, checkpoint);
      }

      final partitionToDirIndex = <int, int>{};
      final mapping = _directoryMapping;
      if (mapping != null && mapping.partitionToDir.isNotEmpty) {
        for (final entry in mapping.partitionToDir.entries) {
          final p = entry.key;
          if (isObsoletePartition(p)) {
            partitionToDirIndex[p] = entry.value;
          }
        }
      }

      final yieldController = YieldController(
          'WalManager.cleanupObsoletePartitions',
          checkInterval: 1);

      // Delete partition files that still have mapping entries
      for (final entry in partitionToDirIndex.entries) {
        final y3 = yieldController.maybeYield();
        if (y3 != null) await y3;
        final p = entry.key;
        final dirIndex = entry.value;
        final path = _dataStore.pathManager.getWalPartitionLogPath(dirIndex, p,
            spaceName: _dataStore.currentSpaceName);
        try {
          // Ensure any pooled handle is flushed and closed before deleting the file
          try {
            await _dataStore.storage.flushAll(path: path, closeHandles: true);
          } catch (_) {}
          await _dataStore.storage.deleteFile(path);
          _markPartitionDurable(p);
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

      // Advance start to checkpoint: unmapped indices never had files.
      _meta = _meta.copyWith(
        existingStartPartitionIndex: checkpoint,
        directoryMapping: _directoryMapping,
      );
      await persistMeta();
    } catch (e) {
      Logger.error('cleanupObsoletePartitions failed', rawError: e);
    }
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
    // Start a single flush pump; the pump drains the queue before completing.
    _walFlushFuture = _pumpWalFlush();
  }

  /// Flush WAL write queue to files in batches.
  ///
  /// - Normal mode (drainCompletely=false, until=null): used for online WAL
  ///   persistence; drains the current queue without artificial tail delays.
  /// - Drain mode (drainCompletely=true): shutdown / strong full drain.
  /// - Prefix mode ([until] set): stop once [_appended] covers [until], leaving
  ///   newer queued entries for the background pump.
  Future<void> _pumpWalFlush({
    bool drainCompletely = false,
    WalPointer? until,
  }) async {
    if (!_config.enableJournal) return;
    if (_walQueue.isEmpty) return;
    // Another pump owns the queue: wait for it instead of no-op spinning.
    if (_walFlushInProgress) {
      final existing = _walFlushFuture;
      if (existing != null) {
        try {
          await existing;
        } catch (_) {}
      }
      return;
    }
    _walFlushInProgress = true;
    final run = Completer<void>();
    _walFlushFuture = run.future;
    var stopAfterWriteError = false;
    try {
      if (!_currentPartitionSizeLoaded) {
        await _ensureCurrentPartitionSizeLoaded();
      }

      final int batchSize = _config.logWriteBatchSize;
      final bool prefixMode = until != null;

      while (_walQueue.isNotEmpty) {
        if (prefixMode && !_isPointerNewerThan(until, _appended)) {
          break;
        }

        // Take up to batchSize entries from the head of the queue for this batch.
        // In prefix mode, stop taking once we have included [until].
        final int take =
            batchSize < _walQueue.length ? batchSize : _walQueue.length;
        if (take <= 0) break;

        // Keep full queue entries so a write failure can requeue intact.
        final Map<String, List<_QueuedWalEntry>> byPath = {};
        WalPointer lastAppended = _appended;
        var advancedAppended = false;
        int taken = 0;
        while (taken < take && _walQueue.isNotEmpty) {
          final _QueuedWalEntry e = _walQueue.removeFirst();
          final list = byPath.putIfAbsent(e.path, () => []);
          list.add(e);
          taken++;
          if (prefixMode && !_isPointerNewerThan(until, e.pointer)) {
            break;
          }
        }

        final yieldController = YieldController('WalManager._pumpWalFlush');
        while (byPath.isNotEmpty) {
          final y4 = yieldController.maybeYield();
          if (y4 != null) await y4;
          final String path = byPath.keys.first;
          final List<_QueuedWalEntry> queued = byPath.remove(path)!;
          if (queued.isEmpty) continue;

          final rawEntries = <Map<String, dynamic>>[
            for (final q in queued) q.rawEntry,
          ];
          final combined = FastWalEncoder.encodeBatch(rawEntries);

          bool wroteToCurrentPartition = false;
          try {
            await _dataStore.storage.appendBytes(path, combined, flush: false);

            final writeP =
                rawEntries.isNotEmpty ? rawEntries.first['p'] as int? : null;
            if (writeP != null) {
              _durableDirtyPartitions.add(writeP);
              if (writeP == _current.partitionIndex) {
                _currentPartitionSizeApprox += combined.length;
                wroteToCurrentPartition = true;
              }
            }
          } catch (e) {
            Logger.error('WAL append batch failed for path: $path',
                rawError: e);
            // Requeue failed group + any not-yet-written groups.
            for (int i = queued.length - 1; i >= 0; i--) {
              _walQueue.addFirst(queued[i]);
            }
            final remainingPaths = byPath.keys.toList(growable: false);
            for (int pi = remainingPaths.length - 1; pi >= 0; pi--) {
              final rem = byPath.remove(remainingPaths[pi])!;
              for (int i = rem.length - 1; i >= 0; i--) {
                _walQueue.addFirst(rem[i]);
              }
            }
            stopAfterWriteError = true;
            break;
          }

          lastAppended = queued.last.pointer;
          advancedAppended = true;

          await _maybeRotateAfterAppend(
            writtenBytes: combined.length,
            entryCount: rawEntries.length,
            wroteToCurrentPartition: wroteToCurrentPartition,
          );
        }

        if (advancedAppended) {
          _appended = lastAppended;
          try {
            StorageAdapter.notifyRecoveryWrite();
          } catch (_) {}
        }
        if (stopAfterWriteError) {
          break;
        }
      }
    } finally {
      _walFlushInProgress = false;
      if (!run.isCompleted) {
        run.complete();
      }
      if (identical(_walFlushFuture, run.future)) {
        _walFlushFuture = null;
      }
      // Cover the race where new entries arrived after the last emptiness
      // check but before [_walFlushInProgress] cleared. After a hard write
      // error, delay the retry so we do not spin, but still re-arm the pump
      // so orphaned queue entries are not left forever without a new writer.
      if (_walQueue.isNotEmpty) {
        if (stopAfterWriteError) {
          // ignore: discarded_futures
          Future<void>.delayed(const Duration(milliseconds: 100), () {
            scheduleFlushIfNeeded();
          });
        } else {
          scheduleFlushIfNeeded();
        }
      }
    }
  }

  /// Drain or discard the WAL write queue.
  ///
  /// - [flush] `true` (default): write all queued entries to disk.
  /// - [flush] `false`: await in-flight pump/rotate, then drop remaining
  ///   queued entries without writing (aligned with `close(flush: false)` /
  ///   journal `stop(flush: false)`). Callers already returned for async
  ///   durability; queued entries have no waiters.
  Future<void> flushQueueCompletely({bool flush = true}) async {
    if (!_config.enableJournal) return;
    // 1. Ensure any in-flight background rotation completes
    while (_rotateInProgress && _rotateFuture != null) {
      try {
        await _rotateFuture;
      } catch (_) {}
    }

    // 2. Ensure any currently in-flight flush pump completes before touching queue
    final inFlight = _walFlushFuture;
    if (inFlight != null) {
      try {
        await inFlight;
      } catch (_) {}
    }

    if (!flush) {
      // Drop not-yet-written entries. Re-await once: the completed pump's
      // finally may have synchronously rescheduled while the queue was still
      // non-empty; after that second await, clear again.
      _walQueue.clear();
      final again = _walFlushFuture;
      if (again != null) {
        try {
          await again;
        } catch (_) {}
      }
      _walQueue.clear();
      return;
    }

    // 3. Drain any remaining queued items to disk
    while (_walQueue.isNotEmpty) {
      final existing = _walFlushFuture;
      if (existing != null) {
        try {
          await existing;
        } catch (_) {}
      }
      if (_walQueue.isEmpty) break;
      await _pumpWalFlush(drainCompletely: true);
    }

    // 4. Ensure the last pump that may have drained the queue has completely finished
    final remaining = _walFlushFuture;
    if (remaining != null) {
      try {
        await remaining;
      } catch (_) {}
    }
  }

  /// Lightweight durability: write queued WAL entries through [target] into OS
  /// file buffers, without draining newer entries.
  ///
  /// Prefer this over [flushQueueCompletely] on commit / single-op return paths.
  /// When [flushToStorage] is true, also durable-sync dirty WAL partitions/meta
  /// (power-safer; more expensive).
  Future<void> ensureAppendedUpTo(
    WalPointer target, {
    bool flushToStorage = false,
  }) async {
    if (!_config.enableJournal) return;
    if (target.partitionIndex < 0) return;

    // Prefix-drain until [target] is in OS buffers. Loop covers races where an
    // online pump is in-flight or starts between awaits.
    while (_isPointerNewerThan(target, _appended)) {
      final existing = _walFlushFuture;
      if (existing != null) {
        try {
          await existing;
        } catch (_) {}
        continue;
      }
      if (_walQueue.isEmpty) break;
      // Do not overwrite [_walFlushFuture]; scheduleFlushIfNeeded owns it.
      await _pumpWalFlush(until: target);
    }

    if (flushToStorage) {
      await flushRecoveryArtifactsToStorage();
    }
    // Newer entries may remain; keep the background pump alive.
    if (_walQueue.isNotEmpty) {
      scheduleFlushIfNeeded();
    }
  }

  /// Flush existing WAL partition logs and main meta to stable storage.
  ///
  /// Intended for power-safe recovery durability after [flushQueueCompletely].
  /// Only flushes partitions/meta that received writes since the last durable
  /// sync (hot-path safe; skips already-durable files).
  Future<void> flushRecoveryArtifactsToStorage() async {
    if (!_config.enableJournal) return;
    if (_durableDirtyPartitions.isEmpty && !_walMetaDurableDirty) return;

    // Claim (= remove from dirty) before await: swap out the set so success
    // needs no post-flush remove, and concurrent appends re-mark on a fresh set.
    final dirtyPartitions = _durableDirtyPartitions;
    _durableDirtyPartitions = <int>{};
    final flushMeta = _walMetaDurableDirty;
    _walMetaDurableDirty = false;

    final space = _dataStore.currentSpaceName;
    final paths = <String>[];
    for (final p in dirtyPartitions) {
      if (p < 0) continue;
      final dirIndex =
          getPartitionDirIndex(p) ?? p ~/ _dataStore.maxEntriesPerDir;
      paths.add(_dataStore.pathManager.getWalPartitionLogPath(
        dirIndex,
        p,
        spaceName: space,
      ));
    }
    if (flushMeta) {
      paths.add(_dataStore.pathManager.getWalMainMetaPath(spaceName: space));
    }
    if (paths.isEmpty) return;

    try {
      await _dataStore.storage.flushAll(paths: paths, closeHandles: false);
    } catch (_) {
      _durableDirtyPartitions.addAll(dirtyPartitions);
      if (flushMeta) _walMetaDurableDirty = true;
    }
  }

  void _clearDurableDirtyState() {
    _durableDirtyPartitions.clear();
    _walMetaDurableDirty = false;
  }

  void _markPartitionDurable(int partitionIndex) {
    _durableDirtyPartitions.remove(partitionIndex);
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
    int size = 0;
    if (_currentPartitionSizeLoaded &&
        _current.partitionIndex == ptr.partitionIndex) {
      size = _currentPartitionSizeApprox;
    } else {
      final path = _dataStore.pathManager.getWalPartitionLogPath(
        dirIndex,
        ptr.partitionIndex,
        spaceName: _dataStore.currentSpaceName,
      );
      try {
        if (await _dataStore.storage.existsFile(path)) {
          size = await _dataStore.storage.getFileSize(path);
        }
      } catch (_) {}
    }
    if (_meta.lastRecoveredPointer == ptr &&
        _meta.lastRecoveredTailFileSize == size &&
        !_walMetaDurableDirty) {
      return;
    }
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
      final encoderConfig = EncryptionManager.getCurrentEncodingState();
      final allEntries = await WalDecodeBatchRunner.decodeFile(
        fileBytes: fullData,
        partitionIndex: pIdx,
        encoderConfig: encoderConfig,
      );
      return WalPointer(partitionIndex: pIdx, entrySeq: allEntries.length);
    } catch (e) {
      Logger.warn('readLastWalPointer failed', rawError: e);
      return WalPointer(partitionIndex: pIdx, entrySeq: 0);
    }
  }

  /// Synchronously switches active WAL partition in memory (0 await overhead),
  /// cleans target partition file synchronously, and schedules background
  /// persistence of metadata and old handle closure.
  void _rotatePartitionSync(int pIdx, String oldPath) {
    final next = (pIdx + 1) % _config.logPartitionCycle;
    final nextDirIndex = _getOrAllocateDirIndexForPartition(next);
    final newPath = _dataStore.pathManager.getWalPartitionLogPath(
      nextDirIndex,
      next,
      spaceName: _dataStore.currentSpaceName,
    );

    // 1. Synchronously clean newPath if it exists (e.g. from previous cycle or aborted run).
    // Closes any sync handle and removes physical file synchronously without microtask yield.
    try {
      _dataStore.storage.deleteFileSync(newPath);
    } catch (e) {
      Logger.warn('Failed to deleteFileSync new partition: $newPath',
          rawError: e);
    }

    // 2. Synchronously advance in-memory pointer and reset partition size IMMEDIATELY!
    _current = WalPointer(partitionIndex: next, entrySeq: 0);
    _currentPartitionSizeApprox = 0;
    _currentPartitionSizeLoaded = true;
    _cachedWalPartitionIndex = -1;
    _cachedWalPartitionPath = null;

    // 3. Synchronously advance meta existing partition range in memory
    if (_meta.existingStartPartitionIndex == -1) {
      _meta.existingStartPartitionIndex = pIdx;
      _meta.existingEndPartitionIndex = next;
    } else {
      final oldStart = _meta.existingStartPartitionIndex;
      _meta.existingEndPartitionIndex = next;
      if (next == oldStart) {
        _meta.existingStartPartitionIndex =
            (oldStart + 1) % _config.logPartitionCycle;
      }
    }

    // 4. Schedule background task to flush old handle and persist metadata durably
    _scheduleBackgroundRotationIo(oldPIdx: pIdx, oldPath: oldPath);
  }

  /// Chains background I/O tasks for WAL partition rotation.
  void _scheduleBackgroundRotationIo({
    required int oldPIdx,
    required String oldPath,
  }) {
    final prev = _rotateFuture;
    _rotateInProgress = true;
    late final Future<void> currentFuture;
    currentFuture = () async {
      try {
        if (prev != null) {
          try {
            await prev;
          } catch (_) {}
        }
        await persistMeta(flush: true);
        try {
          await _dataStore.storage.flushAll(path: oldPath, closeHandles: true);
          _markPartitionDurable(oldPIdx);
        } catch (_) {}
      } finally {
        if (identical(_rotateFuture, currentFuture)) {
          _rotateInProgress = false;
          _rotateFuture = null;
        }
      }
    }();
    _rotateFuture = currentFuture;
  }

  /// Called when the active partition meets [DataStoreConfig.maxLogPartitionFileSize]
  /// (hard threshold) or when predictive backlog would exceed it.
  Future<void> _rotatePartition() async {
    final pIdx = _current.partitionIndex;
    final dirIndex = _getOrAllocateDirIndexForPartition(pIdx);
    final path = _dataStore.pathManager.getWalPartitionLogPath(
      dirIndex,
      pIdx,
      spaceName: _dataStore.currentSpaceName,
    );
    _rotatePartitionSync(pIdx, path);
    final fut = _rotateFuture;
    if (fut != null) {
      try {
        await fut;
      } catch (_) {}
    }
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
            Logger.warn(
                'persistMeta wait timeout after 30s, proceeding anyway');
          },
        );
      } catch (e) {
        Logger.warn('persistMeta wait error', rawError: e);
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
            Logger.error('Backup WAL meta failed', rawError: e);
          }
        }

        final bytes = WalMetaCodec.encodeFile(
          _meta,
          encryptionConfig: _dataStore.config.encryptionConfig,
        );
        await _dataStore.storage.writeAsBytes(metaPath, bytes, flush: flush);
        // Durable flag tracks whether meta still needs a storage-level flush.
        _walMetaDurableDirty = !flush;
      } catch (e) {
        // Log the full error with stack trace for debugging
        Logger.error('Failed to persist WAL meta', rawError: e);
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

  /// Register a table-level maintenance operation (clear/drop) into WAL meta.
  ///
  /// The caller is responsible for generating a unique [opId].
  Future<void> registerTableOp(TableOpMeta op) async {
    if (!_config.enableJournal) return;
    if (!_initialized) {
      await initializeAndRecover();
    }
    // At most keep one active maintenance op per table. Newer ops (with a
    // later cutoff) completely subsume older ones for the same table, so
    // we safely drop previous entries to keep WAL meta compact and avoid
    // repeated replays on restart.
    _meta.tableOps
        .removeWhere((_, existing) => existing.tableUid == op.tableUid);
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
    if (!_config.enableJournal) return;
    final op = _meta.tableOps[opId];
    if (op == null) return;
    _meta.tableOps[opId] = op.copyWith(completed: true);
    await persistMeta(flush: false);
  }

  /// Remove a pending table-level maintenance op that never took effect.
  ///
  /// Used when clear/drop is rejected before destructive work (e.g. FK
  /// RESTRICT). Must remove rather than [completeTableOp]: completed ops still
  /// contribute cutoffs that would incorrectly skip valid WAL entries.
  Future<void> abortTableOp(String opId) async {
    if (!_config.enableJournal) return;
    if (!_meta.tableOps.containsKey(opId)) return;
    _meta.tableOps.remove(opId);
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
