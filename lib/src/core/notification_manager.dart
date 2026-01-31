import 'dart:async';

import '../model/change_event.dart';
import '../query/query_condition.dart';
import '../model/query_index.dart';
import '../model/table_schema.dart';
import '../handler/value_matcher.dart';

class NotificationManager {
  // Table Name -> QueryIndex
  final Map<String, QueryIndex> _indexes = {};

  // Keep track of subscriptions by ID for easy removal
  final Map<String, QuerySubscription> _activeSubscriptions = {};

  final Map<String, TableSchema> _schemas;

  NotificationManager([List<TableSchema> schemas = const []])
      : _schemas = {for (var s in schemas) s.name: s};

  /// Register a listener for a specific query
  StreamSubscription<ChangeEvent> register(
    String tableName,
    QueryCondition condition,
    void Function(ChangeEvent) onData,
  ) {
    final id = '${DateTime.now().microsecondsSinceEpoch}_${condition.hashCode}';

    final controller = StreamController<ChangeEvent>();

    final subscription = QuerySubscription(
      id: id,
      condition: condition,
      callback: (event) {
        controller.add(event as ChangeEvent);
      },
    );

    if (!_indexes.containsKey(tableName)) {
      _indexes[tableName] = QueryIndex();
    }

    _indexes[tableName]!.add(subscription);
    _activeSubscriptions[id] = subscription;

    // Forward events to the user provided callback
    // We return the stream subscription so the user can cancel it
    final streamSub = controller.stream.listen(onData);

    // When the user cancels the stream subscription, we remove the query subscription
    streamSub.onDone(() {
      _unregister(tableName, id);
      controller.close();
    });

    return streamSub;
  }

  void _unregister(String tableName, String id) {
    if (_activeSubscriptions.containsKey(id)) {
      final sub = _activeSubscriptions.remove(id)!;
      _indexes[tableName]?.remove(sub);
    }
  }

  /// Notify listeners of a change
  void notify(ChangeEvent event) {
    final index = _indexes[event.tableName];
    if (index == null) return;

    // We need to check both the new record (to see if it matches now)
    // AND the old record (to see if it matched before).
    // This ensures we notify when:
    // 1. A record enters the view (matches new, didn't match old)
    // 2. A record leaves the view (matches old, doesn't match new)
    // 3. A record stays in the view but updates (matches both)

    final candidates = <QuerySubscription>{};

    if (event.record != null) {
      candidates.addAll(index.getCandidates(event.record!));
    }
    if (event.oldRecord != null) {
      candidates.addAll(index.getCandidates(event.oldRecord!));
    }

    for (var sub in candidates) {
      // Double check the full condition logic
      // The index is just a pre-filter. We must verify the full condition matches.
      bool matchesNew = false;
      bool matchesOld = false;

      if (event.record != null) {
        matchesNew = _matches(sub.condition, event.record!, event.tableName);
      }

      if (event.oldRecord != null) {
        matchesOld = _matches(sub.condition, event.oldRecord!, event.tableName);
      }

      // If it matches either state, we notify.
      // The listener can decide what to do (e.g. re-query).
      if (matchesNew || matchesOld) {
        sub.callback(event);
      }
    }
  }

  /// Verify if a record matches a condition
  bool _matches(
      QueryCondition condition, Map<String, dynamic> record, String tableName) {
    final matcher =
        ConditionRecordMatcher.prepare(condition, _schemas, tableName);
    return matcher.matches(record);
  }
}
