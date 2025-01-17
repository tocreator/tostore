# ToStore

[English](../../README.md) | [简体中文](README.zh-CN.md) | 日本語 | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![Build Status](https://github.com/tocreator/tostore/workflows/build/badge.svg)](https://github.com/tocreator/tostore/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

ToStoreは、モバイルアプリケーション向けに特別に設計された高性能ストレージエンジンです。Pure Dartで実装され、B+ツリーインデックスとインテリジェントなキャッシング戦略により、卓越したパフォーマンスを実現しています。マルチスペースアーキテクチャにより、ユーザーデータの分離とグローバルデータの共有という課題を解決し、トランザクション保護、自動修復、増分バックアップ、アイドル時のゼロコストなどのエンタープライズグレードの機能により、モバイルアプリケーションの信頼性の高いデータストレージを実現します。

## なぜToStoreを選ぶのか？

- 🚀 **究極のパフォーマンス**: 
  - B+ツリーインデックスとスマートクエリ最適化
  - インテリジェントキャッシング戦略でミリ秒レベルの応答
  - 安定したパフォーマンスでノンブロッキングな同時読み書き
- 🔄 **スマートスキーマ進化**: 
  - スキーマを通じた自動テーブル構造アップグレード
  - 手動のバージョン移行が不要
  - 複雑な変更に対応するチェーンAPI
  - ゼロダウンタイムでのアップグレード
- 🎯 **使いやすさ**: 
  - 流暢なチェーンAPIデザイン
  - SQL/Mapスタイルのクエリをサポート
  - スマートな型推論と完全なコードヒント
  - 設定不要ですぐに使用可能
- 🔄 **革新的なアーキテクチャ**: 
  - マルチユーザーシナリオに最適なマルチスペースデータ分離
  - 設定同期の課題を解決するグローバルデータ共有
  - ネストされたトランザクションをサポート
  - リソース使用を最小限に抑えるオンデマンドスペースローディング
  - 自動データ操作（upsert）
- 🛡️ **エンタープライズグレードの信頼性**: 
  - データの一貫性を保証するACIDトランザクション保護
  - クイックリカバリー機能付き増分バックアップメカニズム
  - 自動エラー修復機能付きデータ整合性検証

## クイックスタート

基本的な使用方法:

```dart
// データベースの初期化
final db = ToStore(
  version: 2, // バージョン番号が増加すると、schemasのテーブル構造が自動的に作成またはアップグレードされます
  schemas: [
    // 最新のスキーマを定義するだけで、ToStoreが自動的にアップグレードを処理します
    const TableSchema(
      name: 'users',
      primaryKey: 'id',
      fields: [
        FieldSchema(name: 'id', type: DataType.integer, nullable: false),
        FieldSchema(name: 'username', type: DataType.text, nullable: false),
        FieldSchema(name: 'email', type: DataType.text, nullable: false),
        FieldSchema(name: 'last_login', type: DataType.datetime),
      ],
      indexes: [
        IndexSchema(fields: ['username'], unique: true),
        IndexSchema(fields: ['email'], unique: true),
      ],
    ),
  ],
  // 複雑なアップグレードと移行にはdb.updateSchemaを使用できます
  // テーブル数が少ない場合は、schemasで直接データ構造を調整して自動アップグレードすることをお勧めします
  onUpgrade: (db, oldVersion, newVersion) async {
    if (oldVersion == 1) {
      await db.updateSchema('users')
          .addField("fans", type: DataType.array, comment: "フォロワー")
          .addIndex("follow", fields: ["follow", "username"])
          .removeField("last_login")
          .modifyField('email', unique: true)
          .renameField("last_login", "last_login_time");
    }
  },
);
await db.initialize(); // オプション、データベース操作の前に初期化の完了を確実にします

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