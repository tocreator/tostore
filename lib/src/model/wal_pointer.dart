/// Pointer to a WAL entry for ordered replay/flush
class WalPointer {
  final int partitionIndex;
  final int entrySeq;

  const WalPointer({required this.partitionIndex, required this.entrySeq});

  Map<String, dynamic> toJson() => {
        'partitionIndex': partitionIndex,
        'entrySeq': entrySeq,
      };

  factory WalPointer.fromJson(Map<String, dynamic> json) => WalPointer(
        partitionIndex: json['partitionIndex'] as int,
        entrySeq: json['entrySeq'] as int,
      );

  @override
  String toString() => 'WalPointer(p:$partitionIndex,e:$entrySeq)';

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is WalPointer &&
          runtimeType == other.runtimeType &&
          partitionIndex == other.partitionIndex &&
          entrySeq == other.entrySeq;

  @override
  int get hashCode => partitionIndex.hashCode ^ entrySeq.hashCode;

  /// Returns true if this pointer is newer than [other] in a circular WAL ring.
  bool isNewerThan(WalPointer other, int cycle) {
    if (cycle <= 0) return false;
    if (partitionIndex == other.partitionIndex) {
      return entrySeq > other.entrySeq;
    }

    // Calculate distance in circular ring: (this - other + cycle) % cycle
    // Small distance means 'this' is just after 'other' (newer).
    // Large distance means 'this' is long before 'other' (older).
    final d = (partitionIndex - other.partitionIndex + cycle) % cycle;

    // In a ring of size 'cycle', if distance is less than half cycle, it's forward.
    return d < (cycle / 2);
  }
}

/// Fold [index] into `[0, cycle)`. Returns 0 when [cycle] is not positive.
int normalizeWalPartitionIndex(int index, int cycle) {
  if (cycle <= 0) return 0;
  final r = index % cycle;
  return r < 0 ? r + cycle : r;
}

/// Inclusive count of partitions on the forward ring arc `[start, end]`.
int walInclusiveArcLength(int start, int end, int cycle) {
  if (cycle <= 0) return 0;
  if (start == end) return 1;
  return (end - start + cycle) % cycle + 1;
}

/// Whether [p] lies on the inclusive forward ring arc `[start, end]`.
bool isWalPartitionOnInclusiveArc(int p, int start, int end, int cycle) {
  if (cycle <= 0) return false;
  if (start == end) return p == start;
  if (start < end) return p >= start && p <= end;
  return p >= start || p <= end;
}

/// Partitions to visit on the inclusive forward arc `[start, end]`.
///
/// Always terminates. Out-of-range indices are folded into `[0, cycle)`.
///
/// A missing file on one slot must not drop later partitions on the same
/// meta range: short arcs (`<= maxUnmappedWalk`) enumerate every index so
/// recovery can `existsFile` each and continue. Huge arcs (bogus wrap /
/// `end == cycle` after a crash) are **not** expanded to `logPartitionCycle`
/// empty slots; they use [mappedPartitions] ∪ [existingPartitionIndices]
/// intersected with the arc so real files on the determined range are kept.
List<int> listWalPartitionsOnArc({
  required int start,
  required int end,
  required int cycle,
  Iterable<int>? mappedPartitions,
  Iterable<int>? existingPartitionIndices,
  int maxUnmappedWalk = 1024,
}) {
  if (cycle <= 0 || start < 0 || end < 0) {
    return const <int>[];
  }
  final startN = normalizeWalPartitionIndex(start, cycle);
  final endN = normalizeWalPartitionIndex(end, cycle);
  final len = walInclusiveArcLength(startN, endN, cycle);
  if (len <= 0) return const <int>[];

  // Short determined range: visit every slot. Missing files are skipped by
  // the caller without aborting the rest of the range.
  if (len <= maxUnmappedWalk) {
    return List<int>.generate(len, (i) => (startN + i) % cycle);
  }

  final known = <int>{};
  void addIfOnArc(int raw) {
    if (raw < 0) return;
    final p = normalizeWalPartitionIndex(raw, cycle);
    if (isWalPartitionOnInclusiveArc(p, startN, endN, cycle)) {
      known.add(p);
    }
  }

  if (mappedPartitions != null) {
    for (final raw in mappedPartitions) {
      addIfOnArc(raw);
    }
  }
  if (existingPartitionIndices != null) {
    for (final raw in existingPartitionIndices) {
      addIfOnArc(raw);
    }
  }

  // Huge arc: never walk hundreds of thousands of empty indices.
  // Keep every known partition that lies on the meta range.
  if (known.isEmpty) return const <int>[];
  final out = known.toList();
  out.sort((a, b) {
    final da = (a - startN + cycle) % cycle;
    final db = (b - startN + cycle) % cycle;
    return da.compareTo(db);
  });
  return out;
}

/// True when a persisted [lastRecovered] hint may skip WAL replay.
///
/// Replay into the flush queue must not persist this hint: if it is newer
/// than [checkpoint], table files do not yet contain those entries.
bool walRecoveryHintIsSafeToSkip({
  required WalPointer checkpoint,
  required WalPointer lastRecovered,
  required int cycle,
}) {
  if (cycle <= 0) return false;
  return !lastRecovered.isNewerThan(checkpoint, cycle);
}
