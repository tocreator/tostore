import 'dart:async';
import 'dart:math';

import '../handler/logger.dart';
import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/background_write_entry.dart';
import '../model/migration_write_mode.dart';
import '../model/background_write_type.dart';
import '../model/buffer_entry.dart';
import '../model/cancellation_token.dart';
import '../model/change_event.dart';
import '../model/expr.dart';
import '../model/foreign_key_operation.dart';
import '../model/table_schema.dart';
import '../query/query_condition.dart';
import 'compute/batch_match_runner.dart';
import 'data_store_impl.dart';
import 'resource_manager.dart';
import 'wal_manager.dart';
import 'yield_controller.dart';
import '../model/data_store_config.dart';

/// Runner that processes large delete and update operations asynchronously in the background.
///
/// It scans for running operations in the WAL metadata and sequentially processes them batch-by-batch
/// without blocking the caller's main thread. It respects cooperative cancellation tokens for space switching
/// and shutdown.
class LargeOperationRunner {
  LargeOperationRunner._();

  static final Map<String, CancellationToken> _activeTokens = {};
  static final Map<String, Future<void>> _activeTasks = {};
  static final Set<String> _runningOpIds = {};

  /// Check if a specific large operation is currently running.
  static bool isOperationRunning(String opId) => _runningOpIds.contains(opId);

  /// Request cooperative pause for all tasks in a specific space.
  static void requestPause(String spaceName) {
    _activeTokens[spaceName]?.cancel();
  }

  /// Request cooperative pause for all tasks in a specific space and wait for them to finish.
  static Future<bool> pauseAndAwait(String spaceName) async {
    final token = _activeTokens[spaceName];
    if (token == null) return false;
    token.cancel();
    final task = _activeTasks[spaceName];
    if (task != null) {
      try {
        await task;
      } catch (_) {}
    }
    return true;
  }

  /// Cooperatively pause ongoing background tasks for switch space or shutdown.
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

    Logger.info('Background large operations stopped for space [$space].');
  }

  /// Run or resume pending large delete/update operations for the given [dataStore] space.
  static Future<void> runPendingOperations(DataStoreImpl dataStore) async {
    final space = dataStore.currentSpaceName;
    if (_activeTasks.containsKey(space)) {
      return;
    }

    final completer = Completer<void>();
    _activeTasks[space] = completer.future;

    final token = CancellationToken();
    _activeTokens[space] = token;

    unawaited(() async {
      try {
        await _executePendingLoop(dataStore, token);
      } catch (e) {
        if (e is DbClosedException) {
          Logger.info(
              'Pending large operations for space $space cancelled due to database close');
          return;
        }
        Logger.error('Error running pending operations for space $space',
            rawError: e);
      } finally {
        _activeTokens.remove(space);
        _activeTasks.remove(space);
        completer.complete();
      }
    }());
  }

  static Future<void> _executePendingLoop(
    DataStoreImpl dataStore,
    CancellationToken token,
  ) async {
    final spaceName = dataStore.currentSpaceName;

    while (!token.isCancelled) {
      final meta = dataStore.walManager.meta;
      final pendingDeletes = meta.largeDeletes.values
          .where((op) =>
              op.status == 'running' &&
              ((op.spaceName == '__global__' &&
                      !dataStore.isMigrationInstance) ||
                  op.spaceName == spaceName))
          .toList();

      final pendingUpdates = meta.largeUpdates.values
          .where((op) =>
              op.status == 'running' &&
              ((op.spaceName == '__global__' &&
                      !dataStore.isMigrationInstance) ||
                  op.spaceName == spaceName))
          .toList();

      final allOps = [];
      allOps.addAll(pendingDeletes);
      allOps.addAll(pendingUpdates);

      if (allOps.isEmpty) {
        break;
      }

      // Sort by creation time to ensure FIFO serial scheduling
      allOps.sort((a, b) => a.createdAt.compareTo(b.createdAt));

      final activeOp = allOps.first;
      if (activeOp is LargeDeleteMeta) {
        await _runLargeDelete(dataStore, activeOp, token);
      } else if (activeOp is LargeUpdateMeta) {
        await _runLargeUpdate(dataStore, activeOp, token);
      }

      // Briefly yield to event loop before checking the next operation
      await Future.delayed(Duration.zero);
    }
  }

  static Future<void> _runLargeDelete(
    DataStoreImpl dataStore,
    LargeDeleteMeta op,
    CancellationToken token,
  ) async {
    if (token.isCancelled) return;
    _runningOpIds.add(op.opId);

    final tempConflictTableName = '_system_temp_op_conflict_${op.opId}';

    try {
      final table =
          await dataStore.tableMetaManager?.getTableContext(op.tableUid);
      if (table == null) {
        Logger.warn(
            'Background delete skipped: table not found (opId: ${op.opId}).');
        await dataStore.dropTable(tempConflictTableName, registerWalOp: false);
        await dataStore.walManager.completeLargeDelete(op.opId);
        return;
      }

      Logger.info(
          'Starting/resuming background delete for table [${table.tableName}] (opId: ${op.opId}).');

      final schema = table.schema;
      final primaryKey = schema.primaryKey;
      int deletedCount = op.deletedSoFar;
      final conditionMap = op.condition;
      final writeBatchSize = dataStore.config.writeBatchSize;

      await dataStore.queryExecutor.queryEachBatch(
        table,
        batchSize: writeBatchSize,
        checkpointCursor: op.checkpointCursor,
        cancellationToken: token,
        orderBy: op.orderBy,
        condition: QueryCondition.fromMap(conditionMap),
        onBatch: (records, currentCursor, nextCursor) async {
          if (token.isCancelled) return false;

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

          if (records.isEmpty) return true;

          // 1. Fetch skip flags from the temporary conflict table
          Map<String, int> skipMap = {};
          try {
            if (await dataStore.tableExists(tempConflictTableName)) {
              final conflictTable =
                  await dataStore.getTableContext(tempConflictTableName);
              final conflictRecords = (await dataStore.queryExecutor.execute(
                conflictTable,
                condition: QueryCondition.fromMap({
                  'primaryKey': {
                    'IN': records.map((r) => r[primaryKey].toString()).toList()
                  }
                }),
              ))
                  .records;
              skipMap = {
                for (final cr in conflictRecords)
                  cr['primaryKey'].toString(): (cr['skipFlag'] as num).toInt()
              };
            }
          } catch (_) {}

          final remainingMatchBudget =
              op.limit == null ? null : max(0, op.limit! - deletedCount);
          if (op.limit != null && remainingMatchBudget == 0) {
            return false;
          }

          // 2. Perform batch index matching
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
          final yieldController = YieldController('LargeDeleteRunner.process');

          for (final matchedIndex in matchResult.matchedIndices) {
            if (token.isCancelled) return false;
            final y1 = yieldController.maybeYield();
            if (y1 != null) await y1;

            final record = records[matchedIndex];
            final pkValue = record[primaryKey];
            if (pkValue == null) continue;
            final pkValueStr = pkValue.toString();

            if (skipMap[pkValueStr] == 1) {
              continue; // Skip entirely
            }

            // 3. Foreign Key Checks and Cascades
            if (dataStore.foreignKeyManager != null) {
              try {
                await dataStore.foreignKeyManager!
                    .checkRestrictConstraintsForDelete(
                  table: table,
                  deletedPkValues: pkValue,
                );
              } catch (e) {
                Logger.error('RESTRICT constraint check failed in heavy delete',
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
                Logger.error('Cascade delete failed in heavy delete',
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

          // 4. Populate scheduler for batch flushing
          for (final record in deletes) {
            if (token.isCancelled) return false;
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
                // Assign nextCursor to currentCursor to forward checkpoint correctly
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

      if (token.isCancelled) return;

      // Drain all enqueued background write records for this task to disk
      await _drainOpBackgroundWrites(dataStore, op.opId, token);

      if (token.isCancelled) return;

      // Drop conflict table and complete operation in WAL
      try {
        await dataStore.dropTable(tempConflictTableName, registerWalOp: false);
        await dataStore.walManager.completeLargeDelete(op.opId);
        Logger.info(
            'Background delete completed for table [${table.tableName}] (opId: ${op.opId}).');
      } catch (_) {}
    } catch (e) {
      Logger.error('Large delete failed for ${op.opId}', rawError: e);
      try {
        await dataStore.dropTable(tempConflictTableName, registerWalOp: false);
        await dataStore.walManager.cancelLargeDelete(op.opId);
      } catch (_) {}
      rethrow;
    } finally {
      _runningOpIds.remove(op.opId);
    }
  }

  static Future<void> _runLargeUpdate(
    DataStoreImpl dataStore,
    LargeUpdateMeta op,
    CancellationToken token,
  ) async {
    if (token.isCancelled) return;
    _runningOpIds.add(op.opId);

    final tempConflictTableName = '_system_temp_op_conflict_${op.opId}';

    try {
      final table =
          await dataStore.tableMetaManager?.getTableContext(op.tableUid);
      if (table == null) {
        Logger.warn(
            'Background update skipped: table not found (opId: ${op.opId}).');
        await dataStore.dropTable(tempConflictTableName, registerWalOp: false);
        await dataStore.walManager.completeLargeUpdate(op.opId);
        return;
      }

      Logger.info(
          'Starting/resuming background update for table [${table.tableName}] (opId: ${op.opId}).');

      final schema = table.schema;
      final primaryKey = schema.primaryKey;
      int updatedCount = op.updatedSoFar;
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
          if (index.fields.any(
              (f) => validData.containsKey(f) && validData[f] is ExprNode)) {
            uniqueFieldsToCheck.addAll(index.fields);
          }
        }
      }

      await dataStore.queryExecutor.queryEachBatch(
        table,
        batchSize: writeBatchSize,
        checkpointCursor: op.checkpointCursor,
        cancellationToken: token,
        orderBy: op.orderBy,
        condition: QueryCondition.fromMap(conditionMap),
        onBatch: (records, currentCursor, nextCursor) async {
          if (token.isCancelled) return false;

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

          if (records.isEmpty) return true;

          // 1. Fetch skip flags from the temporary conflict table
          Map<String, int> skipMap = {};
          Map<String, List<String>> conflictFieldsMap = {};
          try {
            if (await dataStore.tableExists(tempConflictTableName)) {
              final conflictTable =
                  await dataStore.getTableContext(tempConflictTableName);
              final conflictRecords = (await dataStore.queryExecutor.execute(
                conflictTable,
                condition: QueryCondition.fromMap({
                  'primaryKey': {
                    'IN': records.map((r) => r[primaryKey].toString()).toList()
                  }
                }),
              ))
                  .records;
              for (final cr in conflictRecords) {
                final pk = cr['primaryKey'].toString();
                skipMap[pk] = (cr['skipFlag'] as num).toInt();
                final fields = cr['conflictFields'] as String?;
                if (fields != null && fields.isNotEmpty) {
                  conflictFieldsMap[pk] = fields.split(',');
                }
              }
            }
          } catch (_) {}

          final remainingMatchBudget =
              op.limit == null ? null : max(0, op.limit! - updatedCount);
          if (op.limit != null && remainingMatchBudget == 0) {
            return false;
          }

          // 2. Perform batch index matching
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
          final matchedIndexSet = matchResult.matchedIndices.toSet();

          // First add records matched by ConditionBatchMatcher
          for (final matchedIndex in matchResult.matchedIndices) {
            final candidate = records[matchedIndex];
            final candidatePk = candidate[primaryKey]?.toString();
            if (candidatePk != null &&
                insertedPrimaryKeysThisUpdate.contains(candidatePk)) {
              continue;
            }
            if (op.limit != null && updatedCount >= op.limit!) {
              continue;
            }
            updatedCount++;
            matchedRecords.add(candidate);
          }

          // Safely catch up on records that were modified online (skipFlag == 2)
          // but no longer match the condition filter, preventing them from being leaked.
          for (var idx = 0; idx < records.length; idx++) {
            if (matchedIndexSet.contains(idx)) continue;
            final candidate = records[idx];
            final candidatePk = candidate[primaryKey]?.toString();
            if (candidatePk != null && skipMap[candidatePk] == 2) {
              if (insertedPrimaryKeysThisUpdate.contains(candidatePk)) {
                continue;
              }
              if (op.limit != null && updatedCount >= op.limit!) {
                continue;
              }
              updatedCount++;
              matchedRecords.add(candidate);
            }
          }

          if (matchedRecords.isEmpty) return true;

          // Compute uniform update records using isolate if applicable
          final preparedMatchedRecords =
              await dataStore.prepareUniformUpdateRecords(
            schema,
            table,
            validData,
            matchedRecords,
          );

          final updates = <Map<String, dynamic>>[];
          final deletes = <Map<String, dynamic>>[];
          final inserts = <Map<String, dynamic>>[];
          final cacheKeysToRemove = <String>{};
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
              YieldController('LargeUpdateRunner.process');

          for (int matchedIndex = 0;
              matchedIndex < matchedRecords.length;
              matchedIndex++) {
            if (token.isCancelled) {
              await releaseChunkReservations();
              return false;
            }
            final y2 = applyYieldController.maybeYield();
            if (y2 != null) await y2;

            final record = matchedRecords[matchedIndex];
            var updatedRecord =
                preparedMatchedRecords[matchedIndex].updatedRecord;
            final pkValue = record[primaryKey];
            if (pkValue == null) continue;
            final pkValueStr = pkValue.toString();

            final skipFlag = skipMap[pkValueStr];
            if (skipFlag == 1) continue; // Skip entirely
            if (skipFlag == 2) {
              final skipFields = conflictFieldsMap[pkValueStr];
              if (skipFields != null && skipFields.isNotEmpty) {
                final mergedRecord = Map<String, dynamic>.from(record);
                updatedRecord.forEach((k, v) {
                  if (!skipFields.contains(k)) {
                    mergedRecord[k] = v;
                  }
                });
                updatedRecord = mergedRecord;
              }
            }
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
                    'Unique constraint check failed in heavy update reserve',
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
                Logger.error('Unique constraint check failed in heavy update',
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
                    Logger.error('Cascade update failed in heavy update',
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
                Logger.error('Foreign key check failed in heavy update',
                    rawError: e);
                if (op.continueOnPartialErrors) continue;
                await releaseChunkReservations();
                rethrow;
              }
            }

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
            cacheKeysToRemove.add(pkValueStr);
          }

          var entryVersion = schema.schemaVersion ?? '';
          if (dataStore.migrationManager?.hasRuntimeMigrationForTable(table) ??
              false) {
            entryVersion = '';
          }

          // Populate scheduler
          for (final record in deletes) {
            if (token.isCancelled) {
              await releaseChunkReservations();
              return false;
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
            if (token.isCancelled) {
              await releaseChunkReservations();
              return false;
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
            if (token.isCancelled) {
              await releaseChunkReservations();
              return false;
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

      if (token.isCancelled) return;

      await _drainOpBackgroundWrites(dataStore, op.opId, token);

      if (token.isCancelled) return;

      try {
        await dataStore.dropTable(tempConflictTableName, registerWalOp: false);
        await dataStore.walManager.completeLargeUpdate(op.opId);
        Logger.info(
            'Background update completed for table [${table.tableName}] (opId: ${op.opId}).');
      } catch (_) {}
    } catch (e) {
      Logger.error('Large update failed for ${op.opId}', rawError: e);
      try {
        await dataStore.dropTable(tempConflictTableName, registerWalOp: false);
        await dataStore.walManager.cancelLargeUpdate(op.opId);
      } catch (_) {}
      rethrow;
    } finally {
      _runningOpIds.remove(op.opId);
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
      if (token.isCancelled) break;
      if (++rounds > 512) {
        Logger.warn(
            'Background write drain hit round limit for operation $opId');
        break;
      }
      await dataStore.parallelJournalManager.flushCompletely();
    }
  }
}
