import 'dart:typed_data';

import '../model/db_exception.dart';
import '../model/result_status.dart';
import '../model/result_type.dart';
import 'wmbp_constants.dart';
import 'wmbp_swar.dart';

/// Counters for one WMBP query.
class WmbpSearchStats {
  int macroWindowSkips = 0;
  int superWindowSkips = 0;
  int microBlockSkips = 0;
  int microBlocksSeen = 0;
  int ghostPrevented = 0;
  int coldPrimaryKeyMisses = 0;
}

/// One state-II physical block: 128 postings, 8 micro-blocks of 16.
class WmbpPhysBlock {
  final int lastDocOffset;
  final int blockDocStart;
  final int blockMaxImpact;
  final int itemCount;

  /// Lanes 0..3 packed little-endian (web-safe uint32 limb).
  final int microMaxLo;

  /// Lanes 4..7 packed little-endian (web-safe uint32 limb).
  final int microMaxHi;
  final Uint16List offsets;
  final Uint8List impacts;

  const WmbpPhysBlock({
    required this.lastDocOffset,
    required this.blockDocStart,
    required this.blockMaxImpact,
    required this.itemCount,
    required this.microMaxLo,
    required this.microMaxHi,
    required this.offsets,
    required this.impacts,
  });
}

/// Tri-state window body for one term inside one super-window.
class WmbpEncodedWindow {
  static final Uint16List _emptyOffsets = Uint16List(0);
  final int state;
  final int df;
  final int maxImpact;
  Uint16List _offsets;
  final Uint8List impacts;
  final List<WmbpPhysBlock> blocks;
  final Uint32List? presence;
  final Uint16List? rankLut;
  final Uint32List? microMaxSlots;

  WmbpEncodedWindow({
    required this.state,
    required this.df,
    required this.maxImpact,
    required Uint16List offsets,
    required this.impacts,
    this.blocks = const <WmbpPhysBlock>[],
    this.presence,
    this.rankLut,
    this.microMaxSlots,
  }) : _offsets = offsets;

  /// Bytes currently held by the offsets array (0 when State-III is lazy).
  int get allocatedOffsetsBytes => _offsets.lengthInBytes;

  /// Posting offsets. State-III may materialize lazily from [presence].
  Uint16List get offsets {
    if (_offsets.isEmpty && state == 3 && df > 0) {
      final bits = presence;
      if (bits != null) {
        _offsets = _offsetsFromPresence(bits, df);
      }
    }
    return _offsets;
  }

  static Uint16List _offsetsFromPresence(Uint32List bits, int df) {
    final out = Uint16List(df);
    var at = 0;
    for (int word = 0; word < bits.length && at < df; word++) {
      var value = bits[word];
      var bit = 0;
      while (value != 0 && bit < 32 && at < df) {
        if ((value & 1) != 0) {
          out[at++] = (word << 5) | bit;
        }
        value >>>= 1;
        bit++;
      }
    }
    return out;
  }

  /// Encodes sorted-or-unsorted `(docOffset, impact)` pairs into state I/II/III.
  ///
  /// Duplicate offsets keep the greater impact. Impact `0` is dropped.
  /// When [presorted] is true, [docOffsets] must already be non-decreasing
  /// (typical first-seal path) — skips the O(n log n) pair sort.
  factory WmbpEncodedWindow.encode(
    List<int> docOffsets,
    List<int> impacts, {
    bool presorted = false,
  }) {
    final normalized =
        _normalizePairs(docOffsets, impacts, presorted: presorted);
    final offList = normalized.offsets;
    final impList = normalized.impacts;
    final int df = offList.length;
    final int maxImpact = normalized.maxImpact;
    // Sparse bodies never serialize presence; skip the 8KB bitmap alloc.
    if (df <= WmbpConstants.dfSparseLimit) {
      return WmbpEncodedWindow(
        state: 1,
        df: df,
        maxImpact: maxImpact,
        offsets: offList,
        impacts: impList,
      );
    }
    if (df < WmbpConstants.dfDenseThreshold) {
      // Presence is not part of the state-II wire image; build it lazily on
      // demand (impactAt / fromBytes) so seal does not pay an 8KB alloc per
      // term-window.
      return WmbpEncodedWindow(
        state: 2,
        df: df,
        maxImpact: maxImpact,
        offsets: offList,
        impacts: impList,
        blocks: _buildBlocks(offList, impList),
      );
    }
    final dense = _buildDense(offList, impList);
    return WmbpEncodedWindow(
      state: 3,
      df: df,
      maxImpact: maxImpact,
      offsets: offList,
      impacts: impList,
      presence: dense.$1,
      rankLut: dense.$2,
      microMaxSlots: dense.$3,
    );
  }

  Uint8List? _flatImpacts;

  /// Filled on first [impactAt] when encode skipped the seal-time presence alloc.
  Uint32List? _lazyPresence;

  Uint8List _getOrCreateFlatImpacts() {
    var flat = _flatImpacts;
    if (flat != null) return flat;
    flat = Uint8List(WmbpConstants.windowSize);
    final int n =
        offsets.length < impacts.length ? offsets.length : impacts.length;
    for (int i = 0; i < n; i++) {
      flat[offsets[i]] = impacts[i];
    }
    return _flatImpacts = flat;
  }

  Uint32List? _presenceBits() {
    final eager = presence;
    if (eager != null) return eager;
    final lazy = _lazyPresence;
    if (lazy != null) return lazy;
    // Only state II skips seal-time presence; sparse stays binary/flat.
    if (state != 2 || offsets.isEmpty) return null;
    return _lazyPresence = _buildPresenceBits(offsets);
  }

  @pragma('vm:prefer-inline')
  int impactAt(int docOffset) {
    final int off = docOffset & WmbpConstants.windowMask;
    // State-III: Rank1 over presence — never force offset materialization.
    if (state == 3) {
      final bits = presence;
      final lut = rankLut;
      if (bits == null || lut == null) return 0;
      final int word = off >> 5;
      final int bit = off & 31;
      if ((bits[word] & (1 << bit)) == 0) return 0;
      final int rank = _rank1(bits, lut, off);
      if (rank < 0 || rank >= impacts.length) return 0;
      return impacts[rank];
    }
    final presenceBits = _presenceBits();
    if (presenceBits != null) {
      final int word = off >> 5;
      final int bit = off & 31;
      if ((presenceBits[word] & (1 << bit)) == 0) return 0;
    }
    final flat = _flatImpacts;
    if (flat != null) return flat[off];
    final offs = offsets;
    // Prefer posting-array length over the header field so a mismatched
    // in-memory image cannot walk past impacts[].
    final int liveDf = impacts.length;
    if (liveDf > 32 || (liveDf == 0 && offs.length > 32)) {
      return _getOrCreateFlatImpacts()[off];
    }
    var lo = 0;
    var hi = offs.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      final int v = offs[mid];
      if (v < off) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo < offs.length && lo < impacts.length && offs[lo] == off) {
      return impacts[lo];
    }
    return 0;
  }

  /// Emits postings whose impact can still reach [reqQ8].
  ///
  /// [emit] receives `(docOffset, impact)` so State-III callers can reuse the
  /// Rank1 result without a second `_rank1` / `impactAt` round-trip.
  void visitCandidates(
    int reqQ8,
    void Function(int docOffset, int impact) emit, {
    WmbpSearchStats? stats,
  }) {
    final offs = offsets;
    final int liveDf = state == 3
        ? (impacts.isNotEmpty
            ? impacts.length
            : (offs.isNotEmpty ? offs.length : df))
        : (impacts.length < offs.length ? impacts.length : offs.length);
    if (liveDf <= 0 || reqQ8 > 255) return;
    // State 0 (OPEN_RAW) and state 1 share compact offset/impact arrays.
    // Closed windows may remain OPEN_RAW until background seal; recall must
    // stay lossless (Recall@K == 1.0) without forcing sync full-vocab seal.
    if (state == 0 || state == 1) {
      for (int i = 0; i < liveDf; i++) {
        final int q = impacts[i];
        if (q >= reqQ8) emit(offs[i], q);
      }
      return;
    }
    if (state == 2) {
      for (final block in blocks) {
        if (block.blockMaxImpact < reqQ8) continue;
        final int mask = WmbpSwar.evalMicroBlockMask(
          block.microMaxLo,
          block.microMaxHi,
          reqQ8,
        );
        final int micros = WmbpSwar.microBlocksPerPhysBlock();
        for (int m = 0; m < micros; m++) {
          if (stats != null) {
            stats.microBlocksSeen++;
            if ((mask & (1 << m)) == 0) stats.microBlockSkips++;
          }
          if ((mask & (1 << m)) == 0) continue;
          final int begin = m * WmbpConstants.microBlockSize;
          var end = begin + WmbpConstants.microBlockSize;
          if (end > block.itemCount) end = block.itemCount;
          for (int i = begin; i < end; i++) {
            final int q = block.impacts[i];
            if (q >= reqQ8) emit(block.offsets[i], q);
          }
        }
      }
      return;
    }
    final slots = microMaxSlots;
    final bits = presence;
    final lut = rankLut;
    if (bits == null || lut == null) return;
    if (slots == null || reqQ8 <= 1) {
      for (int word = 0; word < bits.length; word++) {
        var value = bits[word];
        int bit = 0;
        while (value != 0) {
          if ((value & 1) != 0) {
            final int off = (word << 5) | bit;
            final int rank = _rank1(bits, lut, off);
            if (rank >= 0 && rank < impacts.length) {
              final int q = impacts[rank];
              if (q >= reqQ8) emit(off, q);
            }
          }
          value >>>= 1;
          bit++;
        }
      }
      return;
    }
    for (int slot = 0; slot < 4096; slot++) {
      final int lane = (slots[slot >> 2] >> ((slot & 3) * 8)) & 0xFF;
      if (lane < reqQ8) continue;
      final int start = slot << 4;
      for (int off = start; off < start + 16; off++) {
        final int word = off >> 5;
        final int bit = off & 31;
        if ((bits[word] & (1 << bit)) == 0) continue;
        final int rank = _rank1(bits, lut, off);
        if (rank >= 0 && rank < impacts.length) {
          final int q = impacts[rank];
          if (q >= reqQ8) emit(off, q);
        }
      }
    }
  }

  /// Little-endian tri-state body: `state:u8`, `df:u32`, `maxImpact:u8`,
  /// then the state image.
  ///
  /// Pre-sized [Uint8List] + [ByteData] — BytesBuilder byte-at-a-time was the
  /// dominant cost on long-document seals (state II/III windows).
  Uint8List toBytes() {
    _requireValidDf(df, 'wmbpWindow.toBytes');
    if (state == 2) {
      // Contiguous 16B phys-block headers, then payload region (WMBP.md §6.2).
      var payloadBytes = 0;
      for (final block in blocks) {
        payloadBytes += block.itemCount * 3;
      }
      final int headerBytes =
          WmbpConstants.windowHeaderSize + 2 + blocks.length * 16;
      final out = Uint8List(headerBytes + payloadBytes);
      final data = ByteData.sublistView(out);
      _writeWindowHeader(data, state: state, df: df, maxImpact: maxImpact);
      data.setUint16(
          WmbpConstants.windowHeaderSize, blocks.length, Endian.little);
      var headerAt = WmbpConstants.windowHeaderSize + 2;
      var payloadAt = headerBytes;
      for (final block in blocks) {
        if (block.itemCount > 255) {
          throw DbException([
            GeneralStatus(
              type: ResultType.sysInvalidDataFormat,
              message: 'State-II itemCount=${block.itemCount} exceeds u8',
              operation: 'wmbpWindow.toBytes',
            ),
          ]);
        }
        data.setUint16(headerAt, block.lastDocOffset, Endian.little);
        data.setUint16(headerAt + 2, block.blockDocStart, Endian.little);
        data.setUint8(headerAt + 4, block.blockMaxImpact);
        data.setUint8(headerAt + 5, block.itemCount);
        data.setUint16(headerAt + 6, payloadAt - headerBytes, Endian.little);
        data.setUint32(headerAt + 8, block.microMaxLo, Endian.little);
        data.setUint32(headerAt + 12, block.microMaxHi, Endian.little);
        headerAt += 16;
        for (int i = 0; i < block.itemCount; i++) {
          data.setUint16(payloadAt, block.offsets[i], Endian.little);
          out[payloadAt + 2] = block.impacts[i];
          payloadAt += 3;
        }
      }
      return out;
    }
    if (state == 3) {
      final bits = presence;
      final lut = rankLut;
      final slots = microMaxSlots;
      // Offsets may be lazy-empty (materialized from presence on demand).
      if (bits == null ||
          lut == null ||
          slots == null ||
          impacts.length != df ||
          bits.length != WmbpConstants.activeMaskWords ||
          lut.length != 128 ||
          slots.length != 1024) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysInvalidDataFormat,
            message: 'Corrupted state-III window invariants: df=$df, '
                'impacts=${impacts.length}, '
                'presenceNull=${bits == null}, lutNull=${lut == null}, '
                'slotsNull=${slots == null}',
            operation: 'wmbpWindow.toBytes',
          ),
        ]);
      }
      // Rank1 → Presence → MicroMax → Impacts (WMBP.md §6.3).
      const int fixedPrefix = WmbpConstants.windowHeaderSize +
          128 * 2 +
          WmbpConstants.activeMaskWords * 4 +
          1024 * 4;
      final out = Uint8List(fixedPrefix + df);
      final data = ByteData.sublistView(out);
      _writeWindowHeader(data, state: state, df: df, maxImpact: maxImpact);
      var at = WmbpConstants.windowHeaderSize;
      for (int i = 0; i < lut.length; i++) {
        data.setUint16(at, lut[i], Endian.little);
        at += 2;
      }
      for (int i = 0; i < bits.length; i++) {
        data.setUint32(at, bits[i], Endian.little);
        at += 4;
      }
      for (int i = 0; i < slots.length; i++) {
        data.setUint32(at, slots[i], Endian.little);
        at += 4;
      }
      out.setRange(at, at + df, impacts);
      return out;
    }
    // State 0 (OPEN_RAW) and state 1 share compact offset/impact pairs.
    final out = Uint8List(WmbpConstants.windowHeaderSize + df * 3);
    final data = ByteData.sublistView(out);
    _writeWindowHeader(data, state: state, df: df, maxImpact: maxImpact);
    var at = WmbpConstants.windowHeaderSize;
    for (int i = 0; i < df; i++) {
      data.setUint16(at, offsets[i], Endian.little);
      out[at + 2] = impacts[i];
      at += 3;
    }
    return out;
  }

  /// Restores a window body written by [toBytes].
  factory WmbpEncodedWindow.fromBytes(Uint8List bytes) {
    final reader = _WindowReader(bytes);
    final int state = reader.u8();
    final int df = reader.u32();
    final int maxImpact = reader.u8();
    _requireValidDf(df, 'wmbpWindow.fromBytes');
    if (state == 2) {
      final int blocksN = reader.u16();
      final meta = <({
        int last,
        int start,
        int blockMax,
        int count,
        int payloadOff,
        int microLo,
        int microHi,
      })>[];
      for (int b = 0; b < blocksN; b++) {
        meta.add((
          last: reader.u16(),
          start: reader.u16(),
          blockMax: reader.u8(),
          count: reader.u8(),
          payloadOff: reader.u16(),
          microLo: reader.u32(),
          microHi: reader.u32(),
        ));
      }
      final int payloadBase = reader.i;
      final blocks = <WmbpPhysBlock>[];
      final offsets = <int>[];
      final impacts = <int>[];
      for (final m in meta) {
        reader.i = payloadBase + m.payloadOff;
        final blockOffsets = Uint16List(m.count);
        final blockImpacts = Uint8List(m.count);
        for (int i = 0; i < m.count; i++) {
          blockOffsets[i] = reader.u16();
          blockImpacts[i] = reader.u8();
          offsets.add(blockOffsets[i]);
          impacts.add(blockImpacts[i]);
        }
        blocks.add(WmbpPhysBlock(
          lastDocOffset: m.last,
          blockDocStart: m.start,
          blockMaxImpact: m.blockMax,
          itemCount: m.count,
          microMaxLo: m.microLo,
          microMaxHi: m.microHi,
          offsets: blockOffsets,
          impacts: blockImpacts,
        ));
      }
      // Consume exact payload end.
      var payloadEnd = payloadBase;
      for (final m in meta) {
        final int end = payloadBase + m.payloadOff + m.count * 3;
        if (end > payloadEnd) payloadEnd = end;
      }
      reader.i = payloadEnd;
      if (impacts.length != df || reader.remaining != 0) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysIoDataCorrupted,
            message: 'State-II window length mismatch: headerDf=$df, '
                'postings=${impacts.length}, trailing=${reader.remaining}',
            operation: 'wmbpWindow.fromBytes',
          ),
        ]);
      }
      final offList = Uint16List.fromList(offsets);
      final impList = Uint8List.fromList(impacts);
      // Presence is built lazily via [_lazyPresence] on impactAt.
      return WmbpEncodedWindow(
        state: 2,
        df: df,
        maxImpact: maxImpact,
        offsets: offList,
        impacts: impList,
        blocks: blocks,
      );
    }
    if (state == 3) {
      // Rank1 → Presence → MicroMax → Impacts.
      // Offsets stay empty until merge/append/compact reads [offsets].
      final lut = Uint16List(128);
      for (int i = 0; i < lut.length; i++) {
        lut[i] = reader.u16();
      }
      final bits = Uint32List(WmbpConstants.activeMaskWords);
      var presenceDf = 0;
      for (int i = 0; i < bits.length; i++) {
        final int w = reader.u32();
        bits[i] = w;
        presenceDf += _popcnt(w);
      }
      final slots = Uint32List(1024);
      for (int i = 0; i < slots.length; i++) {
        slots[i] = reader.u32();
      }
      if (presenceDf != df || reader.remaining != df) {
        throw DbException([
          GeneralStatus(
            type: ResultType.sysIoDataCorrupted,
            message: 'State-III window length mismatch: headerDf=$df, '
                'presenceDf=$presenceDf, remaining=${reader.remaining}',
            operation: 'wmbpWindow.fromBytes',
          ),
        ]);
      }
      final impacts = Uint8List(df);
      for (int i = 0; i < df; i++) {
        impacts[i] = reader.u8();
      }
      return WmbpEncodedWindow(
        state: 3,
        df: df,
        maxImpact: maxImpact,
        offsets: _emptyOffsets,
        impacts: impacts,
        presence: bits,
        rankLut: lut,
        microMaxSlots: slots,
      );
    }
    if (state != 0 && state != 1) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysInvalidDataFormat,
          message: 'WMBP window state $state is not supported',
          operation: 'wmbpWindow',
        ),
      ]);
    }
    final int need = df * 3;
    // Header df is authoritative. Trailing bytes past [need] are allowed:
    // inplace shrink of a post slot leaves the old posting tail in place, and a
    // stale macro length (common under memory-pressure cache/tail races) would
    // otherwise fail with headerDf=0 remaining=3 (one leftover posting triple).
    if (reader.remaining < need) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysIoDataCorrupted,
          message: 'State-$state window length mismatch: headerDf=$df, '
              'remaining=${reader.remaining}',
          operation: 'wmbpWindow.fromBytes',
        ),
      ]);
    }
    final offsets = Uint16List(df);
    final impacts = Uint8List(df);
    for (int i = 0; i < df; i++) {
      offsets[i] = reader.u16();
      impacts[i] = reader.u8();
    }
    return WmbpEncodedWindow(
      state: state,
      df: df,
      maxImpact: maxImpact,
      offsets: offsets,
      impacts: impacts,
    );
  }

  /// Open-window raw postings (state 0) — never builds II/III metadata.
  factory WmbpEncodedWindow.openRaw(
    List<int> docOffsets,
    List<int> impacts, {
    bool presorted = false,
  }) {
    final normalized =
        _normalizePairs(docOffsets, impacts, presorted: presorted);
    return WmbpEncodedWindow(
      state: 0,
      df: normalized.offsets.length,
      maxImpact: normalized.maxImpact,
      offsets: normalized.offsets,
      impacts: normalized.impacts,
    );
  }

  /// Appends sorted extras onto an OPEN_RAW window without II/III rebuild.
  ///
  /// Returns null when this window is not state 0 or [extraOff] is not
  /// appendable (first offset below the current tail).
  WmbpEncodedWindow? appendOpenRaw(List<int> extraOff, List<int> extraQ) {
    if (state != 0) return null;
    final int extraN =
        extraOff.length < extraQ.length ? extraOff.length : extraQ.length;
    if (extraN <= 0) return this;
    final normalized = _normalizePairs(extraOff, extraQ, presorted: true);
    if (normalized.offsets.isEmpty) return this;
    if (offsets.isNotEmpty && normalized.offsets.first < offsets.last) {
      return null;
    }
    final int oldN = offsets.length;
    final int newN = oldN + normalized.offsets.length;
    // Same last offset: keep the greater impact (no new posting).
    var mergeDup = false;
    if (oldN > 0 && normalized.offsets.first == offsets.last) {
      mergeDup = true;
    }
    final int outN = mergeDup ? newN - 1 : newN;
    final outOff = Uint16List(outN);
    final outQ = Uint8List(outN);
    outOff.setRange(0, oldN, offsets);
    outQ.setRange(0, oldN, impacts);
    var at = oldN;
    var maxQ = maxImpact;
    for (int i = 0; i < normalized.offsets.length; i++) {
      final int off = normalized.offsets[i];
      final int q = normalized.impacts[i];
      if (q > maxQ) maxQ = q;
      if (at > 0 && outOff[at - 1] == off) {
        if (q > outQ[at - 1]) outQ[at - 1] = q;
        continue;
      }
      outOff[at] = off;
      outQ[at] = q;
      at++;
    }
    return WmbpEncodedWindow(
      state: 0,
      df: at,
      maxImpact: maxQ,
      offsets: at == outN ? outOff : Uint16List.sublistView(outOff, 0, at),
      impacts: at == outN ? outQ : Uint8List.sublistView(outQ, 0, at),
    );
  }
}

/// Deduped, sorted `(offset, q8)` pairs shared by [encode] / [openRaw].
({Uint16List offsets, Uint8List impacts, int maxImpact}) _normalizePairs(
  List<int> docOffsets,
  List<int> impacts, {
  required bool presorted,
}) {
  final int n =
      docOffsets.length < impacts.length ? docOffsets.length : impacts.length;
  final offsets = <int>[];
  final qs = <int>[];
  if (presorted) {
    int? prev;
    for (int i = 0; i < n; i++) {
      final int q = impacts[i];
      if (q <= 0) continue;
      final int off = docOffsets[i] & WmbpConstants.windowMask;
      final int q8 = q > 255 ? 255 : q;
      if (prev == off) {
        if (q8 > qs.last) qs[qs.length - 1] = q8;
        continue;
      }
      prev = off;
      offsets.add(off);
      qs.add(q8);
    }
  } else {
    final paired = <(int, int)>[];
    for (int i = 0; i < n; i++) {
      final int q = impacts[i];
      if (q <= 0) continue;
      paired.add(
        (docOffsets[i] & WmbpConstants.windowMask, q > 255 ? 255 : q),
      );
    }
    paired.sort((a, b) => a.$1.compareTo(b.$1));
    int? prev;
    for (final pair in paired) {
      if (prev == pair.$1) {
        if (pair.$2 > qs.last) qs[qs.length - 1] = pair.$2;
        continue;
      }
      prev = pair.$1;
      offsets.add(pair.$1);
      qs.add(pair.$2);
    }
  }
  var maxImpact = 0;
  for (final q in qs) {
    if (q > maxImpact) maxImpact = q;
  }
  return (
    offsets: Uint16List.fromList(offsets),
    impacts: Uint8List.fromList(qs),
    maxImpact: maxImpact,
  );
}

void _writeWindowHeader(
  ByteData data, {
  required int state,
  required int df,
  required int maxImpact,
}) {
  data.setUint8(0, state);
  data.setUint32(1, df, Endian.little);
  data.setUint8(5, maxImpact);
}

void _requireValidDf(int df, String operation) {
  if (df < 0 || df > WmbpConstants.windowSize) {
    throw DbException([
      GeneralStatus(
        type: ResultType.sysInvalidDataFormat,
        message: 'WMBP window df=$df is out of range '
            '(0..${WmbpConstants.windowSize})',
        operation: operation,
      ),
    ]);
  }
}

Uint32List _buildPresenceBits(Uint16List offsets) {
  final bits = Uint32List(WmbpConstants.activeMaskWords);
  for (int i = 0; i < offsets.length; i++) {
    final int off = offsets[i];
    bits[off >> 5] |= 1 << (off & 31);
  }
  return bits;
}

class _WindowReader {
  final Uint8List bytes;
  int i = 0;

  _WindowReader(this.bytes);

  int get remaining => bytes.length - i;

  int u8() {
    _need(1);
    return bytes[i++];
  }

  int u16() {
    _need(2);
    final int v = bytes[i] | (bytes[i + 1] << 8);
    i += 2;
    return v;
  }

  int u32() {
    _need(4);
    final int v = bytes[i] |
        (bytes[i + 1] << 8) |
        (bytes[i + 2] << 16) |
        (bytes[i + 3] << 24);
    i += 4;
    return v & 0xFFFFFFFF;
  }

  void _need(int n) {
    if (bytes.length - i < n) {
      throw DbException([
        GeneralStatus(
          type: ResultType.sysIoDataCorrupted,
          message: 'WMBP window body is truncated',
          operation: 'wmbpWindow',
        ),
      ]);
    }
  }
}

List<WmbpPhysBlock> _buildBlocks(Uint16List offsets, Uint8List impacts) {
  final blocks = <WmbpPhysBlock>[];
  for (int start = 0;
      start < offsets.length;
      start += WmbpConstants.physBlockSize) {
    var end = start + WmbpConstants.physBlockSize;
    if (end > offsets.length) end = offsets.length;
    final int count = end - start;
    final blockOffsets = Uint16List(count);
    final blockImpacts = Uint8List(count);
    final laneMax = List<int>.filled(8, 0);
    int blockMax = 0;
    for (int i = 0; i < count; i++) {
      final int q = impacts[start + i];
      blockOffsets[i] = offsets[start + i];
      blockImpacts[i] = q;
      if (q > blockMax) blockMax = q;
      final int lane = i ~/ WmbpConstants.microBlockSize;
      if (lane < 8 && q > laneMax[lane]) laneMax[lane] = q;
    }
    final packed = WmbpSwar.packMicroMaxWord(laneMax);
    blocks.add(WmbpPhysBlock(
      lastDocOffset: blockOffsets[count - 1],
      blockDocStart: blockOffsets[0],
      blockMaxImpact: blockMax,
      itemCount: count,
      microMaxLo: packed.$1,
      microMaxHi: packed.$2,
      offsets: blockOffsets,
      impacts: blockImpacts,
    ));
  }
  return blocks;
}

(Uint32List, Uint16List, Uint32List) _buildDense(
  Uint16List offsets,
  Uint8List impacts,
) {
  final bits = Uint32List(WmbpConstants.activeMaskWords);
  final slotMax = List<int>.filled(4096, 0);
  for (int i = 0; i < offsets.length; i++) {
    final int off = offsets[i];
    final int q = impacts[i];
    bits[off >> 5] |= 1 << (off & 31);
    final int slot = off >> 4;
    if (q > slotMax[slot]) slotMax[slot] = q;
  }
  final lut = Uint16List(128);
  int running = 0;
  for (int g = 0; g < 128; g++) {
    lut[g] = running;
    final int start = g << 4;
    for (int w = 0; w < 16; w++) {
      running += _popcnt(bits[start + w]);
    }
  }
  final slots = Uint32List(1024);
  for (int slot = 0; slot < 4096; slot++) {
    final int q = slotMax[slot] & 0xFF;
    slots[slot >> 2] |= q << ((slot & 3) * 8);
  }
  return (bits, lut, slots);
}

int _rank1(Uint32List bits, Uint16List lut, int docOffset) {
  final int word = docOffset >> 5;
  final int bit = docOffset & 31;
  final int group = word >> 4;
  int rank = lut[group];
  final int start = group << 4;
  for (int i = start; i < word; i++) {
    rank += _popcnt(bits[i]);
  }
  if (bit > 0) {
    final int lowMask = (1 << bit) - 1;
    rank += _popcnt(bits[word] & lowMask);
  }
  return rank;
}

/// 32-bit popcount. Dart ints are arbitrary-width — the classic SWAR
/// `* 0x01010101 >> 24` must mask back to u32 or the multiply overflows and
/// Rank1 / fromBytes presenceDf checks explode (e.g. presenceDf≈2e10).
@pragma('vm:prefer-inline')
int _popcnt(int x) {
  var v = x & 0xFFFFFFFF;
  v -= (v >>> 1) & 0x55555555;
  v = (v & 0x33333333) + ((v >>> 2) & 0x33333333);
  v = (v + (v >>> 4)) & 0x0F0F0F0F;
  return ((v * 0x01010101) & 0xFFFFFFFF) >>> 24;
}
