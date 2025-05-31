# Tostore

[English](../../README.md) | [简体中文](README.zh-CN.md) | 日本語 | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![Build Status](https://github.com/tocreator/tostore/workflows/build/badge.svg)](https://github.com/tocreator/tostore/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

Tostoreは、プロジェクトに深く統合されたクロスプラットフォーム分散アーキテクチャデータベースエンジンです。そのニューラルネットワークにインスパイアされたデータ処理モデルは、脳のようなデータ管理を実現します。マルチパーティション並列処理メカニズムとノード相互接続トポロジーによってインテリジェントなデータネットワークを作成し、Isolateによる並列処理はマルチコア機能を最大限に活用します。様々な分散プライマリキーアルゴリズムと無制限のノード拡張により、分散コンピューティングや大規模データトレーニングインフラストラクチャのデータレイヤーとして機能し、エッジデバイスからクラウドサーバーまでのシームレスなデータフローを可能にします。スキーマ変更の正確な検出、インテリジェントマイグレーション、ChaCha20Poly1305暗号化、マルチスペースアーキテクチャなどの機能は、モバイルアプリからサーバーサイドシステムまで、様々なアプリケーションシナリオを完璧にサポートします。

## なぜTostoreを選ぶのか？

### 1. パーティション並列処理 vs 単一ファイルストレージ
| Tostore | 従来のデータベース |
|:---------|:-----------|
| ✅ インテリジェントなパーティショニングメカニズム、適切なサイズの複数ファイルにデータを分散 | ❌ 単一データファイルでの保存、データ増加に伴い性能が直線的に低下 |
| ✅ 関連するパーティションファイルのみを読み取り、クエリパフォーマンスがデータ総量から分離 | ❌ 単一レコードの照会でも全データファイルの読み込みが必要 |
| ✅ TB級のデータ量でもミリ秒レベルの応答時間を維持 | ❌ データが5MBを超えるとモバイルデバイスでの読み書き遅延が大幅に増加 |
| ✅ リソース消費はクエリされるデータ量に比例し、総データ量ではない | ❌ リソース制約のあるデバイスはメモリ圧迫やOOMエラーの影響を受けやすい |
| ✅ Isolate技術により真のマルチコア並列処理を実現 | ❌ 単一ファイルは並列処理できず、CPUリソースの無駄 |

### 2. 組み込み統合 vs 独立データストア
| Tostore | 従来のデータベース |
|:---------|:-----------|
| ✅ Dart言語を使用し、Flutter/Dartプロジェクトとシームレスに統合 | ❌ SQLや特定のクエリ言語の学習が必要で、学習曲線が高い |
| ✅ 同じコードでフロントエンドとバックエンドをサポート、技術スタックの変更不要 | ❌ フロントエンドとバックエンドは通常、異なるデータベースとアクセス方法が必要 |
| ✅ 現代的なプログラミングスタイルに合わせたチェーンAPI、優れた開発者エクスペリエンス | ❌ SQL文字列の連結は攻撃やエラーに脆弱で、型安全性が欠如 |
| ✅ リアクティブプログラミングのサポート、UIフレームワークと自然に連携 | ❌ UIとデータレイヤーを接続するための追加適応レイヤーが必要 |
| ✅ 複雑なORMマッピング設定が不要、Dartオブジェクトを直接使用 | ❌ オブジェクトリレーショナルマッピングの複雑さ、開発・保守コストが高い |

### 3. 正確なスキーマ変更検出 vs 手動マイグレーション管理
| Tostore | 従来のデータベース |
|:---------|:-----------|
| ✅ スキーマ変更を自動検出、バージョン番号管理不要 | ❌ 手動バージョン管理と明示的なマイグレーションコードに依存 |
| ✅ テーブル/フィールド変更をミリ秒レベルで検出し、データを自動マイグレーション | ❌ バージョン間のアップグレード用にマイグレーションロジックの維持が必要 |
| ✅ テーブル/フィールドの名前変更を正確に識別し、すべての履歴データを保持 | ❌ テーブル/フィールドの名前変更によりデータ損失を招く可能性 |
| ✅ データ一貫性を確保するアトミックなマイグレーション操作 | ❌ マイグレーション中断によりデータ不整合を引き起こす可能性 |
| ✅ 完全自動化されたスキーマ更新、手動介入不要 | ❌ 複雑なアップグレードロジックとバージョン増加に伴う高い保守コスト |

### 4. マルチスペースアーキテクチャ vs 単一ストレージスペース
| Tostore | 従来のデータベース |
|:---------|:-----------|
| ✅ マルチスペースアーキテクチャ、異なるユーザーのデータを完全に分離 | ❌ 単一ストレージスペース、複数ユーザーのデータが混合保存 |
| ✅ 一行のコードでスペース切り替え、シンプルで効果的 | ❌ 複数のデータベースインスタンスまたは複雑な分離ロジックが必要 |
| ✅ 柔軟なスペース分離とグローバルデータ共有メカニズム | ❌ ユーザーデータの分離と共有のバランスが難しい |
| ✅ スペース間でデータをコピーまたは移行するためのシンプルなAPI | ❌ テナント移行やデータコピーの複雑な操作 |
| ✅ クエリが自動的に現在のスペースに制限され、追加フィルタリング不要 | ❌ 異なるユーザー向けのクエリには複雑なフィルタリングが必要 |





## 技術的ハイライト

- 🌐 **透過的クロスプラットフォームサポート**:
  - Web、Linux、Windows、Mobile、Macプラットフォーム間で一貫した体験
  - 統一されたAPIインターフェース、手間のかからないクロスプラットフォームデータ同期
  - 様々なクロスプラットフォームストレージバックエンド（IndexedDB、ファイルシステムなど）への自動適応
  - エッジコンピューティングからクラウドへのシームレスなデータフロー

- 🧠 **ニューラルネットワークにインスパイアされた分散アーキテクチャ**:
  - 相互接続されたノードのニューラルネットワークのようなトポロジー
  - 分散処理のための効率的なデータパーティショニングメカニズム
  - インテリジェントな動的ワークロードバランシング
  - 無制限のノード拡張をサポート、複雑なデータネットワークの容易な構築

- ⚡ **究極の並列処理能力**:
  - Isolatesによる真の並列読み書き、マルチコアCPU利用率の最大化
  - 複数タスクの効率を倍増させる協調マルチノードコンピュートネットワーク
  - リソース認識分散処理フレームワーク、自動パフォーマンス最適化
  - 大規模データセット処理に最適化されたストリーミングクエリインターフェース

- 🔑 **様々な分散プライマリキーアルゴリズム**:
  - 連続増分アルゴリズム - 自由に調整可能なランダムステップ長
  - タイムスタンプベースアルゴリズム - 高性能並列実行シナリオに最適
  - 日付プレフィックスアルゴリズム - 時間範囲表示のあるデータに適合
  - ショートコードアルゴリズム - 簡潔な一意識別子

- 🔄 **インテリジェントスキーママイグレーション**:
  - テーブル/フィールド名変更動作の正確な識別
  - スキーマ変更時の自動データ更新とマイグレーション
  - ゼロダウンタイムアップグレード、ビジネス運営に影響なし
  - データ損失を防止する安全なマイグレーション戦略

- 🛡️ **エンタープライズレベルセキュリティ**:
  - 機密データを保護するChaCha20Poly1305暗号化アルゴリズム
  - エンドツーエンド暗号化、保存・送信データのセキュリティ確保
  - きめ細かいデータアクセス制御

- 🚀 **インテリジェントキャッシングと検索パフォーマンス**:
  - 効率的なデータ取得のためのマルチレベルインテリジェントキャッシングメカニズム
  - アプリ起動速度を劇的に向上させるスタートアップキャッシング
  - キャッシュと深く統合されたストレージエンジン、追加同期コード不要
  - 適応的なスケーリング、データが増大しても安定したパフォーマンスを維持

- 🔄 **革新的ワークフロー**:
  - マルチスペースデータ分離、マルチテナント、マルチユーザーシナリオの完全サポート
  - コンピュートノード間のインテリジェントワークロード割り当て
  - 大規模データトレーニングと分析のための堅牢なデータベースを提供
  - 自動データストレージ、インテリジェントな更新と挿入

- 💼 **開発者体験が優先事項**:
  - 詳細なバイリンガルドキュメントとコードコメント（中国語と英語）
  - 豊富なデバッグ情報とパフォーマンスメトリクス
  - 組み込みデータ検証と破損回復機能
  - ゼロ構成のすぐに使える、クイックスタート

## クイックスタート

基本的な使用法:

```dart
// データベース初期化
final db = ToStore();
await db.initialize(); // オプション、操作前にデータベース初期化の完了を確保

// データ挿入
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
});

// データ更新
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// データ削除
await db.delete('users').where('id', '!=', 1);

// 複雑な連鎖クエリのサポート
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// 自動データストレージ、存在する場合は更新、存在しない場合は挿入
await db.upsert('users', {'name': 'John','email': 'john@example.com'})
  .where('email', '=', 'john@example.com');
// または
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});

// 効率的なレコードカウント
final count = await db.query('users').count();

// ストリーミングクエリを使用した大量データの処理
db.streamQuery('users')
  .where('email', 'like', '%@example.com')
  .listen((userData) {
    // 必要に応じて各レコードを処理し、メモリ圧力を回避
    print('ユーザー処理中: ${userData['username']}');
  });

// グローバルキー値ペアを設定
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// グローバルキー値ペアからデータを取得
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```

## モバイルアプリの例

```dart
// モバイルアプリなどの頻繁な起動シナリオに適したテーブル構造定義、テーブル構造変更の正確な検出、自動データアップグレードとマイグレーション
final db = ToStore(
  schemas: [
    const TableSchema(
      name: 'users', // テーブル名
      tableId: "users",  // 一意のテーブル識別子、オプション、名前変更要件の100%識別に使用、なくても>98%の精度率を達成可能
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id', // プライマリキー
      ),
      fields: [ // フィールド定義、プライマリキーを含まない
        FieldSchema(name: 'username', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'email', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'last_login', type: DataType.datetime),
      ],
      indexes: [ // インデックス定義
        IndexSchema(fields: ['username']),
        IndexSchema(fields: ['email']),
      ],
    ),
  ],
);

// ユーザースペースに切り替え - データ分離
await db.switchSpace(spaceName: 'user_123');
```

## バックエンドサーバーの例

```dart
await db.createTables([
      const TableSchema(
        name: 'users', // テーブル名
        primaryKeyConfig: PrimaryKeyConfig(
          name: 'id', // プライマリキー
          type: PrimaryKeyType.timestampBased,  // プライマリキータイプ
        ),
        fields: [
          // フィールド定義、プライマリキーを含まない
          FieldSchema(
              name: 'username',
              type: DataType.text,
              nullable: false,
              unique: true),
          FieldSchema(name: 'vector_data', type: DataType.blob),  // ベクトルデータストレージ
          // その他のフィールド...
        ],
        indexes: [
          // インデックス定義
          IndexSchema(fields: ['username']),
          IndexSchema(fields: ['email']),
        ],
      ),
      // その他のテーブル...
]);


// テーブル構造更新
final taskId = await db.updateSchema('users')
    .renameTable('newTableName')  // テーブル名変更
    .modifyField('username',minLength: 5,maxLength: 20,unique: true)  // フィールドプロパティ修正
    .renameField('oldName', 'newName')  // フィールド名変更
    .removeField('fieldName')  // フィールド削除
    .addField('name', type: DataType.text)  // フィールド追加
    .removeIndex(fields: ['age'])  // インデックス削除
    .setPrimaryKeyConfig(  // プライマリキー設定
      const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
    );
    
// マイグレーションタスクステータス照会
final status = await db.queryMigrationTaskStatus(taskId);  
print('マイグレーション進捗: ${status?.progressPercentage}%');
```


## 分散アーキテクチャ

```dart
// 分散ノード設定
final db = ToStore(
    config: DataStoreConfig(
        distributedNodeConfig: const DistributedNodeConfig(
            enableDistributed: true,  // 分散モードを有効化
            clusterId: 1,  // クラスターメンバーシップ設定
            centralServerUrl: 'http://127.0.0.1:8080',
            accessToken: 'b7628a4f9b4d269b98649129'))
);

// ベクトルデータのバッチ挿入
await db.batchInsert('vector', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... 何千ものレコード
]);

// 分析用大規模データセットのストリーミング処理
await for (final record in db.streamQuery('vector')
    .where('vector_name', '=', 'face_2366')
    .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
    .stream) {
  // ストリーミングインターフェースは大規模な特徴抽出と変換をサポート
  print(record);
}
```

## プライマリキーの例
様々なプライマリキーアルゴリズム、すべて分散生成をサポート、検索能力への無秩序プライマリキーの影響を避けるため、自分でプライマリキーを生成することは推奨されません。
連続プライマリキー PrimaryKeyType.sequential: 238978991
タイムスタンプベースプライマリキー PrimaryKeyType.timestampBased: 1306866018836946
日付プレフィックスプライマリキー PrimaryKeyType.datePrefixed: 20250530182215887631
ショートコードプライマリキー PrimaryKeyType.shortCode: 9eXrF0qeXZ

```dart
// 連続プライマリキー PrimaryKeyType.sequential
// 分散システム有効時、中央サーバーがノードが自己生成する範囲を割り当て、コンパクトで覚えやすく、ユーザーIDや魅力的な番号に適合
await db.createTables([
      const TableSchema(
        name: 'users',
        primaryKeyConfig: PrimaryKeyConfig(
          type: PrimaryKeyType.sequential,  // 連続プライマリキータイプ
          sequentialConfig:  SequentialIdConfig(
              initialValue: 10000, // 自動増分開始値
              increment: 50,  // 増分ステップ
              useRandomIncrement: true,  // ビジネスボリュームの露出を避けるためランダムステップを使用
            ),
        ),
        // フィールドとインデックス定義...
        fields: []
      ),
      // その他のテーブル...
 ]);
```


## セキュリティ設定

```dart
// テーブルとフィールドの名前変更 - 自動認識とデータ保存
final db = ToStore(
      config: DataStoreConfig(
        enableEncoding: true, // テーブルデータの安全なエンコーディングを有効化
        encodingKey: 'YouEncodingKey', // エンコーディングキー、任意に調整可能
        encryptionKey: 'YouEncryptionKey', // 暗号化キー、注意: これを変更すると古いデータの復号化ができなくなります
      ),
    );
```

## パフォーマンステスト

Tostore 2.0は線形パフォーマンススケーラビリティを実現し、並列処理、パーティショニングメカニズム、分散アーキテクチャの基本的な変更がデータ検索能力を大幅に向上させ、大規模なデータ成長でもミリ秒レベルの応答時間を提供します。大規模データセットの処理には、ストリーミングクエリインターフェースがメモリリソースを枯渇させることなく、大量のデータボリュームを処理できます。



## 将来の計画
Tostoreはマルチモーダルデータ処理とセマンティック検索に適応するため、高次元ベクトルのサポートを開発中です。


私たちの目標はデータベースを作成することではありません。Tostoreは単にTowayフレームワークから抽出されたコンポーネントで、あなたの考慮のために提供されています。モバイルアプリケーションを開発している場合は、Flutterアプリケーション開発のフルスタックソリューションをカバーする統合エコシステムを持つTowayフレームワークの使用をお勧めします。Towayを使用すれば、基礎となるデータベースに触れる必要はなく、すべてのクエリ、ロード、ストレージ、キャッシング、データ表示操作はフレームワークによって自動的に実行されます。
Towayフレームワークについての詳細は、[Towayリポジトリ](https://github.com/tocreator/toway)をご覧ください。

## ドキュメント

詳細なドキュメントについては、[Wiki](https://github.com/tocreator/tostore)をご覧ください。

## サポートとフィードバック

- 問題を提出する: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- ディスカッションに参加: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- コード貢献: [Contributing Guide](CONTRIBUTING.md)

## ライセンス

このプロジェクトはMITライセンスの下でライセンスされています - 詳細は[LICENSE](LICENSE)ファイルをご覧ください。

---

<p align="center">Tostoreが役立つと思われる場合は、⭐️をお願いします</p>
