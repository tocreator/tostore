import 'dart:async';
import 'dart:math';

import '../handler/common.dart';
import '../handler/logger.dart';
import '../handler/platform_handler.dart';
import '../model/data_store_config.dart';
import '../model/db_exception.dart';
import '../model/flush_pressure_state.dart';
import '../model/memory_info.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import 'crontab_manager.dart';
import 'data_store_impl.dart';

/// Resource status representing the health of system resources (Memory and Disk)
enum ResourceStatus {
  /// Resources are healthy
  normal,

  /// Resources are low, triggers cache cleanup
  warning,

  /// Resources are critically low; write admission waits (file mode) or rejects
  critical,
}

/// Resource manager responsible for dynamically monitoring system memory and disk space
class ResourceManager {
  /// Singleton implementation
  static final ResourceManager _instance = ResourceManager._internal();
  factory ResourceManager() => _instance;
  ResourceManager._internal();

  /// Total cache memory budget (MB). Default: 75% of available at first init.
  int _memoryThresholdInMB = 0;

  /// Configured memory threshold in megabytes
  int get memoryThresholdInMB => _memoryThresholdInMB;

  /// Safe cache ceiling for flush headroom and post-eviction target (budget*80%).
  static const double _budgetWarningRatio = 0.80;

  /// Bytes: full budget. Polling cleans only when usage exceeds this.
  int _budgetLimitUsageBytes = 0;

  /// Bytes: budget * [_budgetWarningRatio]. Headroom trigger and cleanup target.
  int _budgetWarningUsageBytes = 0;

  /// Set when projected usage (cache + pending flush×3.0) exceeds full budget.
  bool _budgetTrimActive = false;

  /// Safety factor on pending-flush estimate during polling (covers Maps/Lists).
  static const double _pendingFlushBudgetFactor = 3.0;

  /// Allocation ratios for various caches
  static const double _tableDataCacheRatio = 0.45; // Table data cache 45%
  static const double _indexCacheRatio = 0.30; // Index cache 30%
  static const double _queryCacheRatio = 0.10; // Query cache 10%
  static const double _metaCacheRatio =
      0.10; // Table data and index all meta cache 10%
  static const double _schemaCacheRatio = 0.05; // Schema cache 5%

  /// Size thresholds for various caches (in bytes)
  int _tableDataCacheSize = 0;
  int _indexCacheSize = 0;
  int _queryCacheSize = 0;
  int _schemaCacheSize = 0;
  int _metaCacheSize = 0;

  /// Last cache clear time
  DateTime _lastCacheClearTime = DateTime.now();

  /// Current resource status
  ResourceStatus _status = ResourceStatus.normal;

  /// Current memory status, kept separate from the combined memory/disk status.
  ResourceStatus _memoryStatus = ResourceStatus.normal;

  /// Current disk status, kept separate from the combined memory/disk status.
  ResourceStatus _diskStatus = ResourceStatus.normal;

  /// Default timeout for [awaitWriteAdmission] when file-mode memory is critical.
  static const Duration defaultWriteAdmissionTimeout = Duration(seconds: 60);

  /// Initialization flag
  bool _initialized = false;

  /// Single-flight handle for [initialize] (startup prefetch / concurrent).
  Future<void>? _initFuture;

  /// Last measured total cache usage across all types (bytes)
  int _lastMeasuredTotalUsageBytes = 0;

  /// Data store reference
  DataStoreImpl? _dataStore;

  /// Cache eviction callback function by type
  final Map<MemoryQuotaType, CacheEvictionCallback?> _cacheEvictionCallbacks = {
    MemoryQuotaType.tableData: null,
    MemoryQuotaType.queryResult: null,
    MemoryQuotaType.indexData: null,
    MemoryQuotaType.vectorIndex: null,
    MemoryQuotaType.schema: null,
    MemoryQuotaType.meta: null,
  };

  /// Flag to prevent re-entrant cache cleanup
  bool _isCleaning = false;

  /// Set when eviction is requested while another pass is already running.
  /// Cleared and re-checked after the in-flight pass finishes.
  bool _evictionRetriggerPending = false;

  /// Completes when the active eviction Future finishes. Waiters (headroom)
  /// use this instead of sharing a needFree budget across cleanups.
  Completer<void>? _cleaningDone;

  /// Ignore tiny headroom requests (bytes).
  static const int _minHeadroomBytes = 8 * 1024 * 1024;

  /// Initialize resource manager
  Future<void> initialize(
      DataStoreConfig config, DataStoreImpl dataStore) async {
    if (_initialized) return;
    final inFlight = _initFuture;
    if (inFlight != null) {
      await inFlight;
      return;
    }

    final loadOp = _doInitialize(config, dataStore);
    _initFuture = loadOp;
    try {
      await loadOp;
    } finally {
      if (identical(_initFuture, loadOp)) {
        _initFuture = null;
      }
    }
  }

  /// Await in-flight [initialize] if any; no-op when already initialized or
  /// never started (callers already use sync fallbacks for unset quotas).
  Future<void> ensureInitialized() async {
    if (_initialized) return;
    final inFlight = _initFuture;
    if (inFlight != null) {
      await inFlight;
    }
  }

  Future<void> _doInitialize(
      DataStoreConfig config, DataStoreImpl dataStore) async {
    if (_initialized) return;

    // Store data store reference for accessing cache managers
    _dataStore = dataStore;

    // Set memory threshold
    await _configureMemoryThreshold(config);

    // Calculate cache sizes
    _calculateCacheSizes();

    // Establish an actual resource state before accepting operations instead
    // of waiting for the first periodic monitor tick.
    try {
      final info = await getMemoryInfo();
      await _updateResourceStatus(cacheUsageBytes: info.totalUsageBytes);
    } catch (e) {
      Logger.warn('Initial resource status check failed', rawError: e);
    }

    // Register resource monitoring task
    _registerResourceMonitor();

    _initialized = true;
  }

  /// Total physical system memory in MB (cached on initialization).
  int _systemMemoryMB = 0;
  int get systemMemoryMB => _systemMemoryMB;

  /// Cached warning memory threshold in MB.
  int _warningMemoryThresholdMB = 256;
  int get warningMemoryThresholdMB => _warningMemoryThresholdMB;

  /// Cached critical memory threshold in MB.
  int _criticalMemoryThresholdMB = 32;
  int get criticalMemoryThresholdMB => _criticalMemoryThresholdMB;

  /// Cached recovery hysteresis margin in MB.
  int _recoveryMarginMB = 64;
  int get recoveryMarginMB => _recoveryMarginMB;

  /// Last sampled available system memory in MB (from resource status check).
  int _lastAvailableMemoryMB = 0;

  /// Configure memory threshold (total cache budget) and OS safety thresholds.
  Future<void> _configureMemoryThreshold(DataStoreConfig config) async {
    try {
      // Get available system memory and total memory
      int availableMemoryMB =
          await PlatformHandler.getAvailableSystemMemoryMB();
      int systemMemoryMB = await PlatformHandler.getSystemMemoryMB();
      _systemMemoryMB = systemMemoryMB;
      // OS warning band from init-time headroom (see calculateWarning...).
      _warningMemoryThresholdMB = calculateWarningMemoryThresholdMB(
        systemMemoryMB,
        availableMemoryMB: availableMemoryMB,
      );
      _criticalMemoryThresholdMB =
          calculateCriticalMemoryThresholdMB(systemMemoryMB);
      _recoveryMarginMB = max(64, (systemMemoryMB * 0.03).toInt());

      // Default budget: 75% of available at first init (fixed for process lifetime).
      final int baseMemoryMB = (availableMemoryMB * 0.75).toInt();

      // Soft ceiling so an oversized user budget cannot push the process into OOM.
      final int maxBudgetMB = max(
        _getMinimumMemoryThreshold(),
        min(
          (availableMemoryMB * 0.9).toInt(),
          max(0, systemMemoryMB - _criticalMemoryThresholdMB),
        ),
      );

      if (config.cacheMemoryBudgetMB != null &&
          config.cacheMemoryBudgetMB! > 0) {
        _memoryThresholdInMB = min(config.cacheMemoryBudgetMB!, maxBudgetMB);
      } else {
        _memoryThresholdInMB = min(baseMemoryMB, maxBudgetMB);
      }

      // Ensure memory threshold is not less than minimum value
      _memoryThresholdInMB =
          max(_memoryThresholdInMB, _getMinimumMemoryThreshold());
      _refreshBudgetUsageThresholds();
    } catch (e) {
      Logger.error('Failed to configure memory threshold', rawError: e);
      // Set default threshold
      _memoryThresholdInMB = _getDefaultMemoryThreshold();
      _systemMemoryMB = _getDefaultMemoryThreshold() * 2;
      _warningMemoryThresholdMB =
          calculateWarningMemoryThresholdMB(_systemMemoryMB);
      _criticalMemoryThresholdMB =
          calculateCriticalMemoryThresholdMB(_systemMemoryMB);
      _recoveryMarginMB = 64;
      _refreshBudgetUsageThresholds();
    }
  }

  /// Derive budget limit (100%) and safe target (80%) byte thresholds.
  void _refreshBudgetUsageThresholds() {
    final budgetBytes = _memoryThresholdInMB * 1024 * 1024;
    _budgetLimitUsageBytes = budgetBytes;
    _budgetWarningUsageBytes = (budgetBytes * _budgetWarningRatio).toInt();
  }

  /// Get minimum memory threshold
  int _getMinimumMemoryThreshold() {
    if (PlatformHandler.isWeb) {
      return 64; // Web environment minimum 64MB
    } else if (PlatformHandler.isMobile) {
      return 128; // Mobile device minimum 128MB
    } else {
      return 256; // Desktop and server environment minimum 256MB
    }
  }

  /// Get default memory threshold
  int _getDefaultMemoryThreshold() {
    if (PlatformHandler.isWeb) {
      return 128; // Web default 128MB
    } else if (PlatformHandler.isMobile) {
      return 512; // Mobile device default 512MB
    } else if (PlatformHandler.isServerEnvironment) {
      return 2048; // Server default 2GB
    } else {
      return 1024; // Desktop default 1GB
    }
  }

  /// Current interval used for periodic resource monitoring
  ExecuteInterval _currentMonitorInterval = ExecuteInterval.seconds30;

  /// Consecutive sample count showing normal memory levels before downgrading to 30s
  int _normalRecoveryCount = 0;

  /// Whether the database is currently experiencing active disk flush pressure
  bool get _isFlushBusy =>
      _dataStore?.parallelJournalManager.pressureState ==
      FlushPressureState.busy;

  /// Current recommended cache eviction ratio based on status severity
  double get currentEvictionRatio =>
      getEvictionRatio(MemoryQuotaType.tableData);

  /// Estimated pending+in-flight flush heap (bytes), or 0 if unavailable.
  int _estimatePendingFlushBytes() {
    final ds = _dataStore;
    if (ds == null || ds.isBaseInitialized != true) return 0;
    try {
      return ds.parallelJournalManager.estimatedPendingFlushBytes;
    } catch (_) {
      return 0;
    }
  }

  /// Structured cache + pending-flush estimate × [_pendingFlushBudgetFactor].
  int _projectedUsageBytes(int cacheUsageBytes) {
    final pending = _estimatePendingFlushBytes();
    return cacheUsageBytes + (pending * _pendingFlushBudgetFactor).toInt();
  }

  /// Base eviction ratio from deficit vs current cache footprint.
  ///
  /// Reactive: free enough that projected (cache+pending×1.5) fits in the
  /// full budget, and/or lift OS available above warning. Prefer not cutting
  /// structured cache below budget*80% when projected is already under limit.
  /// One-shot: uses [oneShotNeedFreeMB] from [requestHeadroom] only.
  double _baseEvictionRatio({int? oneShotNeedFreeMB}) {
    if (oneShotNeedFreeMB != null) {
      final cacheMB = max(1, _lastMeasuredTotalUsageBytes ~/ (1024 * 1024));
      final ratio = (oneShotNeedFreeMB / cacheMB) * 1.5;
      return ratio.clamp(0.30, 0.75);
    }

    if (_status == ResourceStatus.normal) return 0.20;

    final cacheMB = max(1, _lastMeasuredTotalUsageBytes ~/ (1024 * 1024));
    final usageMB = _lastMeasuredTotalUsageBytes ~/ (1024 * 1024);
    final projectedMB =
        _projectedUsageBytes(_lastMeasuredTotalUsageBytes) ~/ (1024 * 1024);
    final limitMB = _budgetLimitUsageBytes ~/ (1024 * 1024);
    final safeTargetMB = _budgetWarningUsageBytes ~/ (1024 * 1024);

    // Over full budget (incl. pending): free the projected overrun.
    // Otherwise (e.g. OS-only warning): trim cache toward 80% safe target.
    final budgetNeedFreeMB = limitMB > 0 && projectedMB > limitMB
        ? projectedMB - limitMB
        : max(0, usageMB - safeTargetMB);
    final osNeedFreeMB =
        max(0, _warningMemoryThresholdMB - _lastAvailableMemoryMB);

    final needFreeMB = max(budgetNeedFreeMB, osNeedFreeMB);
    final ratio = (needFreeMB / cacheMB) * 1.5;

    if (_status == ResourceStatus.critical) {
      return ratio.clamp(0.55, 1.0);
    }
    return ratio.clamp(0.30, 0.75);
  }

  /// Eviction ratio for [type]. Light scale only — no extra memory probes.
  double getEvictionRatio(MemoryQuotaType type, {int? oneShotNeedFreeMB}) {
    final base = _baseEvictionRatio(oneShotNeedFreeMB: oneShotNeedFreeMB);
    switch (type) {
      case MemoryQuotaType.queryResult:
        return (base * 1.25).clamp(0.0, 1.0);
      case MemoryQuotaType.tableData:
        return base;
      case MemoryQuotaType.indexData:
      case MemoryQuotaType.vectorIndex:
        // CRITICAL: dump pages aggressively. Otherwise gentler, tighter if flush busy.
        if (_status == ResourceStatus.critical) {
          return base.clamp(0.55, 1.0);
        }
        final scaled = _isFlushBusy ? base * 0.55 : base * 0.75;
        return scaled.clamp(0.15, 0.50);
      case MemoryQuotaType.schema:
      case MemoryQuotaType.meta:
        return 0.0;
    }
  }

  /// Hot record maps (heap-heavy) — slightly above base.
  double getRecordCacheEvictionRatio({int? oneShotNeedFreeMB}) {
    final base = _baseEvictionRatio(oneShotNeedFreeMB: oneShotNeedFreeMB);
    if (_status == ResourceStatus.critical) {
      return base.clamp(0.55, 1.0);
    }
    return (base * 1.1).clamp(0.30, 0.85);
  }

  /// B+Tree page caches — below base to protect flush IO.
  double getPageCacheEvictionRatio({int? oneShotNeedFreeMB}) {
    final base = _baseEvictionRatio(oneShotNeedFreeMB: oneShotNeedFreeMB);
    if (_status == ResourceStatus.critical) {
      return base.clamp(0.55, 1.0);
    }
    final scaled = _isFlushBusy ? base * 0.50 : base * 0.70;
    return scaled.clamp(0.15, 0.45);
  }

  /// Current eviction cooldown duration in seconds based on severity and flush pressure
  int get _currentEvictionCooldownSeconds {
    switch (_status) {
      case ResourceStatus.critical:
        return 1;
      case ResourceStatus.warning:
        // Short LOW cooldown so continuous inserts reclaim before CRITICAL.
        return _isFlushBusy ? 1 : 2;
      case ResourceStatus.normal:
        return 10;
    }
  }

  /// OS polling safeguard (available MB below this → warning eviction).
  ///
  /// Init-time headroom decides how early to fire (fixed for process lifetime):
  /// - [availableMemoryMB] >= 32% of system (≈ used ≤ 68%) → warn at
  ///   available < 25% (≈ used 75%), leaving room for vector split / page-redo
  /// - otherwise (already tight) → warn at available < 10% (≈ used 90%)
  ///   to avoid thrashing cleanup on constrained devices
  static int calculateWarningMemoryThresholdMB(
    int systemMemoryMB, {
    int? availableMemoryMB,
  }) {
    if (systemMemoryMB <= 0) return 64;
    // 32%: hosts often already sit near ~68% used at open.
    final hasHeadroom = availableMemoryMB != null &&
        availableMemoryMB >= (systemMemoryMB * 0.32).toInt();
    final ratio = hasHeadroom ? 0.25 : 0.10;
    final ratioMB = (systemMemoryMB * ratio).toInt();
    return ratioMB.clamp(64, hasHeadroom ? 4096 : 2048);
  }

  /// Calculate dynamic critical threshold in MB based on total system memory.
  /// Uses 3.5% of total system memory as baseline, capped at 512 MB and floored
  /// at 32 MB for emergency write blocking.
  static int calculateCriticalMemoryThresholdMB(int systemMemoryMB) {
    if (systemMemoryMB <= 0) return 32;
    final ratioMB = (systemMemoryMB * 0.035).toInt();
    return ratioMB.clamp(32, 512);
  }

  /// Register resource monitoring periodic task
  void _registerResourceMonitor() {
    _currentMonitorInterval = ExecuteInterval.seconds30;
    _normalRecoveryCount = 0;
    CrontabManager.addCallback(_currentMonitorInterval, _checkResourceUsage);
  }

  /// Adapt monitor interval dynamically based on resource status
  void _adjustMonitorInterval(ResourceStatus status) {
    if (status != ResourceStatus.normal) {
      _normalRecoveryCount = 0;
      if (_currentMonitorInterval != ExecuteInterval.seconds3) {
        CrontabManager.removeCallback(
            _currentMonitorInterval, _checkResourceUsage);
        _currentMonitorInterval = ExecuteInterval.seconds3;
        CrontabManager.addCallback(
            _currentMonitorInterval, _checkResourceUsage);
      }
    } else {
      _normalRecoveryCount++;
      if (_normalRecoveryCount >= 2 &&
          _currentMonitorInterval != ExecuteInterval.seconds30) {
        CrontabManager.removeCallback(
            _currentMonitorInterval, _checkResourceUsage);
        _currentMonitorInterval = ExecuteInterval.seconds30;
        CrontabManager.addCallback(
            _currentMonitorInterval, _checkResourceUsage);
      }
    }
  }

  // Throttle immediate checks to avoid storming the resource manager
  DateTime _lastImmediateCheckTime = DateTime.fromMillisecondsSinceEpoch(0);

  /// Trigger an immediate resource check (bypassing the timer).
  ///
  /// Useful when large operations finish and system pressure might have changed.
  /// Pass [force] to skip the throttle (e.g. write-admission wait loops).
  Future<void> triggerImmediateCheck({bool force = false}) async {
    final now = DateTime.now();
    if (!force) {
      final int throttleMs = _isFlushBusy ? 500 : 2000;
      if (now.difference(_lastImmediateCheckTime).inMilliseconds < throttleMs) {
        return;
      }
    }
    _lastImmediateCheckTime = now;
    await _checkResourceUsage();
  }

  /// Fire-and-forget headroom for an upcoming flush/allocation peak.
  ///
  /// Only acts when `usage + estimated` would cross budget*80%. Per-cache
  /// self-eviction handles steady-state; this relieves temporary batch pressure.
  /// Never await from insert/flush hot paths.
  void requestHeadroom(int estimatedBytes) {
    if (estimatedBytes < _minHeadroomBytes) return;
    if (_budgetWarningUsageBytes <= 0) return;

    // Fast reject when idle and projected usage stays under the safe ceiling.
    if (!_isCleaning &&
        _lastMeasuredTotalUsageBytes + estimatedBytes <
            _budgetWarningUsageBytes) {
      return;
    }

    Future(() async {
      try {
        for (var attempt = 0; attempt < 3; attempt++) {
          if (_isCleaning) {
            await _waitUntilCleaningDone();
          }

          final info = await getMemoryInfo();
          _lastMeasuredTotalUsageBytes = info.totalUsageBytes;

          final projectedUsage = _lastMeasuredTotalUsageBytes + estimatedBytes;
          if (projectedUsage < _budgetWarningUsageBytes) return;

          final needFreeMB = max(
            0,
            (projectedUsage - _budgetWarningUsageBytes + (1024 * 1024) - 1) ~/
                (1024 * 1024),
          );
          if (needFreeMB <= 0) return;

          if (_isCleaning) continue;

          _triggerCacheEviction(oneShotNeedFreeMB: needFreeMB);
          return;
        }
      } catch (e) {
        if (e is DbClosedException) return;
        Logger.warn('requestHeadroom failed', rawError: e);
      }
    });
  }

  /// Await the in-flight eviction Future if any.
  Future<void> _waitUntilCleaningDone() async {
    final done = _cleaningDone;
    if (!_isCleaning || done == null) return;
    await done.future;
  }

  /// Check resource usage (Memory and Disk) and trigger cleanup if needed
  Future<void> _checkResourceUsage() async {
    try {
      final info = await getMemoryInfo();
      await _updateResourceStatus(
        forceRefresh: true,
        cacheUsageBytes: info.totalUsageBytes,
      );

      if (_status != ResourceStatus.normal) {
        _triggerCacheEviction(info: info);
      }

      _dataStore?.updatePressureStatus();
    } catch (e) {
      Logger.error('Failed to check resource usage', rawError: e);
    }
  }

  /// Update resource status.
  ///
  /// - critical: OS available < critical (write admission wait / reject)
  /// - warning: `cache + pendingFlush×1.5` > [_budgetLimitUsageBytes] (full
  ///   budget), or OS available below init-time warning band (~25% or ~10%)
  /// - flush [requestHeadroom] still uses budget*80% for a single batch peak
  Future<void> _updateResourceStatus({
    bool forceRefresh = false,
    int? cacheUsageBytes,
  }) async {
    final availableMemoryMB = await PlatformHandler.getAvailableSystemMemoryMB(
        forceRefresh: forceRefresh);
    _lastAvailableMemoryMB = availableMemoryMB;
    final availableDiskMB = await _getAvailableDiskSpace();

    _refreshEffectivePrewarmThresholdMB(availableMemoryMB);

    final totalSysMB = _systemMemoryMB > 0 ? _systemMemoryMB : 1024;
    final usageBytes = cacheUsageBytes ?? _lastMeasuredTotalUsageBytes;
    if (cacheUsageBytes != null) {
      _lastMeasuredTotalUsageBytes = cacheUsageBytes;
    }

    // Include entire pending flush queue (not just the batch about to flush).
    final projectedBytes = _projectedUsageBytes(usageBytes);

    ResourceStatus memoryStatus = ResourceStatus.normal;
    if (availableMemoryMB < _criticalMemoryThresholdMB) {
      memoryStatus = ResourceStatus.critical;
    } else {
      // Poll against full budget so idle cache can still use up to 100%.
      // Pending flush ×1.5 is included; warning clears only when projected fits.
      _budgetTrimActive =
          _budgetLimitUsageBytes > 0 && projectedBytes > _budgetLimitUsageBytes;

      // OS poll: available below init-time warning band (~25% or ~10%).
      final osWarn = availableMemoryMB < _warningMemoryThresholdMB;
      final osRecovered =
          availableMemoryMB >= _warningMemoryThresholdMB + _recoveryMarginMB;
      if (_budgetTrimActive ||
          osWarn ||
          (_memoryStatus != ResourceStatus.normal &&
              !_budgetTrimActive &&
              !osRecovered)) {
        memoryStatus = ResourceStatus.warning;
      }
    }
    _memoryStatus = memoryStatus;

    // Determine disk status
    ResourceStatus diskStatus = ResourceStatus.normal;
    if (availableDiskMB < 20) {
      diskStatus = ResourceStatus.critical;
    } else if (availableDiskMB < 100) {
      diskStatus = ResourceStatus.warning;
    }
    _diskStatus = diskStatus;

    // Combined status (take the most severe)
    final newStatus =
        ResourceStatus.values[max(memoryStatus.index, diskStatus.index)];

    if (newStatus != _status) {
      final usageMB = usageBytes ~/ (1024 * 1024);
      if (newStatus == ResourceStatus.critical) {
        final ResultType type = (diskStatus == ResourceStatus.critical &&
                memoryStatus == ResourceStatus.critical)
            ? ResultType.sysResourceExhausted
            : (diskStatus == ResourceStatus.critical
                ? ResultType.sysIoDiskFull
                : ResultType.sysResourceExhaustedMemory);

        final msg =
            'CRITICAL RESOURCE SHORTAGE! Write admission will wait (file mode) '
            'or reject (memory mode / disk full). Memory: $availableMemoryMB/'
            '$totalSysMB MB, cache: $usageMB/$_memoryThresholdInMB MB, '
            'Disk: $availableDiskMB MB';
        Logger.critical(msg,
            rawError: GeneralStatus(
              type: type,
              message: msg,
            ));
      } else if (newStatus == ResourceStatus.warning) {
        if (InternalConfig.showInternalLogs) {
          Logger.debug(
            'Low resources detected! Triggering cache eviction. Memory: $availableMemoryMB/$totalSysMB MB, cache: $usageMB/$_memoryThresholdInMB MB, Disk: $availableDiskMB MB',
          );
        }
      } else if (InternalConfig.showInternalLogs) {
        Logger.debug(
          'Resources recovered to normal levels. Memory: $availableMemoryMB/$totalSysMB MB, cache: $usageMB/$_memoryThresholdInMB MB, Disk: $availableDiskMB MB',
        );
      }
      _status = newStatus;
    }

    // Adapt monitor interval dynamically based on resource status
    _adjustMonitorInterval(_status);
  }

  /// Get current available disk space for the database path
  Future<double> _getAvailableDiskSpace() async {
    if (_dataStore == null || _dataStore!.instancePath == null) {
      return 10240.0; // 10GB safe default
    }
    try {
      final int mb =
          await PlatformHandler.getDiskFreeSpaceMB(_dataStore!.instancePath!);
      return mb.toDouble();
    } catch (e) {
      Logger.warn('Failed to get disk space', rawError: e);
      return 10240.0;
    }
  }

  /// Trigger cache cleanup.
  ///
  /// Runs up to 3 full passes while status stays above [ResourceStatus.normal],
  /// re-checking OS memory and cache usage after each cache type so a single
  /// under-sized pass cannot leave CRITICAL stuck until the next cron.
  ///
  /// When [oneShotNeedFreeMB] is set (from [requestHeadroom]), runs one pass
  /// even if status is still normal, passing that deficit into ratio getters
  /// for this call only (no instance reserve state).
  ///
  /// Concurrent callers while a pass is running set [_evictionRetriggerPending]
  /// instead of dropping the pressure signal; a follow-up pass is scheduled
  /// after the in-flight work completes if status is still elevated.
  void _triggerCacheEviction({MemoryInfo? info, int? oneShotNeedFreeMB}) {
    if (_isCleaning) {
      _evictionRetriggerPending = true;
      return;
    }

    final isOneShot = oneShotNeedFreeMB != null && oneShotNeedFreeMB > 0;
    final now = DateTime.now();

    // One-shot headroom must not wait for the normal-path 10s cooldown.
    final cooldownSeconds =
        isOneShot ? (_isFlushBusy ? 1 : 2) : _currentEvictionCooldownSeconds;
    if (now.difference(_lastCacheClearTime).inSeconds < cooldownSeconds) {
      return;
    }

    _isCleaning = true;
    _cleaningDone = Completer<void>();
    _lastCacheClearTime = now;

    // Run the entire eviction process asynchronously.
    Future(() async {
      try {
        final maxRounds = isOneShot ? 1 : 3;
        MemoryInfo? roundInfo = info;

        for (var round = 0; round < maxRounds; round++) {
          if (!isOneShot && _status == ResourceStatus.normal) return;

          final currentInfo = roundInfo ?? await getMemoryInfo();
          roundInfo = null;
          final totalUsage = currentInfo.totalUsageBytes;
          final underPressure = isOneShot || _status != ResourceStatus.normal;

          if (totalUsage <= 0) return;
          if (!underPressure && totalUsage < _getMinTotalCacheToEvict()) {
            return;
          }

          await _evictCacheAndCheck(MemoryQuotaType.tableData,
              oneShotNeedFreeMB: oneShotNeedFreeMB);
          if (_headroomSatisfied(isOneShot)) return;

          await _evictCacheAndCheck(MemoryQuotaType.queryResult,
              oneShotNeedFreeMB: oneShotNeedFreeMB);
          if (_headroomSatisfied(isOneShot)) return;

          await _evictCacheAndCheck(MemoryQuotaType.indexData,
              oneShotNeedFreeMB: oneShotNeedFreeMB);
          if (_headroomSatisfied(isOneShot)) return;

          await _evictCacheAndCheck(MemoryQuotaType.vectorIndex,
              oneShotNeedFreeMB: oneShotNeedFreeMB);
          if (_headroomSatisfied(isOneShot)) return;
        }
      } catch (e) {
        if (e is DbClosedException) return;
        Logger.error('An error occurred during cache eviction process',
            rawError: e);
      } finally {
        _isCleaning = false;
        final done = _cleaningDone;
        _cleaningDone = null;
        if (done != null && !done.isCompleted) {
          done.complete();
        }
        if (_evictionRetriggerPending) {
          _evictionRetriggerPending = false;
          unawaited(_retriggerEvictionIfNeeded());
        }
      }
    });
  }

  /// After a concurrent eviction request was coalesced, re-sample and start
  /// another pass if pressure remains.
  Future<void> _retriggerEvictionIfNeeded() async {
    try {
      final info = await getMemoryInfo();
      await _updateResourceStatus(
        forceRefresh: true,
        cacheUsageBytes: info.totalUsageBytes,
      );
      if (_status != ResourceStatus.normal) {
        _triggerCacheEviction(info: info);
      }
    } catch (e) {
      if (e is DbClosedException) return;
      Logger.warn('Eviction retrigger failed', rawError: e);
    }
  }

  /// Stop when usage is back under budget*80% (one-shot) or status is normal.
  bool _headroomSatisfied(bool isOneShot) {
    if (isOneShot) {
      return _budgetWarningUsageBytes <= 0 ||
          _lastMeasuredTotalUsageBytes <= _budgetWarningUsageBytes;
    }
    return _status == ResourceStatus.normal;
  }

  /// Evict a specific cache type and then refresh the resource status.
  Future<void> _evictCacheAndCheck(
    MemoryQuotaType cacheType, {
    int? oneShotNeedFreeMB,
  }) async {
    await _evictCacheByType(cacheType, oneShotNeedFreeMB: oneShotNeedFreeMB);

    // Refresh status after eviction with fresh OS + cache usage readings.
    final info = await getMemoryInfo();
    await _updateResourceStatus(
      forceRefresh: true,
      cacheUsageBytes: info.totalUsageBytes,
    );
  }

  /// Execute specific type cache cleanup
  Future<void> _evictCacheByType(
    MemoryQuotaType cacheType, {
    int? oneShotNeedFreeMB,
  }) async {
    final callback = _cacheEvictionCallbacks[cacheType];
    if (callback == null) return;

    try {
      // Measure cache size before eviction for relevant cache types
      int beforeSize = await _getCurrentCacheSizeByType(cacheType);

      // Guard check: skip if cache size is below minimum threshold
      final minThreshold = _getMinEvictThreshold(cacheType);
      if (beforeSize < minThreshold) {
        return;
      }

      // Execute eviction callback, which might be async
      final result = callback(oneShotNeedFreeMB: oneShotNeedFreeMB);
      if (result is Future) {
        await result;
      }

      // Measure cache size after eviction to verify the cleanup effect
      int afterSize = await _getCurrentCacheSizeByType(cacheType);
      final freedBytes = beforeSize > afterSize ? beforeSize - afterSize : 0;

      // Meaningful reclaim only; gated like other engine-internal diagnostics.
      if (InternalConfig.showInternalLogs && freedBytes >= 1 * 1024 * 1024) {
        final freedMB = freedBytes / (1024 * 1024);
        final remainMB = afterSize / (1024 * 1024);
        final protectMB = minThreshold / (1024 * 1024);
        Logger.debug('Cache eviction for ${cacheType.name}: '
            'freed ${freedMB.toStringAsFixed(2)}MB, '
            'remain ${remainMB.toStringAsFixed(1)}MB '
            '(protect ${protectMB.toStringAsFixed(0)}MB)');
      }
    } catch (e) {
      if (e is DbClosedException) return;
      Logger.error('Error in cache eviction callback for ${cacheType.name}',
          rawError: e);
    }
  }

  /// Get current cache size by type using appropriate cache manager methods
  Future<int> _getCurrentCacheSizeByType(MemoryQuotaType cacheType) async {
    if (_dataStore == null) return 0;

    try {
      switch (cacheType) {
        case MemoryQuotaType.tableData:
          return _dataStore!.cacheManager.getCurrentTableDataCacheSize();
        case MemoryQuotaType.queryResult:
          return _dataStore!.cacheManager.getCurrentQueryCacheSize();
        case MemoryQuotaType.indexData:
          return await _dataStore!.indexManager
                  ?.getCurrentBtreeIndexDataCacheSize() ??
              0;
        case MemoryQuotaType.vectorIndex:
          return _dataStore!.vectorIndexManager?.getCurrentCacheSize() ?? 0;
        case MemoryQuotaType.schema:
          return _dataStore!.cacheManager.getCurrentSchemaCacheSize();
        case MemoryQuotaType.meta:
          // Meta cache = Table Data Meta + Index Meta (Data excluded)
          final tableDataMetaSize =
              _dataStore!.tableDataManager.getCurrentTableDataMetaCacheSize();
          final indexMetaSize =
              await _dataStore!.indexManager?.getCurrentIndexMetaCacheSize() ??
                  0;
          return tableDataMetaSize + indexMetaSize;
      }
    } catch (e) {
      if (e is DbClosedException || _dataStore?.isBaseInitialized != true) {
        return 0;
      }
      Logger.warn('Failed to get current cache size for ${cacheType.name}',
          rawError: e);
      return 0;
    }
  }

  /// Calculate cache sizes from the total budget.
  void _calculateCacheSizes() {
    // Convert MB to bytes
    int totalThresholdBytes = _memoryThresholdInMB * 1024 * 1024;
    _refreshBudgetUsageThresholds();

    // Allocate cache sizes based on predefined ratios
    _tableDataCacheSize = (totalThresholdBytes * _tableDataCacheRatio).toInt();
    _indexCacheSize = (totalThresholdBytes * _indexCacheRatio).toInt();
    _queryCacheSize = (totalThresholdBytes * _queryCacheRatio).toInt();
    _schemaCacheSize = (totalThresholdBytes * _schemaCacheRatio).toInt();
    _metaCacheSize = (totalThresholdBytes * _metaCacheRatio).toInt();
    _dataStore?.vectorIndexManager?.syncVectorSearchCacheBudget();
  }

  /// Register cache eviction callback
  void registerCacheEvictionCallback(
      MemoryQuotaType cacheType, CacheEvictionCallback callback) {
    _cacheEvictionCallbacks[cacheType] = callback;
  }

  /// Unregister cache eviction callback
  void unregisterCacheEvictionCallback(MemoryQuotaType cacheType) {
    _cacheEvictionCallbacks[cacheType] = null;
  }

  /// Get table data cache size limit
  int getTableDataCacheSize() => _tableDataCacheSize;

  /// Get record cache size limit
  int getRecordCacheSize() => (_tableDataCacheSize * 0.7).toInt();

  /// Get index cache size limit
  int getIndexCacheSize() => _indexCacheSize;

  /// Get query cache size limit
  int getQueryCacheSize() => _queryCacheSize;

  /// Get schema cache size limit
  int getSchemaCacheSize() => _schemaCacheSize;

  /// Get table data and index all meta cache size limit
  int getMetaCacheSize() => _metaCacheSize;

  int? _effectivePrewarmThresholdMB;

  /// Initialize or refresh the shared effective prewarm threshold (MB).
  ///
  /// Startup cache prewarm and runtime query prewarm use the same dynamic
  /// threshold. Resource polling refreshes it from available memory later.
  Future<int> initializeEffectivePrewarmThresholdMB() async {
    final availableMemoryMB =
        await PlatformHandler.getAvailableSystemMemoryMB();
    _refreshEffectivePrewarmThresholdMB(availableMemoryMB);
    return _effectivePrewarmThresholdMB!;
  }

  /// Get the latest effective runtime prewarm threshold (MB).
  int getEffectivePrewarmThresholdMB() {
    return _effectivePrewarmThresholdMB ?? _getMinimumPrewarmThresholdMB();
  }

  void _refreshEffectivePrewarmThresholdMB(int availableMemoryMB) {
    try {
      final minimum = _getMinimumPrewarmThresholdMB();
      final memoryBased = max(
        (availableMemoryMB * 0.3).floor(),
        minimum,
      );

      final configured = _dataStore?.config.prewarmThresholdMB;
      if (configured != null && configured > 0) {
        _effectivePrewarmThresholdMB = max(1, min(configured, memoryBased));
      } else {
        _effectivePrewarmThresholdMB = memoryBased;
      }
    } catch (_) {
      _effectivePrewarmThresholdMB = _getMinimumPrewarmThresholdMB();
    }
  }

  static int _getMinimumPrewarmThresholdMB() {
    if (PlatformHandler.isWeb) return 32;
    if (PlatformHandler.isMobile) return 32;
    if (PlatformHandler.isServerEnvironment) return 256;
    return 128;
  }

  /// Get current resource status
  ResourceStatus get status => _status;

  /// Get current memory status without conflating it with disk pressure.
  ResourceStatus get memoryStatus => _memoryStatus;

  /// Get current disk status without conflating it with memory pressure.
  ResourceStatus get diskStatus => _diskStatus;

  /// Whether disk space is critically low (writes cannot recover by waiting).
  bool get isDiskCritical => _diskStatus == ResourceStatus.critical;

  /// Whether combined resources are critical (memory and/or disk).
  ///
  /// Prefer [awaitWriteAdmission] at public write entry points: file-mode
  /// memory pressure waits for flush/eviction; disk-full / memory-mode reject.
  bool get isWriteBlocked => _status == ResourceStatus.critical;

  /// Await write admission under resource pressure.
  ///
  /// Returns `true` when the caller may proceed, `false` when the write should
  /// be rejected:
  /// - not critical → admit immediately
  /// - disk critical → reject (waiting cannot free disk)
  /// - [isMemoryMode] → reject (waiting cannot free committed in-memory data)
  /// - file mode + memory critical → kick recovery and wait until status leaves
  ///   critical or [timeout] elapses
  Future<bool> awaitWriteAdmission({
    required bool isMemoryMode,
    Duration timeout = defaultWriteAdmissionTimeout,
    Future<void> Function()? onKickRecovery,
  }) async {
    if (_status != ResourceStatus.critical) return true;
    if (isDiskCritical) return false;
    if (isMemoryMode) return false;

    final deadline = DateTime.now().add(timeout);
    while (_status == ResourceStatus.critical) {
      if (isDiskCritical) return false;
      if (DateTime.now().isAfter(deadline)) return false;

      if (onKickRecovery != null) {
        try {
          await onKickRecovery();
        } catch (_) {
          // Best-effort: flush/eviction kick must not abort admission wait.
        }
      }
      await triggerImmediateCheck(force: true);
      if (_status != ResourceStatus.critical) return true;
      if (isDiskCritical) return false;
      if (DateTime.now().isAfter(deadline)) return false;

      await Future.delayed(const Duration(milliseconds: 1000));
    }
    return true;
  }

  /// Whether resources are low (warning or critical), triggers cache cleanup
  bool get isLowMemoryMode => _status != ResourceStatus.normal;

  /// Get last measured total cache usage in MB
  int get lastMeasuredTotalUsageMB =>
      _lastMeasuredTotalUsageBytes ~/ (1024 * 1024);

  /// Get current memory and cache usage information
  Future<MemoryInfo> getMemoryInfo() async {
    final tableDataUsage =
        await _getCurrentCacheSizeByType(MemoryQuotaType.tableData);
    final indexUsage =
        await _getCurrentCacheSizeByType(MemoryQuotaType.indexData);
    final vectorUsage =
        await _getCurrentCacheSizeByType(MemoryQuotaType.vectorIndex);
    final queryUsage =
        await _getCurrentCacheSizeByType(MemoryQuotaType.queryResult);
    final schemaUsage =
        await _getCurrentCacheSizeByType(MemoryQuotaType.schema);
    final metaUsage = await _getCurrentCacheSizeByType(MemoryQuotaType.meta);

    final totalUsage = tableDataUsage +
        indexUsage +
        vectorUsage +
        queryUsage +
        schemaUsage +
        metaUsage;

    final info = MemoryInfo(
      totalThresholdMB: _memoryThresholdInMB,
      tableDataCacheUsage: tableDataUsage,
      tableDataCacheLimit: _tableDataCacheSize,
      indexCacheUsage: indexUsage + vectorUsage,
      indexCacheLimit: _indexCacheSize,
      queryCacheUsage: queryUsage,
      queryCacheLimit: _queryCacheSize,
      schemaCacheUsage: schemaUsage,
      schemaCacheLimit: _schemaCacheSize,
      metaCacheUsage: metaUsage,
      metaCacheLimit: _metaCacheSize,
      isLowMemoryMode: _status != ResourceStatus.normal,
      totalUsageBytes: totalUsage,
    );

    // Sync last measured total usage whenever info is gathered
    _lastMeasuredTotalUsageBytes = totalUsage;

    return info;
  }

  /// Get baseline protection threshold for specific cache type
  int _getMinEvictThreshold(MemoryQuotaType type) {
    final total = _getMinTotalCacheToEvict();
    switch (type) {
      case MemoryQuotaType.tableData:
        return (total * 0.5).toInt(); // 50% of protection budget
      case MemoryQuotaType.indexData:
        return (total * 0.25).toInt(); // 25%
      case MemoryQuotaType.vectorIndex:
        return (total * 0.25).toInt(); // 25%
      case MemoryQuotaType.queryResult:
        return (total * 0.125).toInt(); // 12.5%
      case MemoryQuotaType.schema:
        return (total * 0.0625).toInt(); // 6.25%
      case MemoryQuotaType.meta:
        return (total * 0.0625).toInt(); // 6.25%
    }
  }

  /// Get global minimum total cache size to trigger any eviction based on platform
  int _getMinTotalCacheToEvict() {
    int baselineBytes;
    if (PlatformHandler.isServerEnvironment) {
      baselineBytes = 512 * 1024 * 1024; // 512MB for high-throughput servers
    } else if (PlatformHandler.isDesktop) {
      baselineBytes = 256 * 1024 * 1024; // 256MB for desktops
    } else if (PlatformHandler.isWeb) {
      baselineBytes = 64 * 1024 * 1024; // 64MB (more restricted environments)
    } else {
      baselineBytes = 128 * 1024 * 1024; // 128MB for modern mobile devices
    }

    // Baseline protection must never exceed 50% of configured total cache budget
    if (_memoryThresholdInMB > 0) {
      final maxAllowedBaseline =
          (_memoryThresholdInMB * 1024 * 1024 * 0.5).toInt();
      baselineBytes = min(baselineBytes, maxAllowedBaseline);
    }
    return max(baselineBytes, 16 * 1024 * 1024);
  }

  /// Clean up all resources
  void dispose() {
    // Deregister periodic monitor callback from CrontabManager
    CrontabManager.removeCallback(_currentMonitorInterval, _checkResourceUsage);
    _currentMonitorInterval = ExecuteInterval.seconds30;
    _normalRecoveryCount = 0;

    _cacheEvictionCallbacks.updateAll((key, value) => null);
    _dataStore = null;
    _effectivePrewarmThresholdMB = null;
    _status = ResourceStatus.normal;
    _memoryStatus = ResourceStatus.normal;
    _diskStatus = ResourceStatus.normal;
    _systemMemoryMB = 0;
    _memoryThresholdInMB = 0;
    _budgetLimitUsageBytes = 0;
    _budgetWarningUsageBytes = 0;
    _budgetTrimActive = false;
    _warningMemoryThresholdMB = 256;
    _criticalMemoryThresholdMB = 32;
    _recoveryMarginMB = 64;
    _lastAvailableMemoryMB = 0;
    _lastMeasuredTotalUsageBytes = 0;
    _isCleaning = false;
    _evictionRetriggerPending = false;
    final cleaningDone = _cleaningDone;
    _cleaningDone = null;
    if (cleaningDone != null && !cleaningDone.isCompleted) {
      cleaningDone.complete();
    }
    _initialized = false;
    _initFuture = null;
  }
}

/// Cache eviction callback. [oneShotNeedFreeMB] is set only for headroom
/// eviction from [ResourceManager.requestHeadroom]; otherwise null.
typedef CacheEvictionCallback = FutureOr<void> Function(
    {int? oneShotNeedFreeMB});

/// Memory quota allocation type (MemoryQuotaType), sorted by allocation priority
enum MemoryQuotaType {
  /// Table data cache (clean up first)
  tableData,

  /// Query result cache
  queryResult,

  /// Index data cache
  indexData,

  /// Vector / NGH ANN caches (after structured table+index still LOW)
  vectorIndex,

  /// Table structure cache (clean up last)
  schema,

  /// Table data and index all meta cache
  meta,
}
