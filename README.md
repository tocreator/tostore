# ToStore

English | [简体中文](docs/translations/README.zh-CN.md) | [日本語](docs/translations/README.ja.md) | [한국어](docs/translations/README.ko.md) | [Español](docs/translations/README.es.md) | [Português (Brasil)](docs/translations/README.pt-BR.md) | [Русский](docs/translations/README.ru.md) | [Deutsch](docs/translations/README.de.md) | [Français](docs/translations/README.fr.md) | [Italiano](docs/translations/README.it.md) | [Türkçe](docs/translations/README.tr.md)

ToStore is a high-performance storage engine built specifically for mobile applications. Implemented purely in Dart, it achieves exceptional performance through B+ tree indexing and intelligent caching strategies. Its multi-space architecture solves the challenges of user data isolation and global data sharing, while enterprise-grade features like transaction protection, automatic repair, incremental backup, and zero-cost idle ensure reliable data storage for mobile applications.

## Why ToStore?

- 🚀 **Ultimate Performance**: 
  - B+ tree indexing with smart query optimization
  - Intelligent caching strategy with millisecond response
  - Non-blocking concurrent read/write with stable performance
- 🎯 **Easy to Use**: 
  - Fluent chainable API design
  - Support for SQL/Map style queries
  - Smart type inference with complete code hints
  - Zero configuration, ready out of the box
- 🔄 **Innovative Architecture**: 
  - Multi-space data isolation, perfect for multi-user scenarios
  - Global data sharing solves configuration sync challenges
  - Support for nested transactions
  - On-demand space loading minimizes resource usage
- 🛡️ **Enterprise-Grade Reliability**: 
  - ACID transaction protection ensures data consistency
  - Incremental backup mechanism with quick recovery
  - Data integrity validation with automatic error repair

## Quick Start

Basic usage:

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
await db.initialize(); // Optional, ensures database is fully initialized before operations

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

// Batch insert
await db.batchInsert('users', [
  {'id': 1, 'name': 'John', 'age': 30},
  {'id': 2, 'name': 'Mary', 'age': 25},
]);
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

Our goal isn't just to create another database. ToStore is extracted from the Toway framework to provide an alternative solution. If you're developing mobile applications, we recommend using the Toway framework, which offers a complete Flutter development ecosystem. With Toway, you won't need to deal with the underlying database directly - data requests, loading, storage, caching, and display are all handled automatically by the framework.
For more information about the Toway framework, visit the [Toway Repository](https://github.com/tocreator/toway)

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