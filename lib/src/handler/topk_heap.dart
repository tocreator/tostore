/// A bounded top-K selector using a max-heap (worst-at-root).
///
/// The comparator follows the same contract as `List.sort`:
/// - `compare(a, b) < 0`  => `a` ranks BEFORE `b` (better)
/// - `compare(a, b) > 0`  => `a` ranks AFTER `b` (worse)
///
/// This data structure keeps at most [k] best elements by discarding worse ones.
final class TopKHeap<T> {
  final int k;
  final int Function(T a, T b) compare;
  final List<T> _heap = <T>[];

  TopKHeap({
    required this.k,
    required this.compare,
  });

  int get length => _heap.length;

  bool get isEmpty => _heap.isEmpty;

  /// Offer an item to the selector.
  ///
  /// Keeps at most [k] best elements by discarding worse ones.
  void offer(T item) {
    if (k <= 0) return;
    if (_heap.length < k) {
      _heap.add(item);
      _siftUp(_heap.length - 1);
      return;
    }
    // Replace the current worst if the new item is better.
    if (compare(item, _heap[0]) < 0) {
      _heap[0] = item;
      _siftDown(0);
    }
  }

  /// Returns the retained items sorted in the requested order (best -> worst).
  List<T> toSortedList() {
    if (_heap.isEmpty) return <T>[];
    final out = List<T>.from(_heap, growable: true);
    out.sort(compare);
    return out;
  }

  bool _isWorse(T a, T b) => compare(a, b) > 0;

  void _swap(int i, int j) {
    final tmp = _heap[i];
    _heap[i] = _heap[j];
    _heap[j] = tmp;
  }

  void _siftUp(int idx) {
    while (idx > 0) {
      final parent = (idx - 1) >> 1;
      // Max-heap: bubble up when child is WORSE than parent.
      if (!_isWorse(_heap[idx], _heap[parent])) break;
      _swap(idx, parent);
      idx = parent;
    }
  }

  void _siftDown(int idx) {
    final n = _heap.length;
    while (true) {
      final left = (idx << 1) + 1;
      if (left >= n) break;
      final right = left + 1;
      int worstChild = left;
      if (right < n && _isWorse(_heap[right], _heap[left])) {
        worstChild = right;
      }
      // Stop when parent is already worse-or-equal than the worst child.
      if (!_isWorse(_heap[worstChild], _heap[idx])) break;
      _swap(idx, worstChild);
      idx = worstChild;
    }
  }
}
