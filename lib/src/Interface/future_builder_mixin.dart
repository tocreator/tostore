import 'dart:async';

/// Future builder mixin
mixin FutureBuilderMixin<T> implements Future<T> {
  Future<T> get future;

  @override
  Future<R> then<R>(FutureOr<R> Function(T value) onValue,
      {Function? onError}) {
    return future.then(onValue, onError: onError);
  }

  @override
  Future<T> catchError(Function onError, {bool Function(Object error)? test}) {
    return future.catchError(onError, test: test);
  }

  @override
  Future<T> whenComplete(FutureOr Function() action) {
    return future.whenComplete(action);
  }

  @override
  Future<T> timeout(Duration timeLimit, {FutureOr<T> Function()? onTimeout}) {
    return future.timeout(timeLimit, onTimeout: onTimeout);
  }

  @override
  Stream<T> asStream() {
    return future.asStream();
  }
}
