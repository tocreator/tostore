import 'dart:async';
import 'dart:typed_data';

import '../handler/encryption.dart';
import '../handler/global_config_codec.dart';
import '../handler/logger.dart';
import '../model/applied_encryption.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/db_result.dart';
import '../model/encryption_domain.dart';
import '../model/global_config.dart';
import '../model/key_migration_info.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import 'crontab_manager.dart';
import 'data_store_impl.dart';
import 'key_migration_progress.dart';
import 'key_migration_runner.dart';

/// Manages encoding/encryption keys and encodingKey migration.
///
/// - [encryptionKey] (KEK): protects GlobalConfig shell only; rotation does not
///   rewrite table/index data.
/// - [encodingKey] (DEK): stored plaintext in [AppliedEncryption] inside
///   GlobalConfig; changes trigger background [KeyMigrationRunner].
class KeyManager {
  final DataStoreImpl _dataStore;

  String? _cachedEncodingKey;
  String? _cachedEncryptionKey;
  bool _keyMigrationScheduled = false;
  Future<void>? _keyMigrationFuture;
  KeyChangeInfo? _deferredKeyChangeInfo;
  DateTime? _lastHistoryPurgeDay;
  DateTime? _lastPauseCompletedAt;

  /// Low-frequency watch for WAL / page-redo / txn natural turnover.
  /// Registered only while rewrite is done and those domains remain open.
  bool _naturalTurnoverWatchRegistered = false;
  bool _naturalTurnoverPollInFlight = false;
  Future<void>? _naturalTurnoverPollFuture;
  late final String _naturalTurnoverLeaseId =
      'key_natural_${identityHashCode(_dataStore)}';

  KeyManager(DataStoreImpl dataStore) : _dataStore = dataStore;

  /// Get effective encryption config (use default if not provided)
  EncryptionConfig _getEncryptionConfig() {
    return _dataStore.config.encryptionConfig ?? const EncryptionConfig();
  }

  /// Get effective encryption key
  String _getEncryptionKey() {
    return _cachedEncryptionKey ??=
        _getEncryptionConfig().resolveEncryptionKey();
  }

  String _getEncodingKey() {
    return _cachedEncodingKey ??= _getEncryptionConfig().resolveEncodingKey();
  }

  EncryptionType _getEncryptionType() => _getEncryptionConfig().encryptionType;

  EncryptionScope _getEncryptionScope() =>
      _getEncryptionConfig().encryptionScope;

  /// Rotate the master [encryptionKey] that protects GlobalConfig.
  ///
  /// Does not rewrite table data. When [oldKey] is null/empty, the engine
  /// built-in [defaultEncryptionKey] is used (null → user-key transition).
  Future<DbResult> rotateEncryptionKey({
    String? oldKey,
    required String newKey,
  }) async {
    final effectiveOld =
        (oldKey == null || oldKey.isEmpty) ? defaultEncryptionKey : oldKey;

    if (newKey.isEmpty) {
      return DbResult.batch(
        statuses: [
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentMissing,
            message: 'newKey must be non-empty',
            parameterName: 'newKey',
            passedValue: newKey,
          ),
        ],
        failedCount: 1,
      );
    }
    if (effectiveOld == newKey) {
      return DbResult.batch(
        statuses: [
          InvalidArgumentStatus(
            type: ResultType.devInvalidArgumentFormat,
            message: 'newKey must differ from the effective old key',
            parameterName: 'newKey',
            passedValue: newKey,
          ),
        ],
        failedCount: 1,
      );
    }

    final migrationManager = _dataStore.migrationManager;
    final keyMigration = await migrationManager?.getKeyMigrationInfo();
    if (keyMigration != null && keyMigration.isRunning) {
      return DbResult.error(
        type: ResultType.devUnsupportedOperation,
        message:
            'Cannot rotate encryptionKey while encodingKey migration is in progress',
      );
    }

    try {
      final configPath = _dataStore.pathManager.getGlobalConfigPath();
      if (!await _dataStore.storage.existsFile(configPath)) {
        return DbResult.error(
          type: ResultType.engError,
          message: 'GlobalConfig missing; cannot rotate encryptionKey',
        );
      }

      final bytes = await _dataStore.storage.readAsBytes(configPath);
      final decoded = GlobalConfigCodec.decodeFileWithFallback(
        bytes,
        preferredKey: effectiveOld,
        fallbackKeys: [
          defaultEncryptionKey,
        ],
      );

      _cachedEncryptionKey = newKey;
      _dataStore.updateEncryptionKeyInConfig(newKey);
      await _dataStore.saveGlobalConfig(decoded.config, propagateErrors: true);

      Logger.info('encryptionKey rotated successfully');
      return DbResult.success(
        message: 'encryptionKey rotated successfully',
      );
    } catch (e) {
      Logger.error('encryptionKey rotation failed', rawError: e);
      final dbEx = DbException.wrap(
        e,
        fallbackType: ResultType.engError,
        fallbackMessage: 'encryptionKey rotation failed',
      );
      return DbResult.batch(
        statuses: dbEx.statuses,
        failedCount: dbEx.statuses.length,
      );
    }
  }

  /// V2 upgrade only: stash legacy plain encoding keys into GlobalConfig
  /// [AppliedEncryption], mint a fresh current key, and persist.
  Future<void> prepareKeysForV2DataRewrite({
    required String spaceName,
    required Map<int, String> legacyPlainEncodingKeysById,
  }) async {
    _getEncodingKey();
    _getEncryptionKey();

    final history = <EncryptionKeyInfo>[];
    void addHistory(int keyId, String plain) {
      if (plain.isEmpty) return;
      if (history.any((k) => k.keyId == keyId)) return;
      history.add(EncryptionKeyInfo(key: plain, keyId: keyId));
    }

    for (final entry in legacyPlainEncodingKeysById.entries) {
      addHistory(entry.key, entry.value);
    }

    final newKey = _getEncodingKey();
    var maxKeyId = 0;
    for (final id in legacyPlainEncodingKeysById.keys) {
      if (id > maxKeyId) maxKeyId = id;
    }
    final newKeyId = newKey.isEmpty ? 0 : maxKeyId + 1;
    final current = newKey.isEmpty
        ? const EncryptionKeyInfo(key: '', keyId: 0)
        : EncryptionKeyInfo(key: newKey, keyId: newKeyId);

    final applied = AppliedEncryption(current: current, historyKeys: history);
    await _saveAppliedEncryption(applied);

    final fallbackKeys = <int, Uint8List>{};
    for (final entry in legacyPlainEncodingKeysById.entries) {
      if (entry.value.isEmpty) continue;
      fallbackKeys[entry.key] = EncryptionManager.generateKey(entry.value);
    }
    if (newKey.isNotEmpty && newKeyId > 0) {
      fallbackKeys[newKeyId] = EncryptionManager.generateKey(newKey);
      EncryptionManager.setCurrentKey(newKey, newKeyId);
    }
    if (fallbackKeys.isNotEmpty) {
      EncryptionManager.setFallbackKeys(fallbackKeys);
    }

    Logger.info(
      'V2 key bootstrap for space [$spaceName]: '
      'current keyId=$newKeyId, history=${history.length}',
    );
  }

  /// Initialize KeyManager and detect encodingKey changes.
  Future<void> initialize() async {
    _getEncodingKey();
    _getEncryptionKey();

    // Set EncoderHandler encryption type and scope
    EncryptionManager.setEncryptionType(_getEncryptionType());
    EncryptionManager.setEncryptionScope(_getEncryptionScope());

    var applied = await _loadOrCreateAppliedEncryption();

    KeyChangeInfo? keyChangeInfo;
    try {
      keyChangeInfo = await updateEncoderHandlerKeys(applied);
    } catch (e) {
      Logger.error('Failed to set Encoder key', rawError: e);
    }

    // Switch to none: clear incomplete migration checkpoints; keep history keys.
    // Do not schedule encodingKey rewrite under none.
    if (_getEncryptionType() == EncryptionType.none) {
      await _clearIncompleteKeyMigrationCheckpoints();
      unawaited(_maybePurgeHistoryKeys());
      return;
    }

    unawaited(_maybePurgeHistoryKeys());

    if (_dataStore.isMigrationInstance) {
      return;
    }

    if (keyChangeInfo?.hasChanged == true) {
      _deferredKeyChangeInfo = keyChangeInfo;
    }
  }

  /// Start or resume key migration after [MigrationManager.initialize] has recovered schema tasks.
  Future<void> startDeferredKeyMigrationWork() async {
    if (_dataStore.isMigrationInstance) return;
    if (_getEncryptionType() == EncryptionType.none) return;

    final pendingChange = _deferredKeyChangeInfo;
    _deferredKeyChangeInfo = null;

    if (pendingChange != null) {
      await _beginKeyMigration(pendingChange);
    } else {
      await _resumeKeyMigrationIfNeeded();
    }
    await _syncNaturalTurnoverWatch();
  }

  Future<AppliedEncryption> _loadOrCreateAppliedEncryption() async {
    final global = await _dataStore.getGlobalConfig() ?? GlobalConfig();
    final existing = global.appliedEncryption;
    if (existing != null &&
        (existing.current.key.isNotEmpty || existing.current.keyId > 0)) {
      return existing;
    }

    final created = await createAppliedEncryption();
    await _saveAppliedEncryption(created);
    return created;
  }

  Future<void> _saveAppliedEncryption(AppliedEncryption applied) async {
    final global = await _dataStore.getGlobalConfig() ?? GlobalConfig();
    await _dataStore.saveGlobalConfig(
      global.copyWith(appliedEncryption: applied),
      propagateErrors: true,
    );
  }

  Future<KeyChangeInfo?> updateEncoderHandlerKeys(
    AppliedEncryption applied, {
    KeyMigrationInfo? runningMigration,
  }) async {
    final newKey = _getEncodingKey();
    final fallbackKeys = <int, Uint8List>{};

    for (final info in applied.getAllKeys()) {
      fallbackKeys[info.keyId] = EncryptionManager.generateKey(info.key);
    }

    final encryptionType = _getEncryptionType();
    if (encryptionType == EncryptionType.none) {
      EncryptionManager.setFallbackKeys(fallbackKeys);
      return null;
    }

    final running = runningMigration ??
        await _dataStore.migrationManager?.getKeyMigrationInfo();

    // In-flight migration: AppliedEncryption.current already holds the target
    // DEK (KEK-protected); match config against that — never read DEK from meta.
    if (running != null &&
        running.isRunning &&
        newKey.isNotEmpty &&
        applied.current.keyId == running.targetKeyId &&
        applied.current.key == newKey) {
      fallbackKeys[running.targetKeyId] = EncryptionManager.generateKey(newKey);
      EncryptionManager.setFallbackKeys(fallbackKeys);
      EncryptionManager.setCurrentKey(newKey, running.targetKeyId);
      return null;
    }

    final currentPlain =
        applied.current.key.isNotEmpty ? applied.current.key : null;

    final bool keyChanged = currentPlain != newKey;
    int keyIdToUse = applied.current.keyId;
    KeyChangeInfo? keyChangeInfo;

    if (keyChanged && newKey.isNotEmpty) {
      final newKeyId = _nextKeyId(applied, running);
      final newDecodedKey = EncryptionManager.generateKey(newKey);
      fallbackKeys[newKeyId] = newDecodedKey;
      keyIdToUse = newKeyId;
      Logger.info(
        'Encoding key changed, preparing async migration with new keyId: $newKeyId',
      );
      keyChangeInfo = KeyChangeInfo(
        hasChanged: true,
        newKey: newDecodedKey,
        newKeyId: newKeyId,
        plainEncodingKey: newKey,
      );
    }

    EncryptionManager.setFallbackKeys(fallbackKeys);

    if (newKey.isNotEmpty) {
      EncryptionManager.setCurrentKey(newKey, keyIdToUse);
    }

    return keyChangeInfo;
  }

  /// Create initial AppliedEncryption for a new database.
  Future<AppliedEncryption> createAppliedEncryption() async {
    final newKey = _getEncodingKey();
    if (newKey.isEmpty) {
      return AppliedEncryption.empty();
    }
    return AppliedEncryption(
      current: EncryptionKeyInfo(key: newKey, keyId: 1),
    );
  }

  int _nextKeyId(AppliedEncryption applied, KeyMigrationInfo? running) {
    var maxId = applied.current.keyId;
    for (final k in applied.historyKeys) {
      if (k.keyId > maxId) maxId = k.keyId;
    }
    if (running != null && running.targetKeyId > maxId) {
      maxId = running.targetKeyId;
    }
    return maxId + 1;
  }

  /// Promote target DEK to [AppliedEncryption.current] at migration start.
  Future<void> _persistTargetAsCurrent(KeyChangeInfo info) async {
    final global = await _dataStore.getGlobalConfig() ?? GlobalConfig();
    final applied = global.appliedEncryption ?? AppliedEncryption.empty();

    if (applied.current.keyId == info.newKeyId &&
        applied.current.key == info.plainEncodingKey) {
      await _refreshFallbackKeys(applied);
      return;
    }

    final history = [...applied.historyKeys];
    if (applied.current.key.isNotEmpty &&
        applied.current.keyId != info.newKeyId &&
        !history.any((k) => k.keyId == applied.current.keyId)) {
      history.add(applied.current);
    }

    final promoted = AppliedEncryption(
      current: EncryptionKeyInfo(
        key: info.plainEncodingKey,
        keyId: info.newKeyId,
      ),
      historyKeys: history,
    );
    await _saveAppliedEncryption(promoted);
    await _refreshFallbackKeys(promoted);
  }

  Future<void> _refreshFallbackKeys(AppliedEncryption applied) async {
    final fallbackKeys = <int, Uint8List>{};
    for (final info in applied.getAllKeys()) {
      fallbackKeys[info.keyId] = EncryptionManager.generateKey(info.key);
    }
    EncryptionManager.setFallbackKeys(fallbackKeys);
    if (applied.current.key.isNotEmpty) {
      EncryptionManager.setCurrentKey(
        applied.current.key,
        applied.current.keyId,
      );
    }
  }

  Future<void> _beginKeyMigration(KeyChangeInfo info) async {
    final migrationManager = _dataStore.migrationManager;
    if (migrationManager == null) return;

    var existing = await migrationManager.getKeyMigrationInfo();
    if (existing != null &&
        (existing.isRunning || existing.status == KeyMigrationStatus.failed)) {
      if (existing.status == KeyMigrationStatus.failed) {
        existing = existing.copyWith(status: KeyMigrationStatus.running);
        await migrationManager.persistKeyMigrationInfo(existing);
      }

      final applied = (await _dataStore.getGlobalConfig())?.appliedEncryption;
      // Target DEK lives only in AppliedEncryption (GlobalConfig / KEK shell).
      final matchesTarget = applied != null &&
          applied.current.keyId == existing.targetKeyId &&
          applied.current.key == info.plainEncodingKey;

      if (matchesTarget) {
        final resumeInfo = KeyChangeInfo(
          hasChanged: true,
          newKey: EncryptionManager.generateKey(info.plainEncodingKey),
          newKeyId: existing.targetKeyId,
          plainEncodingKey: info.plainEncodingKey,
        );
        await _persistTargetAsCurrent(resumeInfo);
        if (existing.snapshots == null) {
          final snapshots =
              await KeyMigrationRunner.captureNaturalSnapshots(_dataStore);
          await migrationManager.persistKeyMigrationInfo(
            existing.copyWith(snapshots: snapshots),
          );
        }
        _scheduleKeyMigrationRun(resumeInfo);
        return;
      }

      await _supersedeKeyMigration(info);
      return;
    }

    await KeyMigrationProgressStore.clearAll(_dataStore);
    // Promote DEK into GlobalConfig before any rewrite / meta persist.
    await _persistTargetAsCurrent(info);

    final snapshots =
        await KeyMigrationRunner.captureNaturalSnapshots(_dataStore);
    await migrationManager.persistKeyMigrationInfo(
      KeyMigrationInfo.start(
        targetKeyId: info.newKeyId,
        snapshots: snapshots,
      ),
    );
    _scheduleKeyMigrationRun(info);
  }

  Future<void> _resumeKeyMigrationIfNeeded() async {
    final migrationManager = _dataStore.migrationManager;
    if (migrationManager == null) return;

    var info = await migrationManager.getKeyMigrationInfo();
    if (info == null) return;

    // Transient runner failures must not strand the DB: retry on next open.
    if (info.status == KeyMigrationStatus.failed) {
      Logger.warn(
        'Retrying previously failed encodingKey migration '
        '(targetKeyId=${info.targetKeyId})',
      );
      info = info.copyWith(status: KeyMigrationStatus.running);
      await migrationManager.persistKeyMigrationInfo(info);
      await migrationManager.syncHasMigrationTask();
    }

    if (!info.isRunning) return;

    // Rewrite already finished; only natural-turnover domains remain.
    final rewriteDone = info.isDomainDone(EncryptionDomain.tableData) &&
        info.isDomainDone(EncryptionDomain.btreeIndex);
    if (rewriteDone && !info.allDomainsComplete) {
      await KeyMigrationRunner.refreshNaturalTurnoverAndMaybeComplete(
        _dataStore,
      );
      return;
    }

    final resumeInfo = await _buildResumeKeyChangeInfo(info);
    if (resumeInfo == null) {
      Logger.error(
        'Cannot resume key migration for keyId ${info.targetKeyId}: '
        'target encodingKey material missing; marking failed',
      );
      await migrationManager.persistKeyMigrationInfo(
        info.copyWith(status: KeyMigrationStatus.failed),
      );
      await migrationManager.syncHasMigrationTask();
      // Do not throw: startup must remain openable; failed status is explicit.
      return;
    }

    // Ensure AppliedEncryption + EncryptionManager match the in-flight target.
    await _persistTargetAsCurrent(resumeInfo);

    Logger.info(
      'Resuming key migration for keyId ${info.targetKeyId}',
    );
    _scheduleKeyMigrationRun(resumeInfo);
  }

  Future<void> _supersedeKeyMigration(KeyChangeInfo info) async {
    final migrationManager = _dataStore.migrationManager;
    if (migrationManager == null) return;

    await KeyMigrationProgressStore.clearAll(_dataStore);
    await migrationManager.clearKeyMigrationInfo();

    await _persistTargetAsCurrent(info);

    final snapshots =
        await KeyMigrationRunner.captureNaturalSnapshots(_dataStore);
    await migrationManager.persistKeyMigrationInfo(
      KeyMigrationInfo.start(
        targetKeyId: info.newKeyId,
        snapshots: snapshots,
      ),
    );
    _scheduleKeyMigrationRun(info);
  }

  /// Rebuild [KeyChangeInfo] from AppliedEncryption (KEK-protected GlobalConfig).
  Future<KeyChangeInfo?> _buildResumeKeyChangeInfo(
    KeyMigrationInfo info,
  ) async {
    final global = await _dataStore.getGlobalConfig();
    final applied = global?.appliedEncryption;
    if (applied == null) return null;

    String? plain;
    if (applied.current.keyId == info.targetKeyId &&
        applied.current.key.isNotEmpty) {
      plain = applied.current.key;
    } else {
      final hist = applied.getKeyById(info.targetKeyId);
      if (hist != null && hist.key.isNotEmpty) {
        plain = hist.key;
      }
    }

    if (plain == null || plain.isEmpty) return null;

    return KeyChangeInfo(
      hasChanged: true,
      newKey: EncryptionManager.generateKey(plain),
      newKeyId: info.targetKeyId,
      plainEncodingKey: plain,
    );
  }

  Future<void> _clearIncompleteKeyMigrationCheckpoints() async {
    final migrationManager = _dataStore.migrationManager;
    final info = await migrationManager?.getKeyMigrationInfo();
    if (info != null &&
        (info.status == KeyMigrationStatus.running ||
            info.status == KeyMigrationStatus.failed)) {
      await KeyMigrationProgressStore.clearAll(_dataStore);
      await migrationManager?.clearKeyMigrationInfo();
      await migrationManager?.syncHasMigrationTask();
      Logger.info(
        'Cleared incomplete key-migration checkpoints after switch to none',
      );
    }
  }

  Future<void> _maybePurgeHistoryKeys() async {
    final now = DateTime.now().toUtc();
    final day = DateTime.utc(now.year, now.month, now.day);
    if (_lastHistoryPurgeDay == day) return;
    _lastHistoryPurgeDay = day;

    final global = await _dataStore.getGlobalConfig();
    final applied = global?.appliedEncryption;
    if (applied == null) return;

    final purged = applied.purgeEligibleHistory(now: now);
    if (identical(purged, applied) ||
        purged.historyKeys.length == applied.historyKeys.length) {
      return;
    }
    await _saveAppliedEncryption(purged);
    Logger.info(
      'Purged ${applied.historyKeys.length - purged.historyKeys.length} '
      'expired history encoding keys',
    );
  }

  /// Cooperative pause for close / switchSpace / destructive ops.
  ///
  /// Returns `true` when the rewrite runner has stopped (or was idle).
  /// Returns `false` on timeout — callers must **not** open another space or
  /// tear down storage while the runner may still hold file handles.
  ///
  /// **Migration helper instances must no-op**: their [DataStoreImpl.close]
  /// must not cancel the primary [KeyMigrationRunner] token (otherwise each
  /// finished other-space helper would abort the multi-space run).
  ///
  /// Stops the natural-turnover crontab watch. Callers that keep the session
  /// should later run [startDeferredKeyMigrationWork], which re-arms the watch.
  ///
  /// [skipIfRecentlyPaused]: when true and a pause completed within 2s with no
  /// active runner (e.g. switchSpace then close), skip the second 30s poll wait.
  Future<bool> pauseKeyMigration({
    Duration timeout = const Duration(seconds: 120),
    bool skipIfRecentlyPaused = false,
  }) async {
    if (_dataStore.isMigrationInstance) {
      return true;
    }

    if (skipIfRecentlyPaused &&
        _lastPauseCompletedAt != null &&
        _keyMigrationFuture == null &&
        DateTime.now().difference(_lastPauseCompletedAt!) <
            const Duration(seconds: 2)) {
      _stopNaturalTurnoverWatch();
      return true;
    }

    _stopNaturalTurnoverWatch();
    await _awaitNaturalTurnoverPollIdle(
      timeout: const Duration(seconds: 30),
    );

    KeyMigrationRunner.requestPause();
    final future = _keyMigrationFuture;
    if (future == null) {
      _lastPauseCompletedAt = DateTime.now();
      return true;
    }

    try {
      await future.timeout(timeout);
      _lastPauseCompletedAt = DateTime.now();
      return true;
    } on TimeoutException {
      Logger.warn(
        'Key migration did not stop within ${timeout.inSeconds}s',
      );
      // Pause was requested; when the runner eventually exits, resume if this
      // primary session is still open (e.g. switchSpace aborted on timeout).
      unawaited(future.whenComplete(() {
        if (_dataStore.isMigrationInstance) return;
        if (!_dataStore.isInitialized && !_dataStore.isBaseInitialized) {
          return;
        }
        unawaited(startDeferredKeyMigrationWork());
      }));
      return false;
    } catch (_) {
      _lastPauseCompletedAt = DateTime.now();
      return true;
    }
  }

  Future<void> _awaitNaturalTurnoverPollIdle({
    required Duration timeout,
  }) async {
    final poll = _naturalTurnoverPollFuture;
    if (poll == null) return;
    try {
      await poll.timeout(timeout);
    } on TimeoutException {
      Logger.warn(
        'Natural-turnover poll did not finish within ${timeout.inSeconds}s',
      );
    } catch (_) {}
  }

  /// Start or stop the low-frequency natural-turnover poller based on meta.
  ///
  /// Safe to call before [DataStoreImpl.isInitialized] becomes true (startup
  /// arms the watch; ticks no-op until the DB is initialized).
  Future<void> _syncNaturalTurnoverWatch() async {
    if (_dataStore.isMigrationInstance) {
      _stopNaturalTurnoverWatch();
      return;
    }
    if (_getEncryptionType() == EncryptionType.none) {
      _stopNaturalTurnoverWatch();
      return;
    }

    final info = await _dataStore.migrationManager?.getKeyMigrationInfo();
    if (info == null || !info.isRunning) {
      _stopNaturalTurnoverWatch();
      return;
    }

    final rewriteDone = info.isDomainDone(EncryptionDomain.tableData) &&
        info.isDomainDone(EncryptionDomain.btreeIndex);
    if (rewriteDone && !info.allDomainsComplete) {
      _ensureNaturalTurnoverWatch();
    } else {
      _stopNaturalTurnoverWatch();
    }
  }

  void _ensureNaturalTurnoverWatch() {
    if (_naturalTurnoverWatchRegistered) return;
    if (_dataStore.isMigrationInstance) return;
    CrontabManager.addCallback(
      ExecuteInterval.minutes5,
      _onNaturalTurnoverTick,
    );
    CrontabManager.acquireBackgroundWorkLease(_naturalTurnoverLeaseId);
    _naturalTurnoverWatchRegistered = true;
    Logger.info(
      'Started 5-minute natural-turnover watch for encodingKey migration',
    );
  }

  void _stopNaturalTurnoverWatch() {
    if (!_naturalTurnoverWatchRegistered) return;
    CrontabManager.removeCallback(
      ExecuteInterval.minutes5,
      _onNaturalTurnoverTick,
    );
    CrontabManager.releaseBackgroundWorkLease(_naturalTurnoverLeaseId);
    _naturalTurnoverWatchRegistered = false;
  }

  void _onNaturalTurnoverTick() {
    if (!_naturalTurnoverWatchRegistered) return;
    // Startup may arm the watch before isInitialized; skip tick, keep watch.
    if (!_dataStore.isInitialized) return;
    unawaited(_pollNaturalTurnover());
  }

  Future<void> _pollNaturalTurnover() async {
    if (_naturalTurnoverPollInFlight) return;
    _naturalTurnoverPollInFlight = true;
    final done = Completer<void>();
    _naturalTurnoverPollFuture = done.future;
    try {
      if (!_dataStore.isInitialized) return;

      final migrationManager = _dataStore.migrationManager;
      final info = await migrationManager?.getKeyMigrationInfo();
      if (info == null || !info.isRunning) {
        _stopNaturalTurnoverWatch();
        return;
      }

      final rewriteDone = info.isDomainDone(EncryptionDomain.tableData) &&
          info.isDomainDone(EncryptionDomain.btreeIndex);
      if (!rewriteDone) {
        // Table rewrite still in progress — runner owns progress.
        return;
      }
      if (info.allDomainsComplete) {
        _stopNaturalTurnoverWatch();
        return;
      }

      await KeyMigrationRunner.refreshNaturalTurnoverAndMaybeComplete(
        _dataStore,
      );

      final after = await migrationManager?.getKeyMigrationInfo();
      if (after == null || !after.isRunning || after.allDomainsComplete) {
        _stopNaturalTurnoverWatch();
      }
    } catch (e) {
      if (e is DbClosedException) {
        _stopNaturalTurnoverWatch();
        return;
      }
      Logger.warn(
        'Natural-turnover poll for encodingKey migration failed',
        rawError: e,
      );
    } finally {
      _naturalTurnoverPollInFlight = false;
      if (!done.isCompleted) done.complete();
      if (identical(_naturalTurnoverPollFuture, done.future)) {
        _naturalTurnoverPollFuture = null;
      }
    }
  }

  void _scheduleKeyMigrationRun(KeyChangeInfo info) {
    if (_keyMigrationScheduled) return;
    _keyMigrationScheduled = true;
    Logger.info(
      'Scheduling background key migration for keyId ${info.newKeyId}',
    );
    unawaited(_keyMigrationFuture = _runKeyMigration(info));
  }

  Future<void> _runKeyMigration(KeyChangeInfo info) async {
    try {
      await KeyMigrationRunner.run(
        _dataStore,
        targetKeyId: info.newKeyId,
        keyChangeInfo: info,
      );
    } on DbClosedException catch (_) {
      // Silent
    } catch (e) {
      Logger.error('Key migration failed', rawError: e);
      final migrationManager = _dataStore.migrationManager;
      final existing = await migrationManager?.getKeyMigrationInfo();
      if (existing != null) {
        await migrationManager?.persistKeyMigrationInfo(
          existing.copyWith(status: KeyMigrationStatus.failed),
        );
      }
    } finally {
      _keyMigrationScheduled = false;
      _keyMigrationFuture = null;
      await _syncNaturalTurnoverWatch();
    }
  }

  /// Mark [domain] complete on the running key migration (if any).
  Future<void> markEncryptionDomainDone(EncryptionDomain domain) async {
    final migrationManager = _dataStore.migrationManager;
    if (migrationManager == null) return;
    final info = await migrationManager.getKeyMigrationInfo();
    if (info == null || !info.isRunning) return;
    if (info.isDomainDone(domain)) return;
    await migrationManager.persistKeyMigrationInfo(info.markDomainDone(domain));
  }
}
