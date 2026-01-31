import 'dart:collection';
import 'dart:async';
import 'crontab_manager.dart';

import '../handler/logger.dart';
import '../model/buffer_entry.dart';
import '../model/wal_pointer.dart';
import '../model/unique_violation.dart';
import 'yield_controller.dart';
import 'data_store_impl.dart';

class WriteQueueEntry {
  final String tableName;
  final String recordId;
  final BufferOperationType operationType;
  final WalPointer walPointer;

  const WriteQueueEntry({
    required this.tableName,
    required this.recordId,
    required this.operationType,
    required this.walPointer,
  });
}

class UniquePlan {
  final List<UniqueKeyRef> refs;
  const UniquePlan(this.refs);
}

class UniqueKeyRef {
  final String indexName;
  final dynamic compositeKey; // raw native value or List<dynamic> for composite
  late final dynamic internalKey;

  UniqueKeyRef(this.indexName, this.compositeKey) {
    internalKey = _toInternalKey(compositeKey);
  }

  Map<String, dynamic> toJson() => {
        'indexName': indexName,
        'compositeKey': compositeKey,
      };

  factory UniqueKeyRef.fromJson(Map<String, dynamic> json) {
    return UniqueKeyRef(
      json['indexName'] as String,
      json['compositeKey'],
    );
  }
}

/// Context for batch operations to avoid repetitive Map lookups
class BatchCheckContext {
  final String tableName;
  final String? transactionId;
  final WriteDataBuffer? mainBuf;
  // ignore: library_private_types_in_public_api
  final _TxnUniqueTableBuffer? txnBuf;
  final Map<String, Map<dynamic, Map<String, Set<String>>>>? globalIndices;

  BatchCheckContext(
      this.tableName,
      this.transactionId,
      this.mainBuf,
      // ignore: library_private_types_in_public_api
      this.txnBuf,
      this.globalIndices);

  List<UniqueKeyRef>? tryReserve(
      String recordId, List<UniqueKeyRef> uniqueKeys) {
    // 1. Check ALL keys first
    for (final uk in uniqueKeys) {
      if (_hasUniqueKeyOwnedByOther(uk, recordId)) {
        throw UniqueViolation(
          tableName: tableName,
          fields: [],
          value: uk.compositeKey,
          indexName: uk.indexName,
        );
      }
    }

    // 2. Add keys
    // Optimized add pathway using cached buffers
    if (transactionId != null) {
      final buf = txnBuf!; // Must exist if transactionId not null
      final oldKeys = buf.recordIdToUniqueKeys[recordId];

      if (uniqueKeys.isEmpty) return oldKeys;

      // Remove existing keys (copied from _removeTransactionUniqueKeysForRecord but optimized)
      final existingKeys = buf.recordIdToUniqueKeys.remove(recordId);
      if (existingKeys != null) {
        for (final uk in existingKeys) {
          final iKey = uk.internalKey;
          buf.uniqueKeyOwners[uk.indexName]?[iKey]?.remove(recordId);
          // Global cleanup
          _removeFromGlobalIndex(uk.indexName, iKey, recordId);
        }
      }

      buf.recordIdToUniqueKeys[recordId] = uniqueKeys;

      // Add new
      for (final uk in uniqueKeys) {
        final iKey = uk.internalKey;
        // Local
        var ownersByKey = buf.uniqueKeyOwners[uk.indexName];
        if (ownersByKey == null) {
          ownersByKey = <dynamic, Set<String>>{};
          buf.uniqueKeyOwners[uk.indexName] = ownersByKey;
        }
        var owners = ownersByKey[iKey];
        if (owners == null) {
          owners = <String>{};
          ownersByKey[iKey] = owners;
        }
        owners.add(recordId);

        // Global
        var globalKeys = globalIndices?[uk.indexName];
        if (globalKeys == null) {
          globalKeys = {};
          // Should verify if globalIndices is not null, but it comes from context
          if (globalIndices != null) globalIndices![uk.indexName] = globalKeys;
        }
        var globalOwners = globalKeys[iKey];
        if (globalOwners == null) {
          globalOwners = {};
          globalKeys[iKey] = globalOwners;
        }
        var txOwners = globalOwners[transactionId];
        if (txOwners == null) {
          txOwners = {};
          globalOwners[transactionId!] = txOwners;
        }
        txOwners.add(recordId);
      }
      return oldKeys;
    } else {
      final buf = mainBuf!;
      final oldKeys = buf.recordIdToUniqueKeys[recordId];

      if (oldKeys != null) {
        buf.recordIdToUniqueKeys.remove(recordId);
        for (final uk in oldKeys) {
          buf.uniqueKeyOwners[uk.indexName]?[uk.internalKey]?.remove(recordId);
        }
      }

      buf.recordIdToUniqueKeys[recordId] = uniqueKeys;
      for (final uk in uniqueKeys) {
        final iKey = uk.internalKey;
        var set = buf.uniqueIndexEntries[uk.indexName];
        if (set == null) {
          set = <dynamic>{};
          buf.uniqueIndexEntries[uk.indexName] = set;
        }
        set.add(iKey);

        var ownersByKey = buf.uniqueKeyOwners[uk.indexName];
        if (ownersByKey == null) {
          ownersByKey = <dynamic, Set<String>>{};
          buf.uniqueKeyOwners[uk.indexName] = ownersByKey;
        }
        var owners = ownersByKey[iKey];
        if (owners == null) {
          owners = <String>{};
          ownersByKey[iKey] = owners;
        }
        owners.add(recordId);
      }
      return oldKeys;
    }
  }

  bool _hasUniqueKeyOwnedByOther(UniqueKeyRef uk, String? selfRecordId) {
    // 1. Check main buffer
    if (mainBuf != null) {
      final owners = mainBuf!.uniqueKeyOwners[uk.indexName]?[uk.internalKey];
      if (owners != null && owners.isNotEmpty) {
        if (selfRecordId == null) return true;
        if (owners.length > 1) return true;
        if (!owners.contains(selfRecordId)) return true;
      }
    }
    // 2. Check global txn
    if (globalIndices != null) {
      final globalOwners = globalIndices![uk.indexName]?[uk.internalKey];
      if (globalOwners != null && globalOwners.isNotEmpty) {
        for (final entry in globalOwners.entries) {
          final txId = entry.key;
          final recordIds = entry.value;
          if (recordIds.isEmpty) continue;

          if (transactionId != null && txId == transactionId) {
            if (selfRecordId == null) return true;
            if (recordIds.length > 1) return true;
            if (!recordIds.contains(selfRecordId)) return true;
          } else {
            return true;
          }
        }
      }
    }
    return false;
  }

  // Duplicated helper for context to avoid refactoring entire class to static
  void _removeFromGlobalIndex(
      String indexName, dynamic internalKey, String recordId) {
    if (globalIndices == null) return;
    final globalKeys = globalIndices![indexName];
    if (globalKeys == null) return;
    final globalOwners = globalKeys[internalKey];
    if (globalOwners == null) return;

    final txOwners = globalOwners[transactionId];
    if (txOwners != null) {
      txOwners.remove(recordId);
      if (txOwners.isEmpty) {
        globalOwners.remove(transactionId);
      }
    }
    if (globalOwners.isEmpty) {
      globalKeys.remove(internalKey);
      if (globalKeys.isEmpty) {
        globalIndices!.remove(indexName);
      }
    }
  }
}

class InsertionSequence {
  int _minSeq = 1;
  int _maxSeq = 0;
  final Map<int, String> _bySeq = {};
  final Map<String, int> _byKey = {};

  bool get isEmpty => _bySeq.isEmpty;
  String? get last {
    if (isEmpty) return null;
    // Scan backward to find valid entry (in case tail was removed)
    for (int i = _maxSeq; i >= _minSeq; i--) {
      if (_bySeq.containsKey(i)) return _bySeq[i];
    }
    return null;
  }

  void add(String key) {
    if (_byKey.containsKey(key)) return; // Already exists, keep original order
    _maxSeq++;
    _bySeq[_maxSeq] = key;
    _byKey[key] = _maxSeq;
  }

  void remove(String key) {
    final seq = _byKey.remove(key);
    if (seq != null) {
      _bySeq.remove(seq);
      // If we removed head, advance minSeq (optimization)
      if (seq == _minSeq) {
        while (_minSeq <= _maxSeq && !_bySeq.containsKey(_minSeq)) {
          _minSeq++;
        }
      }
    }
  }

  void clear() {
    _bySeq.clear();
    _byKey.clear();
    _minSeq = 1;
    _maxSeq = 0;
  }

  /// Safe iterable that handles concurrent modifications by snapshotting the range
  /// but looking up values dynamically.
  /// If [reverse] is true, iterates from max to min.
  Iterable<String> iterable({bool reverse = false}) sync* {
    // Snapshot bounds to avoid infinite loops if appending happens during iteration
    final start = _minSeq;
    final end = _maxSeq;

    if (reverse) {
      for (int i = end; i >= start; i--) {
        final k = _bySeq[i];
        if (k != null) yield k;
      }
    } else {
      for (int i = start; i <= end; i++) {
        final k = _bySeq[i];
        if (k != null) yield k;
      }
    }
  }
}

class WriteDataBuffer {
  // recordId -> BufferEntry
  final Map<String, BufferEntry> records = <String, BufferEntry>{};
  // indexName -> Set<internalKey>
  final Map<String, Set<dynamic>> uniqueIndexEntries = <String, Set<dynamic>>{};
  // recordId -> List<UniqueKeyRef>
  final Map<String, List<UniqueKeyRef>> recordIdToUniqueKeys =
      <String, List<UniqueKeyRef>>{};
  // indexName -> internalKey -> Set<recordId> (owners)
  final Map<String, Map<dynamic, Set<String>>> uniqueKeyOwners =
      <String, Map<dynamic, Set<String>>>{};

  // Insertion Index for O(1) Max ID and Safe Iteration
  final InsertionSequence insertedKeys = InsertionSequence();
}

class _PendingCleanup {
  final WriteQueueEntry entry;
  final WalPointer flushMarker;

  _PendingCleanup(this.entry, this.flushMarker);
}

/// Manages in-memory write buffers and the ordered write queue derived from WAL pointers
class WriteBufferManager {
  final DataStoreImpl _dataStore;

  final Map<String, WriteDataBuffer> _buffersByTable =
      <String, WriteDataBuffer>{};
  final Map<String, int> _tableClearEpochs = <String, int>{};
  int _globalClearEpoch = 0;
  final Queue<WriteQueueEntry> _writeQueue = Queue<WriteQueueEntry>();
  final StreamController<int> _sizeController =
      StreamController<int>.broadcast();

  /// Delayed cleanup queue: keep data in [_buffersByTable] main buffer, only this queue records cleanup tasks.
  /// Cleanup condition: all active read views' snapshots must be newer than [flushMarker] (i.e., the system pointer at the time of Flush completion).
  final Queue<_PendingCleanup> _pendingCleanupQueue = Queue<_PendingCleanup>();

  WriteBufferManager(this._dataStore);

  bool get isEmpty => _writeQueue.isEmpty;
  int get queueLength => _writeQueue.length;

  /// Get the length of the pending cleanup queue (for monitoring)
  int get pendingCleanupCount => _pendingCleanupQueue.length;

  Stream<int> get sizeStream => _sizeController.stream;

  void _emitSizeChanged() {
    try {
      _sizeController.add(_writeQueue.length);
    } catch (_) {}
  }

  WriteDataBuffer _ensureTable(String tableName) {
    return _buffersByTable.putIfAbsent(tableName, () => WriteDataBuffer());
  }

  /// Get the current clear epoch for a table.
  /// Incremented every time clearTable or clearAll is called.
  int getClearEpoch(String tableName) {
    return (_tableClearEpochs[tableName] ?? 0) + _globalClearEpoch;
  }

  /// Remove a specific record from buffer and queue (best effort)
  void removeRecord(String tableName, String recordId) {
    // 1) Cleanup table buffers
    final buf = _buffersByTable[tableName];
    if (buf != null) {
      buf.records.remove(recordId);
      buf.insertedKeys.remove(recordId);
      final keys = buf.recordIdToUniqueKeys.remove(recordId);
      if (keys != null) {
        for (final uk in keys) {
          final internalKey = _toInternalKey(uk.compositeKey);
          final set = buf.uniqueIndexEntries[uk.indexName];
          set?.remove(internalKey);
          if (set != null && set.isEmpty) {
            buf.uniqueIndexEntries.remove(uk.indexName);
          }
          final ownersByKey = buf.uniqueKeyOwners[uk.indexName];
          final owners = ownersByKey?[internalKey];
          owners?.remove(recordId);
          if (owners != null && owners.isEmpty) {
            ownersByKey?.remove(internalKey);
          }
          if (ownersByKey != null && ownersByKey.isEmpty) {
            buf.uniqueKeyOwners.remove(uk.indexName);
          }
        }
      }
      if (buf.records.isEmpty &&
          buf.uniqueIndexEntries.isEmpty &&
          buf.recordIdToUniqueKeys.isEmpty) {
        _buffersByTable.remove(tableName);
      }
    }

    // 2) Rebuild queue without affected entries (iterator cannot remove in-place)
    if (_writeQueue.isNotEmpty) {
      _writeQueue.removeWhere(
          (e) => e.tableName == tableName && e.recordId == recordId);
      _emitSizeChanged();
    }
  }

  /// Add record into buffer and enqueue for flush (ordered by WAL pointer)
  Future<void> addRecord({
    required String tableName,
    required String recordId,
    required BufferEntry entry,
    List<UniqueKeyRef> uniqueKeys = const <UniqueKeyRef>[],
    bool updateStats = true,
  }) async {
    final buf = _ensureTable(tableName);
    final BufferEntry? prior = buf.records[recordId];
    bool skipBufferStore = false;
    bool skipQueueEnqueue =
        false; // Flag to skip adding to queue when merging INSERT+UPDATE
    BufferEntry effectiveEntry = entry;
    if (prior != null && prior.operation == BufferOperationType.insert) {
      if (entry.operation == BufferOperationType.update) {
        // Merge: keep as INSERT with latest data
        // The buffer data is updated, but we should NOT add this UPDATE to the queue
        // because the INSERT entry is already in the queue and will be flushed with the updated data.
        effectiveEntry = BufferEntry(
          data: entry.data,
          operation: BufferOperationType.insert,
          timestamp: entry.timestamp,
          walPointer: effectiveEntry.walPointer,
          transactionId: prior.transactionId ?? entry.transactionId,
          oldValues: null,
        );
        skipQueueEnqueue =
            true; // Skip queue enqueue - INSERT entry already exists
      } else if (entry.operation == BufferOperationType.delete) {
        // Cancel: drop the pending INSERT from buffer (no buffered record kept)
        // Remove the existing buffered INSERT so subsequent reads won't see it.
        // Cancel: drop the pending INSERT from buffer (no buffered record kept)
        // Remove the existing buffered INSERT so subsequent reads won't see it.
        buf.records.remove(recordId);
        buf.insertedKeys.remove(recordId);
        skipBufferStore = true;
      }
    }

    // Update unique structures
    // Only touch unique key structures when:
    // - this is a delete (we must drop existing reservations), or
    // - caller explicitly provides new uniqueKeys (to refresh reservations).
    if (effectiveEntry.operation == BufferOperationType.delete ||
        uniqueKeys.isNotEmpty) {
      final existing = buf.recordIdToUniqueKeys.remove(recordId);
      if (existing != null) {
        for (final uk in existing) {
          final internalKey = _toInternalKey(uk.compositeKey);
          final set = buf.uniqueIndexEntries[uk.indexName];
          set?.remove(internalKey);
          if (set != null && set.isEmpty) {
            buf.uniqueIndexEntries.remove(uk.indexName);
          }
          final ownersByKey = buf.uniqueKeyOwners[uk.indexName];
          final owners = ownersByKey?[internalKey];
          owners?.remove(recordId);
          if (owners != null && owners.isEmpty) {
            ownersByKey?.remove(internalKey);
          }
          if (ownersByKey != null && ownersByKey.isEmpty) {
            buf.uniqueKeyOwners.remove(uk.indexName);
          }
        }
      }
    }

    // Store (unless canceled by coalescing)
    if (!skipBufferStore) {
      buf.records[recordId] = effectiveEntry;

      // Update Insert Index
      // Update Insert Index
      if (effectiveEntry.operation == BufferOperationType.insert) {
        buf.insertedKeys.add(recordId);
      }

      if (uniqueKeys.isNotEmpty &&
          effectiveEntry.operation != BufferOperationType.delete) {
        buf.recordIdToUniqueKeys[recordId] = uniqueKeys;
        for (final uk in uniqueKeys) {
          final internalKey = _toInternalKey(uk.compositeKey);
          var set = buf.uniqueIndexEntries[uk.indexName];
          if (set == null) {
            set = <dynamic>{};
            buf.uniqueIndexEntries[uk.indexName] = set;
          }
          set.add(internalKey);

          var ownersByKey = buf.uniqueKeyOwners[uk.indexName];
          if (ownersByKey == null) {
            ownersByKey = <dynamic, Set<String>>{};
            buf.uniqueKeyOwners[uk.indexName] = ownersByKey;
          }
          var owners = ownersByKey[internalKey];
          if (owners == null) {
            owners = <String>{};
            ownersByKey[internalKey] = owners;
          }
          owners.add(recordId);
        }
      }
    }

    // Enqueue to write queue only if not skipped (e.g., when INSERT+UPDATE merged).
    // When INSERT+UPDATE are merged, we update the buffer data but skip adding the UPDATE
    // to the queue because the INSERT entry is already there and will be flushed with
    // the updated data. This preserves primary key ordering and prevents duplicate processing.
    if (!skipQueueEnqueue) {
      // Update record count statistics (awaited to ensure consistency)
      if (updateStats) {
        await _dataStore.tableDataManager
            .updateTableRecordCount(tableName, effectiveEntry.operation);
      }
      _writeQueue.add(WriteQueueEntry(
        tableName: tableName,
        recordId: recordId,
        operationType: effectiveEntry.operation,
        walPointer: effectiveEntry.walPointer!,
      ));
      _emitSizeChanged();
    }
    // Treat data operation as activity to keep scheduler alive
    CrontabManager.notifyActivity();
  }

  /// High-performance batch insert into buffer + ordered write queue.
  ///
  /// This avoids per-record awaits and stream notifications, which is critical for
  /// large batch insert workloads (10k+ rows).
  ///
  /// Notes:
  /// - All [entries] must be INSERT operations with non-null WAL pointers.
  /// - Caller must ensure primary key uniqueness and unique-key reservations are done before calling.
  Future<void> addInsertBatch({
    required String tableName,
    required List<String> recordIds,
    required List<BufferEntry> entries,
    required List<List<UniqueKeyRef>> uniqueKeysList,
  }) async {
    if (recordIds.isEmpty) return;
    if (recordIds.length != entries.length ||
        recordIds.length != uniqueKeysList.length) {
      throw ArgumentError(
          'addInsertBatch length mismatch: recordIds=${recordIds.length}, entries=${entries.length}, uniqueKeysList=${uniqueKeysList.length}');
    }

    // Update record count once (batch optimized).
    await _dataStore.tableDataManager.updateTableRecordCountDelta(
      tableName,
      insertDelta: recordIds.length,
    );

    final buf = _ensureTable(tableName);
    final yieldController =
        YieldController('WriteBufferManager.addInsertBatch');

    for (int i = 0; i < recordIds.length; i++) {
      await yieldController.maybeYield();
      final recordId = recordIds[i];
      final entry = entries[i];
      final uniqueKeys = uniqueKeysList[i];

      // Store entry (INSERT). If a prior entry exists, remove its unique keys to prevent leaks.
      final existingKeys = buf.recordIdToUniqueKeys.remove(recordId);
      if (existingKeys != null) {
        for (final uk in existingKeys) {
          final internalKey = uk.internalKey;
          final set = buf.uniqueIndexEntries[uk.indexName];
          set?.remove(internalKey);
          if (set != null && set.isEmpty) {
            buf.uniqueIndexEntries.remove(uk.indexName);
          }
          final ownersByKey = buf.uniqueKeyOwners[uk.indexName];
          final owners = ownersByKey?[internalKey];
          owners?.remove(recordId);
          if (owners != null && owners.isEmpty) {
            ownersByKey?.remove(internalKey);
          }
          if (ownersByKey != null && ownersByKey.isEmpty) {
            buf.uniqueKeyOwners.remove(uk.indexName);
          }
        }
      }

      buf.records[recordId] = entry;
      buf.insertedKeys.add(recordId);

      if (uniqueKeys.isNotEmpty) {
        buf.recordIdToUniqueKeys[recordId] = uniqueKeys;
        for (final uk in uniqueKeys) {
          final internalKey = uk.internalKey;

          var set = buf.uniqueIndexEntries[uk.indexName];
          if (set == null) {
            set = <dynamic>{};
            buf.uniqueIndexEntries[uk.indexName] = set;
          }
          set.add(internalKey);

          var ownersByKey = buf.uniqueKeyOwners[uk.indexName];
          if (ownersByKey == null) {
            ownersByKey = <dynamic, Set<String>>{};
            buf.uniqueKeyOwners[uk.indexName] = ownersByKey;
          }
          var owners = ownersByKey[internalKey];
          if (owners == null) {
            owners = <String>{};
            ownersByKey[internalKey] = owners;
          }
          owners.add(recordId);
        }
      }

      final wp = entry.walPointer;
      if (wp == null) {
        // Should never happen for modern batch paths; skip enqueue to preserve queue integrity.
        Logger.warn(
          'Batch insert missing walPointer: table=$tableName pk=$recordId, skipping enqueue',
          label: 'WriteBufferManager.addInsertBatch',
        );
        continue;
      }
      _writeQueue.add(WriteQueueEntry(
        tableName: tableName,
        recordId: recordId,
        operationType: BufferOperationType.insert,
        walPointer: wp,
      ));
    }

    _emitSizeChanged();
    CrontabManager.notifyActivity();
  }

  /// Get a batch from the write queue without removing them (peek)
  List<WriteQueueEntry> peekBatch(int size) {
    if (_writeQueue.isEmpty) return const <WriteQueueEntry>[];
    final result = <WriteQueueEntry>[];
    var it = _writeQueue.iterator;
    while (it.moveNext() && result.length < size) {
      result.add(it.current);
    }
    return result;
  }

  /// Pop a batch from the write queue
  List<WriteQueueEntry> popBatch(int size) {
    if (_writeQueue.isEmpty) return const <WriteQueueEntry>[];
    final result = <WriteQueueEntry>[];
    for (int i = 0; i < size && _writeQueue.isNotEmpty; i++) {
      result.add(_writeQueue.removeFirst());
    }
    if (result.isNotEmpty) _emitSizeChanged();
    return result;
  }

  /// Requeue a previously popped batch back to the **front** of the queue.
  ///
  /// This is used to ensure durability when a flush batch fails mid-flight:
  /// we must not drop the queue items, otherwise they will never be flushed and
  /// can cause data loss / memory growth.
  void requeueFront(List<WriteQueueEntry> batch) {
    if (batch.isEmpty) return;
    // Preserve original order: the oldest item should remain at the head.
    for (int i = batch.length - 1; i >= 0; i--) {
      _writeQueue.addFirst(batch[i]);
    }
    _emitSizeChanged();
  }

  /// Cleanup queue (and buffer state) for entries already persisted to table files.
  ///
  /// Removes queue items from the head while their WAL pointer is **at or before**
  /// [checkpointInclusive] (cycle-aware). This is primarily used after recovering
  /// a pending parallel journal batch so in-memory buffers don't keep replaying
  /// already-flushed WAL operations.
  Future<void> cleanupCommittedUpTo(
    WalPointer checkpointInclusive,
    int walCycle,
  ) async {
    if (_writeQueue.isEmpty) return;
    bool changed = false;
    final yieldControl =
        YieldController('WriteBufferManager.cleanupCommittedUpTo');

    bool isAtOrBefore(WalPointer p, WalPointer cutoff) {
      // `isNewerThan` is a circular-order heuristic used across the WAL system.
      return !p.isNewerThan(cutoff, walCycle);
    }

    while (_writeQueue.isNotEmpty) {
      await yieldControl.maybeYield();
      final head = _writeQueue.first;
      // Treat pseudo pointers as immediately removable.
      if (head.walPointer.partitionIndex < 0) {
        final removed = _writeQueue.removeFirst();
        _cleanupSingle(removed);
        changed = true;
        continue;
      }
      if (!isAtOrBefore(head.walPointer, checkpointInclusive)) {
        break;
      }
      final removed = _writeQueue.removeFirst();
      _cleanupSingle(removed);
      changed = true;
    }
    if (changed) _emitSizeChanged();
  }

  void _cleanupSingle(WriteQueueEntry e) {
    final buf = _buffersByTable[e.tableName];
    if (buf == null) return;

    // Strict check: only remove if the buffer entry matches the flushed WAL pointer.
    // If pointers differ, it means a new update came in during flush; deleting it would cause data loss.
    final currentEntry = buf.records[e.recordId];
    if (currentEntry == null) return;

    bool shouldRemove = false;
    if (currentEntry.walPointer != null) {
      final p1 = currentEntry.walPointer!;
      final p2 = e.walPointer;
      // Compare partition index and entry sequence for equality
      if (p1.partitionIndex == p2.partitionIndex &&
          p1.entrySeq == p2.entrySeq) {
        shouldRemove = true;
      }
    } else {
      // Logic for legacy/migration or if walPointer missing:
      // If we can't verify version, it's safer NOT to remove to prevent data loss.
      // However, we must ensure we don't leak.
      // Given we enforce walPointer now, this case should only be temporary/edge.
      // We choose safety: do not remove if we can't verify.
      shouldRemove = false;
    }
    if (shouldRemove) {
      _removeUnconditionally(e.tableName, e.recordId);
    }
  }

  void _removeUnconditionally(String tableName, String recordId) {
    final buf = _buffersByTable[tableName];
    if (buf == null) return;

    buf.records.remove(recordId);
    buf.insertedKeys.remove(recordId);
    final keys = buf.recordIdToUniqueKeys.remove(recordId);
    if (keys != null) {
      for (final uk in keys) {
        final internalKey = _toInternalKey(uk.compositeKey);
        final set = buf.uniqueIndexEntries[uk.indexName];
        set?.remove(internalKey);
        if (set != null && set.isEmpty) {
          buf.uniqueIndexEntries.remove(uk.indexName);
        }
        final ownersByKey = buf.uniqueKeyOwners[uk.indexName];
        final owners = ownersByKey?[internalKey];
        owners?.remove(recordId);
        if (owners != null && owners.isEmpty) {
          ownersByKey?.remove(internalKey);
        }
        if (ownersByKey != null && ownersByKey.isEmpty) {
          buf.uniqueKeyOwners.remove(uk.indexName);
        }
      }
    }
    if (buf.records.isEmpty &&
        buf.uniqueIndexEntries.isEmpty &&
        buf.recordIdToUniqueKeys.isEmpty) {
      _buffersByTable.remove(tableName);
    }
  }

  /// Remove already processed items for current batch based on counts by table/op
  void removeProcessedForCurrentBatch(
      Map<String, Map<BufferOperationType, int>> processedCounts) {
    if (processedCounts.isEmpty || _writeQueue.isEmpty) return;
    _writeQueue.removeWhere((e) {
      final byOp = processedCounts[e.tableName];
      if (byOp == null) return false;
      final remaining = byOp[e.operationType] ?? 0;
      if (remaining > 0) {
        byOp[e.operationType] = remaining - 1;
        _cleanupSingle(e);
        return true;
      }
      return false;
    });
    _emitSizeChanged();
  }

  /// Cleanup buffer state for the given batch after successful flush
  Future<void> cleanupAfterBatch(List<WriteQueueEntry> batch) async {
    final yieldControl =
        YieldController('WriteBufferManager.cleanupAfterBatch');

    final hasActiveViews = _dataStore.readViewManager.hasActiveViews;

    // Only if there are active read views, we need to delay cleaning these data.
    // Use the current WAL pointer as the "Flush completed marker".
    // Only when all read views are later than this marker can these data be safely cleaned.
    WalPointer? flushMarker;
    if (hasActiveViews) {
      flushMarker = _dataStore.walManager.currentPointer;
    }

    for (final e in batch) {
      await yieldControl.maybeYield();
      if (hasActiveViews && flushMarker != null) {
        _pendingCleanupQueue.add(_PendingCleanup(e, flushMarker));
      } else {
        _cleanupSingle(e);
      }
    }
    if (batch.isNotEmpty) _emitSizeChanged();
  }

  /// Try to clean up pending cleanups in the delay queue
  ///
  /// Call timing: after view release or periodic call.
  bool _isPurging = false;

  /// Try to clean up pending cleanups in the delay queue
  ///
  /// Call timing: after view release or periodic call.
  /// [OPTIMIZATION] Added re-entry lock to avoid redundant concurrent executions.
  Future<void> purgePendingCleanups() async {
    if (_isPurging) return;
    if (_pendingCleanupQueue.isEmpty) return;

    _isPurging = true;
    try {
      final int walCycle = _dataStore.config.logPartitionCycle;

      // We need to wait for the snapshot.
      // Note: getOldestActiveSnapshot might trigger _cleanupExpiredHead internally.
      final WalPointer? oldestSnapshot =
          _dataStore.readViewManager.getOldestActiveSnapshot();

      // If there are no active read views, purge all
      if (oldestSnapshot == null) {
        final yieldControl =
            YieldController('WriteBufferManager.purgeAllPending');
        while (_pendingCleanupQueue.isNotEmpty) {
          await yieldControl.maybeYield();
          _cleanupSingle(_pendingCleanupQueue.removeFirst().entry);
        }
        return;
      }

      // Otherwise, only clean up those tasks where flushMarker is older than oldestSnapshot
      // (i.e., Flush occurred before the oldest read view was created -> the read view must see the flushed data)
      // Note: isNewerThan is circular comparison.
      // If oldestSnapshot.isNewerThan(head.flushMarker) is true, it means the Snapshot is newer (newer) than the Flush.
      // This means that the Snapshot was created when the Flush was already marked as completed. We can clean up.

      final yieldControl = YieldController('WriteBufferManager.purgePending');
      while (_pendingCleanupQueue.isNotEmpty) {
        await yieldControl.maybeYield();
        final head = _pendingCleanupQueue.first;

        // Check if oldestSnapshot is newer than flushMarker
        if (oldestSnapshot.isNewerThan(head.flushMarker, walCycle)) {
          // Safe cleanup
          _cleanupSingle(head.entry);
          _pendingCleanupQueue.removeFirst();
        } else {
          // Head data is still needed by an old view (or equal to flushMarker), stop cleaning
          break;
        }
      }
    } finally {
      _isPurging = false;
    }
  }

  /// Buffered read helpers
  BufferEntry? getBufferedRecord(String tableName, String recordId) {
    return _buffersByTable[tableName]?.records[recordId];
  }

  /// Get the maximum primary key value from the buffer for a table
  /// Optimized: Uses side-channel index of inserts to avoid scan.
  /// Returns the latest inserted key (assuming monotonic assumption).
  dynamic getMaxPrimaryKey(String tableName, String pkField,
      int Function(dynamic, dynamic) comparator) {
    // 1. Try Insert Index (Fastest, O(1))
    final buf = _buffersByTable[tableName];
    if (buf != null && !buf.insertedKeys.isEmpty) {
      final lastKey = buf.insertedKeys.last;
      if (lastKey != null) {
        final entry = buf.records[lastKey];
        if (entry != null) {
          return entry.data[pkField];
        }
      }
    }

    // Fallback? If index empty, then no max in buffer.
    return null;
  }

  /// Get efficient iterable of buffered insert keys
  /// Returns a Yield-Safe iterable (Sequence Based).
  /// Get efficient iterable of buffered insert keys
  /// Returns a Yield-Safe iterable (Sequence Based).
  Iterable<String> getBufferedInsertKeys(String tableName,
      {bool reverse = false}) {
    return _buffersByTable[tableName]
            ?.insertedKeys
            .iterable(reverse: reverse) ??
        const [];
  }

  /// Incremental overlay after a snapshot by scanning the write queue from tail.
  /// This version is cycle-aware using the current WAL pointer and cycle size.
  ///
  /// It collects the latest BufferEntry for each recordId of [tableName] where
  /// walPointer is newer than [afterExclusive]. It stops early once encountering
  /// a queue entry that is not newer than [afterExclusive] (since the queue is append-ordered).
  /// Get incremental updates from queues (Active + Pending)
  /// - Scans both _writeQueue and _pendingCleanupQueue
  /// - Supports filtering by table, key predicate, and limit for efficiency
  Future<Map<String, BufferEntry>> getTableDeltaFromQueueSince(
    String tableName,
    WalPointer since,
    WalPointer until, {
    bool Function(String)? keyPredicate,
    int? limit,
  }) async {
    final result = <String, BufferEntry>{};
    final yieldControl =
        YieldController('WriteBufferManager.getTableDeltaFromQueueSince');

    int walCycle = _dataStore.config.logPartitionCycle;

    // Helper to process an entry and decide whether to continue
    // Returns true to continue scanning, false to stop (limit reached)
    bool processEntry(String tName, String rId, WalPointer ptr) {
      // 1. Check table
      if (tName != tableName) return true;

      // 2. Check WAL range (Stop if we hit 'since' or older)
      // Since we scan Reverse (Newest -> Oldest),
      // if ptr <= since, we can stop for this queue/global timeline?
      // Yes, because queues are ordered.
      if (!ptr.isNewerThan(since, walCycle)) {
        // Found entry older than 'since'.
        // Because of strict ordering, all subsequent entries (older) are also irrelevant.
        // BUT be careful: isNewerThan on HEAD (oldest) check?
        // We are iterating items. If item <= since. Stop.
        return false; // Stop scanning
      }

      // 3. Check 'until' (future filter)
      if (ptr.isNewerThan(until, walCycle)) return true; // Skip (too new)

      // 4. Check Key Predicate
      if (keyPredicate != null && !keyPredicate(rId)) return true; // Skip

      // 5. Check limit
      if (limit != null && result.length >= limit) return false; // Stop

      // 6. Fetch Data
      // Note: WriteQueueEntry doesn't have data. Get from buffer.
      // If buffer has newer version, we effectively return newer version.
      // (This is a known limitation without MVCC, but fits Read Committed).
      final buf = _buffersByTable[tableName];
      if (buf != null) {
        final data = buf.records[rId];
        if (data != null) {
          result[rId] = data;
        }
      }
      return true;
    }

    // 1. Scan Active Write Queue (Reverse: Newest -> Oldest)
    // We convert to list to iterate reversed. This is O(N) copy but N is queue size (small-ish).
    final activeList = _writeQueue.toList();
    for (int i = activeList.length - 1; i >= 0; i--) {
      await yieldControl.maybeYield();
      final e = activeList[i];
      if (!processEntry(e.tableName, e.recordId, e.walPointer)) {
        // If processEntry returned false, it means we hit 'since' or limit.
        // If limit: full stop.
        // If 'since': subsequent items in activeList are older. And pendingQueue is even older.
        // So we can return immediately!
        return result;
      }
    }

    // 2. Scan Pending Cleanup Queue (Reverse: Newest Flushed -> Oldest Flushed)
    // Pending items are older than Active items.
    final pendingList = _pendingCleanupQueue.toList();
    for (int i = pendingList.length - 1; i >= 0; i--) {
      await yieldControl.maybeYield();
      final item = pendingList[i];
      if (!processEntry(
          item.entry.tableName, item.entry.recordId, item.entry.walPointer)) {
        return result;
      }
    }

    return result;
  }

  bool hasUniqueKey(String tableName, String indexName, dynamic compositeKey) {
    final internalKey = _toInternalKey(compositeKey);
    final set = _buffersByTable[tableName]?.uniqueIndexEntries[indexName];
    return set != null && set.contains(internalKey);
  }

  /// Clear all buffers (used after a full flush or on close)
  void clearAll() {
    _globalClearEpoch++;
    _buffersByTable.clear(); // InsertedKeys cleared with buffers
    _writeQueue.clear();
    _pendingCleanupQueue.clear();

    // Clear transaction-specific unique key reservations
    _txnBuffers.clear();
    _txnGlobalUniqueKeyOwners.clear();

    _emitSizeChanged();
  }

  /// Clear buffers and queued entries for a specific table (best effort)
  Future<void> clearTable(String tableName) async {
    _buffersByTable.remove(tableName);
    // From pending cleanup queue, remove entries for this table
    _pendingCleanupQueue
        .removeWhere((item) => item.entry.tableName == tableName);
    _tableClearEpochs[tableName] = (_tableClearEpochs[tableName] ?? 0) + 1;
    if (_writeQueue.isNotEmpty) {
      _writeQueue.removeWhere((e) => e.tableName == tableName);
    }

    // Cleanup transaction unique keys for this table
    final yieldController = YieldController('buf_clear_table_txn');
    for (final tables in _txnBuffers.values) {
      await yieldController.maybeYield();
      tables.remove(tableName);
    }

    _txnGlobalUniqueKeyOwners.remove(tableName);
    _emitSizeChanged();
  }

  // Transaction-specific unique key tracking
  // transactionId -> tableName -> _TxnUniqueTableBuffer
  final Map<String, Map<String, _TxnUniqueTableBuffer>> _txnBuffers = {};

  // Global inverted index for valid active transaction unique keys (O(1) conflict detection)
  // tableName -> indexName -> internalKey -> { Map<txId, Set<recordId>> }
  final Map<String, Map<String, Map<dynamic, Map<String, Set<String>>>>>
      _txnGlobalUniqueKeyOwners = {};

  void addTransactionUniqueKeys({
    required String transactionId,
    required String tableName,
    required String recordId,
    required List<UniqueKeyRef> uniqueKeys,
    List<dynamic>? internalKeys,
  }) {
    if (uniqueKeys.isEmpty) return;
    final byTable = _txnBuffers.putIfAbsent(transactionId, () => {});
    final buf = byTable.putIfAbsent(tableName, () => _TxnUniqueTableBuffer());

    // Remove existing keys for this record/table/tx to handle updates correctly (overwrite)
    _removeTransactionUniqueKeysForRecord(
        transactionId, tableName, recordId, buf);

    // Save mapping for O(1) cleanup later
    buf.recordIdToUniqueKeys[recordId] = uniqueKeys;

    for (int i = 0; i < uniqueKeys.length; i++) {
      final uk = uniqueKeys[i];
      final internalKey = internalKeys != null
          ? internalKeys[i]
          : _toInternalKey(uk.compositeKey);
      // Local
      var ownersByKey = buf.uniqueKeyOwners[uk.indexName];
      if (ownersByKey == null) {
        ownersByKey = <dynamic, Set<String>>{};
        buf.uniqueKeyOwners[uk.indexName] = ownersByKey;
      }
      var owners = ownersByKey[internalKey];
      if (owners == null) {
        owners = <String>{};
        ownersByKey[internalKey] = owners;
      }
      owners.add(recordId);

      // Global
      var globalIndices = _txnGlobalUniqueKeyOwners[tableName];
      if (globalIndices == null) {
        globalIndices = {};
        _txnGlobalUniqueKeyOwners[tableName] = globalIndices;
      }
      var globalKeys = globalIndices[uk.indexName];
      if (globalKeys == null) {
        globalKeys = {};
        globalIndices[uk.indexName] = globalKeys;
      }
      var globalOwners = globalKeys[internalKey];
      if (globalOwners == null) {
        globalOwners = {};
        globalKeys[internalKey] = globalOwners;
      }
      var txOwners = globalOwners[transactionId];
      if (txOwners == null) {
        txOwners = {};
        globalOwners[transactionId] = txOwners;
      }
      txOwners.add(recordId);
    }
  }

  void _removeTransactionUniqueKeysForRecord(String transactionId,
      String tableName, String recordId, _TxnUniqueTableBuffer buf) {
    // Optimization: avoid O(N^2) scan by using record-to-keys reverse index
    final existingKeys = buf.recordIdToUniqueKeys.remove(recordId);
    if (existingKeys == null) return;

    for (final uk in existingKeys) {
      final internalKey = _toInternalKey(uk.compositeKey);
      // Local cleanup
      final owners = buf.uniqueKeyOwners[uk.indexName]?[internalKey];
      if (owners != null) {
        owners.remove(recordId);
        if (owners.isEmpty) {
          buf.uniqueKeyOwners[uk.indexName]?.remove(internalKey);
          if (buf.uniqueKeyOwners[uk.indexName]?.isEmpty == true) {
            buf.uniqueKeyOwners.remove(uk.indexName);
          }
        }
      }

      // Global cleanup
      _removeFromGlobalIndex(
          transactionId, tableName, uk.indexName, internalKey, recordId);
    }
  }

  void _removeFromGlobalIndex(String transactionId, String tableName,
      String indexName, dynamic internalKey, String recordId) {
    final globalIndices = _txnGlobalUniqueKeyOwners[tableName];
    if (globalIndices == null) return;
    final globalKeys = globalIndices[indexName];
    if (globalKeys == null) return;
    final globalOwners = globalKeys[internalKey];
    if (globalOwners == null) return;

    final txOwners = globalOwners[transactionId];
    if (txOwners != null) {
      txOwners.remove(recordId);
      if (txOwners.isEmpty) {
        globalOwners.remove(transactionId);
      }
    }

    // Hierarchical cleanup to prevent memory leaks
    if (globalOwners.isEmpty) {
      globalKeys.remove(internalKey);
      if (globalKeys.isEmpty) {
        globalIndices.remove(indexName);
        if (globalIndices.isEmpty) {
          _txnGlobalUniqueKeyOwners.remove(tableName);
        }
      }
    }
  }

  Future<void> removeTransactionUniqueKeys(String transactionId) async {
    final byTable = _txnBuffers.remove(transactionId);
    if (byTable == null) return;

    // Cleanup global index
    final yieldController = YieldController('buf_remove_txn_keys');
    for (final tEntry in byTable.entries) {
      final tableName = tEntry.key;
      final buf = tEntry.value;
      for (final iEntry in buf.uniqueKeyOwners.entries) {
        final indexName = iEntry.key;
        for (final kEntry in iEntry.value.entries) {
          await yieldController.maybeYield();
          final internalKey = _toInternalKey(kEntry.key);
          _removeTxFromGlobalIndex(
              transactionId, tableName, indexName, internalKey);
        }
      }
    }
  }

  void _removeTxFromGlobalIndex(String transactionId, String tableName,
      String indexName, dynamic internalKey) {
    final globalIndices = _txnGlobalUniqueKeyOwners[tableName];
    if (globalIndices == null) return;
    final globalKeys = globalIndices[indexName];
    if (globalKeys == null) return;
    final globalOwners = globalKeys[internalKey];
    if (globalOwners == null) return;

    globalOwners.remove(transactionId);

    // Hierarchical cleanup
    if (globalOwners.isEmpty) {
      globalKeys.remove(internalKey);
      if (globalKeys.isEmpty) {
        globalIndices.remove(indexName);
        if (globalIndices.isEmpty) {
          _txnGlobalUniqueKeyOwners.remove(tableName);
        }
      }
    }
  }

  BatchCheckContext createBatchCheckContext(
      String tableName, String? transactionId) {
    WriteDataBuffer? mainBuf;
    _TxnUniqueTableBuffer? txnBuf;
    Map<String, Map<dynamic, Map<String, Set<String>>>>? globalIndices;

    if (transactionId != null) {
      // Transactional: Ensure txn buffers and Global indices exist for writing
      final byTable = _txnBuffers.putIfAbsent(transactionId, () => {});
      txnBuf = byTable.putIfAbsent(tableName, () => _TxnUniqueTableBuffer());

      mainBuf = _buffersByTable[tableName]; // Used for reading/checking only
      globalIndices =
          _txnGlobalUniqueKeyOwners.putIfAbsent(tableName, () => {});
    } else {
      // Non-Transactional: Ensure main buffer exists for writing
      mainBuf = _ensureTable(tableName);
      globalIndices = _txnGlobalUniqueKeyOwners[tableName];
    }

    return BatchCheckContext(
        tableName, transactionId, mainBuf, txnBuf, globalIndices);
  }

  bool hasUniqueKeyOwnedByOther(String tableName, String indexName,
      dynamic compositeKey, String? selfRecordId,
      {String? transactionId, dynamic internalKey}) {
    internalKey ??= _toInternalKey(compositeKey);
    // 1. Check main buffer (committed/flushing)
    final mainBuf = _buffersByTable[tableName];
    if (mainBuf != null) {
      final owners = mainBuf.uniqueKeyOwners[indexName]?[internalKey];
      if (owners != null && owners.isNotEmpty) {
        // If owner is self, valid. If owner is different, invalid.
        // If multiple owners (shouldn't happen for unique), invalid.
        if (selfRecordId == null) return true;
        if (owners.length > 1) return true;
        if (!owners.contains(selfRecordId)) return true;
      }
    }

    // 2. Check global transaction index (O(1))
    final globalOwners =
        _txnGlobalUniqueKeyOwners[tableName]?[indexName]?[internalKey];
    if (globalOwners != null && globalOwners.isNotEmpty) {
      for (final entry in globalOwners.entries) {
        final txId = entry.key;
        final recordIds = entry.value;
        if (recordIds.isEmpty) {
          continue; // should not happen if maintained correctly
        }

        // If checking check against OWN transaction
        if (transactionId != null && txId == transactionId) {
          if (selfRecordId == null) return true;
          // If multiple records in same tx have same key -> duplicate!
          if (recordIds.length > 1) return true;
          // If single record, must be self
          if (!recordIds.contains(selfRecordId)) return true;
        } else {
          // Conflict with OTHER transaction (regardless of recordId, assuming unique key cannot be shared across txns until commit)
          return true;
        }
      }
    }

    return false;
  }

  /// Check if a unique key is owned by another transaction (transaction-only check).
  ///
  /// This method only checks the global transaction index, NOT the main buffer.
  /// Useful when full index cache is marked, where committed data is already validated
  /// via cache, and we only need to check for transactional conflicts.
  ///
  /// Returns true if the key is owned by another transaction (or by another record
  /// in the same transaction if selfRecordId is provided).
  bool hasUniqueKeyOwnedByOtherTransaction(String tableName, String indexName,
      dynamic compositeKey, String? selfRecordId,
      {String? transactionId, dynamic internalKey}) {
    internalKey ??= _toInternalKey(compositeKey);

    // Only check global transaction index (O(1))
    final globalOwners =
        _txnGlobalUniqueKeyOwners[tableName]?[indexName]?[internalKey];
    if (globalOwners != null && globalOwners.isNotEmpty) {
      for (final entry in globalOwners.entries) {
        final txId = entry.key;
        final recordIds = entry.value;
        if (recordIds.isEmpty) {
          continue; // should not happen if maintained correctly
        }

        // If checking against OWN transaction
        if (transactionId != null && txId == transactionId) {
          if (selfRecordId == null) return true;
          // If multiple records in same tx have same key -> duplicate!
          if (recordIds.length > 1) return true;
          // If single record, must be self
          if (!recordIds.contains(selfRecordId)) return true;
        } else {
          // Conflict with OTHER transaction (regardless of recordId, assuming unique key cannot be shared across txns until commit)
          return true;
        }
      }
    }

    return false;
  }

  /// Try to reserve unique keys for a record.
  /// If any key is already owned by another record, throws a UniqueViolation (or returns false/error).
  /// Returns the previous unique keys reserved for this record (if any), to allow restoration on failure.
  List<UniqueKeyRef>? tryReserveUniqueKeys({
    required String tableName,
    required String recordId,
    required List<UniqueKeyRef> uniqueKeys,
    String? transactionId,
  }) {
    if (uniqueKeys.isEmpty) return null;

    // Pre-calculate internal keys to avoid repetitive encoding costs
    final List<dynamic> internalKeys =
        List<dynamic>.filled(uniqueKeys.length, null);
    for (int i = 0; i < uniqueKeys.length; i++) {
      internalKeys[i] = _toInternalKey(uniqueKeys[i].compositeKey);
    }

    // 1. Check ALL keys first to fail fast without modifying state
    for (int i = 0; i < uniqueKeys.length; i++) {
      final uk = uniqueKeys[i];
      if (hasUniqueKeyOwnedByOther(
          tableName, uk.indexName, uk.compositeKey, recordId,
          transactionId: transactionId, internalKey: internalKeys[i])) {
        throw UniqueViolation(
          tableName: tableName,
          fields: [], // Caller can fill this if needed, or we just throw simple error
          value: uk.compositeKey,
          indexName: uk.indexName,
        );
      }
    }

    // 2. Add keys to structures (and capture old keys)
    if (transactionId != null) {
      final byTable = _txnBuffers.putIfAbsent(transactionId, () => {});
      final buf = byTable.putIfAbsent(tableName, () => _TxnUniqueTableBuffer());

      // Capture old keys before they are removed by addTransactionUniqueKeys
      final oldKeys = buf.recordIdToUniqueKeys[recordId];

      addTransactionUniqueKeys(
          transactionId: transactionId,
          tableName: tableName,
          recordId: recordId,
          uniqueKeys: uniqueKeys,
          internalKeys: internalKeys);
      return oldKeys;
    } else {
      final buf = _ensureTable(tableName);
      final oldKeys = buf.recordIdToUniqueKeys[recordId];

      // Remove old keys if present (to ensure clean state like addRecord, though mostly additive here)
      // Actually strictly speaking, if we just overwrite map and add to owners, we leave garbage in owners.
      // We must remove old ownerships!
      if (oldKeys != null) {
        buf.recordIdToUniqueKeys.remove(recordId);
        for (final uk in oldKeys) {
          final internalKey = _toInternalKey(uk.compositeKey);
          buf.uniqueKeyOwners[uk.indexName]?[internalKey]?.remove(recordId);
        }
      }

      buf.recordIdToUniqueKeys[recordId] = uniqueKeys;
      for (int i = 0; i < uniqueKeys.length; i++) {
        final uk = uniqueKeys[i];
        final internalKey = internalKeys[i];
        var set = buf.uniqueIndexEntries[uk.indexName];
        if (set == null) {
          set = <dynamic>{};
          buf.uniqueIndexEntries[uk.indexName] = set;
        }
        set.add(internalKey);

        var ownersByKey = buf.uniqueKeyOwners[uk.indexName];
        if (ownersByKey == null) {
          ownersByKey = <dynamic, Set<String>>{};
          buf.uniqueKeyOwners[uk.indexName] = ownersByKey;
        }
        var owners = ownersByKey[internalKey];
        if (owners == null) {
          owners = <String>{};
          ownersByKey[internalKey] = owners;
        }
        owners.add(recordId);
      }
      return oldKeys;
    }
  }

  /// Release reserved unique keys (used on failure).
  /// If [restoreKeys] is provided, these keys are re-reserved for the record,
  /// effectively rolling back to the previous state.
  void releaseReservedUniqueKeys({
    required String tableName,
    required String recordId,
    String? transactionId,
    List<UniqueKeyRef>? restoreKeys,
  }) {
    if (transactionId != null) {
      final byTable = _txnBuffers[transactionId];
      final buf = byTable?[tableName];
      if (buf != null) {
        _removeTransactionUniqueKeysForRecord(
            transactionId, tableName, recordId, buf);
      }
    } else {
      final buf = _buffersByTable[tableName];
      if (buf != null) {
        final keys = buf.recordIdToUniqueKeys.remove(recordId);
        if (keys != null) {
          for (final uk in keys) {
            final internalKey = _toInternalKey(uk.compositeKey);
            final set = buf.uniqueIndexEntries[uk.indexName];
            set?.remove(internalKey);
            if (set != null && set.isEmpty) {
              buf.uniqueIndexEntries.remove(uk.indexName);
            }
            final ownersByKey = buf.uniqueKeyOwners[uk.indexName];
            final owners = ownersByKey?[internalKey];
            owners?.remove(recordId);
            if (owners != null && owners.isEmpty) {
              ownersByKey?.remove(internalKey);
            }
            if (ownersByKey != null && ownersByKey.isEmpty) {
              buf.uniqueKeyOwners.remove(uk.indexName);
            }
          }
        }
      }
    }

    if (restoreKeys != null && restoreKeys.isNotEmpty) {
      tryReserveUniqueKeys(
        tableName: tableName,
        recordId: recordId,
        uniqueKeys: restoreKeys,
        transactionId: transactionId,
      );
    }
  }
}

class _TxnUniqueTableBuffer {
  // indexName -> internalKey -> Set<recordId>
  final Map<String, Map<dynamic, Set<String>>> uniqueKeyOwners = {};
  // recordId -> List<UniqueKeyRef> (reverse index for O(1) removals)
  final Map<String, List<UniqueKeyRef>> recordIdToUniqueKeys = {};
}

/// Helper to handle List equality in Map/Set keys by converting to a fast string key.
/// If it's not a List, returns as is.
dynamic _toInternalKey(dynamic key) {
  if (key is List) {
    if (key.isEmpty) return '';
    if (key.length == 1) return key[0];
    // Optimized join for internal keying.
    // Uses \x00 as delimiter which is rare and fast for joining.
    return key.join('\x00');
  }
  return key;
}
