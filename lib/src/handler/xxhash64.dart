/// Official XXH64 (xxHash 64-bit) for ToStore.
///
/// Platform backends (conditional export):
/// - Native / dart2wasm: [xxhash64_vm.dart] — 64-bit `int` arithmetic (fast)
/// - dart2js only (`dart.library.js`): [xxhash64_web.dart] — [BigInt] arithmetic
///
/// Both backends implement the same algorithm from the xxHash specification
/// and produce identical little-endian digest bytes.
library;

export 'xxhash64_vm.dart' if (dart.library.js) 'xxhash64_web.dart';
