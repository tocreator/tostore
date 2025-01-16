# ToStore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | Türkçe

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![Build Status](https://github.com/tocreator/tostore/workflows/build/badge.svg)](https://github.com/tocreator/tostore/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

ToStore, özellikle mobil uygulamalar için tasarlanmış yüksek performanslı bir depolama motorudur. Saf Dart ile uygulanmış olup, B+ ağacı indeksleme ve akıllı önbellek stratejileri sayesinde olağanüstü performans elde eder. Çok alanlı mimarisi, kullanıcı verilerinin izolasyonu ve global veri paylaşımı zorluklarını çözerken, işlem koruması, otomatik onarım, artımlı yedekleme ve boşta sıfır maliyet gibi kurumsal düzey özellikler mobil uygulamalar için güvenilir veri depolama sağlar.

## Neden ToStore?

- 🚀 **Maksimum Performans**: 
  - Akıllı sorgu optimizasyonlu B+ ağacı indeksleme
  - Milisaniye yanıt süreli akıllı önbellek stratejisi
  - Kararlı performanslı engellemesiz eşzamanlı okuma/yazma
- 🔄 **Akıllı Şema Evrimi**: 
  - Şemalar aracılığıyla otomatik tablo yapısı güncellemesi
  - Manuel sürüm sürüm migrasyonlar yok
  - Karmaşık değişiklikler için zincirleme API
  - Kesintisiz güncellemeler
- 🎯 **Kullanımı Kolay**: 
  - Akıcı zincirleme API tasarımı
  - SQL/Map tarzı sorgu desteği
  - Tam kod önerileriyle akıllı tip çıkarımı
  - Karmaşık yapılandırma olmadan kullanıma hazır
- 🔄 **Yenilikçi Mimari**: 
  - Çok kullanıcılı senaryolar için mükemmel çok alanlı veri izolasyonu
  - Senkronizasyon zorluklarını çözen global veri paylaşımı
  - İç içe işlem desteği
  - Kaynak kullanımını minimize eden talep üzerine alan yükleme
  - Otomatik veri işlemleri (upsert)
- 🛡️ **Kurumsal Güvenilirlik**: 
  - Veri tutarlılığını garanti eden ACID işlem koruması
  - Hızlı kurtarma özellikli artımlı yedekleme mekanizması
  - Otomatik onarımlı veri bütünlüğü doğrulaması

## Hızlı Başlangıç

Temel kullanım:

```dart
// Veritabanını başlat
final db = ToStore(
  version: 2, // sürüm numarası her artırıldığında, schemas'daki tablo yapısı otomatik olarak oluşturulacak veya güncellenecek
  schemas: [
    // Sadece en son şemanızı tanımlayın, ToStore güncellemeyi otomatik olarak halleder
    const TableSchema(
      name: 'users',
      primaryKey: 'id',
      fields: [
        FieldSchema(name: 'id', type: DataType.integer, nullable: false),
        FieldSchema(name: 'name', type: DataType.text, nullable: false),
        FieldSchema(name: 'age', type: DataType.integer),
      ],
      indexes: [
        IndexSchema(fields: ['name'], unique: true),
      ],
    ),
  ],
  // karmaşık güncellemeler ve migrasyonlar db.updateSchema kullanılarak yapılabilir
  // tablo sayısı azsa, otomatik güncelleme için yapıyı doğrudan schemas'da ayarlamanız önerilir
  onUpgrade: (db, oldVersion, newVersion) async {
    if (oldVersion == 1) {
      await db.updateSchema('users')
          .addField("fans", type: DataType.array, comment: "takipçiler")
          .addIndex("follow", fields: ["follow", "name"])
          .dropField("last_login")
          .modifyField('email', unique: true)
          .renameField("last_login", "last_login_time");
    }
  },
);
await db.initialize(); // İsteğe bağlı, işlemlerden önce veritabanının tamamen başlatıldığından emin olur

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