# ToStore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | Türkçe

ToStore, özellikle mobil uygulamalar için tasarlanmış yüksek performanslı bir depolama motorudur. Tamamen Dart ile uygulanmış olup, B+ ağacı indeksleme ve akıllı önbellek stratejileri sayesinde olağanüstü performans elde eder. Çok alanlı mimarisi, kullanıcı verilerinin izolasyonu ve global veri paylaşımı zorluklarını çözerken, işlem koruması, otomatik onarım, artımlı yedekleme ve sıfır maliyetli boşta kalma gibi kurumsal düzey özellikleri ile mobil uygulamalar için güvenilir veri depolama sağlar.

## Neden ToStore?

- 🚀 **Üstün Performans**: 
  - Akıllı sorgu optimizasyonlu B+ ağacı indeksleme
  - Milisaniye yanıt süreli akıllı önbellek stratejisi
  - Kararlı performanslı engellemesiz eşzamanlı okuma/yazma
- 🎯 **Kullanımı Kolay**: 
  - Akıcı zincirleme API tasarım
  - SQL/Map tarzı sorgular için destek
  - Tam kod önerileriyle akıllı tip çıkarımı
  - Sıfır yapılandırma, kutudan çıktığı gibi hazır
- 🔄 **Yenilikçi Mimari**: 
  - Çok kullanıcılı senaryolar için mükemmel çok alanlı veri izolasyonu
  - Global veri paylaşımı senkronizasyon zorluklarını çözer
  - İç içe işlemler için destek
  - İsteğe bağlı alan yükleme kaynak kullanımını minimize eder
  - Otomatik veri depolama, akıllı güncelleme/ekleme
- 🛡️ **Kurumsal Düzey Güvenilirlik**: 
  - ACID işlem koruması veri tutarlılığını garanti eder
  - Hızlı kurtarmalı artımlı yedekleme mekanizması
  - Otomatik hata onarımlı veri bütünlüğü doğrulaması

## Hızlı Başlangıç

Temel kullanım:

```dart
// Veritabanını başlat
final db = ToStore(
  version: 1,
  onCreate: (db) async {
    // Tablo oluştur
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
await db.initialize(); // İsteğe bağlı, işlemlerden önce veritabanının tam olarak başlatıldığından emin olur

// Veri ekle
await db.insert('users', {
  'id': 1,
  'name': 'John',
  'age': 30,
});

// Veri güncelle
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// Veri sil
await db.delete('users').where('id', '!=', 1);

// Karmaşık koşullu zincir sorgu
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// Kayıtları say
final count = await db.query('users').count();

// SQL tarzı sorgu
final users = await db.queryBySql(
  'users',
  where: 'age > 20 AND name LIKE "%John%" OR id IN (1, 2, 3)',
  limit: 10
);

// Map tarzı sorgu
final users = await db.queryByMap(
  'users',
  where: {
    'age': {'>=': 30},
    'name': {'like': '%John%'},
  },
  orderBy: ['age'],
  limit: 10,
);

// Toplu ekleme
await db.batchInsert('users', [
  {'id': 1, 'name': 'John', 'age': 30},
  {'id': 2, 'name': 'Mary', 'age': 25},
]);
```

## Çok Alanlı Mimari

ToStore'un çok alanlı mimarisi çok kullanıcılı veri yönetimini kolaylaştırır:

```dart
// Kullanıcı alanına geç
await db.switchBaseSpace(spaceName: 'user_123');

// Kullanıcı verilerini sorgula
final followers = await db.query('followers');

// Anahtar-değer verilerini ayarla veya güncelle, isGlobal: true global verileri belirtir
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// Global anahtar-değer verilerini al
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```


### Otomatik Veri Depolama

```dart
// Koşulla otomatik depolama
await db.upsert('users', {'name': 'John'})
  .where('email', '=', 'john@example.com');

// Birincil anahtarla otomatik depolama
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});
``` 


## Performans

Toplu yazma, rastgele okuma/yazma ve koşullu sorgular dahil yüksek eşzamanlılık senaryolarında, ToStore olağanüstü performans gösterir ve Dart/Flutter için mevcut diğer ana veritabanlarını büyük ölçüde geçer.

## Daha Fazla Özellik

- 💫 Zarif zincirleme API
- 🎯 Akıllı tip çıkarımı
- 📝 Tam kod önerileri
- 🔐 Otomatik artımlı yedekleme
- 🛡️ Veri bütünlüğü doğrulama
- 🔄 Otomatik çökme kurtarma
- 📦 Akıllı veri sıkıştırma
- 📊 Otomatik indeks optimizasyonu
- 💾 Katmanlı önbellek stratejisi

Amacımız sadece başka bir veritabanı oluşturmak değil. ToStore, alternatif bir çözüm sunmak için Toway framework'ünden çıkarılmıştır. Mobil uygulamalar geliştiriyorsanız, eksiksiz bir Flutter geliştirme ekosistemi sunan Toway framework'ünü kullanmanızı öneririz. Toway ile altta yatan veritabanıyla doğrudan uğraşmanız gerekmez - veri istekleri, yükleme, depolama, önbellekleme ve görüntüleme framework tarafından otomatik olarak yönetilir.
Toway framework'ü hakkında daha fazla bilgi için [Toway Deposu](https://github.com/tocreator/toway)'nu ziyaret edin

## Dokümantasyon

Detaylı dokümantasyon için [Wiki](https://github.com/tocreator/tostore)'mizi ziyaret edin.

## Destek & Geri Bildirim

- Issue Gönder: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- Tartışmalara Katıl: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- Katkıda Bulun: [Katkıda Bulunma Rehberi](CONTRIBUTING.md)

## Lisans

Bu proje MIT lisansı altında lisanslanmıştır - detaylar için [LICENSE](LICENSE) dosyasına bakın.

---

<p align="center">ToStore'u faydalı buluyorsanız, bize bir ⭐️ verin</p> 