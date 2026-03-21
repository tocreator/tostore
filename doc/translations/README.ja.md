<h1 align="center">
  <img src="../resource/logo-tostore.svg" width="400" alt="ToStore">
</h1>

<p align="center">
  <a href="https://pub.dev/packages/tostore"><img src="https://img.shields.io/pub/v/tostore.svg" alt="pub package"></a>
  <a href="https://pub.dev/packages/tostore/score"><img src="https://img.shields.io/pub/points/tostore.svg" alt="Pub Points"></a>
  <a href="https://pub.dev/packages/tostore/likes"><img src="https://img.shields.io/pub/likes/tostore.svg" alt="Pub Likes"></a>
  <a href="https://pub.dev/packages/tostore"><img src="https://img.shields.io/pub/dm/tostore.svg" alt="Monthly Downloads"></a>
</p>

<p align="center">
  <a href="https://opensource.org/licenses/Apache-2.0"><img src="https://img.shields.io/badge/License-Apache_2.0-blue.svg" alt="License"></a>
  <a href="https://pub.dev/packages/tostore"><img src="https://img.shields.io/badge/Platform-Multi--Platform-02569B?logo=dart" alt="Platform"></a>
  <img src="https://img.shields.io/badge/Architecture-Neural--Distributed-orange" alt="Architecture">
</p>

<p align="center">
  <a href="../../README.md">English</a> | 
  <a href="README.zh-CN.md">简体中文</a> | 
  日本語 | 
  <a href="README.ko.md">한국어</a> | 
  <a href="README.es.md">Español</a> | 
  <a href="README.pt-BR.md">Português (Brasil)</a> | 
  <a href="README.ru.md">Русский</a> | 
  <a href="README.de.md">Deutsch</a> | 
  <a href="README.fr.md">Français</a> | 
  <a href="README.it.md">Italiano</a> | 
  <a href="README.tr.md">Türkçe</a>
</p>


## クイックナビゲーション

- [なぜToStoreなのか？](#why-tostore) | [主な機能](#key-features) | [インストール](#installation) | [クイックスタート](#quick-start)
- [スキーマ定義](#schema-definition) | [モバイル/デスクトップ統合](#mobile-integration) | [サーバー側統合](#server-integration)
- [ベクトルとANN検索](#vector-advanced) | [テーブルレベルTTL](#ttl-config) | [クエリとページネーション](#query-pagination) | [外部キー](#foreign-keys) | [クエリ演算子](#query-operators)
- [分散アーキテクチャ](#distributed-architecture) | [主キーの例](#primary-key-examples) | [アトミックな式操作](#atomic-expressions) | [トランザクション](#transactions) | [エラー処理](#error-handling)
- [セキュリティ構成](#security-config) | [パフォーマンス](#performance) | [リソース](#more-resources)


<a id="why-tostore"></a>
## なぜ ToStore なのか？

ToStore は、AGI 時代とエッジインテリジェンスのシナリオ向けに設計された近代的なデータエンジンです。分散システム、マルチモーダル融合、リレーショナル構造化データ、高次元ベクトル、および非構造化データの保存をネイティブにサポートしています。ニューラルネットワークのような基盤アーキテクチャに基づき、ノードは高い自律性と弾力的な水平スケーラビリティを備え、エッジとクラウドを横断するシームレスなクロスプラットフォームの連携を実現する柔軟なデータトポロジネットワークを構築します。ACID トランザクション、複雑なリレーションクエリ（JOIN、連鎖外部キー）、テーブルレベルの TTL、集計計算などの機能を備えています。また、複数の分散主キーアルゴリズム、アトミックな式、スキーマ変更の識別、暗号化保護、マルチスペースデータ分離、リソース対応のインテリジェントな負荷分散、および災害時やクラッシュ時の自己修復機能を備えています。

コンピューティングの重心がエッジインテリジェンスへとシフトし続ける中で、エージェントやセンサーなどの様々な端末は単なる「コンテンツ表示装置」ではなく、ローカル生成、環境認識、リアルタイムの意思決定、およびデータ連携を担うインテリジェントノードになりつつあります。従来のデータベースソリューションは、基盤アーキテクチャやアドオン型の拡張に制限され、高頻度の書き込み、膨大なデータ、ベクトル検索、および連携生成に直面した際、エッジインテリジェンスアプリケーションが求める低遅延と安定性を満たすことが困難になっています。

ToStore は、膨大なデータ、複雑なローカル AI 生成、および大規模なデータフローをサポートする分散機能をエッジに提供します。エッジとクラウドのノード間の深層的な連携により、没入型の AR/VR 融合、マルチモーダル対話、セマンティックベクトル、空間モデリングなどのシナリオに対して信頼性の高いデータ基盤を提供します。


<a id="key-features"></a>
## 主な機能

- 🌐 **統合されたクロスプラットフォームデータエンジン**
  - モバイル、デスクトップ、Web、およびサーバー向けの統合 API。
  - リレーショナル構造化データ、高次元ベクトル、および非構造化データの保存をサポート。
  - ローカルストレージからエッジ・クラウド連携まで、あらゆるデータサイクルに対応。

- 🧠 **ニューラルネットワークのような分散アーキテクチャ**
  - ノードの高い自律性；相互接続された連携により柔軟なデータトポロジを構築。
  - ノードの連携と弾力的な水平スケーラビリティをサポート。
  - エッジインテリジェントノードとクラウド間の深層接続。

- ⚡ **並列実行とリソーススケジューリング**
  - リソース対応型のインテリジェントな負荷分散による高可用性を実現。
  - マルチノード並列連携計算とタスクの細分化。

- 🔍 **構造化クエリとベクトル検索**
  - 複雑な条件クエリ、JOIN、集計計算、およびテーブルレベルの TTL をサポート。
  - ベクトルフィールド、ベクトルインデックス、および近傍検索（ANN）をサポート。
  - 構造化データとベクトルデータを同一エンジン内で連携して使用可能。

- 🔑 **主キー、インデックス、およびスキーマの進化**
  - 順次増分、タイムスタンプ、日付プレフィックス、および短縮コードの主キーアルゴリズムを内蔵。
  - ユニークインデックス、複合インデックス、ベクトルインデックス、および外部キー制約をサポート。
  - スキーマ変更をインテリジェントに認識し、データ移行を自動化。

- 🛡️ **トランザクション、セキュリティ、およびリカバリ**
  - ACID トランザクション、アトミックな式の更新、および連鎖外部キーを提供。
  - クラッシュリカバリ、永続化フラッシュ、およびデータ整合性を保証。
  - ChaCha20-Poly1305 および AES-256-GCM 暗号化をサポート。

- 🔄 **マルチスペースとデータワークフロー**
  - スペースによるデータ分離とグローバル共有の設定をサポート。
  - クエリのリアルタイムリスナー、マルチレベルのインテリジェントキャッシュ、およびカーソルページネーション。
  - マルチユーザー、ローカル優先、オフライン連携アプリケーションに最適。


<a id="installation"></a>
## インストール

> [!IMPORTANT]
> **v2.x からアップグレードしますか？** 重要な移行手順と重大な変更については、[v3.x アップグレードガイド](../UPGRADE_GUIDE_v3.md) をお読みください。

`pubspec.yaml` に `tostore` を依存関係として追加します。

```yaml
dependencies:
  tostore: any # 最新バージョンを使用してください
```

<a id="quick-start"></a>
## クイックスタート

> [!IMPORTANT]
> **テーブルスキーマの定義が最初のステップです**：CRUD操作を実行する前に、テーブルスキーマを定義する必要があります（KVストレージのみを使用する場合を除く）。具体的な定義方法は、シナリオによって異なります。
> - 定義と制約の詳細については、[スキーマ定義](#schema-definition) を参照してください。
> - **モバイル/デスクトップ**：インスタンスの初期化時に `schemas` を渡します。詳細は [モバイル/デスクトップ統合](#mobile-integration) を参照してください。
> - **サーバー側**：実行時に `createTables` を使用します。詳細は [サーバー側統合](#server-integration) を参照してください。

```dart
// 1. データベースの初期化
final db = await ToStore.open();

// 2. データの挿入
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. チェーンクエリ（詳細は[クエリ演算子](#query-operators)を参照; =, !=, >, <, LIKE, IN などをサポート）
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// 4. 更新と削除
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. リアルタイムリスニング (データ変更時に UI が自動的に更新されます)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('一致するユーザーが更新されました: $users');
});
```

### キー値ストレージ (KV)
構造化されたテーブルを必要としないシナリオに適しています。シンプルで実用的であり、設定やステータスなどの散在するデータ向けに高性能なKVストアを内蔵しています。異なるスペースのデータはデフォルトで分離されていますが、グローバル共有に設定することも可能です。

```dart
// データベースの初期化
final db = await ToStore.open();

// キー値ペアの設定 (String, int, bool, double, Map, List などをサポート)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// データの取得
final theme = await db.getValue('theme'); // 'dark'

// データの削除
await db.removeValue('theme');

// グローバルキー値 (スペース間で共有)
// 通常のKVデータはスペースを切り替えると無効になります。グローバル共有には isGlobal: true を使用します。
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```


<a id="schema-definition"></a>
## スキーマ定義
以下のモバイルおよびサーバー側の例では、ここで定義された `appSchemas` を再利用します。

### TableSchema の概要

```dart
const userSchema = TableSchema(
  name: 'users', // テーブル名、必須
  tableId: 'users', // ユニーク識別子、オプション；テーブルのリネームを100%正確に識別するために使用
  primaryKeyConfig: PrimaryKeyConfig(
    name: 'id', // 主キーフィールド名、デフォルトは 'id'
    type: PrimaryKeyType.sequential, // 自動生成タイプ
    sequentialConfig: SequentialIdConfig(
      initialValue: 1000, // 開始値
      increment: 1, // ステップサイズ
      useRandomIncrement: false, // ランダム増分を使用するかどうか
    ),
  ),
  fields: [
    FieldSchema(
      name: 'username', // フィールド名、必須
      type: DataType.text, // データタイプ、必須
      nullable: false, // nullを許可するかどうか
      minLength: 3, // 最小長
      maxLength: 32, // 最大長
      unique: true, // ユニーク制約
      fieldId: 'username', // フィールドの一意の識別子、オプション；リネームの識別に、
      comment: 'ログイン名', // オプションのコメント
    ),
    FieldSchema(
      name: 'status',
      type: DataType.integer,
      minValue: 0, // 下限
      maxValue: 150, // 上限
      defaultValue: 0, // 静的デフォルト値
      createIndex: true,  // インデックスをショートカットで作成し、パフォーマンスを向上
    ),
    FieldSchema(
      name: 'created_at',
      type: DataType.datetime,
      nullable: false,
      defaultValueType: DefaultValueType.currentTimestamp, // 現在時刻で自動入力
      createIndex: true,
    ),
  ],
  indexes: const [
    IndexSchema(
      indexName: 'idx_users_status_created_at', // オプションのインデックス名
      fields: ['status', 'created_at'], // 複合インデックスフィールド
      unique: false, // ユニークインデックスかどうか
      type: IndexType.btree, // インデックスタイプ：btree/hash/bitmap/vector
    ),
  ],
  foreignKeys: const [], // オプションの外部キー制約；詳細は「外部キー」セクションを参照
  isGlobal: false, // グローバルテーブルかどうか；すべてのスペースでアクセス可能
  ttlConfig: null, // テーブルレベルの TTL；詳細は「テーブルレベル TTL」セクションを参照
);

const appSchemas = [userSchema];
```

`DataType` は `integer`、`bigInt`、`double`、`text`、`blob`、`boolean`、`datetime`、`array`、`json`、`vector` をサポートしています。`PrimaryKeyType` は `none`、`sequential`、`timestampBased`、`datePrefixed`、`shortCode` をサポートしています。

### 制約と自動検証

`FieldSchema` を使用して、一般的な検証ルールをスキーマに直接記述することができ、UI やサービス層での重複したロジックを避けることができます。

- `nullable: false`：非 null 制約。
- `minLength` / `maxLength`：テキスト長の制約。
- `minValue` / `maxValue`：数値範囲の制約。
- `defaultValue` / `defaultValueType`：静的および動的なデフォルト値。
- `unique`：ユニーク制約。
- `createIndex`：高頻度のフィルタリング、ソート、または結合用のインデックスを作成。
- `fieldId` / `tableId`：移行時のテーブルやフィールドのリネーム識別の補助。

これらの制約はデータの書き込み時に検証され、ビジネス層での重複した実装を減らします。`unique: true` は自動的に一意のインデックスを生成し、`createIndex: true` や外部キーは自動的に標準のインデックスを生成します。複合インデックスやベクトルインデックスには `indexes` を使用します。


### 統合方法の選択

- **モバイル/デスクトップ**：`appSchemas` を直接 `ToStore.open(...)` に渡すのが最適です。
- **サーバー側**：実行時に `createTables(appSchemas)` を介して動的にスキーマを作成するのが最適です。


<a id="mobile-integration"></a>
## モバイル/デスクトップ統合

📱 **例**: [mobile_quickstart.dart](../../example/lib/mobile_quickstart.dart)

```dart
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// Android/iOS: 書き込み可能なディレクトリを先に解決し、dbPath として渡します
final docDir = await getApplicationDocumentsDirectory();
final dbRoot = p.join(docDir.path, 'common');

// 上記で定義した appSchemas を再利用
final db = await ToStore.open(
  dbPath: dbRoot,
  schemas: appSchemas,
);

// マルチスペースアーキテクチャ - 異なるユーザーのデータを分離
await db.switchSpace(spaceName: 'user_123');
```

### ログイン状態の保持とログアウト（アクティブスペース）

マルチスペースは**ユーザーデータの分離**に最適です。ユーザーごとに1つのスペースを割り当て、ログイン時に切り替えます。**アクティブスペース**と**クローズオプション**を使用すると、アプリの再起動後も現在のユーザーを保持し、クリーンなログアウトをサポートできます。

- **ログイン状態の保持**：ユーザーが自分のスペースに切り替える際、それをアクティブとしてマークします。次回の起動時はデフォルトでそのスペースに直接入ることができ、「デフォルトを開いてから切り替える」手順を避けることができます。
- **ログアウト**：ユーザーがログアウトする際は、`keepActiveSpace: false` でデータベースを閉じます。次回の起動時に前のユーザーのスペースが自動的に開かれることはありません。

```dart
// ログイン後：ユーザーのスペースに切り替え、アクティブとしてマーク（ログイン状態の保持）
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// オプション：デフォルトのスペースのみを厳密に使用する場合（例：ログイン画面のみ）
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// ログアウト時：データベースを閉じ、アクティブスペースをクリアして次回起動時にデフォルトを使用
await db.close(keepActiveSpace: false);
```


<a id="server-integration"></a>
## サーバー側統合

🖥️ **例**: [server_quickstart.dart](../../example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// サーバー起動時にテーブル構造を作成または検証
await db.createTables(appSchemas);

// オンラインスキーマの更新
final taskId = await db.updateSchema('users')
  .renameTable('users_new')                // テーブル名を変更
  .modifyField(
    'username',
    minLength: 5,
    maxLength: 20,
    unique: true
  )                                        // フィールド属性を変更
  .renameField('old_name', 'new_name')     // フィールド名を変更
  .removeField('deprecated_field')         // フィールドを削除
  .addField('created_at', type: DataType.datetime)  // フィールドを追加
  .removeIndex(fields: ['age'])            // インデックスを削除
  .setPrimaryKeyConfig(                    // 主キータイプを変更；データが空である必要があります
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
    
// 移行の進捗を監視
final status = await db.queryMigrationTaskStatus(taskId);
print('移行の進捗: ${status?.progressPercentage}%');


// 手動クエリキャッシュ管理 (サーバー側)
主キーやインデックス付きフィールドに対する等価またはINクエリは非常に高速なため、手動のキャッシュ管理は通常不要です。

// クエリ結果を5分間手動でキャッシュ。期間を指定しない場合は無期限になります。
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// データ変更時に特定のキャッシュを無効化し、一貫性を確保
await db.query('users')
    .where('is_active', '=', true)
    .clearQueryCache();

// リアルタイムのデータを必要とするクエリでキャッシュを明示的に無効化
final freshUserData = await db.query('users')
    .where('is_active', '=', true)
    .noQueryCache();
```


<a id="advanced-usage"></a>
## 進階的な使い方

ToStore は、複雑なビジネス要件を満たすための豊富な機能を提供します。


<a id="vector-advanced"></a>
### ベクトルと ANN 検索

```dart
await db.createTables([
  const TableSchema(
    name: 'embeddings',
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.timestampBased,
    ),
    fields: [
      FieldSchema(
        name: 'document_title',
        type: DataType.text,
        nullable: false,
      ),
      FieldSchema(
        name: 'embedding',
        type: DataType.vector,  // ベクトル型を宣言
        nullable: false,
        vectorConfig: VectorFieldConfig(
          dimensions: 128, // ベクトルの次元；書き込み時とクエリ時で一致させる必要があります
          precision: VectorPrecision.float32, // 精度；float32 は精度とスペースのバランスが良いです
        ),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['embedding'], // インデックスを作成するフィールド
        type: IndexType.vector,  // ベクトルインデックスを構築
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh,  // インデックスアルゴリズム；内蔵の NGH
          distanceMetric: VectorDistanceMetric.cosine, // メトリック；正規化された埋め込みに最適
          maxDegree: 32, // 各ノードの最大近傍数；大きくすると再現率は上がりますがメモリを消費します
          efSearch: 64, // 検索拡張係数；大きくすると精度は上がりますが遅くなります
          constructionEf: 128, // インデックス品質係数；大きくすると高品質になりますが構築が遅くなります
        ),
      ),
    ],
  ),
]);

final queryVector =
    VectorData.fromList(List.generate(128, (i) => i * 0.01)); // 次元を一致させる必要があります

// ベクトル検索
final results = await db.vectorSearch(
  'embeddings', 
  fieldName: 'embedding', 
  queryVector: queryVector, 
  topK: 5, // 上位 5 件を返す
  efSearch: 64, // デフォルトの検索拡張係数を上書き
);

for (final r in results) {
  print('pk=${r.primaryKey}, score=${r.score}, distance=${r.distance}');
}
```

**パラメータの説明**:
- `dimensions`: 入力埋め込みの幅と一致させる必要があります。
- `precision`: オプションの `float64`、`float32`、`int8`; 高精度にするとストレージコストが増加します。
- `distanceMetric`: セマンティックな類似性には `cosine`、ユークリッド距離には `l2`、内積検索には `innerProduct` を選択。
- `maxDegree`: NGH グラフ内の最大近傍数。
- `efSearch`: 検索時の拡張幅。
- `topK`: 返す結果の数。

**結果の説明**:
- `score`: 正規化された類似度スコア (0 から 1)；大きいほど類似度が高い。
- `distance`: `l2` や `cosine` では、距離が大きいほど類似度が低くなります。


<a id="ttl-config"></a>
### テーブルレベル TTL (自動有効期限)

ログやイベントなどの時系列データについては、スキーマで `ttlConfig` を定義します。期限切れのデータはバックグラウンドで自動的にクリーンアップされます。

```dart
const TableSchema(
  name: 'event_logs',
  fields: [
    FieldSchema(
      name: 'created_at',
      type: DataType.datetime,
      nullable: false,
      createIndex: true,
      defaultValueType: DefaultValueType.currentTimestamp,
    ),
  ],
  ttlConfig: TableTtlConfig(
    ttlMs: 7 * 24 * 60 * 60 * 1000, // 7日間保持
    // sourceField: 指定しない場合は自動的に作成されたインデックスが使用されます
    // カスタム sourceField の要件:
    // 1) DataType.datetime
    // 2) 非 null (nullable: false)
    // 3) デフォルト値が DefaultValueType.currentTimestamp
    // sourceField: 'created_at',
  ),
);
```


### クエリの入れ子とカスタムフィルタリング
無限のレベルの入れ子と柔軟なカスタム関数をサポートしています。

```dart
// 条件の入れ子: (type = 'app' OR (id >= 123 OR fans >= 200))
final idCondition = QueryCondition().where('id', '>=', 123).or().where('fans', '>=', 200);

final result = await db.query('users')
    .condition(
        QueryCondition().whereEqual('type', 'app').or().condition(idCondition)
    )
    .limit(20);

// カスタム条件関数
final customResult = await db.query('users')
    .whereCustom((record) => record['tags']?.contains('おすすめ') ?? false);
```

### 挿入と更新の自動切り替え (Upsert)
PK またはユニークキーが存在する場合は更新し、存在しない場合は挿入します。`where` はサポートされません。競合の対象はデータによって決まります。

```dart
// 主キーによる
final result = await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});

// ユニークキーによる（ユニークインデックスの全フィールドと必須フィールドが含まれている必要があります）
await db.upsert('users', {
  'username': 'john',
  'email': 'john@example.com',
  'age': 26,
});

// 一括 upsert
final batchResult = await db.batchUpsert('users', [
  {'username': 'a', 'email': 'a@example.com'},
  {'username': 'b', 'email': 'b@example.com'},
], allowPartialErrors: true);
```


### 結合 (JOIN) とフィールド選択
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000)
    .limit(20);
```

### ストリーミングと集計
```dart
// レコードのカウント
final count = await db.query('users').count();

// テーブルが存在するかチェック (スペースに依存しない)
final usersTableDefined = await db.tableExists('users');

// 効率的なデータの存在確認（レコード全体を読み込まない）
final emailExists = await db.query('users')
    .where('email', '=', 'test@example.com')
    .exists();

// 集計関数
final totalAge = await db.query('users').where('age', '>', 18).sum('age');
final avgAge = await db.query('users').avg('age');
final maxAge = await db.query('users').max('age');
final minAge = await db.query('users').min('age');

// グループ化とフィルタリング
final result = await db.query('orders')
    .select(['status', Agg.sum('amount', alias: 'total')])
    .groupBy(['status'])
    .having(Agg.sum('amount'), '>', 1000)
    .limit(20);

// 重複除外クエリ
final uniqueCities = await db.query('users').distinct(['city']);

// ストリーミング (膨大なデータに最適)
db.streamQuery('users').listen((data) => print(data));
```


<a id="query-pagination"></a>
### クエリと効率的なページネーション

> [!TIP]
> **最高のパフォーマンスを得るために `limit` を明示的に指定してください**：常に `limit` を指定することを強く推奨します。省略した場合、エンジンはデフォルトで 1000 レコードに制限します。コアは高速ですが、アプリ層で大量のデータをシリアライズすると不必要な遅延が発生する可能性があります。

ToStore は、データの規模に合わせて 2 つのページネーションモードを提供します。

#### 1. オフセットモード
小規模なデータセット（1万件未満）や、特定のページへのジャンプが必要な場合に最適です。

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // 最初の40件をスキップ
    .limit(20); // 20件を取得
```
> [!TIP]
> `offset` が大きくなると、DB がレコードをスキャンして破棄する必要があるため、パフォーマンスは直線的に低下します。深い階層のページには **カーソルモード** を使用してください。

#### 2. カーソルモード
**膨大なデータと無限スクロールに推奨されます**。`nextCursor` を使用して現在の位置から読み取りを再開するため、大きなオフセットに伴うオーバーヘッドを回避できます。

> [!IMPORTANT]
> 複雑なクエリやインデックスのないフィールドでのソートの場合、エンジンは全テーブルスキャンにフォールバックし、`null` カーソルを返すことがあります（その特定のクエリではページネーションがサポートされていないことを示します）。

```dart
// 1ページ目
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// カーソルを使用して次のページを取得
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // その位置に直接シークします
}

// prevCursor を使用して効率的に戻る
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| 機能 | オフセットモード | カーソルモード |
| :--- | :--- | :--- |
| **パフォーマンス** | ページが進むにつれて低下 | **常に一定 (O(1))** |
| **ユースケース** | 小規模データ、ページジャンプ | **膨大なデータ、無限スクロール** |
| **一貫性** | データの変更により重複や欠落が生じる可能性がある | **データの変更による不整合を回避** |


<a id="foreign-keys"></a>
### 外部キーと連鎖操作

参照整合性を強制し、連鎖的な更新や削除を構成します。制約は書き込み時にチェックされます。連鎖ポリシーは関連データを自動的に処理するため、アプリ内での整合性ロジックを減らすことができます。

```dart
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(name: 'id'),
    fields: [
      FieldSchema(name: 'username', type: DataType.text, nullable: false),
    ],
  ),
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
          fields: ['user_id'],              // 現在のテーブルのフィールド
          referencedTable: 'users',         // 参照先のテーブル
          referencedFields: ['id'],         // 参照先のフィールド
          onDelete: ForeignKeyCascadeAction.cascade,  // 連鎖削除
          onUpdate: ForeignKeyCascadeAction.cascade,  // 連鎖更新
        ),
    ],
  ),
]);
```


<a id="query-operators"></a>
### クエリ演算子

すべての `where(field, operator, value)` 条件は、以下の演算子をサポートしています（大文字小文字を区別しません）。

| 演算子 | 説明 | 例 / 型 |
| :--- | :--- | :--- |
| `=` | 等しい | `where('status', '=', 'active')` |
| `!=`, `<>` | 等しくない | `where('role', '!=', 'guest')` |
| `>` | より大きい | `where('age', '>', 18)` |
| `>=` | 以上 | `where('score', '>=', 60)` |
| `<` | より小さい | `where('price', '<', 100)` |
| `<=` | 以下 | `where('quantity', '<=', 10)` |
| `IN` | リストに含まれる | `where('id', 'IN', ['a','b','c'])` — 型: `List` |
| `NOT IN` | リストに含まれない | `where('status', 'NOT IN', ['banned'])` — 型: `List` |
| `BETWEEN` | 範囲内 | `where('age', 'BETWEEN', [18, 65])` — 型: `[開始, 終了]` |
| `LIKE` | パターンマッチ (`%` は任意, `_` は一文字) | `where('name', 'LIKE', '%John%')` — 型: `String` |
| `NOT LIKE` | パターン不一致 | `where('email', 'NOT LIKE', '%@test.com')` — 型: `String` |
| `IS` | null である | `where('deleted_at', 'IS', null)` — 型: `null` |
| `IS NOT` | null でない | `where('email', 'IS NOT', null)` — 型: `null` |

### セマンティックなクエリメソッド (推奨)

セマンティックなメソッドを使用すると、手動での演算子文字列入力を避け、より良い IDE サポートを利用できます。

```dart
// 比較
db.query('users').whereEqual('username', 'John');
db.query('users').whereNotEqual('role', 'guest');
db.query('users').whereGreaterThan('age', 18);
db.query('users').whereGreaterThanOrEqualTo('score', 60);
db.query('users').whereLessThan('price', 100);
db.query('users').whereLessThanOrEqualTo('quantity', 10);

// 集合と範囲
db.query('users').whereIn('id', ['id1', 'id2']);
db.query('users').whereNotIn('status', ['banned', 'pending']);
db.query('users').whereBetween('age', 18, 65);

// Null チェック
db.query('users').whereNull('deleted_at');
db.query('users').whereNotNull('email');

// パターンマッチング
db.query('users').whereLike('name', '%John%');
db.query('users').whereNotLike('email', '%@temp.');
db.query('users').whereContains('bio', 'flutter');   // LIKE '%flutter%'
db.query('users').whereNotContains('title', 'draft');

// 次と等価: .where('age', '>', 18).where('name', 'like', '%John%')
final users = await db.query('users')
    .whereGreaterThan('age', 18)
    .whereLike('username', '%John%')
    .orderByDesc('age')
    .limit(20);
```


<a id="distributed-architecture"></a>
## 分散アーキテクチャ

```dart
// 分散ノードの構成
final db = await ToStore.open(
  config: DataStoreConfig(
    distributedNodeConfig: const DistributedNodeConfig(
      enableDistributed: true,            // 分散モードを有効にする
      clusterId: 1,                       // クラスター ID
      centralServerUrl: 'https://127.0.0.1:8080',
      accessToken: 'b7628a4f9b4d269b98649129'
    )
  )
);

// 高性能な一括挿入
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... 効率的な一括挿入
]);

// 大規模データセットのストリーミング
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // メモリのスパイクを避けるために、レコードを順次処理します
  print(record);
}
```


<a id="primary-key-examples"></a>
## 主キー

ToStore は、様々なシナリオに対応するために多様な分散主キーアルゴリズムを提供しています。

- **順次増分** (PrimaryKeyType.sequential): 238978991
- **タイムスタンプベース** (PrimaryKeyType.timestampBased): 1306866018836946
- **日付プレフィックス** (PrimaryKeyType.datePrefixed): 20250530182215887631
- **短縮コード** (PrimaryKeyType.shortCode): 9eXrF0qeXZ

```dart
// 順次主キーの構成例
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,
        increment: 50,
        useRandomIncrement: true, // ビジネスボリュームの隠蔽
      ),
    ),
    fields: [/* フィールド定義 */]
  ),
]);
```


<a id="atomic-expressions"></a>
## アトミックな式操作

式システムは、型安全でアトミックなフィールド更新を提供します。すべての計算はデータベースレベルで実行され、同時実行の不整合を防止します。

```dart
// 単純な増分: balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// 複雑な計算: total = price * quantity + tax
await db.update('orders', {
  'total': (Expr.field('price') * Expr.field('quantity')) + Expr.field('tax'),
}).where('id', '=', orderId);

// 入れ子の括弧
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) * 
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// 関数: price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// タイムスタンプ
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

**条件付き式 (例: Upsert 時)**: `Expr.isUpdate()` / `Expr.isInsert()` を `Expr.ifElse` や `Expr.when` と組み合わせて、更新時または挿入時にのみロジックを実行します。

```dart
// Upsert: 更新時に増分し、挿入時に1をセットする
await db.upsert('counters', {
  'key': 'visits',
  'count': Expr.ifElse(
    Expr.isUpdate(),
    Expr.field('count') + Expr.value(1),
    1, // 挿入ブランチ: リテラル値。評価対象外。
  ),
});

// Expr.when を使用
await db.upsert('orders', {
  'id': orderId,
  'updatedAt': Expr.when(Expr.isUpdate(), Expr.now(), otherwise: Expr.now()),
});
```


<a id="transactions"></a>
## トランザクション

トランザクションは原子性を保証します。すべての操作が成功するか、すべてがロールバックされるかのいずれかとなり、絶対的な一貫性を維持します。

**トランザクションの特徴**:
- マルチステップ操作のアトミックなコミット。
- クラッシュ後の未完了タスクの自動リカバリ。
- コミット成功時にデータが安全に永続化されます。

```dart
// 基本的なトランザクション
final txResult = await db.transaction(() async {
  // ユーザーの挿入
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });
  
  // 式によるアトミックな更新
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');
  
  // ここでの失敗は、すべての変更の自動ロールバックをトリガーします。
});

if (txResult.isSuccess) {
  print('トランザクションがコミットされました');
} else {
  print('トランザクションがロールバックされました: ${txResult.error?.message}');
}

// 例外時の自動ロールバック
final txResult2 = await db.transaction(() async {
  await db.insert('users', {
    'username': 'jane',
    'email': 'jane@example.com',
  });
  throw Exception('Business Failure'); 
}, rollbackOnError: true);
```


<a id="error-handling"></a>
### エラー処理

ToStore は、データ操作に対して統一されたレスポンスモデルを使用します。
- `ResultType`: 分岐ロジックに使用できる安定したステータス列挙型。
- `result.code`: `ResultType` に対応する数値コード。
- `result.message`: エラーの読みやすい説明。
- `successKeys` / `failedKeys`: 一括操作時などの主キーのリスト。

```dart
final result = await db.insert('users', {
  'username': 'john',
  'email': 'john@example.com',
});

if (!result.isSuccess) {
  switch (result.type) {
    case ResultType.notFound:
      print('リソースが見つかりませんでした: ${result.message}');
      break;
    case ResultType.notNullViolation:
    case ResultType.validationFailed:
      print('検証に失敗しました: ${result.message}');
      break;
    case ResultType.uniqueViolation:
      print('競合が発生しました: ${result.message}');
      break;
    default:
      print('コード: ${result.code}, メッセージ: ${result.message}');
  }
}
```

**一般的なステータスコード**:
成功は 0、負の値はエラーを表します。
- `ResultType.success` (0)
- `ResultType.partialSuccess` (1)
- `ResultType.uniqueViolation` (-2)
- `ResultType.primaryKeyViolation` (-3)
- `ResultType.foreignKeyViolation` (-4)
- `ResultType.notNullViolation` (-5)
- `ResultType.validationFailed` (-6)
- `ResultType.notFound` (-11)
- `ResultType.resourceExhausted` (-15)


### 純メモリモード

データキャッシュやディスクレス環境の場合は、`ToStore.memory()` を使用します。すべてのデータ（スキーマ、インデックス、KV）は RAM 内に保持されます。

**注意**: データはアプリの終了または再起動時に失われます。

```dart
// インメモリデータベースの初期化
final db = await ToStore.memory(schemas: []);

// すべての操作がほぼ即座に完了します
await db.insert('temp_cache', {'key': 'session_1', 'value': 'admin'});
```


<a id="security-config"></a>
## セキュリティ構成

> [!WARNING]
> **キー管理**: **`encodingKey`** は変更可能です。エンジンが自動的にデータを移行します。**`encryptionKey`** は非常に重要です。変更すると、移行なしで古いデータを読み取ることができなくなります。機密キーをハードコードしないでください。

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // サポート: none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305, 
      
      // 符号化キー (データの自動移行が可能)
      encodingKey: 'Your-32-Byte-Long-Encoding-Key...', 
      
      // 暗号化キー (非常に重要、移行なしでの変更不可)
      encryptionKey: 'Your-Secure-Encryption-Key...',
      
      // デバイスバインディング (パスベース)
      // キーを DB のパスとデバイスの特性に紐付けます。
      // DB ファイルが移動された場合に復号を防ぎます。
      deviceBinding: false, 
    ),
    enableJournal: true, // ライトアヘッドロギング (WAL)
    persistRecoveryOnCommit: true, // コミット時に強制フラッシュ
  ),
);
```

### フィールドレベルの暗号化 (ToCrypto)

データベース全体の暗号化はパフォーマンスに影響を与える可能性があります。特定の機密フィールドには **ToCrypto** を使用します。DB インスタンスを必要とせず、Base64 出力で値をエンコード/デコードするスタンドアロンのユーティリティで、JSON や TEXT カラムに最適です。

```dart
const key = 'my-secret-key';
// エンコード: プレーンテキスト -> Base64 暗号文
final cipher = ToCrypto.encode('機密データ', key: key);
// デコード
final plain = ToCrypto.decode(cipher, key: key);

// オプション: AAD によるコンテキストバインディング (デコード時にも一致させる必要があります)
final aad = Uint8List.fromList(utf8.encode('users:id_number'));
final cipher2 = ToCrypto.encode('secret', key: key, aad: aad);
final plain2 = ToCrypto.decode(cipher2, key: key, aad: aad);
```


<a id="performance"></a>
## パフォーマンス

### ベストプラクティス
- 📱 **サンプルプロジェクト**: Flutter アプリの完全な例については、`example` ディレクトリを参照してください。
- 🚀 **実稼働環境**: リリースモードでのパフォーマンスはデバッグモードを大幅に上回ります。
- ✅ **標準化**: すべてのコア機能は包括的なテストスイートによってカバーされています。

### ベンチマーク

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="ToStore パフォーマンスデモ" width="320" />
</p>

- **パフォーマンスショーケース**: 1億件以上のレコードがあっても、標準的なモバイルデバイス上で起動、スクロール、検索がスムーズに維持されます。 ( [動画](https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4) を参照)

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="ToStore 災害復旧" width="320" />
</p>

- **災害復旧**: 高頻度の書き込み中に電源が切れたりプロセスが強制終了されたりしても、ToStore は迅速に自己修復します。 ( [動画](https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4) を参照)


ToStore がお役に立てたなら、ぜひ ⭐️ をお願いします！それはオープンソースに対する最大のサポートです。

---

> **推奨**: フロントエンド開発には [ToApp Framework](https://github.com/tocreator/toapp) の使用をご検討ください。データリクエスト、読み込み、保存、キャッシュ、および状態管理を自動化するフルスタックソリューションを提供します。


<a id="more-resources"></a>
## リソース

- 📖 **ドキュメント**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **フィードバック**: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **ディスカッション**: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
