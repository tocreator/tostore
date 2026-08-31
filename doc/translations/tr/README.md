<h1 align="center">
  <img src="../../resource/logo-tostore.svg" width="400" alt="ToStore">
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
  <a href="../../../README.md">English</a> |
  <a href="../zh-CN/README.md">简体中文</a> |
  <a href="../ja/README.md">日本語</a> |
  <a href="../ko/README.md">한국어</a> |
  <a href="../es/README.md">Español</a> |
  <a href="../pt-BR/README.md">Português (Brasil)</a> |
  <a href="../ru/README.md">Русский</a> |
  <a href="../de/README.md">Deutsch</a> |
  <a href="../fr/README.md">Français</a> |
  <a href="../it/README.md">Italiano</a> |
  Türkçe
</p>

## Hızlı Gezinme
- [Neden Saklamalı](#why-tostore) | [Temel Özellikler](#key-features) | [Kurulum Kılavuzu](#installation) | [KV Modu](#quick-start-kv) | [Tablo Modu](#quick-start-table) | [Bellek Modu](#quick-start-memory)
- [Şema Tanımı](#schema-definition) | [Dağıtılmış Mimari](#distributed-architecture) | [Basamaklı Yabancı Anahtarlar](#foreign-keys) | [Mobil/Masaüstü](#mobile-integration) | [Sunucu/Aracı](#server-integration) | [Birincil Anahtar Algoritmaları](#primary-key-examples)
- [Gelişmiş Sorgular (KATIL)](#query-advanced) | [Toplama ve İstatistikler](#aggregation-stats) | [Karmaşık Mantık (Sorgu Durumu)](#query-condition) | [Reaktif Sorgu (izle)](#reactive-query) | [Akış Sorgusu](#streaming-query)
- [Gelişmiş KV](#kv-advanced) | [Toplu İşlemler](#bulk-operations) | [Vektör ve Hibrit Getirme](#vector-advanced) | [Tablo düzeyinde TTL](#ttl-config) | [Etkili Sayfalandırma](#query-pagination) | [Bellek Probu ve Senkron Arama (peek)](#query-peek) | [Sorgu Önbelleği](#query-cache) | [Atomik İfadeler](#atomic-expressions) | [İşlemler](#transactions)
- [Yönetim](#database-maintenance) | [Güvenlik Yapılandırması](#security-config) | [Hata İşleme](#error-handling) | [Performans ve Tanılama](#performance) | [Katkıda Bulunma](#contribute) | [YZ asistanları](#for-ai-coding-assistants)

## <a id="why-tostore"></a>Neden ToStore'u Seçmelisiniz?

ToStore, AGI çağı ve uç zeka senaryoları için tasarlanmış modern bir veri motorudur. Kendi kendini yönlendiren (Self-Routing) düğüm mimarisi üzerine kurulu olan bu sistem, düğümlere yüksek özerklik ve esnek yatay ölçeklenebilirlik sağlarken performansı veri ölçeğinden mantıksal olarak ayırır.

Çalışma zamanı modellemesi ve engelsiz yürütme yolları, mimari evrimi her zaman çevrimiçi ve iş operasyonlarına tamamen şeffaf tutar — bildirimsel şema değişiklikleri, veri kodlama anahtarı rotasyonu ve büyük ölçekli veri yeniden yapılandırması kesintisiz olarak gerçekleşir. Ajan ve otomatik işletime yönelik olarak, onların özerk evrimini ve sürekli yinelemesini hizmeti kesmeden destekler.

İlişkisel yapılandırılmış verileri, yüksek boyutlu vektörleri ve yapılandırılmamış verileri yerel olarak destekleyen birleşik bir veri motoru; yerleşik hibrit getirme ve çok yollu getirme füzyonu ile birlikte ACID işlemleri, karmaşık ilişkisel sorgular (JOIN'ler, basamaklı yabancı anahtarlar), tablo düzeyinde TTL, toplama işlemlerinin yanı sıra dağıtık birincil anahtar algoritmaları, atomik ifadeler, şifreleme, çoklu alan yalıtımı ve otomatik kurtarma gibi kurumsal düzeyde veritabanı yetenekleri sunar.

Bilgi işlem uç zekaya doğru kaymaya devam ettikçe, cihazlar artık yalnızca "içerik ekranları" değil, yerel üretimden, çevre algılamasından, gerçek zamanlı karar alma ve veri koordinasyonundan sorumlu akıllı düğümlerdir. ToStore, uca büyük veri kümeleri ve karmaşık yerel yapay zeka üretimi için dağıtık yetenekler sunar. Uç ve bulut düğümleri arasındaki derin akıllı işbirliği, çok modlu etkileşim, anlamsal vektör hibrit getirme, uzamsal modelleme, uç özerk işbirliği ve benzer senaryolar için güvenilir bir veri temeli sağlar.

## <a id="key-features"></a>Temel Özellikler

- 🤖 **Çalışma Zamanı Evrimi ve Akıllı İşletim**
  - Bildirimsel tanım, otomatik yeniden yapılandırma, sürüm yönetimi gereksiz
  - Anahtar rotasyonu, şema değişiklikleri, büyük ölçekli yeniden yapılandırma—tümü çevrimiçi, kesintisiz
  - Otomatik işletim ve Ajan algılaması için entegre durum özellikleri
  - Uzun vadeli kararlılık için hizmet kesintisi olmadan sıcak güncellemeler

- 🧠 **Kendi Kendini Yönlendiren Dağıtık Mimari**
  - Fiziksel adreslemeyi veri ölçeğinden ayıran kendi kendini yönlendiren düğüm mimarisi
  - Yüksek düzeyde özerk düğümler esnek bir veri topolojisi oluşturmak için işbirliği yapar
  - Uç ve bulut düğümleri arasında derin bağlantı ile esnek yatay ölçeklendirme

- 🌐 **Birleşik Platformlar Arası Veri Motoru**
  - Mobil, masaüstü, web ve sunucu ortamlarında birleşik API
  - İlişkisel yapılandırılmış verileri, yüksek boyutlu vektörleri ve yapılandırılmamış verileri kapsar
  - Yerel depolamadan uç-bulut işbirliğine kadar eksiksiz veri hattı

- 🔍 **Yapılandırılmış Sorgular ve Hibrit Getirme**
  - Karmaşık yüklemler, JOIN'ler, toplama işlemleri ve tablo düzeyinde TTL
  - Çok kanallı getirme aynı sorgu zincirinde birleştirilebilir (vektör, yapılandırılmış ve daha fazlası)
  - Çok yollu getirme füzyon sıralaması; puanlar ve kanal tanılaması sorgu sonucunda döner

- ⚡ **Paralel Yürütme ve Kaynak Planlama**
  - Yüksek kullanılabilirlik için kaynağa duyarlı akıllı yük planlaması
  - Çok düğümlü paralel işbirliği ve görev ayrıştırma
  - Ağır yük altında bile kullanıcı arayüzü animasyonlarını akıcı tutan zaman dilimleme

- 🔐 **Veri Güvenliği ve Yalıtımı**
  - İsteğe bağlı küresel paylaşımla çoklu alan yalıtımı, çok kullanıcılı ve çoklu kiracı senaryoları için ideal
  - Entegre ChaCha20-Poly1305 ve AES-256-GCM şifrelemesi
  - Birden fazla karmaşık afet kurtarma senaryosu ile doğrulanmıştır

## <a id="installation"></a>Kurulum

> [!IMPORTANT]
> **V2.x'ten yükseltme mi yapıyorsunuz?** Kritik geçiş adımları ve önemli değişiklikler için lütfen [v3.x Yükseltme Kılavuzu](../../UPGRADE_GUIDE_v3.md)'nu okuyun.

`pubspec.yaml`'ınıza `tostore` ekleyin:

```yaml
dependencies:
  tostore: any # Please use the latest version
```

### For AI Coding Assistants

ToStore istemci kodunu bir YZ asistanıyla üretirken, tek dosyalık derlemeyi [`llms-full.txt`](../../../llms-full.txt) asistanına verin — örneğin IDE'de `@llms-full.txt`, dosyayı yükleyin/yapıştırın veya [raw URL](https://raw.githubusercontent.com/tocreator/tostore/main/llms-full.txt) adresini asistan belgelerine ekleyin. Gerçek genel API yüzeyine uyum için imzalar, kısıtlar ve anti-örüntüler içerir. Dizin: [`llms.txt`](../../../llms.txt).

## <a id="quick-start"></a>Hızlı Başlangıç

> [!TIP]
> **Depolama modunu nasıl seçmelisiniz?**
> 1. [**Anahtar-Değer Modu (KV)**](#quick-start-kv): Yapılandırma erişimi, dağınık durum yönetimi veya JSON veri depolama için en iyisi. Başlamanın en hızlı yoludur.
> 2. [**Yapılandırılmış Tablo Modu**](#quick-start-table): Karmaşık sorgular, kısıtlama doğrulama veya büyük ölçekli veri yönetimi gerektiren temel iş verileri için en iyisi. Bütünlük mantığını motora aktararak uygulama katmanı geliştirme ve bakım maliyetlerini önemli ölçüde azaltabilirsiniz.
> 3. [**Bellek Modu**](#quick-start-memory): Geçici hesaplama, birim testleri veya **ultra hızlı küresel durum yönetimi** için en iyisi. Global sorgular ve `watch` dinleyicilerle, bir yığın global değişkeni muhafaza etmeden uygulama etkileşimini yeniden şekillendirebilirsiniz.

### <a id="quick-start-kv"></a>Anahtar-Değer Depolama (KV)
Bu mod, önceden tanımlanmış yapılandırılmış tablolara ihtiyacınız olmadığında uygundur. Basittir, pratiktir ve yüksek performanslı bir depolama motoruyla desteklenir. **Etkili indeksleme mimarisi, çok büyük veri ölçeklerindeki sıradan mobil cihazlarda bile sorgu performansını son derece istikrarlı ve son derece duyarlı tutar.** Farklı Alanlardaki veriler doğal olarak izole edilirken küresel paylaşım da desteklenir.

```dart
// Initialize the database
final db = await ToStore.open();

// Set key-value pairs (supports String, int, bool, double, Map, List, Json, and more)
await db.setValue('user_profile', {
  'name': 'John',
  'age': 25,
});

// Switch space - isolate data for different users
await db.switchSpace(spaceName: 'user_123');

// Set a globally shared variable (isGlobal: true enables cross-space sharing, such as login state)
await db.setValue('current_user', 'John', isGlobal: true);

// Automatic expiration cleanup (TTL)
// Supports either a relative lifetime (ttl) or an absolute expiration time (expiresAt)
await db.setValue('temp_config', 'value', ttl: Duration(hours: 2));
await db.setValue('session_token', 'abc', expiresAt: DateTime(2026, 2, 31));

// Read data
final profile = await db.getValue('user_profile'); // Map<String, dynamic>

// Listen for real-time value changes (useful for refreshing local UI without extra state frameworks)
db.watchValue('current_user', isGlobal: true).listen((value) {
  print('Logged-in user changed to: $value');
});

// Listen to multiple keys at once
db.watchValues(['current_user', 'login_status']).listen((map) {
  print('Multiple config values were updated: $map');
});

// Remove data
await db.removeValue('current_user');
```

> [!TIP]
> **Daha fazla anahtar-değer özelliğine mi ihtiyacınız var?**
> Tür açısından güvenli okuma (`getInt`, `getBool`), atomik artırma, önek arama, **zincirlenmiş sayfalı kayıt sorguları** (`db.kv.query()`) gibi gelişmiş işlemler için lütfen [**Gelişmiş Anahtar-Değer İşlemleri (db.kv)**](#kv-advanced) bölümüne bakın.

#### Flutter Kullanıcı Arayüzü Otomatik Yenileme Örneği
Flutter'da, `StreamBuilder` plus `watchValue` size çok kısa bir reaktif yenileme akışı sağlar:

```dart
StreamBuilder(
  // When listening to a global variable, remember to set isGlobal: true
  stream: db.watchValue('current_user', isGlobal: true),
  builder: (context, snapshot) {
    // snapshot.data is the latest value of 'current_user' in KV storage
    final user = snapshot.data ?? 'Not logged in';
    return Text('Current user: $user');
  },
)
```

### <a id="quick-start-table"></a>Yapılandırılmış Tablo Modu
Yapılandırılmış tablolardaki CRUD, şemanın önceden oluşturulmasını gerektirir (bkz. [Şema Tanımı](#schema-definition)). Farklı senaryolar için önerilen entegrasyon yaklaşımları:
- **Mobil/Masaüstü**: [Sık başlatma senaryoları](#mobile-integration) için, başlatma sırasında `schemas` iletilmesi önerilir.
- **Sunucu/Aracı**: [Uzun süren senaryolar](#server-integration) için, tabloların `createTables` aracılığıyla dinamik olarak oluşturulması önerilir.

```dart
// 1. Initialize the database
final db = await ToStore.open();

// 2. Insert data (prepare some base records)
final result = await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// Unified operation result model: DbResult
// It is recommended to check hasErrors
if (!result.hasErrors) {
  print('Insert succeeded, generated primary key ID: ${result.firstPrimaryKey}');
} else {
  print('Insert failed: ${result.message}');
}

// Chained query (see [Query Operators](#query-operators); supports =, !=, >, <, LIKE, IN, and more)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// Update and delete
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// Real-time listening (see [Reactive Query](#reactive-query) for more details)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Users matching the condition have changed: $users');
});

// Pair with Flutter StreamBuilder for automatic local UI refresh
StreamBuilder(
  stream: db.query('users').where('age', '>', 18).watch(),
  builder: (context, snapshot) {
    final users = snapshot.data ?? [];
    return ListView.builder(
      itemCount: users.length,
      itemBuilder: (context, index) => Text(users[index]['username']),
    );
  },
);
```

### <a id="quick-start-memory"></a>Hafıza Modu

Önbelleğe alma, geçici hesaplama veya diskte kalıcılık gerektirmeyen iş yükleri gibi senaryolar için, `ToStore.memory()` aracılığıyla saf bir bellek içi veritabanını başlatabilirsiniz. Bu modda, şemalar, dizinler ve anahtar/değer çiftleri de dahil olmak üzere tüm veriler, maksimum okuma/yazma performansı için tamamen bellekte saklanır.

#### 💡 Ayrıca Küresel Devlet Yönetimi olarak da çalışıyor
Bir yığın küresel değişkene veya ağır bir devlet yönetimi çerçevesine ihtiyacınız yok. Bellek modunu `watchValue` veya `watch()` ile birleştirerek, widget'lar ve sayfalar arasında tam otomatik kullanıcı arayüzü yenilemesi elde edebilirsiniz. Bir veritabanının güçlü alma yeteneklerini korurken, size sıradan değişkenlerin çok ötesinde reaktif bir deneyim sunar; bu da onu oturum açma durumu, canlı yapılandırma veya genel mesaj sayaçları için ideal kılar.

> [!CAUTION]
> **Not**: Salt bellek modunda oluşturulan veriler, uygulama kapatıldıktan veya yeniden başlatıldıktan sonra tamamen kaybolur. Temel iş verileri için kullanmayın.

```dart
// Initialize a pure in-memory database
final memDb = await ToStore.memory();

// Set a global state value (for example: unread message count)
await memDb.setValue('unread_count', 5, isGlobal: true);

// Listen from anywhere in the UI without passing parameters around
memDb.watchValue<int>('unread_count', isGlobal: true).listen((count) {
  print('UI automatically sensed the message count change: $count');
});

// All CRUD, KV access, and vector search run at in-memory speed
await memDb.insert('active_users', {'name': 'Marley', 'status': 'online'});
```


## <a id="schema-definition"></a>Şema Tanımı
**Bir kez tanımlayın ve uygulamanızın artık ağır doğrulama bakımı gerektirmemesi için motorun uçtan uca otomatik yönetimi yönetmesine izin verin.**

Aşağıdaki mobil, sunucu tarafı ve aracı örneklerinin tümü, burada tanımlanan `appSchemas`'yi yeniden kullanır.


### Tablo Şemasına Genel Bakış

```dart
const userSchema = TableSchema(
  name: 'users', // Table name, required
  tableId: 'users', // Unique identifier of the table, optional
  primaryKeyConfig: PrimaryKeyConfig(
    name: 'id', // Primary key field name, defaults to id
    type: PrimaryKeyType.sequential, // Primary key auto-generation strategy
    sequentialConfig: SequentialIdConfig(
      initialValue: 1000, // Initial value for sequential IDs
      increment: 1, // Step size
      useRandomIncrement: false, // Whether to use random step sizes
    ),
  ),
  fields: [
    FieldSchema(
      name: 'username', // Field name, required
      type: DataType.text, // Field data type, required
      nullable: false, // Whether null is allowed
      minLength: 3, // Minimum length
      maxLength: 32, // Maximum length
      unique: true, // Whether it must be unique
      fieldId: 'username', // Stable field identifier, optional, used to detect field renames
      comment: 'Login name', // Optional comment
    ),
    FieldSchema(
      name: 'status',
      type: DataType.integer,
      minValue: 0, // Minimum numeric value
      maxValue: 150, // Maximum numeric value
      defaultValue: 0, // Static default value
      createIndex: true, // Shortcut for creating an index
    ),
    FieldSchema(
      name: 'created_at',
      type: DataType.datetime,
      nullable: false,
      defaultValueType: DefaultValueType.currentTimestamp, // Automatically fill with current time
      createIndex: true,
    ),
  ],
  indexes: const [
    IndexSchema(
      indexName: 'idx_users_status_created_at', // Optional index name
      fields: ['status', 'created_at'], // Composite index fields
      unique: false, // Whether it is a unique index
      type: IndexType.btree, // Index type: btree/vector
    ),
  ],
  foreignKeys: const [], // Optional foreign-key constraints; see "Foreign Keys & Cascading"
  isGlobal: false, // Whether this is a global table; true means it can be shared across spaces
  ttlConfig: null, // Optional table-level TTL; see "Table-level TTL"
);

const appSchemas = [userSchema];
```

- **Ortak `DataType` eşlemeleri**:
  | Tür | İlgili Dart Türü | Açıklama |
  | :--- | :--- | :--- |
| `integer` | `int` | Kimlikler, sayaçlar ve benzeri veriler için uygun standart tamsayı |
  | `bigInt` | `BigInt` / `String` | Büyük tamsayılar; Hassasiyet kaybını önlemek için sayılar 18 haneyi aştığında önerilir |
  | `double` | `double` | Fiyatlar, koordinatlar ve benzeri veriler için uygun kayan noktalı sayı |
  | `text` | `String` | İsteğe bağlı uzunluk kısıtlamalarına sahip metin dizesi |
  | `blob` | `Uint8List` | Ham ikili veriler |
  | `boolean` | `bool` | Boole değeri |
  | `datetime` | `DateTime` / `String` | Tarih/saat; dahili olarak ISO8601 olarak saklanır |
  | `array` | `List` | Liste veya dizi türü |
  | `json` | `Map<String, dynamic>` | Dinamik yapılandırılmış verilere uygun JSON nesnesi |
  | `vector` | `VectorData` / `List<num>` | Yapay zeka anlamsal alımı (gömmeler) için yüksek boyutlu vektör verileri |

- **`PrimaryKeyType` otomatik oluşturma stratejileri**:
  | Strateji | Açıklama | Özellikler |
  | :--- | :--- | :--- |
| `none` | Otomatik nesil yok | Ekleme sırasında birincil anahtarı manuel olarak sağlamanız gerekir |
  | `sequential` | Sıralı artış | İnsan dostu kimlikler için iyidir ancak dağıtılmış performans için daha az uygundur |
  | `timestampBased` | Zaman damgası tabanlı | Dağıtılmış ortamlar için önerilir |
  | `datePrefixed` | Tarih öneki | Tarihin okunabilirliği işletme için önemli olduğunda kullanışlıdır |
  | `shortCode` | Kısa kodlu birincil anahtar | Kompakt ve harici ekrana uygun |

> Tüm birincil anahtarlar varsayılan olarak `text` (`String`) olarak saklanır.


### Kısıtlamalar ve Otomatik Doğrulama

Uygulama kodunda yinelenen mantıktan kaçınarak ortak doğrulama kurallarını doğrudan `FieldSchema` içine yazabilirsiniz:

- `nullable: false`: boş olmayan kısıtlama
- `minLength` / `maxLength`: metin uzunluğu kısıtlamaları
- `minValue` / `maxValue`: tam sayı veya kayan nokta aralığı kısıtlamaları
- `defaultValue` / `defaultValueType`: statik varsayılan değerler ve dinamik varsayılan değerler
- `unique`: benzersiz kısıtlama
- `createIndex`: yüksek frekanslı filtreleme, sıralama veya ilişkiler için dizinler oluşturun
- `fieldId` / `tableId`: geçiş sırasında alanlar ve tablolar için yeniden adlandırma tespitine yardımcı olun

Ayrıca `unique: true` otomatik olarak tek alanlı benzersiz bir dizin oluşturur. `createIndex: true` ve yabancı anahtarlar otomatik olarak tek alanlı normal dizinler oluşturur. Bileşik dizinlere, adlandırılmış dizinlere veya vektör dizinlere ihtiyaç duyduğunuzda `indexes` kullanın.

### <a id="schema-evolution"></a>Şema gelişimi (Schema Evolution)

Motor yapısal değişiklikleri (tablo/alan ekleme, silme veya yeniden adlandırma, öznitelik güncellemeleri, dizin değişiklikleri vb.) otomatik algılar ve veri geçişini tamamlar — manuel sürüm yönetimi veya geçiş betikleri gerekmez. Bildirimsel `schemas`, `ToStore.open()` sırasında evrilir; çalışma zamanında `updateSchema` da kullanılabilir — **iş mantığına şeffaf**, okuma/yazma kesintisizdir.

#### <a id="promote-primary-key"></a>Benzersiz alanı birincil anahtara yükseltme

Mevcut **benzersiz ve null olmayan** bir alanı birincil anahtara yükseltebilirsiniz (yeniden adlandırma isteğe bağlı; mevcut veriyle; işe şeffaf). **`setPrimaryKeyConfig` ile birlikte değiştirmeyin**.

- **Mobil (bildirimsel `schemas`)**: `ToStore.open()` sırasında otomatik algılanır. Hedef birincil anahtar **mutlaka** `PrimaryKeyType.none` olmalıdır (değerler kaynak benzersiz alandan gelir; diğer otomatik üretim türleri desteklenmez). Adlar aynıysa ad eşleşmesi yeterlidir; yeniden adlandırmada `fromFieldId` kaynağın `fieldId` değeri olmalıdır.
- **Sunucu (çalışma zamanı)**: `updateSchema(...).promoteFieldToPrimaryKey(sourceFieldName: ..., targetPrimaryKeyName: ...)` çağırın. `targetPrimaryKeyName` isteğe bağlıdır; verilmezse kaynak alan adı korunur.

### Bir Entegrasyon Yöntemi Seçme

- **Mobil/Masaüstü**: `appSchemas`'yi doğrudan `ToStore.open(...)`'ye aktarırken en iyisi
- **Sunucu/Aracı**: Çalışma zamanında `createTables(appSchemas)` aracılığıyla dinamik olarak şemalar oluştururken en iyisidir


## <a id="mobile-integration"></a>Mobil, Masaüstü ve Diğer Sık Başlatma Senaryoları için Entegrasyon

📱 **Örnek**: [mobile_quickstart.dart](../../../example/lib/mobile_quickstart.dart)

```dart
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// On Android/iOS, resolve the app's writable directory first, then pass dbPath explicitly
final docDir = await getApplicationDocumentsDirectory();
final dbRoot = p.join(docDir.path, 'common');

// Reuse the appSchemas defined above
final db = await ToStore.open(
  dbPath: dbRoot,
  schemas: appSchemas,
);

// Multi-space architecture - isolate data for different users
await db.switchSpace(spaceName: 'user_123');
```

### Başlangıç İlerlemesini Takip Etme

Normal şema değişiklikleri iş mantığına karşı şeffaftır ve başlatmayı engellemez. Yalnızca sık sık zorla kapatılan mobil uygulamalara özgü nadir istisnai durumlarda (örneğin, anormal bir çıkıştan sonra kısa veri doğrulaması ve kilitlenme kurtarma) başlatma fark edilebilir bir süre alabilir — bu durumda bir açılış ekranı veya ilerleme göstergesi göstermek için `onStartupProgress` kullanın:

```dart
final db = await ToStore.open(
  dbPath: dbRoot,
  schemas: appSchemas,
  onStartupProgress: (progress, stage) {
    // progress: 0.0 – 1.0  |  stage: opening → recovering → optimizing → ready
    print('Başlangıç ilerlemesi ${(progress * 100).toStringAsFixed(0)}% [$stage]');
    // Açılış ekranı / ilerleme çubuğunu güncelle
  },
);
// Veritabanı tamamen hazır
```

Aşamalar:
- `opening` — Yapılandırma yükleniyor, temel motor hazırlanıyor
- `recovering` — Güvenlik kontrolleri ve çökme kurtarma
- `optimizing` — Dahili motor ayarı ve yapısal optimizasyon
- `ready` — Başlatma tamamlandı, kullanıma hazır


### Oturum Açma Durumunu ve Oturum Kapatmayı Tutma (Aktif Alan)

Çoklu alan **kullanıcı verilerini izole etmek** için idealdir: oturum açma sırasında kullanıcı başına bir alan. **Aktif Alan** ve kapatma seçenekleriyle, uygulama yeniden başlatıldığında geçerli kullanıcıyı koruyabilir ve temiz oturum kapatma davranışını destekleyebilirsiniz.

- **Giriş durumunu koru**: Bir kullanıcıyı kendi alanına geçirdikten sonra bu alanı etkin olarak işaretleyin. Bir sonraki başlatma, "önce varsayılan, sonra geçiş" adımı olmadan, varsayılan örneği açarken doğrudan bu alana girebilir.
- **Oturumu Kapat**: Kullanıcı oturumu kapattığında, veritabanını `keepActiveSpace: false` ile kapatın. Bir sonraki başlatmada önceki kullanıcının alanına otomatik olarak girilmeyecektir.

```dart
// After login: switch to the user's space and mark it active
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// Optional: strictly stay in default when needed (for example, login screen only)
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// On logout: close and clear the active space so the next launch starts from default
await db.close(keepActiveSpace: false);
```


## <a id="server-integration"></a>Sunucu Tarafı / Aracı Entegrasyonu (Uzun Süreli Senaryolar)

🖥️ **Örnek**: [sunucu_hızlıbaşlangıç.dart](../../../example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// Create table structures while the process is running
await db.createTables(appSchemas);

// Online schema updates
final result = await db.updateSchema('users')
  .renameTable('users_new')                // Rename table
  .modifyField(
    'username',
    minLength: 5,
    maxLength: 20,
    unique: true
  )                                        // Modify field attributes
  .renameField('old_name', 'new_name')     // Rename field
  .removeField('deprecated_field')         // Remove field
  .addField('created_at', type: DataType.datetime)  // Add field
  .removeIndex(fields: ['age'])            // Remove index
  .setPrimaryKeyConfig(                    // Change auto-generated PK strategy; avoid when the table already has data
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
// Promote a unique field to PK (see promote-primary-key section; do not chain with the above):
// await db.updateSchema('users').promoteFieldToPrimaryKey(
//   sourceFieldName: 'user_id',
//   targetPrimaryKeyName: 'uid', // optional; omit to keep the source field name
// );

// Monitor migration progress
final taskId = result.taskId;
if (taskId != null) {
  // Inspect migration metadata
  print('Estimated duration: ${result.estimateDuration?.inMilliseconds} ms');
  print('Migration write mode: ${result.writeMode}'); // e.g. MigrationWriteMode.indexOnly

  final status = await db.queryMigrationTaskStatus(taskId);
  print('Migration progress: ${status?.progressPercentage}%');
}


// Optional performance tuning for pure server workloads
// yieldDurationMs controls how often long-running work yields time slices.
// The default is tuned to 8ms to keep frontend UI animations smooth.
// In environments without UI, 50ms is recommended for higher throughput.
final dbServer = await ToStore.open(
  config: DataStoreConfig(yieldDurationMs: 50),
);
```


## <a id="advanced-usage"></a>Gelişmiş Kullanım

ToStore, karmaşık iş senaryoları için zengin bir dizi gelişmiş yetenek sağlar:


### <a id="kv-advanced"></a>Gelişmiş Anahtar-Değer İşlemleri (db.kv)

Daha karmaşık anahtar-değer senaryoları için `db.kv` ad alanının kullanılması önerilir. Alan izolasyonu, küresel paylaşım, çeşitli veri türleri ve zincirlenmiş karmaşık sorgular/filtreler (ör. sayfalama, sıralama, süre sonu filtresi için `db.kv.query().prefix(...).orderBy...().limit(...)`) ile tam bir API seti sunar.

- **Temel Erişim (Basic Access)**
  ```dart
  // Değer ata (String, int, bool, double, Map, List vb. destekler)
  await db.kv.set('key', 'value', ttl: Duration(hours: 1));
  
  // Ham dinamik değeri al
  dynamic val = await db.kv.get('key');

  // Tek bir anahtarı kaldır
  await db.kv.remove('key');
  ```

- **Tür Güvenli Okuma (Type-Safe Getters)**
  Verileri manuel dönüşüm olmadan doğrudan hedef formatta alın:
  ```dart
  String? name = await db.kv.getString('user_name');
  int? age = await db.kv.getInt('user_age');
  bool? isVip = await db.kv.getBool('is_vip');
  Map<String, dynamic>? profile = await db.kv.getMap('profile');
  List<String>? tags = await db.kv.getList<String>('tags');
  ```

- **Toplu İşlemler (Bulk Operations)**
  Birden fazla anahtar-değer çiftini tek bir işlemde verimli bir şekilde işleyin:
  ```dart
  // Toplu atama
  await db.kv.setMany({
    'theme': 'dark',
    'language': 'tr_TR',
  });

  // Toplu kaldırma
  await db.kv.removeKeys(['temp_1', 'temp_2']);
  ```

- **Atomik Sayaçlar (Atomic Increment)**
  Yüksek eşzamanlı senaryolarda sayısal değerleri güvenli bir şekilde artırın veya azaltın:
  ```dart
  // 1 artır (varsayılan)
  await db.kv.setIncrement('view_count');
  // 5 azalt (negatif miktar geçerek)
  await db.kv.setIncrement('stock_count', amount: -5);
  ```

- **Zincirlenmiş kayıt sorgusu (db.kv.query)**
  `db.query()` benzeri zincir API; anahtar-değer **kayıtlarını** (çözülmüş `value` dahil) sorgular ve sayfalamayı destekler. `getKeys`'ten (yalnızca anahtar adları) farklı olarak tam kayıtlar döndürür.


  ```dart
  // İlk sayfa: önek filtresi, güncelleme zamanına göre azalan, sayfa başına 20
  final page = await db.kv.query()
      .prefix('setting_')
      .orderByUpdatedAtDesc() // veya orderByKeyAsc / orderByKeyDesc / orderByUpdatedAtAsc
      .limit(20);

  for (final record in page.data) {
    // record içerir: key, value, updated_at, expires_at
    print('${record['key']} = ${record['value']}');
  }

  // Önerilen: next() / prev() ile sayfalama (tablo sorguları ile aynı, en basit yol)
  if (page.hasMore) {
    final page2 = await page.next();
    print('Sonraki sayfa: ${page2.data.length}');
    if (page2.hasPrev) {
      final back = await page2.prev();
      print('Önceki sayfa: ${back.data.length}');
    }
  }

  // Offset sayfalama (cursor ile karşılıklı dışlayıcı; derin sayfalama için yukarıdaki next() tercih edilir)
  final byOffset = await db.kv.query()
      .orderByKeyAsc()
      .limit(20)
      .offset(20);

  // Eşleşen kayıt sayısı (prefix yoksa O(1) meta veri toplamı)
  final total = await db.kv.query().prefix('setting_').count();

  // İlk eşleşen kaydı al
  final first = await db.kv.query().prefix('setting_').orderByKeyAsc().first();

  // Küresel KV alanı
  final globalPage = await db.kv.query(isGlobal: true).limit(50);

  // Varsayılan olarak süresi dolmuş kayıtlar filtrelenir; henüz temizlenmemiş süre dolmuşları dahil etmek için:
  final withExpired = await db.kv.query()
      .includeExpired()
      .limit(20);
  ```

  Sık kullanılan zincir yöntemleri:

  | Yöntem | Açıklama |
  | --- | --- |
  | `prefix(String)` | key önekine göre filtrele |
  | `orderByKeyAsc` / `orderByKeyDesc` | key (birincil anahtar) ile sırala |
  | `orderByUpdatedAtAsc` / `orderByUpdatedAtDesc` | `updated_at` ile sırala |
  | `limit(n)` | Bu sayfadaki en fazla kayıt (her zaman açıkça belirtmeniz önerilir) |
  | `offset(n)` | Ofset sayfalama (cursor'ı temizler) |
  | `cursor(token)` | Yalnızca özel senaryolar: süreçler/ağ üzerinden sayfalama Token'ı geçirme |
  | `includeExpired([true])` | Süresi dolmuş ama henüz temizlenmemiş kayıtları dahil et |
  | `count()` | Eşleşen kayıt sayısını hesapla |
  | `first()` | İlk kaydı döndür (orijinal builder'ın limit'ini etkilemez) |

  Sorgu sonucu `QueryResult`: günlük sayfalama için `hasMore` / `hasPrev` + `next()` / `prev()`; `nextCursorToken` / `prevCursorToken` yalnızca uçtan uca aktarım gibi özel senaryolar içindir (kullanım tablo sorguları ile aynı).

- **Keşif ve Yönetim (Discovery & Management)**
  ```dart
  // Yalnızca anahtar adlarını numaralandır (value içermez); isteğe bağlı prefix / limit / offset
  final keys = await db.kv.getKeys(prefix: 'setting_');
  final pageKeys = await db.kv.getKeys(
    prefix: 'setting_',
    limit: 100,
    offset: 0,
  );

  // Mevcut alandaki toplam anahtar sayısını say
  final count = await db.kv.count();

  // Bir anahtarın mevcut olup olmadığını ve süresinin dolup dolmadığını kontrol et
  final exists = await db.kv.exists('config_cache');

  // Bellek probu (senkron, yalnızca önbellek isabeti — bkz. [Bellek Probu ve Senkron Arama (peek)](#query-peek))
  final theme = db.kv.peekGet('theme') ?? await db.kv.get('theme');
  if (db.kv.peekExists('config_cache')) { /* ... */ }

  // Mevcut alandaki tüm KV verilerini temizle
  await db.kv.clear();
  ```

- **Yaşam Döngüsü Yönetimi (TTL)**
  Mevcut anahtarların sona erme ayarlarını inceleyin veya güncelleyin:
  ```dart
  // Kalan süreyi al
  Duration? ttl = await db.kv.getTtl('token');

  // Mevcut bir anahtar için TTL'yi güncelle (7 gün içinde sona erer)
  await db.kv.setTtl('token', Duration(days: 7));
  ```

- **Reaktif İzleme (Reactive Watch)**
  ```dart
  // Tek bir anahtarı izle
  db.kv.watch<int>('unread_count').listen((count) => print(count));

  // Birden fazla anahtarın anlık görüntüsünü izle
  db.kv.watchValues(['theme', 'font_size']).listen((map) => print(map));
  ```

- **Küresel Paylaşım (isGlobal)**
  Yukarıdaki tüm yöntemler isteğe bağlı `isGlobal` parametresini destekler: küresel alan için `true` (tüm alanlar arasında paylaşılır), mevcut izole alan için `false` (varsayılan).


### <a id="bulk-operations"></a>Toplu İşlemler (Bulk Operations)

ToStore, büyük ölçekli veri çıkışı için optimize edilmiş özel toplu işleme arayüzleri sağlar. Bu arayüzler, yoğun yazma işlemleri sırasında kullanıcı arayüzünün yanıt verebilirliğini sağlamak için paralel görev dağıtımı ve zaman dilimleme (time-slicing) çizelgelemesini entegre eder.

| Yöntem | Temel Amaç | Veri Gereksinimleri | Özellikler |
| :--- | :--- | :--- | :--- |
| `batchInsert` | Kayıtları toplu ekleme | Boş bırakılamaz tüm alanları içermelidir | Saf ekleme, maksimum performans |
| `batchUpsert` | Akıllı Senkronizasyon (Upsert) | **Boş bırakılamaz tüm alanları içermelidir** | Tam senkronizasyon, birincil anahtar veya benzersiz alan ile tanımlanır |
| `batchUpdate` | Kayıtları toplu güncelleme | **Birincil anahtar veya benzersiz alan** + Güncellenecek alanlar | Mevcut kayıtlar için kısmi güncellemeler |

- **Toplu Ekleme (batchInsert)**
  ```dart
  await db.batchInsert('users', [
    {'username': 'user1', 'email': '1@ex.com'},
    {'username': 'user2', 'email': '2@ex.com'},
  ]);
  ```

- **Akıllı Toplu Senkronizasyon (batchUpsert)**
  Birincil anahtar veya benzersiz alanlara göre "Ekleme" veya "Güncelleme" işlemini otomatik olarak tanımlar. Tam veri senkronizasyonu için yaygındır.
  > [!IMPORTANT]
  > **Veri Gereksinimleri**: Bir ekleme işlemi tetiklenebileceğinden, `batchUpsert` her kaydın boş bırakılamaz tüm alanları (`nullable: false`) içermesini gerektirir.

- **Yüksek Performanslı Toplu Güncelleme (batchUpdate)**
  Özellikle mevcut kayıtları güncellemek içindir. Her kayıt, bir tanımlayıcı olarak birincil anahtar veya benzersiz alanın yanı sıra değiştirilecek alanları içermelidir.
  > [!TIP]
  > **Kısmi Güncellemeler**: `batchUpdate` yalnızca sağlanan alanları değiştirir ve boş bırakılamaz tüm alanların mevcut olmasını gerektirmez, bu da onu artımlı güncellemeler için ideal kılar.
  ```dart
  await db.batchUpdate('users', [
    {'username': 'john', 'age': 27}, // Benzersiz alan 'username' ile tanımla ve 'age' alanını güncelle
    {'id': '1002', 'status': 'active'}, // Doğrudan birincil anahtarı da kullanabilir
  ]);
  ```

> [!TIP]
> Münferit kayıt hatalarının (örneğin benzersiz kısıtlama ihlali) tüm toplu işlemi reddetmemesini sağlamak için `allowPartialErrors: true` ayarını yapabilirsiniz.


### <a id="vector-advanced"></a>Vektör Alanları, Vektör İndeksleri ve Hibrit Getirme

Vektör getirme, birleşik `db.query(...).matchVector(...)` sorgu zincirini kullanır: aynı zincirde yapılandırılmış koşullarla birleştirilebilir veya diğer getirme dallarıyla kaynaştırılabilir. Skorlar ve kanal tanıları `QueryResult.retrieval` içinde döner ve `data` satırlarıyla 1:1 hizalanır. Güncel örnekler vektör + yapılandırılmış yollara odaklanır; sözcüksel, grafik ve diğer kanallar aynı zincirli hibrit getirme modeliyle genişletilecektir.

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
        name: 'category',
        type: DataType.text,
        nullable: false,
        createIndex: true,
      ),
      FieldSchema(
        name: 'embedding',
        type: DataType.vector, // Declare a vector field
        nullable: false,
        vectorConfig: VectorFieldConfig(
          dimensions: 128, // Written and queried vectors must match this width
        ),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['embedding'], // Field to index
        type: IndexType.vector, // Build a vector index
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh, // ToStore built-in proprietary dense index
          distanceMetric: VectorDistanceMetric.cosine, // Good for normalized embeddings
        ),
      ),
    ],
  ),
]);

final queryVector =
    VectorData.fromList(List.generate(128, (i) => i * 0.01)); // Must match dimensions

// 1) Recommended: chained hybrid retrieval (pure vector ANN)
final result = await db
    .query('embeddings')
    .matchVector('embedding', queryVector) // default searchDepth = 80
    .limit(5);

for (var i = 0; i < result.data.length; i++) {
  final row = result.data[i];
  final entry = result.retrieval?.entries[i];
  final score = entry?.score;
  final distance = entry?.meta?['distance'];
  print('pk=${row['id']}, title=${row['document_title']}, '
      'score=$score, distance=$distance');
}

// 2) Structured filter + vector (AND hybrid)
final filtered = await db
    .query('embeddings')
    .whereEqual('category', 'tech')
    .matchVector('embedding', queryVector)
    .limit(5);

// 3) Multi-way fused recall (vector + structured paths, engine-side RRF)
final otherVector =
    VectorData.fromList(List.generate(128, (i) => i * 0.012));
final fused = await db
    .query('embeddings')
    .matchVector('embedding', queryVector, weight: 1.0)
    .orMatchVector('embedding', otherVector, weight: 0.6, minScore: 0.2)
    .or()
    .whereEqual('category', 'tech')
    .limit(10);

print('fusion=${fused.retrieval?.fusionMethod}'); // Multi-way is typically rrf
```

**Şema / vektör indeks yapılandırması** (`VectorFieldConfig`, `VectorIndexConfig`):

- `dimensions`: yazılan embedding genişliğiyle eşleşmelidir
- `precision`: yaygın seçenekler `float64`, `float32`, `int8`; daha yüksek hassasiyet genellikle daha fazla depolama gerektirir
- `distanceMetric`: indeks tarafı benzerlik ölçüsü; `cosine` anlamsal embedding için yaygındır, `l2` Öklid mesafesi, `innerProduct` nokta çarpımı araması içindir

**Zincirli getirme parametreleri** (`matchVector` / `orMatchVector` ve sorgu zincirindeki `limit`):

- `field` / `vector`: hedef vektör alanı ve sorgu vektörü (`VectorData` / `List<num>` / `Float32List`)
- `searchDepth`: optional thoroughness in `[1, 100]` (**not** a recall%); higher usually means better recall intent and higher latency, lower is faster but may miss neighbors; omit → engine default `80`
- `weight`: çok yollu getirmede bu kanalın füzyon ağırlığı; varsayılan `1.0`
- `minScore`: normalize benzerlik alt sınırı `[0.0 ~ 1.0]`; altındakiler elenir
- `distanceThreshold`: mesafe üst sınırı; aşan adaylar dışlanır
- `limit`: döndürülecek sonuç sayısı (tipik ANN kullanımında topK karşılığı)

**Sonuç notları** (`QueryResult`):

- İş satırları `data` içinde; getirme skorları ve kanal bilgisi `retrieval.entries` içinde, `data` ile **1:1** hizalı
- `entry.score`: normalize benzerlik / füzyon skoru, tipik olarak `0 ~ 1`; büyük = daha ilgili
- `entry.meta['distance']`: ham mesafe (vektör kanalında yaygındır); `l2` / `cosine` için küçük genellikle daha yakındır
- `retrieval.fusionMethod`: tek kanalda genellikle `single`; çok yollu füzyon tipik olarak `rrf` (Reciprocal Rank Fusion)

### <a id="ttl-config"></a>Tablo düzeyinde TTL (Otomatik Zamana Dayalı Sona Erme)

Günlükler, telemetri, olaylar ve zamanla sona ermesi gereken diğer veriler için tablo düzeyinde TTL'yi `ttlConfig` aracılığıyla tanımlayabilirsiniz. Motor, süresi dolmuş kayıtları arka planda otomatik olarak temizleyecektir:

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
    ttlMs: 7 * 24 * 60 * 60 * 1000, // Keep for 7 days
    // When sourceField is omitted, the engine creates the needed index automatically.
    // Optional custom sourceField requirements:
    // 1) type must be DataType.datetime
    // 2) nullable must be false
    // 3) defaultValueType must be DefaultValueType.currentTimestamp
    // sourceField: 'created_at',
  ),
);
```


### Akıllı Depolama (Upsert)
ToStore, `data`'de bulunan birincil anahtara veya benzersiz alana göre güncelleme veya ekleme kararı verir. `where` burada desteklenmemektedir; çakışma hedefi verilerin kendisi tarafından belirlenir.

```dart
// Birincil anahtara göre
final result = await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});

// Benzersiz alana göre (kayıt, benzersiz bir kısıtlamaya katılan tüm alanları ve gerekli alanları içermelidir)
await db.upsert('users', {
  'username': 'john',
  'email': 'john@example.com',
  'age': 26,
});

// Toplu upsert (atomik modu veya kısmi başarı modunu destekler)
// allowPartialErrors: true, bazı satırlar başarısız olurken diğerlerinin yine de başarılı olabileceği anlamına gelir
final batchResult = await db.batchUpsert('users', [
  {'username': 'a', 'email': 'a@example.com'},
  {'username': 'b', 'email': 'b@example.com'},
], allowPartialErrors: true);
```


### <a id="query-advanced"></a>Gelişmiş Sorgular

ToStore, esnek alan işleme ve karmaşık çoklu tablo ilişkileriyle bildirim temelli zincirlenebilir bir sorgu API'si sağlar.

#### 1. Alan Seçimi (`select`)
`select` yöntemi hangi alanların döndürüleceğini belirtir. Eğer çağırmazsanız, varsayılan olarak tüm alanlar döndürülür.
- **Takma Adlar**: sonuç kümesindeki anahtarları yeniden adlandırmak için `field as alias` sözdizimini (büyük/küçük harfe duyarlı olmayan) destekler
- **Tablo nitelikli alanlar**: çoklu tablo birleştirmelerinde, `table.field` adlandırma çakışmalarını önler
- **Toplama karıştırma**: `Agg` nesneleri doğrudan `select` listesinin içine yerleştirilebilir

```dart
final results = await db.query('orders')
    .select([
      'orders.id',
      'users.name as customer_name',
      'orders.amount',
      Agg.count('id', alias: 'total_items')
    ])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000)
    .limit(20);
```

#### 2. Katılıyor (`join`)
Standart `join` (iç birleştirme), `leftJoin` ve `rightJoin`'yi destekler.

#### 3. Akıllı Yabancı Anahtar Tabanlı Birleştirmeler (Önerilen)
`foreignKeys`, `TableSchema`'da doğru şekilde tanımlanmışsa, birleştirme koşullarını elle yazmanıza gerek yoktur. Motor, referans ilişkilerini çözebilir ve en uygun JOIN yolunu otomatik olarak oluşturabilir.

- **`joinReferencedTable(tableName)`**: geçerli tablonun referans verdiği ana tabloya otomatik olarak katılır
- **`joinReferencingTable(tableName)`**: geçerli tabloya başvuran alt tablolara otomatik olarak katılır

```dart
// Assume posts defines a foreign key to users
final posts = await db.query('posts')
    .joinReferencedTable('users') // Automatically resolves to ON posts.user_id = users.id
    .select(['posts.title', 'users.username'])
    .limit(20);
```

---

### <a id="aggregation-stats"></a>Toplama, Gruplandırma ve İstatistik (Toplama ve Gruplandırma)

#### 1. Toplama (`Agg` fabrika)
Toplama işlevleri, bir veri kümesi üzerinden istatistikleri hesaplar. `alias` parametresiyle sonuç alanı adlarını özelleştirebilirsiniz.

| Yöntem | Amaç | Örnek |
| :--- | :--- | :--- |
| `Agg.count(field)` | Boş olmayan kayıtları say | `Agg.count('id', alias: 'total')` |
| `Agg.sum(field)` | Toplam değerler | `Agg.sum('amount', alias: 'total_price')` |
| `Agg.avg(field)` | Ortalama değer | `Agg.avg('score', alias: 'average_score')` |
| `Agg.max(field)` | Maksimum değer | `Agg.max('age')` |
| `Agg.min(field)` | Minimum değer | `Agg.min('price')` |

> [!TIP]
> **İki yaygın toplama stili**
> 1. **Kısayol yöntemleri (tek metrikler için önerilir)**: doğrudan zincirden çağrı yapın ve hesaplanan değeri hemen geri alın.
> `num? totalAge = await db.query('users').sum('age');`
> 2. **`select` içine gömülüdür (birden fazla ölçüm veya gruplama için)**: `Agg` nesnelerini `select` listesine aktarın.
> `final stats = await db.query('orders').select(['status', Agg.sum('amount')]).groupBy(['status']);`

#### 2. Gruplandırma ve Filtreleme (`groupBy` / `having`)
Kayıtları kategorilere ayırmak için `groupBy` kullanın, ardından SQL'in HAVING davranışına benzer şekilde toplu sonuçları filtrelemek için `having` kullanın.

```dart
final stats = await db.query('orders')
    .select([
      'status',
      Agg.sum('amount', alias: 'sum_amount'),
      Agg.count('id', alias: 'order_count')
    ])
    .groupBy(['status'])
    // having accepts a QueryCondition used to filter aggregated results
    .having(QueryCondition().where(Agg.sum('amount'), '>', 5000))
    .limit(10);
```

#### 3. Yardımcı Sorgu Yöntemleri
- **`exists()` (yüksek performans)**: herhangi bir kaydın eşleşip eşleşmediğini kontrol eder. `count() > 0`'dan farklı olarak, tek bir eşleşme bulunur bulunmaz kısa devre yapar; bu, çok büyük veri kümeleri için mükemmeldir.
- **`count()`**: eşleşen kayıtların sayısını verimli bir şekilde döndürür.
- **`first()`**: `limit(1)`'ye eşdeğer olan ve ilk satırı doğrudan `Map` olarak döndüren kullanışlı bir yöntem.
- **`distinct([fields])`**: sonuçları tekilleştirir. `fields` sağlanırsa benzersizlik bu alanlara göre hesaplanır.

```dart
// Efficient existence check
if (await db.query('users').whereEqual('email', 'test@test.com').exists()) {
  print('Email is already registered');
}

// Get a deduplicated city list
final cities = await db.query('users').distinct(['city']);
```

#### <a id="query-condition"></a>4. `QueryCondition` ile Karmaşık Mantık
`QueryCondition`, ToStore'un iç içe mantık ve parantezli sorgu oluşturmaya yönelik temel aracıdır. Basit zincirleme `where` çağrıları `(A AND B) OR (C AND D)` gibi ifadeler için yeterli olmadığında kullanılacak araç budur.

- **`condition(QueryCondition sub)`**: `AND` iç içe geçmiş bir grubu açar
- **`orCondition(QueryCondition sub)`**: `OR` iç içe geçmiş bir grup açar
- **`or()`**: sonraki konektörü `OR` olarak değiştirir (varsayılan `AND`'dir)

##### Örnek 1: Karışık VEYA Koşulları
Eşdeğer SQL: `WHERE is_active = true AND (role = 'admin' OR fans >= 1000)`

```dart
final subGroup = QueryCondition()
    .whereEqual('role', 'admin')
    .or()
    .whereGreaterThanOrEqualTo('fans', 1000);

final results = await db.query('users')
    .whereEqual('is_active', true)
    .condition(subGroup);
```

##### Örnek 2: Yeniden Kullanılabilir Durum Parçaları
Yeniden kullanılabilir iş mantığı parçalarını bir kez tanımlayabilir ve bunları farklı sorgularda birleştirebilirsiniz:

```dart
final hotUser = QueryCondition().whereGreaterThan('fans', 5000);
final recentLogin = QueryCondition().whereGreaterThan('last_login', '2024-01-01');

final targetUsers = await db.query('users')
    .condition(hotUser)
    .condition(recentLogin);
```


#### <a id="streaming-query"></a>5. Akış Sorgusu
Her şeyi aynı anda belleğe yüklemek istemediğinizde çok büyük veri kümeleri için uygundur. Sonuçlar okundukça işlenebilir.

```dart
db.streamQuery('users').listen((data) {
  print('Processing one record: $data');
});
```

#### <a id="reactive-query"></a>6. Reaktif Sorgu
`watch()` yöntemi, sorgu sonuçlarını gerçek zamanlı olarak izlemenizi sağlar. Bir `Stream` döndürür ve hedef tabloda eşleşen veriler değiştiğinde sorguyu otomatik olarak yeniden çalıştırır.
- **Otomatik geri dönme**: yerleşik akıllı geri dönme, gereksiz sorgu patlamalarını önler
- **UI senkronizasyonu**: canlı güncelleme listeleri için Flutter `StreamBuilder` ile doğal olarak çalışır

```dart
// Simple listener
db.query('users').whereEqual('is_online', true).watch().listen((users) {
  print('Online user count changed: ${users.length}');
});

// Flutter StreamBuilder integration example
// Local UI refreshes automatically when data changes
StreamBuilder<List<Map<String, dynamic>>>(
  stream: db.query('messages').orderByDesc('id').limit(50).watch(),
  builder: (context, snapshot) {
    if (snapshot.hasData) {
      return ListView.builder(
        itemCount: snapshot.data!.length,
        itemBuilder: (context, index) => MessageTile(snapshot.data![index]),
      );
    }
    return CircularProgressIndicator();
  },
)
```

---

### <a id="query-cache"></a>Manuel Sorgu Sonucunu Önbelleğe Alma (İsteğe bağlı)

> [!IMPORTANT]
> **ToStore zaten dahili olarak verimli, çok seviyeli bir akıllı LRU önbelleği içerir.**
> **Rutin manuel önbellek yönetimi önerilmez.** Bunu yalnızca özel durumlarda düşünün:
> 1. Nadiren değişen, indekslenmemiş veriler üzerinde pahalı tam taramalar
> 2. Sıcak olmayan sorgular için bile kalıcı ultra düşük gecikme gereksinimleri

- `useQueryCache([Duration? expiry])`: önbelleği etkinleştirin ve isteğe bağlı olarak bir son kullanma tarihi ayarlayın
- `noQueryCache()`: bu sorgu için önbelleği açıkça devre dışı bırakın
- `clearQueryCache()`: bu sorgu modeli için önbelleği manuel olarak geçersiz kılın

```dart
final results = await db.query('heavy_table')
    .where('non_indexed_field', '=', 'value')
    .useQueryCache(const Duration(minutes: 10)); // Manual acceleration for a heavy query only
```


### <a id="query-pagination"></a>Sorgu ve Etkin Sayfalama

> [!TIP]
> **Her zaman sayfa boyutu olarak `limit` belirtin**: Sorgularınızda her zaman `limit` belirtmeniz önemle tavsiye edilir. Belirtilmezse, motor tek seferde çok fazla verinin çekilmesini önlemek için varsayılan olarak 1.000 kayıtla sınırlandırır.

ToStore, çift modlu sayfalama desteği sunar. Sonsuz kaydırma veya liste yükleme işlemleri için dahili **sorunsuz imleç (cursor) sayfalamasını** kullanmanızı önemle tavsiye ederiz; belirli sayfalara doğrudan atlamak için ise temel offset sayfalama yeterlidir:

#### 1. Temel Sayfalama (Offset Modu)
Veri hacminin küçük olduğu (örneğin 10k altı) veya belirli bir sayfaya tam olarak atlamanız gereken durumlar için uygundur.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // İlk 40 satırı atla
    .limit(20); // 20 satır al
```
> [!TIP]
> `offset` değeri çok büyüdüğünde, veritabanının çok sayıda kaydı taraması ve atması gerekir, bu da performansı doğrusal olarak düşürür. Derin sayfalama veya daha büyük veri kümeleri için **İmleç Modu** önerilir.

#### 2. İmleç Sayfalama (Cursor Modu - Önerilen)
Büyük veri kümeleri ve sonsuz kaydırma için idealdir. Geçerli sayfanın veri akışının başlangıç konumunu kaydederek, sayfalama sırasında doğrudan bu konuma konumlanır (seek). Geçmiş verileri taramaktan ve atmaktan kaçınarak derin sayfalama hızını her zaman sabit tutar.

* **Otomatik Yönetim**: Sayfa boyutu için limit belirleyin ve sonraki sayfalar için doğrudan `next()` veya `prev()` çağrısı yaparak optimum sayfalama performansını zahmetsizce elde edin.
* **Başlangıç Noktası Sapması**: İlk sorguda başlangıç penceresini konumlandırmak için `.offset(N)` kullanımını destekler; sonrasında `next()` çağrısı sonraki sayfaları doğrudan getirir.

```dart
// 1. İlk sorguyu başlat
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// 2. Sonraki sayfayı getir
if (page1.hasMore) {
  final page2 = await page1.next(); 
  print('Sonraki sayfadaki öğe sayısı: \${page2.data.length}');
  
  // 3. Önceki sayfayı getir
  if (page2.hasPrev) {
    final prevPage = await page2.prev();
    print('Önceki sayfa verileri: \${prevPage.data}');
  }
}
```

##### Gelişmiş Senaryo: Durumsuz Belirteç Tabanlı İmleç Sayfalama (Token-based Cursor)
Uygulama içi günlük sayfalama için yukarıdaki `next()` / `prev()` yöntemlerini tercih edin. İmleç belirteçlerini yalnızca istemci-sunucu API'lerinde veya sayfalama durumunu süreçler/ağlar arasında serileştirmeniz gerektiğinde kullanın:
* İlk sorgu `nextCursorToken` / `prevCursorToken` dizelerini döndürür.
* Sonraki sorgu, seek için `.cursor(token)` ile belirteci iletir.
* **Not**: `cursor` ve `offset` birbirini dışlar; birini ayarlamak diğerini temizler.

```dart
// İlk sorgu (örneğin, API sunucu tarafında)
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

final String? nextToken = page1.nextCursorToken; // Bu belirteci serileştirip istemciye döndürün

// İstemci belirteçle sonraki sayfayı talep ettiğinde:
if (nextToken != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(nextToken); // Doğru şekilde konumlanmak ve okumak için belirteci iletin
}
```

| Özellik | Offset Modu | İmleç Modu |
| :--- | :--- | :--- |
| **Sorgu Performansı** | Sayfa sayısı arttıkça düşer | Derin sayfalama için sabit hız |
| **En İyi Kullanım Yeri** | Küçük veri kümeleri, tam sayfa atlamaları | **Büyük veri kümeleri, sonsuz kaydırma** |
| **Değişikliklerde Tutarlılık** | Veri değişiklikleri yinelenen veya atlanan satırlara neden olabilir | Veri değişikliklerinden kaynaklanan yinelemeleri ve eksiklikleri önler |


### <a id="query-peek"></a>Bellek Probu ve Senkron Arama (peek)

İş hacmi ve gecikme açısından aşırı gereksinimleri olan senaryolar için ToStore, `peek` saf senkron bellek arama serisini sunar ve patlama halindeki sıcak okuma trafiğini doğrudan süreç içinde karşılar: **edge tarafı** saniyede milyonlarca okuma isteğini; **sunucu tarafı** daha güçlü donanımla makine başına on milyonlarca okumayı karşılayabilir (ayrıntılar için [Kıyaslamalar](#performance) bölümüne bakın).

> [!NOTE]
> **Yalnızca bellek önbelleği**: `peek` sıfır zamanlama ile saf bellek bypass'ıdır. Önbellek isabetsizliğinde hemen boş/`null` döner; motor senkron dosya G/Ç yapmaz (yüksek eşzamanlılıkta olay döngüsü tıkanmasını önler). Tam kalıcı sonuçlar için uygulamada `await query()` kullanın.

#### peek API yöntemleri
| Yöntem | Dönüş türü | Açıklama |
| :--- | :--- | :--- |
| `peekFirst()` | `Map<String, dynamic>?` | Tek kayıt; önbellek isabetsizliğinde `null` |
| `peek()` | `QueryResult<T>` | `data` listesi ve sayfalama meta verileri (`hasMore`, imleçler vb.) içeren `QueryResult`; yalnızca önbellek isabetinde veri |
| `peekExists()` | `bool` | Bellek önbelleğinde eşleşen kayıt olup olmadığını senkron kontrol eder |
| `peekCount()` | `int` | Bellek önbelleğindeki eşleşen kayıtları senkron sayar |
| `result.peekNext()` | `QueryResult<T>` | Sayfalama sonucu önbellekteyken senkron sonraki sayfa |
| `result.peekPrev()` | `QueryResult<T>` | Sayfalama sonucu önbellekteyken senkron önceki sayfa |

#### En iyi uygulama: bellek probu öncelikli (Peek-Through)
```dart
// Tek kayıt: önce bellek probu, isabetsizlikte standart asenkron sorgu
final q = db.query('users').where('id', '=', userId);
final user = q.peekFirst() ?? await q.first();

// Sayfalı prob sorgusu
final listQ = db.query('users').orderByDesc('id').limit(20);
var page = listQ.peek();
if (page.data.isEmpty) page = await listQ;

if (page.hasMore) {
  final next = page.peekNext(); // önbellek isabeti: senkron sayfa geçişi
  if (next.data.isEmpty) await page.next();
}
```

#### KV probu (`db.kv`)

| Yöntem | Async eşdeğeri | Açıklama |
| :--- | :--- | :--- |
| `peekGet(key)` | `get(key)` | Senkron bellek nokta sorgusu; süresi dolmuş anahtarlar → `null` |
| `peekExists(key)` | `exists(key)` | Senkron bellek varlık kontrolü |
| `db.kv.query().peek()` | `await db.kv.query()` | Sayfalı senkron prob (önek / sıralama / limit) |
| `db.kv.query().peekFirst()` | `await db.kv.query().first()` | İlk kayıt senkron probu |

```dart
// Nokta: önce prob, isabetsizlikte async geri dönüş
final theme = db.kv.peekGet('theme', isGlobal: true) ?? await db.kv.get('theme', isGlobal: true);

// Sayfalı KV probu
var page = db.kv.query().prefix('setting_').limit(20).peek();
if (page.data.isEmpty) page = await db.kv.query().prefix('setting_').limit(20);
```

> [!TIP]
> **Öneri**: Standart asenkron sorgular (`await query()`) olay zamanlaması ile uzun vadeli kararlılık ve çoklu görev adilliğini sağlar; 100k+ QPS çoğu iş yükü için yeterlidir. `peek` serisi, makine başına milyon/on milyon QPS düzeyindeki aşırı sıcak okuma tepe yüklerini karşılamak için tasarlanmıştır.


### <a id="foreign-keys"></a>Yabancı Anahtarlar ve Basamaklı

Yabancı anahtarlar bilgi bütünlüğünü garanti eder ve basamaklı güncellemeleri ve silmeleri yapılandırmanıza olanak tanır. İlişkiler yazma ve güncelleme sırasında doğrulanır. Basamaklı ilkeler etkinleştirilirse ilgili veriler otomatik olarak güncellenir ve uygulama kodundaki tutarlılık çalışması azalır.

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
          fields: ['user_id'],              // Field in the current table
          referencedTable: 'users',         // Referenced table
          referencedFields: ['id'],         // Referenced field
          onDelete: ForeignKeyCascadeAction.cascade,  // Delete posts automatically when the user is deleted
          onUpdate: ForeignKeyCascadeAction.cascade,  // Cascade updates
        ),
    ],
  ),
]);
```


### <a id="query-operators"></a>Sorgu Operatörleri

Tüm `where(field, operator, value)` koşulları aşağıdaki operatörleri destekler (büyük/küçük harfe duyarlı değildir):

| Operatör | Açıklama | Örnek / Performans |
| :--- | :--- | :--- |
| `=` | Eşit | `where('status', '=', 'val')` — **[Önerilen]** İndeks Arama (Seek) |
| `!=`, `<>` | Eşit değil | `where('role', '!=', 'val')` — **[Dikkat]** Tam Tablo Taraması |
| `>` , `>=`, `<`, `<=` | Karşılaştırma | `where('age', '>', 18)` — **[Önerilen]** İndeks Taraması (Scan) |
| `IN` | Listede | `where('id', 'IN', [...])` — **[Önerilen]** İndeks Arama (Seek) |
| `NOT IN` | Listede yok | `where('status', 'NOT IN', [...])` — **[Dikkat]** Tam Tablo Taraması |
| `BETWEEN` | Aralık | `where('age', 'BETWEEN', [18, 65])` — **[Önerilen]** İndeks Taraması (Scan) |
| `LIKE` | Desen eşleşmesi (`%` = herhangi bir karakter, `_` = tek karakter) | `where('name', 'LIKE', 'John%')` — **[Dikkat]** Aşağıdaki nota bakın |
| `NOT LIKE` | Desen uyuşmazlığı | `where('email', 'NOT LIKE', '...')` — **[Dikkat]** Tam Tablo Taraması |
| `IS` | null | `where('deleted_at', 'IS', null)` — **[Önerilen]** İndeks Arama (Seek) |
| `IS NOT` | null değil | `where('email', 'IS NOT', null)` — **[Dikkat]** Tam Tablo Taraması |

### Anlamsal Sorgu Yöntemleri (Önerilen)

Elle yazılan operatör dizelerinden kaçınmak ve daha iyi IDE yardımı almak için önerilir.

#### 1. Karşılaştırma
Doğrudan sayısal veya dize karşılaştırmaları için kullanılır.

```dart
db.query('users').whereEqual('username', 'John');           // Equal
db.query('users').whereNotEqual('role', 'guest');          // Not equal
db.query('users').whereGreaterThan('age', 18);             // Greater than
db.query('users').whereGreaterThanOrEqualTo('score', 60);  // Greater than or equal
db.query('users').whereLessThan('price', 100);             // Less than
db.query('users').whereLessThanOrEqualTo('quantity', 10);  // Less than or equal
db.query('users').whereTrue('is_active');                  // Is true
db.query('users').whereFalse('is_banned');                 // Is false
```

#### 2. Koleksiyon ve Menzil
Bir alanın bir kümenin veya aralığın içinde olup olmadığını test etmek için kullanılır.

```dart
db.query('users').whereIn('id', ['id1', 'id2']);                 // In list
db.query('users').whereNotIn('status', ['banned', 'pending']);   // Not in list
db.query('users').whereBetween('age', 18, 65);                   // In range (inclusive)
```

#### 3. Boş Kontrol
Bir alanın bir değere sahip olup olmadığını test etmek için kullanılır.

```dart
db.query('users').whereNull('deleted_at');    // Is null
db.query('users').whereNotNull('email');      // Is not null
db.query('users').whereEmpty('nickname');     // Is null or empty string
db.query('users').whereNotEmpty('bio');       // Is not null and not empty
```

#### 4. Desen Eşleştirme
SQL tarzı joker karakter aramasını destekler (`%` herhangi bir sayıda karakterle eşleşir, `_` tek bir karakterle eşleşir).

```dart
db.query('users').whereLike('name', 'John%');                        // SQL-style pattern match
db.query('users').whereContains('bio', 'flutter');                   // Contains match (LIKE '%value%')
db.query('users').whereStartsWith('name', 'Admin');                  // Prefix match (LIKE 'value%')
db.query('users').whereEndsWith('email', '.com');                    // Suffix match (LIKE '%value')
db.query('users').whereContainsAny('tags', ['dart', 'flutter']);     // Fuzzy match against any item in the list
```

```dart
// Equivalent to: .where('age', '>', 18).where('name', 'like', '%John%')
final users = await db.query('users')
    .whereGreaterThan('age', 18)
    .whereLike('username', '%John%')
    .orderByDesc('age')
    .limit(20);
```

> [!CAUTION]
> **Sorgu Performans Rehberi (İndeks vs Tam Tarama)**
>
> Büyük ölçekli veri senaryolarında (milyonlarca satır veya daha fazla), ana iş parçacığı gecikmelerini ve sorgu zaman aşımlarını önlemek için bu ilkelere uyun:
>
> 1. **İndeks Optimize Edilmiş - [Önerilen]**:
>    *   **Anlamsal yöntemler**: `whereEqual`, `whereGreaterThan`, `whereLessThan`, `whereIn`, `whereBetween`, `whereNull`, `whereTrue`, `whereFalse` ve **`whereStartsWith`** (önek eşleşmesi).
>    *   **Operatörler**: `=`, `>`, `<`, `>=`, `<=`, `IN`, `BETWEEN`, `IS null`, `LIKE 'prefix%'`.
>    *   *Açıklama: Bu işlemler, indeksler aracılığıyla ultra hızlı konumlandırma sağlar. `whereStartsWith` / `LIKE 'abc%'` için indeks hala bir önek aralığı taraması gerçekleştirebilir.*
>
> 2. **Tam Tarama Riskleri - [Dikkat]**:
>    *   **Bulanık eşleşme**: `whereContains` (`LIKE '%val%'`), `whereEndsWith` (`LIKE '%val'`), `whereContainsAny`.
>    *   **Negasyon sorguları**: `whereNotEqual` (`!=`, `<>`), `whereNotIn` (`NOT IN`), `whereNotNull` (`IS NOT null`/`whereNotEmpty`).
>    *   **Desen uyuşmazlığı**: `NOT LIKE`.
>    *   *Açıklama: Yukarıdaki işlemler genellikle bir indeks oluşturulmuş olsa bile tüm veri depolama alanının taranmasını gerektirir. Mobil cihazlarda veya küçük veri kümelerinde etkisi minimum olsa da, dağıtılmış analiz veya ultra büyük veri senaryolarında bunlar dikkatli kullanılmalı, diğer indeks koşullarıyla (örneğin, ID veya zaman aralığına göre verileri daraltma) ve `limit` ifadesiyle birleştirilmelidir.*

## <a id="distributed-architecture"></a>Dağıtık Mimari

```dart
// Configure distributed nodes
final db = await ToStore.open(
  config: DataStoreConfig(
    distributedNodeConfig: const DistributedNodeConfig(
      enableDistributed: true,            // Enable distributed mode
      clusterId: 1,                       // Cluster ID
      centralServerUrl: 'https://127.0.0.1:8080',
      accessToken: 'b7628a4f9b4d269b98649129'
    )
  )
);

// Batch insert
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... efficient one-shot insertion of vector records
]);

// Stream and process large datasets
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // Process each result incrementally to avoid loading everything at once
  print(record);
}
```

## <a id="primary-key-examples"></a>Birincil Anahtar Örnekleri

ToStore, farklı iş senaryoları için birden fazla dağıtılmış birincil anahtar algoritması sağlar:

- **Sıralı birincil anahtar** (`PrimaryKeyType.sequential`): `238978991`
- **Zaman damgası tabanlı birincil anahtar** (`PrimaryKeyType.timestampBased`): `1306866018836946`
- **Tarih önekli birincil anahtar** (`PrimaryKeyType.datePrefixed`): `20250530182215887631`
- **Kısa kodlu birincil anahtar** (`PrimaryKeyType.shortCode`): `9eXrF0qeXZ`

```dart
// Sequential primary key configuration example
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,      // Starting value
        increment: 50,            // Step size
        useRandomIncrement: true, // Random step size to hide business volume
      ),
    ),
    fields: [/* field definitions */]
  ),
]);
```


## <a id="atomic-expressions"></a>Atomik İfadeler

İfade sistemi, tür açısından güvenli atom alanı güncellemeleri sağlar. Tüm hesaplamalar veritabanı katmanında atomik olarak yürütülür ve eşzamanlı çakışmalar önlenir:

```dart
// Simple increment: balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// Complex calculation: total = price * quantity + tax
await db.update('orders', {
  'total': Expr.field('price') * Expr.field('quantity') + Expr.field('tax'),
}).where('id', '=', orderId);

// Multi-layer parentheses: finalPrice = ((price * quantity) + tax) * (1 - discount)
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) *
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// Use functions: price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// Timestamp: updatedAt = now()
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

**Koşullu ifadeler (örneğin, bir üstsertta güncelleme ve eklemeyi ayırt etme)**: `Expr.isUpdate()` / `Expr.isInsert()`'yi `Expr.ifElse` veya `Expr.when` ile birlikte kullanın, böylece ifade yalnızca güncellemede veya yalnızca eklemede değerlendirilir.

```dart
// Upsert: increment on update, set to 1 on insert
// The insert branch can use a plain literal; expressions are only evaluated on the update path
await db.upsert('counters', {
  'key': 'visits',
  'count': Expr.ifElse(
    Expr.isUpdate(),
    Expr.field('count') + Expr.value(1),
    1,
  ),
});

// Use Expr.when (single branch, otherwise null)
await db.upsert('orders', {
  'id': orderId,
  'updatedAt': Expr.when(Expr.isUpdate(), Expr.now(), otherwise: Expr.now()),
});
```

## <a id="transactions"></a>İşlemler

İşlemler birden fazla işlem arasında atomiklik sağlar: ya her şey başarılı olur ya da her şey geri alınarak veri tutarlılığı korunur.

**İşlem özellikleri**
- birden fazla işlemin tümü başarılı olur veya tümü geri alınır
- çökmelerden sonra tamamlanmamış işler otomatik olarak kurtarılır
- başarılı operasyonlar güvenli bir şekilde sürdürülür

```dart
// Basic transaction - atomically commit multiple operations
final txResult = await db.transaction(() async {
  // Insert a user
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });

  // Atomic update using an expression
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');

  // If any operation fails, all changes are rolled back automatically
});

if (!txResult.hasErrors) {
  print('İşlem başarıyla tamamlandı');
} else {
  print('İşlem şu nedenlerle geri alındı:');
  for (final status in txResult.statuses) {
    if (status.type != ResultType.success) {
      print(' - [$status.codeKey}] $status.message}');
    }
  }
}

// Automatic rollback on error
final txResult2 = await db.transaction(() async {
  await db.insert('users', {
    'username': 'jane',
    'email': 'jane@example.com',
  });
  throw Exception('Business logic error'); // Trigger rollback
}, rollbackOnError: true);
```


### <a id="database-maintenance"></a>Yönetim ve Bakım

Aşağıdaki API'ler, eklenti tarzı geliştirme, yönetici panelleri ve operasyonel senaryolar için veritabanı yönetimini, tanılamayı ve bakımı kapsar:

- **Masa Yönetimi**
  - `createTable(schema)`: manuel olarak tek bir tablo oluşturun; modül yükleme veya isteğe bağlı çalışma zamanı tablosu oluşturma için kullanışlıdır
  - `getTableSchema(tableName)`: tanımlanmış şema bilgilerini alır; otomatik doğrulama veya kullanıcı arayüzü modeli oluşturma için kullanışlıdır
  - `getTableNames({isGlobal})`: genel schema envanterindeki kullanıcı tablo adlarını listeler. İsteğe bağlı `isGlobal`: `true` yalnızca global, `false` yalnızca global olmayan, atlanırsa ikisi. Global olmayan şemalar alanlar arasında paylaşılır; yalnızca veri izole edilir.
  - `getTableInfo(tableName)`: çalışma zamanı istatistikleri (`totalRecordCount`, `totalTableDataSizeBytes`, `totalIndexDataSizeBytes`, `indexCount`, oluşturma, global mi)
  - `clear(tableName)`: şemayı, dizinleri ve dahili/harici anahtar kısıtlamalarını güvenli bir şekilde korurken tüm tablo verilerini temizleyin
  - `dropTable(tableName)`: bir tabloyu ve şemasını tamamen yok edin; geri döndürülemez
- **Alan Yönetimi**
  - `currentSpaceName`: mevcut aktif alanı gerçek zamanlı olarak alın
  - `listSpaces()`: geçerli veritabanı örneğindeki tüm ayrılmış alanları listeler
  - `getSpaceInfo(useCache: true)`: alan-yerel toplamlar (`totalRecordCount`, tablo/indeks veri boyutu). Meta'dan yeniden hesap için `useCache: false`.
  - `deleteSpace(spaceName)`: belirli bir alanı ve `default` ve mevcut aktif alan hariç tüm verilerini silin
- **Örnek Keşfi**
  - `config`: örneğin son etkili `DataStoreConfig` anlık görüntüsünü inceleyin
  - `instancePath`: fiziksel depolama dizinini tam olarak bulun
  - `getVersion()` / `setVersion(version)`: uygulama düzeyinde geçiş kararları için iş tanımlı sürüm kontrolü (motor sürümü değil)
- **Bakım**
  - `flush(flushStorage: true)`: bekleyen verileri diske zorla; `flushStorage: true` ise sistemden ayrıca alt düzey depolama arabelleklerini temizlemesi istenir
  - `deleteDatabase()`: geçerli örnek için tüm fiziksel dosyaları ve meta verileri kaldırın; dikkatli kullanın
- **Teşhis**
  - `db.status.memory()`: önbellek isabet oranlarını, dizin sayfası kullanımını ve genel yığın tahsisini inceleyin
  - `db.status.space()` / `db.status.table(tableName)`: alanlar ve masalar için canlı istatistikleri ve sağlık bilgilerini inceleyin
  - `db.status.config()`: geçerli çalışma zamanı yapılandırma anlık görüntüsünü inceleyin
  - `db.status.migration(taskId)`: eşzamansız geçiş sürecini gerçek zamanlı olarak izleyin

```dart

final spaces = await db.listSpaces();
final tableNames = await db.getTableNames();
final spaceInfo = await db.getSpaceInfo(useCache: false);
final tableSchema = await db.getTableSchema('users');
final tableInfo = await db.getTableInfo('users');

print('spaces: $spaces');
print('tables: $tableNames');
print(spaceInfo.toJson());
print(tableSchema?.toJson());
print(tableInfo?.toJson());

await db.flush();

final memoryInfo = await db.status.memory();
final configInfo = await db.status.config();
print(memoryInfo.toJson());
print(configInfo.toJson());
```


### <a id="backup-restore"></a>Yedekleme ve Geri Yükleme

Özellikle tek kullanıcılı yerel içe/dışa aktarım, büyük çevrimdışı veri geçişi ve arıza sonrasında sistemin geri alınması için kullanışlıdır:

- **Yedek (`backup`)**
  - `compress`: sıkıştırmanın etkinleştirilip etkinleştirilmeyeceği; varsayılan olarak önerilir ve etkindir
  - `scope`: yedekleme aralığını kontrol eder
    - `BackupScope.database`: tüm alanlar ve genel tablolar da dahil olmak üzere **tüm veritabanı örneğini** yedekler
    - `BackupScope.currentSpace`: genel tablolar hariç yalnızca **geçerli etkin alanı** yedekler
    - `BackupScope.currentSpaceWithGlobal`: **mevcut alanı ve ilgili genel tabloları** yedekler; tek kiracılı veya tek kullanıcılı geçiş için idealdir
- **Geri yükle (`restore`)**
  - `backupPath`: yedekleme paketinin fiziksel yolu
  - `cleanupBeforeRestore`: ilgili mevcut verilerin geri yüklemeden önce sessizce silinip silinmeyeceği; Karışık mantıksal durumlardan kaçınmak için `true` önerilir
  - `deleteAfterRestore`: başarılı geri yükleme sonrasında yedekleme kaynak dosyasını otomatik olarak siler

```dart
// Example: export the full data package for the current user
final backupPath = await db.backup(
  compress: true,
  scope: BackupScope.currentSpaceWithGlobal,
);

// Example: restore from a backup package and clean up the source file automatically
final restored = await db.restore(
  backupPath,
  cleanupBeforeRestore: true,
  deleteAfterRestore: true,
);
```

### <a id="error-handling"></a>Durum Kodları ve Hata Yönetimi

ToStore'da hata ve istisna geri bildirimi için iki kanal vardır:

> [!NOTE]
> **Birleşik Teşhis Temeli**: Yanıt sonuç modeli (`statuses` in `DbResult`/`QueryResult`) aracılığıyla döndürülsün veya ölümcül istisnalar (`statuses` in `DbException`) aracılığıyla fırlatılsın, tüm teşhis durumları yapılandırılmış **`ResultStatus`** sistemine birleşik olarak dayanır ve aynı durum kodlarını paylaşır, bu da tutarlılığı garanti eder.

1. Yanıt Sonuç Modeli (Result-based Response)
Ekleme, güncelleme, silme, sorgulama, işlemler ve çalışma zamanı tablo şeması oluşturma/değiştirme gibi günlük işlemler için. Bu işlemler, kısıt ihlalleri, doğrulama hataları veya geçersiz bağımsız değişkenlerle karşılaştığında istisna fırlatmaz. Bunun yerine ToStore, sonuçları `DbResult` veya `QueryResult` kullanarak sarmalar ve tüm teşhis bilgilerini durum listesine kaydeder. Bu, sıradan iş mantığı hatalarının veritabanını kesintiye uğratmamasını garanti eder.

- **`hasErrors`: Geçerli işlemde herhangi bir hata olup olmadığını belirtir. Toplu işlemlerde veya işlemlerde en az bir hata varsa bu özellik `true` olur.**
- **`statuses`: İşlem için tüm `ResultStatus` teşhislerinin ayrıntılı bir listesi. Toplu işlemler için çok yararlı olan 1:1 sıra eşleşmesini destekler.**
- **`firstPrimaryKey`: `statuses` bileşenini manuel olarak ayrıştırmadan, tek bir ekleme/yazma işlemi sırasında doğrudan fiziksel olarak oluşturulan birincil anahtarı okur.**
- **`ResultType`: Dal yönetimi ve kontroller için uygun durum kategorisi numaralandırması (örneğin, `isBusinessError`, `isDeveloperError`).**

2. İstisna Fırlatma (Exception-based Throwing)
Geliştirici hatası veya tasarım kusurlarından kaynaklanan ölümcül hatalar için (örneğin, `ToStore.open` sırasında şema doğrulama hatası, motor sürümü uyuşmazlığı, ölümcül veri taşıma bozulması vb.). Bu durumlarda ToStore, yürütmeyi durdurmak için `DbException` fırlatır ve geliştiriciyi bunu düzeltmeye teşvik eder.

> [!WARNING]
> Geliştirme Kılavuzları: Sıradan iş hataları istisna fırlatmamalıdır; uygulamanın çalışma zamanını bozmamak için yanıt sonuç modelinde döndürülmelidir.

---

### Hata ve İstisna Örnekleri

#### 1. Tekli Yazma Yanıtı Yönetimi

```dart
final result = await db.insert('users', {
  'username': 'john',
  'email': 'john@example.com',
});

if (result.hasErrors) {
  // İlk hata türünü ve açıklamasını al
  print('Operation failed: [\${result.firstType.codeKey}] \${result.message}');
} else {
  print('Yazma başarılı, birincil anahtar: \${result.firstPrimaryKey}');
}
```

#### 2. Toplu Yazma Hassas Teşhis

```dart
final batchResult = await db.batchInsert('users', [
  {'username': 'alice', 'email': 'alice@example.com'},
  {'username': 'bob', 'email': 'invalid-email-format'}, // Validation fails
]);

if (batchResult.hasErrors) {
  print('Toplu işlem kısmen başarısız oldu: başarılı \${batchResult.successCount}, başarısız \${batchResult.failedCount}');
  
  for (final status in batchResult.statuses) {
    final int idx = status.index;
    
    if (status is ConstraintStatus) {
      print('Index [\$idx] Kısıt ihlali! Tablo! Tablo: \${status.tableName}, alanlar: \${status.fields}');
    } else if (status is InvalidArgumentStatus) {
      print('Index [\$idx] Bağımsız değişken hatası! Parametre! Parameter: \${status.parameterName}, geçen değer: \${status.passedValue}');
    } else if (status.type != ResultType.success) {
      print('Index [\$idx] bir hata oluştu: [\${status.codeKey}] \${status.message}');
    }
  }
}
```

#### 3. Ölümcül Hata og Başlatma İstisnası Yakalama (DbException)

```dart
try {
  // Initialize database with schemas that might have validation issues
  final db = await ToStore.open(schemas: appSchemas);
} on DbException catch (e) {
  print('❌ Ölümcül veritabanı istisnası! Hata mesajı: \n\${e.message}');
  
  // Iterate through the detailed status list in the exception
  for (final status in e.statuses) {
    if (status is SchemaValidationStatus) {
      print('Şema doğrulaması başarısız oldu! Tablo! Tablo: \${status.tableName}, alan: \${status.field}, geçersiz yapılandırma: \${status.wrongValue}');
    } else {
      print('Teşhis bilgisi: [\${status.codeKey}] \${status.message}');
    }
  }
}
```

Hata türleri, yaprak durum kodları, JSON serileştirme biçimleri ve alan eşlemelerinin tam listesi için lütfen tam spesifikasyona bakın: [ToStore ResultStatus Otomatik Teşhis ve Durum Çözümleme Spesifikasyonu](result_status_specification.md).

### <a id="logging-diagnostics"></a>Günlük Geri Arama ve Veritabanı Tanılama
ToStore, veritabanı yaşam döngüsü günlüklerini `ToStore.setLogConfig(...)` aracılığıyla iş katmanına geri yönlendirebilir.

- `onLog` geri araması, mevcut `enableLog` ve `logLevel` filtrelerini geçen tüm `LogRecord` günlük kayıtlarını alır.
  - **LogLevel.error**: Yerel bir hata oluştu, normal çalışmayı etkilemez.
  - **LogLevel.critical**: Manuel müdahale gerektiren genel afet düzeyinde hata (disk dolu, yetersiz bellek, kritik geçiş hatası vb.). Bu düzeyde alarm bildirimlerinin tetiklenmesi önerilir.
- Başlatmadan önce `ToStore.setLogConfig(...)`'yi çağırın, böylece başlatma ve otomatik geçiş sırasında oluşturulan günlükler de yakalanır.

```dart
  // Günlük parametrelerini veya geri aramayı yapılandırın
  ToStore.setLogConfig(
    enableLog: true,
    logLevel: debugMode ? LogLevel.debug : LogLevel.warn,
    logLabel: 'my_app_db', // Uygulamaları veya veritabanı örneklerini ayırt etmek için günlüğün üstündeki açık gri başlık,
    onLog: (log) {
      // Üretimde, warn/error/critical backend veya günlük platformuna bildirilebilir
      // log.level günlük düzeyine karşılık gelir (LogLevel.debug, info, warn, error, critical)
      // log.message işlenen günlük metnine karşılık gelir
      // log.status temel ResultStatus teşhis durumuna karşılık gelir (code ve codeKey içerir)
      if (!debugMode && (log.level == LogLevel.warn || log.level == LogLevel.error || log.level == LogLevel.critical)) {
        developer.log(log.message, name: 'my_app_db', time: log.timestamp);
      }
    },
  );

  final db = await ToStore.open();
```
## <a id="security-config"></a>Güvenlik Yapılandırması

> [!WARNING]
> **Anahtar yönetimi**
>
> | Anahtar | Rol | Nasıl değiştirilir | Verilerin tamamen yeniden yazılması? |
> | :--- | :--- | :--- | :--- |
> | **`encodingKey`** | Veri şifreleme anahtarı | Yeni değer ayarlayıp tekrar `open` | **Evet** (yavaş) |
> | **`encryptionKey`** | Güvenlik anahtarı; `encodingKey`'i korur | Çalışma zamanında `db.rotateEncryptionKey` çağırın | **Hayır** (hızlı) |
>
> Hassas anahtarları asla sabit kodlamayın. Cihaza bağlamak için `encryptionKey` değerini OS Keychain / Keystore / güvenli enclave’de saklayıp motora iletin.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // Supported: none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305,

      // Data encryption key: encrypts table/index/log data; changing it triggers a background rewrite
      encodingKey: 'Your-Encoding-Key...',

      // Security key: protects encodingKey; rotate online via db.rotateEncryptionKey
      encryptionKey: 'Your-Secure-Encryption-Key...',

      // standard: critical table data, B-tree indexes, and log payloads
      // full: encrypts the entire engine files
      encryptionScope: EncryptionScope.standard,
    ),
    // Enable crash recovery logging (Write-Ahead Logging), enabled by default
    enableJournal: true,
    // Whether transactions force data to disk on commit; set false to reduce sync overhead
    persistRecoveryOnCommit: true,
  ),
);
```

**`encodingKey` değiştirme**: `EncryptionConfig` içinde yeni değeri ayarlayın ve tekrar `open` çağırın. Motor değişikliği algılar ve verileri arka planda otomatik olarak taşır; uygulama tarafında ek işlem gerekmez.

**`encryptionKey` rotasyonu** (periyodik güvenlik/uyumluluk rotasyonu): veri yeniden yazımı yok; çevrimiçi çalıştırılabilir.

```dart
// If encryptionKey was never set explicitly, oldKey can be omitted
final result = await db.rotateEncryptionKey(newKey: 'new-secure-key');
// Or: await db.rotateEncryptionKey(oldKey: 'old-key', newKey: 'new-key');
if (result.hasErrors) {
  // Hata işleme (yanlış oldKey, encodingKey taşıması devam ediyor vb.)
  return;
}
// Başarılı: bellekteki yapılandırma güncellendi; sonraki ToStore.open çağrısında güncel encryptionKey verin
```

### Değer Düzeyinde Şifreleme (ToCrypto)

Tam veritabanı şifrelemesi tüm tablo ve dizin verilerini korur ancak genel performansı etkileyebilir. Yalnızca birkaç hassas değeri korumanız gerekiyorsa bunun yerine **ToCrypto** kullanın. Veritabanından ayrılmıştır, `db` örneği gerektirmez ve uygulamanızın yazmadan önce veya okumadan sonra değerleri kodlamasına/kod çözmesine olanak tanır. Çıktı, JSON veya TEXT sütunlarına doğal olarak uyan Base64'tür.

- **`key`** (gerekli): `String` veya `Uint8List`. 32 bayt değilse, 32 baytlık bir anahtar türetmek için SHA-256 kullanılır.
- **`type`** (isteğe bağlı): `ToCryptoType`'den gelen şifreleme türü, örneğin `ToCryptoType.chacha20Poly1305` veya `ToCryptoType.aes256Gcm`. Varsayılan olarak `ToCryptoType.chacha20Poly1305` şeklindedir.
- **`aad`** (isteğe bağlı): `Uint8List` türünde ek kimliği doğrulanmış veriler. Kodlama sırasında sağlanmışsa, kod çözme sırasında da tam olarak aynı baytların sağlanması gerekir.

```dart
const key = 'my-secret-key';
// Encode: plaintext -> Base64 ciphertext (can be stored in DB or JSON)
final cipher = ToCrypto.encode('sensitive data', key: key);
// Decode when reading
final plain = ToCrypto.decode(cipher, key: key);

// Optional: bind contextual data with aad (must match during decode)
final aad = Uint8List.fromList(utf8.encode('users:id_number'));
final cipher2 = ToCrypto.encode('secret', key: key, aad: aad);
final plain2 = ToCrypto.decode(cipher2, key: key, aad: aad);
```


## <a id="advanced-config"></a>Gelişmiş Yapılandırma Açıklaması (DataStoreConfig)

> [!TIP]
> **Sıfır Yapılandırma zekası**
> ToStore, eşzamanlılık, parça boyutu ve önbellek bütçesi gibi parametreleri optimize etmek için platformu, performans özelliklerini, kullanılabilir belleği ve G/Ç davranışını otomatik olarak algılar. **Yaygın iş senaryolarının %99'unda, `DataStoreConfig`'da manuel olarak ince ayar yapmanıza gerek yoktur.** Varsayılanlar halihazırda mevcut platform için mükemmel performans sağlamaktadır.


| Parametre | Varsayılan | Amaç ve Öneri |
| :--- | :--- | :--- |
| **`yieldDurationMs`** | **8ms** | **Temel öneri.** Uzun görevler verimli olduğunda kullanılan zaman dilimi. `8ms`, 120 fps/60 fps işlemeyle iyi uyum sağlar ve büyük sorgular veya geçişler sırasında kullanıcı arayüzünün sorunsuz kalmasına yardımcı olur. |
| **`maxQueryOffset`** | **10000** | **Sorgu koruması.** `offset` bu eşiği aştığında bir hata ortaya çıkar. Bu, patolojik G/Ç'nin derin ofset sayfalandırmasını önler. |
| **`defaultQueryLimit`** | **1000** | **Kaynak koruması.** Bir sorguda `limit` belirtilmediğinde uygulanır; böylece çok büyük sonuç kümelerinin yanlışlıkla yüklenmesi ve olası OOM sorunları önlenir. |
| **`cacheMemoryBudgetMB`** | (otomatik) | **İnce taneli bellek yönetimi.** Toplam önbellek bütçesi. Motor bunu LRU ıslahını otomatik olarak gerçekleştirmek için kullanır. |
| **`enableJournal`** | **doğru** | **Çökme durumunda kendi kendini iyileştirme.** Etkinleştirildiğinde, motor, çarpma veya elektrik kesintilerinden sonra otomatik olarak iyileşebilir. |
| **`persistRecoveryOnCommit`** | **doğru** | **Güçlü dayanıklılık garantisi.** Doğru olduğunda, taahhüt edilen işlemler fiziksel depolamayla senkronize edilir. Yanlış olduğunda, temizleme işlemi daha iyi hız için arka planda eşzamansız olarak yapılır; aşırı çökmelerde çok küçük miktarda veri kaybı riski vardır. |
| **`ttlCleanupIntervalMs`** | **300000** | **Genel TTL yoklaması.** Motor boşta değilken süresi dolmuş verileri taramak için arka plan aralığı. Daha düşük değerler, süresi dolmuş verileri daha çabuk siler ancak daha fazla masrafa neden olur. |
| **`maxConcurrency`** | (otomatik) | **Hesaplama eşzamanlılık kontrolü.** Vektör hesaplama ve şifreleme/şifre çözme gibi yoğun görevler için maksimum paralel çalışan sayısını ayarlar. Otomatik tutmak genellikle en iyisidir. |

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    yieldDurationMs: 8, // Excellent for frontend UI smoothness; for servers, 50ms is often better
    defaultQueryLimit: 50, // Force a maximum result-set size
    enableJournal: true, // Ensure crash self-healing
  ),
);
```

---

## <a id="performance"></a>Performans ve Deneyim

### Karşılaştırmalar

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="ToStore Basic Performance Demo" width="320" />
</p>

- **Temel performans demosu** (<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4" target="_blank" rel="noopener">basic-demo.mp4</a>): GIF önizlemesi her şeyi göstermeyebilir. Gösterimin tamamı için lütfen videoyu açın. Sıradan mobil cihazlarda bile, veri kümesi 100 milyon kaydı aştığında bile başlatma, sayfalama ve alma işlemleri istikrarlı ve sorunsuz kalır.

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="ToStore Disaster Recovery Stress Test" width="320" />
</p>

- **Olağanüstü durum kurtarma stres testi** (<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4" target="_blank" rel="noopener">disaster-recovery.mp4</a>): yüksek frekanslı yazmalar sırasında, çökmeleri ve elektrik kesintilerini simüle etmek için süreç kasıtlı olarak tekrar tekrar kesintiye uğrar. ToStore hızlı bir şekilde kurtarılabilir.


### Deneyim İpuçları

- 📱 **Örnek proje**: `example` dizini tam bir Flutter uygulaması içerir
- 🚀 **Üretim yapıları**: yayın modunda paketleyin ve test edin; sürüm performansı hata ayıklama modunun çok ötesinde
- ✅ **Standart testler**: temel yetenekler standart testlerin kapsamındadır


ToStore size yardımcı oluyorsa lütfen bize bir ⭐️ verin, bu projeyi desteklemenin en iyi yollarından biridir. Çok teşekkür ederim!

## <a id="contribute"></a>🤝 Katkıda Bulunma

ToStore sürekli gelişen modern bir veri motorudur ve topluluk katkılarını içtenlikle karşılıyoruz.
İster hata düzeltme, ister belge iyileştirme, mimari geliştirme veya yeni fikir önerme olsun, PR aracılığıyla katılabilirsiniz:

- 🔗 **PR Gönder**: [Pull Requests](https://github.com/tocreator/tostore/pulls)
- 📖 **Belgeler**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **Sorun Bildirme**: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **Teknik Tartışma**: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)


