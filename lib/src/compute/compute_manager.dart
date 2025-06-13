import 'dart:async';

import '../Interface/compute_provider.dart' as compute_impl;

/// A compute manager to control whether to use isolate.
///
/// Provides a unified entry point for running computational tasks, with the ability
/// to dynamically enable or disable the use of isolates.
class ComputeManager {

  /// - [Q]: The type of the message to be passed to the function.
  /// - [R]: The type of the result.
  /// - [function]: The function to execute. It must be a top-level function or a static method
  ///   to be executed in an isolate.
  /// - [message]: The argument to pass to the [function].
  static Future<R> run<Q, R>(FutureOr<R> Function(Q) function, Q message, {bool useIsolate = true}) {
    if (useIsolate) {
      // Delegates to the platform-specific implementation.
      // On native, this will use an Isolate. On web, it will run inline.
      return compute_impl.compute(function, message);
    } else {
      // Forces the function to run on the current isolate and returns the result as a Future.
      return Future(() => function(message));
    }
  }
} 