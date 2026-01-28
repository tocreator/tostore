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
