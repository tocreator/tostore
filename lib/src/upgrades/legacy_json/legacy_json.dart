/// Legacy JSON wire formats retired from hot paths.
///
/// # Purpose
/// When a storage format moves from JSON to binary, the **decode-only** JSON
/// parsers live here — never in `lib/src/model/` or hot-path handlers.
/// Blocking upgrades (`v2_upgrade`, `v3_upgrade`, …) are the only intended
/// callers.
///
/// # Layout
/// ```
/// upgrades/legacy_json/
///   legacy_json.dart          // this barrel
///   transaction_json.dart     // txn status / commit-plan NDJSON
///   parallel_journal_json.dart  // (future) A/B journal BatchStart.tablePlan
///   table_meta_json.dart        // (future) table meta.json → page0
///   index_meta_json.dart        // (future) index / NGH meta.json
///   wal_meta_json.dart          // (future) if WAL meta leaves JSON
///   schema_partition_json.dart  // (future) legacy schema partition blobs
/// ```
/// One domain per file. Prefer small focused parsers over a single dump file.
///
/// # Rules for new migrations
/// 1. **Hot path**: encode/decode only via binary codecs (`TxnEncoder`,
///    `WalEncoder`, `BinarySchemaCodec`, `BinaryMapCodec`, `meta_binary_codec`,
///    …) + optional `EncryptionManager` (prefix pass-through for plaintext).
/// 2. **Formal models** (`lib/src/model/`): keep in-memory shapes; strip
///    `toJson`/`fromJson` once no runtime writer/reader remains.
/// 3. **Legacy parsers**: move JSON parse helpers here before deleting model
///    JSON methods. Name classes `LegacyXxxJson` with static `parse` /
///    `fromJson` style APIs that return current memory models.
/// 4. **Upgrade timing**: rewrite on disk in a blocking major upgrade; recovery
///    after upgrade must only see the new binary format.
/// 5. **Do not** import `legacy_json` from core/query/handler hot paths —
///    upgrades and one-shot migration helpers only.
///
/// # Checklist when retiring a JSON format
/// - [ ] Add `legacy_json/<domain>_json.dart` with decode-only parsers
/// - [ ] Export it from this barrel
/// - [ ] One-shot rewrite in the current engine upgrade class
/// - [ ] Remove JSON from the runtime writer
/// - [ ] Remove `toJson`/`fromJson` from formal models if unused
/// - [ ] Keep meta-driven discovery where possible (prefer meta indexes over
///       `listDirectory` scans; directory scan only as corrupt-meta fallback)
library;

export 'transaction_json.dart';
