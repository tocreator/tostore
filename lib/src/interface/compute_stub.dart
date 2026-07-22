import 'dart:async';

/// A stub implementation of compute that runs the function on the main isolate.
/// This is used on platforms that do not support isolates, such as the web.
Future<R> compute<Q, R>(FutureOr<R> Function(Q) function, Q message) async {
  // On the web, isolates are not available, so we run the function
  // directly. It will still be asynchronous if the function returns a Future.
  return await function(message);
}

Future<void> prewarm() async {
  // On the web, isolates are not available, so we do nothing.
}
