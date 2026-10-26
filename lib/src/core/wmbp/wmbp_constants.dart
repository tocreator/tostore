/// Frozen WMBP layout constants.
abstract final class WmbpConstants {
  static const int windowSize = 65536;
  static const int windowShift = 16;
  static const int windowMask = 0xFFFF;
  static const int macroWindowSpan = 64;
  static const int physBlockSize = 128;
  static const int microBlockSize = 16;
  static const int championPrefixSize = 128;
  static const int dfSparseLimit = 64;
  static const int dfDenseThreshold = 4096;

  /// Window body header: `state:u8` + `df:u32` + `maxImpact:u8`.
  ///
  /// [df] must be `u32` so a full super-window (`windowSize == 65536`) is
  /// representable; a `u16` field would truncate that count to 0.
  static const int windowHeaderSize = 6;
  static const int storePageSize = 16384;
  static const int pageHeaderSize = 16;
  static const int pagePayloadSize = storePageSize - pageHeaderSize;

  /// Encryption / AEAD slack reserved inside each StorePage payload.
  static const int encryptSlackBytes = 96;

  /// Max payload that still fits after page-codec encryption.
  static const int safePayloadSize = pagePayloadSize - encryptSlackBytes;

  /// Active-count summary values per dict summary page (`u32` each).
  ///
  /// `4000 * 4 = 16000 <= safePayloadSize` — never use raw `pagePayloadSize/4`
  /// (4096) which overflows the framed page under encryption.
  static const int summaryValuesPerPage = 4000;

  /// Fixed `_IdRec` slot: `df:u64 + headPage:u32 + headOffset:u32 + headLength:u32`.
  static const int idRecSize = 24;
  static const int idRecSlotsPerPage = safePayloadSize ~/ idRecSize;

  /// Page-local fwd: 512 docs/page, directory `u16 off + u16 len` per slot.
  static const int fwdDocsPerPage = 512;
  static const int fwdDirBytes = fwdDocsPerPage * 4;
  static const int fwdMaxInlinePkBytes = 24;
  static const int fwdOverflowDescBytes = 8;
  static const int fwdOverflowFlag = 0x8000;

  /// Legacy fixed 16B fwd slots (being replaced by page-local slotted layout).
  static const int fwdSlotSize = 16;
  static const int fwdInlineBytes = 14;
  static const int fwdSlotsPerPage = pagePayloadSize ~/ fwdSlotSize;
  static const int activeMaskBytes = 8192;
  static const int activeMaskWords = 2048;
  static const int cacheLruBytes = 50 * 1024 * 1024;
  static const int gcActiveCountFloor = 52428;

  /// Negative query-term cache in [WmbpCorpus] (FIFO when full).
  static const int missingTermsCacheCap = 16384;

  /// Packed [WmbpPagePtr] local pageNo width inside one `u32`.
  static const int pagePtrPageNoBits = 18;
  static const int pagePtrPageNoMask = (1 << pagePtrPageNoBits) - 1;

  /// Max partition index in a packed ptr (`0 .. pagePtrMaxPartition`).
  ///
  static const int pagePtrMaxPartition =
      (0xFFFFFFFE - pagePtrPageNoMask) ~/ (pagePtrPageNoMask + 1);

  /// Prefer truncating division over `>>` so dart2js does not ToInt32-truncate
  /// docIds above 2^32 (bitwise shifts on the web are 32-bit only).
  static int windowIdOf(int docId) => docId ~/ windowSize;

  static int docOffsetOf(int docId) => docId % windowSize;

  /// Active-mask StorePage index: one framed page per super-window.
  ///
  /// (Former dual-window raw packing left no room for page-codec encryption.)
  static int maskPageOfWindow(int windowId) => windowId;

  static int maskPageOfDoc(int docId) => windowIdOf(docId);

  static int macroIdOfWindow(int windowId) => windowId ~/ macroWindowSpan;
}
