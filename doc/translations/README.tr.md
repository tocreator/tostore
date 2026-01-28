# Tostore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | Türkçe

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)


## Neden Tostore'u Seçmelisiniz?

Tostore, Dart/Flutter ekosistemindeki dağıtık vektör veritabanları için tek yüksek performanslı depolama motorudur. Sinir ağı benzeri bir mimari kullanarak, düğümler arası akıllı birbirine bağlanabilirlik ve iş birliği sunarak sonsuz yatay ölçeklenebilirliği destekler. Esnek bir veri topolojisi ağı oluşturur ve şema değişikliklerinin hassas tanımlanmasını, şifreleme korumasını ve çok alanlı (multi-space) veri izolasyonunu sağlar. Tostore, uç paralel işleme için çok çekirdekli işlemcilerden tam olarak yararlanır ve mobil uç (edge) cihazlardan buluta kadar yerel olarak platformlar arası iş birliğini destekler. Çeşitli dağıtık birincil anahtar algoritmaları ile sürükleyici sanal gerçeklik, çok modlu etkileşim, mekansal hesaplama, üretken yapay zeka ve semantik vektör uzayı modelleme gibi senaryolar için güçlü bir veri temeli sağlar.

Üretken yapay zeka ve mekansal hesaplama, hesaplama ağırlık merkezini uç (edge) noktalara kaydırdıkça, terminal cihazları sadece içerik görüntüleyiciler olmaktan çıkıp yerel üretim, çevresel algılama ve gerçek zamanlı karar verme merkezlerine dönüşüyor. Geleneksel tek dosyalı gömülü veritabanları mimari tasarımları gereği kısıtlıdır ve akıllı uygulamaların yüksek eşzamanlı yazma, devasa vektör geri çağırma ve bulut-uç iş birliğine dayalı üretim gibi anında yanıt gereksinimlerini karşılamakta zorlanırlar. Tostore, uç cihazlar için doğmuştur; onlara karmaşık yerel yapay zeka üretimini ve büyük ölçekli veri akışını destekleyecek kadar dağıtık depolama yetenekleri kazandırarak, bulut ve uç arasında gerçek bir derin iş birliği sağlar.

**Güç Kesintisine ve Çökmeye Dayanıklı**: Beklenmedik bir güç kesintisi veya uygulama çökmesi durumunda bile veriler otomatik olarak kurtarılabilir ve gerçek sıfır veri kaybı elde edilir. Bir veri işlemi yanıt verdiğinde, veriler zaten güvenli bir şekilde kaydedilmiştir ve veri kaybı riski ortadan kalkar.

**Performans Sınırlarını Zorlamak**: Performans testleri, 10 milyon kayıtla bile tipik bir akıllı telefonun anında başlayabildiğini ve sorgu sonuçlarını anında gösterebildiğini kanıtlamıştır. Veri hacmi ne kadar büyük olursa olsun, geleneksel veritabanlarını çok geride bırakan akıcı bir deneyimin tadını çıkarabilirsiniz.




...... Parmak uçlarınızdan bulut uygulamalarına kadar, Tostore veri hesaplama gücünü serbest bırakmanıza ve geleceği güçlendirmenize yardımcı olur ......




## Tostore Özellikleri

- 🌐 **Sorunsuz Tüm Platform Desteği**
  - Mobil uygulamalardan bulut sunucularına kadar tüm platformlarda aynı kodu çalıştırın.
  - Farklı platform depolama arka uçlarına (IndexedDB, dosya sistemi vb.) akıllıca uyum sağlar.
  - Endişesiz platformlar arası veri senkronizasyonu için birleşik API arayüzü.
  - Uç cihazlardan bulut sunucularına kesintisiz veri akışı.
  - Uç cihazlarda yerel vektör hesaplama, ağ gecikmesini ve bulut bağımlılığını azaltır.

- 🧠 **Sinir Ağı Benzeri Dağıtık Mimari**
  - Veri akışının verimli organizasyonu için birbirine bağlı düğüm topolojisi yapısı.
  - Gerçek dağıtık işleme için yüksek performanslı veri bölümlendirme mekanizması.
  - Kaynak kullanımını maksimize etmek için akıllı dinamik iş yükü dengeleme.
  - Karmaşık veri ağlarını kolayca oluşturmak için düğümlerin sonsuz yatay ölçeklenmesi.

- ⚡ **Üst Düzey Paralel İşleme Yeteneği**
  - İzolatlar (Isolates) kullanarak gerçek paralel okuma/yazma, çok çekirdekli işlemcilerde tam hızda çalışma.
  - Akıllı kaynak planlaması, çok çekirdekli performansı maksimize etmek için yükü otomatik olarak dengeler.
  - İş birliğine dayalı çok düğümlü hesaplama ağı, görev işleme verimliliğini ikiye katlar.
  - Kaynağa duyarlı planlama çerçevesi, kaynak çekişmesini önlemek için yürütme planlarını otomatik olarak optimize eder.
  - Akışlı (streaming) sorgu arayüzü, devasa veri kümelerini kolaylıkla yönetir.

- 🔑 **Çeşitli Dağıtık Birincil Anahtar Algoritmaları**
  - Sıralı Artış Algoritması - İş hacmini gizlemek için rastgele adım boyutlarını serbestçe ayarlayın.
  - Zaman Damgası (Timestamp) Tabanlı Algoritma - Yüksek eşzamanlılık senaryoları için en iyi seçim.
  - Tarih Öneki Algoritması - Zaman aralığı veri gösterimi için mükemmel destek.
  - Kısa Kod Algoritması - Kısa, okunması kolay benzersiz tanımlayıcılar oluşturur.

- 🔄 **Akıllı Şema Migrasyonu ve Veri Bütünlüğü**
  - Yeniden adlandırılan tablo alanlarını sıfır veri kaybıyla hassas bir şekilde tanımlar.
  - Şema değişikliklerinin otomatik tespiti ve milisaniyeler içinde veri migrasyonu.
  - İşletme için fark edilmeyen, kesintisiz güncellemeler.
  - Karmaşık yapı değişiklikleri için güvenli migrasyon stratejileri.
  - Referans bütünlüğünü sağlayan kaskad desteğiyle otomatik yabancı anahtar kısıtlama doğrulaması.

- 🛡️ **Kurumsal Düzeyde Güvenlik ve Dayanıklılık**
  - Çift koruma mekanizması: Veri değişikliklerinin gerçek zamanlı günlüğü hiçbir şeyin kaybolmamasını sağlar.
  - Otomatik çökme kurtarma: Güç kesintisi veya çökme sonrası tamamlanmamış işlemleri otomatik olarak sürdürür.
  - Veri tutarlılığı garantisi: İşlemler ya tamamen başarılı olur ya da tamamen geri alınır (rollback).
  - Atomik hesaplamalı güncellemeler: İfade sistemi, eşzamanlılık çatışmalarını önlemek için atomik olarak yürütülen karmaşık hesaplamaları destekler.
  - Anında güvenli kalıcılık: İşlem başarılı olduğunda veriler güvenli bir şekilde kaydedilir.
  - Yüksek dirençli ChaCha20Poly1305 şifreleme algoritması hassas verileri korur.
  - Tüm depolama ve iletim boyunca güvenlik için uçtan uca şifreleme.

- 🚀 **Akıllı Önbellek ve Geri Çağırma Performansı**
  - Ultra hızlı veri geri çağırma için çok seviyeli akıllı önbellek mekanizması.
  - Depolama motoruyla derinlemesine entegre edilmiş önbellek stratejileri.
  - Uyarlanabilir ölçekleme, veri ölçeği büyüdükçe kararlı performansı korur.
  - Sorgu sonuçlarının otomatik güncellenmesi ile gerçek zamanlı veri değişikliği bildirimleri.

- 🔄 **Akıllı Veri İş Akışı**
  - Çok alanlı mimari, küresel paylaşımla birlikte veri izolasyonu sağlar.
  - Hesaplama düğümleri arasında akıllı iş yükü dağıtımı.
  - Büyük ölçekli veri eğitimi ve analizi için sağlam bir temel sağlar.


## Kurulum

> [!IMPORTANT]
> **v2.x sürümünden mi yükseltiyorsunuz?** Kritik geçiş adımları ve önemli değişiklikler için lütfen [v3.0 Yükseltme Kılavuzu](../UPGRADE_GUIDE_v3.md) dosyasını okuyun.

`pubspec.yaml` dosyanıza `tostore` bağımlılığını ekleyin:

```yaml
dependencies:
  tostore: any # Lütfen en güncel sürümü kullanın
```

## Hızlı Başlangıç

> [!IMPORTANT]
> **Tablo şemasını tanımlamak ilk adımdır**: CRUD işlemlerini gerçekleştirmeden önce tablo şemasını tanımlamalısınız. Özel tanımlama yöntemi senaryonuza bağlıdır:
> - **Mobil/Masaüstü**: [Sık Başlatılan Senaryolar İçin Entegrasyon](#sık-başlatılan-senaryolar-için-entegrasyon) (Statik Tanımlama) önerilir.
> - **Sunucu Tarafı**: [Sunucu Tarafı Entegrasyonu](#sunucu-tarafı-entegrasyonu) (Dinamik Oluşturma) önerilir.

```dart
// 1. Veritabanını başlatın
final db = await ToStore.open();

// 2. Veri ekleyin
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. Zincirleme sorgular (=, !=, >, <, LIKE, IN vb. destekler)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(10);

// 4. Güncelleme ve Silme
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. Gerçek zamanlı dinleme (Arayüz otomatik güncellenir)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Eşleşen kullanıcılar güncellendi: $users');
});
```

### Anahtar-Değer (KV) Depolama
Yapılandırılmış tabloların tanımlanmasını gerektirmeyen senaryolar için uygundur. Basit, pratiktir ve yapılandırmalar, durumlar ve diğer dağınık veriler için yerleşik yüksek performanslı bir KV mağazası içerir. Farklı Alanlardaki (Spaces) veriler doğal olarak izoledir ancak küresel paylaşım için ayarlanabilir.

```dart
// 1. Anahtar-değer çiftlerini ayarlayın (String, int, bool, double, Map, List vb. destekler)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// 2. Veriyi alın
final theme = await db.getValue('theme'); // 'dark'

// 3. Veriyi silin
await db.removeValue('theme');

// 4. Küresel anahtar-değer (Alanlar arası paylaşılır)
// KV verileri varsayılan olarak alana özeldir. Paylaşım için isGlobal: true kullanın.
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```



## Sık Başlatılan Senaryolar İçin Entegrasyon

```dart
// Mobil ve masaüstü uygulamaları için uygun şema tanımı.
// Şema değişikliklerini hassas bir şekilde tanımlar ve verileri otomatik olarak taşır.
final db = await ToStore.open(
  schemas: [
    const TableSchema(
            name: 'global_settings',
            isGlobal: true,  // Tüm alanlar tarafından erişilebilen küresel tablo
            fields: [],
    ),
    const TableSchema(
      name: 'users', // Tablo adı
      tableId: "users",  // %100 yeniden adlandırma tespiti için benzersiz tanımlayıcı
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id',       // Birincil anahtar adı
      ),
      fields: [        // Alan tanımları (birincil anahtar hariç)
        FieldSchema(
          name: 'username', 
          type: DataType.text, 
          nullable: false, 
          unique: true,
          fieldId: 'username',  // Benzersiz alan tanımlayıcı
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
      indexes: [ // Dizin tanımları
        IndexSchema(fields: ['username']),
        IndexSchema(fields: ['email']),
      ],
    ),
    // Yabancı anahtar kısıtlaması örneği
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
          fields: ['user_id'],              // Mevcut tablo alanları
          referencedTable: 'users',         // Referans alınan tablo
          referencedFields: ['id'],         // Referans alınan alanlar
          onDelete: ForeignKeyCascadeAction.cascade,  // Kaskad silme
          onUpdate: ForeignKeyCascadeAction.cascade,  // Kaskad güncelleme
        ),
      ],
    ),
  ],
);

// Çok alanlı mimari - farklı kullanıcıların verilerinin mükemmel izolasyonu
await db.switchSpace(spaceName: 'user_123');
```

## Sunucu Tarafı Entegrasyonu

```dart
// Çalışma zamanında toplu şema oluşturma
await db.createTables([
  // 3D mekansal özellik vektör depolama tablosu
  const TableSchema(
    name: 'spatial_embeddings',
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.timestampBased,   // Yüksek eşzamanlılık için zaman damgası PK
    ),
    fields: [
      FieldSchema(
        name: 'video_name',
        type: DataType.text,
        nullable: false,
      ),
      FieldSchema(
        name: 'spatial_features',
        type: DataType.vector,                // Vektör depolama türü
        vectorConfig: VectorFieldConfig(
          dimensions: 1024,                   // Yüksek boyutlu vektör
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
        type: IndexType.vector,              // Vektör dizini
        fields: ['spatial_features'],
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.hnsw,   // Verimli ANN için HNSW algoritması
          distanceMetric: VectorDistanceMetric.cosine,
          parameters: {
            'M': 16,
            'efConstruction': 200,
          },
        ),
      ),
    ],
  ),
  // Diğer tablolar...
]);

// Çevrimiçi Şema Güncellemeleri - İşletme için kesintisiz
final taskId = await db.updateSchema('users')
  .renameTable('users_new')                // Tabloyu yeniden adlandır
  .modifyField(
    'username',
    minLength: 5,
    maxLength: 20,
    unique: true
  )                                        // Alan özelliklerini değiştir
  .renameField('old_name', 'new_name')     // Alanı yeniden adlandır
  .removeField('deprecated_field')         // Alanı kaldır
  .addField('created_at', type: DataType.datetime)  // Alan ekle
  .removeIndex(fields: ['age'])            // Dizini kaldır
  .setPrimaryKeyConfig(                    // PK yapılandırmasını değiştir
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
    
// Migrasyon ilerlemesini izleyin
final status = await db.queryMigrationTaskStatus(taskId);
print('Migrasyon ilerlemesi: ${status?.progressPercentage}%');


// Manuel Sorgu Önbelleği Yönetimi (Sunucu Tarafı)
// İstemci platformlarında otomatik olarak yönetilir.
// Sunucu veya büyük ölçekli veriler için hassas kontrol için bu API'leri kullanın.

// Bir sorgu sonucunu manuel olarak 5 dakika boyunca önbelleğe alın.
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// Veriler değiştiğinde belirli önbelleği geçersiz kılın.
await db.query('users')
    .where('is_active', '=', true)
    .clearQueryCache();

// Gerçek zamanlı veri gerektiren sorgular için önbelleği açıkça devre dışı bırakın.
final freshUserData = await db.query('users')
    .where('is_active', '=', true)
    .noQueryCache();
```



## Gelişmiş Kullanım

Tostore, karmaşık iş gereksinimleri için zengin bir gelişmiş özellikler seti sunar:

### İçe İçe Sorgular ve Özel Filtreleme
Koşulların sonsuz iç içe geçmesini ve esnek özel işlevleri destekler.

```dart
// Koşul iç içe geçirme: (type = 'app' OR (id >= 123 OR fans >= 200))
final idCondition = QueryCondition().where('id', '>=', 123).or().where('fans', '>=', 200);

final result = await db.query('users')
    .condition(
        QueryCondition().whereEqual('type', 'app').or().condition(idCondition)
    )
    .limit(20);

// Özel koşul işlevi
final customResult = await db.query('users')
    .whereCustom((record) => record['tags']?.contains('önerilen') ?? false);
```

### Akıllı Upsert
Varsa güncelle, yoksa ekle.

```dart
await db.upsert('users', {
  'email': 'john@example.com',
  'name': 'John New'
}).where('email', '=', 'john@example.com');
```


### Birleştirmeler (Joins) ve Alan Seçimi
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000);
```

### Akış (Streaming) ve İstatistikler
```dart
// Kayıtları say
final count = await db.query('users').count();

// Akış sorgusu (büyük veriler için uygun)
db.streamQuery('users').listen((data) => print(data));
```



### Sorgular ve Verimli Sayfalandırma

Tostore, farklı veri ölçeklerine uygun çift modlu sayfalandırma desteği sunar:

#### 1. Ofset Modu
Küçük veri kümeleri için veya belirli bir sayfaya atlamak gerektiğinde uygundur.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // İlk 40 hesabı atla
    .limit(20); // 20 tane al
```
> [!TIP]
> `offset` çok büyük olduğunda, veritabanının birçok kaydı taraması ve atması gerekir, bu da performans kaybına yol açar. Derin sayfalandırma için **İmleç (Cursor) Modu**'nu kullanın.

#### 2. Yüksek Performanslı İmleç (Cursor) Modu
**Büyük veriler ve sonsuz kaydırma senaryoları için önerilir**. O(1) performans için `nextCursor` kullanır ve sayfa derinliğinden bağımsız olarak sabit sorgu hızı sağlar.

> [!IMPORTANT]
> Dizinlenmemiş bir alan üzerinden sıralama yapıldığında veya bazı karmaşık sorgularda, motor tam tablo taramasına dönebilir ve `null` bir imleç döndürebilir (bu, söz konusu sorgu için sayfalama desteğinin henüz mevcut olmadığı anlamına gelir).

```dart
// Sayfa 1
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// İmleci kullanarak bir sonraki sayfayı getirin
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // Doğrudan konuma gidin
}

// prevCursor ile verimli bir şekilde geri gidin
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| Özellik | Ofset Modu | İmleç Modu |
| :--- | :--- | :--- |
| **Performans** | Sayfa arttıkça düşer | **Sabit (O(1))** |
| **Karmaşıklık** | Küçük veri, sayfa atlama | **Büyük veri, sonsuz kaydırma** |
| **Tutarlılık** | Değişiklikler atlamalara neden olabilir | **Değişiklikler karşısında mükemmel bütünlük** |





## Dağıtık Mimari

```dart
// Dağıtık Düğümleri Yapılandırın
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

// Yüksek Performanslı Toplu Ekleme (Batch Insert)
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... Kayıtlar verimli bir şekilde toplu olarak eklenir
]);

// Büyük veri kümelerini akışla işleyin - Sabit bellek
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // Yüksek bellek kullanımı olmadan TB ölçeğindeki verileri bile verimli bir şekilde işler
  print(record);
}
```

## Birincil Anahtar Örnekleri

Tostore çeşitli dağıtık birincil anahtar algoritmaları sağlar:

- **Sıralı** (PrimaryKeyType.sequential): 238978991
- **Zaman Damgası Tabanlı** (PrimaryKeyType.timestampBased): 1306866018836946
- **Tarih Öneki** (PrimaryKeyType.datePrefixed): 20250530182215887631
- **Kısa Kod** (PrimaryKeyType.shortCode): 9eXrF0qeXZ

```dart
// Sıralı birincil anahtar yapılandırma örneği
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,
        increment: 50,
        useRandomIncrement: true, // İş hacmini gizle
      ),
    ),
    fields: [/* Alan tanımları */]
  ),
]);
```


## İfadelerle Atomik İşlemler

İfade sistemi, güvenli atomik alan güncellemeleri sağlar. Tüm hesaplamalar, eşzamanlılık çatışmalarını önlemek için veritabanı düzeyinde atomik olarak yürütülür:

```dart
// Basit Artış: balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// Karmaşık Hesaplama: total = price * quantity + tax
await db.update('orders', {
  'total': Expr.field('price') * Expr.field('quantity') + Expr.field('tax'),
}).where('id', '=', orderId);

// İçe içe parantezler: finalPrice = ((price * quantity) + tax) * (1 - discount)
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) * 
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// Fonksiyon kullanımı: price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// Zaman Damgası: updatedAt = now()
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

## İşlemler (Transactions)

İşlemler, birden fazla işlemin atomikliğini sağlar: Ya tümü başarılı olur ya da tümü geri alınır (rollback), veri tutarlılığı garanti edilir.

**İşlem Özellikleri**:
- Birden fazla işlemin atomik yürütülmesi.
- Çökme sonrası tamamlanmamış işlemlerin otomatik kurtarılması.
- Başarılı teslimde (commit) veriler güvenli bir şekilde kaydedilir.

```dart
// Temel İşlem
final txResult = await db.transaction(() async {
  // Kullanıcı Ekle
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });
  
  // İfadeleri kullanarak atomik güncelleme
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');
  
  // Herhangi bir işlem başarısız olursa, tüm değişiklikler otomatik olarak geri alınır.
});

if (txResult.isSuccess) {
  print('İşlem başarıyla tamamlandı');
} else {
  print('İşlem geri alındı: ${txResult.error?.message}');
}

// Hata durumunda otomatik geri alma
final txResult2 = await db.transaction(() async {
  await db.insert('users', {
    'username': 'jane',
    'email': 'jane@example.com',
  });
  throw Exception('İş mantığı hatası'); // Geri almayı tetikler
}, rollbackOnError: true);
```

## Güvenlik Yapılandırması

**Veri Güvenliği Mekanizmaları**:
- Çift koruma mekanizmaları verilerin asla kaybolmamasını sağlar.
- Tamamlanmamış işlemler için otomatik çökme kurtarma.
- İşlem başarısında anında güvenli kalıcılık.
- Yüksek dirençli şifreleme hassas verileri korur.

> [!WARNING]
> **Anahtar Yönetimi**: `encryptionKey`'i değiştirmek, eski verileri okunamaz hale getirir (bir migrasyon yapılmadığı sürece). Hassas anahtarları koda gömmeyin; güvenli bir sunucudan alın.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // Desteklenen algoritmalar: none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305, 
      
      // Kodlama anahtarı (başlatma sırasında sağlanmalıdır)
      encodingKey: '32-Byte-Uzunluğunda-Kodlama-Anahtarınız...', 
      
      // Kritik veriler için şifreleme anahtarı
      encryptionKey: 'Güvenli-Şifreleme-Anahtarınız...',
      
      // Cihaz Bağlama (Yol tabanlı)
      // Etkinleştirildiğinde, anahtarlar yola ve cihaz özelliklerine bağlanır.
      // Veritabanı dosyalarının kopyalanmasına karşı güvenliği artırır.
      deviceBinding: false, 
    ),
    // Yazma Öncesi Günlük Kaydı (WAL) varsayılan olarak etkindir
    enableJournal: true, 
    // Commit sırasında diske yazmayı zorla (performans için false yapın)
    persistRecoveryOnCommit: true,
  ),
);
```


## Performans ve Deneyim

### Performans Spesifikasyonları

- **Başlatma Hızı**: Tipik akıllı telefonlarda 10M+ kayıtla bile anında başlatma ve veri gösterimi.
- **Sorgu Performansı**: Ölçekten bağımsız, her veri hacminde sürekli yıldırım hızında geri çağırma.
- **Veri Güvenliği**: Sıfır veri kaybı için ACID işlem garantileri + çökme kurtarma.

### Öneriler

- 📱 **Örnek Proje**: `example` dizininde tam bir Flutter uygulaması örneği sunulmuştur.
- 🚀 **Üretim**: Debug modundan çok daha yüksek performans için Release modunu kullanın.
- ✅ **Standart Testler**: Tüm temel işlevler standart entegrasyon testlerini geçmiştir.




Tostore size yardımcı oluyorsa lütfen bize bir ⭐️ verin




## Yol Haritası (Roadmap)

Tostore, yapay zeka çağında veri altyapısını güçlendirmek için aktif olarak özellikler geliştirmektedir:

- **Yüksek Boyutlu Vektörler**: Vektör geri çağırma ve semantik arama algoritmaları ekleniyor.
- **Çok Modlu Veriler**: Ham verilerden özellik vektörlerine kadar uçtan uca işleme sağlanıyor.
- **Graf Veri Yapıları**: Bilgi graflarının ve karmaşık ilişkisel ağların verimli depolanması ve sorgulanması için destek.





> **Öneri**: Mobil geliştiriciler, veri isteklerini, yüklemeyi, depolamayı, önbelleğe almayı ve görüntülemeyi otomatiklecek bir full-stack çözüm olan [Toway Framework](https://github.com/tocreator/toway)'ü de değerlendirebilirler.




## Ek Kaynaklar

- 📖 **Dokümantasyon**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **Geri Bildirim**: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **Tartışma**: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)


## Lisans

Bu proje MIT Lisansı altındadır - ayrıntılar için [LICENSE](LICENSE) dosyasına bakın.

---
