// Common interface for Isolate functionality across platforms
// This file conditionally exports the appropriate implementation

export 'isolate_stub.dart' if (dart.library.isolate) 'isolate_native.dart';
