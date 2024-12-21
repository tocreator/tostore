
# Tostore

[English](README.md) | 简体中文

Tostore 是一款专为移动应用打造的高性能数据存储引擎。它采用纯 Dart 实现，通过 B+ 树索引结构和智能缓存策略，实现了卓越的性能表现。其多空间架构不仅解决了用户数据隔离及全局数据共享难点，配合事务保护、自动修复、增量备份、闲置零损耗等企业级特性，为移动应用提供了一个安全可靠的数据存储方案。

## 为什么选择 Tostore?

- 🚀 **极致性能**: 
  - B+ 树索引结构，智能查询优化
  - 智能缓存策略，毫秒级响应
  - 并发读写无阻塞，性能稳定可靠
- 🎯 **简单易用**: 
  - 流畅的链式 API 设计
  - 支持 SQL/Map 多风格查询
  - 智能类型推导，代码提示完善
  - 无需复杂配置，开箱即用
- 🔄 **创新架构**: 
  - 多空间数据隔离，完美支持多用户
  - 全局数据共享，解决配置同步难题
  - 支持嵌套事务，数据操作更灵活
  - 空间按需加载，资源占用最小
- 🛡️ **企业级可靠**: 
  - ACID 事务保护，数据一致性保证
  - 增量备份机制，快速恢复能力
  - 数据完整性校验，自动错误修复

## 快速开始

1. 添加依赖:

```yaml
dependencies:
  tostore: ^1.8.1
```

2. 基础使用:

```dart
// 初始化数据库
final db = ToStore(
  version: 1,
  onCreate: (db) async {
    // 创建表
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
await db.initialize(); // 可省略，能确保初始化数据库完成就绪，再执行数据库操作

// 插入数据
await db.insert('users', {
  'id': 1,
  'name': 'John',
  'age': 30,
});

// 更新数据
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// 删除数据
await db.delete('users').where('id', '!=', 1);

// 链式查询，支持复杂条件
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// 查询记录数
final count = await db.query('users').count();

// Sql风格查询
final users = await db.queryBySql('users',where: 'age > 20 AND name LIKE "%John%" OR id IN (1, 2, 3)', limit: 10);

// Map风格查询
final users = await db.queryByMap(
    'users',
    where: {
      'age': {'>=': 30},
      'name': {'like': '%John%'},
    },
    orderBy: ['age'],
    limit: 10,
);

// 批量插入
await db.batchInsert('users', [
  {'id': 1, 'name': 'John', 'age': 30},
  {'id': 2, 'name': 'Mary', 'age': 25},
]);
```

## 多空间架构

Tostore 的多空间架构设计让多用户数据管理变得轻而易举：

```dart
// 切换到用户
await db.switchBaseSpace(spaceName: 'user_123');

// 查询用户数据
final followers = await db.query('followers');

// 设置键值对数据或更新，isGlobal: true 表示全局数据
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// 获取全局键值对数据
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```

## 性能测试

在高并发场景下的批量写入、随机读写、条件查询等性能测试，Tostore 均表现出色，远超其它支持dart、flutter的主流数据库。

## 更多特性

- 💫 优雅的链式 API
- 🎯 智能的类型推导
- 📝 完善的代码提示
- 🔐 自动增量备份
- 🛡️ 数据完整性校验
- 🔄 崩溃自动恢复
- 📦 智能数据压缩
- 📊 自动索引优化
- 💾 分级缓存策略


我们的目的不是为了打造一个数据库，Tostore只是从Toway框架中抽离出来供大家候选，如果您正在开发移动应用，推荐使用Toway框架，一体化生态，涉及了Flutter应用开发的全栈解决方案，使用Toway后，您将无须触及底层数据库，数据请求、加载、存储、缓存、展示等，均由Toway框架自动完成。
关于Toway框架更多信息，请访问[Toway仓库](https://github.com/tocreator/toway)

## 文档

访问我们的 [Wiki](https://github.com/tocreator/tostore) 获取详细文档。

## 支持与反馈

- 提交 Issue: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 加入讨论: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- 贡献代码: [Contributing Guide](CONTRIBUTING.md)

## 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件。

---

<p align="center">如果觉得 Tostore 对你有帮助，欢迎给我们一个 ⭐️</p>
