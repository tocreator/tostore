# Tostore

[English](../../README.md) | 简体中文 | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)


## 为什么选择 Tostore？

Tostore 是Dart/Flutter生态中唯一的分布式向量数据库高性能存储引擎。采用类神经网络式架构，节点间智能互联协同，支持无限节点水平扩展，构建灵活的数据拓扑网络，提供精准的表结构变动识别、加密保护以及多空间数据隔离，充分利用多核心CPU实现极致并行处理，天然支持从移动边缘设备到云端的跨平台协同，具备多种分布式主键算法，为沉浸式虚实融合、多模态交互、空间计算、生成式AI、语义向量空间建模等场景提供强大的数据基座。

随着生成式AI与空间计算驱动计算重心向边缘偏移，终端设备正由单纯的内容展示器演变为局部生成、环境感知与实时决策的核心。传统的单文件嵌入式数据库受限于架构设计，在面对高并发写入、海量向量检索以及云边协同生成时，往往难以支撑智能化应用对极致响应的要求。Tostore 专为边缘设备而生，赋予了边缘端足以支撑复杂AI局部生成与大规模数据流转的分布式存储能力，真正实现云端与边缘的深度协同。

**不怕断电，不怕崩溃**：即使意外断电或应用崩溃，数据也能自动恢复，真正做到零丢失。当数据操作响应时，数据已经安全保存，无需担心数据丢失的风险。

**性能突破极限**：实测普通手机在亿级以上数据量下也能保持恒定检索能力，不会随着数据规模影响，带来远超传统数据库的使用体验。




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
  - 智能资源调度，自动平衡负载，最大化发挥多核心性能
  - 多节点计算网络协同工作，任务处理效率倍增
  - 资源感知的调度框架，自动优化执行计划，避免资源竞争
  - 流式查询接口轻松处理海量数据集

- 🔑 **多样化分布式主键算法**
  - 顺序递增算法 - 自由调整随机步长，隐藏业务规模
  - 时间戳基础算法 - 高并发场景下的最佳选择
  - 日期前缀算法 - 完美支持时间范围数据展示
  - 短码算法 - 生成短小易读的唯一标识符

- 🔄 **智能模式迁移与数据完整性**
  - 精准识别表字段重命名，数据零丢失
  - 毫秒级自动检测表结构变动并完成数据迁移
  - 零停机升级，业务无感知
  - 复杂结构变更的安全迁移策略
  - 外键约束自动验证，支持级联操作，确保数据引用完整性

- 🛡️ **企业级数据安全与持久性**
  - 双重保障机制：数据变更实时记录，确保永不丢失
  - 崩溃自动恢复：意外断电或崩溃后自动恢复未完成操作，数据零丢失
  - 数据一致性保障：多个操作要么全部成功，要么全部回滚，保证数据准确
  - 原子计算更新：表达式系统支持复杂计算，原子执行避免并发冲突
  - 即时安全落盘：操作成功响应时，数据已安全保存，无需等待
  - ChaCha20Poly1305高强度加密算法保护敏感数据
  - 端到端加密，存储与传输全程安全

- 🚀 **智能缓存与检索性能**
  - 多层级智能缓存机制，极速数据检索
  - 与存储引擎深度融合的缓存策略
  - 自适应扩展，数据规模增长下保持稳定性能
  - 实时数据变动通知，查询结果自动更新

- 🔄 **智能数据工作流**
  - 多空间架构，数据隔离兼具全局共享
  - 跨计算节点的智能工作负载分配
  - 为大规模数据训练和分析提供稳固底座


## 安装

> [!IMPORTANT]
> **从 v2.x 升级？** 请阅读 [v3.0 升级指南](../UPGRADE_GUIDE_v3.md) 以了解关键的迁移步骤和重大更改。

在 `pubspec.yaml` 中添加 `tostore` 依赖：

```yaml
dependencies:
  tostore: any # 请使用最新版本
```

## 快速开始

> [!IMPORTANT]
> **定义表结构是首要步骤**：在进行增删改查之前，必须先定义表结构。具体的定义方式取决于您的场景：
> - **移动端/桌面端**：推荐[静态定义](#频繁启动场景集成)。
> - **服务端**：推荐[动态创建](#服务端集成方案)。

```dart
// 1. 初始化数据库
final db = await ToStore.open();

// 2. 插入数据
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. 链式查询（详见[查询操作符](#查询操作符)，支持 =, !=, >, <, LIKE, IN 等）
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// 4. 更新与删除
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. 实时监听 (数据变动时 UI 自动刷新)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('符合条件的用户已更新: $users');
});
```

### 键值对存储 (KV)
适用于不需要定义结构化表的场景，简单实用，内置了高性能的键值对存储，可用于存储配置信息、状态等零散数据。不同空间（Space）的数据是天然隔离的，可设置全局共享。

```dart
// 1. 设置键值对 (支持 String, int, bool, double, Map, List 等)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// 2. 获取数据
final theme = await db.getValue('theme'); // 'dark'

// 3. 删除数据
await db.removeValue('theme');

// 4. 全局键值对 (跨 Space 共享)
// 在不同空间切换后，默认键值对数据会自动失效。使用 isGlobal: true 可以实现全局共享。
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```



## 频繁启动场景集成

📱 **示例**：[mobile_quickstart.dart](example/lib/mobile_quickstart.dart)

```dart
// 适用移动应用、桌面客户端等频繁启动场景的表结构定义方式
// 精准识别表结构变动，自动升级迁移数据，零代码维护
final db = await ToStore.open(
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
          unique: true, // 自动创建唯一索引
          fieldId: 'username',  // 字段唯一标识，可选
        ),
        FieldSchema(
          name: 'email', 
          type: DataType.text, 
          nullable: false, 
          unique: true // 自动创建唯一索引
        ),
        FieldSchema(
          name: 'last_login', 
          type: DataType.datetime,
          createIndex: true // 自动创建索引
        ),
      ],
      // 组合索引示例
      indexes: [
        IndexSchema(fields: ['username', 'last_login']),
      ],
    ),
    // 外键约束定义示例
    TableSchema(
      name: 'posts',
      primaryKeyConfig: const PrimaryKeyConfig(name: 'id'),
      fields: [
        const FieldSchema(name: 'title', type: DataType.text, nullable: false),
        const FieldSchema(name: 'user_id', type: DataType.integer, nullable: false),
        const FieldSchema(name: 'content', type: DataType.text),
      ],
      foreignKeys: [
        ForeignKeySchema(
          name: 'fk_posts_user',
          fields: ['user_id'],              // 当前表的字段
          referencedTable: 'users',         // 引用的表
          referencedFields: ['id'],         // 引用的字段
          onDelete: ForeignKeyCascadeAction.cascade,  // 删除时级联删除，users表的记录删除后会自动删除posts表的数据
          onUpdate: ForeignKeyCascadeAction.cascade,  // 更新时级联更新
        ),
      ],
    ),
  ],
);

// 多空间架构 - 完美隔离不同用户数据
await db.switchSpace(spaceName: 'user_123');
```

### 保持登录状态与退出登录（活跃空间）

多空间适合**按用户隔离数据**：每用户一个空间，登录时切换。通过**活跃空间**与**关闭选项**，可保持当前用户到下次启动，并支持退出登录。

- **保持登录状态**：用户切换到自己的空间后，将其记为活跃空间，下次启动时用 default 打开即可直接进入该空间，无需「先开 default 再切换」。
- **退出登录**：用户退出时，使用 `keepActiveSpace: false` 关闭数据库，下次启动不会自动进入上一用户空间。

```dart

// 登录后：切换到该用户空间并记为活跃空间（保持登录状态）
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// 可选：仅需严格使用 default 时（如仅登录页）—— 不使用已保存的活跃空间
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// 退出登录：关闭并清除活跃空间，下次启动使用 default 空间
await db.close(keepActiveSpace: false);
```



## 服务端集成

🖥️ **示例**：[server_quickstart.dart](example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

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
          indexType: VectorIndexType.ngh,   // NGH算法，高效近邻检索算法
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
// 针对主键及索引的等值查询、IN 查询，由于引擎性能卓越，通常无须额外手动维护查询缓存。

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



## 进阶用法

Tostore 提供了丰富的进阶功能，满足各种复杂业务场景需求：

### 复杂查询嵌套与自定义过滤
支持无限层级的条件嵌套和灵活的自定义函数。

```dart
// 条件嵌套：(type = 'app' OR (id >= 123 OR fans >= 200))
final idCondition = QueryCondition().where('id', '>=', 123).or().where('fans', '>=', 200);

final result = await db.query('users')
    .condition(
        QueryCondition().whereEqual('type', 'app').or().condition(idCondition)
    )
    .limit(20);

// 自定义条件函数
final customResult = await db.query('users')
    .whereCustom((record) => record['tags']?.contains('推荐') ?? false);
```

### 智能存储 (Upsert)
根据 data 中的主键或唯一键判断：存在则更新，不存在则插入。不支持 where，冲突目标由 data 决定。

```dart
// 按主键
final result = await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});

// 按唯一键（记录须包含某一唯一索引的全部字段及必填字段）
await db.upsert('users', {
  'username': 'john',
  'email': 'john@example.com',
  'age': 26,
});

// 批量 upsert
final batchResult = await db.batchUpsert('users', [
  {'username': 'a', 'email': 'a@example.com'},
  {'username': 'b', 'email': 'b@example.com'},
], allowPartialErrors: true);
```


### 表连接关联查询与字段选择
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000)
    .limit(20);
```

### 流式处理与统计
```dart
// 统计记录数
final count = await db.query('users').count();

// 聚合函数
final totalAge = await db.query('users').where('age', '>', 18).sum('age');
final avgAge = await db.query('users').avg('age');
final maxAge = await db.query('users').max('age');
final minAge = await db.query('users').min('age');

// 分组统计与过滤
final result = await db.query('orders')
    .select(['status', Agg.sum('amount', alias: 'total')])
    .groupBy(['status'])
    .having(Agg.sum('amount'), '>', 1000)
    .limit(20);

// 去重查询
final uniqueCities = await db.query('users').distinct(['city']);

// 流式查询 (适用于海量数据)
db.streamQuery('users').listen((data) => print(data));
```



### 查询与高效分页

> [!TIP]
> **显式指定 `limit` 以获得最佳性能**：强烈建议在查询时始终指定 `limit`。如果省略，引擎默认限制为 1000 条记录。虽然核心查询速度极快，但在应用层序列化大量记录可能会带来不必要的耗时开销。

Tostore 提供双模式分页支持，您可以根据数据规模和性能需求灵活选择：

#### 1. 基础分页 (Offset Mode)
适用于数据量较小（如万级以下）或需要精确跳转页码的场景。

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // 跳过前 40 条
    .limit(20); // 取 20 条
```
> [!TIP]
> 当 `offset` 非常大时，数据库需要扫描并丢弃大量记录，性能会线性下降。建议深度翻页时使用 **Cursor 模式**。

#### 2. 高性能游标分页 (Cursor Mode)
**推荐用于海量数据和无限滚动场景**。利用 `nextCursor` 实现 O(1) 级别的性能，确保无论翻到多少页，查询速度始终恒定。

> [!IMPORTANT]
> 对于部分复杂的查询或针对未索引字段进行排序时，引擎可能会回退到全表扫描并返回 `null` 游标（即暂不支持该特定查询的分页）。

```dart
// 第一页查询
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// 使用返回的游标查询下一页
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // 传入游标，引擎将直接 seek 到对应位置
}

// 同理，使用 prevCursor 可以实现高效回翻
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| 特性 | Offset 模式 | Cursor 模式 |
| :--- | :--- | :--- |
| **查询性能** | 随页数增加而下降 | **始终恒定 (O(1))** |
| **适用范围** | 少量数据、精确跳转 | **海量数据、无限滚动** |
| **数据一致性** | 数据变动后可能导致跳行 | **完美避免数据变动导致的重复或遗漏** |



### 查询操作符

所有 `where(field, operator, value)` 条件支持以下操作符（大小写不敏感）：

| 操作符 | 说明 | 示例 / 值类型 |
| :--- | :--- | :--- |
| `=` | 等于 | `where('status', '=', 'active')` |
| `!=`, `<>` | 不等于 | `where('role', '!=', 'guest')` |
| `>` | 大于 | `where('age', '>', 18)` |
| `>=` | 大于等于 | `where('score', '>=', 60)` |
| `<` | 小于 | `where('price', '<', 100)` |
| `<=` | 小于等于 | `where('quantity', '<=', 10)` |
| `IN` | 在列表中 | `where('id', 'IN', ['a','b','c'])` — value: `List` |
| `NOT IN` | 不在列表中 | `where('status', 'NOT IN', ['banned'])` — value: `List` |
| `BETWEEN` | 介于（含首尾） | `where('age', 'BETWEEN', [18, 65])` — value: `[start, end]` |
| `LIKE` | 模式匹配（`%` 任意，`_` 单字符） | `where('name', 'LIKE', '%John%')` — value: `String` |
| `NOT LIKE` | 模式不匹配 | `where('email', 'NOT LIKE', '%@test.com')` — value: `String` |
| `IS` | 为 null | `where('deleted_at', 'IS', null)` — value: `null` |
| `IS NOT` | 不为 null | `where('email', 'IS NOT', null)` — value: `null` |

### 语义化查询方法（推荐）

推荐使用语义化方法，避免手写操作符字符串并便于 IDE 提示：

```dart
// 比较
db.query('users').whereEqual('username', 'John');
db.query('users').whereNotEqual('role', 'guest');
db.query('users').whereGreaterThan('age', 18);
db.query('users').whereGreaterThanOrEqualTo('score', 60);
db.query('users').whereLessThan('price', 100);
db.query('users').whereLessThanOrEqualTo('quantity', 10);

// 集合与范围
db.query('users').whereIn('id', ['id1', 'id2']);
db.query('users').whereNotIn('status', ['banned', 'pending']);
db.query('users').whereBetween('age', 18, 65);

// 空值判断
db.query('users').whereNull('deleted_at');
db.query('users').whereNotNull('email');

// 模式匹配
db.query('users').whereLike('name', '%John%');
db.query('users').whereNotLike('email', '%@temp.');
db.query('users').whereContains('bio', 'flutter');   // LIKE '%flutter%'
db.query('users').whereNotContains('title', 'draft');

// 等价于：.where('age', '>', 18).where('name', 'like', '%John%')
final users = await db.query('users')
    .whereGreaterThan('age', 18)
    .whereLike('username', '%John%')
    .orderByDesc('age')
    .limit(20);
```

## 分布式架构

```dart
// 配置分布式节点
final db = await ToStore.open(
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


## 表达式原子操作

表达式系统提供类型安全的原子字段更新，所有计算在数据库层面原子执行，避免并发冲突：

```dart
// 简单增量：balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// 复杂计算：total = price * quantity + tax
await db.update('orders', {
  'total': Expr.field('price') * Expr.field('quantity') + Expr.field('tax'),
}).where('id', '=', orderId);

// 多层括号：finalPrice = ((price * quantity) + tax) * (1 - discount)
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) * 
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// 使用函数：price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// 时间戳：updatedAt = now()
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

**条件判断（如 upsert 中区分更新/插入）**：使用 `Expr.isUpdate()` / `Expr.isInsert()` 配合 `Expr.ifElse` 或 `Expr.when`，使表达式仅在更新或仅在插入时执行：

```dart
// Upsert：更新时自增，插入时设为 1（插入分支用普通值即可，仅更新路径会求值表达式）
await db.upsert('counters', {
  'key': 'visits',
  'count': Expr.ifElse(
    Expr.isUpdate(),
    Expr.field('count') + Expr.value(1),
    1,  // 插入分支：字面量，insert 不会对其做表达式求值
  ),
});

// 使用 Expr.when（单分支，否则为 null）
await db.upsert('orders', {
  'id': orderId,
  'updatedAt': Expr.when(Expr.isUpdate(), Expr.now(), otherwise: Expr.now()),
});
```

## 事务操作

事务确保多个操作的原子性，要么全部成功，要么全部回滚，保证数据一致性：

**事务特性**：
- 多个操作要么全部成功，要么全部回滚，保证数据准确
- 崩溃后自动恢复未完成的操作
- 操作成功时数据已安全保存

```dart
// 基本事务 - 多个操作原子提交
final txResult = await db.transaction(() async {
  // 插入用户
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });
  
  // 使用表达式原子更新
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');
  
  // 如果任何操作失败，所有更改都会自动回滚
});

if (txResult.isSuccess) {
  print('事务提交成功');
} else {
  print('事务回滚: ${txResult.error?.message}');
}

// 错误时自动回滚
final txResult2 = await db.transaction(() async {
  await db.insert('users', {
    'username': 'jane',
    'email': 'jane@example.com',
  });
  throw Exception('业务逻辑错误'); // 触发回滚
}, rollbackOnError: true);
```

## 安全配置

**数据安全机制**：
- 双重保障机制确保数据永不丢失
- 崩溃后自动恢复未完成操作
- 操作成功时数据已安全保存
- 高强度加密算法保护敏感数据

> [!WARNING]
> **密钥管理**：**`encodingKey`** 可随意修改，修改后引擎会自动迁移数据，无需担心数据不可恢复。**`encryptionKey`** 不可随意变更，变更后旧数据将无法解密（除非执行数据迁移）。请勿硬编码敏感密钥，建议从安全服务端获取。

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // 加密算法支持：none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305, 
      
      // 编码密钥（可随意修改，修改后数据会自动迁移）
      encodingKey: 'Your-32-Byte-Long-Encoding-Key...', 
      
      // 关键数据加密密钥（不可随意变更，否则旧数据无法解密，除非执行迁移）
      encryptionKey: 'Your-Secure-Encryption-Key...',
      
      // 设备绑定 (Path-based binding)
      // 开启后密钥将与数据库文件路径、设备特征深度绑定。数据在不同物理路径下无法解密。
      // 优点：极大地提升了暴力拷贝数据库文件的安全性。
      // 缺点：如果应用安装路径发生变化及设备特征发生变化，数据将无法还原。
      deviceBinding: false, 
    ),
    // 启用崩溃恢复日志 (Write-Ahead Logging)，默认开启
    enableJournal: true, 
    // 事务提交时是否强制刷新数据到磁盘，追求极致性能可设为 false（交由后台自动刷新）
    persistRecoveryOnCommit: true,
  ),
);
```

### 价值级加密（ToCrypto）

上文的全库加密会加密所有表与索引数据，可能影响整体性能。若只需加密部分敏感字段，可使用 **ToCrypto**：与数据库解耦（无需 db 实例），在写入前或读取后自行对值进行编码/解码，密钥由应用完全管理。输出为 Base64，适合存入 JSON 或 TEXT 列。

- **key**（必填）：`String` 或 `Uint8List`。若非 32 字节，将用 SHA-256 派生为 32 字节。
- **type**（可选）：加密类型 [ToCryptoType]： [ToCryptoType.chacha20Poly1305] 或 [ToCryptoType.aes256Gcm]。默认 [ToCryptoType.chacha20Poly1305]。不传则使用默认。
- **aad**（可选）：附加认证数据，类型为 `Uint8List`。若在编码时传入，解码时必须传入相同字节（例如表名+字段名做上下文绑定）；简单用法可不传。

```dart
const key = 'my-secret-key';
// 编码：明文 → Base64 密文（可存入 DB 或 JSON）
final cipher = ToCrypto.encode('sensitive data', key: key);
// 读取时解码
final plain = ToCrypto.decode(cipher, key: key);

// 可选：用 aad 绑定上下文（编码与解码须使用相同 aad）
final aad = Uint8List.fromList(utf8.encode('users:id_number'));
final cipher2 = ToCrypto.encode('secret', key: key, aad: aad);
final plain2 = ToCrypto.decode(cipher2, key: key, aad: aad);
```

## 性能与体验

### 性能表现

- **启动速度**：实测普通手机在亿级数据量下也能立即启动，即时展示数据
- **查询性能**：不会随着数据规模影响，恒定保持极速检索能力
- **数据安全**：ACID事务保障 + 崩溃恢复机制，数据零丢失

### 体验建议

- 📱 **示例项目**：`example` 目录下提供了完整的Flutter应用示例
- 🚀 **生产环境**：建议打包release版本，release模式下性能远超调试模式
- ✅ **标准测试**：所有基础、核心功能都通过了标准测试

### 视频演示

<p align="center">
  <img src="../media/basic-demo.gif" alt="Tostore 基础性能演示" width="320" />
  </p>

- **基础性能演示**（<a href="../media/basic-demo.mp4?raw=1" target="_blank" rel="noopener">basic-demo.mp4</a>）：GIF 预览可能显示不全，请点击视频查看完整演示。在普通手机上，即便数据量超过亿级，应用的启动、翻页与检索性能依旧保持稳定顺滑。只要存储空间充足，在边缘设备上也可以支撑 TB、PB 级数据规模，而交互时延始终保持在可接受范围内。

<p align="center">
  <img src="../media/disaster-recovery.gif" alt="Tostore 灾难恢复压力测试" width="320" />
  </p>

- **灾难恢复压力测试**（<a href="../media/disaster-recovery.mp4?raw=1" target="_blank" rel="noopener">disaster-recovery.mp4</a>）：在高频写入过程中，故意反复中断进程，模拟崩溃与断电，即便有成千上万条写入操作被意外打断，Tostore 也能在普通手机上快速完成自恢复，不影响下一次启动和数据可用性。




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

本项目采用 Apache License 2.0 许可证 - 详见 [LICENSE](LICENSE) 文件

---


