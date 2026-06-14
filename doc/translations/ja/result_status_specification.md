# ToStore ResultStatus 自動診断・状態解析仕様書

自動化された運用（Ops）、AIエージェント、自動テストスクリプト、およびクライアントアプリケーションが、データベースのさまざまな実行結果や例外状態を正確に識別できるように、ToStoreは最新バージョンで構造化された`ResultStatus`体系を導入しました。

この仕様書では、データベースユーザーや開発者が独自に状態解析を実装できるように、状態コードの設計原則、セマンティック識別子キーの仕様、および各種状態タイプの専用フィールド構造について詳しく説明します。

---

## 1. コア設計原則

### 1.1 状態コード（code）数値仕様

すべての数値状態コード（`code`）は、固定長5桁の数字で定義されています（成功状態を除く）：

- **成功状態（Special Success Code）**: 特別に`0`に固定されています。
- **その他の状態（Error & Diagnostic Codes）**: 5桁の数字に統一されています。
- **クラスコード（大分類コード）**: 状態コードの最初の2桁。大まかなエラーカテゴリを素早く特定するために使用されます。
- **リーフコード（詳細コード）**: 状態コードの後半の3桁。具体的なエラーシナリオを表します。

> [!TIP]
> 自動化運用、AIエージェント、または外部テストスクリプトを開発する場合、開発者は最初の2桁（クラスコード）または範囲を使用して、ロジック内で対応する例外ハンドラーに素早くルーティングし、その後、リーフコードに基づいて詳細な処理を行うことができます。

> [!IMPORTANT]
> **メモリ内判定のベストプラクティス (In-Memory Check)**:
> クライアントまたはDart/Flutterコードなどのメモリ内でデータベース操作結果を読み取る場合、**最も推奨される効率的な方法は、`ResultStatus`または`ResultType`の組み込み読み取り専用プロパティ（`isBusinessError`や`isCriticalError`など。詳細は[第3.2節](#32-メモリ内判定用の便利なゲッター-in-memory-helper-getters)を参照）を直接使用すること**です。これにより、数値範囲の手動解析や文字列プレフィックスのマッチングを回避できます。

### 1.2 セマンティック状態識別子（codeKey）仕様

各ステータスは、一意の文字列識別子`codeKey`に対応しています：

- **命名形式**: `[大分類プレフィックス]_[マルチレベル詳細識別子]`。
- **命名規則**: 英大文字とアンダースコア`_`で構成され、スペースや特殊文字は含まれません。
- **大分類プレフィックス**: その状態が属するコアビジネス大分類を示します。複数の分類レベルが存在する場合、プレフィックスの検索や範囲フィルタリングを容易にするため、最も一般的なプレフィックスが先頭に配置されます。

---

## 2. クラスコード（大分類コード）クイック参照表

以下は、ToStoreにおけるすべてのクラスコードのマッピング定義です：

| コード範囲 | クラスコード（最初の2桁） | セマンティックプレフィックス | カテゴリ | 例外スロー戦略 |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `00` | `SUCCESS` | **操作成功** | 例外をスローせず、正常に返します。 |
| `10000 - 19999` | `10 - 19` | `BIZ_` | **ビジネスエラー**（エンドユーザーの入力エラー、制約違反など） | 例外をスローせず、常に`DbResult`または`QueryResult`を介して返されます。 |
| `20000 - 49999` | `20 - 49` | `DEV_` | **開発者エラー**（無効なAPIパラメータ、無効なテーブルスキーマ構成など） | **デバッグ環境では`DbException`を直接スロー**して開発者に警告します。**本番環境では結果として正常に返されます**。*(注意: エンジンバージョンの不整合および重大な移行バッチ実行の失敗は重大なエラーであり、本番環境でも強制的に例外をスローします)* |
| `50000 - 79999` | `50 - 79` | `SYS_` | **システムエラー**（ディスク容量不足、IO例外、ロック取得タイムアウトなど） | 正常な実行が妨げられた場合に例外をスローします。その他（トランザクション競合など）は結果として返されます。 |
| `99000 - 99999` | `99` | `ENG_` | **エンジンエラー**（エンジンロジックエラー、データファイル破損、不明な内部エラー） | 通常は例外をスローしません。深刻なケースでのみ例外をスローします。 |

---

## 3. ResultStatus 共通フィールド構造とメモリ内判定ヘルパー

### 3.1 共通フィールド（シリアライズされた JSON 構造）

すべてのタイプの`ResultStatus`は、JSONにシリアライズされると、次の4つの基本的な共通フィールドを含みます。ユーザーはこれらのフィールドを直接読み取って予備的なチェックを行うことができます。

| フィールド | タイプ | 説明 |
| :--- | :--- | :--- |
| `index` | `int` | バッチ操作におけるシーケンスインデックス。単一操作の場合、これは`0`に固定されます。 |
| `code` | `int` | 数値ステータスコード（成功時は`0`、例外時は5桁の数字）。 |
| `codeKey` | `String` | セマンティック状態識別子キー（例: `CONSTRAINT_VIOLATION_UNIQUE`）。 |
| `message` | `String` | 人間が読めるステータス詳細の説明。 |

### 3.2 メモリ内判定用の便利なゲッター (In-Memory Helper Getters)

Dart/Flutterでは、`ResultStatus`と`ResultType`は、手動の範囲チェックや文字列マッチングを行うことなく、メモリ内でカテゴリと重大度をチェックするための非常に効率的な`O(1)`読み取り専用プロパティ（ゲッター）をカプセル化しています：

| プロパティ | タイプ | 説明 |
| :--- | :--- | :--- |
| `isBusinessError` | `bool` | **ビジネスエラー**であるかどうか（制約違反、キャスト失敗など。範囲: `10000 - 19999`）。 |
| `isDeveloperError` | `bool` | **開発者エラー**であるかどうか（無効なスキーマ、パラメータ不一致、テーブル未検出など。範囲: `20000 - 49999`）。 |
| `isSystemError` | `bool` | **システムエラー**であるかどうか（ロックタイムアウト、ディスクフル、ファイルロックなど。範囲: `50000 - 79999`）。 |
| `isEngineError` | `bool` | **エンジンエラー**であるかどうか（範囲: `99000 - 99999`）。 |
| `isCriticalError` | `bool` | **重大なエラー/災害レベルのイベント**であるかどうか（ディスクフル、メモリ不足、深刻なデータファイル破損、互換性のない移行の失敗など、手動または運用上の介入が必要な場合）。 |

---

## 4. 詳細な解析構造と専用フィールドの説明

`code` / `codeKey` の範囲と`ResultStatus`の具体的なサブクラスに応じて、シリアライズされたJSON構造は異なる**専用の診断フィールド**を持ちます。以下に、5つのステータスサブクラスのフィールド仕様とアプリケーションマッピングを示します。

### 4.1 SuccessStatus（操作成功状態）

- **カテゴリ範囲**: `code == 0`、`codeKey == "SUCCESS"`
- **適用シナリオ**: レコードの挿入、変更、または削除が完全に成功した場合。
- **専用フィールド定義**:

  | フィールド | タイプ | 詳細 |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **オプション**。単一のレコード書き込み（`insert`など）または更新（`update`など）が成功した場合にのみ返され、物理的に生成または変更されたレコードの主キー値を表します。 |

- **JSON 物理表現例**:
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

### 4.2 ConstraintStatus（データ整合性と制約衝突状態）

- **カテゴリ範囲**: `code`が`[10000, 19999]`の範囲（主にデータ検証および整合性制約の競合）。
- **専用フィールド定義**:

  | フィールド | タイプ | 詳細 |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **必須**。整合性制約の競合または未検出エラーが発生した具体的なテーブル名。 |
  | `constraintName` | `String?` | **オプション**。エラーを引き起こした具体的な制約名（外キー競合の場合は`fk_users_profile`、一意性制約の場合はインデックス名、NOT NULLやキャストエラーなどの名前のない制約の場合は`null`）。 |
  | `fields` | `List<String>` | **必須**。競合の原因となったフィールドのリスト。 |
  | `conflictingKeys` | `List<dynamic>` | **必須**。競合を引き起こした具体的な入力値のリスト。`fields`リストと1対1で対応します。フィールドがnullの場合、リストの対応する項目は`null`になります。 |
  | `primaryKey` | `String?` | **オプション**。関連付けられたレコードの物理主キー。単一レコードの操作でない場合、またはメモリ段階でブロックされた場合は`null`になります。 |
  | `referencedTable` | `String?` | **オプション**。外キー制約競合（親レコード未存在、子レコード制限など）の親テーブル名。 |

- **リーフコードのガイドライン**:

  | コードとメモリ内タイプ | シナリオ | フィールドガイドライン |
  | :--- | :--- | :--- |
  | `10000`<br>`bizValidationFailed` | データ形式または範囲検証の失敗 | <ul><li>`tableName`: 対象テーブル</li><li>`constraintName`: `null`</li><li>`fields`: 検証に違反したフィールド、例 `["email"]`</li><li>`conflictingKeys`: 失敗の原因となった無効な値、例 `["invalid-email"]`</li><li>`primaryKey`: レコードの主キー（存在する場合）</li></ul> |
  | `10001`<br>`bizNotNullViolation` | NOT NULL制約違反 | <ul><li>`tableName`: 対象テーブル</li><li>`constraintName`: `null`</li><li>`fields`: 制約に違反したフィールド、例 `["email"]`</li><li>`conflictingKeys`: 常に `[null]`</li><li>`primaryKey`: レコードの主キー（存在する場合）</li></ul> |
  | `10002`<br>`bizTypeCastFailed` | データ型の変換またはキャストの失敗 | <ul><li>`tableName`: 対象テーブル</li><li>`constraintName`: `null`</li><li>`fields`: キャストに失敗したフィールド、例 `["age"]`</li><li>`conflictingKeys`: 失敗の原因となった無効な値、例 `["not_a_number"]`</li><li>`primaryKey`: レコードの主キー（存在する場合）</li></ul> |
  | `11001`<br>`bizPrimaryKeyViolation` | 主キー競合（すでに存在します） | <ul><li>`tableName`: 対象テーブル</li><li>`constraintName`: `"PRIMARY"` または制約名</li><li>`fields`: 主キーフィールド、例 `["id"]`</li><li>`conflictingKeys`: 重複した値、例 `["usr_101"]`</li><li>`primaryKey`: 競合する値、例 `"usr_101"`</li></ul> |
  | `11002`<br>`bizUniqueViolation` | 一意制約違反 | <ul><li>`tableName`: 対象テーブル</li><li>`constraintName`: 一意インデックス名、例 `"uk_email"`</li><li>`fields`: 一意性を構成するフィールド、例 `["email"]`</li><li>`conflictingKeys`: 競合を引き起こす値、例 `["test@a.com"]`</li><li>`primaryKey`: 競合するレコードの主キー（存在する場合）</li></ul> |
  | `11003`<br>`bizForeignKeyViolation` | 外キー制約違反（汎用） | <ul><li>`tableName`: 子テーブル</li><li>`constraintName`: 外キー制約名</li><li>`fields`: 外キー列</li><li>`conflictingKeys`: 競合を引き起こす入力値</li><li>`primaryKey`: レコードの主キー（存在する場合）</li><li>`referencedTable`: 親テーブル</li></ul> |
  | `11004`<br>`bizCheckViolation` | CHECK制約違反 | <ul><li>`tableName`: 対象テーブル</li><li>`constraintName`: CHECK制約名</li><li>`fields`: チェックされたフィールド</li><li>`conflictingKeys`: CHECKに違反する値</li><li>`primaryKey`: レコードの主キー（存在する場合）</li></ul> |
  | `11005`<br>`bizForeignKeyParentNotExist` | 参照された親キーが存在しません | <ul><li>`tableName`: 子テーブル</li><li>`constraintName`: 外キー制約名</li><li>`fields`: 外キー列、例 `["userId"]`</li><li>`conflictingKeys`: 存在しない参照値、例 `["non_parent"]`</li><li>`primaryKey`: レコードの主キー（存在する場合）</li><li>`referencedTable`: 親テーブル</li></ul> |
  | `11006`<br>`bizForeignKeyChildRestrict` | 子レコードによって削除/更新が制限されています | <ul><li>`tableName`: 親テーブル</li><li>`constraintName`: 外キー制約名</li><li>`fields`: 親テーブルの参照列</li><li>`conflictingKeys`: 子テーブルから参照されている親テーブルのキー値</li><li>`primaryKey`: 親キー値</li><li>`referencedTable`: 子テーブル</li></ul> |
  | `11007`<br>`bizForeignKeyCompositeMismatch` | 複合外キーの値が不完全です | <ul><li>`tableName`: 子テーブル</li><li>`constraintName`: 外キー制約名</li><li>`fields`: 複合外キー列</li><li>`conflictingKeys`: 入力値（部分的なnullを含む）</li><li>`primaryKey`: レコードの主キー（存在する場合）</li><li>`referencedTable`: 親テーブル</li></ul> |
  | `11008`<br>`bizForeignKeyTypeMismatch` | 外キーの型が一致しません | <ul><li>`tableName`: 子テーブル</li><li>`constraintName`: 外キー制約名</li><li>`fields`: 外キー列</li><li>`conflictingKeys`: キャストに失敗した値</li><li>`primaryKey`: レコードの主キー（存在する場合）</li><li>`referencedTable`: 親テーブル</li></ul> |
  | `11009`<br>`bizValueExceedsMaxLength` | 値の長さがスキーマ制限を超えています | <ul><li>`tableName`: 対象テーブル</li><li>`constraintName`: `null`</li><li>`fields`: 制約に違反したフィールド、例 `["name"]`</li><li>`conflictingKeys`: 制限を超えた値、例 `["a" * 1000]`</li><li>`primaryKey`: レコードの主キー（存在する場合）</li></ul> |
  | `11010`<br>`bizValueLessThanMinLength` | 値の長さがスキーマ制限未満です | <ul><li>`tableName`: 対象テーブル</li><li>`constraintName`: `null`</li><li>`fields`: 制約に違反したフィールド、例 `["code"]`</li><li>`conflictingKeys`: 最小値より短い値、例 `["ab"]`</li><li>`primaryKey`: レコードの主キー（存在する場合）</li></ul> |
  | `11011`<br>`bizValueLessThanMinValue` | 数値がスキーマ制限未満です | <ul><li>`tableName`: 対象テーブル</li><li>`constraintName`: `null`</li><li>`fields`: 制約に違反したフィールド、例 `["age"]`</li><li>`conflictingKeys`: 最小値未満の値、例 `[-5]`</li><li>`primaryKey`: レコードの主キー（存在する場合）</li></ul> |
  | `11012`<br>`bizValueExceedsMaxValue` | 数値がスキーマ制限を超えています | <ul><li>`tableName`: 対象テーブル</li><li>`constraintName`: `null`</li><li>`fields`: 制約に違反したフィールド、例 `["score"]`</li><li>`conflictingKeys`: 最大値を超える値、例 `[105]`</li><li>`primaryKey`: レコードの主キー（存在する場合）</li></ul> |
  | `12002`<br>`bizRecordNotFound` | リソースが存在しない / レコード未検出 | <ul><li>`tableName`: 対象テーブル</li><li>`constraintName`: `null`</li><li>`fields`: 検索対象フィールド、例 `["id"]`</li><li>`conflictingKeys`: 検出されなかったターゲットキー、例 `["non_exist_id"]`</li><li>`primaryKey`: 不足しているキーの値、例 `"non_exist_id"`</li></ul> |

- **JSON 物理表現例**（外キーの親レコードが存在しないエラー）:
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

### 4.3 SchemaValidationStatus（テーブルスキーマ検証および不互換移行状態）

- **カテゴリ範囲**: `code`が`[30000, 39999]`の範囲（スキーマ構成検証エラーおよび物理的移行不整合）。
- **専用フィールド定義**:

  | フィールド | タイプ | 詳細 |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **必須**。検証または物理的移行が行われているテーブル名。 |
  | `field` | `String?` | **オプション**。スキーマまたは移行エラーを引き起こした具体的なフィールド名。 |
  | `wrongValue` | `dynamic` | **オプション**。競合の原因となった無効な設定値または移行の差分構成。 |

- **リーフコードのガイドライン**:

  | コードとメモリ内タイプ | シナリオ | フィールドガイドライン |
  | :--- | :--- | :--- |
  | `30000`<br>`devInvalidSchema` | 無効なテーブルスキーマ定義 | <ul><li>`tableName`: テーブル名</li><li>`field`: `null`</li><li>`wrongValue`: 無効な設定マップ、または `null`</li></ul> |
  | `30001`<br>`devInvalidSchemaTableName` | テーブル名検証エラー（無効な文字または長すぎ） | <ul><li>`tableName`: 違反している名前</li><li>`field`: `null`</li><li>`wrongValue`: 違反している文字列</li></ul> |
  | `30002`<br>`devInvalidSchemaFieldName` | フィールド名検証エラー（無効な文字） | <ul><li>`tableName`: テーブル名</li><li>`field`: 違反しているフィールド名</li><li>`wrongValue`: 違反している文字列</li></ul> |
  | `30003`<br>`devInvalidSchemaPrimaryKey` | 主キー検証エラー（欠落または無効な形式） | <ul><li>`tableName`: テーブル名</li><li>`field`: `"primaryKey"` または主キーフィールド名</li><li>`wrongValue`: 主キーの設定詳細</li></ul> |
  | `30004`<br>`devInvalidSchemaIndexLimit` | テーブルのインデックス数がシステム制限（16個）を超過 | <ul><li>`tableName`: テーブル名</li><li>`field`: `null`</li><li>`wrongValue`: インデックス設定リスト</li></ul> |
  | `30005`<br>`devSchemaTableExists` | テーブルは既に存在します | <ul><li>`tableName`: テーブル名</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30006`<br>`devSchemaFieldExists` | スキーマアップグレード: 既に存在するフィールドを追加しようとしました | <ul><li>`tableName`: テーブル名</li><li>`field`: 競合するフィールド名</li><li>`wrongValue`: `null`</li></ul> |
  | `30007`<br>`devSchemaIndexExists` | スキーマアップグレード: 既に存在するインデックスを追加しようとしました | <ul><li>`tableName`: テーブル名</li><li>`field`: インデックス名</li><li>`wrongValue`: `null`</li></ul> |
  | `30008`<br>`devInvalidSchemaForeignKey` | 外キー定義が無効（列の不一致など） | <ul><li>`tableName`: テーブル名</li><li>`field`: 外キー名</li><li>`wrongValue`: 外キーの設定詳細</li></ul> |
  | `30009`<br>`devInvalidSchemaSpaceMismatch` | グローバル/スペース固有の境界の不一致 | <ul><li>`tableName`: テーブル名</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30010`<br>`devMigrationNotAllowedWithData` | 移行にはデータ変更が必要ですが、明示的に許可されていません | <ul><li>`tableName`: テーブル名</li><li>`field`: `null`</li><li>`wrongValue`: 移行アップグレードの差分マップ</li></ul> |
  | `30011`<br>`devMigrationUnsafeTypeConversion` | 物理移行: フィールドのサポートされていない型変換 | <ul><li>`tableName`: テーブル名</li><li>`field`: フィールド名</li><li>`wrongValue`: 競合する型のマップ、例 `{ "from": "text", "to": "integer" }`</li></ul> |
  | `30013`<br>`devMigrationCannotAddNonNullField` | データがあるテーブルにデフォルト値なしで非NULLフィールドを追加できません | <ul><li>`tableName`: テーブル名</li><li>`field`: 違反しているフィールド名</li><li>`wrongValue`: 移行パラメータ、例 `{ "nullable": false, "defaultValue": null }`</li></ul> |
  | `30014`<br>`devMigrationNullableToNonNullNotAllowed` | 物理移行: フィールドをNULL許容から非NULLに変更 | <ul><li>`tableName`: テーブル名</li><li>`field`: フィールド名</li><li>`wrongValue`: 移行パラメータ（30013と同様）</li></ul> |
  | `30015`<br>`devMigrationUniqueTighteningNotAllowed` | 物理移行: フィールド制約をUNIQUEに引き締め | <ul><li>`tableName`: テーブル名</li><li>`field`: フィールド名</li><li>`wrongValue`: 一意性制約を引き起こすインデックス定義</li></ul> |
  | `30016`<br>`devInvalidSchemaTtlConfig` | TTL構成の検証に失敗しました | <ul><li>`tableName`: テーブル名</li><li>`field`: TTLタイムスタンプフィールド</li><li>`wrongValue`: 無効なTTL設定マップ、例 `{ "enabled": true, "fieldName": "expire_at" }`</li></ul> |
  | `30017`<br>`devInvalidSchemaDuplicateFieldName` | テーブルスキーマ内の重複するフィールド名 | <ul><li>`tableName`: テーブル名</li><li>`field`: 重複するフィールド名</li><li>`wrongValue`: `null`</li></ul> |
  | `30018`<br>`devInvalidSchemaIndexField` | インデックスが存在しないフィールドを参照しています | <ul><li>`tableName`: テーブル名</li><li>`field`: インデックス名</li><li>`wrongValue`: 不一致を引き起こすフィールド名</li></ul> |

- **JSON 物理表現例**（データのあるテーブルにデフォルト値なしで非NULLフィールドを追加するエラー）:
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

### 4.4 InvalidArgumentStatus（API 引数およびカーソルページング検証例外）

- **カテゴリ範囲**: `code`が`[20000, 20999]`の範囲（APIパラメータ、クエリ構造、またはページングトークンの検証エラー）。
- **専用フィールド定義**:

  | フィールド | タイプ | 詳細 |
  | :--- | :--- | :--- |
  | `parameterName` | `String` | **必須**。検証エラーを引き起こしたパラメータ名（例: `"cursor"`、`"orderBy"`、または特定の列キー）。 |
  | `passedValue` | `dynamic` | **オプション**。呼び出し元から渡された無効な値。複雑なオブジェクトは文字列に変換されます。 |
  | `primaryKey` | `String?` | **オプション**。関連付けられたレコードの物理主キー。 |

- **リーフコードのガイドライン**:

  | コードとメモリ内タイプ | シナリオ | フィールドガイドライン |
  | :--- | :--- | :--- |
  | `20001`<br>`devInvalidArgumentFormat` | 引数の形式エラー | <ul><li>`parameterName`: 無効なパラメータ名</li><li>`passedValue`: 渡された値、例 `"twenty"`</li><li>`primaryKey`: レコードの主キー（存在する場合）</li></ul> |
  | `20002`<br>`devInvalidArgumentType` | 引数の型不一致 | <ul><li>`parameterName`: パラメータ名</li><li>`passedValue`: 渡された値、例 `{"foo": "bar"}` (Stringが期待された場合)</li><li>`primaryKey`: レコードの主キー（存在する場合）</li></ul> |
  | `20003`<br>`devInvalidArgumentMissing` | 必須引数が欠落しています | <ul><li>`parameterName`: 欠落しているパラメータ名、例 `"dbPath"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: レコードの主キー（存在する場合）</li></ul> |
  | `20005`<br>`devInvalidPrimaryKeyFormat` | 無効な主キー形式 | <ul><li>`parameterName`: `"primaryKey"` または主キーフィールド</li><li>`passedValue`: 無効な主キー値、例 `"invalid_id_value"`</li><li>`primaryKey`: 無効な主キー値</li></ul> |
  | `20010`<br>`devVectorDimensionMismatch` | ベクトルの次元不一致 | <ul><li>`parameterName`: `"other"`</li><li>`passedValue`: 違反している次元サイズ</li><li>`primaryKey`: `null`</li></ul> |
  | `20011`<br>`devIndexFieldMissing` | カーソル用レコードで必要なインデックスフィールドが欠落 | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: 欠落しているインデックスフィールド</li><li>`primaryKey`: `null`</li></ul> |
  | `20201`<br>`devInvalidCursorPagination` | カーソルページングとオフセットは相互に排他的です | <ul><li>`parameterName`: `"cursor"` / `"offset"`</li><li>`passedValue`: 競合するページングパラメータ</li><li>`primaryKey`: `null`</li></ul> |
  | `20202`<br>`devInvalidCursorTable` | カーソルがターゲットテーブルと一致しません | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: カーソルトークン</li><li>`primaryKey`: `null`</li></ul> |
  | `20203`<br>`devInvalidCursorSignature` | カーソルの署名不一致（改ざん） | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: カーソルトーク</li><li>`primaryKey`: `null`</li></ul> |
  | `20204`<br>`devInvalidCursorOrderBy` | カーソルのorderBy構成が無効または不一致 | <ul><li>`parameterName`: `"orderBy"`</li><li>`passedValue`: orderByリスト、例 `["-age", "id"]`</li><li>`primaryKey`: `null`</li></ul> |
  | `20205`<br>`devInvalidCursorMode` | カーソルトークンモードの不一致 | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: トークンモード、例 `"sortKey"`</li><li>`primaryKey`: `null`</li></ul> |
  | `20206`<br>`devInvalidCursorPayload` | 無効なカーソルペイロード（デコード不可） | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: `null`</li></ul> |
  | `20301`<br>`devInvalidQuerySelectField` | クエリ選択フィールドはStringまたはQueryAggregationである必要があります | <ul><li>`parameterName`: `"select"`</li><li>`passedValue`: 無効な選択フィールド定義</li><li>`primaryKey`: `null`</li></ul> |
  | `20302`<br>`devInvalidQueryForeignKeyJoin` | 自動結合用の外キー関係が存在しません | <ul><li>`parameterName`: `"join"` / `"tableName"`</li><li>`passedValue`: 関係を欠くターゲットテーブル</li><li>`primaryKey`: `null`</li></ul> |
  | `20303`<br>`devInvalidQueryFieldAlias` | クエリフィールドのエイリアス形式が無効です | <ul><li>`parameterName`: `"alias"`</li><li>`passedValue`: 無効なエイリアス文字列</li><li>`primaryKey`: `null`</li></ul> |
  | `20304`<br>`devInvalidExpression` | 無効な式構成または実行例外 | <ul><li>`parameterName`: エラーの側面（例: `"arguments"`、`"functionName"`、`"node"`）</li><li>`passedValue`: 無効な値またはカウント</li><li>`primaryKey`: `null`</li></ul> |
  | `22005`<br>`devFieldNotFound` | フィールドが見つかりません | <ul><li>`parameterName`: 未知のフィールド名、例 `"extra"`</li><li>`passedValue`: 渡されたフィールドの値</li><li>`primaryKey`: レコードの主キー（存在する場合）</li></ul> |

- **JSON 物理表現例**（カーソルのソート順がクエリのソート順と競合するエラー）:
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

### 4.5 TransactionOperationStatus（トランザクション競合およびアボート）

- **カテゴリ範囲**: `code`が`[50000, 50999]`の範囲（トランザクションのロールバック、明示的なアボート、またはシリアライザビリティ競合）。
- **専用フィールド定義**:

  | フィールド | タイプ | 詳細 |
  | :--- | :--- | :--- |
  | `txId` | `String` | **必須**。トランザクションの有効期間を追跡するために使用される、グローバルに一意なトランザクションストリーム識別子ID。 |

- **リーフコードのガイドライン**:

  | コードとメモリ内タイプ | シナリオ | フィールドガイドライン |
  | :--- | :--- | :--- |
  | `50001`<br>`sysTransactionAborted` | トランザクションアボート（明示的ロールバックまたはカスケード失敗） | <ul><li>`txId`: アクティブなトランザクションID</li></ul> |
  | `50002`<br>`sysTransactionConflict` | トランザクション競合（SSI/WALにおける同キーへの同時更新） | <ul><li>`txId`: 競合するトランザクションID</li></ul> |

- **JSON 物理表現例**（SSI 同時書き込み競合）:
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

### 4.6 GeneralStatus（一般およびシステムレベルの例外状態）

- **カテゴリ範囲**: 他のすべてのステータスコードのフォールバック（低レベルIO、ハードウェアエラー、システムタイムアウトなど）。
- **専用フィールド定義**:

  | フィールド | タイプ | 詳細 |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **オプション**。関連付けられたレコードの物理主キー。 |
  | `target` | `String?` | **オプション**。ターゲットの物理リソース（物理ファイルパス、ロック名、URLリソースなど）。 |
  | `operation` | `String?` | **オプション**。アクティブなシステムコール名（`'readAsString'`、`'delete'`、`'acquire'`など）。 |

- **リーフコードのガイドライン**:

  | コードとメモリ内タイプ | シナリオ / レベル | フィールドガイドライン |
  | :--- | :--- | :--- |
  | `20007`<br>`devIndexOutOfBounds` | インデックスまたは範囲が境界外（開発者エラー） | <ul><li>`primaryKey`: `null`</li></ul> |
  | `20008`<br>`devUnsupportedOperation` | 現在のコンテキストでは操作がサポートされていません（開発者エラー） | <ul><li>`primaryKey`: `null`</li><li>`target`: ターゲットテーブル/リソース（存在する場合）</li><li>`operation`: メソッド名（存在する場合）</li></ul> |
  | `22001`<br>`devTableNotFound` | テーブルが見つかりません（開発者エラー） | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22003`<br>`devIndexNotFound` | インデックスが見つかりません（開発者エラー） | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22004`<br>`devSpaceNotFound` | スペースが見つかりません（開発者エラー） | <ul><li>`primaryKey`: `null`</li></ul> |
  | `23001`<br>`devLargeScaleOperationBypassRequired` | OOM防止のため結果詳細のスキップが必要（開発者エラー） | <ul><li>`primaryKey`: `null`</li></ul> |
  | `24001`<br>`devEngineIncompatible` | **重大**: エンジンバージョン不整合（開発者エラー） | <ul><li>`primaryKey`: `null`</li></ul> |
  | `50003`<br>`sysMigrationBatchExecutionFailed` | 重大な移行バッチ実行の失敗（システムエラー） | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51001`<br>`sysTimeoutLockAcquisition` | ロック取得タイムアウト（システムエラー） | <ul><li>`primaryKey`: ターゲットキー（存在する場合）</li><li>`target`: ロックリソースID</li><li>`operation`: `"acquire"`</li></ul> |
  | `51002`<br>`sysTimeout` | 操作タイムアウト（システムエラー） | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51003`<br>`sysCancellation` | 操作がキャンセルされました（システムエラー） | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52001`<br>`sysResourceExhaustedMemory` | 重大なメモリリソース枯渇（システムエラー） | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52002`<br>`sysResourceExhausted` | 重大なシステムリソース枯渇（例: ディスクフル）（システムエラー） | <ul><li>`primaryKey`: `null`</li></ul> |
  | `53001`<br>`sysIoNotFound` | 物理ファイルまたはパスが存在しません（システムエラー） | <ul><li>`primaryKey`: `null`</li><li>`target`: ファイルまたはフォルダパス</li><li>`operation`: I/O操作名</li></ul> |
  | `53002`<br>`sysIoPermissionDenied` | ファイルアクセス権限がありません（システムエラー） | <ul><li>`primaryKey`: `null`</li><li>`target`: ファイルパス</li><li>`operation`: I/O操作名</li></ul> |
  | `53003`<br>`sysIoDiskFull` | 重大なディスク容量不足またはクォータ超過（システムエラー） | <ul><li>`primaryKey`: `null`</li><li>`target`: ファイルパス</li><li>`operation`: I/O操作名</li></ul> |
  | `53004`<br>`sysIoFileLocked` | ファイルが別のプロセスによってロック中（システムエラー） | <ul><li>`primaryKey`: `null`</li><li>`target`: ファイルパス</li><li>`operation`: I/O操作名</li></ul> |
  | `53005`<br>`sysIoDeviceFault` | 重大なストレージデバイスまたはメディア障害（システムエラー） | <ul><li>`primaryKey`: `null`</li><li>`target`: ファイルパス</li><li>`operation`: I/O操作名</li></ul> |
  | `53006`<br>`sysIoWebStorageUnavailable` | Web IndexedDB またはストレージが利用不可（システムエラー） | <ul><li>`primaryKey`: `null`</li><li>`target`: IndexedDBリソース</li><li>`operation`: I/O操作名</li></ul> |
  | `53007`<br>`sysBackupCorrupted` | バックアップパッケージの破損またはメタデータ欠落（システムエラー） | <ul><li>`primaryKey`: `null`</li><li>`target`: バックアップパス</li><li>`operation`: バックアップ処理</li></ul> |
  | `53008`<br>`sysIoDataCorrupted` | 重大なデータファイル破損またはチェックサム失敗（システムエラー） | <ul><li>`primaryKey`: `null`</li><li>`target`: データファイルパス</li><li>`operation`: I/O操作名</li></ul> |
  | `53009`<br>`sysInvalidDataFormat` | データストリームのフォーマットまたは解析失敗（システムエラー） | <ul><li>`primaryKey`: `null`</li><li>`target`: データストリームキー</li><li>`operation`: `"decode"` / `"deserialize"`</li></ul> |
  | `53099`<br>`sysIoGeneric` | 一般的なシステムIOエラー（システムエラー） | <ul><li>`primaryKey`: `null`</li><li>`target`: ファイルパス</li><li>`operation`: I/O操作名</li></ul> |
  | `99001`<br>`engError` | エンジンエラー（エンジンエラー） | <ul><li>`primaryKey`: `null`</li></ul> |

- **JSON 物理表現例**（テーブル未検出エラー）:
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

## 5. データベースユーザーによる解析と例外処理の推奨事項（Dart/Flutterの例）

ToStoreでは、すべてのコアデータ操作（挿入、更新、削除）は`DbResult`を返します。クエリは`QueryResult`を返し、トランザクション操作は`TransactionResult`を返します。構造的な構成ミスは`DbException`をスローします。

以下は、開発者アプリケーションがデータベースステータスをどのように処理、解析し、適切に例外処理を行うかを示すコード例です：

### 5.1 書き込み操作応答の処理（`DbResult`）

```dart
import 'package:tostore/tostore.dart';

void handleDatabaseWriteResult(DbResult result) {
  // 1. 書き込みがエラーなしで完了したかどうかを即座に確認
  if (!result.hasErrors) {
    print("すべての書き込み操作に成功しました。影響件数: ${result.successCount}");

    // 単一レコードの書き込みの場合、statusesをループせずに直接キーを取得
    if (result.firstPrimaryKey != null) {
      print("最初の成功レコードの主キー: ${result.firstPrimaryKey}");
    }
  } else {
    print("🛑 エラーが検出されました。成功: ${result.successCount}, 失敗: ${result.failedCount}");
    print("最初のエラー: ${result.firstType.codeKey} (${result.firstType.code})");

    // 2. statusesを反復処理（インデックスは入力バッチ配列と1:1で一致）
    for (final status in result.statuses) {
      final int idx = status.index;

      // 3. サブクラスをパターンマッチングして処理ロジックをルーティング
      if (status is SuccessStatus) {
        print("インデックス [$idx] 成功。主キー: ${status.primaryKey}");
      } 
      else if (status is ConstraintStatus) {
        // 制約違反（主キー、一意、チェック、外キーなど）の処理
        print("インデックス [$idx] 制約違反! テーブル: ${status.tableName}, 列: ${status.fields}");
        print("競合する値: ${status.conflictingKeys}, 主キー: ${status.primaryKey}");
        print("エラーメッセージ: ${status.message}");
      } 
      else if (status is InvalidArgumentStatus) {
        // パラメータエラーの処理
        print("インデックス [$idx] 無効なパラメータ! パラメータ名: ${status.parameterName}, 渡された値: ${status.passedValue}");
      } 
      else if (status is GeneralStatus) {
        // ロックタイムアウト、ディスクフル、システムI/O問題などの処理
        print("インデックス [$idx] 一般的な例外! コード: ${status.code} (${status.codeKey})");
        print("メッセージ: ${status.message}");
      }
    }
  }
}
```

### 5.2 テーブルスキーマと操作例外のキャッチ（`DbException`）

テーブル作成（`createTable`）やスキーマ変更（`updateSchema`）において、またはスキーマ定義がコードレベルのチェックに失敗した場合、ToStoreは本番環境で`DbException`をスローします：

```dart
try {
  // スキーマ更新を伴うデータベースのオープン
  await ToStore.open(schemas: [..]);
} on DbException catch (e) {
  print("❌ 致命的なデータベース例外! 集約されたエラー: \n${e.message}");
  
  // 例外内の個々のステータスを反復処理
  for (final status in e.statuses) {
    if (status is SchemaValidationStatus) {
      // スキーマバリデータの問題
      print("スキーマ検証に失敗しました! テーブル: ${status.tableName}");
      if (status.field != null) {
        print("違反しているフィールド: ${status.field}, 無効な構成: ${status.wrongValue}");
      }
    } else {
      print("診断情報: [${status.codeKey}] (Code ${status.code}): ${status.message}");
    }
  }
}
```

### 5.3 クエリ操作（`QueryResult`）およびトランザクション制御（`TransactionResult`）の処理

- **クエリの場合**:
  ```dart
  final queryResult = await db.query('users').where('age', '>', 18);
  if (queryResult.hasErrors) {
    // クエリ例外（無効なカーソル、見つからないテーブルなど）の処理
    print("クエリ失敗! コード: ${queryResult.type.code}, メッセージ: ${queryResult.message}");
  } else {
    // クエリの実行成功
    final List<Map<String, dynamic>> users = queryResult.data;
    print("${users.length} 件のレコードを取得しました。さらにデータあり: ${queryResult.hasMore}");
  }
  ```
- **トランザクションの場合**:
  ```dart
  final txnResult = await db.transaction(() async {
    await db.insert('users', newUser);
  });

  if (txnResult.hasErrors) {
    print("トランザクションがロールバックされました! TxId: ${txnResult.txId}");
    // 詳細なサブ操作の失敗を取得
    for (final status in txnResult.statuses) {
      if (status.type != ResultType.success) {
        print("失敗の原因: [${status.codeKey}] ${status.message}");
      }
    }
  }
  ```

---

## 6. 全リーフ状態コードとセマンティック識別子リファレンス

正確な状態ルーティングと解析については、以下の表を参照してください：

| ステータスコード | 識別子（CodeKey） | メモリ内列挙型（ResultType） | カテゴリ | 説明 |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `SUCCESS` | `ResultType.success` | 成功 | 操作が正常に実行されました |
| **10000** | `BIZ_VALIDATION_FAILED` | `ResultType.bizValidationFailed` | ビジネスエラー | データ形式または範囲検証の失敗 |
| **10001** | `BIZ_NOT_NULL_VIOLATION` | `ResultType.bizNotNullViolation` | ビジネスエラー | NOT NULL制約違反 |
| **10002** | `BIZ_VALIDATION_TYPE_CAST` | `ResultType.bizTypeCastFailed` | ビジネスエラー | データ型の変換またはキャストの失敗 |
| **11001** | `BIZ_CONSTRAINT_PRIMARY_KEY` | `ResultType.bizPrimaryKeyViolation` | ビジネスエラー | 主キー競合（すでに存在します） |
| **11002** | `BIZ_CONSTRAINT_UNIQUE` | `ResultType.bizUniqueViolation` | ビジネスエラー | 一意制約違反 |
| **11003** | `BIZ_CONSTRAINT_FOREIGN_KEY` | `ResultType.bizForeignKeyViolation` | ビジネスエラー | 外キー制約違反（汎用） |
| **11004** | `BIZ_CONSTRAINT_CHECK` | `ResultType.bizCheckViolation` | ビジネスエラー | CHECK制約違反 |
| **11005** | `BIZ_CONSTRAINT_FOREIGN_KEY_PARENT_NOT_EXIST` | `ResultType.bizForeignKeyParentNotExist` | ビジネスエラー | 参照された親キーが存在しません |
| **11006** | `BIZ_CONSTRAINT_FOREIGN_KEY_CHILD_RESTRICT` | `ResultType.bizForeignKeyChildRestrict` | ビジネスエラー | 子レコードによって削除/更新が制限されています |
| **11007** | `BIZ_CONSTRAINT_FOREIGN_KEY_COMPOSITE_MISMATCH` | `ResultType.bizForeignKeyCompositeMismatch` | ビジネスエラー | 複合外キーの値が不完全です |
| **11008** | `BIZ_CONSTRAINT_FOREIGN_KEY_TYPE_MISMATCH` | `ResultType.bizForeignKeyTypeMismatch` | ビジネスエラー | 外キーの型が一致しません |
| **11009** | `BIZ_CONSTRAINT_MAX_LENGTH` | `ResultType.bizValueExceedsMaxLength` | ビジネスエラー | 値の長さがスキーマ制限を超えています |
| **11010** | `BIZ_CONSTRAINT_MIN_LENGTH` | `ResultType.bizValueLessThanMinLength` | ビジネスエラー | 値の長さがスキーマ制限未満です |
| **11011** | `BIZ_CONSTRAINT_MIN_VALUE` | `ResultType.bizValueLessThanMinValue` | ビジネスエラー | 数値がスキーマ制限未満です |
| **11012** | `BIZ_CONSTRAINT_MAX_VALUE` | `ResultType.bizValueExceedsMaxValue` | ビジネスエラー | 数値がスキーマ制限を超えています |
| **12002** | `BIZ_NOT_FOUND_RECORD` | `ResultType.bizRecordNotFound` | ビジネスエラー | リソースが存在しない / レコード未検出 |
| **20001** | `DEV_INVALID_ARGUMENT_FORMAT` | `ResultType.devInvalidArgumentFormat` | 開発者エラー | 引数の形式エラー |
| **20002** | `DEV_INVALID_ARGUMENT_TYPE` | `ResultType.devInvalidArgumentType` | 開発者エラー | 引数の型不一致 |
| **20003** | `DEV_INVALID_ARGUMENT_MISSING` | `ResultType.devInvalidArgumentMissing` | 開発者エラー | 必須引数が欠落しています |
| **20005** | `DEV_INVALID_PRIMARY_KEY_FORMAT` | `ResultType.devInvalidPrimaryKeyFormat` | 開発者エラー | 无效的PrimaryKey形式 |
| **20007** | `DEV_INDEX_OUT_OF_BOUNDS` | `ResultType.devIndexOutOfBounds` | 開発者エラー | インデックスまたは範囲が境界外 |
| **20008** | `DEV_UNSUPPORTED_OPERATION` | `ResultType.devUnsupportedOperation` | 開発者エラー | 現在のコンテキストでは操作がサポートされていません |
| **20010** | `DEV_VECTOR_DIMENSION_MISMATCH` | `ResultType.devVectorDimensionMismatch` | 開発者エラー | ベクトルの次元不一致 |
| **20011** | `DEV_INDEX_FIELD_MISSING` | `ResultType.devIndexFieldMissing` | 開発者エラー | カーソル用レコードで必要なインデックスフィールドが欠落 |
| **20201** | `DEV_INVALID_CURSOR_PAGINATION` | `ResultType.devInvalidCursorPagination` | 開発者エラー | カーソルページングとオフセットは相互に排ethelessです |
| **20202** | `DEV_INVALID_CURSOR_TABLE` | `ResultType.devInvalidCursorTable` | 開発者エラー | カーソルがターゲットテーブルと一致しません |
| **20203** | `DEV_INVALID_CURSOR_SIGNATURE` | `ResultType.devInvalidCursorSignature` | 開発者エラー | カーソルの署名不一致（改ざん） |
| **20204** | `DEV_INVALID_CURSOR_ORDERBY` | `ResultType.devInvalidCursorOrderBy` | 開発者エラー | カーソルのorderBy構成が無効または不一致 |
| **20205** | `DEV_INVALID_CURSOR_MODE` | `ResultType.devInvalidCursorMode` | 開発者エラー | カーソルトークンモードの不一致 |
| **20206** | `DEV_INVALID_CURSOR_PAYLOAD` | `ResultType.devInvalidCursorPayload` | 開発者エラー | 无效的カーソルペイロード（デコード不可） |
| **20301** | `DEV_INVALID_QUERY_SELECT_FIELD` | `ResultType.devInvalidQuerySelectField` | 開発者エラー | クエリ選択フィールドはStringまたはQueryAggregationである必要があります |
| **20302** | `DEV_INVALID_QUERY_FOREIGN_KEY_JOIN` | `ResultType.devInvalidQueryForeignKeyJoin` | 開発者エラー | 自動結合用の外キー関係が存在しません |
| **20303** | `DEV_INVALID_QUERY_FIELD_ALIAS` | `ResultType.devInvalidQueryFieldAlias` | 開発者エラー | クエリフィールドのエイリアス形式が無効です |
| **20304** | `DEV_INVALID_EXPRESSION` | `ResultType.devInvalidExpression` | 開発者エラー | 無効な式構成または実行例外 |
| **22001** | `DEV_NOT_FOUND_TABLE` | `ResultType.devTableNotFound` | 開発者エラー | テーブルが見つかりません |
| **22003** | `DEV_NOT_FOUND_INDEX` | `ResultType.devIndexNotFound` | 開発者エラー | インデックスが見つかりません |
| **22004** | `DEV_NOT_FOUND_SPACE` | `ResultType.devSpaceNotFound` | 開発者エラー | スペースが見つかりません |
| **22005** | `DEV_NOT_FOUND_FIELD` | `ResultType.devFieldNotFound` | 開発者エラー | フィールドが見つかりません |
| **23001** | `DEV_LARGE_SCALE_OPERATION_REQUIRED_BYPASS` | `ResultType.devLargeScaleOperationBypassRequired` | 開発者エラー | OOM防止のため結果詳細のスキップが必要 |
| **24001** | `DEV_ENGINE_INCOMPATIBLE` | `ResultType.devEngineIncompatible` | 開発者エラー | **重大**: エンジンバージョン不整合 |
| **30000** | `DEV_INVALID_SCHEMA` | `ResultType.devInvalidSchema` | 開発者エラー | 無効なテーブルスキーマ定義 |
| **30001** | `DEV_INVALID_SCHEMA_TABLE_NAME` | `ResultType.devInvalidSchemaTableName` | 開発者エラー | テーブル名検証エラー |
| **30002** | `DEV_INVALID_SCHEMA_FIELD_NAME` | `ResultType.devInvalidSchemaFieldName` | 開発者エラー | フィールド名検証エラー |
| **30003** | `DEV_INVALID_SCHEMA_PRIMARY_KEY` | `ResultType.devInvalidSchemaPrimaryKey` | 開発者エラー | 主キー検証エラー |
| **30004** | `DEV_INVALID_SCHEMA_INDEX_LIMIT` | `ResultType.devInvalidSchemaIndexLimit` | 開発者エラー | インデックス数検証エラー |
| **30005** | `DEV_SCHEMA_TABLE_EXISTS` | `ResultType.devSchemaTableExists` | 開発者エラー | テーブルは既に存在します |
| **30006** | `DEV_SCHEMA_FIELD_EXISTS` | `ResultType.devSchemaFieldExists` | 開発者エラー | フィールドは既に存在します |
| **30007** | `DEV_SCHEMA_INDEX_EXISTS` | `ResultType.devSchemaIndexExists` | 開発者エラー | インデックスは既に存在します |
| **30008** | `DEV_INVALID_SCHEMA_FOREIGN_KEY` | `ResultType.devInvalidSchemaForeignKey` | 開発者エラー | 外キー定義が無効 |
| **30009** | `DEV_INVALID_SCHEMA_SPACE_MISMATCH` | `ResultType.devInvalidSchemaSpaceMismatch` | 開発者エラー | グローバル/スペース固有の境界の不一致 |
| **30010** | `DEV_MIGRATION_NOT_ALLOWED_WITH_DATA` | `ResultType.devMigrationNotAllowedWithData` | 開発者エラー | 移行にはデータ変更が必要ですが、明示的に許可されていません |
| **30011** | `DEV_MIGRATION_UNSAFE_TYPE_CONVERSION` | `ResultType.devMigrationUnsafeTypeConversion` | 開発者エラー | サポートされていない型変換 |
| **30013** | `DEV_MIGRATION_CANNOT_ADD_NON_NULL_FIELD` | `ResultType.devMigrationCannotAddNonNullField` | 開発者エラー | データがあるテーブルにデフォルト値なしで非NULLフィールドを追加できません |
| **30014** | `DEV_MIGRATION_NULLABLE_TO_NON_NULL_NOT_ALLOWED` | `ResultType.devMigrationNullableToNonNullNotAllowed` | 開発者エラー | フィールドをNULL許容から非NULLに変更できません |
| **30015** | `DEV_MIGRATION_UNIQUE_TIGHTENING_NOT_ALLOWED` | `ResultType.devMigrationUniqueTighteningNotAllowed` | 開発者エラー | フィールド制約をUNIQUEに引き締めできません |
| **30016** | `DEV_INVALID_SCHEMA_TTL_CONFIG` | `ResultType.devInvalidSchemaTtlConfig` | 開発者エラー | TTL構成の検証に失敗しました |
| **30017** | `DEV_INVALID_SCHEMA_DUPLICATE_FIELD_NAME` | `ResultType.devInvalidSchemaDuplicateFieldName` | 開発者エラー | テーブルスキーマ内の重複するフィールド名 |
| **30018** | `DEV_INVALID_SCHEMA_INDEX_FIELD` | `ResultType.devInvalidSchemaIndexField` | 開発者エラー | インデックスが存在しないフィールドを参照しています |
| **50001** | `SYS_TRANSACTION_ABORTED` | `ResultType.sysTransactionAborted` | システムエラー | トランザクションがアボートされました |
| **50002** | `SYS_TRANSACTION_CONFLICT` | `ResultType.sysTransactionConflict` | systemエラー | トランザクション競合 |
| **50003** | `SYS_MIGRATION_BATCH_EXECUTION_FAILED` | `ResultType.sysMigrationBatchExecutionFailed` | システムエラー | **重大**: 重大な移行バッチ実行の失敗 |
| **51001** | `SYS_TIMEOUT_LOCK_ACQUISITION` | `ResultType.sysTimeoutLockAcquisition` | システムエラー | ロック取得タイムアウト |
| **51002** | `SYS_TIMEOUT` | `ResultType.sysTimeout` | システムエラー | 操作タイムアウト |
| **51003** | `SYS_CANCELLATION` | `ResultType.sysCancellation` | システムエラー | 操作がキャンセルされました |
| **52001** | `SYS_RESOURCE_EXHAUSTED_MEMORY` | `ResultType.sysResourceExhaustedMemory` | システムエラー | **重大**: 重大なメモリリソース枯渇 |
| **52002** | `SYS_RESOURCE_EXHAUSTED` | `ResultType.sysResourceExhausted` | システムエラー | **重大**: 重大なシステムリソース枯渇 |
| **53001** | `SYS_IO_NOT_FOUND` | `ResultType.sysIoNotFound` | システムエラー | 物理ファイルまたはパスが存在しません |
| **53002** | `SYS_IO_PERMISSION_DENIED` | `ResultType.sysIoPermissionDenied` | システムエラー | ファイルアクセス権限がありません |
| **53003** | `SYS_IO_DISK_FULL` | `ResultType.sysIoDiskFull` | システムエラー | **重大**: 重大なディスク容量不足 |
| **53004** | `SYS_IO_FILE_LOCKED` | `ResultType.sysIoFileLocked` | システムエラー | ファイルが別のプロセスによってロック中 |
| **53005** | `SYS_IO_DEVICE_FAULT` | `ResultType.sysIoDeviceFault` | システムエラー | **重大**: 重大なストレージデバイスまたはメディア障害 |
| **53006** | `SYS_IO_WEB_STORAGE_UNAVAILABLE` | `ResultType.sysIoWebStorageUnavailable` | システムエラー | Web IndexedDB またはストレージが利用不可 |
| **53007** | `SYS_BACKUP_CORRUPTED` | `ResultType.sysBackupCorrupted` | システムエラー | バックアップパッケージの破損またはメタデータ欠落 |
| **53008** | `SYS_IO_DATA_CORRUPTED` | `ResultType.sysIoDataCorrupted` | システムエラー | **重大**: 重大なデータファイル破損 |
| **53009** | `SYS_INVALID_DATA_FORMAT` | `ResultType.sysInvalidDataFormat` | システムエラー | データストリームのフォーマットまたは解析失敗 |
| **53099** | `SYS_IO_GENERIC` | `ResultType.sysIoGeneric` | システムエラー | 一般的なシステムIOエラー |
| **99001** | `ENG_ERROR` | `ResultType.engError` | エンジンエラー | エンジンエラー |
