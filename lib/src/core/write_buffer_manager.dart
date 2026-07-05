import 'dart:async';
import 'dart:collection';

import '../handler/logger.dart';
import '../model/buffer_entry.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/table_context.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';
import '../model/unique_violation.dart';
import '../model/wal_pointer.dart';
import 'crontab_manager.dart';
import 'data_store_impl.dart';
import 'yield_controller.dart';

class WriteQueueEntry {
  TableUid tableUid;
  final String recordId;
  final BufferOperationType operationType;
  final WalPointer walPointer;

  WriteQueueEntry({
    required this.tableUid,
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
  final IndexUid indexUid;
  final dynamic compositeKey; // raw native value or List<dynamic> for composite
  late final dynamic internalKey;

  UniqueKeyRef(this.indexUid, this.compositeKey) {
    internalKey = _toInternalKey(compositeKey);
  }

  Map<String, dynamic> toJson() => {
        'indexUid': indexUid.value,
        'compositeKey': compositeKey,
      };

  factory UniqueKeyRef.fromJson(Map<String, dynamic> json) {
    final uid =
        json['indexUid'] as String? ?? json['indexName'] as String? ?? '';
    return UniqueKeyRef(
      IndexUid(uid),
      json['compositeKey'],
    );
  }
}

IndexSchema? _findIndexSchemaByUid(TableSchema schema, IndexUid indexUid) {
  for (final idx in schema.getAllIndexes()) {
    if (idx.indexUid == indexUid) return idx;
  }
  return null;
}

/// Build a user-facing [UniqueViolation] from an internal [UniqueKeyRef].
UniqueViolation _uniqueViolationForKeyRef(
  TableContext table,
  UniqueKeyRef uk,
  String existingPrimaryKey,
) {
  if (uk.indexUid == IndexUid('pk')) {
    return UniqueViolation(
      tableName: table.tableName,
      fields: [table.schema.primaryKey],
      value: uk.compositeKey,
      indexName: IndexName('pk'),
      existingPrimaryKey: existingPrimaryKey,
    );
  }

  final idx = _findIndexSchemaByUid(table.schema, uk.indexUid);
  return UniqueViolation(
    tableName: table.tableName,
    fields: idx?.fields ?? const <String>[],
    value: uk.compositeKey,
    indexName: idx != null ? IndexName(idx.actualIndexName) : null,
    existingPrimaryKey: existingPrimaryKey,
  );
}

/// Context for batch operations to avoid repetitive Map lookups
class BatchCheckContext {
  final TableContext table;
  final TableName tableName;
  final TableUid tableUid;
  final String? transactionId;
  final WriteDataBuffer? mainBuf;
  // ignore: library_private_types_in_public_api
  final _TxnUniqueTableBuffer? txnBuf;
  final Map<IndexUid, Map<dynamic, Map<String, Set<String>>>>? globalIndices;

  BatchCheckContext(
    this.table,
    this.transactionId,
    this.mainBuf,
    // ignore: library_private_types_in_public_api
    this.txnBuf,
    this.globalIndices,
  )   : tableName = table.tableName,
        tableUid = table.tableUid;

  List<UniqueKeyRef>? tryReserve(
      String recordId, List<UniqueKeyRef> uniqueKeys) {
    // 1. Check ALL keys first
    for (final uk in uniqueKeys) {
      final conflictId = _hasUniqueKeyOwnedByOther(uk, recordId);
      if (conflictId != null) {
        throw _uniqueViolationForKeyRef(table, uk, conflictId);
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
          buf.uniqueKeyOwners[uk.indexUid]?[iKey]?.remove(recordId);
          // Global cleanup
          _removeFromGlobalIndex(uk.indexUid, iKey, recordId);
        }
      }

      buf.recordIdToUniqueKeys[recordId] = uniqueKeys;

      // Add new
      for (final uk in uniqueKeys) {
        final iKey = uk.internalKey;
        // Local
        var ownersByKey = buf.uniqueKeyOwners[uk.indexUid];
        if (ownersByKey == null) {
          ownersByKey = <dynamic, Set<String>>{};
          buf.uniqueKeyOwners[uk.indexUid] = ownersByKey;
        }
        var owners = ownersByKey[iKey];
        if (owners == null) {
          owners = <String>{};
          ownersByKey[iKey] = owners;
        }
        owners.add(recordId);

        // Global
        var globalKeys = globalIndices?[uk.indexUid];
        if (globalKeys == null) {
          globalKeys = {};
          // Should verify if globalIndices is not null, but it comes from context
          if (globalIndices != null) globalIndices![uk.indexUid] = globalKeys;
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
          buf.uniqueKeyOwners[uk.indexUid]?[uk.internalKey]?.remove(recordId);
        }
      }

      buf.recordIdToUniqueKeys[recordId] = uniqueKeys;
      for (final uk in uniqueKeys) {
        final iKey = uk.internalKey;
        var set = buf.uniqueIndexEntries[uk.indexUid];
        if (set == null) {
          set = <dynamic>{};
          buf.uniqueIndexEntries[uk.indexUid] = set;
        }
        set.add(iKey);

        var ownersByKey = buf.uniqueKeyOwners[uk.indexUid];
        if (ownersByKey == null) {
          ownersByKey = <dynamic, Set<String>>{};
          buf.uniqueKeyOwners[uk.indexUid] = ownersByKey;
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

  String? _hasUniqueKeyOwnedByOther(UniqueKeyRef uk, String? selfRecordId) {
    // 1. Check main buffer
    if (mainBuf != null) {
      final owners = mainBuf!.uniqueKeyOwners[uk.indexUid]?[uk.internalKey];
      if (owners != null && owners.isNotEmpty) {
        if (selfRecordId == null) return owners.first;
        if (!owners.contains(selfRecordId)) return owners.first;
        if (owners.length > 1) {
          return owners.firstWhere((id) => id != selfRecordId);
        }
      }
    }
    // 2. Check global txn
    if (globalIndices != null) {
      final globalOwners = globalIndices![uk.indexUid]?[uk.internalKey];
      if (globalOwners != null && globalOwners.isNotEmpty) {
        for (final entry in globalOwners.entries) {
          final txId = entry.key;
          final recordIds = entry.value;
          if (recordIds.isEmpty) continue;

          if (transactionId != null && txId == transactionId) {
            if (selfRecordId == null) return recordIds.first;
            if (!recordIds.contains(selfRecordId)) return recordIds.first;
            if (recordIds.length > 1) {
              return recordIds.firstWhere((id) => id != selfRecordId);
            }
          } else {
            return recordIds.first;
          }
        }
      }
    }
    return null;
  }

  // Duplicated helper for context to avoid refactoring entire class to static
  void _removeFromGlobalIndex(
      IndexUid indexUid, dynamic internalKey, String recordId) {
    if (globalIndices == null) return;
    final globalKeys = globalIndices![indexUid];
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
        globalIndices!.remove(indexUid);
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
  // indexUid -> Set<internalKey>
  final Map<IndexUid, Set<dynamic>> uniqueIndexEntries =
      <IndexUid, Set<dynamic>>{};
  // recordId -> List<UniqueKeyRef>
  final Map<String, List<UniqueKeyRef>> recordIdToUniqueKeys =
      <String, List<UniqueKeyRef>>{};
  // indexUid -> internalKey -> Set<recordId> (owners)
  final Map<IndexUid, Map<dynamic, Set<String>>> uniqueKeyOwners =
      <IndexUid, Map<dynamic, Set<String>>>{};

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

  final Map<TableUid, WriteDataBuffer> _buffersByTableUid =
      <TableUid, WriteDataBuffer>{};
  final Map<TableUid, int> _tableClearEpochs = <TableUid, int>{};
  int _globalClearEpoch = 0;
  final Queue<WriteQueueEntry> _writeQueue = Queue<WriteQueueEntry>();
  final StreamController<int> _sizeController =
      StreamController<int>.broadcast();

  /// Delayed cleanup queue: keep data in [_buffersByTableUid] main buffer, only this queue records cleanup tasks.
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

  WriteDataBuffer _ensureTable(TableContext table) {
    return _buffersByTableUid.putIfAbsent(
        table.tableUid, () => WriteDataBuffer());
  }

  /// Get the current clear epoch for a table.
  /// Incremented every time clearTable or clearAll is called.
  int getClearEpoch(TableContext table) {
    return (_tableClearEpochs[table.tableUid] ?? 0) + _globalClearEpoch;
  }

  /// Remove a specific record from buffer and queue (best effort)
  void removeRecord(TableContext table, String recordId) {
    final tableUid = table.tableUid;
    // 1) Cleanup table buffers
    final buf = _buffersByTableUid[tableUid];
    if (buf != null) {
      buf.records.remove(recordId);
      buf.insertedKeys.remove(recordId);
      final keys = buf.recordIdToUniqueKeys.remove(recordId);
      if (keys != null) {
        for (final uk in keys) {
          final internalKey = _toInternalKey(uk.compositeKey);
          final set = buf.uniqueIndexEntries[uk.indexUid];
          set?.remove(internalKey);
          if (set != null && set.isEmpty) {
            buf.uniqueIndexEntries.remove(uk.indexUid);
          }
          final ownersByKey = buf.uniqueKeyOwners[uk.indexUid];
          final owners = ownersByKey?[internalKey];
          owners?.remove(recordId);
          if (owners != null && owners.isEmpty) {
            ownersByKey?.remove(internalKey);
          }
          if (ownersByKey != null && ownersByKey.isEmpty) {
            buf.uniqueKeyOwners.remove(uk.indexUid);
          }
        }
      }
      if (buf.records.isEmpty &&
          buf.uniqueIndexEntries.isEmpty &&
          buf.recordIdToUniqueKeys.isEmpty) {
        _buffersByTableUid.remove(tableUid);
      }
    }

    // 2) Rebuild queue without affected entries (iterator cannot remove in-place)
    if (_writeQueue.isNotEmpty) {
      _writeQueue
          .removeWhere((e) => e.tableUid == tableUid && e.recordId == recordId);
      _emitSizeChanged();
    }
  }

  /// Add record into buffer and enqueue for flush (ordered by WAL pointer)
  Future<void> addRecord({
    required TableContext table,
    required String recordId,
    required BufferEntry entry,
    List<UniqueKeyRef> uniqueKeys = const <UniqueKeyRef>[],
    bool updateStats = true,
  }) async {
    final buf = _ensureTable(table);
    final BufferEntry? prior = buf.records[recordId];
    bool skipBufferStore = false;
    bool skipQueueEnqueue =
        false; // Flag to skip adding to queue when merging INSERT+UPDATE
    bool restoreDeletedCount = false;
    BufferEntry effectiveEntry = entry;
    if (prior != null) {
      if (prior.operation == BufferOperationType.insert &&
          entry.operation == BufferOperationType.update) {
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
          schemaVersion: entry.schemaVersion,
        );
        skipQueueEnqueue =
            true; // Skip queue enqueue - INSERT entry already exists
      } else if (prior.operation == BufferOperationType.insert &&
          entry.operation == BufferOperationType.delete) {
        // Cancel: drop the pending INSERT from buffer (no buffered record kept)
        // Remove the existing buffered INSERT so subsequent reads won't see it.
        // Cancel: drop the pending INSERT from buffer (no buffered record kept)
        // Remove the existing buffered INSERT so subsequent reads won't see it.
        buf.records.remove(recordId);
        buf.insertedKeys.remove(recordId);
        skipBufferStore = true;
      } else if (prior.operation == BufferOperationType.delete &&
          entry.operation == BufferOperationType.insert) {
        // A committed record was deleted and then recreated with the same PK
        // before the delete flushed. Persist this as an UPDATE so flush keeps
        // the old indexed values available for diff/removal.
        effectiveEntry = BufferEntry(
          data: entry.data,
          operation: BufferOperationType.update,
          timestamp: entry.timestamp,
          walPointer: entry.walPointer,
          transactionId: prior.transactionId ?? entry.transactionId,
          oldValues: prior.oldValues ?? prior.data,
          schemaVersion: entry.schemaVersion,
        );
        restoreDeletedCount = true;
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
          final set = buf.uniqueIndexEntries[uk.indexUid];
          set?.remove(internalKey);
          if (set != null && set.isEmpty) {
            buf.uniqueIndexEntries.remove(uk.indexUid);
          }
          final ownersByKey = buf.uniqueKeyOwners[uk.indexUid];
          final owners = ownersByKey?[internalKey];
          owners?.remove(recordId);
          if (owners != null && owners.isEmpty) {
            ownersByKey?.remove(internalKey);
          }
          if (ownersByKey != null && ownersByKey.isEmpty) {
            buf.uniqueKeyOwners.remove(uk.indexUid);
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
      } else {
        buf.insertedKeys.remove(recordId);
      }

      if (uniqueKeys.isNotEmpty &&
          effectiveEntry.operation != BufferOperationType.delete) {
        buf.recordIdToUniqueKeys[recordId] = uniqueKeys;
        for (final uk in uniqueKeys) {
          final internalKey = _toInternalKey(uk.compositeKey);
          var set = buf.uniqueIndexEntries[uk.indexUid];
          if (set == null) {
            set = <dynamic>{};
            buf.uniqueIndexEntries[uk.indexUid] = set;
          }
          set.add(internalKey);

          var ownersByKey = buf.uniqueKeyOwners[uk.indexUid];
          if (ownersByKey == null) {
            ownersByKey = <dynamic, Set<String>>{};
            buf.uniqueKeyOwners[uk.indexUid] = ownersByKey;
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
      // Invalidate any pending background write entries for this primary key, so that
      // background tasks (keyMigration, schemaMigration, largeUpdate, largeDelete) cannot
      // overwrite this newer online write during the next _pumpFlush cycle.
      // This is an O(1) guard; _pumpFlush also enforces business-over-background priority,
      // but early invalidation releases memory sooner.
      if (!skipBufferStore) {
        _dataStore.backgroundWriteScheduler.handleOnlineWrite(table, recordId);
      }
      // Write backpressure: measured-delay throttle (1 multiply + 1 compare)
      await _dataStore.parallelJournalManager.waitIfThrottled();
      // Update record count statistics (awaited to ensure consistency)
      if (updateStats) {
        if (restoreDeletedCount) {
          await _dataStore.tableDataManager
              .updateTableRecordCount(table, BufferOperationType.insert);
        } else {
          await _dataStore.tableDataManager
              .updateTableRecordCount(table, effectiveEntry.operation);
        }
      }
      _writeQueue.add(WriteQueueEntry(
        tableUid: table.tableUid,
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
    required TableContext table,
    required List<String> recordIds,
    required List<BufferEntry> entries,
    required List<List<UniqueKeyRef>> uniqueKeysList,
  }) async {
    if (recordIds.isEmpty) return;
    if (recordIds.length != entries.length ||
        recordIds.length != uniqueKeysList.length) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message:
              'addInsertBatch length mismatch: recordIds=${recordIds.length}, entries=${entries.length}, uniqueKeysList=${uniqueKeysList.length}',
          parameterName: 'recordIds/entries/uniqueKeysList',
          passedValue: {
            'recordIdsLength': recordIds.length,
            'entriesLength': entries.length,
            'uniqueKeysListLength': uniqueKeysList.length,
          },
        )
      ]);
    }

    // Update record count once (batch optimized).
    await _dataStore.tableDataManager.updateTableRecordCountDelta(
      table,
      insertDelta: recordIds.length,
    );

    final buf = _ensureTable(table);
    final yieldController =
        YieldController('WriteBufferManager.addInsertBatch');
    final batchSize = _dataStore.config.writeBatchSize;
    final backpressureCap = batchSize > 0 ? batchSize * 2 : 20000;
    const int emitChunk = 1000;

    for (int i = 0; i < recordIds.length; i++) {
      await yieldController.maybeYield();
      if (i % emitChunk == 0) {
        await _dataStore.parallelJournalManager.waitIfThrottled(emitChunk);
        await _dataStore.parallelJournalManager.waitUntilQueueBelow(
          backpressureCap,
          timeout: const Duration(seconds: 120),
        );
      }
      final recordId = recordIds[i];
      final entry = entries[i];
      final uniqueKeys = uniqueKeysList[i];
      final prior = buf.records[recordId];
      BufferEntry effectiveEntry = entry;

      if (prior != null && prior.operation == BufferOperationType.delete) {
        effectiveEntry = BufferEntry(
          data: entry.data,
          operation: BufferOperationType.update,
          timestamp: entry.timestamp,
          walPointer: entry.walPointer,
          transactionId: prior.transactionId ?? entry.transactionId,
          oldValues: prior.oldValues ?? prior.data,
          schemaVersion: entry.schemaVersion,
        );
      }

      // Store entry (INSERT). If a prior entry exists, remove its unique keys to prevent leaks.
      final existingKeys = buf.recordIdToUniqueKeys.remove(recordId);
      if (existingKeys != null) {
        for (final uk in existingKeys) {
          final internalKey = uk.internalKey;
          final set = buf.uniqueIndexEntries[uk.indexUid];
          set?.remove(internalKey);
          if (set != null && set.isEmpty) {
            buf.uniqueIndexEntries.remove(uk.indexUid);
          }
          final ownersByKey = buf.uniqueKeyOwners[uk.indexUid];
          final owners = ownersByKey?[internalKey];
          owners?.remove(recordId);
          if (owners != null && owners.isEmpty) {
            ownersByKey?.remove(internalKey);
          }
          if (ownersByKey != null && ownersByKey.isEmpty) {
            buf.uniqueKeyOwners.remove(uk.indexUid);
          }
        }
      }

      buf.records[recordId] = effectiveEntry;
      if (effectiveEntry.operation == BufferOperationType.insert) {
        buf.insertedKeys.add(recordId);
      } else {
        buf.insertedKeys.remove(recordId);
      }

      if (uniqueKeys.isNotEmpty) {
        buf.recordIdToUniqueKeys[recordId] = uniqueKeys;
        for (final uk in uniqueKeys) {
          final internalKey = uk.internalKey;

          var set = buf.uniqueIndexEntries[uk.indexUid];
          if (set == null) {
            set = <dynamic>{};
            buf.uniqueIndexEntries[uk.indexUid] = set;
          }
          set.add(internalKey);

          var ownersByKey = buf.uniqueKeyOwners[uk.indexUid];
          if (ownersByKey == null) {
            ownersByKey = <dynamic, Set<String>>{};
            buf.uniqueKeyOwners[uk.indexUid] = ownersByKey;
          }
          var owners = ownersByKey[internalKey];
          if (owners == null) {
            owners = <String>{};
            ownersByKey[internalKey] = owners;
          }
          owners.add(recordId);
        }
      }

      final wp = effectiveEntry.walPointer;
      if (wp == null) {
        // Should never happen for modern batch paths; skip enqueue to preserve queue integrity.
        Logger.warn(
          'Batch insert missing walPointer: table=${table.tableName} pk=$recordId, skipping enqueue',
        );
        continue;
      }
      // Invalidate any pending background write entries for this primary key.
      _dataStore.backgroundWriteScheduler.handleOnlineWrite(table, recordId);
      _writeQueue.add(WriteQueueEntry(
        tableUid: table.tableUid,
        recordId: recordId,
        operationType: effectiveEntry.operation,
        walPointer: wp,
      ));
      if ((i + 1) % emitChunk == 0 || i == recordIds.length - 1) {
        _emitSizeChanged();
      }
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
    final buf = _buffersByTableUid[e.tableUid];
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
      _removeUnconditionally(e.tableUid, e.recordId);
    }
  }

  void _removeUnconditionally(TableUid tableUid, String recordId) {
    final buf = _buffersByTableUid[tableUid];
    if (buf == null) return;

    buf.records.remove(recordId);
    buf.insertedKeys.remove(recordId);
    final keys = buf.recordIdToUniqueKeys.remove(recordId);
    if (keys != null) {
      for (final uk in keys) {
        final internalKey = _toInternalKey(uk.compositeKey);
        final set = buf.uniqueIndexEntries[uk.indexUid];
        set?.remove(internalKey);
        if (set != null && set.isEmpty) {
          buf.uniqueIndexEntries.remove(uk.indexUid);
        }
        final ownersByKey = buf.uniqueKeyOwners[uk.indexUid];
        final owners = ownersByKey?[internalKey];
        owners?.remove(recordId);
        if (owners != null && owners.isEmpty) {
          ownersByKey?.remove(internalKey);
        }
        if (ownersByKey != null && ownersByKey.isEmpty) {
          buf.uniqueKeyOwners.remove(uk.indexUid);
        }
      }
    }
    if (buf.records.isEmpty &&
        buf.uniqueIndexEntries.isEmpty &&
        buf.recordIdToUniqueKeys.isEmpty) {
      _buffersByTableUid.remove(tableUid);
    }
  }

  /// Remove already processed items for current batch based on counts by table/op
  void removeProcessedForCurrentBatch(
      Map<TableUid, Map<BufferOperationType, int>> processedCounts) {
    if (processedCounts.isEmpty || _writeQueue.isEmpty) return;
    _writeQueue.removeWhere((e) {
      final byOp = processedCounts[e.tableUid];
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
  BufferEntry? getBufferedRecord(TableContext table, String recordId) {
    return _buffersByTableUid[table.tableUid]?.records[recordId];
  }

  /// Read-path accessor:
  /// When a table is under runtime schema migration, normalize buffered records
  /// to the latest schema shape so callers stay schema-consistent.
  BufferEntry? getBufferedRecordForRead(TableContext table, String recordId) {
    final migrationManager = _dataStore.migrationManager;
    final entry = getBufferedRecord(table, recordId);
    if (entry == null) {
      return null;
    }
    if (migrationManager == null ||
        !migrationManager.hasRuntimeMigrationForTable(table)) {
      return entry;
    }
    final normalizedData = migrationManager.normalizeRecordToLatestSync(
      table,
      entry.data,
      fromVersion: entry.schemaVersion,
    );
    final normalizedOldValues = entry.oldValues != null
        ? migrationManager.normalizeRecordToLatestSync(
            table,
            entry.oldValues!,
            fromVersion: entry.schemaVersion,
          )
        : null;
    if (identical(normalizedData, entry.data) &&
        identical(normalizedOldValues, entry.oldValues)) {
      return entry;
    }
    return entry.copyWith(data: normalizedData, oldValues: normalizedOldValues);
  }

  /// Get the maximum primary key value from the buffer for a table
  /// Optimized: Uses side-channel index of inserts to avoid scan.
  /// Returns the latest inserted key (assuming monotonic assumption).
  dynamic getMaxPrimaryKey(TableContext table, String pkField,
      int Function(dynamic, dynamic) comparator) {
    // 1. Try Insert Index (Fastest, O(1))
    final buf = _buffersByTableUid[table.tableUid];
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
  Iterable<String> getBufferedInsertKeys(TableContext table,
      {bool reverse = false}) {
    return _buffersByTableUid[table.tableUid]
            ?.insertedKeys
            .iterable(reverse: reverse) ??
        const [];
  }

  /// Incremental overlay after a snapshot by scanning the write queue from tail.
  /// This version is cycle-aware using the current WAL pointer and cycle size.
  ///
  /// It collects the latest BufferEntry for each recordId of [table] where
  /// walPointer is newer than [afterExclusive]. It stops early once encountering
  /// a queue entry that is not newer than [afterExclusive] (since the queue is append-ordered).
  /// Get incremental updates from queues (Active + Pending)
  /// - Scans both _writeQueue and _pendingCleanupQueue
  /// - Supports filtering by table, key predicate, and limit for efficiency
  Future<Map<String, BufferEntry>> getTableDeltaFromQueueSince(
    TableContext table,
    WalPointer since,
    WalPointer until, {
    bool Function(String)? keyPredicate,
    int? limit,
  }) async {
    final tableUid = table.tableUid;
    final result = <String, BufferEntry>{};
    final yieldControl =
        YieldController('WriteBufferManager.getTableDeltaFromQueueSince');

    int walCycle = _dataStore.config.logPartitionCycle;

    // Helper to process an entry and decide whether to continue
    // Returns true to continue scanning, false to stop (limit reached)
    bool processEntry(String tUid, String rId, WalPointer ptr) {
      // 1. Check table
      if (tUid != tableUid) return true;

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
      final buf = _buffersByTableUid[tableUid];
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
      if (!processEntry(e.tableUid, e.recordId, e.walPointer)) {
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
          item.entry.tableUid, item.entry.recordId, item.entry.walPointer)) {
        return result;
      }
    }

    return result;
  }

  bool hasUniqueKey(
      TableContext table, IndexUid indexUid, dynamic compositeKey) {
    final internalKey = _toInternalKey(compositeKey);
    final set =
        _buffersByTableUid[table.tableUid]?.uniqueIndexEntries[indexUid];
    return set != null && set.contains(internalKey);
  }

  /// Clear all buffers (used after a full flush or on close)
  void clearAll() {
    _globalClearEpoch++;
    _buffersByTableUid.clear(); // InsertedKeys cleared with buffers
    _writeQueue.clear();
    _pendingCleanupQueue.clear();

    // Clear transaction-specific unique key reservations
    _txnBuffers.clear();
    _txnGlobalUniqueKeyOwners.clear();

    _tableClearEpochs.clear();
    _globalClearEpoch = 0;

    _emitSizeChanged();
  }

  /// Clear buffers and queued entries for a specific table (best effort)
  Future<void> clearTable(TableContext table) async {
    final tableUid = table.tableUid;
    _buffersByTableUid.remove(tableUid);
    // From pending cleanup queue, remove entries for this table
    _pendingCleanupQueue.removeWhere((item) => item.entry.tableUid == tableUid);
    _tableClearEpochs[tableUid] = (_tableClearEpochs[tableUid] ?? 0) + 1;
    if (_writeQueue.isNotEmpty) {
      _writeQueue.removeWhere((e) => e.tableUid == tableUid);
    }

    // Cleanup transaction unique keys for this table
    final yieldController = YieldController('buf_clear_table_txn');
    for (final tables in _txnBuffers.values) {
      await yieldController.maybeYield();
      tables.remove(tableUid);
    }

    _txnGlobalUniqueKeyOwners.remove(tableUid);
    _emitSizeChanged();
  }

  // Transaction-specific unique key tracking
  // transactionId -> tableUid -> _TxnUniqueTableBuffer
  final Map<String, Map<TableUid, _TxnUniqueTableBuffer>> _txnBuffers = {};

  // Global inverted index for valid active transaction unique keys (O(1) conflict detection)
  // tableUid -> indexUid -> internalKey -> { Map<txId, Set<recordId>> }
  final Map<TableUid, Map<IndexUid, Map<dynamic, Map<String, Set<String>>>>>
      _txnGlobalUniqueKeyOwners = {};

  void addTransactionUniqueKeys({
    required String transactionId,
    required TableContext table,
    required String recordId,
    required List<UniqueKeyRef> uniqueKeys,
    List<dynamic>? internalKeys,
  }) {
    if (uniqueKeys.isEmpty) return;
    final tableUid = table.tableUid;
    final byTable = _txnBuffers.putIfAbsent(transactionId, () => {});
    final buf = byTable.putIfAbsent(tableUid, () => _TxnUniqueTableBuffer());

    // Remove existing keys for this record/table/tx to handle updates correctly (overwrite)
    _removeTransactionUniqueKeysForRecord(
        transactionId, tableUid, recordId, buf);

    // Save mapping for O(1) cleanup later
    buf.recordIdToUniqueKeys[recordId] = uniqueKeys;

    for (int i = 0; i < uniqueKeys.length; i++) {
      final uk = uniqueKeys[i];
      final internalKey = internalKeys != null
          ? internalKeys[i]
          : _toInternalKey(uk.compositeKey);
      // Local
      var ownersByKey = buf.uniqueKeyOwners[uk.indexUid];
      if (ownersByKey == null) {
        ownersByKey = <dynamic, Set<String>>{};
        buf.uniqueKeyOwners[uk.indexUid] = ownersByKey;
      }
      var owners = ownersByKey[internalKey];
      if (owners == null) {
        owners = <String>{};
        ownersByKey[internalKey] = owners;
      }
      owners.add(recordId);

      // Global
      var globalIndices = _txnGlobalUniqueKeyOwners[tableUid];
      if (globalIndices == null) {
        globalIndices = {};
        _txnGlobalUniqueKeyOwners[tableUid] = globalIndices;
      }
      var globalKeys = globalIndices[uk.indexUid];
      if (globalKeys == null) {
        globalKeys = {};
        globalIndices[uk.indexUid] = globalKeys;
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
      TableUid tableUid, String recordId, _TxnUniqueTableBuffer buf) {
    // Optimization: avoid O(N^2) scan by using record-to-keys reverse index
    final existingKeys = buf.recordIdToUniqueKeys.remove(recordId);
    if (existingKeys == null) return;

    for (final uk in existingKeys) {
      final internalKey = _toInternalKey(uk.compositeKey);
      // Local cleanup
      final owners = buf.uniqueKeyOwners[uk.indexUid]?[internalKey];
      if (owners != null) {
        owners.remove(recordId);
        if (owners.isEmpty) {
          buf.uniqueKeyOwners[uk.indexUid]?.remove(internalKey);
          if (buf.uniqueKeyOwners[uk.indexUid]?.isEmpty == true) {
            buf.uniqueKeyOwners.remove(uk.indexUid);
          }
        }
      }

      // Global cleanup
      _removeFromGlobalIndex(
          transactionId, tableUid, uk.indexUid, internalKey, recordId);
    }
  }

  void _removeFromGlobalIndex(String transactionId, TableUid tableUid,
      IndexUid indexUid, dynamic internalKey, String recordId) {
    final globalIndices = _txnGlobalUniqueKeyOwners[tableUid];
    if (globalIndices == null) return;
    final globalKeys = globalIndices[indexUid];
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
        globalIndices.remove(indexUid);
        if (globalIndices.isEmpty) {
          _txnGlobalUniqueKeyOwners.remove(tableUid);
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
      final tableUid = tEntry.key;
      final buf = tEntry.value;
      for (final iEntry in buf.uniqueKeyOwners.entries) {
        final indexUid = iEntry.key;
        for (final kEntry in iEntry.value.entries) {
          await yieldController.maybeYield();
          final internalKey = _toInternalKey(kEntry.key);
          _removeTxFromGlobalIndex(
              transactionId, tableUid, indexUid, internalKey);
        }
      }
    }
  }

  void _removeTxFromGlobalIndex(String transactionId, TableUid tableUid,
      IndexUid indexUid, dynamic internalKey) {
    final globalIndices = _txnGlobalUniqueKeyOwners[tableUid];
    if (globalIndices == null) return;
    final globalKeys = globalIndices[indexUid];
    if (globalKeys == null) return;
    final globalOwners = globalKeys[internalKey];
    if (globalOwners == null) return;

    globalOwners.remove(transactionId);

    // Hierarchical cleanup
    if (globalOwners.isEmpty) {
      globalKeys.remove(internalKey);
      if (globalKeys.isEmpty) {
        globalIndices.remove(indexUid);
        if (globalIndices.isEmpty) {
          _txnGlobalUniqueKeyOwners.remove(tableUid);
        }
      }
    }
  }

  BatchCheckContext createBatchCheckContext(
      TableContext table, String? transactionId) {
    final tableUid = table.tableUid;
    WriteDataBuffer? mainBuf;
    _TxnUniqueTableBuffer? txnBuf;
    Map<IndexUid, Map<dynamic, Map<String, Set<String>>>>? globalIndices;

    if (transactionId != null) {
      // Transactional: Ensure txn buffers and Global indices exist for writing
      final byTable = _txnBuffers.putIfAbsent(transactionId, () => {});
      txnBuf = byTable.putIfAbsent(tableUid, () => _TxnUniqueTableBuffer());

      mainBuf = _buffersByTableUid[tableUid]; // Used for reading/checking only
      globalIndices = _txnGlobalUniqueKeyOwners.putIfAbsent(tableUid, () => {});
    } else {
      // Non-Transactional: Ensure main buffer exists for writing
      mainBuf = _ensureTable(table);
      globalIndices = _txnGlobalUniqueKeyOwners[tableUid];
    }

    return BatchCheckContext(
        table, transactionId, mainBuf, txnBuf, globalIndices);
  }

  String? hasUniqueKeyOwnedByOther(TableContext table, IndexUid indexUid,
      dynamic compositeKey, String? selfRecordId,
      {String? transactionId, dynamic internalKey}) {
    internalKey ??= _toInternalKey(compositeKey);
    final tableUid = table.tableUid;

    // 1. Check main buffer (committed/flushing)
    final mainBuf = _buffersByTableUid[tableUid];
    if (mainBuf != null) {
      final owners = mainBuf.uniqueKeyOwners[indexUid]?[internalKey];
      if (owners != null && owners.isNotEmpty) {
        if (selfRecordId == null) return owners.first;
        if (!owners.contains(selfRecordId)) return owners.first;
        if (owners.length > 1) {
          return owners.firstWhere((id) => id != selfRecordId);
        }
      }
    }

    // 2. Check global transaction index (O(1))
    final globalOwners =
        _txnGlobalUniqueKeyOwners[tableUid]?[indexUid]?[internalKey];
    if (globalOwners != null && globalOwners.isNotEmpty) {
      for (final entry in globalOwners.entries) {
        final txId = entry.key;
        final recordIds = entry.value;
        if (recordIds.isEmpty) {
          continue;
        }

        // If checking check against OWN transaction
        if (transactionId != null && txId == transactionId) {
          if (selfRecordId == null) return recordIds.first;
          if (!recordIds.contains(selfRecordId)) return recordIds.first;
          if (recordIds.length > 1) {
            return recordIds.firstWhere((id) => id != selfRecordId);
          }
        } else {
          // Conflict with OTHER transaction
          return recordIds.first;
        }
      }
    }

    return null;
  }

  /// Check if a unique key is owned by another transaction (transaction-only check).
  ///
  /// This method only checks the global transaction index, NOT the main buffer.
  /// Useful when full index cache is marked, where committed data is already validated
  /// via cache, and we only need to check for transactional conflicts.
  ///
  /// Returns true if the key is owned by another transaction (or by another record
  /// in the same transaction if selfRecordId is provided).
  String? hasUniqueKeyOwnedByOtherTransaction(TableContext table,
      IndexUid indexUid, dynamic compositeKey, String? selfRecordId,
      {String? transactionId, dynamic internalKey}) {
    internalKey ??= _toInternalKey(compositeKey);
    final tableUid = table.tableUid;

    // Only check global transaction index (O(1))
    final globalOwners =
        _txnGlobalUniqueKeyOwners[tableUid]?[indexUid]?[internalKey];
    if (globalOwners != null && globalOwners.isNotEmpty) {
      for (final entry in globalOwners.entries) {
        final txId = entry.key;
        final recordIds = entry.value;
        if (recordIds.isEmpty) {
          continue;
        }

        // If checking against OWN transaction
        if (transactionId != null && txId == transactionId) {
          if (selfRecordId == null) return recordIds.first;
          if (!recordIds.contains(selfRecordId)) return recordIds.first;
          if (recordIds.length > 1) {
            return recordIds.firstWhere((id) => id != selfRecordId);
          }
        } else {
          // Conflict with OTHER transaction
          return recordIds.first;
        }
      }
    }

    return null;
  }

  /// Try to reserve unique keys for a record.
  /// If any key is already owned by another record, throws a UniqueViolation (or returns false/error).
  /// Returns the previous unique keys reserved for this record (if any), to allow restoration on failure.
  List<UniqueKeyRef>? tryReserveUniqueKeys({
    required TableContext table,
    required String recordId,
    required List<UniqueKeyRef> uniqueKeys,
    String? transactionId,
    bool isUpdate = false,
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
      final conflictId = hasUniqueKeyOwnedByOther(
          table, uk.indexUid, uk.compositeKey, isUpdate ? recordId : null,
          transactionId: transactionId, internalKey: internalKeys[i]);
      if (conflictId != null) {
        throw _uniqueViolationForKeyRef(table, uk, conflictId);
      }
    }

    // 2. Add keys to structures (and capture old keys)
    if (transactionId != null) {
      final tableUid = table.tableUid;
      final byTable = _txnBuffers.putIfAbsent(transactionId, () => {});
      final buf = byTable.putIfAbsent(tableUid, () => _TxnUniqueTableBuffer());

      // Capture old keys before they are removed by addTransactionUniqueKeys
      final oldKeys = buf.recordIdToUniqueKeys[recordId];

      addTransactionUniqueKeys(
          transactionId: transactionId,
          table: table,
          recordId: recordId,
          uniqueKeys: uniqueKeys,
          internalKeys: internalKeys);
      return oldKeys;
    } else {
      final buf = _ensureTable(table);
      final oldKeys = buf.recordIdToUniqueKeys[recordId];

      // Remove old keys if present (to ensure clean state like addRecord, though mostly additive here)
      // Actually strictly speaking, if we just overwrite map and add to owners, we leave garbage in owners.
      // We must remove old ownerships!
      if (oldKeys != null) {
        buf.recordIdToUniqueKeys.remove(recordId);
        for (final uk in oldKeys) {
          final internalKey = _toInternalKey(uk.compositeKey);
          buf.uniqueKeyOwners[uk.indexUid]?[internalKey]?.remove(recordId);
        }
      }

      buf.recordIdToUniqueKeys[recordId] = uniqueKeys;
      for (int i = 0; i < uniqueKeys.length; i++) {
        final uk = uniqueKeys[i];
        final internalKey = internalKeys[i];
        var set = buf.uniqueIndexEntries[uk.indexUid];
        if (set == null) {
          set = <dynamic>{};
          buf.uniqueIndexEntries[uk.indexUid] = set;
        }
        set.add(internalKey);

        var ownersByKey = buf.uniqueKeyOwners[uk.indexUid];
        if (ownersByKey == null) {
          ownersByKey = <dynamic, Set<String>>{};
          buf.uniqueKeyOwners[uk.indexUid] = ownersByKey;
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
    required TableContext table,
    required String recordId,
    String? transactionId,
    List<UniqueKeyRef>? restoreKeys,
  }) {
    final tableUid = table.tableUid;
    if (transactionId != null) {
      final byTable = _txnBuffers[transactionId];
      final buf = byTable?[tableUid];
      if (buf != null) {
        _removeTransactionUniqueKeysForRecord(
            transactionId, tableUid, recordId, buf);
      }
    } else {
      final buf = _buffersByTableUid[tableUid];
      if (buf != null) {
        final keys = buf.recordIdToUniqueKeys.remove(recordId);
        if (keys != null) {
          for (final uk in keys) {
            final internalKey = _toInternalKey(uk.compositeKey);
            final set = buf.uniqueIndexEntries[uk.indexUid];
            set?.remove(internalKey);
            if (set != null && set.isEmpty) {
              buf.uniqueIndexEntries.remove(uk.indexUid);
            }
            final ownersByKey = buf.uniqueKeyOwners[uk.indexUid];
            final owners = ownersByKey?[internalKey];
            owners?.remove(recordId);
            if (owners != null && owners.isEmpty) {
              ownersByKey?.remove(internalKey);
            }
            if (ownersByKey != null && ownersByKey.isEmpty) {
              buf.uniqueKeyOwners.remove(uk.indexUid);
            }
          }
        }
      }
    }

    if (restoreKeys != null && restoreKeys.isNotEmpty) {
      tryReserveUniqueKeys(
        table: table,
        recordId: recordId,
        uniqueKeys: restoreKeys,
        transactionId: transactionId,
      );
    }
  }

  /// High-performance batch update into buffer + ordered write queue.
  ///
  /// Notes:
  /// - All [entries] must be UPDATE operations with non-null WAL pointers.
  /// - Caller must ensure unique-key reservations are done before calling.
  Future<void> addUpdateBatch({
    required TableContext table,
    required List<String> recordIds,
    required List<BufferEntry> entries,
    required List<List<UniqueKeyRef>> uniqueKeysList,
  }) async {
    if (recordIds.isEmpty) return;
    if (recordIds.length != entries.length ||
        recordIds.length != uniqueKeysList.length) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message:
              'addUpdateBatch length mismatch: recordIds=${recordIds.length}, entries=${entries.length}, uniqueKeysList=${uniqueKeysList.length}',
          parameterName: 'recordIds/entries/uniqueKeysList',
          passedValue: {
            'recordIdsLength': recordIds.length,
            'entriesLength': entries.length,
            'uniqueKeysListLength': uniqueKeysList.length,
          },
        )
      ]);
    }

    final buf = _ensureTable(table);
    final yieldController =
        YieldController('WriteBufferManager.addUpdateBatch');
    final batchSize = _dataStore.config.writeBatchSize;
    final backpressureCap = batchSize > 0 ? batchSize * 2 : 20000;
    const int emitChunk = 1000;

    for (int i = 0; i < recordIds.length; i++) {
      await yieldController.maybeYield();
      if (i % emitChunk == 0) {
        await _dataStore.parallelJournalManager.waitIfThrottled(emitChunk);
        await _dataStore.parallelJournalManager.waitUntilQueueBelow(
          backpressureCap,
          timeout: const Duration(seconds: 120),
        );
      }

      final recordId = recordIds[i];
      final entry = entries[i];
      final uniqueKeys = uniqueKeysList[i];

      // Handle insert-then-update merge logic
      final prior = buf.records[recordId];
      BufferEntry effectiveEntry = entry;
      bool skipQueueEnqueue = false;

      if (prior != null) {
        if (prior.operation == BufferOperationType.insert) {
          // Merge UPDATE into existing INSERT
          final mergedData = Map<String, dynamic>.from(prior.data);
          mergedData.addAll(entry.data);

          effectiveEntry = BufferEntry(
            data: mergedData,
            operation: BufferOperationType.insert,
            timestamp: prior.timestamp,
            transactionId: prior.transactionId,
            walPointer: prior.walPointer,
            oldValues: null,
            schemaVersion: entry.schemaVersion,
          );
          skipQueueEnqueue = true; // Insert is already in queue
        } else if (prior.operation == BufferOperationType.update) {
          // Merge UPDATE into existing UPDATE
          final mergedData = Map<String, dynamic>.from(prior.data);
          mergedData.addAll(entry.data);

          effectiveEntry = BufferEntry(
            data: mergedData,
            operation: BufferOperationType.update,
            timestamp: prior.timestamp,
            transactionId: prior.transactionId,
            walPointer: prior.walPointer,
            oldValues: prior.oldValues ?? entry.oldValues,
            schemaVersion: entry.schemaVersion,
          );
        }
      }

      // 1) Update buffer storage
      buf.records[recordId] = effectiveEntry;

      // Maintain insertedKeys status (crucial for coalesced INSERT+UPDATE)
      if (effectiveEntry.operation == BufferOperationType.insert) {
        buf.insertedKeys.add(recordId);
      } else {
        buf.insertedKeys.remove(recordId);
      }

      // 2) Update unique indexes (thoroughly remove old, then add new)
      final existingKeys = buf.recordIdToUniqueKeys.remove(recordId);
      if (existingKeys != null) {
        for (final uk in existingKeys) {
          final internalKey = uk.internalKey;

          // Remove from index entries
          final set = buf.uniqueIndexEntries[uk.indexUid];
          set?.remove(internalKey);
          if (set != null && set.isEmpty) {
            buf.uniqueIndexEntries.remove(uk.indexUid);
          }

          // Remove from owners map
          final ownersByKey = buf.uniqueKeyOwners[uk.indexUid];
          final owners = ownersByKey?[internalKey];
          owners?.remove(recordId);
          if (owners != null && owners.isEmpty) {
            ownersByKey?.remove(internalKey);
          }
          if (ownersByKey != null && ownersByKey.isEmpty) {
            buf.uniqueKeyOwners.remove(uk.indexUid);
          }
        }
      }

      if (uniqueKeys.isNotEmpty) {
        buf.recordIdToUniqueKeys[recordId] = uniqueKeys;
        for (final uk in uniqueKeys) {
          final internalKey = uk.internalKey;
          buf.uniqueIndexEntries
              .putIfAbsent(uk.indexUid, () => <dynamic>{})
              .add(internalKey);
          buf.uniqueKeyOwners
              .putIfAbsent(uk.indexUid, () => <dynamic, Set<String>>{})
              .putIfAbsent(internalKey, () => <String>{})
              .add(recordId);
        }
      }

      // 3) Enqueue for write
      if (!skipQueueEnqueue) {
        _writeQueue.add(WriteQueueEntry(
          tableUid: table.tableUid,
          recordId: recordId,
          operationType: effectiveEntry.operation,
          walPointer: effectiveEntry.walPointer!,
        ));
      }
    }

    _emitSizeChanged();
    CrontabManager.notifyActivity();
  }

  /// Adds a batch of delete operations to the write buffer.
  Future<void> addDeleteBatch({
    required TableContext table,
    required List<String> recordIds,
    required List<BufferEntry> entries,
  }) async {
    if (recordIds.isEmpty) return;
    if (recordIds.length != entries.length) {
      throw DbException([
        InvalidArgumentStatus(
          type: ResultType.engError,
          message:
              'addDeleteBatch length mismatch: recordIds=${recordIds.length}, entries=${entries.length}',
          parameterName: 'recordIds/entries',
          passedValue: {
            'recordIdsLength': recordIds.length,
            'entriesLength': entries.length,
          },
        )
      ]);
    }

    // Update record count once (batch optimized).
    await _dataStore.tableDataManager.updateTableRecordCountDelta(
      table,
      deleteDelta: recordIds.length,
    );

    final buf = _ensureTable(table);
    final yieldController =
        YieldController('WriteBufferManager.addDeleteBatch');
    final batchSize = _dataStore.config.writeBatchSize;
    final backpressureCap = batchSize > 0 ? batchSize * 2 : 20000;
    const int emitChunk = 1000;

    for (int i = 0; i < recordIds.length; i++) {
      await yieldController.maybeYield();
      if (i % emitChunk == 0) {
        await _dataStore.parallelJournalManager.waitIfThrottled(emitChunk);
        await _dataStore.parallelJournalManager.waitUntilQueueBelow(
          backpressureCap,
          timeout: const Duration(seconds: 120),
        );
      }

      final recordId = recordIds[i];
      final entry = entries[i];

      // 1. Handle Operation Coalescing (Merge/Cancel)
      final prior = buf.records[recordId];
      bool skipBufferStore = false;

      if (prior != null && prior.operation == BufferOperationType.insert) {
        // Cancel: drop the pending INSERT from buffer
        // Note: The insert is already in the queue, so we must still enqueue a delete
        // to tombstone it in WAL during flush.
        buf.records.remove(recordId);
        skipBufferStore = true;
      }

      // 2. Clean up Unique Key Index Reservations
      // When a record is deleted, we must release its unique keys in the buffer.
      final existingUniqueKeys = buf.recordIdToUniqueKeys.remove(recordId);
      if (existingUniqueKeys != null) {
        for (final uk in existingUniqueKeys) {
          final internalKey = _toInternalKey(uk.compositeKey);
          final set = buf.uniqueIndexEntries[uk.indexUid];
          set?.remove(internalKey);
          if (set != null && set.isEmpty) {
            buf.uniqueIndexEntries.remove(uk.indexUid);
          }
          final ownersByKey = buf.uniqueKeyOwners[uk.indexUid];
          final owners = ownersByKey?[internalKey];
          owners?.remove(recordId);
          if (owners != null && owners.isEmpty) {
            ownersByKey?.remove(internalKey);
          }
          if (ownersByKey != null && ownersByKey.isEmpty) {
            buf.uniqueKeyOwners.remove(uk.indexUid);
          }
        }
      }

      // 3. Update Buffer State
      buf.insertedKeys.remove(recordId);
      if (!skipBufferStore) {
        buf.records[recordId] = entry;
      }

      // 4. Enqueue to Write Queue (as a tombstone)
      _writeQueue.add(WriteQueueEntry(
        tableUid: table.tableUid,
        recordId: recordId,
        operationType: entry.operation,
        walPointer: entry.walPointer!,
      ));
    }

    _emitSizeChanged();
    CrontabManager.notifyActivity();
  }
}

class _TxnUniqueTableBuffer {
  // indexUid -> internalKey -> Set<recordId>
  final Map<IndexUid, Map<dynamic, Set<String>>> uniqueKeyOwners = {};
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
