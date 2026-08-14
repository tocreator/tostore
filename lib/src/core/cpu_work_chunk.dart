import 'dart:math' as math;

import '../handler/platform_handler.dart';
import 'yield_controller.dart';

/// Workload intensity for main-isolate CPU traversals.
///
/// [writeBatchSize] controls IO merge size; these sizes control how many
/// records of synchronous CPU work may run before yielding to the event loop.
enum CpuChunkKind {
  /// Pointer moves, map grouping, cheap filters.
  light,

  /// Field remaps, unique-key materialization, simple transforms.
  medium,

  /// Encode / crypto / index-delta style work (prefer isolate when available).
  heavy,
}

/// Platform-aware CPU work chunking for flush / batchInsert hot paths.
///
/// Goal: keep each synchronous stretch short enough that ~10--20 concurrent
/// chunks (via [ParallelProcessor] / workload tokens) still leave headroom
/// for the UI frame budget, without over-splitting into startup thrash.
class EngineCpuChunk {
  EngineCpuChunk._();

  /// Hard floor for light work -- smaller chunks cost more than they save.
  static const int minLightChunk = 512;

  /// Absolute floor for any kind.
  static const int minChunk = 64;

  /// Hot-path [YieldController] floor -- prevents dual-pressure avalanche to 1--10.
  static const int hotPathMinCheckInterval = 64;

  /// Resolve chunk size for [kind] (mobile/web halved, server doubled).
  static int sizeFor(CpuChunkKind kind) {
    int base;
    switch (kind) {
      case CpuChunkKind.light:
        base = 2048;
        break;
      case CpuChunkKind.medium:
        base = 1024;
        break;
      case CpuChunkKind.heavy:
        base = 256;
        break;
    }

    if (PlatformHandler.isServerEnvironment) {
      base = base * 2;
    } else if (PlatformHandler.isMobile || PlatformHandler.isWeb) {
      base = math.max(1, (base / 2).round());
    }

    if (kind == CpuChunkKind.light) {
      return math.max(minLightChunk, base);
    }
    return math.max(minChunk, base);
  }

  /// Run synchronous [process] over `[0, length)` in chunks; yield only between
  /// chunks when [YieldController] is enabled.
  static Future<void> forEachRange({
    required int length,
    required void Function(int start, int end) process,
    CpuChunkKind kind = CpuChunkKind.light,
    int? chunkSize,
    bool yieldBetweenChunks = true,
  }) async {
    if (length <= 0) return;
    final int cs = math.max(1, chunkSize ?? sizeFor(kind));
    final bool shouldYield =
        yieldBetweenChunks && YieldController.globalSettings.enabled;

    for (int start = 0; start < length; start += cs) {
      final int end = start + cs < length ? start + cs : length;
      process(start, end);
      if (shouldYield && end < length) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  /// Async chunk body (e.g. awaits inside the chunk); still yields between chunks.
  static Future<void> forEachRangeAsync({
    required int length,
    required Future<void> Function(int start, int end) process,
    CpuChunkKind kind = CpuChunkKind.light,
    int? chunkSize,
    bool yieldBetweenChunks = true,
  }) async {
    if (length <= 0) return;
    final int cs = math.max(1, chunkSize ?? sizeFor(kind));
    final bool shouldYield =
        yieldBetweenChunks && YieldController.globalSettings.enabled;

    for (int start = 0; start < length; start += cs) {
      final int end = start + cs < length ? start + cs : length;
      await process(start, end);
      if (shouldYield && end < length) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }

  /// Indexed list traversal with chunk-boundary yields only.
  static Future<void> forEachIndexed<T>(
    List<T> items,
    void Function(int index, T item) process, {
    CpuChunkKind kind = CpuChunkKind.light,
    int? chunkSize,
    bool yieldBetweenChunks = true,
  }) {
    return forEachRange(
      length: items.length,
      kind: kind,
      chunkSize: chunkSize,
      yieldBetweenChunks: yieldBetweenChunks,
      process: (start, end) {
        for (int i = start; i < end; i++) {
          process(i, items[i]);
        }
      },
    );
  }

  /// Iterable traversal without materializing; yield every [chunkSize] items.
  static Future<void> forEachIterable<T>(
    Iterable<T> items,
    void Function(T item) process, {
    CpuChunkKind kind = CpuChunkKind.light,
    int? chunkSize,
    bool yieldBetweenChunks = true,
  }) async {
    final int cs = math.max(1, chunkSize ?? sizeFor(kind));
    final bool shouldYield =
        yieldBetweenChunks && YieldController.globalSettings.enabled;
    var n = 0;
    for (final item in items) {
      process(item);
      n++;
      if (shouldYield && n % cs == 0) {
        await Future<void>.delayed(Duration.zero);
      }
    }
  }
}
