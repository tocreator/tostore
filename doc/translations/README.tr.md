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
  <a href="README.ja.md">日本語</a> | 
  <a href="README.ko.md">한국어</a> | 
  <a href="README.es.md">Español</a> | 
  <a href="README.pt-BR.md">Português (Brasil)</a> | 
  <a href="README.ru.md">Русский</a> | 
  <a href="README.de.md">Deutsch</a> | 
  <a href="README.fr.md">Français</a> | 
  <a href="README.it.md">Italiano</a> | 
  Türkçe
</p>


## Hızlı Gezinti

- [Neden ToStore?](#why-tostore) | [Temel Özellikler](#key-features) | [Kurulum](#installation) | [Hızlı Başlangıç](#quick-start)
- [Şema Tanımlama](#schema-definition) | [Mobil/Masaüstü Entegrasyonu](#mobile-integration) | [Sunucu Tarafı Entegrasyonu](#server-integration)
- [Vektör ve ANN Arama](#vector-advanced) | [Tablo Düzeyinde TTL](#ttl-config) | [Sorgu ve Sayfalama](#query-pagination) | [Yabancı Anahtarlar](#foreign-keys) | [Sorgu İşleçleri](#query-operators)
- [Dağıtık Mimari](#distributed-architecture) | [Birincil Anahtar Örnekleri](#primary-key-examples) | [Atomik İfade İşlemleri](#atomic-expressions) | [İşlemler (Transactions)](#transactions) | [Veritabanı Yönetimi ve Bakım](#database-maintenance) | [Yedekleme ve Geri Yükleme](#backup-restore) | [Hata Yönetimi](#error-handling) | [Log geri çağrısı ve veritabanı tanısı](#logging-diagnostics)
- [Güvenlik Yapılandırması](#security-config) | [Performans](#performance) | [Kaynaklar](#more-resources)


<a id="why-tostore"></a>
## Neden ToStore?

ToStore, AGI çağı ve uç zeka (edge intelligence) senaryoları için tasarlanmış modern bir veri motorudur. Dağıtık sistemleri, çok modlu füzyonu, ilişkisel yapılandırılmış verileri, yüksek boyutlu vektörleri ve yapılandırılmamış veri depolamayı yerel olarak destekler. Sinir ağı benzeri bir temel mimariye dayanan düğümler, yüksek özerkliğe ve esnek yatay ölçeklenebilirliğe sahiptir ve uç ile bulut arasında birden fazla platformda sorunsuz iş birliği için esnek bir veri topolojisi ağı oluşturur. ACID işlemlerini, karmaşık ilişkisel sorguları (JOIN, kademeli yabancı anahtarlar), tablo düzeyinde TTL'yi ve toplama hesaplamalarını sunar. Birden fazla dağıtık birincil anahtar algoritmasını, atomik ifadeleri, şema değişikliği tanımlamayı, şifreleme korumasını, çoklu alan veri izolasyonunu, kaynağa duyarlı akıllı yük planlamasını ve felaket/çökme sonrası otomatik kurtarmayı içerir.

Bilişimin ağırlık merkezi uç zekaya doğru kaymaya devam ederken, temsilciler ve sensörler gibi çeşitli terminaller artık sadece "içerik görüntüleme" cihazları değil; yerel üretim, çevre algılama, gerçek zamanlı karar verme ve veri iş birliğinden sorumlu akıllı düğümler haline gelmektedir. Temel mimarileri ve eklenti tipi uzantılarıyla sınırlı olan geleneksel veritabanı çözümleri, yüksek frekanslı yazmalar, devasa veriler, vektör arama ve iş birliğine dayalı üretimle karşılaşıldığında uç zeka ve bulut uygulamalarının gerektirdiği düşük gecikme ve kararlılık gereksinimlerini karşılamakta zorlanmaktadır.

ToStore, devasa verileri, karmaşık yerel yapay zeka üretimini ve büyük ölçekli veri akışlarını desteklemek için uca yeterli dağıtık yetenekler kazandırır. Uç ve bulut düğümleri arasındaki derin akıllı iş birliği; sürükleyici AR/VR füzyonu, çok modlu etkileşim, anlamsal vektörler ve mekansal modelleme gibi senaryolar için güvenilir bir veri temeli sağlar.


<a id="key-features"></a>
## Temel Özellikler

- 🌐 **Birleşik Çoklu Platform Veri Motoru**
  - Mobil, Masaüstü, Web ve Sunucu için birleşik API.
  - İlişkisel yapılandırılmış verileri, yüksek boyutlu vektörleri ve yapılandırılmamış veri depolamayı destekler.
  - Yerel depolamadan uç-bulut iş birliğine kadar veri yaşam döngüleri için idealdir.

- 🧠 **Sinir Ağı Benzeri Dağıtık Mimari**
  - Düğümlerin yüksek özerkliği; birbirine bağlı iş birliği esnek veri topolojileri oluşturur.
  - Düğüm iş birliğini ve esnek yatay ölçeklenebilirliği destekler.
  - Akıllı uç düğümleri ve bulut arasında derin ara bağlantı.

- ⚡ **Paralel Yürütme ve Kaynak Planlama**
  - Yüksek kullanılabilirlik ile kaynağa duyarlı akıllı yük planlaması.
  - Çok düğümlü paralel iş birliğine dayalı bilgi işlem ve görev ayrıştırma.

- 🔍 **Yapılandırılmış Sorgu ve Vektör Arama**
  - Karmaşık koşullu sorguları, JOIN'leri, toplama hesaplamalarını ve tablo düzeyinde TTL'yi destekler.
  - Vektör alanlarını, vektör indekslerini ve Yakın Komşu (ANN) aramasını destekler.
  - Yapılandırılmış ve vektör verileri aynı motor içinde iş birliği içinde kullanılabilir.

- 🔑 **Birincil Anahtarlar, İndeksleme ve Şema Gelişimi**
  - Yerleşik ardışık artış, zaman damgası, tarih ön eki ve kısa kod PK algoritmaları.
  - Benzersiz indeksleri, bileşik indeksleri, vektör indekslerini ve yabancı anahtar kısıtlamalarını destekler.
  - Şema değişikliklerini akıllıca tanımlar ve veri geçişini otomatikleştirir.

- 🛡️ **İşlemler, Güvenlik ve Kurtarma**
  - ACID işlemlerini, atomik ifade güncellemelerini ve kademeli yabancı anahtarları sunar.
  - Çökme kurtarma, kalıcı flaş yazma ve veri tutarlılığı garantilerini destekler.
  - ChaCha20-Poly1305 ve AES-256-GCM şifrelemeyi destekler.

- 🔄 **Çoklu Alan (Multi-Space) ve Veri İş Akışı**
  - Yapılandırılabilir küresel paylaşımla Alanlar (Spaces) aracılığıyla veri izolasyonunu destekler.
  - Gerçek zamanlı sorgu dinleyicileri, çok seviyeli akıllı önbelleğe alma ve imleç sayfalama.
  - Çok kullanıcılı, yerel öncelikli ve çevrimdışı iş birliği uygulamaları için mükemmeldir.


<a id="installation"></a>
## Kurulum

> [!IMPORTANT]
> **v2.x'ten mi yükseltiyorsunuz?** Kritik geçiş adımları ve önemli değişiklikler için [v3.x Yükseltme Kılavuzunu](../UPGRADE_GUIDE_v3.md) okuyun.

`pubspec.yaml` dosyanıza bağımlılık olarak `tostore` ekleyin:

```yaml
dependencies:
  tostore: any # En son sürümü kullanın
```

<a id="quick-start"></a>
## Hızlı Başlangıç

> [!TIP]
> **Yapılandırılmış ve yapılandırılmamış verilerin birlikte depolanmasını destekler**
> Depolama yöntemi nasıl seçilmeli?
> 1. **Temel iş verileri**: [Şema Tanımlama](#schema-definition) önerilir. Karmaşık sorgular, kısıt doğrulamaları, ilişkiler ve yüksek güvenlik gereksinimleri için uygundur. Bütünlük mantığını motora indirmek, uygulama katmanındaki geliştirme ve bakım maliyetini belirgin şekilde azaltır.
> 2. **Dinamik/dağınık veriler**: Doğrudan [Anahtar-Değer Depolama (KV)](#quick-start) kullanabilir veya tabloda `DataType.json` alanları tanımlayabilirsiniz. Yapılandırma erişimi ve dağınık durum yönetimi için uygundur; hızlı başlangıç ve yüksek esneklik sağlar.

### Yapılandırılmış tablo modu (Table)
CRUD işlemleri için tablo şemasının önceden oluşturulması gerekir (bkz. [Şema Tanımlama](#schema-definition)). Senaryoya göre önerilen entegrasyon yaklaşımı:
- **Mobil/Masaüstü**: [Sık başlatılan senaryolar](#mobile-integration) için, örnek başlatılırken `schemas` geçirilmesi önerilir.
- **Sunucu/Ajan**: [Sürekli çalışan senaryolar](#server-integration) için, tabloların `createTables` ile dinamik olarak oluşturulması önerilir.

```dart
// 1. Veritabanını başlatın
final db = await ToStore.open();

// 2. Veri ekleyin
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. Zincirleme Sorgulamalar ([Sorgu İşleçleri](#query-operators) kısmına bakın; =, !=, >, <, LIKE, IN vb. destekler)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// 4. Güncelleme ve Silme
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. Gerçek zamanlı dinleme (Veri değiştiğinde UI otomatik olarak güncellenir)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Eşleşen kullanıcılar güncellendi: $users');
});
```

### Anahtar-Değer Depolama (KV)
Yapılandırılmış tablolara ihtiyaç duymayan senaryolar için uygundur. Basit ve pratiktir; yapılandırma, durum ve diğer dağınık veriler için yerleşik yüksek performanslı bir KV deposu içerir. Farklı Alanlardaki (Space) veriler varsayılan olarak izoledir ancak küresel paylaşım için yapılandırılabilir.

```dart
final db = await ToStore.open();

// Anahtar-değer çiftlerini ayarlayın (String, int, bool, double, Map, List vb. destekler)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// Veriyi al
final theme = await db.getValue('theme'); // 'dark'

// Veriyi sil
await db.removeValue('theme');

// Küresel anahtar-değer (Alanlar arası paylaşılır)
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```


<a id="schema-definition"></a>
## Şema Tanımlama
**Tek seferlik tanım, motorun uçtan uca otomatik yönetimi üstlenmesini sağlar ve uygulamayı ağır doğrulama bakım yükünden uzun vadede kurtarır.**

Aşağıdaki mobil, sunucu ve ajan örnekleri burada tanımlanan `appSchemas` yapısını yeniden kullanır.

### TableSchema Genel Bakış

```dart
const userSchema = TableSchema(
  name: 'users', // Tablo adı, zorunlu
  tableId: 'users', // Benzersiz kimlik, isteğe bağlı; yeniden adlandırmayı %100 doğru algılamak için
  primaryKeyConfig: PrimaryKeyConfig(
    name: 'id', // PK alan adı, varsayılan 'id'
    type: PrimaryKeyType.sequential, 
    sequentialConfig: SequentialIdConfig(
      initialValue: 1000, 
      increment: 1, 
      useRandomIncrement: false, 
    ),
  ),
  fields: [
    FieldSchema(
      name: 'username',
      type: DataType.text,
      nullable: false,
      minLength: 3,
      maxLength: 32,
      unique: true,
      fieldId: 'username', 
      comment: 'Giriş adı', 
    ),
    FieldSchema(
      name: 'status',
      type: DataType.integer,
      minValue: 0,
      maxValue: 150,
      defaultValue: 0,
      createIndex: true, // Performans için indeks oluşturur
    ),
    FieldSchema(
      name: 'created_at',
      type: DataType.datetime,
      nullable: false,
      defaultValueType: DefaultValueType.currentTimestamp, // Otomatik zaman damgası
      createIndex: true,
    ),
  ],
  indexes: const [
    IndexSchema(
      indexName: 'idx_users_status_created_at',
      fields: ['status', 'created_at'],
      unique: false,
      type: IndexType.btree,
    ),
  ],
  foreignKeys: const [], // Yabancı anahtar kısıtlamaları (ilgili bölüme bakın)
  isGlobal: false, // Küresel tablo (tüm Alanlarda erişilebilir)
  ttlConfig: null, // Tablo düzeyinde TTL (ilgili bölüme bakın)
);
```

`DataType`; `integer`, `bigInt`, `double`, `text`, `blob`, `boolean`, `datetime`, `array`, `json`, `vector` tiplerini destekler. 

### Kısıtlamalar ve Otomatik Doğrulama

Genel doğrulama kurallarını `FieldSchema` aracılığıyla doğrudan şemaya yazabilirsiniz:

- `nullable: false`: Null olmayan kısıtlaması.
- `minLength` / `maxLength`: Metin uzunluğu kısıtlamaları.
- `minValue` / `maxValue`: Sayısal aralık kısıtlamaları.
- `defaultValue`: Varsayılan değerler.
- `unique`: Benzersizlik (benzersiz bir indeks oluşturur).
- `createIndex`: Sık kullanılan filtreler veya sıralama için bir indeks oluşturur.


<a id="mobile-integration"></a>
## Mobil/Masaüstü Entegrasyonu

```dart
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

final docDir = await getApplicationDocumentsDirectory();
final dbRoot = p.join(docDir.path, 'common');

final db = await ToStore.open(
  dbPath: dbRoot,
  schemas: appSchemas,
);

// Çoklu Alan - Farklı kullanıcıların verilerini izole edin
await db.switchSpace(spaceName: 'user_123');
```

### Giriş Durumunu Koruma ve Oturum Kapatma (Aktif Alan)

Yeniden başlatmanın ardından mevcut kullanıcıyı korumak için **Aktif Alan (Active Space)** kullanın.

- **Korumak**: Alanı değiştirirken aktif olarak işaretleyin (`keepActive: true`).
- **Oturum Kapatma**: Veritabanını `keepActiveSpace: false` ile kapatın.

```dart
// Giriş sonrası: Kullanıcı alanını aktif olarak kaydedin
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// Oturum kapatma: Bir sonraki başlatma için aktif alanı temizleyin
await db.close(keepActiveSpace: false);
```


<a id="server-integration"></a>
## Sunucu Tarafı Entegrasyonu

```dart
final db = await ToStore.open();

// Başlangıçta tablo yapısını oluşturun veya doğrulayın
await db.createTables(appSchemas);

// Çevrimiçi şema güncellemeleri
final taskId = await db.updateSchema('users')
  .renameTable('users_new')
  .modifyField('username', minLength: 5, unique: true)
  .renameField('old', 'new')
  .removeField('deprecated')
  .addField('created_at', type: DataType.datetime)
  .removeIndex(fields: ['age']);
    
// Geçiş ilerlemesini izleme
final status = await db.queryMigrationTaskStatus(taskId);
print('İlerleme: ${status?.progressPercentage}%');


// Manuel Sorgu Önbelleği Yönetimi
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// Belirli önbelleği geçersiz kılın
await db.query('users').where('is_active', '=', true).clearQueryCache();
```


<a id="advanced-usage"></a>
## Gelişmiş Kullanım


<a id="vector-advanced"></a>
### Vektör ve ANN Arama

```dart
await db.createTables([
  const TableSchema(
    name: 'embeddings',
    fields: [
      FieldSchema(name: 'document_title', type: DataType.text, nullable: false),
      FieldSchema(
        name: 'embedding',
        type: DataType.vector,
        vectorConfig: VectorFieldConfig(dimensions: 128, precision: VectorPrecision.float32),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['embedding'],
        type: IndexType.vector,
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh,
          distanceMetric: VectorDistanceMetric.cosine,
        ),
      ),
    ],
  ),
]);

final queryVector = VectorData.fromList(List.generate(128, (i) => i * 0.01));

// Vektör arama
final results = await db.vectorSearch(
  'embeddings', 
  fieldName: 'embedding', 
  queryVector: queryVector, 
  topK: 5,
);
```


<a id="ttl-config"></a>
### Tablo Düzeyinde TTL (Otomatik Zaman Aşımı)

Günlükler veya olaylar için: süresi dolan veriler arka planda otomatik olarak temizlenir.

```dart
const TableSchema(
  name: 'event_logs',
  fields: [/* ... */],
  ttlConfig: TableTtlConfig(ttlMs: 7 * 24 * 60 * 60 * 1000), // 7 gün sakla
);
```


### Akıllı Yazma (Upsert)
PK veya benzersiz anahtar varsa günceller, yoksa ekler.

```dart
await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});
```


### JOIN ve Toplama (Aggregation)
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .limit(20);

// Toplama fonksiyonları
final count = await db.query('users').count();
final sum = await db.query('orders').sum('total');
```


<a id="query-pagination"></a>
### Sorgu ve Etkili Sayfalama

- **Offset Modu**: Küçük veri kümeleri veya sayfa atlamaları için.
- **İmleç (Cursor) Modu**: Dev Veriler ve sonsuz kaydırma için önerilir (O(1)).

```dart
final page1 = await db.query('users').orderByDesc('id').limit(20);

if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor);
}
```


<a id="foreign-keys"></a>
### Yabancı Anahtarlar ve Kademeli İşlemler

```dart
foreignKeys: [
    ForeignKeySchema(
      name: 'fk_posts_user',
      fields: ['user_id'],
      referencedTable: 'users',
      referencedFields: ['id'],
      onDelete: ForeignKeyCascadeAction.cascade, // Kullanıcı silinirse gönderileri siler
    ),
],
```


<a id="query-operators"></a>
### Sorgu İşleçleri

Desteklenenler: `=`, `!=`, `>`, `>=`, `<`, `<=`, `IN`, `NOT IN`, `BETWEEN`, `LIKE`, `IS NULL`, `IS NOT NULL`.

```dart
db.query('users').whereEqual('name', 'John').whereGreaterThan('age', 18).limit(20);
```


<a id="atomic-expressions"></a>
## Atomik İfadeler

Eşzamanlılık çakışmalarını önlemek için veritabanı düzeyinde hesaplamalar:

```dart
// balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', id);

// Bir Upsert içerisinde: güncellemeyse artır, değilse 1 yap
await db.upsert('counters', {
  'key': 'visits',
  'count': Expr.ifElse(Expr.isUpdate(), Expr.field('count') + 1, 1),
});
```


<a id="transactions"></a>
## İşlemler (Transactions)

Atomikliği garanti eder: ya tüm işlemler başarılı olur ya da hepsi geri alınır.

```dart
final txResult = await db.transaction(() async {
  await db.insert('users', {...});
  await db.update('users', {...});
});
```


<a id="database-maintenance"></a>
### Veritabanı Yönetimi ve Bakım

Aşağıdaki API'ler veritabanı yönetimi, tanılama ve bakım işleri için uygundur:

- **Tablo bakımı**
  `createTable(schema)`: Çalışma zamanında tek bir tablo oluşturur.
  `getTableSchema(tableName)`: Şu anda etkin olan şema tanımını okur.
  `getTableInfo(tableName)`: Kayıt sayısı, indeks sayısı, dosya boyutu, oluşturulma zamanı ve global tablo durumu gibi istatistikleri döndürür.
  `clear(tableName)`: Şema, indeksler ve kısıtlamalar korunurken tüm verileri temizler.
  `dropTable(tableName)`: Şema ve veriler dahil tüm tabloyu kaldırır.
- **Alan (Space) yönetimi**
  `currentSpaceName`: Geçerli aktif alan adını döndürür.
  `listSpaces()`: Mevcut örnekteki tüm alanları listeler.
  `getSpaceInfo(useCache: true)`: Geçerli alanın istatistiklerini getirir; en güncel veriler için `useCache: false` kullanın.
  `deleteSpace(spaceName)`: Bir alanı siler. `default` alanı ve şu anda aktif olan alan silinemez.
- **Örnek meta verileri**
  `config`: Etkin `DataStoreConfig` değerini okur.
  `instancePath`: Örneğin son depolama dizinini döndürür.
  `getVersion()` / `setVersion(version)`: İş mantığınız için tanımladığınız sürüm numarasını okur ve yazar. Bu değer motorun dahili mantığında kullanılmaz.
- **Bakım işlemleri**
  `flush(flushStorage: true)`: Bekleyen yazmaları diske yazar. `true` olduğunda alttaki depolama tamponlarını da temizler.
  `deleteDatabase()`: Geçerli veritabanı örneğini ve dosyalarını siler. Yıkıcı bir işlemdir.
- **Birleşik tanı girişi**
  `db.status.memory()`: Önbellek ve bellek kullanımını inceler.
  `db.status.space()`: Geçerli alanın genel durumunu inceler.
  `db.status.table(tableName)`: Belirli bir tablonun tanı bilgilerini inceler.
  `db.status.config()`: Etkin yapılandırma anlık görüntüsünü inceler.
  `db.status.migration(taskId)`: Şema göçü görevinin durumunu inceler.

```dart
final spaces = await db.listSpaces();
final spaceInfo = await db.getSpaceInfo(useCache: false);
final tableInfo = await db.getTableInfo('users');
await db.flush();

print(spaces);
print(spaceInfo.toJson());
print(tableInfo?.toJson());
```


<a id="backup-restore"></a>
### Yedekleme ve Geri Yükleme

Yerel içe/dışa aktarma, kullanıcı verisi taşıma, geri alma ve operasyonel anlık görüntüler için uygundur:

- `backup(compress: true, scope: ...)`: Bir yedek oluşturur ve dosya yolunu döndürür. `compress: true` sıkıştırılmış bir paket üretir ve `scope` yedekleme kapsamını belirler.
- `restore(backupPath, deleteAfterRestore: false, cleanupBeforeRestore: true)`: Yedekten geri yükler. `cleanupBeforeRestore: true` ilgili eski verileri önce temizler, `deleteAfterRestore: true` ise başarılı geri yüklemeden sonra dosyayı siler.
- `BackupScope.database`: Tüm alanlar, global tablolar ve ilgili meta veriler dahil tüm örneği yedekler.
- `BackupScope.currentSpace`: Global tablolar hariç yalnızca geçerli alanı yedekler.
- `BackupScope.currentSpaceWithGlobal`: Geçerli alanı global tablolarla birlikte yedekler.

```dart
final backupPath = await db.backup(
  compress: true,
  scope: BackupScope.currentSpaceWithGlobal,
);

final restored = await db.restore(backupPath);
print(backupPath);
print(restored);
```


<a id="error-handling"></a>
### Hata Yönetimi

ToStore, veri işlemleri için birleşik bir yanıt modeli kullanır:

- `ResultType`: Dallanma mantığı için kararlı durum enum'u.
- `result.code`: `ResultType` ile ilişkili sayısal kod.
- `result.message`: Okunabilir hata açıklaması.
- `successKeys` / `failedKeys`: Toplu işlemlerde başarılı ve başarısız birincil anahtar listeleri.

```dart
final result = await db.insert('users', {
  'username': 'john',
  'email': 'john@example.com',
});

if (!result.isSuccess) {
  switch (result.type) {
    case ResultType.notFound:
      print('Kaynak bulunamadı: ${result.message}');
      break;
    case ResultType.notNullViolation:
    case ResultType.validationFailed:
      print('Doğrulama başarısız: ${result.message}');
      break;
    case ResultType.primaryKeyViolation:
    case ResultType.uniqueViolation:
      print('Kısıt çakışması: ${result.message}');
      break;
    case ResultType.foreignKeyViolation:
      print('Yabancı anahtar kısıtı başarısız: ${result.message}');
      break;
    case ResultType.resourceExhausted:
    case ResultType.timeout:
      print('Sistem meşgul, lütfen daha sonra tekrar deneyin: ${result.message}');
      break;
    case ResultType.ioError:
    case ResultType.dbError:
      print('Depolama hatası, lütfen loglayın: ${result.message}');
      break;
    default:
      print('Tür: ${result.type}, Kod: ${result.code}, Mesaj: ${result.message}');
  }
}
```

**Yaygın durum kodları**:
Başarı `0` değeridir; negatif değerler hataları gösterir.
- `ResultType.success` (`0`): İşlem başarılı.
- `ResultType.partialSuccess` (`1`): Toplu işlem kısmen başarılı.
- `ResultType.unknown` (`-1`): Bilinmeyen hata.
- `ResultType.uniqueViolation` (`-2`): Benzersiz indeks çakışması.
- `ResultType.primaryKeyViolation` (`-3`): Birincil anahtar çakışması.
- `ResultType.foreignKeyViolation` (`-4`): Yabancı anahtar kısıtı ihlali.
- `ResultType.notNullViolation` (`-5`): Zorunlu alan eksik veya `null` kabul edilmiyor.
- `ResultType.validationFailed` (`-6`): Uzunluk, aralık, biçim veya kısıt doğrulaması başarısız.
- `ResultType.notFound` (`-11`): Hedef tablo, alan veya kaynak bulunamadı.
- `ResultType.resourceExhausted` (`-15`): Sistem kaynakları yetersiz; yükü azaltın veya tekrar deneyin.
- `ResultType.ioError` (`-90`): Dosya sistemi veya depolama I/O hatası.
- `ResultType.dbError` (`-91`): Dahili veritabanı hatası.
- `ResultType.timeout` (`-92`): İşlem zaman aşımına uğradı.

### İşlem Sonucu Yönetimi

```dart
final txResult = await db.transaction(() async {
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
  });
});

if (txResult.isFailed) {
  print('İşlem hata türü: ${txResult.error?.type}');
  print('İşlem hata mesajı: ${txResult.error?.message}');
}
```

İşlem hata türleri:
- `TransactionErrorType.operationError`: Alan doğrulama hatası, geçersiz kaynak durumu veya diğer iş kuralı istisnaları gibi işlem içindeki normal operasyon hatası.
- `TransactionErrorType.integrityViolation`: Birincil anahtar, benzersiz anahtar, yabancı anahtar veya not-null gibi bütünlük ya da kısıt çakışması.
- `TransactionErrorType.timeout`: İşlem zaman aşımına uğradı.
- `TransactionErrorType.io`: Alttaki depolama ya da dosya sisteminde I/O hatası.
- `TransactionErrorType.conflict`: İşlem bir çakışma nedeniyle başarısız oldu.
- `TransactionErrorType.userAbort`: Kullanıcı tarafından tetiklenen iptal. İstisna fırlatarak manuel iptal şu anda desteklenmiyor.
- `TransactionErrorType.unknown`: Diğer tüm beklenmeyen hatalar.


<a id="logging-diagnostics"></a>
### Log geri çağrısı ve veritabanı tanısı

ToStore, `LogConfig.setConfig(...)` aracılığıyla başlangıç, kurtarma, otomatik geçiş ve çalışma zamanındaki kısıt çakışması loglarını uygulama katmanına topluca geri iletebilir.

- `onLogHandler`, geçerli `enableLog` ve `logLevel` ile filtrelenen tüm logları alır.
- Başlatma ve otomatik geçiş aşamasındaki logların da yakalanabilmesi için `LogConfig.setConfig(...)` çağrısını ilklendirmeden önce yapın.

```dart
  // Log parametrelerini veya callback'i yapılandır
  LogConfig.setConfig(
    enableLog: true,
    logLevel: debugMode ? LogLevel.debug : LogLevel.warn,
    publicLabel: 'my_app_db',
    onLogHandler: (message, type, label) {
      // Üretim ortamında warn/error backend'e veya log platformuna bildirilebilir
      if (!debugMode && (type == LogType.warn || type == LogType.error)) {
        developer.log(message, name: label);
      }
    },
  );

  final db = await ToStore.open();
```


<a id="security-config"></a>
## Güvenlik

> [!WARNING]
> **Anahtar Yönetimi**: `encodingKey` değiştirilebilir (otomatik geçiş). `encryptionKey` kritiktir; geçiş olmadan değiştirilmesi eski verilerin okunamaz hale gelmesine neden olur.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      encryptionType: EncryptionType.chacha20Poly1305, 
      encodingKey: '...', 
      encryptionKey: '...',
    ),
  ),
);
```

### Alan Düzeyinde Şifreleme (ToCrypto)
Genel veritabanı performansını etkilemeden hassas alanları seçici olarak şifrelemek için.


<a id="performance"></a>
## Performans

- 📱 **Örnek**: Tam bir Flutter projesi için `example` klasörüne bakın.
- 🚀 **Release Modu**: Performans, Debug modundan çok daha yüksektir.
- ✅ **Test Edildi**: Çekirdek işlevler kapsamlı test paketleri ile kapsanmıştır.

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="ToStore Performans Demosu" width="320" />
</p>

- **Performans Tanıtımı**: 100M+ kayıtta bile pürüzsüz çalışma. ([Video](https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4))

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="ToStore Kurtarma" width="320" />
</p>

- **Kurtarma**: Ani güç kesintilerinde otomatik kurtarma. ([Video](https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4))


ToStore size yardımcı olduysa, lütfen bir ⭐️ verin! Bu, açık kaynağa verilen en büyük destektir.

---

> **Öneri**: Ön uç geliştirme için [ToApp Framework](https://github.com/tocreator/toapp) kullanmayı değerlendirin. İstek, önbellek ve durum yönetimi için tam yığın çözüm sunar.
