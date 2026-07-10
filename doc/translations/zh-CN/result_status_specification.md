# ToStore ResultStatus 自动化诊断与状态解析规范文档

为了方便自动化运维、AI 智能体代理、自动化测试脚本以及客户端程序精准识别数据库的各种运行结果和异常状态，ToStore 在新版本中引入了结构化的 `ResultStatus` 体系。

本规范文档旨在详细介绍 `ResultStatus` 的状态码设计原则、语义化标识规范、以及各类状态的专属字段结构，以帮助数据库用户和开发者自主完成状态解析开发。

---

## 1. 核心设计原则

### 1.1 状态码 (code) 数字规范

所有的数字状态码 (`code`) 均采用固定长度的 5 位数字进行定义（除成功状态外）：

- **成功状态（Special Success Code）**：特殊固定为 `0`。
- **其他状态（Error & Diagnostic Codes）**：统一为 5 位数字。
- **Class Code（大类代码）**：状态码的前两位数字，用于快速圈定大类范围。
- **Leaf Code（叶子节点代码）**：状态码的后三位数字，代表具体错误场景。

> [!TIP]
> 开发者在开发自动化运维、AI 智能体代理或外围测试脚本时，可以直接通过状态码的前两位数字（大类代码）或者其所处的数值区间，在逻辑中快速路由到相应的异常处理器，然后再根据叶子节点进行精细化处理。

> [!IMPORTANT]
> **内存开发最佳实践 (In-Memory Check)**：
> 在内存中读取数据库操作结果时，**最推荐且最高效的方法是直接使用 `ResultStatus` 或 `ResultType` 的内置只读属性**（如 `isBusinessError`, `isCriticalError` 等，详见 [第 3.2 节](#32-内存便捷判定只读属性-in-memory-helper-getters)），避免手动解析数值区间或匹配字符串前缀。

### 1.2 语义化状态标识符 (codeKey) 规范

每个状态都对应一个唯一的字符串标识符 `codeKey`：

- **命名格式**：`[大类前缀]_[多层级详情标识]`。
- **命名规范**：由大写英文字母和下划线 `_` 构成，不包含空格或特殊字符。
- **大类前缀**：前缀指示其属于哪个核心业务大类。如果包含多层大类，最重要、最通用的大类前缀置于最前方，以便进行前缀检索和范围过滤。

---

## 2. 大类代码 (Class Code) 快速检索表

以下是 ToStore 中所有 Class Code 大类的映射定义：


| 数值区间 (Code Range) | Class Code (前两位) | 语义化前缀 (Prefix) | 错误范畴 (Category)               | 异常抛出策略 (Exception Strategy)                                                                      |
| ----------------- | ---------------- | -------------- | ----------------------------- | ------------------------------------------------------------------------------------------------ |
| `0`               | `00`             | `SUCCESS`      | **操作成功**                      | 不抛出异常，正常返回                                                                                       |
| `10000 - 19999`   | `10 - 19`        | `BIZ_`         | **业务错误** (终端用户输入错误，如约束违反等)    | 不抛出异常，均通过 `DbResult` 或 `QueryResult` 正常响应                                                        |
| `20000 - 49999`   | `20 - 49`        | `DEV_`         | **开发者错误** (接口传参非法、表结构配置无效等)   | **调试环境下直接抛出** `DbException` 打断运行以警告开发者修改；**生产环境下则保持作为结果正常返回**。*(注：版本不兼容及数据迁移重大冲突为致命错误，生产下也强制抛出)* |
| `50000 - 79999`   | `50 - 79`        | `SYS_`         | **系统错误** (磁盘空间不足、IO 异常、锁超时等) | 影响正常运行时抛出异常；其它（如事务冲突）作为结果响应 |
| `99000 - 99999`   | `99`             | `ENG_`         | **引擎错误** (引擎逻辑出错、数据文件损坏、未知错误) | 一般错误不抛出异常，严重时抛出异常                                                                           |


---

## 3. ResultStatus 公共字段结构与内存便捷 Getter

### 3.1 公共字段（序列化 JSON 结构）

所有类型的 `ResultStatus` 转化为 JSON 时，都包含以下 4 个基础公共字段。用户可以直接读取这 4 个字段进行初步判定。


| 字段名 (Field) | 类型 (Type) | 字段含义 (Description)                        |
| ----------- | --------- | ----------------------------------------- |
| `index`     | `int`     | 在批量操作中的记录序号/索引。若是单条操作，则固定为 `0`            |
| `code`      | `int`     | 数字状态码（0 代表成功，5 位数字代表异常）                   |
| `codeKey`   | `String`  | 语义化状态标识符，例如 `CONSTRAINT_VIOLATION_UNIQUE` |
| `message`   | `String`  | 人类可读的状态详情描述信息                             |

### 3.2 内存便捷判定只读属性 (In-Memory Helper Getters)

在 Dart/Flutter 中，`ResultStatus` 和 `ResultType` 直接封装了高效的 `O(1)` 只读属性（Getters），方便在内存中直接、快速地判断错误大类和严重等级，无需手动解析数值范围或做字符串匹配：

| 属性名 (Property) | 类型 (Type) | 属性含义 (Description) |
| --- | --- | --- |
| `isBusinessError` | `bool` | 是否属于 **业务错误**（如约束冲突、格式强转失败等，数值区间 `10000 - 19999`） |
| `isDeveloperError` | `bool` | 是否属于 **开发者错误**（如无效 Schema、传参不合法、表不存在等，数值区间 `20000 - 49999`） |
| `isSystemError` | `bool` | 是否属于 **系统错误**（如锁获取超时、磁盘已满、物理文件锁等，数值区间 `50000 - 79999`） |
| `isEngineError` | `bool` | 是否属于 **底层引擎错误**（数值区间 `99000 - 99999`） |
| `isCriticalError` | `bool` | 是否属于 **严重错误 / 灾难级别事件**（需要人工或运维介入干预解决，如磁盘不足、内存不足、重大数据文件损坏或版本不兼容迁移失败等） |


---

## 4. 详细解析结构与专属字段说明

根据不同的 `code` / `codeKey` 范围和 `ResultStatus` 具体的子类，序列化后的 JSON 结构会携带不同的**专属诊断字段**。以下详细列出了 5 个状态子类的字段取值规范与适用场景映射。

### 4.1 SuccessStatus（操作成功状态）

- **大类范围**：`code == 0`，`codeKey == "SUCCESS"`
- **适用场景**：记录插入、修改、删除等操作完全成功。
- **专属字段定义**：

  | 专属字段 (Field) | 类型 (Type) | 字段含义及填充规则 (Details)                                                                             |
  | ------------ | --------- | ----------------------------------------------------------------------------------------------- |
  | `primaryKey` | `String?` | **非必填**。仅在单条记录写入（如 `insert`）、更新（如 `update`）成功时返回，代表物理生成或修改的记录主键值。批量写入时，子项的 `primaryKey` 也会对应填充。 |

- **JSON 反序列化样例**：
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

- **大类范围**：`code` 处于区间 `[10000, 19999]` 之间（主要为数据校验与完整性冲突）。
- **专属字段定义**：

  | 专属字段 (Field)      | 类型 (Type)       | 字段含义及通用填充规则 (Details)                                                                                   |
  | ----------------- | --------------- | ------------------------------------------------------------------------------------------------------- |
  | `tableName`       | `String`        | **必填**。触发该完整性冲突或未找到错误的具体数据库表名。                                                                          |
  | `constraintName`  | `String?`       | **可选**。导致错误的具体约束名称。如是外键冲突，这里填充外键名称（如 `fk_users_profile`）；如是唯一性索引冲突，这里填充索引名；对于普通的非空或类型强转等无名约束，则为 `null`。 |
  | `fields`          | `List<String>`  | **必填**。参与或导致冲突的字段名列表。如果是多字段联合唯一索引或复合外键，则这里会包含多个字段。                                                      |
  | `conflictingKeys` | `List<dynamic>` | **必填**。引发冲突的具体非空、重复或越界的数据值列表，其顺序与 `fields` 字段列表完全一一对应。如果字段是 null，则列表项为 `null`。                          |
  | `primaryKey`      | `String?`       | **可选**。关联到当前被操作或发生冲突的记录的物理主键。如果发生冲突的不是单条记录操作，或在内存阶段被阻断，则为 `null`。                                       |
  | `referencedTable`  | `String?`       | **可选**。仅在外键约束冲突（如父项不存在、子记录限制等）时填充，代表被关联引用的父表（目标表）名，以便自动化或智能体无需反查 Schema 元数据直接定位关联关系。        |

- **叶子状态码的具体字段填充规范对照表**：

  | 状态与内存类型<br>(Code & ResultType) | 场景描述<br>(Description) | 专属字段填充规范 (Field Guidelines) |
  | :--- | :--- | :--- |
  | `10000`<br>`bizValidationFailed` | 数据格式、值域验证失败 | <ul><li>`tableName`: 触发错误的表名</li><li>`constraintName`: `null`</li><li>`fields`: 违反校验的字段列表，例如 `["email"]`</li><li>`conflictingKeys`: 导致校验失败的非法值，例如 `["invalid-email"]`</li><li>`primaryKey`: 操作的记录主键值（如有）</li></ul> |
  | `10001`<br>`bizNotNullViolation` | 非空约束冲突（缺少必要非空字段值） | <ul><li>`tableName`: 触发错误的表名</li><li>`constraintName`: `null`</li><li>`fields`: 违反非空限制的字段，例如 `["email"]`</li><li>`conflictingKeys`: 恒为 `[null]`</li><li>`primaryKey`: 正在操作的记录主键值（如有）</li></ul> |
  | `10002`<br>`bizTypeCastFailed` | 数据类型转换或强转失败 | <ul><li>`tableName`: 触发错误的表名</li><li>`constraintName`: `null`</li><li>`fields`: 强转失败的字段列表，例如 `["age"]`</li><li>`conflictingKeys`: 导致转换失败的非法值，例如 `["not_a_number"]`</li><li>`primaryKey`: 正在操作的记录主键值（如有）</li></ul> |
  | `11001`<br>`bizPrimaryKeyViolation` | 主键冲突（主键已存在） | <ul><li>`tableName`: 触发冲突的表名</li><li>`constraintName`: 约束名或 `"PRIMARY"`</li><li>`fields`: 主键字段，例如 `["id"]`</li><li>`conflictingKeys`: 冲突的重复主键值，例如 `["usr_101"]`</li><li>`primaryKey`: 冲突的主键值，如 `"usr_101"`</li></ul> |
  | `11002`<br>`bizUniqueViolation` | 唯一索引冲突 | <ul><li>`tableName`: 触发冲突的表名</li><li>`constraintName`: 唯一索引名，例如 `"uk_email"`</li><li>`fields`: 构成唯一性的字段，例如 `["email"]`</li><li>`conflictingKeys`: 导致冲突的输入值，例如 `["test@a.com"]`</li><li>`primaryKey`: 冲突的记录主键（如有）</li></ul> |
  | `11003`<br>`bizForeignKeyViolation` | 外键约束冲突 (通用) | <ul><li>`tableName`: 触发冲突的表名</li><li>`constraintName`: 外键约束名称</li><li>`fields`: 外键涉及的字段名列表</li><li>`conflictingKeys`: 导致冲突的外键值</li><li>`primaryKey`: 操作的记录主键（如有）</li><li>`referencedTable`: 被引用的父表名</li></ul> |
  | `11004`<br>`bizCheckViolation` | Check 校验约束未通过 | <ul><li>`tableName`: 触发冲突的表名</li><li>`constraintName`: Check 约束名</li><li>`fields`: 触发 Check 校验的字段列表</li><li>`conflictingKeys`: 引起校验失败的非法值</li><li>`primaryKey`: 操作的记录主键（如有）</li></ul> |
  | `11005`<br>`bizForeignKeyParentNotExist` | 引用的外键父级记录不存在 | <ul><li>`tableName`: 子表名</li><li>`constraintName`: 外键约束名称</li><li>`fields`: 子表外键字段列表，例如 `["userId"]`</li><li>`conflictingKeys`: 引用的在父表中不存在的键值，例如 `["non_parent"]`</li><li>`primaryKey`: 操作的子表记录主键（如有）</li><li>`referencedTable`: 被引用的父表名</li></ul> |
  | `11006`<br>`bizForeignKeyChildRestrict` | 被子记录关联，无法删除或更新父级记录 | <ul><li>`tableName`: 被删除/更新的父表名</li><li>`constraintName`: 外键约束名称</li><li>`fields`: 被引用的父表字段列表（通常是主键）</li><li>`conflictingKeys`: 试图删除的被子记录引用的父表主键值</li><li>`primaryKey`: 试图删除的父记录主键值</li><li>`referencedTable`: 关联的子表名</li></ul> |
  | `11007`<br>`bizForeignKeyCompositeMismatch` | 复合外键的部分键值未填写导致不完整 | <ul><li>`tableName`: 子表名</li><li>`constraintName`: 外键约束名称</li><li>`fields`: 复合外键的字段列表</li><li>`conflictingKeys`: 传入的复合值列表（包含了部分 null 值）</li><li>`primaryKey`: 操作的子表记录主键（如有）</li><li>`referencedTable`: 被引用的父表名</li></ul> |
  | `11008`<br>`bizForeignKeyTypeMismatch` | 外键两端字段的数据类型不匹配 | <ul><li>`tableName`: 子表名</li><li>`constraintName`: 外键约束名称</li><li>`fields`: 外键的字段列表</li><li>`conflictingKeys`: 无法被正确强转的非法输入值</li><li>`primaryKey`: 操作的记录主键（如有）</li><li>`referencedTable`: 被引用的父表名</li></ul> |
  | `11009`<br>`bizValueExceedsMaxLength` | 值长度超过了 Schema 约束设定的最大长度 | <ul><li>`tableName`: 触发错误的表名</li><li>`constraintName`: `null`</li><li>`fields`: 违反最大长度限制的字段，例如 `["name"]`</li><li>`conflictingKeys`: 导致超限的具体值，例如 `["a" * 1000]`</li><li>`primaryKey`: 操作的记录主键（如有）</li></ul> |
  | `11010`<br>`bizValueLessThanMinLength` | 值长度小于 Schema 约束设定的最小长度 | <ul><li>`tableName`: 触发错误的表名</li><li>`constraintName`: `null`</li><li>`fields`: 违反最小长度限制的字段，例如 `["code"]`</li><li>`conflictingKeys`: 导致长度不足的具体值，例如 `["ab"]`</li><li>`primaryKey`: 操作的记录主键（如有）</li></ul> |
  | `11011`<br>`bizValueLessThanMinValue` | 数值小于 Schema 约束设定的最小值 | <ul><li>`tableName`: 触发错误的表名</li><li>`constraintName`: `null`</li><li>`fields`: 违反最小值限制的字段，例如 `["age"]`</li><li>`conflictingKeys`: 导致小于最小值的具体值，例如 `[-5]`</li><li>`primaryKey`: 操作的记录主键（如有）</li></ul> |
  | `11012`<br>`bizValueExceedsMaxValue` | 数值大于 Schema 约束设定的最大值 | <ul><li>`tableName`: 触发错误的表名</li><li>`constraintName`: `null`</li><li>`fields`: 违反最大值限制的字段，例如 `["score"]`</li><li>`conflictingKeys`: 导致超过最大值的具体值，例如 `[105]`</li><li>`primaryKey`: 操作的记录主键（如有）</li></ul> |
  | `12002`<br>`bizRecordNotFound` | 目标记录不存在 / 指定的主键值未找到 | <ul><li>`tableName`: 操作的表名</li><li>`constraintName`: `null`</li><li>`fields`: 被查询定位的字段列表，例如 `["id"]`</li><li>`conflictingKeys`: 试图定位但未找到的键值，例如 `["non_exist_id"]`</li><li>`primaryKey`: 未找到的记录主键 `"non_exist_id"`</li></ul> | |

- **JSON 反序列化样例**（外键父项不存在冲突）：
  ```json
  {
    "index": 0,
    "code": 11005,
    "codeKey": "BIZ_CONSTRAINT_FOREIGN_KEY_PARENT_NOT_EXIST",
    "message": "Foreign key constraint violation on table \"profiles\" (Constraint: \"fk_profiles_userId\"): Referenced record does not exist in table \"users\" for fields (userId) referencing (id). Conflicting values: [usr_999]",
    "tableName": "profiles",
    "constraintName": "fk_profiles_userId",
    "fields": ["userId"],
    "conflictingKeys": ["usr_999"],
    "primaryKey": "prof_112233",
    "referencedTable": "users"
  }
  ```

---

### 4.3 SchemaValidationStatus（数据库表结构校验与不兼容迁移状态）

- **大类范围**：`code` 处于区间 `[30000, 39999]` 之间（主要为 Schema 静态校验错误以及表结构版本物理迁移不兼容错误）。
- **专属字段定义**：

  | 专属字段 (Field) | 类型 (Type) | 字段含义及填充规则 (Details)                                                                     |
  | ------------ | --------- | --------------------------------------------------------------------------------------- |
  | `tableName`  | `String`  | **必填**。正在操作或尝试升级/校验的数据库表名。                                              |
  | `field`      | `String?` | **可选**。发生表结构校验或迁移错误的具体字段名称。                                          |
  | `wrongValue`  | `dynamic` | **可选**。导致校验失败或物理不兼容迁移的非法/错误配置值或冲突的差异属性。                      |

- **叶子状态码的具体字段填充规范对照表**：

  | 状态与内存类型<br>(Code & ResultType) | 场景描述<br>(Description) | 专属字段填充规范 (Field Guidelines) |
  | :--- | :--- | :--- |
  | `30000`<br>`devInvalidSchema` | 表的 Schema 结构定义配置不正确 | <ul><li>`tableName`: 数据库表名</li><li>`field`: `null`</li><li>`wrongValue`: 无效的配置 Map，或 `null`</li></ul> |
  | `30001`<br>`devInvalidSchemaTableName` | Schema 表名包含非法字符或超过长度限制 | <ul><li>`tableName`: 非法的表名</li><li>`field`: `null`</li><li>`wrongValue`: 非法的表名值</li></ul> |
  | `30002`<br>`devInvalidSchemaFieldName` | Schema 字段名包含非法字符 | <ul><li>`tableName`: 数据库表名</li><li>`field`: 非法的字段名</li><li>`wrongValue`: 非法的字段名值</li></ul> |
  | `30003`<br>`devInvalidSchemaPrimaryKey` | Schema 主键配置格式非法或缺失 | <ul><li>`tableName`: 数据库表名</li><li>`field`: `"primaryKey"` 或 主键字段名</li><li>`wrongValue`: 无效的主键配置定义</li></ul> |
  | `30004`<br>`devInvalidSchemaIndexLimit` | 该表配置的索引数超出了 16 个的系统限制 | <ul><li>`tableName`: 数据库表名</li><li>`field`: `null`</li><li>`wrongValue`: 超限的索引配置列表</li></ul> |
  | `30005`<br>`devSchemaTableExists` | 创建表冲突，目标表已经存在 | <ul><li>`tableName`: 数据库表名</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30006`<br>`devSchemaFieldExists` | 结构升级中，添加了已经存在的同名字段 | <ul><li>`tableName`: 数据库表名</li><li>`field`: 冲突的字段名</li><li>`wrongValue`: `null`</li></ul> |
  | `30007`<br>`devSchemaIndexExists` | 追加了同名的索引配置 | <ul><li>`tableName`: 数据库表名</li><li>`field`: 索引名称</li><li>`wrongValue`: `null`</li></ul> |
  | `30008`<br>`devInvalidSchemaForeignKey` | 外键定义格式非法（如自引用、字段数不对应） | <ul><li>`tableName`: 数据库表名</li><li>`field`: 外键名称</li><li>`wrongValue`: 无效的外键配置定义</li></ul> |
  | `30009`<br>`devInvalidSchemaSpaceMismatch` | 全局表/Space空间表范围定义越界或冲突 | <ul><li>`tableName`: 数据库表名</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30010`<br>`devMigrationNotAllowedWithData` | 结构物理迁移要求对已有数据表进行列修改/删除等有损物理变动，但调用未显式授权允许物理迁移 | <ul><li>`tableName`: 数据库表名</li><li>`field`: `null`</li><li>`wrongValue`: 进行迁移的升级差异集</li></ul> |
  | `30011`<br>`devMigrationUnsafeTypeConversion` | 物理迁移：不支持且极高风险的数据类型转换操作 | <ul><li>`tableName`: 数据库表名</li><li>`field`: 字段名</li><li>`wrongValue`: 迁移时发生转换冲突的类型参数，如 `{ "from": "text", "to": "integer" }`</li></ul> |
  | `30013`<br>`devMigrationCannotAddNonNullField` | 无法对已有数据的表追加不带 default 值的非空 (NOT NULL) 字段 | <ul><li>`tableName`: 数据库表名</li><li>`field`: 试图添加的非空字段名</li><li>`wrongValue`: 冲突的迁移参数，如 `{ "nullable": false, "defaultValue": null }`</li></ul> |
  | `30014`<br>`devMigrationNullableToNonNullNotAllowed` | 物理迁移：在非空表上将字段从 Null 改为 Non-Null 且无默认值 | <ul><li>`tableName`: 数据库表名</li><li>`field`: 字段名</li><li>`wrongValue`: 冲突的迁移参数，同 30013</li></ul> |
  | `30015`<br>`devMigrationUniqueTighteningNotAllowed` | 物理迁移：将非空表上的字段收紧为 UNIQUE，强制拦截抛出 | <ul><li>`tableName`: 数据库表名</li><li>`field`: 字段名</li><li>`wrongValue`: 导致收紧唯一性的索引定义</li></ul> |
  | `30016`<br>`devInvalidSchemaTtlConfig` | 表的 TTL（数据生存周期）配置项非法 | <ul><li>`tableName`: 数据库表名</li><li>`field`: 生效的 TTL 字段名</li><li>`wrongValue`: 无效的 TTL 配置 Map，如 `{ "enabled": true, "fieldName": "expire_at" }`</li></ul> |
  | `30017`<br>`devInvalidSchemaDuplicateFieldName` | 字段重复配置冲突 | <ul><li>`tableName`: 数据库表名</li><li>`field`: 重复的字段名</li><li>`wrongValue`: `null`</li></ul> |
  | `30018`<br>`devInvalidSchemaIndexField` | 索引指向了表中并不存在的字段名 | <ul><li>`tableName`: 数据库表名</li><li>`field`: 索引名称</li><li>`wrongValue`: 索引指向的但在表结构中未定义的非法字段名</li></ul> |

- **JSON 反序列化样例**（对已有数据的表强加非空且无默认值字段）：
  ```json
  {
    "index": 0,
    "code": 30013,
    "codeKey": "DEV_MIGRATION_CANNOT_ADD_NON_NULL_FIELD",
    "message": "Cannot add non-nullable field \"phone\" without a default value to non-empty table \"users\". This operation is physically impossible and would fail during data write.",
    "tableName": "users",
    "field": "phone",
    "wrongValue": {
      "nullable": false,
      "defaultValue": null
    }
  }
  ```

---

### 4.4 InvalidArgumentStatus（接口传参及游标分页校验异常）

- **大类范围**：`code` 处于区间 `[20000, 20999]` 之间（主要为 API 接口的入参格式、传参类型或分页游标不合法校验错误）。
- **专属字段定义**：

  | 专属字段 (Field)    | 类型 (Type) | 字段含义及填充规则 (Details)                                                                   |
  | --------------- | --------- | ------------------------------------------------------------------------------------- |
  | `parameterName` | `String`  | **必填**。发生传参错误的参数名称。常见的如 `"cursor"`（分页游标错误）、`"orderBy"`（排序项错误），或具体字段的传参键名（如 `"id"` 等）。 |
  | `passedValue`   | `dynamic` | **可选**。调用方传入的具体非法值或格式错误的数据。出于数据安全，复杂对象通常会转换为字符串类型再序列化输出。                              |
  | `primaryKey`    | `String?` | **可选**。本次操作中尝试读取、写入或查询关联的单条记录的主键。                                                     |

- **叶子状态码的具体字段填充规范对照表**：

  | 状态与内存类型<br>(Identity & Type) | 场景描述<br>(Description) | 专属字段填充规范 (Field Guidelines) |
  | :--- | :--- | :--- |
  | **Code**: `20001`<br>`ResultType.devInvalidArgumentFormat` | 传参值格式错误（如非法的 key 格式） | <ul><li>`parameterName`: 非法传参的参数名 (如 `"id"`, `"age"`)</li><li>`passedValue`: 传入的非法格式值，如 `"twenty"`</li><li>`primaryKey`: 操作的记录主键（如有）</li></ul> |
  | **Code**: `20002`<br>`ResultType.devInvalidArgumentType` | 参数的数据类型不匹配（期待数字传入字符串等） | <ul><li>`parameterName`: 参数名</li><li>`passedValue`: 传入的非法类型对象，如 `{"foo": "bar"}`（被期望为 String 时）</li><li>`primaryKey`: 操作的记录主键（如有）</li></ul> |
  | **Code**: `20003`<br>`ResultType.devInvalidArgumentMissing` | 必填的接口入参未传入 | <ul><li>`parameterName`: 缺失的必填参数名 (如 `"dbPath"`)</li><li>`passedValue`: `null` (代表该值未传)</li><li>`primaryKey`: 操作的记录主键（如有）</li></ul> |
  | **Code**: `20005`<br>`ResultType.devInvalidPrimaryKeyFormat` | 主键的值格式不符合主键策略（例如自增主键传入了非法的自定义字符串） | <ul><li>`parameterName`: `"primaryKey"` 或 主键字段名</li><li>`passedValue`: 传入的非法主键值，例如 `"invalid_id_value"`</li><li>`primaryKey`: 传入的非法主键值</li></ul> |

  | **Code**: `20010`<br>`ResultType.devVectorDimensionMismatch` | 向量计算或比较时维度不匹配（如点积、距离计算等） | <ul><li>`parameterName`: `"other"`</li><li>`passedValue`: 传入向量的非法维度值</li><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `20011`<br>`ResultType.devIndexFieldMissing` | 从最后一包记录计算游标时，记录中缺失必要的索引字段（用于游标计算续读） | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: 缺失的字段名</li><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `20201`<br>`ResultType.devInvalidCursorPagination` | 分页冲突（游标分页和 Offset 分页不能同时配置） | <ul><li>`parameterName`: `"cursor"` / `"offset"`</li><li>`passedValue`: 冲突的分页配置对象</li><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `20202`<br>`ResultType.devInvalidCursorTable` | 游标包含的表与当前查询表不一致 | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: 游标字符串 (指出游标和当前表不相符)</li><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `20203`<br>`ResultType.devInvalidCursorSignature` | 游标签名哈希校验失败（游标已被篡改） | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: 游标值 (指出签名校验已被损坏或篡改)</li><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `20204`<br>`ResultType.devInvalidCursorOrderBy` | 游标的 orderBy 配置不合规或与原查询不匹配 | <ul><li>`parameterName`: `"orderBy"`</li><li>`passedValue`: 传入的 orderBy 配置数组，如 `["-age", "id"]`</li><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `20205`<br>`ResultType.devInvalidCursorMode` | 游标 Token 模式不匹配 | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: 当前尝试读取的游标模式字符串，如 `"sortKey"`</li><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `20206`<br>`ResultType.devInvalidCursorPayload` | 无法解码或反序列化的非法游标载荷 | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: `null` (代表不可解析的乱码或非法游标 Payload)</li><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `20301`<br>`ResultType.devInvalidQuerySelectField` | 查询 Select 字段非法（不是 String 或 QueryAggregation） | <ul><li>`parameterName`: `"select"`</li><li>`passedValue`: 传入的非法的查询投影字段值</li><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `20302`<br>`ResultType.devInvalidQueryForeignKeyJoin` | 自动 Join 时两表之间未定义外键关系 | <ul><li>`parameterName`: `"join"` / `"tableName"`</li><li>`passedValue`: 试图进行自动 Join 的未定义关联的另一张表名</li><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `20303`<br>`ResultType.devInvalidQueryFieldAlias` | 查询字段的别名命名格式不正确 | <ul><li>`parameterName`: `"alias"`</li><li>`passedValue`: 非法的查询别名定义</li><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `20304`<br>`ResultType.devInvalidExpression` | 表达式配置或求值执行异常（如内置函数参数不符、未知函数等） | <ul><li>`parameterName`: 异常维度（如 `"arguments"`, `"functionName"`, `"node"`)</li><li>`passedValue`: 非法值或参数长度</li><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `22005`<br>`ResultType.devFieldNotFound` | 传入了表中未定义的未知字段 | <ul><li>`parameterName`: 未知或不存在的字段名 (如 `"extra"`)</li><li>`passedValue`: 传入的未知字段值</li><li>`primaryKey`: 操作 of the record primary key (if any)</li></ul> |

- **JSON 反序列化样例**（分页游标的排序条件与查询要求的排序条件冲突）：
  ```json
  {
    "index": 0,
    "code": 20204,
    "codeKey": "DEV_INVALID_CURSOR_ORDERBY",
    "message": "Cursor orderBy fields do not match current query orderBy.",
    "parameterName": "orderBy",
    "passedValue": ["age DESC", "id ASC"],
    "primaryKey": null
  }
  ```

---

### 4.5 TransactionOperationStatus（事务冲突与回滚异常状态）

- **大类范围**：`code` 处于区间 `[50000, 50999]` 之间（主要为事务主动回滚、被动中止或并发更新导致的序列化冲突）。
- **专属字段定义**：

  | 专属字段 (Field) | 类型 (Type) | 字段含义及填充规则 (Details)                                     |
  | ------------ | --------- | ------------------------------------------------------- |
  | `txId`       | `String`  | **必填**。发生冲突或被中止的事务全局唯一流水标识 ID。前端或运维可依据此 ID 定位具体的事务追踪链路。 |

- **叶子状态码的具体字段填充规范对照表**：

  | 状态与内存类型<br>(Identity & Type) | 场景描述<br>(Description) | 专属字段填充规范 (Field Guidelines) |
  | :--- | :--- | :--- |
  | **Code**: `50001`<br>`ResultType.sysTransactionAborted` | 事务内某些原子操作失败、主动执行了 `rollback`，或者由于底层的级联更新策略失败导致事务崩溃。 | <ul><li>`txId`: 当前作用域内的事务 ID</li></ul> |
  | **Code**: `50002`<br>`ResultType.sysTransactionConflict` | 在开启了 SSI (可序列化快照隔离) 或在写入缓冲区合并检测时，发现另一个并发事务已经修改了同一行实体（版本号不匹配）。 | <ul><li>`txId`: 当前发生写-写冲突的事务 ID</li></ul> |

- **JSON 反序列化样例**（并发写写冲突导致事务失败）：
  ```json
  {
    "index": 0,
    "code": 50002,
    "codeKey": "SYS_TRANSACTION_CONFLICT",
    "message": "Transaction conflict, concurrent updates detected on entity version mismatch (record: usr_123456)",
    "txId": "tx_88ff3b2a99c1"
  }
  ```

---

### 4.6 GeneralStatus（通用及系统级异常状态）

- **大类范围**：除以上情况外，未归属于上述四个子类的所有其他状态码，均作为通用异常输出（主要为底层物理限制、系统故障、无权限访问或未知硬件错误）。
- **专属字段定义**：

  | 专属字段 (Field) | 类型 (Type) | 字段含义及填充规则 (Details) |
  | ------------ | --------- | ------------------------------------------------------- |
  | `primaryKey` | `String?` | **可选**。只有当异常能明确归属到某一特定的主键时才会填充，绝大多数底层系统或引擎级异常时为 `null`。 |
  | `target`     | `String?` | **可选**。操作的物理目标标识符。例如：I/O 错误时的**物理路径**；并发锁超时时的**锁资源名**；网络请求时的 **URL**。 |
  | `operation`  | `String?` | **可选**。具体的底层系统操作动作名称。例如：I/O 错误时的 `'readAsString'`、`'delete'`；锁超时时的 `'acquire'`。 |

- **叶子状态码的具体字段填充规范对照表**：

  | 状态与内存类型<br>(Identity & Type) | 级别分类与典型触发场景<br>(Level & Trigger) | 专属字段填充规范 (Field Guidelines) |
  | :--- | :--- | :--- |
  | **Code**: `20007`<br>`ResultType.devIndexOutOfBounds` | **级别**：开发者错误<br>索引或范围超限错误（如越界读写缓冲区）。 | <ul><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `20008`<br>`ResultType.devUnsupportedOperation` | **级别**：开发者错误<br>当前上下文不支持的操作（不支持该平台、未实现等）。 | <ul><li>`primaryKey`: `null`</li><li>`target`: 操作的资源名/表名（如有）</li><li>`operation`: 不支持的具体操作方法名（如有）</li></ul> |
  | **Code**: `22001`<br>`ResultType.devTableNotFound` | **级别**：开发者错误<br>执行 Query 或写入时，传入了尚未创建的非物理表名。 | <ul><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `22003`<br>`ResultType.devIndexNotFound` | **级别**：开发者错误<br>执行 ForceIndex 查询时，指定了根本没有在 Schema 中建立的索引。 | <ul><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `22004`<br>`ResultType.devSpaceNotFound` | **级别**：开发者错误<br>试图操作或删除一个不存在 Space（命名空间/数据库文件路径）时触发。 | <ul><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `23001`<br>`ResultType.devLargeScaleOperationBypassRequired` | **级别**：开发者错误<br>超大规模写入/更新操作需调用 `skipResultDetails()` 开启防 OOM 旁路模式。 | <ul><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `24001`<br>`ResultType.devEngineIncompatible` | **级别**：**致命错误**<br>库配置或数据文件与当前引擎版本不兼容，强制拦截抛出。 | <ul><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `50003`<br>`ResultType.sysTransactionLimitExceeded` | **级别**：系统错误<br>内存压力下事务缓冲数据超过安全限制。 | <ul><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `50004`<br>`ResultType.sysMigrationBatchExecutionFailed` | **级别**：系统错误<br>批量表结构迁移物理执行失败。 | <ul><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `51001`<br>`ResultType.sysTimeoutLockAcquisition` | **级别**：系统错误<br>并发控制：在高负载下等待行锁或表锁，锁获取超时（默认 10s）。 | <ul><li>`primaryKey`: 等待获取锁的主键值（如有）</li><li>`target`: 锁定的资源名称</li><li>`operation`: `"acquire"`</li></ul> |
  | **Code**: `51002`<br>`ResultType.sysTimeout` | **级别**：系统错误<br>系统超时：整个异步运算执行时间超时未归还。 | <ul><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `51003`<br>`ResultType.sysDbClosed` | **级别**：系统错误<br>数据库已关闭，操作安全取消。 | <ul><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `52001`<br>`ResultType.sysResourceExhaustedMemory` | **级别**：系统错误<br>内存报警：JVM / Dart 虚拟机所分配的堆内存空间面临 OOM. | <ul><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `52002`<br>`ResultType.sysResourceExhausted` | **级别**：系统错误<br>磁盘空间耗尽，无法执行落盘写入。 | <ul><li>`primaryKey`: `null`</li></ul> |
  | **Code**: `53001`<br>`ResultType.sysIoNotFound` | **级别**：系统错误<br>物理文件或目录路径不存在。 | <ul><li>`primaryKey`: `null`</li><li>`target`: 物理文件或目录路径</li><li>`operation`: 系统操作动作名称</li></ul> |
  | **Code**: `53002`<br>`ResultType.sysIoPermissionDenied` | **级别**：系统错误<br>物理文件读写权限不足/拒绝访问。 | <ul><li>`primaryKey`: `null`</li><li>`target`: 物理文件或目录路径</li><li>`operation`: 系统操作动作名称</li></ul> |
  | **Code**: `53003`<br>`ResultType.sysIoDiskFull` | **级别**：系统错误<br>磁盘空间不足或写数据超过配额限额。 | <ul><li>`primaryKey`: `null`</li><li>`target`: 物理文件或目录路径</li><li>`operation`: 系统操作动作名称</li></ul> |
  | **Code**: `53004`<br>`ResultType.sysIoFileLocked` | **级别**：系统错误<br>物理文件已被其它进程占用/共享冲突/锁定。 | <ul><li>`primaryKey`: `null`</li><li>`target`: 物理文件或目录路径</li><li>`operation`: 系统操作动作名称</li></ul> |
  | **Code**: `53005`<br>`ResultType.sysIoDeviceFault` | **级别**：系统错误<br>存储设备或介质硬件故障。 | <ul><li>`primaryKey`: `null`</li><li>`target`: 物理文件或目录路径</li><li>`operation`: 系统操作动作名称</li></ul> |
  | **Code**: `53006`<br>`ResultType.sysIoWebStorageUnavailable` | **级别**：系统错误<br>Web 端 IndexedDB 满额、被禁用或初始化失败。 | <ul><li>`primaryKey`: `null`</li><li>`target`: 物理文件或目录路径</li><li>`operation`: 系统操作动作名称</li></ul> |
  | **Code**: `53007`<br>`ResultType.sysBackupCorrupted` | **级别**：系统错误<br>备份包已损坏或缺少清单文件。 | <ul><li>`primaryKey`: `null`</li><li>`target`: 物理清单文件或目录路径</li><li>`operation`: 系统操作动作名称</li></ul> |
  | **Code**: `53008`<br>`ResultType.sysIoDataCorrupted` | **级别**：系统错误<br>数据库数据文件损坏或 CRC 校验失败。 | <ul><li>`primaryKey`: `null`</li><li>`target`: 物理数据文件或目录路径</li><li>`operation`: 系统操作动作名称</li></ul> |
  | **Code**: `53009`<br>`ResultType.sysInvalidDataFormat` | **级别**：系统错误<br>数据流格式或编解码失败（数据反序列化非法）。 | <ul><li>`primaryKey`: `null`</li><li>`target`: 物理数据文件/数据流标识</li><li>`operation`: `"decode"` / `"deserialize"`</li></ul> |
  | **Code**: `53099`<br>`ResultType.sysIoGeneric` | **级别**：系统错误<br>物理文件系统底层遭遇其他硬件或物理 I/O 错误。 | <ul><li>`primaryKey`: `null`</li><li>`target`: 物理文件或目录路径</li><li>`operation`: 系统操作动作名称</li></ul> |
  | **Code**: `99001`<br>`ResultType.engError` | **级别**：引擎错误<br>数据库底层引擎发生代码崩溃、未知内部异常或运行时逻辑缺陷。 | <ul><li>`primaryKey`: `null`</li></ul> |

- **JSON 反序列化样例**（表不存在错误）：
  ```json
  {
    "index": 0,
    "code": 22001,
    "codeKey": "DEV_NOT_FOUND_TABLE",
    "message": "Table \"orders\" not found in database metadata schema.",
    "primaryKey": null
  }
  ```

---

## 5. 数据库用户操作结果解析与异常处理建议 (Dart/Flutter 示例)

在 ToStore 中，所有核心的数据操作（如 Insert, Update, Delete 等）都会返回 `DbResult`。对于查询会返回 `QueryResult`，对于事务操作会返回 `TransactionResult`。若发生结构性或致命的开发配置错误，则会抛出 `DbException`。

以下是作为**数据库用户（开发者）**，如何优雅地消费、解析这些响应以及诊断错误的示例：

### 5.1 处理增删改操作响应 (`DbResult`)

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

### 5.2 捕获表结构与操作异常 (`DbException`)

对于运行时表创建 (`db.createTable`)、表结构变更(`db.updateSchema`)采用响应结果方式，而移动端场景采用实例化定义表结构方式发生表结构不规范校验失败，属于开发者错误类型，ToStore 会直接抛出 `DbException`，这同样可以通过捕获并解析其内部的 `statuses` 列表来获取最准确的根因：

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

### 5.3 处理查询操作结果 (`QueryResult`) 与事务控制 (`TransactionResult`)

- **对于查询**：
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
- **对于事务**：
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
  ```

---

## 6. 全量叶子状态码及语义化标识规范

开发者与智能体可以对照下表，进行精准的状态路由与解析：

| 状态码 (Code) | 状态标识符 (CodeKey) | 内存枚举类型 (ResultType) | 级别 (Level) | 状态含义描述 (Description) |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `SUCCESS` | `ResultType.success` | 成功 | 操作完全执行成功 |
| **10000** | `BIZ_VALIDATION_FAILED` | `ResultType.bizValidationFailed` | 业务错误 | 数据格式、值域验证失败 |
| **10001** | `BIZ_NOT_NULL_VIOLATION` | `ResultType.bizNotNullViolation` | 业务错误 | 非空约束冲突（缺少必要非空字段值） |
| **10002** | `BIZ_VALIDATION_TYPE_CAST` | `ResultType.bizTypeCastFailed` | 业务错误 | 数据类型转换或强转失败 |
| **11001** | `BIZ_CONSTRAINT_PRIMARY_KEY` | `ResultType.bizPrimaryKeyViolation` | 业务错误 | 主键冲突（主键已存在） |
| **11002** | `BIZ_CONSTRAINT_UNIQUE` | `ResultType.bizUniqueViolation` | 业务错误 | 唯一索引冲突 |
| **11003** | `BIZ_CONSTRAINT_FOREIGN_KEY` | `ResultType.bizForeignKeyViolation` | 业务错误 | 外键约束冲突 (通用) |
| **11004** | `BIZ_CONSTRAINT_CHECK` | `ResultType.bizCheckViolation` | 业务错误 | Check 校验约束未通过 |
| **11005** | `BIZ_CONSTRAINT_FOREIGN_KEY_PARENT_NOT_EXIST` | `ResultType.bizForeignKeyParentNotExist` | 业务错误 | 引用的外键父级记录不存在 |
| **11006** | `BIZ_CONSTRAINT_FOREIGN_KEY_CHILD_RESTRICT` | `ResultType.bizForeignKeyChildRestrict` | 业务错误 | 被子记录关联，无法删除或更新父级记录 |
| **11007** | `BIZ_CONSTRAINT_FOREIGN_KEY_COMPOSITE_MISMATCH` | `ResultType.bizForeignKeyCompositeMismatch` | 业务错误 | 复合外键的部分键值未填写导致不完整 |
| **11008** | `BIZ_CONSTRAINT_FOREIGN_KEY_TYPE_MISMATCH` | `ResultType.bizForeignKeyTypeMismatch` | 业务错误 | 外键两端字段的数据类型不匹配 |
| **11009** | `BIZ_CONSTRAINT_MAX_LENGTH` | `ResultType.bizValueExceedsMaxLength` | 业务错误 | 值长度超过了 Schema 约束设定的最大长度 |
| **11010** | `BIZ_CONSTRAINT_MIN_LENGTH` | `ResultType.bizValueLessThanMinLength` | 业务错误 | 值长度小于 Schema 约束设定的最小长度 |
| **11011** | `BIZ_CONSTRAINT_MIN_VALUE` | `ResultType.bizValueLessThanMinValue` | 业务错误 | 数值小于 Schema 约束设定的最小值 |
| **11012** | `BIZ_CONSTRAINT_MAX_VALUE` | `ResultType.bizValueExceedsMaxValue` | 业务错误 | 数值大于 Schema 约束设定的最大值 |
| **12002** | `BIZ_NOT_FOUND_RECORD` | `ResultType.bizRecordNotFound` | 业务错误 | 目标记录不存在 / 指定的主键值未找到 |
| **20001** | `DEV_INVALID_ARGUMENT_FORMAT` | `ResultType.devInvalidArgumentFormat` | 开发者错误 | 传参值格式错误（如非法的 key 格式） |
| **20002** | `DEV_INVALID_ARGUMENT_TYPE` | `ResultType.devInvalidArgumentType` | 开发者错误 | 参数的数据类型不匹配（期待数字传入字符串等） |
| **20003** | `DEV_INVALID_ARGUMENT_MISSING` | `ResultType.devInvalidArgumentMissing` | 开发者错误 | 必填的接口入参未传入 |
| **20005** | `DEV_INVALID_PRIMARY_KEY_FORMAT` | `ResultType.devInvalidPrimaryKeyFormat` | 开发者错误 | 主键的值格式不符合主键策略（例如自增主键传入了非法的自定义字符串） |
| **20007** | `DEV_INDEX_OUT_OF_BOUNDS` | `ResultType.devIndexOutOfBounds` | 开发者错误 | 索引或范围超限错误（如越界读写缓冲区） |
| **20008** | `DEV_UNSUPPORTED_OPERATION` | `ResultType.devUnsupportedOperation` | 开发者错误 | 当前上下文不支持的操作（不支持该平台、未实现等） |
| **20010** | `DEV_VECTOR_DIMENSION_MISMATCH` | `ResultType.devVectorDimensionMismatch` | 开发者错误 | 向量计算或比较时维度不匹配（如点积、距离计算等） |
| **20011** | `DEV_INDEX_FIELD_MISSING` | `ResultType.devIndexFieldMissing` | 开发者错误 | 从最后一包记录计算游标时，记录中缺失必要的索引字段（用于游标计算续读） |
| **20201** | `DEV_INVALID_CURSOR_PAGINATION` | `ResultType.devInvalidCursorPagination` | 开发者错误 | 分页冲突（游标分页和 Offset 分页不能同时配置） |
| **20202** | `DEV_INVALID_CURSOR_TABLE` | `ResultType.devInvalidCursorTable` | 开发者错误 | 游标包含的表与当前查询表不一致 |
| **20203** | `DEV_INVALID_CURSOR_SIGNATURE` | `ResultType.devInvalidCursorSignature` | 开发者错误 | 游标签名哈希校验失败（游标已被篡改） |
| **20204** | `DEV_INVALID_CURSOR_ORDERBY` | `ResultType.devInvalidCursorOrderBy` | 开发者错误 | 游标的 orderBy 配置不合规或与原查询不匹配 |
| **20205** | `DEV_INVALID_CURSOR_MODE` | `ResultType.devInvalidCursorMode` | 开发者错误 | 游标 Token 模式不匹配 |
| **20206** | `DEV_INVALID_CURSOR_PAYLOAD` | `ResultType.devInvalidCursorPayload` | 开发者错误 | 无法解码或反序列化的非法游标载荷 |
| **20301** | `DEV_INVALID_QUERY_SELECT_FIELD` | `ResultType.devInvalidQuerySelectField` | 开发者错误 | 查询 Select 字段非法（不是 String 或 QueryAggregation） |
| **20302** | `DEV_INVALID_QUERY_FOREIGN_KEY_JOIN` | `ResultType.devInvalidQueryForeignKeyJoin` | 开发者错误 | 自动 Join 时两表之间未定义外键关系 |
| **20303** | `DEV_INVALID_QUERY_FIELD_ALIAS` | `ResultType.devInvalidQueryFieldAlias` | 开发者错误 | 查询字段的别名命名格式不正确 |
| **20304** | `DEV_INVALID_EXPRESSION` | `ResultType.devInvalidExpression` | 开发者错误 | 表达式配置或求值执行异常（如内置函数参数不符、未知函数等） |
| **22001** | `DEV_NOT_FOUND_TABLE` | `ResultType.devTableNotFound` | 开发者错误 | 要操作的数据库表名称不存在 |
| **22003** | `DEV_NOT_FOUND_INDEX` | `ResultType.devIndexNotFound` | 开发者错误 | 指定查询引用的索引不存在 |
| **22004** | `DEV_NOT_FOUND_SPACE` | `ResultType.devSpaceNotFound` | 开发者错误 | 指定的存储空间（Space）在物理或逻辑上不存在 |
| **22005** | `DEV_NOT_FOUND_FIELD` | `ResultType.devFieldNotFound` | 开发者错误 | 传入了表中未定义的未知字段 |
| **23001** | `DEV_LARGE_SCALE_OPERATION_REQUIRED_BYPASS` | `ResultType.devLargeScaleOperationBypassRequired` | 开发者错误 | 超大规模写入/更新操作需调用 `skipResultDetails()` 开启防 OOM 旁路模式 |
| **24001** | `DEV_ENGINE_INCOMPATIBLE` | `ResultType.devEngineIncompatible` | **致命错误** | 库配置或数据文件与当前引擎版本不兼容，强制拦截抛出 |
| **30000** | `DEV_INVALID_SCHEMA` | `ResultType.devInvalidSchema` | 开发者错误 | 表的 Schema 结构定义配置不正确 |
| **30001** | `DEV_INVALID_SCHEMA_TABLE_NAME` | `ResultType.devInvalidSchemaTableName` | 开发者错误 | Schema 表名包含非法字符或超过长度限制 |
| **30002** | `DEV_INVALID_SCHEMA_FIELD_NAME` | `ResultType.devInvalidSchemaFieldName` | 开发者错误 | Schema 字段名包含非法字符 |
| **30003** | `DEV_INVALID_SCHEMA_PRIMARY_KEY` | `ResultType.devInvalidSchemaPrimaryKey` | 开发者错误 | Schema 主键配置格式非法或缺失 |
| **30004** | `DEV_INVALID_SCHEMA_INDEX_LIMIT` | `ResultType.devInvalidSchemaIndexLimit` | 开发者错误 | 该表配置的索引数超出了 16 个的系统限制 |
| **30005** | `DEV_SCHEMA_TABLE_EXISTS` | `ResultType.devSchemaTableExists` | 开发者错误 | 创建表冲突，目标表已经存在 |
| **30006** | `DEV_SCHEMA_FIELD_EXISTS` | `ResultType.devSchemaFieldExists` | 开发者错误 | 结构升级中，添加了已经存在的同名字段 |
| **30007** | `DEV_SCHEMA_INDEX_EXISTS` | `ResultType.devSchemaIndexExists` | 开发者错误 | 追加了同名的索引配置 |
| **30008** | `DEV_INVALID_SCHEMA_FOREIGN_KEY` | `ResultType.devInvalidSchemaForeignKey` | 开发者错误 | 外键定义格式非法（如自引用、字段数不对应） |
| **30009** | `DEV_INVALID_SCHEMA_SPACE_MISMATCH` | `ResultType.devInvalidSchemaSpaceMismatch` | 开发者错误 | 跨 Space 表关系校验冲突 |
| **30010** | `DEV_MIGRATION_NOT_ALLOWED_WITH_DATA` | `ResultType.devMigrationNotAllowedWithData` | **致命错误** | 结构迁移需要物理变更字段但未被显式允许（`allowPhysicalMigration=false`） |
| **30011** | `DEV_MIGRATION_UNSAFE_TYPE_CONVERSION` | `ResultType.devMigrationUnsafeTypeConversion` | **致命错误** | 物理迁移：不支持且极高风险的数据类型转换操作 |
| **30013** | `DEV_MIGRATION_CANNOT_ADD_NON_NULL_FIELD` | `ResultType.devMigrationCannotAddNonNullField` | **致命错误** | 无法对已有数据的表追加不带 default 值的非空 (NOT NULL) 字段 |
| **30014** | `DEV_MIGRATION_NULLABLE_TO_NON_NULL_NOT_ALLOWED` | `ResultType.devMigrationNullableToNonNullNotAllowed` | **致命错误** | 物理迁移：在非空表上将字段从 Null 改为 Non-Null 且无默认值 |
| **30015** | `DEV_MIGRATION_UNIQUE_TIGHTENING_NOT_ALLOWED` | `ResultType.devMigrationUniqueTighteningNotAllowed` | **致命错误** | 物理迁移：将非空表上的字段收紧为 UNIQUE，强制拦截抛出 |
| **30016** | `DEV_INVALID_SCHEMA_TTL_CONFIG` | `ResultType.devInvalidSchemaTtlConfig` | 开发者错误 | 表的 TTL（数据生存周期）配置项非法 |
| **30017** | `DEV_INVALID_SCHEMA_DUPLICATE_FIELD_NAME` | `ResultType.devInvalidSchemaDuplicateFieldName` | 开发者错误 | 字段重复配置冲突 |
| **30018** | `DEV_INVALID_SCHEMA_INDEX_FIELD` | `ResultType.devInvalidSchemaIndexField` | 开发者错误 | 索引指向了表中并不存在的字段名 |
| **50001** | `SYS_TRANSACTION_ABORTED` | `ResultType.sysTransactionAborted` | 系统错误 | 事务主动回滚或被强制中止 |
| **50002** | `SYS_TRANSACTION_CONFLICT` | `ResultType.sysTransactionConflict` | 系统错误 | 并发事务修改了同一实体导致版本冲突 |
| **50003** | `SYS_TRANSACTION_LIMIT_EXCEEDED` | `ResultType.sysTransactionLimitExceeded` | 系统错误 | 事务在内存压力下超过安全内存限制 |
| **50004** | `SYS_MIGRATION_BATCH_EXECUTION_FAILED` | `ResultType.sysMigrationBatchExecutionFailed` | 系统错误 | 批量表结构迁移物理执行失败 |
| **51001** | `SYS_TIMEOUT_LOCK_ACQUISITION` | `ResultType.sysTimeoutLockAcquisition` | 系统错误 | 事务内获取排他锁超时 |
| **51002** | `SYS_TIMEOUT` | `ResultType.sysTimeout` | 系统错误 | 查询、写入等底层操作执行超时 |
| **51003** | `SYS_DB_CLOSED` | `ResultType.sysDbClosed` | 系统错误 | 数据库已关闭，操作安全取消 |
| **52001** | `SYS_RESOURCE_EXHAUSTED_MEMORY` | `ResultType.sysResourceExhaustedMemory` | 系统错误 | 物理内存耗尽，可能面临 OOM 风险 |
| **52002** | `SYS_RESOURCE_EXHAUSTED` | `ResultType.sysResourceExhausted` | 系统错误 | 磁盘空间耗尽，无法执行落盘写入 |
| **53001** | `SYS_IO_NOT_FOUND` | `ResultType.sysIoNotFound` | 系统错误 | 物理文件或目录路径不存在 |
| **53002** | `SYS_IO_PERMISSION_DENIED` | `ResultType.sysIoPermissionDenied` | 系统错误 | 物理文件读写权限不足/拒绝访问 |
| **53003** | `SYS_IO_DISK_FULL` | `ResultType.sysIoDiskFull` | 系统错误 | 磁盘空间不足或写数据超过配额限额 |
| **53004** | `SYS_IO_FILE_LOCKED` | `ResultType.sysIoFileLocked` | 系统错误 | 物理文件已被其它进程占用/共享冲突/锁定 |
| **53005** | `SYS_IO_DEVICE_FAULT` | `ResultType.sysIoDeviceFault` | 系统错误 | 存储设备或介质硬件故障 |
| **53006** | `SYS_IO_WEB_STORAGE_UNAVAILABLE` | `ResultType.sysIoWebStorageUnavailable` | 系统错误 | Web 端 IndexedDB 满额、被禁用或初始化失败 |
| **53007** | `SYS_BACKUP_CORRUPTED` | `ResultType.sysBackupCorrupted` | 系统错误 | 备份包已损坏或缺少清单文件 |
| **53008** | `SYS_IO_DATA_CORRUPTED` | `ResultType.sysIoDataCorrupted` | 系统错误 | 数据库数据文件损坏或 CRC 校验失败 |
| **53009** | `SYS_INVALID_DATA_FORMAT` | `ResultType.sysInvalidDataFormat` | 系统错误 | 数据流格式或编解码失败（数据反序列化非法） |
| **53099** | `SYS_IO_GENERIC` | `ResultType.sysIoGeneric` | 系统错误 | 物理文件系统底层遭遇其他硬件或物理 I/O 错误 |
| **99001** | `ENG_ERROR` | `ResultType.engError` | 引擎错误 | 数据库底层引擎发生代码崩溃、未知内部异常或运行时逻辑缺陷 |
