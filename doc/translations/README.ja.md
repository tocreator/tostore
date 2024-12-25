# ToStore

[English](../../README.md) | [简体中文](README.zh-CN.md) | 日本語 | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

ToStore は、モバイルアプリケーション向けに特別に設計された高性能ストレージエンジンです。Pure Dartで実装され、B+ツリーインデックスとインテリジェントなキャッシング戦略により、卓越したパフォーマンスを実現しています。マルチスペースアーキテクチャにより、ユーザーデータの分離とグローバルデータの共有という課題を解決し、トランザクション保護、自動修復、増分バックアップ、アイドル時のゼロコストなどのエンタープライズグレードの機能により、モバイルアプリケーションの信頼性の高いデータストレージを実現します。

## なぜ ToStore を選ぶのか？

- 🚀 **究極のパフォーマンス**: 
  - スマートなクエリ最適化を備えたB+ツリーインデックス
  - ミリ秒レベルの応答を実現するインテリジェントなキャッシング戦略
  - 安定したパフォーマンスを持つノンブロッキング同時読み書き
- 🎯 **使いやすさ**: 
  - 流暢なチェーン可能なAPI設計
  - SQL/Mapスタイルのクエリをサポート
  - 完全なコードヒントを備えたスマートな型推論
  - ゼロコンフィグで、すぐに使用可能
- 🔄 **革新的なアーキテクチャ**: 
  - マルチユーザーシナリオに最適なマルチスペースデータ分離
  - 設定同期の課題を解決するグローバルデータ共有
  - ネストされたトランザクションをサポート
  - リソース使用を最小限に抑えるオンデマンドスペースローディング
- 🛡️ **エンタープライズグレードの信頼性**: 
  - データの一貫性を保証するACIDトランザクション保護
  - クイックリカバリー機能付き増分バックアップメカニズム
  - 自動エラー修復機能付きデータ整合性検証

## クイックスタート

基本的な使用方法:

```dart
// データベースの初期化
final db = ToStore(
  version: 1,
  onCreate: (db) async {
    // テーブルの作成
    await db.createTable(
      'users',
      TableSchema(
        primaryKey: 'id',
        fields: [
          FieldSchema(name: 'id', type: DataType.integer, nullable: false),
          FieldSchema(name: 'name', type: DataType.text, nullable: false),
          FieldSchema(name: 'age', type: DataType.integer),
          FieldSchema(name: 'tags', type: DataType.array),
        ],
        indexes: [
          IndexSchema(fields: ['name'], unique: true),
        ],
      ),
    );
  },
);
await db.initialize(); // オプション、操作前にデータベースの初期化を確実に行います

// データの挿入
await db.insert('users', {
  'id': 1,
  'name': 'John',
  'age': 30,
});

// データの更新
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// データの削除
await db.delete('users').where('id', '!=', 1);

// 複雑な条件を持つチェーンクエリ
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// レコード数のカウント
final count = await db.query('users').count();

// SQLスタイルのクエリ
final users = await db.queryBySql(
  'users',
  where: 'age > 20 AND name LIKE "%John%" OR id IN (1, 2, 3)',
  limit: 10
);

// Mapスタイルのクエリ
final users = await db.queryByMap(
  'users',
  where: {
    'age': {'>=': 30},
    'name': {'like': '%John%'},
  },
  orderBy: ['age'],
  limit: 10,
);

// バッチ挿入
await db.batchInsert('users', [
  {'id': 1, 'name': 'John', 'age': 30},
  {'id': 2, 'name': 'Mary', 'age': 25},
]);
```

## マルチスペースアーキテクチャ

ToStoreのマルチスペースアーキテクチャにより、マルチユーザーデータ管理が容易になります：

```dart
// ユーザースペースに切り替え
await db.switchBaseSpace(spaceName: 'user_123');

// ユーザーデータのクエリ
final followers = await db.query('followers');

// キーバリューデータの設定または更新、isGlobal: true はグローバルデータを意味します
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// グローバルキーバリューデータの取得
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```


### データの自動保存

```dart
// 条件による自動保存
await db.upsert('users', {'name': 'John'})
  .where('email', '=', 'john@example.com');

// 主キーによる自動保存
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});
```


## パフォーマンス

バッチ書き込み、ランダムな読み書き、条件付きクエリを含む高並行シナリオにおいて、ToStoreは他のDart/Flutter向けの主要なデータベースを大きく上回る優れたパフォーマンスを示しています。

## その他の機能

- 💫 エレガントなチェーン可能なAPI
- 🎯 スマートな型推論
- 📝 完全なコードヒント
- 🔐 自動増分バックアップ
- 🛡️ データ整合性検証
- 🔄 クラッシュ自動復旧
- 📦 スマートデータ圧縮
- 📊 自動インデックス最適化
- 💾 階層型キャッシング戦略

私たちの目標は単なるデータベースの作成ではありません。ToStoreはTowayフレームワークから抽出された代替ソリューションです。モバイルアプリケーションを開発している場合は、完全なFlutter開発エコシステムを提供するTowayフレームワークの使用をお勧めします。Towayを使用すれば、基礎となるデータベースを直接扱う必要はありません - データのリクエスト、ロード、ストレージ、キャッシング、表示はすべてフレームワークによって自動的に処理されます。
Towayフレームワークの詳細については、[Towayリポジトリ](https://github.com/tocreator/toway)をご覧ください。

## ドキュメント

詳細なドキュメントについては、[Wiki](https://github.com/tocreator/tostore)をご覧ください。

## サポート＆フィードバック

- Issue提出: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- ディスカッションへの参加: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- コントリビュート: [Contributing Guide](CONTRIBUTING.md)

## ライセンス

このプロジェクトはMITライセンスの下で供されています - 詳細は[LICENSE](LICENSE)ファイルをご覧ください。

---

<p align="center">ToStoreが役立つと感じた場合は、⭐️をお願いします</p> 