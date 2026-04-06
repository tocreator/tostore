import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:tostore/tostore.dart';

/// quick-start example for mobile apps.
///
/// Copy this file into your project and use it to get started quickly example.
class MobileQuickStart {
  static ToStore? _db;

  /// Global (in-process) singleton accessor.
  static ToStore get db {
    final instance = _db;
    if (instance == null) {
      throw StateError(
          'MobileQuickStart.initialize() must be called before use');
    }
    return instance;
  }

  /// Initialize database
  ///
  /// [dbName] allows multiple isolated instances by name.
  static Future<void> initialize({String dbName = 'quickstart_db'}) async {
    // Resolve app documents directory via path_provider and inject into tostore
    final docDir = await getApplicationDocumentsDirectory();
    final dbRoot = p.join(docDir.path,
        'common'); // tostore: ^2.2.2 version default dbPath is getApplicationDocumentsDirectory()/common
    final instance = await ToStore.open(
      dbPath: dbRoot,
      dbName: dbName,
      schemas: const [
        // records table
        TableSchema(
          name: 'records',
          primaryKeyConfig: PrimaryKeyConfig(
            name: 'id',
            type: PrimaryKeyType.sequential,
          ),
          fields: [
            FieldSchema(name: 'type', type: DataType.text, nullable: false),
            FieldSchema(name: 'title', type: DataType.text, maxLength: 200),
            FieldSchema(name: 'content', type: DataType.text),
            FieldSchema(name: 'data', type: DataType.json),
            FieldSchema(name: 'tags', type: DataType.array),
            FieldSchema(
              name: 'created_at',
              type: DataType.datetime,
              defaultValueType: DefaultValueType.currentTimestamp,
            ),
            FieldSchema(
              name: 'updated_at',
              type: DataType.datetime,
              defaultValueType: DefaultValueType.currentTimestamp,
            ),
          ],
          indexes: [
            IndexSchema(fields: ['type']),
            IndexSchema(fields: ['updated_at']),
          ],
        ),

        // Global key-value settings
        TableSchema(
          name: 'settings',
          isGlobal: true,
          primaryKeyConfig: PrimaryKeyConfig(),
          fields: [
            FieldSchema(
              name: 'key',
              type: DataType.text,
              nullable: false,
              unique: true,
            ),
            FieldSchema(name: 'value', type: DataType.text),
          ],
          indexes: [
            IndexSchema(fields: ['key'], unique: true),
          ],
        ),
      ],
    );

    _db = instance;
  }

  /// Switch user/application space
  static Future<bool> switchSpace(String spaceName) {
    return db.switchSpace(spaceName: spaceName);
  }

  /// Close database resources.
  static Future<void> close() => db.close();

  /// Schema-based custom extensions
  ///
  /// Starting from `addRecord`, all methods below are business-specific helpers
  /// built on the table schemas (CRUD wrappers, etc.). They are not required
  /// by the framework and can be modified as needed.

  /// Create a generic record. Suitable for notes/bookmarks/logs etc.
  static Future<DbResult> addRecord(
    String type, {
    String? title,
    String? content,
    Map<String, dynamic>? data,
    List<dynamic>? tags,
  }) {
    return db.insert('records', {
      'type': type,
      if (title != null) 'title': title,
      if (content != null) 'content': content,
      if (data != null) 'data': data,
      if (tags != null) 'tags': tags,
      'created_at': DateTime.now().toIso8601String(),
      'updated_at': DateTime.now().toIso8601String(),
    });
  }

  /// Update a generic record by id (auto updates updated_at)
  static Future<DbResult> updateRecord(
      String id, Map<String, dynamic> updates) {
    final payload = {
      ...updates,
      'updated_at': DateTime.now().toIso8601String(),
    };
    return db.update('records', payload).where('id', '=', id);
  }

  /// List generic records, optionally by type, ordered by newest update first.
  static Future<QueryResult> listRecords({String? type, int limit = 20}) {
    final builder = db.query('records');
    if (type != null) {
      builder.where('type', '=', type);
    }
    return builder.orderByDesc('updated_at').limit(limit);
  }

  /// Delete a generic record by id.
  static Future<DbResult> deleteRecord(String id) {
    return db.delete('records').where('id', '=', id);
  }

  /// Watch generic records (reactive).
  ///
  /// This returns a Stream that automatically emits a new list of records
  /// whenever the 'records' table is modified.
  static Stream<List<Map<String, dynamic>>> watchRecords(
      {String? type, int limit = 20}) {
    final builder = db.query('records');
    if (type != null) {
      builder.where('type', '=', type);
    }
    return builder.orderByDesc('updated_at').limit(limit).watch();
  }

  /// Set a global setting value (shared across spaces).
  static Future<DbResult> setSetting(String key, String value) {
    return db.upsert('settings', {'key': key, 'value': value});
  }

  /// Get a global setting value; returns null if not exists.
  static Future<String?> getSetting(String key) async {
    final result = await db.query('settings').where('key', '=', key).limit(1);
    if (result.data.isEmpty) return null;
    return result.data.first['value'] as String?;
  }
}

/// A simple UI example demonstrating ToStore's reactive "Auto-Refresh" capability.
///
/// Use [StreamBuilder] combined with [watch] to keep your UI in sync with the DB
/// without manual state management or polling.
class RecordsRefreshExample extends StatelessWidget {
  const RecordsRefreshExample({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ToStore Auto-Refresh'),
        backgroundColor: Colors.blueGrey[900],
        foregroundColor: Colors.white,
      ),
      body: StreamBuilder<List<Map<String, dynamic>>>(
        // 1. Listen to the reactive stream from watchRecords()
        stream: MobileQuickStart.watchRecords(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return Center(child: Text('Error: ${snapshot.error}'));
          }

          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final records = snapshot.data!;
          if (records.isEmpty) {
            return const Center(
              child: Text(
                'No records found.\nTap the + button to add one!',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.grey, fontSize: 16),
              ),
            );
          }

          // 2. The ListView will automatically rebuild when the stream emits
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: records.length,
            separatorBuilder: (_, __) => const Divider(),
            itemBuilder: (context, index) {
              final record = records[index];
              return ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  record['title'] ?? 'Untitled',
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
                subtitle: Text(
                  'ID: ${record['id']} • Updated: ${record['updated_at']}',
                  style: TextStyle(color: Colors.blueGrey[600], fontSize: 12),
                ),
                trailing: IconButton(
                  icon:
                      const Icon(Icons.delete_outline, color: Colors.redAccent),
                  onPressed: () =>
                      MobileQuickStart.deleteRecord(record['id'].toString()),
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => MobileQuickStart.addRecord(
          'note',
          title: 'Quick Note ${DateTime.now().second}',
          content: 'Reactive UI update demo',
        ),
        label: const Text('Add Record'),
        icon: const Icon(Icons.add),
      ),
    );
  }
}
