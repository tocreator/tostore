import 'dart:async';
import 'dart:math';

import '../handler/logger.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import '../model/background_write_entry.dart';
import '../model/migration_write_mode.dart';
import '../model/background_write_type.dart';
import '../model/buffer_entry.dart';
import '../model/cancellation_token.dart';
import '../model/change_event.dart';
import '../model/expr.dart';
import '../model/foreign_key_operation.dart';
import '../model/table_identity.dart';
import '../model/table_schema.dart';
import '../query/query_condition.dart';
import 'compute/batch_match_runner.dart';
import 'compute/record_compute.dart';
import 'data_store_impl.dart';
import 'resource_manager.dart';
import 'yield_controller.dart';
import '../model/data_store_config.dart';

/// In-memory request for a single large-scale data delete (not persisted to WAL).
class LargeDeleteRequest {
  final String opId;
  final TableUid tableUid;
  final Map<String, dynamic> condition;
  final List<String>? orderBy;
  final int? limit;
  final int? offset;

  const LargeDeleteRequest({
    required this.opId,
    required this.tableUid,
    required this.condition,
    this.orderBy,
    this.limit,
    this.offset,
  });
}

/// In-memory request for a single large-scale data update (not persisted to WAL).
class LargeUpdateRequest {
  final String opId;
  final TableUid tableUid;
  final Map<String, dynamic> condition;
  final Map<String, dynamic> updateData;
  final List<String>? orderBy;
  final int? limit;
  final int? offset;
  final bool continueOnPartialErrors;

  const LargeUpdateRequest({
    required this.opId,
    required this.tableUid,
    required this.condition,
    required this.updateData,
    this.orderBy,
    this.limit,
    this.offset,
    this.continueOnPartialErrors = false,
  });
}

/// Outcome of a user-awaited large-scale data operation.
///
/// Errors are returned here instead of thrown so cooperative pause/shutdown and
/// other non-user waiters never see uncaught exceptions. User call sites convert
/// this into [DbResult] for the caller.
class LargeOperationOutcome {
  final int successCount;
  final List<ResultStatus> errorStatuses;

  const LargeOperationOutcome._({
    required this.successCount,
    required this.errorStatuses,
  });

  factory LargeOperationOutcome.ok(int successCount) => LargeOperationOutcome._(
        successCount: successCount,
        errorStatuses: const [],
      );

  factory LargeOperationOutcome.fail(
    List<ResultStatus> errorStatuses, {
    int successCount = 0,
  }) =>
      LargeOperationOutcome._(
        successCount: successCount,
        errorStatuses: errorStatuses,
      );

  bool get hasErrors => errorStatuses.isNotEmpty;
}

/// Blocking large-scale data operation executor.
///
/// Processes delete/update batches via [BackgroundWriteScheduler] and awaits drain
/// until disk writes for the operation complete. Intended to be **awaited by user
/// write APIs** that convert [LargeOperationOutcome] into [DbResult].
/// Cooperative pause/shutdown waiters must not rely on thrown exceptions.
class LargeOperationRunner {
  LargeOperationRunner._();

  static final Map<String, CancellationToken> _activeTokens = {};
  static final Map<String, Future<void>> _activeTasks = {};
  static final Set<String> _runningOpIds = {};
  static final Map<String, TableUid> _opTableUids = {};

  /// Check if a specific large-scale data operation is currently running.
  static bool isOperationRunning(String opId) => _runningOpIds.contains(opId);

  /// Check if any large-scale data operation is running for [tableUid].
  static bool isTableOperationRunning(TableUid tableUid) {
    for (final uid in _opTableUids.values) {
      if (uid == tableUid) return true;
    }
    return false;
  }

  /// Resolve table uid for a running [opId] (e.g. MigrationManager flush callbacks).
  static TableUid? tableUidForOpId(String opId) => _opTableUids[opId];

  /// Request cooperative pause for all tasks in a specific space.
  static void requestPause(String spaceName) {
    _activeTokens[spaceName]?.cancel();
  }

  /// Request cooperative pause for all tasks in a specific space and wait for them to finish.
  static Future<bool> pauseAndAwait(String spaceName) async {
    final token = _activeTokens[spaceName];
    if (token == null && !_activeTasks.containsKey(spaceName)) {
      return false;
    }
    token?.cancel();
    final task = _activeTasks[spaceName];
    if (task != null) {
      try {
        await task;
      } catch (_) {}
    }
    return true;
  }

  /// Cooperatively pause ongoing large-scale data operations for switch space or shutdown.
  ///
  /// Scheduler cleanup is left to the caller ([DataStoreImpl.close] uses
  /// [BackgroundWriteScheduler.clearAll]).
  static Future<void> pauseForShutdown(DataStoreImpl dataStore) async {
    final space = dataStore.currentSpaceName;
    final hasActive =
        _activeTokens.containsKey(space) || _activeTasks.containsKey(space);
    if (!hasActive) return;
    requestPause(space);

    final task = _activeTasks[space];
    if (task != null) {
      try {
        await task;
      } catch (_) {}
    }

    Logger.info('Large-scale data operations stopped for space [$space].');
  }

  /// Run one large-scale data delete; blocks until batches drained to disk.
  ///
  /// Returns [LargeOperationOutcome] (never throws for business/interrupt failures).
  static Future<LargeOperationOutcome> runLargeDelete(
    DataStoreImpl dataStore,
    LargeDeleteRequest op,
  ) async {
    final space = dataStore.currentSpaceName;
    return _withSpaceLock(space, (token) async {
      _runningOpIds.add(op.opId);
      _opTableUids[op.opId] = op.tableUid;
      try {
        final count = await _executeLargeDelete(dataStore, op, token);
        return LargeOperationOutcome.ok(count);
      } on DbClosedException catch (e) {
        Logger.info(
            'Large-scale data delete interrupted by database close (opId: ${op.opId}).');
        return LargeOperationOutcome.fail([
          GeneralStatus(
            type: ResultType.sysDbClosed,
            message: e.toString(),
          ),
        ]);
      } on DbException catch (e) {
        Logger.error('Large-scale data delete failed (opId: ${op.opId})',
            rawError: e);
        return LargeOperationOutcome.fail(e.statuses);
      } catch (e) {
        Logger.error('Large-scale data delete failed (opId: ${op.opId})',
            rawError: e);
        return LargeOperationOutcome.fail(
          DbException.wrap(
            e,
            fallbackMessage: 'Large-scale data delete failed',
          ).statuses,
        );
      } finally {
        _runningOpIds.remove(op.opId);
        _opTableUids.remove(op.opId);
      }
    });
  }

  /// Run one large-scale data update; blocks until batches drained.
  ///
  /// Returns [LargeOperationOutcome] (never throws for business/interrupt failures).
  static Future<LargeOperationOutcome> runLargeUpdate(
    DataStoreImpl dataStore,
    LargeUpdateRequest op,
  ) async {
    final space = dataStore.currentSpaceName;
    return _withSpaceLock(space, (token) async {
      _runningOpIds.add(op.opId);
      _opTableUids[op.opId] = op.tableUid;
      try {
        final count = await _executeLargeUpdate(dataStore, op, token);
        return LargeOperationOutcome.ok(count);
      } on DbClosedException catch (e) {
        Logger.info(
            'Large-scale data update interrupted by database close (opId: ${op.opId}).');
        return LargeOperationOutcome.fail([
          GeneralStatus(
            type: ResultType.sysDbClosed,
            message: e.toString(),
          ),
        ]);
      } on DbException catch (e) {
        Logger.error('Large-scale data update failed (opId: ${op.opId})',
            rawError: e);
        return LargeOperationOutcome.fail(e.statuses);
      } catch (e) {
        Logger.error('Large-scale data update failed (opId: ${op.opId})',
            rawError: e);
        return LargeOperationOutcome.fail(
          DbException.wrap(
            e,
            fallbackMessage: 'Large-scale data update failed',
          ).statuses,
        );
      } finally {
        _runningOpIds.remove(op.opId);
        _opTableUids.remove(op.opId);
      }
    });
  }

  /// Serialize large-scale data operations: one active op at a time per [spaceName].
  static Future<T> _withSpaceLock<T>(
    String spaceName,
    Future<T> Function(CancellationToken token) action,
  ) async {
    final previous = _activeTasks[spaceName];
    final gate = Completer<void>();
    _activeTasks[spaceName] = gate.future;

    if (previous != null) {
      try {
        await previous;
      } catch (_) {}
    }

    final token = CancellationToken();
    _activeTokens[spaceName] = token;
    try {
      return await action(token);
    } finally {
      if (identical(_activeTokens[spaceName], token)) {
        _activeTokens.remove(spaceName);
      }
      if (identical(_activeTasks[spaceName], gate.future)) {
        _activeTasks.remove(spaceName);
      }
      if (!gate.isCompleted) {
        gate.complete();
      }
    }
  }

  static void _throwIfInterrupted(
    DataStoreImpl dataStore,
    CancellationToken token,
    String opKind,
  ) {
    // Cooperative stop uses DbClosedException as control-flow (same as migration).
    if (!dataStore.isInitialized || dataStore.isClosing) {
      throw DbClosedException(
        'Large-scale data $opKind was interrupted because the database is closed; '
        'caller must retry the operation.',
      );
    }
    if (token.isCancelled) {
      throw DbClosedException(
        'Large-scale data $opKind was interrupted; caller must retry the operation.',
      );
    }
  }

  static Future<int> _executeLargeDelete(
    DataStoreImpl dataStore,
    LargeDeleteRequest op,
    CancellationToken token,
  ) async {
    _throwIfInterrupted(dataStore, token, 'delete');

    final table =
        await dataStore.tableMetaManager?.getTableContext(op.tableUid);
    if (table == null) {
      throw DbException([
        GeneralStatus(
          type: ResultType.devTableNotFound,
          message:
              'Large-scale data delete failed: table not found (tableUid: ${op.tableUid.value}, opId: ${op.opId}).',
        ),
      ]);
    }

    Logger.info(
        'Starting large-scale data delete for table [${table.tableName}] (opId: ${op.opId}).');

    final schema = table.schema;
    final primaryKey = schema.primaryKey;
    int deletedCount = 0;
    int skippedForOffset = 0;
    final offsetBudget = op.offset ?? 0;
    final conditionMap = op.condition;
    final writeBatchSize = dataStore.config.writeBatchSize;

    try {
      await dataStore.queryExecutor.queryEachBatch(
        table,
        batchSize: writeBatchSize,
        cancellationToken: token,
        orderBy: op.orderBy,
        condition: QueryCondition.fromMap(conditionMap),
        onBatch: (records, currentCursor, nextCursor) async {
          _throwIfInterrupted(dataStore, token, 'delete');

          await dataStore.backgroundWriteScheduler.waitIfCongested(
            writeBatchSize: writeBatchSize,
            normalQueueLength: dataStore.writeBufferManager.queueLength,
            isMemoryMode:
                dataStore.config.persistenceMode == PersistenceMode.memory,
            getMemoryStatus: () =>
                dataStore.resourceManager?.memoryStatus ??
                ResourceStatus.normal,
            refreshResourceStatus: () =>
                dataStore.resourceManager?.triggerImmediateCheck() ??
                Future<void>.value(),
            cancellationToken: token,
          );

          _throwIfInterrupted(dataStore, token, 'delete');

          if (records.isEmpty) return true;

          final remainingOffset = max(0, offsetBudget - skippedForOffset);
          final remainingLimit =
              op.limit == null ? null : max(0, op.limit! - deletedCount);
          if (remainingLimit != null && remainingLimit == 0) {
            return false;
          }

          final remainingMatchBudget =
              remainingLimit == null ? null : remainingOffset + remainingLimit;

          // Perform batch index matching
          final matchResult = await ConditionBatchMatcher.matchRecordIndices(
            schema: schema,
            table: table,
            condition: conditionMap,
            records: records,
            estimateRecordBytes:
                dataStore.tableDataManager.resolveRecordSizeBytes,
            maxMatchCount: remainingMatchBudget,
          );

          final deletes = <Map<String, dynamic>>[];
          final yieldController = YieldController('LargeScaleDelete.process');

          for (final matchedIndex in matchResult.matchedIndices) {
            _throwIfInterrupted(dataStore, token, 'delete');
            final y1 = yieldController.maybeYield();
            if (y1 != null) await y1;

            final record = records[matchedIndex];
            final pkValue = record[primaryKey];
            if (pkValue == null) continue;
            final pkValueStr = pkValue.toString();

            if (skippedForOffset < offsetBudget) {
              skippedForOffset++;
              continue;
            }

            if (op.limit != null && deletedCount >= op.limit!) {
              return false;
            }

            // Foreign Key Checks and Cascades
            if (dataStore.foreignKeyManager != null) {
              try {
                await dataStore.foreignKeyManager!
                    .checkRestrictConstraintsForDelete(
                  table: table,
                  deletedPkValues: pkValue,
                );
              } catch (e) {
                Logger.error(
                    'RESTRICT constraint check failed in large-scale data delete',
                    rawError: e);
                rethrow;
              }

              try {
                await dataStore.foreignKeyManager!.handleCascadeDelete(
                  table: table,
                  deletedPkValues: pkValue,
                  skipRestrictCheck: true,
                );
              } catch (e) {
                Logger.error('Cascade delete failed in large-scale data delete',
                    rawError: e);
                rethrow;
              }
            }

            deletedCount++;
            deletes.add(record);

            if (dataStore.notificationManager.hasListeners(schema.tableUid)) {
              dataStore.notificationManager.notify(ChangeEvent(
                type: ChangeType.delete,
                tableUid: schema.tableUid,
                oldRecord: record,
              ));
            }

            dataStore.tableDataManager
                .removeRecordFromBuffer(table, pkValueStr);
          }

          if (deletes.isEmpty) {
            return true;
          }

          var entryVersion = schema.schemaVersion ?? '';
          if (dataStore.migrationManager?.hasRuntimeMigrationForTable(table) ??
              false) {
            entryVersion = '';
          }

          // Populate scheduler for batch flushing
          for (final record in deletes) {
            _throwIfInterrupted(dataStore, token, 'delete');
            final pkValueStr = record[primaryKey].toString();
            final entry = BufferEntry(
              operation: BufferOperationType.delete,
              data: record,
              timestamp: DateTime.now(),
              schemaVersion: entryVersion,
            );
            dataStore.backgroundWriteScheduler.addEntry(
              BackgroundWriteEntry(
                taskId: op.opId,
                tableUid: table.tableUid,
                primaryKey: pkValueStr,
                type: BackgroundWriteType.largeDelete,
                mode: MigrationWriteMode.tableAndIndex,
                entry: entry,
                currentCursor: nextCursor,
                nextCursor: nextCursor,
              ),
              pkValueStr,
            );
          }

          dataStore.parallelJournalManager.scheduleFlushIfNeeded();
          return true;
        },
      );

      _throwIfInterrupted(dataStore, token, 'delete');

      // Drain all enqueued background write records for this task to disk
      await _drainOpBackgroundWrites(dataStore, op.opId, token);

      _throwIfInterrupted(dataStore, token, 'delete');

      Logger.info(
          'Large-scale data delete completed for table [${table.tableName}] '
          '(opId: ${op.opId}, count: $deletedCount).');
      return deletedCount;
    } catch (e) {
      if (e is! DbClosedException) {
        Logger.error('Large-scale data delete failed for ${op.opId}',
            rawError: e);
      }
      rethrow;
    }
  }

  static Future<int> _executeLargeUpdate(
    DataStoreImpl dataStore,
    LargeUpdateRequest op,
    CancellationToken token,
  ) async {
    _throwIfInterrupted(dataStore, token, 'update');

    final table =
        await dataStore.tableMetaManager?.getTableContext(op.tableUid);
    if (table == null) {
      throw DbException([
        GeneralStatus(
          type: ResultType.devTableNotFound,
          message:
              'Large-scale data update failed: table not found (tableUid: ${op.tableUid.value}, opId: ${op.opId}).',
        ),
      ]);
    }

    Logger.info(
        'Starting large-scale data update for table [${table.tableName}] (opId: ${op.opId}).');

    final schema = table.schema;
    final primaryKey = schema.primaryKey;
    int updatedCount = 0;
    int skippedForOffset = 0;
    final offsetBudget = op.offset ?? 0;
    final conditionMap = op.condition;
    final validData = op.updateData;
    final writeBatchSize = dataStore.config.writeBatchSize;

    final isPrimaryKeyUpdate = validData.containsKey(primaryKey);
    final insertedPrimaryKeysThisUpdate = <String>{};

    final Set<String> uniqueFieldsToCheck = <String>{};
    if (dataStore.indexManager != null) {
      final allIndexes =
          dataStore.tableMetaManager?.getUniqueIndexesFor(schema) ??
              <IndexSchema>[];
      for (final index in allIndexes) {
        if (index.fields
            .any((f) => validData.containsKey(f) && validData[f] is ExprNode)) {
          uniqueFieldsToCheck.addAll(index.fields);
        }
      }
    }

    try {
      await dataStore.queryExecutor.queryEachBatch(
        table,
        batchSize: writeBatchSize,
        cancellationToken: token,
        orderBy: op.orderBy,
        condition: QueryCondition.fromMap(conditionMap),
        onBatch: (records, currentCursor, nextCursor) async {
          _throwIfInterrupted(dataStore, token, 'update');

          await dataStore.backgroundWriteScheduler.waitIfCongested(
            writeBatchSize: writeBatchSize,
            normalQueueLength: dataStore.writeBufferManager.queueLength,
            isMemoryMode:
                dataStore.config.persistenceMode == PersistenceMode.memory,
            getMemoryStatus: () =>
                dataStore.resourceManager?.memoryStatus ??
                ResourceStatus.normal,
            refreshResourceStatus: () =>
                dataStore.resourceManager?.triggerImmediateCheck() ??
                Future<void>.value(),
            cancellationToken: token,
          );

          _throwIfInterrupted(dataStore, token, 'update');

          if (records.isEmpty) return true;

          final remainingOffset = max(0, offsetBudget - skippedForOffset);
          final remainingLimit =
              op.limit == null ? null : max(0, op.limit! - updatedCount);
          if (remainingLimit != null && remainingLimit == 0) {
            return false;
          }

          final remainingMatchBudget =
              remainingLimit == null ? null : remainingOffset + remainingLimit;

          // Perform batch index matching
          final matchResult = await ConditionBatchMatcher.matchRecordIndices(
            schema: schema,
            table: table,
            condition: conditionMap,
            records: records,
            estimateRecordBytes:
                dataStore.tableDataManager.resolveRecordSizeBytes,
            maxMatchCount: remainingMatchBudget,
          );

          final matchedRecords = <Map<String, dynamic>>[];

          for (final matchedIndex in matchResult.matchedIndices) {
            final candidate = records[matchedIndex];
            final candidatePk = candidate[primaryKey]?.toString();
            if (candidatePk != null &&
                insertedPrimaryKeysThisUpdate.contains(candidatePk)) {
              continue;
            }
            if (skippedForOffset < offsetBudget) {
              skippedForOffset++;
              continue;
            }
            if (op.limit != null &&
                updatedCount + matchedRecords.length >= op.limit!) {
              break;
            }
            matchedRecords.add(candidate);
          }

          if (matchedRecords.isEmpty) return true;

          final updates = <Map<String, dynamic>>[];
          final deletes = <Map<String, dynamic>>[];
          final inserts = <Map<String, dynamic>>[];
          // PKs reserved in this chunk but not yet handed to scheduler.
          final chunkReservedPks = <String>{};

          Future<void> releaseChunkReservations() async {
            await dataStore.writeBufferManager.releaseReservedUniquesForPks(
              table: table,
              recordIds: chunkReservedPks,
            );
            chunkReservedPks.clear();
          }

          final applyYieldController =
              YieldController('LargeScaleUpdate.process');

          for (int matchedIndex = 0;
              matchedIndex < matchedRecords.length;
              matchedIndex++) {
            if (token.isCancelled ||
                !dataStore.isInitialized ||
                dataStore.isClosing) {
              await releaseChunkReservations();
              _throwIfInterrupted(dataStore, token, 'update');
            }
            final y2 = applyYieldController.maybeYield();
            if (y2 != null) await y2;

            if (op.limit != null && updatedCount >= op.limit!) {
              break;
            }

            final record = matchedRecords[matchedIndex];
            var updatedRecord = applyUniformUpdatePure(
              schema: schema,
              validData: validData,
              existingRecord: record,
            );
            final pkValue = record[primaryKey];
            if (pkValue == null) continue;
            final pkValueStr = pkValue.toString();

            List<List<dynamic>>? reservedKeys;
            // Verify unique constraints
            if (uniqueFieldsToCheck.isNotEmpty &&
                dataStore.indexManager != null &&
                !isPrimaryKeyUpdate) {
              try {
                reservedKeys = dataStore.writeBufferManager.tryReserveUniques(
                  table: table,
                  schema: schema,
                  recordId: pkValueStr,
                  data: updatedRecord,
                  isUpdate: true,
                  changedFields: validData.keys.toSet(),
                );
                chunkReservedPks.add(pkValueStr);
              } catch (e) {
                Logger.error(
                    'Unique constraint check failed in large-scale data update reserve',
                    rawError: e);
                if (op.continueOnPartialErrors) {
                  Logger.warn(
                      'Skip updating record with PK $pkValueStr due to unique constraint conflict',
                      rawError: e);
                  continue;
                }
                await releaseChunkReservations();
                rethrow;
              }

              try {
                final violation =
                    await dataStore.indexManager!.checkUniqueConstraints(
                  table,
                  updatedRecord,
                  isUpdate: true,
                  skipBufferCheck: true,
                );
                if (violation != null) {
                  throw DbException([
                    ConstraintStatus(
                      type: violation.constraintResultType,
                      message: violation.message,
                      tableName: table.tableName,
                      constraintName: violation.indexName?.value,
                      fields: violation.fields,
                      conflictingKeys: [violation.value],
                      primaryKey: pkValueStr,
                    ),
                  ]);
                }
              } catch (e) {
                try {
                  dataStore.writeBufferManager.releaseReservedUniques(
                    table: table,
                    recordId: pkValueStr,
                    rollbackKeys: reservedKeys,
                  );
                } catch (_) {}
                chunkReservedPks.remove(pkValueStr);
                Logger.error(
                    'Unique constraint check failed in large-scale data update',
                    rawError: e);
                if (op.continueOnPartialErrors) {
                  Logger.warn(
                      'Skip updating record with PK $pkValueStr due to unique constraint conflict',
                      rawError: e);
                  continue;
                }
                await releaseChunkReservations();
                rethrow;
              }
            }

            // Verify and check primary key update unique constraints with reservation
            if (isPrimaryKeyUpdate) {
              final newPkVal = updatedRecord[primaryKey]?.toString();
              if (newPkVal != null && newPkVal != pkValueStr) {
                List<List<dynamic>>? pkReservedKeys;
                try {
                  pkReservedKeys =
                      dataStore.writeBufferManager.tryReserveUniques(
                    table: table,
                    schema: schema,
                    recordId: newPkVal,
                    data: updatedRecord,
                    isUpdate: false,
                  );
                  chunkReservedPks.add(newPkVal);
                } catch (e) {
                  Logger.error(
                      'Unique constraint check failed in primary key update reserve',
                      rawError: e);
                  if (op.continueOnPartialErrors) {
                    Logger.warn(
                        'Skip primary key update for record with PK $pkValueStr due to unique conflict',
                        rawError: e);
                    continue;
                  }
                  await releaseChunkReservations();
                  rethrow;
                }

                try {
                  final violation =
                      await dataStore.indexManager!.checkUniqueConstraints(
                    table,
                    updatedRecord,
                    isUpdate: true,
                    skipBufferCheck: true,
                  );
                  if (violation != null) {
                    throw DbException([
                      ConstraintStatus(
                        type: violation.constraintResultType,
                        message: violation.message,
                        tableName: table.tableName,
                        constraintName: violation.indexName?.value,
                        fields: violation.fields,
                        conflictingKeys: [violation.value],
                        primaryKey: newPkVal,
                      ),
                    ]);
                  }
                } catch (e) {
                  try {
                    dataStore.writeBufferManager.releaseReservedUniques(
                      table: table,
                      recordId: newPkVal,
                      rollbackKeys: pkReservedKeys,
                    );
                  } catch (_) {}
                  chunkReservedPks.remove(newPkVal);
                  Logger.error(
                      'Unique constraint check failed in primary key update',
                      rawError: e);
                  if (op.continueOnPartialErrors) {
                    Logger.warn(
                        'Skip primary key update for record with PK $pkValueStr due to unique conflict',
                        rawError: e);
                    continue;
                  }
                  await releaseChunkReservations();
                  rethrow;
                }

                // Check restrict and cascade update for primary key updates
                if (dataStore.foreignKeyManager != null) {
                  try {
                    await dataStore.foreignKeyManager!
                        .checkRestrictConstraintsForUpdate(
                      table: table,
                      oldPkValues: pkValueStr,
                    );
                  } catch (e) {
                    dataStore.writeBufferManager.releaseReservedUniques(
                      table: table,
                      recordId: newPkVal,
                      rollbackKeys: pkReservedKeys,
                    );
                    chunkReservedPks.remove(newPkVal);
                    Logger.error(
                        'RESTRICT constraint check failed in primary key update',
                        rawError: e);
                    if (op.continueOnPartialErrors) continue;
                    await releaseChunkReservations();
                    rethrow;
                  }

                  try {
                    await dataStore.foreignKeyManager!.handleCascadeUpdate(
                      table: table,
                      oldPkValues: pkValueStr,
                      newPkValues: newPkVal,
                    );
                  } catch (e) {
                    dataStore.writeBufferManager.releaseReservedUniques(
                      table: table,
                      recordId: newPkVal,
                      rollbackKeys: pkReservedKeys,
                    );
                    chunkReservedPks.remove(newPkVal);
                    Logger.error(
                        'Cascade update failed in large-scale data update',
                        rawError: e);
                    if (op.continueOnPartialErrors) continue;
                    await releaseChunkReservations();
                    rethrow;
                  }
                }

                deletes.add(record);
                inserts.add(updatedRecord);
                insertedPrimaryKeysThisUpdate.add(newPkVal);
              } else {
                updates.add(updatedRecord);
              }
            } else {
              updates.add(updatedRecord);
            }

            // Validate foreign key constraints for fields in updatedRecord
            if (dataStore.foreignKeyManager != null) {
              try {
                await dataStore.foreignKeyManager!
                    .validateForeignKeyConstraints(
                  table: table,
                  data: updatedRecord,
                  operation: ForeignKeyOperation.update,
                );
              } catch (e) {
                if (reservedKeys != null) {
                  dataStore.writeBufferManager.releaseReservedUniques(
                    table: table,
                    recordId: pkValueStr,
                    rollbackKeys: reservedKeys,
                  );
                  chunkReservedPks.remove(pkValueStr);
                }
                // PK-change path reserved under newPk
                final newPkVal = updatedRecord[primaryKey]?.toString();
                if (isPrimaryKeyUpdate &&
                    newPkVal != null &&
                    newPkVal != pkValueStr) {
                  dataStore.writeBufferManager.releaseReservedUniques(
                    table: table,
                    recordId: newPkVal,
                  );
                  chunkReservedPks.remove(newPkVal);
                  deletes.remove(record);
                  inserts.remove(updatedRecord);
                } else {
                  updates.remove(updatedRecord);
                }
                Logger.error(
                    'Foreign key check failed in large-scale data update',
                    rawError: e);
                if (op.continueOnPartialErrors) continue;
                await releaseChunkReservations();
                rethrow;
              }
            }

            updatedCount++;

            if (dataStore.notificationManager.hasListeners(schema.tableUid)) {
              dataStore.notificationManager.notify(ChangeEvent(
                type: ChangeType.update,
                tableUid: schema.tableUid,
                record: updatedRecord,
                oldRecord: record,
              ));
            }

            dataStore.tableDataManager
                .removeRecordFromBuffer(table, pkValueStr);
          }

          var entryVersion = schema.schemaVersion ?? '';
          if (dataStore.migrationManager?.hasRuntimeMigrationForTable(table) ??
              false) {
            entryVersion = '';
          }

          // Populate scheduler
          for (final record in deletes) {
            if (token.isCancelled ||
                !dataStore.isInitialized ||
                dataStore.isClosing) {
              await releaseChunkReservations();
              _throwIfInterrupted(dataStore, token, 'update');
            }
            final pk = record[primaryKey].toString();
            final entry = BufferEntry(
              operation: BufferOperationType.delete,
              data: record,
              timestamp: DateTime.now(),
              schemaVersion: entryVersion,
            );
            dataStore.backgroundWriteScheduler.addEntry(
              BackgroundWriteEntry(
                taskId: op.opId,
                tableUid: table.tableUid,
                primaryKey: pk,
                type: BackgroundWriteType.largeUpdate,
                mode: MigrationWriteMode.tableAndIndex,
                entry: entry,
                currentCursor: nextCursor,
                nextCursor: nextCursor,
              ),
              pk,
            );
          }

          for (final record in inserts) {
            if (token.isCancelled ||
                !dataStore.isInitialized ||
                dataStore.isClosing) {
              await releaseChunkReservations();
              _throwIfInterrupted(dataStore, token, 'update');
            }
            final pk = record[primaryKey].toString();
            final entry = BufferEntry(
              operation: BufferOperationType.insert,
              data: record,
              timestamp: DateTime.now(),
              schemaVersion: entryVersion,
            );
            dataStore.backgroundWriteScheduler.addEntry(
              BackgroundWriteEntry(
                taskId: op.opId,
                tableUid: table.tableUid,
                primaryKey: pk,
                type: BackgroundWriteType.largeUpdate,
                mode: MigrationWriteMode.tableAndIndex,
                entry: entry,
                currentCursor: nextCursor,
                nextCursor: nextCursor,
              ),
              pk,
            );
            // Handed to scheduler/flush; do not release here.
            chunkReservedPks.remove(pk);
          }

          for (final record in updates) {
            if (token.isCancelled ||
                !dataStore.isInitialized ||
                dataStore.isClosing) {
              await releaseChunkReservations();
              _throwIfInterrupted(dataStore, token, 'update');
            }
            final pk = record[primaryKey].toString();
            final oldRecord =
                records.firstWhere((r) => r[primaryKey].toString() == pk);

            final entry = BufferEntry(
              operation: BufferOperationType.update,
              data: record,
              timestamp: DateTime.now(),
              // Pass the complete old record directly to avoid partial index oldValues missing
              oldValues: oldRecord,
              schemaVersion: entryVersion,
            );

            dataStore.backgroundWriteScheduler.addEntry(
              BackgroundWriteEntry(
                taskId: op.opId,
                tableUid: table.tableUid,
                primaryKey: pk,
                type: BackgroundWriteType.largeUpdate,
                mode: MigrationWriteMode.tableAndIndex,
                entry: entry,
                currentCursor: nextCursor,
                nextCursor: nextCursor,
              ),
              pk,
            );
            chunkReservedPks.remove(pk);
          }

          dataStore.parallelJournalManager.scheduleFlushIfNeeded();
          return true;
        },
      );

      _throwIfInterrupted(dataStore, token, 'update');

      await _drainOpBackgroundWrites(dataStore, op.opId, token);

      _throwIfInterrupted(dataStore, token, 'update');

      Logger.info(
          'Large-scale data update completed for table [${table.tableName}] '
          '(opId: ${op.opId}, count: $updatedCount).');
      return updatedCount;
    } catch (e) {
      if (e is! DbClosedException) {
        Logger.error('Large-scale data update failed for ${op.opId}',
            rawError: e);
      }
      rethrow;
    }
  }

  static Future<void> _drainOpBackgroundWrites(
    DataStoreImpl dataStore,
    String opId,
    CancellationToken token,
  ) async {
    var rounds = 0;
    while (dataStore.backgroundWriteScheduler
            .hasPendingEntriesOfType(BackgroundWriteType.largeDelete) ||
        dataStore.backgroundWriteScheduler
            .hasPendingEntriesOfType(BackgroundWriteType.largeUpdate)) {
      _throwIfInterrupted(dataStore, token, 'operation drain');
      if (++rounds > 512) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysTimeout,
            message: 'Large-scale data operation drain timed out for $opId '
                'with pending largeDelete/largeUpdate scheduler entries; '
                'caller must retry the operation.',
          ),
        ]);
      }
      await dataStore.parallelJournalManager.flushCompletely();
    }
  }
}
