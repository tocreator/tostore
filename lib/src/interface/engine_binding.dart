import 'dart:async';

import '../core/data_store_impl.dart';

/// Live engine pointer for APIs that must survive [ToStore.switchSpace].
///
/// [switchSpace] closes the previous [DataStoreImpl] and opens a successor.
/// Facades (KV / query watches) bind through this handle so user-held streams
/// can detach before teardown and re-attach to the new engine.
abstract class EngineBinding {
  /// Currently live engine (replaced after a successful space switch).
  DataStoreImpl get engine;

  /// Invoked synchronously just before the current engine is closed for a
  /// space switch. Listeners must drop subscriptions without completing the
  /// user-facing stream.
  void addEngineReplacingListener(void Function() listener);

  void removeEngineReplacingListener(void Function() listener);

  /// Fires after the successor engine is initialized and published.
  Stream<void> get onEngineReplaced;
}

/// User-facing stream that follows [EngineBinding.engine] across space switches.
Stream<T> bindEngineStream<T>({
  required EngineBinding binding,
  required Stream<T> Function(DataStoreImpl engine) open,
}) {
  return Stream.multi((listener) {
    StreamSubscription<T>? inner;
    StreamSubscription<void>? replacedSub;
    var cancelled = false;

    void detach() {
      final sub = inner;
      inner = null;
      // Drop without forwarding onDone/onError from the closing engine.
      unawaited(sub?.cancel());
    }

    void attach() {
      if (cancelled || listener.isClosed) return;
      detach();
      final engine = binding.engine;
      inner = open(engine).listen(
        listener.add,
        onError: listener.addError,
        onDone: () {
          // Engine closed outside switchSpace (e.g. db.close): end user stream.
          if (!cancelled && identical(binding.engine, engine)) {
            listener.close();
          }
        },
        cancelOnError: false,
      );
    }

    binding.addEngineReplacingListener(detach);
    replacedSub = binding.onEngineReplaced.listen((_) => attach());
    attach();

    listener.onPause = () {
      inner?.pause();
    };
    listener.onResume = () {
      inner?.resume();
    };
    listener.onCancel = () async {
      cancelled = true;
      binding.removeEngineReplacingListener(detach);
      await replacedSub?.cancel();
      detach();
    };
  });
}
