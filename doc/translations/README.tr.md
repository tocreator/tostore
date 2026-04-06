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

<<<<<<< HEAD
## Hızlı Gezinme
- **Başlarken**: [Neden Saklamalı](#why-tostore) | [Temel Özellikler](#key-features) | [Kurulum Kılavuzu](#installation) | [KV Modu](#quick-start-kv) | [Tablo Modu](#quick-start-table) | [Bellek Modu](#quick-start-memory)
- **Mimari ve Model**: [Şema Tanımı](#schema-definition) | [Dağıtılmış Mimari](#distributed-architecture) | [Basamaklı Yabancı Anahtarlar](#foreign-keys) | [Mobil/Masaüstü](#mobile-integration) | [Sunucu/Aracı](#server-integration) | [Birincil Anahtar Algoritmaları](#primary-key-examples)
- **Gelişmiş Sorgular**: [Gelişmiş Sorgular (KATIL)](#query-advanced) | [Toplama ve İstatistikler](#aggregation-stats) | [Karmaşık Mantık (Sorgu Durumu)](#query-condition) | [Reaktif Sorgu (izle)](#reactive-query) | [Akış Sorgusu](#streaming-query)
- **Gelişmiş ve Performans**: [Vektör Arama](#vector-advanced) | [Tablo düzeyinde TTL](#ttl-config) | [Etkili Sayfalandırma](#query-pagination) | [Sorgu Önbelleği](#query-cache) | [Atomik İfadeler](#atomic-expressions) | [İşlemler](#transactions)
- **Operasyonlar ve Güvenlik**: [Yönetim](#database-maintenance) | [Güvenlik Yapılandırması](#security-config) | [Hata İşleme](#error-handling) | [Performans ve Tanılama](#performance) | [Daha Fazla Kaynak](#more-resources)
=======

## Hızlı Gezinti

- [Neden ToStore?](#why-tostore) | [Temel Özellikler](#key-features) | [Kurulum](#installation) | [Hızlı Başlangıç](#quick-start)
- [Şema Tanımlama](#schema-definition) | [Mobil/Masaüstü Entegrasyonu](#mobile-integration) | [Sunucu Tarafı Entegrasyonu](#server-integration)
- [Vektör ve ANN Arama](#vector-advanced) | [Tablo Düzeyinde TTL](#ttl-config) | [Sorgu ve Sayfalama](#query-pagination) | [Yabancı Anahtarlar](#foreign-keys) | [Sorgu İşleçleri](#query-operators)
- [Dağıtık Mimari](#distributed-architecture) | [Birincil Anahtar Örnekleri](#primary-key-examples) | [Atomik İfade İşlemleri](#atomic-expressions) | [İşlemler (Transactions)](#transactions) | [Veritabanı Yönetimi ve Bakım](#database-maintenance) | [Yedekleme ve Geri Yükleme](#backup-restore) | [Hata Yönetimi](#error-handling) | [Log geri çağrısı ve veritabanı tanısı](#logging-diagnostics)
- [Güvenlik Yapılandırması](#security-config) | [Performans](#performance) | [Kaynaklar](#more-resources)

>>>>>>> 4f6c638c44ecdff1a3a62c3210da8f3c60d63f5c

<a id="why-tostore"></a>
## Neden ToStore'u Seçmelisiniz?

ToStore, AGI dönemi ve uç zeka senaryoları için tasarlanmış modern bir veri motorudur. Yerel olarak dağıtılmış sistemleri, çok modlu füzyonu, ilişkisel yapılandırılmış verileri, yüksek boyutlu vektörleri ve yapılandırılmamış veri depolamayı destekler. Kendi Kendini Yönlendiren düğüm mimarisi ve sinir ağından ilham alan bir motor üzerine inşa edilmiş olup, performansı veri ölçeğinden mantıksal olarak ayırırken düğümlere yüksek özerklik ve esnek yatay ölçeklenebilirlik sağlar. ACID işlemlerini, karmaşık ilişkisel sorguları (JOIN'ler ve basamaklı yabancı anahtarlar), tablo düzeyinde TTL ve toplamaların yanı sıra birden fazla dağıtılmış birincil anahtar algoritması, atomik ifadeler, şema değişikliği tanıma, şifreleme, çok alanlı veri izolasyonu, kaynağa duyarlı akıllı yük planlaması ve felaket/çökme kendi kendini onaran kurtarmayı içerir.

Bilgi işlem uç zekaya doğru kaymaya devam ettikçe aracılar, sensörler ve diğer cihazlar artık yalnızca "içerik ekranları" değildir. Bunlar yerel üretimden, çevresel farkındalıktan, gerçek zamanlı karar alma ve koordineli veri akışlarından sorumlu akıllı düğümlerdir. Geleneksel veritabanı çözümleri, temel mimarileri ve birleştirilmiş uzantıları nedeniyle sınırlıdır; bu da, yüksek eşzamanlılık yazmaları, büyük veri kümeleri, vektör alma ve işbirliğine dayalı oluşturma altında uç bulut akıllı uygulamalarının düşük gecikme ve kararlılık gereksinimlerini karşılamayı giderek zorlaştırmaktadır.

ToStore, büyük veri kümeleri, karmaşık yerel yapay zeka üretimi ve büyük ölçekli veri hareketi için yeterince güçlü uç dağıtılmış yetenekler sunar. Uç ve bulut düğümleri arasındaki derin akıllı işbirliği, sürükleyici karma gerçeklik, çok modlu etkileşim, anlamsal vektörler, uzamsal modelleme ve benzer senaryolar için güvenilir bir veri temeli sağlar.

<a id="key-features"></a>
## Temel Özellikler

- 🌐 **Birleşik Platformlar Arası Veri Motoru**
  - Mobil, masaüstü, web ve sunucu ortamlarında birleşik API
  - İlişkisel yapılandırılmış verileri, yüksek boyutlu vektörleri ve yapılandırılmamış veri depolamayı destekler
  - Yerel depolamadan uç bulut işbirliğine kadar bir veri hattı oluşturur

- 🧠 **Sinir Ağı Tarzında Dağıtılmış Mimari**
  - Fiziksel adreslemeyi ölçekten ayıran kendi kendini yönlendiren düğüm mimarisi
  - Yüksek düzeyde özerk düğümler, esnek bir veri topolojisi oluşturmak için işbirliği yapar
  - Düğüm işbirliğini ve elastik yatay ölçeklendirmeyi destekler
  - Uçta akıllı düğümler ve bulut arasında derin bağlantı

- ⚡ **Paralel Yürütme ve Kaynak Planlama**
  - Yüksek kullanılabilirlik ile kaynağa duyarlı akıllı yük planlaması
  - Çok düğümlü paralel işbirliği ve görev ayrıştırma
  - Zaman dilimleme, kullanıcı arayüzü animasyonlarının ağır yük altında bile düzgün kalmasını sağlar

- 🔍 **Yapılandırılmış Sorgular ve Vektör Alma**
  - Karmaşık tahminleri, JOIN'leri, toplamaları ve tablo düzeyinde TTL'yi destekler
  - Vektör alanlarını, vektör indekslerini ve en yakın komşu alımını destekler
  - Yapılandırılmış ve vektörel veriler aynı motor içerisinde birlikte çalışabilmektedir.

- 🔑 **Birincil Anahtarlar, Dizinler ve Şema Gelişimi**
  - Sıralı, zaman damgası, tarih öneki ve kısa kod stratejilerini içeren yerleşik birincil anahtar algoritmaları
  - Benzersiz indeksleri, bileşik indeksleri, vektör indekslerini ve yabancı anahtar kısıtlamalarını destekler
  - Şema değişikliklerini otomatik olarak algılar ve taşıma işlemini tamamlar

- 🛡️ **İşlemler, Güvenlik ve Kurtarma**
  - ACID işlemleri, atomik ifade güncellemeleri ve basamaklı yabancı anahtarlar sağlar
  - Kilitlenme kurtarmayı, dayanıklı taahhütleri ve tutarlılık garantilerini destekler
  - ChaCha20-Poly1305 ve AES-256-GCM şifrelemesini destekler

- 🔄 **Çoklu Alan ve Veri İş Akışları**
  - İsteğe bağlı küresel olarak paylaşılan verilerle izole alanları destekler
  - Gerçek zamanlı sorgu dinleyicilerini, çok düzeyli akıllı önbelleğe almayı ve imleç sayfalandırmayı destekler
  - Çok kullanıcılı, öncelikli yerel ve çevrimdışı işbirliğine dayalı uygulamalara uygundur

<a id="installation"></a>
## Kurulum

> [!IMPORTANT]
> **V2.x'ten yükseltme mi yapıyorsunuz?** Kritik geçiş adımları ve önemli değişiklikler için lütfen [v3.x Yükseltme Kılavuzu](../UPGRADE_GUIDE_v3.md)'nu okuyun.

`pubspec.yaml`'ınıza `tostore` ekleyin:

```yaml
dependencies:
  tostore: any # Please use the latest version
```

<a id="quick-start"></a>
## Hızlı Başlangıç

> [!TIP]
<<<<<<< HEAD
> **Depolama modunu nasıl seçmelisiniz?**
> 1. [**Anahtar-Değer Modu (KV)**](#quick-start-kv): Yapılandırma erişimi, dağınık durum yönetimi veya JSON veri depolama için en iyisi. Başlamanın en hızlı yoludur.
> 2. [**Yapılandırılmış Tablo Modu**](#quick-start-table): Karmaşık sorgular, kısıtlama doğrulama veya büyük ölçekli veri yönetimi gerektiren temel iş verileri için en iyisi. Bütünlük mantığını motora aktararak uygulama katmanı geliştirme ve bakım maliyetlerini önemli ölçüde azaltabilirsiniz.
> 3. [**Bellek Modu**](#quick-start-memory): Geçici hesaplama, birim testleri veya **ultra hızlı küresel durum yönetimi** için en iyisi. Global sorgular ve `watch` dinleyicilerle, bir yığın global değişkeni muhafaza etmeden uygulama etkileşimini yeniden şekillendirebilirsiniz.

<a id="quick-start-kv"></a>
### Anahtar-Değer Depolama (KV)
Bu mod, önceden tanımlanmış yapılandırılmış tablolara ihtiyacınız olmadığında uygundur. Basittir, pratiktir ve yüksek performanslı bir depolama motoruyla desteklenir. **Etkili indeksleme mimarisi, çok büyük veri ölçeklerindeki sıradan mobil cihazlarda bile sorgu performansını son derece istikrarlı ve son derece duyarlı tutar.** Farklı Alanlardaki veriler doğal olarak izole edilirken küresel paylaşım da desteklenir.
=======
> **Yapılandırılmış ve yapılandırılmamış verilerin birlikte depolanmasını destekler**
> Depolama yöntemi nasıl seçilmeli?
> 1. **Temel iş verileri**: [Şema Tanımlama](#schema-definition) önerilir. Karmaşık sorgular, kısıt doğrulamaları, ilişkiler ve yüksek güvenlik gereksinimleri için uygundur. Bütünlük mantığını motora indirmek, uygulama katmanındaki geliştirme ve bakım maliyetini belirgin şekilde azaltır.
> 2. **Dinamik/dağınık veriler**: Doğrudan [Anahtar-Değer Depolama (KV)](#quick-start) kullanabilir veya tabloda `DataType.json` alanları tanımlayabilirsiniz. Yapılandırma erişimi ve dağınık durum yönetimi için uygundur; hızlı başlangıç ve yüksek esneklik sağlar.

### Yapılandırılmış tablo modu (Table)
CRUD işlemleri için tablo şemasının önceden oluşturulması gerekir (bkz. [Şema Tanımlama](#schema-definition)). Senaryoya göre önerilen entegrasyon yaklaşımı:
- **Mobil/Masaüstü**: [Sık başlatılan senaryolar](#mobile-integration) için, örnek başlatılırken `schemas` geçirilmesi önerilir.
- **Sunucu/Ajan**: [Sürekli çalışan senaryolar](#server-integration) için, tabloların `createTables` ile dinamik olarak oluşturulması önerilir.
>>>>>>> 4f6c638c44ecdff1a3a62c3210da8f3c60d63f5c

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

<a id="quick-start-table"></a>
### Yapılandırılmış Tablo Modu
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
// It is recommended to always check isSuccess
if (result.isSuccess) {
  print('Insert succeeded, generated primary key ID: ${result.successKeys.first}');
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

<a id="quick-start-memory"></a>
### Hafıza Modu

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


<a id="schema-definition"></a>
<<<<<<< HEAD
## Şema Tanımı
**Bir kez tanımlayın ve uygulamanızın artık ağır doğrulama bakımı gerektirmemesi için motorun uçtan uca otomatik yönetimi yönetmesine izin verin.**
=======
## Şema Tanımlama
**Tek seferlik tanım, motorun uçtan uca otomatik yönetimi üstlenmesini sağlar ve uygulamayı ağır doğrulama bakım yükünden uzun vadede kurtarır.**

Aşağıdaki mobil, sunucu ve ajan örnekleri burada tanımlanan `appSchemas` yapısını yeniden kullanır.
>>>>>>> 4f6c638c44ecdff1a3a62c3210da8f3c60d63f5c

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
      type: IndexType.btree, // Index type: btree/hash/bitmap/vector
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


### Bir Entegrasyon Yöntemi Seçme

- **Mobil/Masaüstü**: `appSchemas`'yi doğrudan `ToStore.open(...)`'ye aktarırken en iyisi
- **Sunucu/Aracı**: Çalışma zamanında `createTables(appSchemas)` aracılığıyla dinamik olarak şemalar oluştururken en iyisidir


<a id="mobile-integration"></a>
## Mobil, Masaüstü ve Diğer Sık Başlatma Senaryoları için Entegrasyon

📱 **Örnek**: [mobile_quickstart.dart](../../example/lib/mobile_quickstart.dart)

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

### Şema Gelişimi

`ToStore.open()` sırasında motor, `schemas`'daki tablo ve alanların eklenmesi, kaldırılması, yeniden adlandırılması veya değiştirilmesi gibi yapısal değişikliklerin yanı sıra dizin değişikliklerini de otomatik olarak algılar ve ardından gerekli geçiş çalışmasını tamamlar. Veritabanı sürüm numaralarını manuel olarak korumanıza veya geçiş komut dosyaları yazmanıza gerek yoktur.


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


<a id="server-integration"></a>
## Sunucu Tarafı / Aracı Entegrasyonu (Uzun Süreli Senaryolar)

🖥️ **Örnek**: [sunucu_hızlıbaşlangıç.dart](../../example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// Create table structures while the process is running
await db.createTables(appSchemas);

// Online schema updates
final taskId = await db.updateSchema('users')
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
  .setPrimaryKeyConfig(                    // Change PK type; existing data must be empty or a warning will be issued
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );

// Monitor migration progress
final status = await db.queryMigrationTaskStatus(taskId);
print('Migration progress: ${status?.progressPercentage}%');


// Optional performance tuning for pure server workloads
// yieldDurationMs controls how often long-running work yields time slices.
// The default is tuned to 8ms to keep frontend UI animations smooth.
// In environments without UI, 50ms is recommended for higher throughput.
final dbServer = await ToStore.open(
  config: DataStoreConfig(yieldDurationMs: 50),
);
```


<a id="advanced-usage"></a>
## Gelişmiş Kullanım

ToStore, karmaşık iş senaryoları için zengin bir dizi gelişmiş yetenek sağlar:


<a id="vector-advanced"></a>
### Vektör Alanları, Vektör İndeksleri ve Vektör Arama

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
        type: DataType.vector, // Declare a vector field
        nullable: false,
        vectorConfig: VectorFieldConfig(
          dimensions: 128, // Written and queried vectors must match this width
          precision: VectorPrecision.float32, // float32 usually balances precision and storage well
        ),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['embedding'], // Field to index
        type: IndexType.vector, // Build a vector index
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh, // Built-in vector index type
          distanceMetric: VectorDistanceMetric.cosine, // Good for normalized embeddings
          maxDegree: 32, // More neighbors usually improve recall at higher memory cost
          efSearch: 64, // Higher recall but slower queries
          constructionEf: 128, // Higher-quality index but slower build time
        ),
      ),
    ],
  ),
]);

final queryVector =
    VectorData.fromList(List.generate(128, (i) => i * 0.01)); // Must match dimensions

// Vector search
final results = await db.vectorSearch(
  'embeddings',
  fieldName: 'embedding',
  queryVector: queryVector,
  topK: 5, // Return the top 5 nearest records
  efSearch: 64, // Override the search expansion factor for this request
);

for (final r in results) {
  print('pk=${r.primaryKey}, score=${r.score}, distance=${r.distance}');
}
```

Parametre notları:

- `dimensions`: yazdığınız gerçek yerleştirme genişliğiyle eşleşmelidir
- `precision`: yaygın seçenekler arasında `float64`, `float32` ve `int8` yer alır; daha yüksek hassasiyet genellikle daha fazla depolamaya mal olur
- `distanceMetric`: `cosine` anlamsal yerleştirmeler için yaygındır, `l2` Öklid mesafesine uygundur ve `innerProduct` nokta-çarpım aramasına uygundur
- `maxDegree`: NGH grafiğinde düğüm başına tutulan komşuların üst sınırı; daha yüksek değerler genellikle daha fazla bellek ve derleme süresi pahasına hatırlamayı iyileştirir
- `efSearch`: arama süresi genişletme genişliği; bunu artırmak genellikle hatırlamayı iyileştirir ancak gecikmeyi artırır
- `constructionEf`: derleme zamanı genişletme genişliği; bunu artırmak genellikle dizin kalitesini artırır ancak derleme süresini artırır
- `topK`: döndürülecek sonuç sayısı

Sonuç notları:

- `score`: normalleştirilmiş benzerlik puanı, genellikle `0 ~ 1` aralığında; daha büyük, daha benzer anlamına gelir
- `distance`: mesafe değeri; `l2` ve `cosine` için daha küçük, genellikle daha benzer anlamına gelir

<a id="ttl-config"></a>
### Tablo düzeyinde TTL (Otomatik Zamana Dayalı Sona Erme)

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


### Akıllı Depolama (Yukarı Ekle)
ToStore, `data`'de bulunan birincil anahtara veya benzersiz anahtara göre güncelleme veya ekleme kararı verir. `where` burada desteklenmemektedir; çakışma hedefi verilerin kendisi tarafından belirlenir.

```dart
// By primary key
final result = await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});

// By unique key (the record must contain all fields from a unique index plus required fields)
await db.upsert('users', {
  'username': 'john',
  'email': 'john@example.com',
  'age': 26,
});

// Batch upsert (supports atomic mode or partial-success mode)
// allowPartialErrors: true means some rows may fail while others still succeed
final batchResult = await db.batchUpsert('users', [
  {'username': 'a', 'email': 'a@example.com'},
  {'username': 'b', 'email': 'b@example.com'},
], allowPartialErrors: true);
```


<a id="query-advanced"></a>
### Gelişmiş Sorgular

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

<a id="aggregation-stats"></a>
### Toplama, Gruplandırma ve İstatistik (Toplama ve Gruplandırma)

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

<a id="query-condition"></a>
#### 4. `QueryCondition` ile Karmaşık Mantık
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


<a id="streaming-query"></a>
#### 5. Akış Sorgusu
Her şeyi aynı anda belleğe yüklemek istemediğinizde çok büyük veri kümeleri için uygundur. Sonuçlar okundukça işlenebilir.

```dart
db.streamQuery('users').listen((data) {
  print('Processing one record: $data');
});
```

<a id="reactive-query"></a>
#### 6. Reaktif Sorgu
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

<a id="query-cache"></a>
### Manuel Sorgu Sonucunu Önbelleğe Alma (İsteğe bağlı)

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


<a id="query-pagination"></a>
### Sorgu ve Verimli Sayfalandırma

> [!TIP]
> **En iyi performans için her zaman `limit`'yi belirtin**: Her sorguda açıkça `limit` sağlanması kesinlikle önerilir. Atlanırsa motor varsayılan olarak 1000 satıra ayarlanır. Çekirdek sorgu motoru hızlıdır ancak uygulama katmanında çok büyük sonuç kümelerinin serileştirilmesi yine de gereksiz ek yük getirebilir.

ToStore, ölçek ve performans gereksinimlerine göre seçim yapabilmeniz için iki sayfalandırma modu sunar:

#### 1. Temel Sayfalandırma (Ofset Modu)
Nispeten küçük veri kümeleri veya hassas sayfa atlamalarına ihtiyaç duyduğunuz durumlar için uygundur.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // Skip the first 40 rows
    .limit(20); // Take 20 rows
```
> [!TIP]
> `offset` çok büyüdüğünde, veritabanının birçok satırı taraması ve atması gerekir, böylece performans doğrusal olarak düşer. Derin sayfalandırma için **İmleç Modu**'nu tercih edin.

#### 2. İmleç Sayfalandırması (İmleç Modu)
Büyük veri kümeleri ve sonsuz kaydırma için idealdir. `nextCursor` kullanıldığında, motor mevcut konumdan devam eder ve derin ofsetlerin getirdiği ekstra tarama maliyetinden kaçınır.

> [!IMPORTANT]
> Dizine eklenmemiş alanlardaki bazı karmaşık sorgular veya sıralamalar için, motor tam taramaya geri dönebilir ve bir `null` imleci döndürebilir; bu, söz konusu sorgu için sayfalandırmanın şu anda desteklenmediği anlamına gelir.

```dart
// First page
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// Use the returned cursor to fetch the next page
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // Seek directly to the next position
}

// Likewise, prevCursor enables efficient backward paging
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| Özellik | Ofset Modu | İmleç Modu |
| :--- | :--- | :--- |
| **Sorgu performansı** | Sayfalar derinleştikçe bozulur | Derin sayfalama için kararlı |
| **En iyisi** | Daha küçük veri kümeleri, tam sayfa atlamaları | **Devasa veri kümeleri, sonsuz kaydırma** |
| **Değişiklikler altında tutarlılık** | Veri değişiklikleri satırların atlanmasına neden olabilir | Veri değişikliklerinden kaynaklanan kopyaları ve atlamaları önler |


<a id="foreign-keys"></a>
### Yabancı Anahtarlar ve Basamaklı

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


<a id="query-operators"></a>
### Sorgu Operatörleri

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

<a id="distributed-architecture"></a>
## Dağıtık Mimari

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

<a id="primary-key-examples"></a>
## Birincil Anahtar Örnekleri

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


<a id="atomic-expressions"></a>
## Atomik İfadeler

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

<a id="transactions"></a>
## İşlemler

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

if (txResult.isSuccess) {
  print('Transaction committed successfully');
} else {
  print('Transaction rolled back: ${txResult.error?.message}');
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


<a id="database-maintenance"></a>
### Yönetim ve Bakım

Aşağıdaki API'ler, eklenti tarzı geliştirme, yönetici panelleri ve operasyonel senaryolar için veritabanı yönetimini, tanılamayı ve bakımı kapsar:

- **Masa Yönetimi**
  - `createTable(schema)`: manuel olarak tek bir tablo oluşturun; modül yükleme veya isteğe bağlı çalışma zamanı tablosu oluşturma için kullanışlıdır
  - `getTableSchema(tableName)`: tanımlanmış şema bilgilerini alır; otomatik doğrulama veya kullanıcı arayüzü modeli oluşturma için kullanışlıdır
  - `getTableInfo(tableName)`: kayıt sayısı, dizin sayısı, veri dosyası boyutu, oluşturma süresi ve tablonun genel olup olmadığı dahil olmak üzere çalışma zamanı tablosu istatistiklerini alın
  - `clear(tableName)`: şemayı, dizinleri ve dahili/harici anahtar kısıtlamalarını güvenli bir şekilde korurken tüm tablo verilerini temizleyin
  - `dropTable(tableName)`: bir tabloyu ve şemasını tamamen yok edin; geri döndürülemez
- **Alan Yönetimi**
  - `currentSpaceName`: mevcut aktif alanı gerçek zamanlı olarak alın
  - `listSpaces()`: geçerli veritabanı örneğindeki tüm ayrılmış alanları listeler
  - `getSpaceInfo(useCache: true)`: mevcut alanı denetleyin; önbelleği atlamak ve gerçek zamanlı durumu okumak için `useCache: false` kullanın
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
final spaceInfo = await db.getSpaceInfo(useCache: false);
final tableSchema = await db.getTableSchema('users');
final tableInfo = await db.getTableInfo('users');

print('spaces: $spaces');
print(spaceInfo.toJson());
print(tableSchema?.toJson());
print(tableInfo?.toJson());

await db.flush();

final memoryInfo = await db.status.memory();
final configInfo = await db.status.config();
print(memoryInfo.toJson());
print(configInfo.toJson());
```


<a id="backup-restore"></a>
### Yedekleme ve Geri Yükleme

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

<a id="error-handling"></a>
### Durum Kodları ve Hata İşleme


ToStore, veri işlemleri için birleşik bir yanıt modeli kullanır:

- `ResultType`: dallanma mantığı için kullanılan birleşik durum listesi
- `result.code`: `ResultType`'ye karşılık gelen sabit bir sayısal kod
- `result.message`: mevcut hatayı açıklayan okunabilir bir mesaj
- `successKeys` / `failedKeys`: toplu işlemlerde başarılı ve başarısız birincil anahtarların listesi


```dart
final result = await db.insert('users', {
  'username': 'john',
  'email': 'john@example.com',
});

if (!result.isSuccess) {
  switch (result.type) {
    case ResultType.notFound:
      print('Target resource does not exist: ${result.message}');
      break;
    case ResultType.notNullViolation:
    case ResultType.validationFailed:
      print('Data validation failed: ${result.message}');
      break;
    case ResultType.primaryKeyViolation:
    case ResultType.uniqueViolation:
      print('Unique constraint conflict: ${result.message}');
      break;
    case ResultType.foreignKeyViolation:
      print('Foreign key constraint failed: ${result.message}');
      break;
    case ResultType.resourceExhausted:
    case ResultType.timeout:
      print('System is busy. Please retry later: ${result.message}');
      break;
    case ResultType.ioError:
    case ResultType.dbError:
      print('Underlying storage error. Please record the logs: ${result.message}');
      break;
    default:
      print('Error type: ${result.type}, code: ${result.code}, message: ${result.message}');
  }
}
```

Yaygın durum kodu örnekleri:
Başarı geri döner `0`; Negatif sayılar hataları gösterir.
- `ResultType.success` (`0`): işlem başarılı oldu
- `ResultType.partialSuccess` (`1`): toplu işlem kısmen başarılı oldu
- `ResultType.unknown` (`-1`): bilinmeyen hata
- `ResultType.uniqueViolation` (`-2`): benzersiz dizin çakışması
- `ResultType.primaryKeyViolation` (`-3`): birincil anahtar çakışması
- `ResultType.foreignKeyViolation` (`-4`): yabancı anahtar referansı kısıtlamaları karşılamıyor
- `ResultType.notNullViolation` (`-5`): zorunlu bir alan eksik veya izin verilmeyen bir `null` geçildi
- `ResultType.validationFailed` (`-6`): uzunluk, aralık, format veya diğer doğrulama başarısız oldu
- `ResultType.notFound` (`-11`): hedef tablo, alan veya kaynak mevcut değil
- `ResultType.resourceExhausted` (`-15`): yetersiz sistem kaynakları; yükü azaltın veya yeniden deneyin
- `ResultType.dbError` (`-91`): veritabanı hatası
- `ResultType.ioError` (`-90`): dosya sistemi hatası
- `ResultType.timeout` (`-92`): zaman aşımı

### İşlem Sonucu İşleme
```dart
final txResult = await db.transaction(() async {
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
  });
});

// txResult.isFailed: transaction failed; txResult.isSuccess: transaction succeeded
if (txResult.isFailed) {
  print('Transaction error type: ${txResult.error?.type}');
  print('Transaction error message: ${txResult.error?.message}');
}
```

İşlem hatası türleri:
- `TransactionErrorType.operationError`: alan doğrulama hatası, geçersiz kaynak durumu veya iş düzeyindeki başka bir hata gibi işlem içinde normal bir işlem başarısız oldu
- `TransactionErrorType.integrityViolation`: birincil anahtar, benzersiz anahtar, yabancı anahtar veya boş olmayan hata gibi bütünlük veya kısıtlama çakışması
- `TransactionErrorType.timeout`: zaman aşımı
- `TransactionErrorType.io`: temel depolama veya dosya sistemi G/Ç hatası
- `TransactionErrorType.conflict`: bir çakışma işlemin başarısız olmasına neden oldu
- `TransactionErrorType.userAbort`: kullanıcı tarafından başlatılan iptal (atmaya dayalı manuel iptal şu anda desteklenmemektedir)
- `TransactionErrorType.unknown`: başka herhangi bir hata


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
### Günlük Geri Arama ve Veritabanı Tanılama

ToStore, başlatma, kurtarma, otomatik geçiş ve çalışma zamanı kısıtlama çakışması günlüklerini `LogConfig.setConfig(...)` aracılığıyla iş katmanına geri yönlendirebilir.

- `onLogHandler` mevcut `enableLog` ve `logLevel` filtrelerini geçen tüm günlükleri alır.
- Başlatmadan önce `LogConfig.setConfig(...)`'yi arayın, böylece başlatma ve otomatik geçiş sırasında oluşturulan günlükler de yakalanır.

```dart
  // Configure log parameters or callback
  LogConfig.setConfig(
    enableLog: true,
    logLevel: debugMode ? LogLevel.debug : LogLevel.warn,
    publicLabel: 'my_app_db',
    onLogHandler: (message, type, label) {
      // In production, warn/error can be reported to your backend or logging platform
      if (!debugMode && (type == LogType.warn || type == LogType.error)) {
        developer.log(message, name: label);
      }
    },
  );

  final db = await ToStore.open();
```


<a id="security-config"></a>
## Güvenlik Yapılandırması

> [!WARNING]
> **Anahtar yönetimi**: **`encodingKey`** serbestçe değiştirilebilir ve motor, verileri otomatik olarak taşıyarak verilerin kurtarılabilir kalmasını sağlar. **`encryptionKey`** rastgele değiştirilmemelidir. Bir kez değiştirildikten sonra, siz açıkça taşımadığınız sürece eski verilerin şifresi çözülemez. Hassas anahtarları hiçbir zaman sabit kodlamayın; bunları güvenli bir servisten almanız önerilir.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // Supported encryption algorithms: none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305,

      // Encoding key (can be changed; data will be migrated automatically)
      encodingKey: 'Your-32-Byte-Long-Encoding-Key...',

      // Encryption key for critical data (do not change casually unless you are migrating data)
      encryptionKey: 'Your-Secure-Encryption-Key...',

      // Device binding (path-based binding)
      // When enabled, the key is deeply bound to the database path and device characteristics.
      // Data cannot be decrypted when moved to a different physical path.
      // Advantage: better protection if database files are copied directly.
      // Drawback: if the install path or device characteristics change, data may become unrecoverable.
      deviceBinding: false,
    ),
    // Enable crash recovery logging (Write-Ahead Logging), enabled by default
    enableJournal: true,
    // Whether transactions force data to disk on commit; set false to reduce sync overhead
    persistRecoveryOnCommit: true,
  ),
);
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


<a id="advanced-config"></a>
## Gelişmiş Yapılandırma Açıklaması (DataStoreConfig)

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

<a id="performance"></a>
## Performans ve Deneyim

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


ToStore size yardımcı oluyorsa lütfen bize bir ⭐️ verin
Projeyi desteklemenin en iyi yollarından biridir. Çok teşekkür ederim.


> **Öneri**: Ön uç uygulama geliştirme için, veri isteklerini, yüklemeyi, depolamayı, önbelleğe almayı ve sunumu otomatikleştiren ve birleştiren tam kapsamlı bir çözüm sağlayan [ToApp çerçevesi](https://github.com/tocreator/toapp)'yi göz önünde bulundurun.


<a id="more-resources"></a>
## Daha Fazla Kaynak

- 📖 **Belgeler**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **Sorun Bildirme**: [GitHub Sorunları](https://github.com/tocreator/tostore/issues)
- 💬 **Teknik Tartışma**: [GitHub Tartışmaları](https://github.com/tocreator/tostore/discussions)



