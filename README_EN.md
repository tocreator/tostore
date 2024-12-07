# ToStore

English | [简体中文](README.md)

ToStore is a high-performance storage engine that redefines data persistence for Dart/Flutter. Implemented purely in Dart, it delivers several times the performance of mainstream Flutter databases through modern API design and innovation. Its multi-space architecture makes user data management unprecedentedly simple, making it the premier storage solution for the Dart platform.

## Why ToStore?

- 🚀 **Ultimate Performance**: 
  - Pure Dart implementation, no platform restrictions
  - Smart caching strategy, continuous performance optimization
  - High concurrency performance far exceeds mainstream solutions

- 🎯 **Easy to Use**: 
  - Fluent chainable API design
  - Support for both SQL and Map style queries
  - 5-minute migration ready

- 🔄 **Innovative Architecture**: 
  - Breakthrough multi-space design
  - Complete user data isolation
  - Effortless global table sharing

- 🛡️ **Enterprise-Grade Reliability**: 
  - Automatic backup and recovery
  - Data integrity validation
  - ACID transaction support

## Quick Start

1. Add dependency:

```yaml
dependencies:
  tostore: ^1.8.1
```

2. Basic usage:

```dart
// Initialize database
final db = ToStore(
  version: 1,
  onCreate: (db) async {
    // Create table
    await db.createTable(
      'users',
      TableSchema(
        primaryKey: 'id',
        fields: [
          FieldSchema(name: 'id', type: DataType.integer, nullable: false),
          FieldSchema(name: 'name', type: DataType.text, nullable: false),
          FieldSchema(name: 'age', type: DataType.integer),
        ],
        indexes: [
          IndexSchema(fields: ['name'], unique: true),
        ],
      ),
    );
  },
);

// Insert data
await db.insert('users', {
  'id': 1,
  'name': 'John',
  'age': 30,
});

// Update data
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// Delete data
await db.delete('users').where('id', '!=', 1);

// Chain query with complex conditions
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// Count records
final count = await db.query('users').count();

// SQL style query
final users = await db.queryBySql(
  'users',
  where: 'age > 20 AND name LIKE "%John%" OR id IN (1, 2, 3)',
  limit: 10
);

// Map style query
final users = await db.queryByMap(
  'users',
  where: {
    'age': {'>=': 30},
    'name': {'like': '%John%'},
  },
  orderBy: ['age'],
  limit: 10,
);
```

## Multi-Space Architecture

ToStore's multi-space architecture makes multi-user data management effortless:

```dart
// Switch to user space
await db.switchBaseSpace(spaceName: 'user_123');

// Query user data
final followers = await db.query('followers');

// Set or update key-value data, isGlobal: true means global data
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// Get global key-value data
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```

## Performance

In high-concurrency scenarios including batch writes, random read/writes, and conditional queries, ToStore demonstrates exceptional performance, far surpassing other mainstream databases available for Dart/Flutter.

## More Features

- 💫 Elegant chainable API
- 🎯 Smart type inference
- 📝 Complete code hints
- 🔐 Automatic incremental backup
- 🛡️ Data integrity validation
- 🔄 Crash auto-recovery
- 📦 Smart data compression
- 📊 Automatic index optimization
- 💾 Tiered caching strategy

## Documentation

Visit our [Wiki](https://github.com/tocreator/tostore) for detailed documentation.

## Support & Feedback

- Submit Issues: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- Join Discussions: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- Contribute: [Contributing Guide](CONTRIBUTING.md)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---

<p align="center">If you find ToStore helpful, please give us a ⭐️</p> 