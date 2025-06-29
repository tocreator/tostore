# Tostore

[English](../../README.md) | 简体中文 | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)


## 为什么选择 Tostore？

Tostore 是Dart/Flutter生态中唯一的分布式向量数据库高性能存储引擎，采用多分区并行机制和互联拓扑结构构建智能数据网络，提供精准的表结构变动识别、加密保护以及多空间架构，Isolate并行处理机制充分释放多核心性能，dart跨平台特性天然支持从移动边缘设备到云端的协同参与，多种分布式主键算法与节点水平扩展能力，为沉浸式虚实融合、多模态交互、空间计算、生成式AI、语义向量空间建模提供分布式数据基座。


......  从指尖到云端应用，Tostore助你释放数据算力，赋能未来 ......




## Tostore特性

- 🌐 **全平台无缝支持**
  - 从移动应用到云端服务器，一套代码全平台运行
  - 智能适配不同平台存储后端（IndexedDB、文件系统等）
  - 统一API接口，跨平台数据同步无忧
  - 边缘设备到云端服务器的无缝数据流动
  - 边缘设备本地向量计算，减少网络延迟与云端依赖

- 🧠 **神经网络式分布式架构**
  - 类神经网络互联节点拓扑结构，高效组织数据流
  - 高性能数据分区机制实现真正分布式处理
  - 智能工作负载动态平衡，资源利用最大化
  - 无限节点水平扩展，轻松构建复杂数据网络

- ⚡ **极致并行处理能力**
  - Isolate实现真正并行读写，CPU多核心全速运行
  - 多节点计算网络协同工作，任务处理效率倍增
  - 资源感知的调度框架，自动优化执行计划
  - 流式查询接口轻松处理海量数据集

- 🔑 **多样化分布式主键算法**
  - 顺序递增算法 - 自由调整随机步长，隐藏业务规模
  - 时间戳基础算法 - 高并发场景下的最佳选择
  - 日期前缀算法 - 完美支持时间范围数据展示
  - 短码算法 - 生成短小易读的唯一标识符

- 🔄 **智能模式迁移**
  - 精准识别表字段重命名，数据零丢失
  - 毫秒级自动检测表结构变动并完成数据迁移
  - 零停机升级，业务无感知
  - 复杂结构变更的安全迁移策略

- 🛡️ **安全保障**
  - ChaCha20Poly1305高强度加密算法保护敏感数据
  - 端到端加密，存储与传输全程安全
  - 细粒度的数据访问控制

- 🚀 **智能缓存与检索性能**
  - 多层级智能缓存机制，极速数据检索
  - 与存储引擎深度融合的缓存策略
  - 自适应扩展，数据规模增长下保持稳定性能

- 🔄 **智能数据工作流**
  - 多空间架构，数据隔离兼具全局共享
  - 跨计算节点的智能工作负载分配
  - 为大规模数据训练和分析提供稳固底座



## 快速开始

```dart
// 初始化数据库
final db = ToStore();
await db.initialize(); // 初始化，确保数据库就绪

// 插入数据
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
});

// 更新数据
await db.update('users', {'age': 31}).where('id', '=', 1);

// 删除数据
await db.delete('users').where('id', '!=', 1);

// 链式查询 - 简洁而强大
// 支持的操作符：=, !=, <>, >, <, >=, <=, LIKE, NOT LIKE, IN, NOT IN, BETWEEN, IS, IS NOT
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// 复杂查询条件嵌套 - 预定义构造查询条件模块化
final recentLoginCondition = QueryCondition()
    .where('fans', '>=', 200);

final idCondition = QueryCondition()
    .where('id', '>=', 123)
    .orCondition(  // orCondition 相当于 OR 条件组合
        recentLoginCondition
    );

// 自定义条件函数 - 灵活处理任何复杂逻辑
final customCondition = QueryCondition()
    .whereCustom((record) {
      // 例如：判断标签包含'推荐'
      return record['tags'] != null && record['tags'].contains('推荐');
    });

// 查询条件嵌套示例 - 展示无限嵌套能力
final result = await db.query('users')
    .condition(      
        QueryCondition()    // 查询条件构造
            .whereEqual('type', 'app')
            .or()
            .condition(idCondition)  // 再次嵌套已定义的条件
    )
    .orCondition(customCondition)    // 或满足自定义复杂条件
    .limit(20);
// SQL等价: 
// SELECT * FROM users 
// WHERE (status = 'active' AND is_vip >= 1)
//   AND (type = 'app' OR id >= 123 OR fans >= 200)
//   OR ([自定义条件：标签包含'推荐'])
// LIMIT 20


// 智能存储 - 存在则更新，不存在则插入
await db.upsert('users', {
  'name': 'John',
  'email': 'john@example.com'
}).where('email', '=', 'john@example.com');
// 或使用主键ID直接更新插入
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});

// 高效统计
final count = await db.query('users').count();

// 流式查询 - 处理大数据集而不占用大量内存
db.streamQuery('users')
  .where('email', 'like', '%@example.com')
  .listen((userData) {
    // 逐条处理数据，避免内存压力
    print('处理用户: ${userData['username']}');
  });

// 键值对存储数据
await db.setValue('isAgreementPrivacy', true);

// 获取键值对数据
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy');

// 选择特定字段查询 - 提高性能
final userProfiles = await db.query('users')
    .select(['id', 'username', 'email']) // 只返回指定字段
    .where('is_active', '=', true)
    .limit(100);

// 表连接查询 - 多表数据关联
final ordersWithUsers = await db.query('orders')
    .select([
      'orders.id', 
      'orders.amount', 
      'users.username as customer_name', // 使用别名
    ])
    .join('users', 'orders.user_id', '=', 'users.id') // 内连接
    .where('orders.amount', '>', 1000)
    .limit(50);

```

## 频繁启动场景集成

```dart
// 适用移动应用、桌面客户端等频繁启动场景的表结构定义方式
// 精准识别表结构变动，自动升级迁移数据，零代码维护
final db = ToStore(
  schemas: [
    const TableSchema(
            name: 'global_settings',
            isGlobal: true,  // 设置为全局表，所有空间可访问
            fields: [],
    ),
    const TableSchema(
      name: 'users', // 表名
      tableId: "users",  // 表名唯一标识，可选，用于100%识别重命名需求，省略也可达到99.99%以上的精准识别率
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id',       // 主键名称
      ),
      fields: [        // 字段定义（不含主键）
        FieldSchema(
          name: 'username', 
          type: DataType.text, 
          nullable: false, 
          unique: true,
          fieldId: 'username',  // 字段唯一标识，可选
        ),
        FieldSchema(
          name: 'email', 
          type: DataType.text, 
          nullable: false, 
          unique: true
        ),
        FieldSchema(
          name: 'last_login', 
          type: DataType.datetime
        ),
      ],
      indexes: [ // 索引定义
        IndexSchema(fields: ['username']),
        IndexSchema(fields: ['email']),
      ],
    ),
  ],
);

// 多空间架构 - 完美隔离不同用户数据
await db.switchSpace(spaceName: 'user_123');

// 获取全局表数据 - 因为表名全局唯一，所以表操作不需要isGlobal参数区分
final globalSettings = await db.query('global_settings');
// 键值对存储才需要标注isGlobal是否全局，查询时与设置一致
await db.setValue('global_config', true, isGlobal: true);
final isAgreementPrivacy = await db.getValue('global_config', isGlobal: true);

```

## 服务端集成

```dart
// 服务端运行时批量创建表结构 - 适合持续运行场景 （单个表创建为 db.createTable）
await db.createTables([
  // 三维空间特征向量存储表结构
  const TableSchema(
    name: 'spatial_embeddings',                // 表名
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',                            // 主键名
      type: PrimaryKeyType.timestampBased,   // 时间戳主键类型，适合高并发写入
    ),
    fields: [
      FieldSchema(
        name: 'video_name',
        type: DataType.text,
        nullable: false,
      ),
      FieldSchema(
        name: 'spatial_features',
        type: DataType.vector,                // 向量存储类型
        vectorConfig: VectorFieldConfig(
          dimensions: 1024,                   // 适配空间特征的高维向量
          precision: VectorPrecision.float32, // 平衡精度和存储空间
        ),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['video_name'],
        unique: true,
      ),
      IndexSchema(
        type: IndexType.vector,              // 向量索引
        fields: ['spatial_features'],
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.hnsw,   // HNSW算法，高效近邻检索算法
          distanceMetric: VectorDistanceMetric.cosine,
          parameters: {
            'M': 16,                         // 每层最大连接数
            'efConstruction': 200,           // 构建质量参数
          },
        ),
      ),
    ],
  ),
  // 其它表...
]);

// 在线表结构更新 - 业务无感知
final taskId = await db.updateSchema('users')
  .renameTable('users_new')                // 修改表名
  .modifyField(
    'username',
    minLength: 5,
    maxLength: 20,
    unique: true
  )                                        // 修改字段属性
  .renameField('old_name', 'new_name')     // 修改字段名
  .removeField('deprecated_field')         // 删除字段
  .addField('created_at', type: DataType.datetime)  // 添加字段
  .removeIndex(fields: ['age'])            // 删除索引
  .setPrimaryKeyConfig(                    // 更改主键配置
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
    
// 监控迁移进度
final status = await db.queryMigrationTaskStatus(taskId);
print('迁移进度: ${status?.progressPercentage}%');


// 手动查询缓存管理 (服务端)
// 在客户端平台（移动端、桌面端）会智能管理。
// 对于服务端或大规模数据等需要精细控制的场景，您可以通过以下API手动管理缓存以获得最佳性能。

// 手动缓存一个查询结果5分钟。若不提供时长，则缓存永不过期。
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// 当相关数据发生变更时，使用 clearQueryCache 来精确地让缓存失效，确保数据一致性。
await db.query('users')
    .where('is_active', '=', true)
    .clearQueryCache();

// 对于需要获取最新实时数据的查询，可以显式禁用缓存。
final freshUserData = await db.query('users')
    .where('is_active', '=', true)
    .noQueryCache();
    
```

## 分布式架构

```dart
// 配置分布式节点
final db = ToStore(
  config: DataStoreConfig(
    distributedNodeConfig: const DistributedNodeConfig(
      enableDistributed: true,            // 启用分布式模式
      clusterId: 1,                       // 集群ID，配置集群归属
      centralServerUrl: 'http://127.0.0.1:8080',
      accessToken: 'b7628a4f9b4d269b98649129'
    )
  )
);

// 高性能批量插入
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... 向量数据记录一次性高效插入
]);

// 流式处理大数据集 - 内存占用恒定
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // 即使是TB级数据，也能高效处理而不占用大量内存
  print(record);
}
```

## 主键类型示例

Tostore提供多种分布式主键算法，支持各种业务场景：

- **有序递增主键** (PrimaryKeyType.sequential)：238978991
- **时间戳主键** (PrimaryKeyType.timestampBased)：1306866018836946
- **日期前缀主键** (PrimaryKeyType.datePrefixed)：20250530182215887631
- **短码主键** (PrimaryKeyType.shortCode)：9eXrF0qeXZ

```dart
// 有序递增主键配置示例
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,           // 递增主键类型
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,                     // 起始值
        increment: 50,                           // 步长
        useRandomIncrement: true,                // 随机步长，隐藏业务量
      ),
    ),
    fields: [/* 字段定义 */]
  ),
]);
```


## 安全配置

```dart
// 数据安全保护配置
final db = ToStore(
  config: DataStoreConfig(
    enableEncoding: true,          // 启用数据安全编码
    encodingKey: 'YourEncodingKey', // 自定义编码密钥，调整后自动迁移数据
    encryptionKey: 'YourEncryptionKey', // 加密密钥（警告：修改后无法访问旧数据，请勿硬编码到应用中）
  ),
);
```





如果 Tostore 对您有所帮助，请给我们一个 ⭐️





## 未来规划

Tostore 正在积极开发以下功能，进一步增强在AI时代的数据基础设施能力：

- **高维向量**：增加向量检索、语义搜索算法
- **多模态数据**：提供从原始数据到特征向量的端到端处理
- **图数据结构**：支持知识图谱和复杂关系网络的高效存储和查询





> **推荐**：移动应用开发者可考虑使用 [Toway 框架](https://github.com/tocreator/toway)，提供全栈解决方案，自动处理数据请求、加载、存储、缓存和展示。




## 更多资源

- 📖 **文档**：[Wiki](https://github.com/tocreator/tostore)
- 📢 **问题反馈**：[GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **技术讨论**：[GitHub Discussions](https://github.com/tocreator/tostore/discussions)


## 许可证

本项目采用 MIT 许可证 - 详见 [LICENSE](LICENSE) 文件

---


