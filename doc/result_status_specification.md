# ToStore ResultStatus 自动化诊断与状态解析规范文档

为了方便自动化运维、AI 智能体代理、自动化测试脚本以及客户端程序精准识别数据库的各种运行结果和异常状态，ToStore 在新版本中引入了结构化的 `ResultStatus` 体系。

本规范文档旨在详细介绍 `ResultStatus` 的状态码设计原则、语义化标识规范、以及各类状态的专属字段结构，以帮助数据库用户和开发者自主完成状态解析开发。

---

## 1. 核心设计原则

### 1.1 状态码 (code) 数字规范
所有的数字状态码 (`code`) 均采用固定长度的 5 位数字进行定义（除成功状态外）：
* **成功状态（Special Success Code）**：特殊固定为 `0`。
* **其他状态（Error & Diagnostic Codes）**：统一为 5 位数字。
* **Class Code（大类代码）**：状态码的前两位数字，用于快速圈定大类范围。
* **Leaf Code（叶子节点代码）**：状态码的后三位数字，代表具体错误场景。

> [!TIP]
> 开发者可以直接通过状态码的前两位数字（大类代码）或者其所处的数值区间，在逻辑中快速路由到相应的异常处理器，然后再根据叶子节点进行精细化处理。

### 1.2 语义化状态标识符 (codeKey) 规范
每个状态都对应一个唯一的字符串标识符 `codeKey`：
* **命名格式**：`[大类前缀]_[多层级详情标识]`。
* **命名规范**：由大写英文字母和下划线 `_` 构成，不包含空格或特殊字符。
* **大类前缀**：前缀指示其属于哪个核心业务大类。如果包含多层大类，最重要、最通用的大类前缀置于最前方，以便进行前缀检索和范围过滤。

---

## 2. 大类代码 (Class Code) 快速检索表

以下是 ToStore 中所有 Class Code 大类的映射定义：

| 大类名称 (Class Name) | 大类代码 (前2位) | 大类数值区间 | 状态描述说明 |
| :--- | :--- | :--- | :--- |
| **success** | `0` (特殊) | `0` | 操作完全成功 |
| **partialSuccess** | `10` | `[10000, 10999]` | 批量操作部分成功 |
| **invalidArgument** | `40` | `[40000, 40999]` | 参数格式错误或参数值无效 |
| **permissionDenied** | `41` | `[41000, 41999]` | 访问与操作权限拒绝 |
| **validationFailed** | `42` | `[42000, 42999]` | 数据格式或非空约束校验失败 |
| **invalidSchema** | `43` | `[43000, 43999]` | 表结构定义非法或数据库迁移受阻 |
| **notFound** | `44` | `[44000, 44999]` | 找不到对应的资源（表、记录、索引） |
| **constraintViolation** | `45` | `[45000, 45999]` | 数据库完整性约束冲突（主键、唯一、外键、Check等） |
| **transactionError** | `50` | `[50000, 50999]` | 事务执行失败、冲突或回滚 |
| **timeout** | `51` | `[51000, 51999]` | 操作超时（执行超时、查询超时） |
| **resourceExhausted** | `52` | `[52000, 52999]` | 系统资源耗尽（内存不足、磁盘满等） |
| **ioError** | `53` | `[53000, 53999]` | 底层系统文件 IO 读写异常 |
| **dbError** | `54` | `[54000, 54999]` | 数据库引擎错误或版本不兼容 |
| **unknown** | `99` | `[99000, 99999]` | 未知或未分类的异常 |

---

## 3. ResultStatus 公共字段结构

所有类型的 `ResultStatus` 转化为 JSON 时，都包含以下 4 个基础公共字段。用户可以直接读取这 4 个字段进行初步判定。

| 字段名 (Field) | 类型 (Type) | 字段含义 (Description) |
| :--- | :--- | :--- |
| `index` | `int` | 在批量操作中的记录序号/索引。若是单条操作，则固定为 `0` |
| `code` | `int` | 数字状态码（0 代表成功，5 位数字代表异常） |
| `codeKey` | `String` | 语义化状态标识符，例如 `CONSTRAINT_VIOLATION_UNIQUE` |
| `message` | `String` | 人类可读的状态详情描述信息 |

---

## 4. 详细解析结构与专属字段说明

根据不同的 `codeKey` 范围和 `ResultStatus` 具体的子类，序列化后的 JSON 结构会携带不同的**专属诊断字段**。

### 4.1 SuccessStatus（操作成功状态）
* **大类范围**：`code == 0`，`codeKey == "SUCCESS"`
* **适用场景**：记录插入、修改、删除等操作完全成功。
* **专属字段**：
  * `primaryKey` (`String?`, 可选): 本次操作成功插入或更新的记录主键。
* **JSON 反序列化样例**：
  ```json
  {
    "index": 0,
    "code": 0,
    "codeKey": "SUCCESS",
    "message": "Operation successful",
    "primaryKey": "usr_9a8f4c2b"
  }
  ```

---

### 4.2 ConstraintStatus（数据完整性与约束冲突状态）
* **大类范围**：`code == 42001`、`code == 44002` 或 `code` 处于区间 `[45000, 45999]` 之间。
* **适用场景**：
  * 非空约束失败 (`VALIDATION_FAILED_NOT_NULL`)
  * 主键冲突 (`CONSTRAINT_VIOLATION_PRIMARY_KEY`)
  * 唯一索引冲突 (`CONSTRAINT_VIOLATION_UNIQUE`)
  * 外键约束冲突及相关动作受限 (`CONSTRAINT_VIOLATION_FOREIGN_KEY_...`)
  * Check 约束校验未通过 (`CONSTRAINT_VIOLATION_CHECK`)
  * 记录未找到 (`NOT_FOUND_RECORD` - 便于级联定位)
* **专属字段**：
  * `tableName` (`String`): 发生约束冲突的数据库表名。
  * `constraintName` (`String?`, 可选): 具体的数据库约束名称。
  * `fields` (`List<String>`): 发生冲突或校验失败的关联字段名列表。
  * `conflictingKeys` (`List<dynamic>`): 导致冲突的具体冲突值（例如导致唯一键冲突的邮箱地址、用户名等）。
  * `primaryKey` (`String?`, 可选): 与冲突有关的主键信息。
* **JSON 反序列化样例**（唯一性约束冲突）：
  ```json
  {
    "index": 1,
    "code": 45002,
    "codeKey": "CONSTRAINT_VIOLATION_UNIQUE",
    "message": "pk=usr_123456: [Disk Conflict] unique constraint violation: email",
    "tableName": "users",
    "constraintName": "uk_users_email",
    "fields": ["email"],
    "conflictingKeys": ["test@example.com"],
    "primaryKey": "usr_123456"
  }
  ```

---

### 4.3 SchemaValidationStatus（数据库表结构校验异常）
* **大类范围**：`code` 处于区间 `[43000, 43999]` 之间。
* **适用场景**：
  * 无效的表配置、非法的表名/字段名命名。
  * 数据库表已存在、字段已存在、索引已存在。
  * 存在冲突或非法的数据库迁移（如将有数据的表中的字段改为非空且无默认值、不兼容的数据类型转换等）。
  * TTL（生存时间）配置校验失败等。
* **专属字段**：
  * `tableName` (`String`): 发生结构校验错误的表名。
  * `field` (`String?`, 可选): 导致异常的具体字段名。
  * `wrongValue` (`dynamic`, 可选): 错误的配置对象、格式或引起报错的具体数据类型定义。
* **JSON 反序列化样例**（TTL配置校验失败）：
  ```json
  {
    "index": 0,
    "code": 43016,
    "codeKey": "INVALID_SCHEMA_TTL_CONFIG",
    "message": "TTL configuration validation failed: field 'expire_at' does not exist in table 'logs'",
    "tableName": "logs",
    "field": "expire_at",
    "wrongValue": {
      "enabled": true,
      "fieldName": "expire_at"
    }
  }
  ```

---

### 4.4 InvalidArgumentStatus（接口参数校验异常）
* **大类范围**：`code` 处于区间 `[40000, 40999]` 之间。
* **适用场景**：
  * 传参格式错误 (`INVALID_ARGUMENT_FORMAT`)
  * 类型不匹配 (`INVALID_ARGUMENT_TYPE`)
  * 游标分页冲突或配置错误（如同时传游标和偏移量、游标 orderBy 字段不匹配等）。
* **专属字段**：
  * `parameterName` (`String`): 校验未通过的参数名或查询配置项名称。
  * `passedValue` (`dynamic`, 可选): 调用方传入的具体非法值。
  * `primaryKey` (`String?`, 可选): 与操作关联的记录主键（如果有）。
* **JSON 反序列化样例**（参数类型不匹配）：
  ```json
  {
    "index": 0,
    "code": 40001,
    "codeKey": "INVALID_ARGUMENT_FORMAT",
    "message": "Invalid primary key id value type: twenty (should be number or string type) (table users)",
    "parameterName": "id",
    "passedValue": "twenty"
  }
  ```

---

### 4.5 TransactionOperationStatus（事务控制异常）
* **大类范围**：`code` 处于区间 `[50000, 50999]` 之间。
* **适用场景**：
  * 事务主动放弃/被中止 (`TRANSACTION_ERROR_ABORTED`)
  * 并发事务冲突 / 序列化失败 (`TRANSACTION_ERROR_CONFLICT`)
* **专属字段**：
  * `txId` (`String`): 事务的唯一流水标识符 ID。
* **JSON 反序列化样例**：
  ```json
  {
    "index": 0,
    "code": 50002,
    "codeKey": "TRANSACTION_ERROR_CONFLICT",
    "message": "Transaction conflict, concurrent updates detected on entity version mismatch",
    "txId": "tx_abc123xyz"
  }
  ```

---

### 4.6 GeneralStatus（通用及系统异常）
* **大类范围**：除以上场景外，所有未带专属额外诊断字段的大类，均反序列化为通用状态类。
  * 包括权限拒绝与身份鉴权失败 (`41xxx`)、未找到表或索引 (`44xxx`)、超时 (`51xxx`)、资源耗尽 (`52xxx`)、IO 错误 (`53xxx`)、数据库引擎损坏 (`54xxx`) 以及未知错误 (`99xxx`)。分布式身份与细粒度访问控制（RBAC）扩展，该大类不仅限于基础的读写物理限制，也涵盖了用户身份认证失效、操作越权等一切与安全策略相关的拦截状态。
* **专属字段**：
  * `primaryKey` (`String?`, 可选): 关联操作的记录主键（如果有）。
* **JSON 反序列化样例**（系统大批量操作防 OOM 自动旁路详情模式）：
  ```json
  {
    "index": 0,
    "code": 52002,
    "codeKey": "LARGE_SCALE_OPERATION_REQUIRED_BYPASS",
    "message": "This is a large-scale update operation. To prevent memory overflow, you must explicitly call skipResultDetails() to bypass detailed results collection.",
    "primaryKey": null
  }
  ```

---

## 5. ResultType 叶子节点状态码及标识符全量对照表

开发解析器的用户可以根据下表进行完全的模式匹配 (Pattern Matching) 或哈希查找：

| Code (数字) | CodeKey (语义) | 大类 Class (前2位) | 状态默认含义描述 |
| :--- | :--- | :--- | :--- |
| `0` | `SUCCESS` | `success: 0` | 操作完全成功 |
| `10000` | `PARTIAL_SUCCESS` | `partialSuccess: 10` | 批量操作部分成功 |
| `40001` | `INVALID_ARGUMENT_FORMAT` | `invalidArgument: 40` | 参数格式校验错误 |
| `40002` | `INVALID_ARGUMENT_TYPE` | `invalidArgument: 40` | 参数数据类型不匹配 |
| `40201` | `INVALID_CURSOR_PAGINATION` | `invalidArgument: 40` | 游标分页与 Offset 互斥冲突 |
| `40202` | `INVALID_CURSOR_TABLE` | `invalidArgument: 40` | 游标不匹配当前查询的表 |
| `40203` | `INVALID_CURSOR_SIGNATURE` | `invalidArgument: 40` | 游标防伪指纹/签名校验失败 |
| `40204` | `INVALID_CURSOR_ORDERBY` | `invalidArgument: 40` | 游标排序方向或排序字段不匹配 |
| `40205` | `INVALID_CURSOR_MODE` | `invalidArgument: 40` | 游标 Token 运行模式不匹配 |
| `40206` | `INVALID_CURSOR_PAYLOAD` | `invalidArgument: 40` | 游标结构载荷非法（如遭篡改） |
| `41001` | `PERMISSION_DENIED_READ` | `permissionDenied: 41` | 当前用户无数据读取权限 |
| `41002` | `PERMISSION_DENIED_WRITE` | `permissionDenied: 41` | 当前用户无数据写入权限 |
| `42000` | `VALIDATION_FAILED` | `validationFailed: 42` | 通用数据校验失败 |
| `42001` | `VALIDATION_FAILED_NOT_NULL` | `validationFailed: 42` | 非空约束校验失败 |
| `42002` | `VALIDATION_FAILED_TYPE_CAST` | `validationFailed: 42` | 数据类型强制转换失败 |
| `43000` | `INVALID_SCHEMA` | `invalidSchema: 43` | 通用表结构非法配置 |
| `43001` | `INVALID_SCHEMA_TABLE_NAME` | `invalidSchema: 43` | 表名称格式校验非法 |
| `43002` | `INVALID_SCHEMA_FIELD_NAME` | `invalidSchema: 43` | 字段名称格式校验非法 |
| `43003` | `INVALID_SCHEMA_PRIMARY_KEY` | `invalidSchema: 43` | 主键配置无效或冲突 |
| `43004` | `INVALID_SCHEMA_INDEX_LIMIT` | `invalidSchema: 43` | 超出当前表允许的最大索引数量 |
| `43005` | `INVALID_SCHEMA_TABLE_EXISTS` | `invalidSchema: 43` | 表已存在，无法重复创建 |
| `43006` | `INVALID_SCHEMA_FIELD_EXISTS` | `invalidSchema: 43` | 字段已存在，无法重复添加 |
| `43007` | `INVALID_SCHEMA_INDEX_EXISTS` | `invalidSchema: 43` | 索引已存在，无法重复添加 |
| `43008` | `INVALID_SCHEMA_FOREIGN_KEY` | `invalidSchema: 43` | 外键定义非法（引用了不存在的表或字段） |
| `43009` | `INVALID_SCHEMA_SPACE_MISMATCH` | `invalidSchema: 43` | 全局空间与命名空间隔离层级冲突 |
| `43010` | `MIGRATION_NOT_ALLOWED_WITH_DATA` | `invalidSchema: 43` | 迁移操作可能导致数据丢失，需显式授权运行 |
| `43011` | `MIGRATION_UNSAFE_TYPE_CONVERSION`| `invalidSchema: 43` | 破坏性/高风险的数据类型转换迁移受阻 |
| `43012` | `MIGRATION_BATCH_EXECUTION_FAILED`| `invalidSchema: 43` | 批量数据迁移语句执行失败 |
| `43013` | `MIGRATION_CANNOT_ADD_NON_NULL_FIELD`| `invalidSchema: 43` | 不能向已有数据的表添加无默认值的非空字段 |
| `43014` | `MIGRATION_NULLABLE_TO_NON_NULL_NOT_ALLOWED`| `invalidSchema: 43` | 严禁将已有空值记录的字段直接修改为非空属性 |
| `43015` | `MIGRATION_UNIQUE_TIGHTENING_NOT_ALLOWED`| `invalidSchema: 43` | 严禁将已有重复记录的字段直接修改为唯一属性 |
| `43016` | `INVALID_SCHEMA_TTL_CONFIG` | `invalidSchema: 43` | 生存时间 (TTL) 策略配置错误 |
| `43017` | `INVALID_SCHEMA_DUPLICATE_FIELD_NAME`| `invalidSchema: 43` | 表结构中包含重复定义的字段名称 |
| `43018` | `INVALID_SCHEMA_INDEX_FIELD` | `invalidSchema: 43` | 索引配置指向了不存在的表字段 |
| `44001` | `NOT_FOUND_TABLE` | `notFound: 44` | 指定的数据库表不存在 |
| `44002` | `NOT_FOUND_RECORD` | `notFound: 44` | 指定的主键或查询记录不存在 |
| `44003` | `NOT_FOUND_INDEX` | `notFound: 44` | 指定的数据库索引不存在 |
| `45001` | `CONSTRAINT_VIOLATION_PRIMARY_KEY` | `constraintViolation: 45` | 主键唯一约束冲突 |
| `45002` | `CONSTRAINT_VIOLATION_UNIQUE` | `constraintViolation: 45` | 唯一约束 / 唯一索引冲突 |
| `45003` | `CONSTRAINT_VIOLATION_FOREIGN_KEY` | `constraintViolation: 45` | 通用外键完整性约束冲突 |
| `45004` | `CONSTRAINT_VIOLATION_CHECK` | `constraintViolation: 45` | 检查性条件约束校验未通过 |
| `45005` | `CONSTRAINT_VIOLATION_FOREIGN_KEY_PARENT_NOT_EXIST` | `constraintViolation: 45` | 试图插入的外键引用值在父表中不存在 |
| `45006` | `CONSTRAINT_VIOLATION_FOREIGN_KEY_CHILD_RESTRICT` | `constraintViolation: 45` | 因存在级联子项记录，父表删除/更新被限制 |
| `45007` | `CONSTRAINT_VIOLATION_FOREIGN_KEY_COMPOSITE_MISMATCH` | `constraintViolation: 45` | 复合外键的列数目或键值组合不匹配 |
| `45008` | `CONSTRAINT_VIOLATION_FOREIGN_KEY_TYPE_MISMATCH` | `constraintViolation: 45` | 外键字段与引用的父表主键字段类型不匹配 |
| `50001` | `TRANSACTION_ERROR_ABORTED` | `transactionError: 50` | 事务由于某种原因被中止回滚 |
| `50002` | `TRANSACTION_ERROR_CONFLICT` | `transactionError: 50` | 并发操作触发序列化锁冲突，需重试 |
| `51000` | `TIMEOUT` | `timeout: 51` | 数据库操作执行超时 |
| `51001` | `TIMEOUT_LOCK_ACQUISITION` | `timeout: 51` | 锁资源争抢获取超时 |
| `52000` | `RESOURCE_EXHAUSTED` | `resourceExhausted: 52` | 系统底层资源消耗殆尽 |
| `52001` | `RESOURCE_EXHAUSTED_MEMORY` | `resourceExhausted: 52` | 内存资源不足，执行被拦截以防止进程崩溃 |
| `52002` | `LARGE_SCALE_OPERATION_REQUIRED_BYPASS` | `resourceExhausted: 52` | 超大规模写入操作，要求旁路结果详情以节省内存 |
| `53000` | `IO_ERROR` | `ioError: 53` | 数据库通用物理文件 IO 错误 |
| `53001` | `IO_ERROR_FILE_READ` | `ioError: 53` | 数据库文件读取失败 |
| `53002` | `IO_ERROR_FILE_WRITE` | `ioError: 53` | 数据库文件写入/落盘失败 |
| `54000` | `DB_ERROR` | `dbError: 54` | 数据库引擎底层运行时内部错误 |
| `54001` | `DB_ERROR_ENGINE_INCOMPATIBLE`| `dbError: 54` | 存储引擎版本与当前数据文件不兼容 |
| `54002` | `DB_ERROR_CORRUPTION` | `dbError: 54` | 检测到数据文件受损/校验和损坏 |
| `99001` | `UNKNOWN_ERROR` | `unknown: 99` | 未知系统报错 |

---

## 6. 数据库用户操作结果解析与异常处理建议 (Dart/Flutter 示例)

在 ToStore 中，所有核心的数据操作（如 Insert, Update, Delete 等）都会返回 `DbResult`。对于查询会返回 `QueryResult`，对于事务操作会返回 `TransactionResult`。若发生结构性或致命的开发配置错误，则会抛出 `DbException`。

以下是作为**数据库用户（开发者）**，如何优雅地消费、解析这些响应以及诊断错误的示例：

### 6.1 处理增删改操作响应 (`DbResult`)

```dart
import 'package:tostore/tostore.dart';

void handleDatabaseWriteResult(DbResult result) {
  // 1. 快速判断操作是否整体成功（有无任一条目失败）
  if (!result.hasErrors) {
    print("所有写入操作全部成功，影响条数: ${result.successCount}");

    // 单条操作可通过 firstPrimaryKey 获取主键，无需遍历 statuses
    if (result.firstPrimaryKey != null) {
      print("第一条成功记录的主键: ${result.firstPrimaryKey}");
    }
  } else {
    print("🛑 存在执行失败的条目。成功数: ${result.successCount}, 失败数: ${result.failedCount}");
    print("首个错误类型: ${result.firstType.codeKey} (${result.firstType.code})");

    // 2. 遍历 statuses（与批量操作输入列表的 index 顺序一一对应）
    for (final status in result.statuses) {
      final int idx = status.index; // 操作在批处理中的索引位置

      // 3. 使用模式匹配 (Pattern Matching) 针对不同失败大类做处理
      if (status is SuccessStatus) {
        print("索引 [$idx] 操作成功，主键: ${status.primaryKey}");
      } 
      else if (status is ConstraintStatus) {
        // 数据完整性约束冲突（主键冲突、唯一索引冲突、非空约束违背、外键校验失败等）
        print("索引 [$idx] 约束冲突！表名: ${status.tableName}, 冲突的字段: ${status.fields}");
        print("导致冲突的具体值: ${status.conflictingKeys}, 主键: ${status.primaryKey}");
        print("错误消息: ${status.message}"); // 包含数据库底层返回的真实诊断文本
      } 
      else if (status is InvalidArgumentStatus) {
        // 参数格式或类型不符
        print("索引 [$idx] 传参无效！字段名: ${status.parameterName}, 非法值: ${status.passedValue}");
      } 
      else if (status is GeneralStatus) {
        // 超时、资源不足、文件IO等通用异常
        print("索引 [$idx] 发生通用异常！错误码: ${status.code} (${status.codeKey})");
        print("错误描述: ${status.message}");
      }
    }
  }
}
```

### 6.2 捕获表结构与操作异常 (`DbException`)

对于表创建 (`createTable`)、Schema 变更等致命错误，ToStore 会直接抛出 `DbException`，这同样可以通过捕获并解析其内部的 `statuses` 列表来获取最准确的根因：

```dart
try {
  // 假设存在一个非法的表 Schema 迁移或定义
  await ToStore.open(schemas:[..]);
} on DbException catch (e) {
  print("❌ 数据库执行致命异常！统一组合报错: \n${e.message}");
  
  // 遍历异常中的每一个诊断状态
  for (final status in e.statuses) {
    if (status is SchemaValidationStatus) {
      // 处理表结构校验失败
      print("表结构校验失败！表: ${status.tableName}");
      if (status.field != null) {
        print("问题字段: ${status.field}, 非法的配置值: ${status.wrongValue}");
      }
    } else {
      print("诊断详情: [${status.codeKey}] (Code ${status.code}): ${status.message}");
    }
  }
}
```

### 6.3 处理查询操作结果 (`QueryResult`) 与事务控制 (`TransactionResult`)

* **对于查询**：
  ```dart
  final queryResult = await db.query('users').where('age', '>', 18);
  if (queryResult.hasErrors) {
    // 处理查询层面的异常（例如游标失效、表不存在等）
    print("查询失败！错误码: ${queryResult.type.code}, 消息: ${queryResult.message}");
  } else {
    // 成功获取数据
    final List<Map<String, dynamic>> users = queryResult.data;
    print("查询成功，共拉取到 ${users.length} 条数据，是否有下一页: ${queryResult.hasMore}");
  }
  ```

* **对于事务**：
  ```dart
  final txnResult = await db.transaction(() async {
    await db.insert('users', newUser);
  });
  
  if (txnResult.hasErrors) {
    print("事务回滚！事务ID: ${txnResult.txId}");
    // 提取事务中报错子操作的详细诊断
    for (final status in txnResult.statuses) {
      if (status.type != ResultType.success) {
        print("事务失败原因: [${status.codeKey}] ${status.message}");
      }
    }
  }
}
```
