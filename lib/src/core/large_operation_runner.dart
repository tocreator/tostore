import 'dart:async';
import 'dart:math';

import '../handler/logger.dart';
import '../model/background_write_entry.dart';
import '../model/background_write_mode.dart';
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
import 'wal_manager.dart';
import 'yield_controller.dart';
import 'write_buffer_manager.dart';

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

  /// Cooperatively pause ongoing background tasks for switch space or shutdown.
  static Future<void> pauseForShutdown(DataStoreImpl dataStore) async {
    final space = dataStore.currentSpaceName;
    Logger.info('Stopping background large operations for space [$space]...',
        label: 'LargeOperationRunner');
    requestPause(space);

    final task = _activeTasks[space];
    if (task != null) {
      try {
        await task;
      } catch (_) {}
    }

    // Clear pending large operations in the scheduler to avoid stalling shutdown/space-switch
    dataStore.backgroundWriteScheduler
        .clearEntriesOfType(BackgroundWriteType.largeDelete);
    dataStore.backgroundWriteScheduler
        .clearEntriesOfType(BackgroundWriteType.largeUpdate);

    Logger.info('Background large operations stopped for space [$space].',
        label: 'LargeOperationRunner');
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
      } catch (e, s) {
        Logger.error(
            'Error running pending operations for space $space: $e\n$s',
            label: 'LargeOperationRunner');
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

    Logger.info(
        'Starting/resuming background delete for table [${op.table}] (opId: ${op.opId}).',
        label: 'LargeOperationRunner');

    try {
      final tableName = op.table;
      final schema = await dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        // Table not found, clean metadata and complete
        await dataStore.dropTable(tempConflictTableName, registerWalOp: false);
        await dataStore.walManager.completeLargeDelete(op.opId);
        return;
      }

      final primaryKey = schema.primaryKey;
      int deletedCount = op.deletedSoFar;
      final conditionMap = op.condition;
      final writeBatchSize = dataStore.config.writeBatchSize;

      await dataStore.queryExecutor.queryEachBatch(
        tableName,
        batchSize: writeBatchSize,
        checkpointCursor: op.checkpointCursor,
        cancellationToken: token,
        orderBy: op.orderBy,
        condition: QueryCondition.fromMap(conditionMap),
        onBatch: (records, currentCursor, nextCursor) async {
          if (token.isCancelled) return false;

          await dataStore.backgroundWriteScheduler.waitIfCongested(
            writeBatchSize,
            dataStore.writeBufferManager.queueLength,
            cancellationToken: token,
          );

          if (records.isEmpty) return true;

          // 1. Fetch skip flags from the temporary conflict table
          Map<String, int> skipMap = {};
          try {
            if (await dataStore.tableExists(tempConflictTableName)) {
              final conflictRecords = await dataStore.executeQuery(
                tempConflictTableName,
                QueryCondition.fromMap({
                  'primaryKey': {
                    'IN': records.map((r) => r[primaryKey].toString()).toList()
                  }
                }),
              );
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
            tableName: tableName,
            condition: conditionMap,
            records: records,
            estimateRecordBytes:
                dataStore.tableDataManager.estimateRecordSizeBytes,
            maxMatchCount: remainingMatchBudget,
          );

          final deletes = <Map<String, dynamic>>[];
          final yieldController = YieldController('LargeDeleteRunner.process');

          for (final matchedIndex in matchResult.matchedIndices) {
            if (token.isCancelled) return false;
            await yieldController.maybeYield();

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
                  tableName: tableName,
                  deletedPkValues: pkValue,
                );
              } catch (e) {
                Logger.error(
                    'RESTRICT constraint check failed in heavy delete: $e',
                    label: 'LargeOperationRunner');
                rethrow;
              }

              try {
                await dataStore.foreignKeyManager!.handleCascadeDelete(
                  tableName: tableName,
                  deletedPkValues: pkValue,
                  skipRestrictCheck: true,
                );
              } catch (e) {
                Logger.error('Cascade delete failed in heavy delete: $e',
                    label: 'LargeOperationRunner');
                rethrow;
              }
            }

            deletedCount++;
            deletes.add(record);

            if (dataStore.notificationManager.hasListeners(tableName)) {
              dataStore.notificationManager.notify(ChangeEvent(
                type: ChangeType.delete,
                tableName: tableName,
                oldRecord: record,
              ));
            }

            dataStore.tableDataManager
                .removeRecordFromBuffer(tableName, pkValueStr);
          }

          if (deletes.isEmpty) {
            return true;
          }

          // 4. Populate scheduler for batch flushing
          for (final record in deletes) {
            if (token.isCancelled) return false;
            final pkValueStr = record[primaryKey].toString();
            final entry = BufferEntry(
              operation: BufferOperationType.delete,
              data: record,
              timestamp: DateTime.now(),
            );
            dataStore.backgroundWriteScheduler.addEntry(
              BackgroundWriteEntry(
                taskId: op.opId,
                tableName: tableName,
                primaryKey: pkValueStr,
                type: BackgroundWriteType.largeDelete,
                mode: BackgroundWriteMode.tableAndIndex,
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
            'Background delete completed for table [${op.table}] (opId: ${op.opId}).',
            label: 'LargeOperationRunner');
      } catch (_) {}
    } catch (e, s) {
      Logger.error('Large delete failed for ${op.opId}: $e\n$s',
          label: 'LargeOperationRunner');
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

    Logger.info(
        'Starting/resuming background update for table [${op.table}] (opId: ${op.opId}).',
        label: 'LargeOperationRunner');

    try {
      final tableName = op.table;
      final schema = await dataStore.schemaManager?.getTableSchema(tableName);
      if (schema == null) {
        await dataStore.dropTable(tempConflictTableName, registerWalOp: false);
        await dataStore.walManager.completeLargeUpdate(op.opId);
        return;
      }

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
            dataStore.schemaManager?.getUniqueIndexesFor(schema) ??
                <IndexSchema>[];
        for (final index in allIndexes) {
          if (index.fields.any(
              (f) => validData.containsKey(f) && validData[f] is ExprNode)) {
            uniqueFieldsToCheck.addAll(index.fields);
          }
        }
      }

      await dataStore.queryExecutor.queryEachBatch(
        tableName,
        batchSize: writeBatchSize,
        checkpointCursor: op.checkpointCursor,
        cancellationToken: token,
        orderBy: op.orderBy,
        condition: QueryCondition.fromMap(conditionMap),
        onBatch: (records, currentCursor, nextCursor) async {
          if (token.isCancelled) return false;

          await dataStore.backgroundWriteScheduler.waitIfCongested(
            writeBatchSize,
            dataStore.writeBufferManager.queueLength,
            cancellationToken: token,
          );

          if (records.isEmpty) return true;

          // 1. Fetch skip flags from the temporary conflict table
          Map<String, int> skipMap = {};
          Map<String, List<String>> conflictFieldsMap = {};
          try {
            if (await dataStore.tableExists(tempConflictTableName)) {
              final conflictRecords = await dataStore.executeQuery(
                tempConflictTableName,
                QueryCondition.fromMap({
                  'primaryKey': {
                    'IN': records.map((r) => r[primaryKey].toString()).toList()
                  }
                }),
              );
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
            tableName: tableName,
            condition: conditionMap,
            records: records,
            estimateRecordBytes:
                dataStore.tableDataManager.estimateRecordSizeBytes,
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
            tableName,
            validData,
            matchedRecords,
          );

          final updates = <Map<String, dynamic>>[];
          final deletes = <Map<String, dynamic>>[];
          final inserts = <Map<String, dynamic>>[];
          final cacheKeysToRemove = <String>{};

          final applyYieldController =
              YieldController('LargeUpdateRunner.process');

          for (int matchedIndex = 0;
              matchedIndex < matchedRecords.length;
              matchedIndex++) {
            if (token.isCancelled) return false;
            await applyYieldController.maybeYield();

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
            List<UniqueKeyRef>? reservedKeys;
            // Verify unique constraints
            if (uniqueFieldsToCheck.isNotEmpty &&
                dataStore.indexManager != null &&
                !isPrimaryKeyUpdate) {
              final planUpd = dataStore.planUniqueForUpdate(
                tableName,
                schema,
                updatedRecord,
                validData.keys.toSet(),
              );

              try {
                reservedKeys =
                    dataStore.writeBufferManager.tryReserveUniqueKeys(
                  tableName: tableName,
                  recordId: pkValueStr,
                  uniqueKeys: planUpd.refs,
                  isUpdate: true,
                );
              } catch (e) {
                Logger.error(
                    'Unique constraint check failed in heavy update reserve: $e',
                    label: 'LargeOperationRunner');
                if (op.continueOnPartialErrors) {
                  Logger.warn(
                      'Skip updating record with PK $pkValueStr due to unique constraint conflict: $e',
                      label: 'LargeOperationRunner');
                  continue;
                }
                rethrow;
              }

              try {
                final violation =
                    await dataStore.indexManager!.checkUniqueConstraints(
                  tableName,
                  updatedRecord,
                  isUpdate: true,
                  skipBufferCheck: true,
                );
                if (violation != null) {
                  throw violation;
                }
              } catch (e) {
                if (reservedKeys != null) {
                  try {
                    dataStore.writeBufferManager.releaseReservedUniqueKeys(
                      tableName: tableName,
                      recordId: pkValueStr,
                    );
                  } catch (_) {}
                }
                Logger.error(
                    'Unique constraint check failed in heavy update: $e',
                    label: 'LargeOperationRunner');
                if (op.continueOnPartialErrors) {
                  Logger.warn(
                      'Skip updating record with PK $pkValueStr due to unique constraint conflict: $e',
                      label: 'LargeOperationRunner');
                  continue;
                }
                rethrow;
              }
            }

            // Verify and check primary key update unique constraints with reservation
            if (isPrimaryKeyUpdate) {
              final newPkVal = updatedRecord[primaryKey]?.toString();
              if (newPkVal != null && newPkVal != pkValueStr) {
                final planIns = dataStore.planUniqueForInsert(
                  tableName,
                  schema,
                  updatedRecord,
                );

                List<UniqueKeyRef>? pkReservedKeys;
                try {
                  pkReservedKeys =
                      dataStore.writeBufferManager.tryReserveUniqueKeys(
                    tableName: tableName,
                    recordId: newPkVal,
                    uniqueKeys: planIns.refs,
                    isUpdate: false,
                  );
                } catch (e) {
                  Logger.error(
                      'Unique constraint check failed in primary key update reserve: $e',
                      label: 'LargeOperationRunner');
                  if (op.continueOnPartialErrors) {
                    Logger.warn(
                        'Skip primary key update for record with PK $pkValueStr due to unique conflict: $e',
                        label: 'LargeOperationRunner');
                    continue;
                  }
                  rethrow;
                }

                try {
                  final violation =
                      await dataStore.indexManager!.checkUniqueConstraints(
                    tableName,
                    updatedRecord,
                    isUpdate: true,
                    skipBufferCheck: true,
                  );
                  if (violation != null) {
                    throw violation;
                  }
                } catch (e) {
                  if (pkReservedKeys != null) {
                    try {
                      dataStore.writeBufferManager.releaseReservedUniqueKeys(
                        tableName: tableName,
                        recordId: newPkVal,
                      );
                    } catch (_) {}
                  }
                  Logger.error(
                      'Unique constraint check failed in primary key update: $e',
                      label: 'LargeOperationRunner');
                  if (op.continueOnPartialErrors) {
                    Logger.warn(
                        'Skip primary key update for record with PK $pkValueStr due to unique conflict: $e',
                        label: 'LargeOperationRunner');
                    continue;
                  }
                  rethrow;
                }

                // Check restrict and cascade update for primary key updates
                if (dataStore.foreignKeyManager != null) {
                  try {
                    await dataStore.foreignKeyManager!
                        .checkRestrictConstraintsForUpdate(
                      tableName: tableName,
                      oldPkValues: pkValueStr,
                    );
                  } catch (e) {
                    Logger.error(
                        'RESTRICT constraint check failed in primary key update: $e',
                        label: 'LargeOperationRunner');
                    rethrow;
                  }

                  try {
                    await dataStore.foreignKeyManager!.handleCascadeUpdate(
                      tableName: tableName,
                      oldPkValues: pkValueStr,
                      newPkValues: newPkVal,
                    );
                  } catch (e) {
                    Logger.error('Cascade update failed in heavy update: $e',
                        label: 'LargeOperationRunner');
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
                  tableName: tableName,
                  data: updatedRecord,
                  operation: ForeignKeyOperation.update,
                );
              } catch (e) {
                Logger.error('Foreign key check failed in heavy update: $e',
                    label: 'LargeOperationRunner');
                rethrow;
              }
            }

            if (dataStore.notificationManager.hasListeners(tableName)) {
              dataStore.notificationManager.notify(ChangeEvent(
                type: ChangeType.update,
                tableName: tableName,
                record: updatedRecord,
                oldRecord: record,
              ));
            }

            dataStore.tableDataManager
                .removeRecordFromBuffer(tableName, pkValueStr);
            cacheKeysToRemove.add(pkValueStr);
          }

          // Populate scheduler
          for (final record in deletes) {
            final pk = record[primaryKey].toString();
            final entry = BufferEntry(
              operation: BufferOperationType.delete,
              data: record,
              timestamp: DateTime.now(),
            );
            dataStore.backgroundWriteScheduler.addEntry(
              BackgroundWriteEntry(
                taskId: op.opId,
                tableName: tableName,
                primaryKey: pk,
                type: BackgroundWriteType.largeUpdate,
                mode: BackgroundWriteMode.tableAndIndex,
                entry: entry,
                currentCursor: nextCursor,
                nextCursor: nextCursor,
              ),
              pk,
            );
          }

          for (final record in inserts) {
            final pk = record[primaryKey].toString();
            final entry = BufferEntry(
              operation: BufferOperationType.insert,
              data: record,
              timestamp: DateTime.now(),
            );
            dataStore.backgroundWriteScheduler.addEntry(
              BackgroundWriteEntry(
                taskId: op.opId,
                tableName: tableName,
                primaryKey: pk,
                type: BackgroundWriteType.largeUpdate,
                mode: BackgroundWriteMode.tableAndIndex,
                entry: entry,
                currentCursor: nextCursor,
                nextCursor: nextCursor,
              ),
              pk,
            );
          }

          for (final record in updates) {
            final pk = record[primaryKey].toString();
            final oldRecord =
                records.firstWhere((r) => r[primaryKey].toString() == pk);

            final entry = BufferEntry(
              operation: BufferOperationType.update,
              data: record,
              timestamp: DateTime.now(),
              // Pass the complete old record directly to avoid partial index oldValues missing
              oldValues: oldRecord,
            );

            dataStore.backgroundWriteScheduler.addEntry(
              BackgroundWriteEntry(
                taskId: op.opId,
                tableName: tableName,
                primaryKey: pk,
                type: BackgroundWriteType.largeUpdate,
                mode: BackgroundWriteMode.tableAndIndex,
                entry: entry,
                currentCursor: nextCursor,
                nextCursor: nextCursor,
              ),
              pk,
            );
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
            'Background update completed for table [${op.table}] (opId: ${op.opId}).',
            label: 'LargeOperationRunner');
      } catch (_) {}
    } catch (e, s) {
      Logger.error('Large update failed for ${op.opId}: $e\n$s',
          label: 'LargeOperationRunner');
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
            'Background write drain hit round limit for operation $opId',
            label: 'LargeOperationRunner');
        break;
      }
      await dataStore.parallelJournalManager.flushCompletely();
    }
  }
}
