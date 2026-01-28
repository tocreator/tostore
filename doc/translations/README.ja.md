# Tostore

[English](../../README.md) | [简体中文](README.zh-CN.md) | 日本語 | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)


## なぜ Tostore を選ぶのか？

Tostore は、Dart/Flutter エコシステムにおいて唯一の高性能な分散型ベクトルデータベース・ストレージエンジンです。ニューラルネットワーク型のアーキテクチャを採用し、ノード間のインテリジェントな相互接続と協調を実現。無限の水平スケーリングをサポートし、柔軟なデータトポロジーネットワークを構築します。正確なスキーマ変更の識別、暗号化保護、マルチスペースによるデータ隔離を提供します。マルチコア CPU を最大限に活用した超並列処理を実現し、モバイルエッジデバイスからクラウドまでのクロスプラットフォーム協調をネイティブにサポート。多彩な分散主鍵アルゴリズムを備え、没入型 AR/VR、マルチモーダルインタラクション、空間コンピューティング、生成 AI、意味的ベクトル空間モデリングなどのシナリオに強力なデータ基盤を提供します。

生成 AI と空間コンピューティングにより計算の重心がエッジへ移行する中、端末デバイスは単なるコンテンツ表示器から、ローカル生成、環境認識、リアルタイム意思決定の中核へと進化しています。従来の単一ファイル型の組み込みデータベースは、そのアーキテクチャ設計上の制限から、高頻度の書き込みや大規模なベクトル検索、クラウド・エッジ協調生成などの場面おいて、インテリジェント・アプリケーションが求める究極のレスポンス要件を支えきれないことが多々あります。Tostore はエッジデバイスのために生まれ、複雑な AI ローカル生成や大規模なデータ流通を支えるのに十分な分散ストレージ能力をエッジ端に付与し、クラウドとエッジの真の深化協調を実現します。

**停電やクラッシュに強い**：予期せぬ停電やアプリケーションのクラッシュが発生しても、データは自動的に復旧され、真のデータ損失ゼロを実現します。データ操作の応答があった時点でデータは安全に保存されており、損失のリスクを心配する必要はありません。

**性能の限界を突破**：実測テストでは、一般的なスマートフォンでも1,000万件のデータ量で即座に起動し、クエリ結果を瞬時に表示します。データ量に関わらず、従来のデータベースを遥かに凌駕するスムーズな体験を提供します。




...... 指先からクラウドアプリケーションまで、Tostore はデータ演算力を解放し、未来を支えます ......




## Tostore の特徴

- 🌐 **全プラットフォーム。シームレスなサポート**
  - モバイルアプリからクラウドサーバーまで、一つのコードで全プラットフォーム動作。
  - プラットフォームごとのストレージバックエンド（IndexedDB、ファイルシステムなど）にインテリジェントに適応。
  - 統一された API インターフェースにより、クロスプラットフォームのデータ同期も安心。
  - エッジデバイスからクラウドサーバーへのシームレスなデータフロー。
  - エッジデバイス上でのローカルベクトル計算により、ネットワーク遅延とクラウド依存を低減。

- 🧠 **ニューラルネットワーク型分散アーキテクチャ**
  - ノードが相互接続されたニューラルネットワークのようなトポロジー構造により、効率的なデータフローを組織。
  - 高性能なデータパーティショニングメカニズムによる真の分散処理。
  - インテリジェントな動的ワークロードバランスにより、リソース利用を最大化。
  - ノードの無限な水平拡張により、複雑なデータネットワークを容易に構築。

- ⚡ **究極の並列処理能力**
  - Isolate による真の並列読み書きを実現し、マルチコア CPU をフル活用。
  - インテリジェントなリソーススケジューリングにより、負荷を自動分散し、マルチコア性能を最大化。
  - マルチノード計算ネットワークの協調動作により、タスク処理効率が倍増。
  - リソース認識型ススケジューリングフレームワークにより、実行計画を自動最適化し、リソース競合を回避。
  - ストリーミングクエリインターフェースにより、大規模なデータセットも容易に処理。

- 🔑 **多様な分散主鍵（プライマリキー）アルゴリズム**
  - 順次増加アルゴリズム - ランダムなステップ幅を自由に調整し、ビジネス規模を隠蔽。
  - タイムスタンプベースアルゴリズム - 高並列シナリオに最適な選択。
  - 日付プレフィックスアルゴリズム - 時間範囲データ表示を完璧にサポート。
  - 短縮コードアルゴリズム - 短く読みやすい一意の識別子を生成。

- 🔄 **インテリジェントなスキーマ移行とデータ整合性**
  - テーブルフィールドの名称変更を正確に識別し、データ損失ゼロ。
  - ミリ秒単位でスキーマ変更を自動検出し、データ移行を完了。
  - サービスを停止することなくアップグレード可能（ゼロダウンタイム）。
  - 複雑な構造変更に対する安全な移行戦略。
  - 外部キー制約の自動検証とカスケード操作のサポートにより、参照整合性を確保。

- 🛡️ **エンタープライズ級のデータセキュリティと永続性**
  - 二重保護メカニズム：データ変更をリアルタイムに記録し、紛失を防止。
  - クラッシュ自動復旧：予期せぬ停電やクラッシュ後の未完了操作を自動復旧し、データ損失ゼロ。
  - データ一貫性の保証：一連操作の全成功か全ロールバックを保証し、データの正確性を維持。
  - アトミック演算更新：式（Expression）システムによる複雑な計算をアトミックに実行し、並行衝突を回避。
  - 即時安全な永続化：操作が成功応答した時点で、データは安全に保存済み。
  - 高強度な ChaCha20Poly1305 暗号化アルゴリズムにより機密データを保護。
  - ストレージから転送まで全行程を保護するエンドツーエンド暗号化。

- 🚀 **インテリジェントキャッシュと検索性能**
  - 多層構造のインテリジェントキャッシュメカニズムによる超高速なデータ検索。
  - ストレージエンジンと深く統合されたキャッシュ戦略。
  - 適応型スケーリングにより、データ規模が拡大しても安定した性能を維持。
  - リアルタイムなデータ変更通知により、クエリ結果を自動更新。

- 🔄 **インテリジェントなデータワークフロー**
  - マルチスペースアーキテクチャによるデータ隔離とグローバル共有の両立。
  - 計算ノード間でのインテリジェントなワークロード分散。
  - 大規模なデータトレーニングと分析のための強固な基盤を提供。


## インストール

> [!IMPORTANT]
> **v2.x からアップグレードしますか？** 重要な移行手順と重大な変更については、[v3.0 アップグレードガイド](../UPGRADE_GUIDE_v3.md) をお読みください。

`pubspec.yaml` に `tostore` 依存関係を追加します：

```yaml
dependencies:
  tostore: any # 最新バージョンを使用してください
```

## クイックスタート

> [!IMPORTANT]
> **テーブルスキーマの定義が最初のステップです**: CRUD 操作を行う前に、テーブルスキーマを定義する必要があります。具体的な定義方法はシナリオによって異なります。
> - **モバイル/デスクトップ**: [頻繁な起動シナリオでの統合](#頻繁な起動シナリオでの統合)（静的定義）を推奨します。
> - **サーバーサイド**: [サーバーサイド統合](#サーバーサイド統合)（動的作成）を推奨します。

```dart
// 1. データベースの初期化
final db = await ToStore.open();

// 2. データの挿入
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. メソッドチェーンによるクエリ (=, !=, >, <, LIKE, IN などをサポート)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// 4. 更新と削除
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. リアルタイム・リスニング (データ変更時に UI を自動更新)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('条件に一致するユーザーが更新されました: $users');
});
```

### キーバリューストア (KV)
構造化されたテーブルを定義する必要がないシナリオに適した、シンプルで実用的な機能です。高性能な KV ストアが組み込まれており、設定情報や状態などの断片的なデータの保存に使用できます。異なるスペース（Space）のデータはネイティブに隔離されていますが、グローバル共有を設定することも可能です。

```dart
// 1. キーバリューの設定 (String, int, bool, double, Map, List などをサポート)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// 2. データの取得
final theme = await db.getValue('theme'); // 'dark'

// 3. データの削除
await db.removeValue('theme');

// 4. グローバル・キーバリュー (Space を跨いで共有)
// 通常の KV データはスペースごとに独立しています。isGlobal: true を使用するとグローバル共有が可能です。
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```



## 頻繁な起動シナリオでの統合

```dart
// モバイルアプリやデスクトップクライアントなど、頻繁に起動されるシナリオに適したスキーマ定義方法
// スキーマ変更を正確に識別し、自動アップグレードとデータ移行をコードなしで実現
final db = await ToStore.open(
  schemas: [
    const TableSchema(
            name: 'global_settings',
            isGlobal: true,  // グローバルテーブルとして設定、全スペースからアクセス可能
            fields: [],
    ),
    const TableSchema(
      name: 'users', // テーブル名
      tableId: "users",  // テーブルの一意識別子。リネームを100%識別するために使用（省略可）
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id',       // プライマリキー名
      ),
      fields: [        // フィールド定義（プライマリキーを除く）
        FieldSchema(
          name: 'username', 
          type: DataType.text, 
          nullable: false, 
          unique: true,
          fieldId: 'username',  // フィールドの一意識別子（オプション）
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
      indexes: [ // インデックス定義
        IndexSchema(fields: ['username']),
        IndexSchema(fields: ['email']),
      ],
    ),
    // 外部キー制約の定義例
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
          onDelete: ForeignKeyCascadeAction.cascade,  // 削除時のカスケード削除
          onUpdate: ForeignKeyCascadeAction.cascade,  // 更新時のカスケード更新
        ),
      ],
    ),
  ],
);

// マルチスペースアーキテクチャ - 異なるユーザーのデータを完璧に隔離
await db.switchSpace(spaceName: 'user_123');
```

## サーバーサイド統合

```dart
// サーバー実行時のスキーマ一括作成 - 継続的な実行シナリオに適しています
await db.createTables([
  // 3次元空間特徴ベクトル保存用テーブル
  const TableSchema(
    name: 'spatial_embeddings',
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.timestampBased,   // 高並列書き込みに適したタイムスタンプ型 PK
    ),
    fields: [
      FieldSchema(
        name: 'video_name',
        type: DataType.text,
        nullable: false,
      ),
      FieldSchema(
        name: 'spatial_features',
        type: DataType.vector,                // ベクトル保存型
        vectorConfig: VectorFieldConfig(
          dimensions: 1024,                   // 高次元ベクトル
          precision: VectorPrecision.float32, 
        ),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['video_name'],
        unique: true,
      ),
      IndexSchema(
        type: IndexType.vector,              // ベクトルインデックス
        fields: ['spatial_features'],
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.hnsw,   // 高効率な近傍検索を実現する HNSW アルゴリズム
          distanceMetric: VectorDistanceMetric.cosine,
          parameters: {
            'M': 16,
            'efConstruction': 200,
          },
        ),
      ),
    ],
  ),
  // その他のテーブル...
]);

// オンライン・スキーマ・アップデート - サービスを止めずに更新
final taskId = await db.updateSchema('users')
  .renameTable('users_new')                // テーブル名の変更
  .modifyField(
    'username',
    minLength: 5,
    maxLength: 20,
    unique: true
  )                                        // フィールド属性の変更
  .renameField('old_name', 'new_name')     // フィールド名の変更
  .removeField('deprecated_field')         // フィールドの削除
  .addField('created_at', type: DataType.datetime)  // フィールドの追加
  .removeIndex(fields: ['age'])            // インデックスの削除
  .setPrimaryKeyConfig(                    // プライマリキー設定の変更
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
    
// 移行進捗の監視
final status = await db.queryMigrationTaskStatus(taskId);
print('移行進捗: ${status?.progressPercentage}%');


// 手動クエリキャッシュ管理 (サーバーサイド)
// 主キーやインデックスによる等値クエリ、INクエリについては、エンジン性能が非常に高く最適化されているため、通常は手動でクエリキャッシュを管理する必要はありません。

// クエリ結果を5分間手動でキャッシュ。
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// 関連データが変更された際、特定のキャッシュを無効化して整合性を確保。
await db.query('users')
    .where('is_active', '=', true)
    .clearQueryCache();

// 常に最新データを取得する必要があるクエリでは、キャッシュを明示的に無効化。
final freshUserData = await db.query('users')
    .where('is_active', '=', true)
    .noQueryCache();
```



## 高度な使い方

Tostore は、複雑なビジネス要件を満たす様々な高度な機能を提供しています：

### 複雑なクエリのネストとカスタムフィルタ
無限の条件ネストと柔軟なカスタム関数をサポート。

```dart
// 条件のネスト：(type = 'app' OR (id >= 123 OR fans >= 200))
final idCondition = QueryCondition().where('id', '>=', 123).or().where('fans', '>=', 200);

final result = await db.query('users')
    .condition(
        QueryCondition().whereEqual('type', 'app').or().condition(idCondition)
    )
    .limit(20);

// カスタム条件関数
final customResult = await db.query('users')
    .whereCustom((record) => record['tags']?.contains('オススメ') ?? false);
```

### インテリジェント・アップサート (Upsert)
存在すれば更新、存在しなければ挿入。

```dart
await db.upsert('users', {
  'email': 'john@example.com',
  'name': 'John New'
}).where('email', '=', 'john@example.com');
```


### テーブル結合とフィールド選択
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000)
    .limit(20);
```

### ストリーミングと統計
```dart
// レコード数のカウント
final count = await db.query('users').count();

// ストリーミングクエリ (大規模データに最適)
db.streamQuery('users').listen((data) => print(data));
```



### クエリと効率的なページング

> [!TIP]
> **最高のパフォーマンスを実現するために `limit` を指定してください**: クエリ時には常に `limit` を明示的に指定することを強く推奨します。省略した場合はデフォルトで1000件に制限されます。エンジン自体のクエリは非常に高速ですが、UIに関わるアプリケーションで大量のレコードをシリアライズすると、不必要なレイテンシが発生する可能性があります。

Tostore は、データ規模とパフォーマンス要件に応じて選択可能な2つのページングモードを提供します：

#### 1. オフセット・モード (Offset Mode)
データ量が少ない場合や、特定のページ番号に正確にジャンプする必要がある場合に適しています。

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // 最初の40件をスキップ
    .limit(20); // 20件取得
```
> [!TIP]
> `offset` が非常に大きくなると、データベースは大量のレコードをスキャンして破棄する必要があり、パフォーマンスが低下します。深い階層のページングには **カーソル・モード** を推奨します。

#### 2. 高性能カーソル・モード (Cursor Mode)
**大規模データや無限スクロールに適しています**。`nextCursor` を利用することで O(1) レベルの性能を実現し、ページ数に関わらず一定의 クエリ速度を保証します。

> [!IMPORTANT]
> 未インデックスのフィールドでソートした場合や、一部の複雑なクエリでは、エンジンは全表スキャンにフォールバックして `null` カーソルを返すことがあります（その特定のクエリでのページングは現在サポートされていないことを意味します）。

```dart
// 1ページ目のクエリ
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// 返されたカーソルを使用して次のページを取得
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // カーソルの位置へ直接 seek
}

// 同様に prevCursor を使用して前のページへ戻る
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| 特徴 | オフセット・モード | カーソル・モード |
| :--- | :--- | :--- |
| **クエリ性能** | ページ数と共に低下 | **常に一定 (O(1))** |
| **適用範囲** | 小規模データ、特定ページへの遷移 | **大規模データ、無限スクロール** |
| **データ一貫性** | データ変更により行が飛ぶ場合がある | **変更による重複や漏れを完璧に回避** |





## 分散アーキテクチャ

```dart
// 分散ノードの設定
final db = await ToStore.open(
  config: DataStoreConfig(
    distributedNodeConfig: const DistributedNodeConfig(
      enableDistributed: true,
      clusterId: 1,
      centralServerUrl: 'http://127.0.0.1:8080',
      accessToken: 'b7628a4f9b4d269b98649129'
    )
  )
);

// 高性能な一括挿入 (Batch Insert)
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... 大量のレコードを効率よく挿入
]);

// 大規模データセットのストリーミング処理 - メモリ消費を一定に維持
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // TB級のデータでも、メモリを圧迫せずに効率的に処理可能
  print(record);
}
```

## プライマリキーの種類と例

Tostore は、様々なシナリオに対応する多彩な分散プライマリキーアルゴリズムを提供しています：

- **順次増加型** (PrimaryKeyType.sequential)：238978991
- **タイムスタンプ型** (PrimaryKeyType.timestampBased)：1306866018836946
- **日付プレフィックス型** (PrimaryKeyType.datePrefixed)：20250530182215887631
- **短縮コード型** (PrimaryKeyType.shortCode)：9eXrF0qeXZ

```dart
// 順次増加型プライマリキーの設定例
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,
        increment: 50,
        useRandomIncrement: true, // ランダムな歩進でビジネス規模を隠蔽
      ),
    ),
    fields: [/* フィールド定義 */]
  ),
]);
```


## 式（Expression）によるアトミック操作

式システムは、型安全なアトミック・フィールド更新を提供します。全ての計算はデータベース層でアトミックに実行され、並行衝突を回避します：

```dart
// シンプルな加算：balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// 複雑な計算：total = price * quantity + tax
await db.update('orders', {
  'total': Expr.field('price') * Expr.field('quantity') + Expr.field('tax'),
}).where('id', '=', orderId);

// ネストされた計算：finalPrice = ((price * quantity) + tax) * (1 - discount)
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) * 
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// 関数を使用：price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// タイムスタンプ：updatedAt = now()
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

## トランザクション

トランザクションは複数の操作のアトミック性を保証し、一連の操作が全て成功するか、全てロールバックされることを確実にします。

**トランザクションの特徴**：
- 複数操作のアトミックな実行。
- クラッシュ後の未完了操作の自動復旧。
- コミット成功時にデータが安全に永続化。

```dart
// 基本的なトランザクション - 複数操作のアトミック・コミット
final txResult = await db.transaction(() async {
  // ユーザーの挿入
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });
  
  // 式によるアトミック更新
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');
  
  // 途中で失敗した場合、全ての変更が自動的にロールバックされます
});

if (txResult.isSuccess) {
  print('トランザクション成功');
} else {
  print('トランザクション・ロールバック: ${txResult.error?.message}');
}

// エラー時の自動ロールバック
final txResult2 = await db.transaction(() async {
  await db.insert('users', {
    'username': 'jane',
    'email': 'jane@example.com',
  });
  throw Exception('ビジネスロジックエラー'); // ロールバックをトリガー
}, rollbackOnError: true);
```

## セキュリティ設定

**データセキュリティメカニズム**：
- データの紛失を完全に防止する二重保護。
- 未完了操作の自動復旧機能。
- 操作完了時の即時永続化。
- 高強度な暗号化による機密データ保護。

> [!WARNING]
> **キー管理**: `encryptionKey` を変更すると、既存のデータが復号できなくなります（データ移行が必要な場合を除く）。キーをコード内にハードコードせず、セキュアなサーバーから取得することを推奨します。

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // 対応アルゴリズム：none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305, 
      
      // エンコーディングキー（初期化時に必須）
      encodingKey: 'Your-32-Byte-Long-Encoding-Key...', 
      
      // 重要データ暗号化キー
      encryptionKey: 'Your-Secure-Encryption-Key...',
      
      // デバイス連結 (Path-based binding)
      // 有効にすると、キーがパスやデバイス特性に紐付けられます。
      // 物理的なファイルコピーへの耐性が高まりますが、アプリの設置パス変更などでデータが復元できなくなる点に注意。
      deviceBinding: false, 
    ),
    // WAL (Write-Ahead Logging) の有効化（デフォルト：有効）
    enableJournal: true, 
    // コミット時に強制的にディスク同期（パフォーマンス重視の場合は false も可）
    persistRecoveryOnCommit: true,
  ),
);
```


## 性能と体験

### 性能仕様

- **起動速度**：1000万件以上のデータでも、一般的なスマートフォンで即座に起動・表示。
- **検索性能**：データ規模に依存せず、常に超高速な検索性能を維持。
- **データ安全**：ACIDトランザクション保証 + クラッシュリカバリでデータ損失ゼロ。

### 推奨事項

- 📱 **サンプルプロジェクト**：`example` ディレクトリに完全な Flutter アプリのサンプルがあります。
- 🚀 **本番環境**：デバッグモードより遥かに高速な「リリースモード」でのビルドを推奨します。
- ✅ **標準テスト**：全てのコア機能が標準テストをクリアしています。




Tostore がお役に立てれば、ぜひ ⭐️ をお願いします。




## ロードマップ

Tostore は、AI 時代のデータインフラを強化するために以下の機能を開発中です：

- **高次元ベクトル**：ベクトル検索と意味的検索アルゴリズムの追加。
- **マルチモーダルデータ**：生データから特徴ベクトルまでのエンドツーエンド処理。
- **グラフ構造**：ナレッジグラフや複雑なリレーションネットワークの効率的な保存と検索。





> **推奨**：モバイル開発の方には、データのリクエスト、読み込み、保存、キャッシュ、表示を自動化するフルスタック・ソリューション [Toway Framework](https://github.com/tocreator/toway) もお勧めします。




## リソース

- 📖 **ドキュメント**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **フィードバック**: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **議論**: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)


## ライセンス

本プロジェクトは MIT ライセンスの下で公開されています。詳細は [LICENSE](LICENSE) ファイルを参照してください。

---
