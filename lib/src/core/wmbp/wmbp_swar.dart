/// Register micro-block mask for state II (8 x uint8 bounds).
///
/// Conditional backends:
/// - Native / dart2wasm: [wmbp_swar_vm.dart] — SWAR on a packed uint64 word
/// - dart2js only (`dart.library.js`): [wmbp_swar_web.dart] — byte-wise naive
///
/// In-memory form is always two uint32 limbs (lo = lanes 0..3, hi = 4..7) so
/// dart2js never needs a single JS Number above 2^53 for the packed word.
library;

export 'wmbp_swar_vm.dart' if (dart.library.js) 'wmbp_swar_web.dart';
