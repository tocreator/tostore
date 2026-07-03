import 'dart:async';

import '../model/change_event.dart';
import '../query/query_condition.dart';
import '../model/query_index.dart';
import '../model/table_schema.dart';
import '../model/table_identity.dart';
import '../handler/value_matcher.dart';

class NotificationManager {
  // Table UID -> QueryIndex
  final Map<String, QueryIndex> _indexes = {};

  // Keep track of subscriptions by ID for easy removal
  final Map<String, QuerySubscription> _activeSubscriptions = {};

  // Keep track of controllers for explicit closing in dispose()
  final Map<String, StreamController<ChangeEvent>> _controllers = {};

  final Map<String, TableSchema> _schemas;

  NotificationManager([List<TableSchema> schemas = const []])
      : _schemas = {for (var s in schemas) s.tableUid: s};

  /// Check if there are any active subscriptions for a table
  bool hasListeners(TableUid tableUid) {
    final index = _indexes[tableUid];
    return index != null && !index.isEmpty;
  }

  /// Get all table UIDs that have at least one active subscription
  Iterable<String> getActiveTables() {
    return _indexes.entries.where((e) => !e.value.isEmpty).map((e) => e.key);
  }

  /// Register a listener for a specific query
  StreamSubscription<ChangeEvent> register(
    TableUid tableUid,
    QueryCondition condition,
    void Function(ChangeEvent) onData,
  ) {
    final id = '${DateTime.now().microsecondsSinceEpoch}_${condition.hashCode}';

    final controller = StreamController<ChangeEvent>();
    _controllers[id] = controller;

    final subscription = QuerySubscription(
      id: id,
      condition: condition,
      callback: (event) {
        if (!controller.isClosed) {
          controller.add(event as ChangeEvent);
        }
      },
    );

    if (!_indexes.containsKey(tableUid)) {
      _indexes[tableUid] = QueryIndex();
    }

    _indexes[tableUid]!.add(subscription);
    _activeSubscriptions[id] = subscription;

    // Forward events to the user provided callback
    // We return the stream subscription so the user can cancel it
    final streamSub = controller.stream.listen(onData);

    // When the user cancels the stream subscription, we remove the query subscription
    streamSub.onDone(() {
      _unregister(tableUid, id);
    });

    return streamSub;
  }

  void _unregister(TableUid tableUid, String id) {
    if (_activeSubscriptions.containsKey(id)) {
      final sub = _activeSubscriptions.remove(id)!;
      _indexes[tableUid]?.remove(sub);
    }
    final controller = _controllers.remove(id);
    if (controller != null && !controller.isClosed) {
      controller.close();
    }
  }

  /// Notify listeners of a change
  void notify(ChangeEvent event) {
    final index = _indexes[event.tableUid];
    if (index == null) return;

    // For clear operation, we notify all subscriptions on the table
    if (event.type == ChangeType.clear) {
      final allSubs = index.getAllSubscriptions();
      for (var sub in allSubs) {
        sub.callback(event);
      }
      return;
    }

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
        matchesNew = _matches(sub.condition, event.record!, event.tableUid);
      }

      if (event.oldRecord != null) {
        matchesOld = _matches(sub.condition, event.oldRecord!, event.tableUid);
      }

      // If it matches either state, we notify.
      // The listener can decide what to do (e.g. re-query).
      if (matchesNew || matchesOld) {
        sub.callback(event);
      }
    }
  }

  /// Verify if a record matches a condition
  bool _matches(QueryCondition condition, Map<String, dynamic> record,
      TableUid tableUid) {
    final matcher =
        ConditionRecordMatcher.prepare(condition, _schemas, tableUid);
    return matcher.matches(record);
  }

  /// Clear all subscriptions and indexes
  void dispose() {
    _activeSubscriptions.clear();
    _indexes.clear();
    _schemas.clear();

    // Explicitly close all controllers to release listeners and their closures
    for (final controller in _controllers.values) {
      if (!controller.isClosed) {
        controller.close();
      }
    }
    _controllers.clear();
  }
}
