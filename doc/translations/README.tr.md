# Tostore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | Türkçe

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![Build Status](https://github.com/tocreator/tostore/workflows/build/badge.svg)](https://github.com/tocreator/tostore/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

Tostore, projenize derinlemesine entegre edilmiş çok platformlu dağıtık mimari veritabanı motorudur. Sinir ağlarından esinlenen veri işleme modeli, beynin işleyişine benzer veri yönetimi uygular. Çoklu bölüm paralelleştirme mekanizmaları ve düğüm ara bağlantı topolojisi akıllı bir veri ağı oluştururken, Isolate ile paralel işleme çok çekirdekli yetenekleri tam olarak kullanır. Çeşitli dağıtık birincil anahtar algoritmaları ve sınırsız düğüm genişletmesiyle, dağıtık hesaplama ve büyük ölçekli veri eğitimi altyapıları için veri katmanı olarak hizmet verebilir, kenar cihazlardan bulut sunucularına kadar sorunsuz veri akışı sağlar. Şema değişikliklerinin hassas tespiti, akıllı göç, ChaCha20Poly1305 şifreleme ve çoklu alan mimarisi gibi özellikler, mobil uygulamalardan sunucu tarafı sistemlere kadar çeşitli uygulama senaryolarını mükemmel şekilde destekler.

## Neden Tostore'u Seçmelisiniz?

### 1. Bölüm Paralel İşleme vs. Tek Dosya Depolama
| Tostore | Geleneksel Veritabanları |
|:---------|:-----------|
| ✅ Akıllı bölümleme mekanizması, veriler uygun boyutlu birden çok dosyaya dağıtılır | ❌ Tek bir veri dosyasında depolama, veriler büyüdükçe doğrusal performans bozulması |
| ✅ Yalnızca ilgili bölüm dosyalarını okuma, sorgu performansı toplam veri hacminden bağımsız | ❌ Tek bir kaydı sorgulamak için bile tüm veri dosyasını yükleme ihtiyacı |
| ✅ TB düzeyinde veri hacimleriyle bile milisaniye yanıt sürelerini koruma | ❌ Mobil cihazlarda veriler 5MB'ı aştığında okuma/yazma gecikmesinde önemli artış |
| ✅ Kaynak tüketimi sorgulanan veri miktarıyla orantılı, toplam veri hacmiyle değil | ❌ Sınırlı kaynaklı cihazlar bellek baskısına ve OOM hatalarına maruz kalır |
| ✅ Isolate teknolojisi gerçek çok çekirdekli paralel işlemeyi sağlar | ❌ Tek dosya paralel olarak işlenemez, CPU kaynaklarının israfı |

### 2. Dart Paralelizmi vs. Geleneksel Betik Dilleri
| Tostore | Geleneksel Betik Tabanlı Veritabanları |
|:---------|:-----------|
| ✅ Isolate'ler global kilit kısıtlamaları olmadan gerçek paralelde çalışır | ❌ Python gibi diller GIL tarafından sınırlandırılmıştır, CPU yoğun görevler için verimsiz |
| ✅ AOT derlemesi verimli makine kodu üretir, yerli performansa yakın | ❌ Yorumlanan yürütme nedeniyle veri işlemede performans kaybı |
| ✅ Bağımsız bellek yığını modeli, kilit ve bellek çekişmelerini önler | ❌ Paylaşılan bellek modeli yüksek eşzamanlılıkta karmaşık kilitleme mekanizmaları gerektirir |
| ✅ Tür güvenliği performans optimizasyonları ve derleme zamanı hata kontrolü sağlar | ❌ Dinamik tipleme hataları çalışma zamanında keşfeder, daha az optimizasyon fırsatı |
| ✅ Flutter ekosistemiyle derin entegrasyon | ❌ Ek ORM katmanları ve UI adaptörleri gerektirir, karmaşıklığı artırır |

### 3. Gömülü Entegrasyon vs. Bağımsız Veri Depoları
| Tostore | Geleneksel Veritabanları |
|:---------|:-----------|
| ✅ Dart dilini kullanır, Flutter/Dart projelerine kusursuz entegre olur | ❌ SQL veya özel sorgu dillerini öğrenmeyi gerektirir, öğrenme eğrisini artırır |
| ✅ Aynı kod frontend ve backend'i destekler, teknoloji yığınını değiştirmeye gerek yok | ❌ Frontend ve backend genellikle farklı veritabanları ve erişim yöntemleri gerektirir |
| ✅ Modern programlama stillerine uyan zincirleme API stili, mükemmel geliştirici deneyimi | ❌ SQL dize birleştirme saldırılara ve hatalara karşı savunmasız, tür güvenliği eksik |
| ✅ Reaktif programlama desteği, UI çerçeveleriyle doğal olarak uyumlu | ❌ UI ve veri katmanını bağlamak için ek adaptasyon katmanları gerektirir |
| ✅ Karmaşık ORM eşleme yapılandırması gerekmez, Dart nesnelerini doğrudan kullanır | ❌ Nesne-ilişkisel eşleme karmaşıklığı, yüksek geliştirme ve bakım maliyetleri |

### 4. Hassas Şema Değişikliği Algılama vs. Manuel Göç Yönetimi
| Tostore | Geleneksel Veritabanları |
|:---------|:-----------|
| ✅ Şema değişikliklerini otomatik olarak algılar, sürüm numarası yönetimi gerekmez | ❌ Manuel sürüm kontrolüne ve açık göç koduna bağımlılık |
| ✅ Tablo/alan değişikliklerini milisaniye düzeyinde algılama ve otomatik veri göçü | ❌ Sürümler arası yükseltmeler için göç mantığını sürdürme ihtiyacı |
| ✅ Tablo/alan yeniden adlandırmalarının kesin tanımlanması, tüm geçmiş verilerin korunması | ❌ Tablo/alan yeniden adlandırmaları veri kaybına neden olabilir |
| ✅ Veri tutarlılığını garanti eden atomik göç işlemleri | ❌ Göç kesintileri veri tutarsızlıklarına neden olabilir |
| ✅ Manuel müdahale olmadan tamamen otomatik şema güncellemeleri | ❌ Sürümler arttıkça karmaşık yükseltme mantığı ve yüksek bakım maliyetleri |

### 5. Çoklu Alan Mimarisi vs. Tek Depolama Alanı
| Tostore | Geleneksel Veritabanları |
|:---------|:-----------|
| ✅ Çoklu alan mimarisi, farklı kullanıcıların verilerini mükemmel şekilde izole eder | ❌ Tek depolama alanı, birden çok kullanıcının verilerinin karışık depolanması |
| ✅ Tek satır kodla alan değiştirme, basit ve etkili | ❌ Birden çok veritabanı örneği veya karmaşık izolasyon mantığı gerektirir |
| ✅ Esnek alan izolasyonu ve global veri paylaşım mekanizması | ❌ Kullanıcı verilerinin izolasyonu ve paylaşımını dengelemek zor |
| ✅ Alanlar arasında veri kopyalama veya taşıma için basit API | ❌ Kiracılar arasında karmaşık veri geçiş veya kopyalama işlemleri |
| ✅ Sorgular otomatik olarak mevcut alanla sınırlıdır, ek filtreleme gerekmez | ❌ Farklı kullanıcılar için sorgular karmaşık filtreleme gerektirir |

### 6. Çoklu Platform Desteği vs. Platform Sınırlamaları
| Tostore | Geleneksel Veritabanları |
|:---------|:-----------|
| ✅ Linux, Web, Mobil, Masaüstü platformlarında birleşik API | ❌ Farklı platformlar farklı depolama motorları ve API'ler gerektirir |
| ✅ Çeşitli çok platformlu depolama backend'lerine otomatik adaptasyon, tutarlı geliştirme deneyimi | ❌ Çok platformlu geliştirme platform farklılıklarını yönetmelidir |
| ✅ Bir kez tanımla, tüm platformlarda veri modellerini kullan | ❌ Farklı platformlar için veri modellerini yeniden tasarlama gerekliliği |
| ✅ Optimize edilmiş çok platformlu performans, tutarlı kullanıcı deneyimini korur | ❌ Platformlar arasında tutarsız performans özellikleri |
| ✅ Tüm platformlarda uygulanan birleşik güvenlik standartları | ❌ Platforma özgü güvenlik mekanizmaları ve yapılandırmaları |

### 7. Dağıtık Birincil Anahtar Algoritmaları vs. Geleneksel Otomatik Artan ID'ler
| Tostore | Geleneksel Veritabanları |
|:---------|:-----------|
| ✅ Çeşitli senaryo gereksinimlerine uygun dört dağıtık birincil anahtar algoritması | ❌ Basit otomatik artan ID'ler, küme ortamlarında çakışmalara maruz kalır |
| ✅ Dağıtık ID oluşturma, son derece yüksek paralel işlemleri destekler | ❌ Seri ID oluşturma yüksek paralellikte darboğaz haline gelir |
| ✅ İş ölçeğinin açığa çıkmasını önleyen rastgele adım uzunluğu ve dağıtık algoritmalar | ❌ ID'ler iş hacmi hakkında bilgi ifşa eder, güvenlik riskleri oluşturur |
| ✅ Kısa kodlardan zaman damgalarına, çeşitli okunabilirlik ve performans gereksinimlerini karşılar | ❌ Sınırlı ID türleri ve özelleştirme seçenekleri |

### 8. Akış Veri İşleme vs. Toplu Yükleme
| Tostore | Geleneksel Veritabanları |
|:---------|:-----------|
| ✅ Akış sorgu arayüzü, talep üzerine veri işleme, düşük bellek kullanımı | ❌ Tüm sonuçları bir kerede yükler, büyük veri kümeleriyle OOM'a duyarlı |
| ✅ Asenkron yineleme ve reaktif programlama modellerine destek | ❌ Senkron işleme modeli UI iş parçacığını engeller, kullanıcı deneyimini etkiler |
| ✅ Akış verilerinin paralel işlenmesi, çok çekirdekli performansı en üst düzeye çıkarır | ❌ Büyük verilerin sıralı işlenmesi, düşük CPU kullanımı |
| ✅ Veri hatları ve dönüşüm işlemlerine destek | ❌ Özel veri işleme mantığı uygulaması gerektirir |
| ✅ Yerleşik hız sınırlama ve geri basınç yönetimi mekanizmaları | ❌ Akış kontrolü eksikliği, kolay kaynak tükenmesi |

### 9. Akıllı Önbellek Stratejileri vs. Geleneksel Önbellek
| Tostore | Geleneksel Veritabanları |
|:---------|:-----------|
| ✅ Erişim kalıplarına uyarlanabilir çok seviyeli akıllı önbellek stratejileri | ❌ Basit LRU önbelleği, esneklik eksikliği |
| ✅ Kullanım kalıplarına dayalı otomatik önbellek strateji ayarlaması | ❌ Sabit önbellek yapılandırması, dinamik olarak ayarlanması zor |
| ✅ Soğuk başlatma sürelerini önemli ölçüde azaltan başlatma önbellek mekanizması | ❌ Başlatma önbelleği yok, yavaş soğuk başlatmalar, önbelleği yeniden oluşturma ihtiyacı |
| ✅ Optimal performans için önbellekle derinlemesine entegre depolama motoru | ❌ Ayrı önbellek ve depolama mantığı, ek senkronizasyon mekanizmaları gerektirir |
| ✅ Otomatik önbellek senkronizasyonu ve geçersiz kılma yönetimi, ek kod gerekmez | ❌ Önbellek tutarlılığı manuel bakım gerektirir, hatalara açık |

### 10. Sunucusuz Mimari vs. Geleneksel Sunucu Bağımlılığı
| Tostore | Geleneksel Veritabanları |
|:---------|:-----------|
| ✅ Gömülü tasarım, ek sunucular veya yapılandırmalar gerekmez | ❌ Ayrı bir veritabanı sunucusu veya bulut hizmeti gerektirir |
| ✅ Sıfır bakım maliyeti, uygulamaya entegre veri katmanı | ❌ Özel DBA'lar ve operasyon ekipleri gerektirir |
| ✅ Çevrimdışı çalışabilir, ağ bağlantısına bağımlılık yok | ❌ Ağ güvenilirliğine bağlıdır, çevrimdışı senaryolarda kullanılamaz |
| ✅ Basit dağıtım, uygulama tüm veri özelliklerini içerir | ❌ Karmaşık sunucu yapılandırması ve bağlantı yönetimi |
| ✅ Bağımsızlık ve dağıtık ölçeklendirme yeteneklerini birleştirir | ❌ Ya ölçeklenebilirlik olmadan basit, ya da karmaşık ve bakımı zor |

### 11. Akıllı Kaynak Optimizasyonu vs. Sabit Kaynak Tahsisi
| Tostore | Geleneksel Veritabanları |
|:---------|:-----------|
| ✅ Gerçek taleplere dayalı dinamik kaynak tüketimi ayarlaması | ❌ İş yükünden bağımsız sabit kaynak tahsisi |
| ✅ Cihaz yeteneklerine dayalı otomatik paralellik ayarlaması | ❌ Cihaz yeteneklerini dikkate almaz, karmaşık ve optimize edilmesi zor |
| ✅ Akıllı toplu işlem stratejileri, toplu işlemleri otomatik olarak optimize eder | ❌ Toplu işleme mantığının manuel uygulamasını gerektirir, zahmetli ve hatalara açık |
| ✅ Bellek kullanımı aktif veri hacmine karşılık gelir, toplam veri hacminden bağımsız | ❌ Bellek kullanımı toplam veritabanı boyutuyla yüksek oranda ilişkili |
| ✅ Enerji tüketimi ve performansı otomatik olarak dengeler, mobil cihazlara uygun | ❌ Pil ile çalışan cihazlar için optimize edilmemiş, yüksek enerji tüketimi ve ısı üretimi |

## Teknik Öne Çıkan Özellikler

- 🌐 **Şeffaf Çoklu Platform Desteği**:
  - Web, Linux, Windows, Mobil, Mac platformlarında tutarlı deneyim
  - Birleşik API arayüzü, sorunsuz çok platformlu veri senkronizasyonu
  - Çeşitli çok platformlu depolama backend'lerine (IndexedDB, dosya sistemleri vb.) otomatik adaptasyon
  - Kenar bilgi işlemden buluta sorunsuz veri akışı

- 🧠 **Sinir Ağlarından Esinlenen Dağıtık Mimari**:
  - Sinir ağlarına benzer ara bağlantılı düğüm topolojisi
  - Dağıtık işleme için verimli veri bölümleme mekanizması
  - Akıllı dinamik iş yükü dengeleme
  - Sınırsız düğüm genişletme desteği, karmaşık veri ağları kolay oluşturma

- ⚡ **Nihai Paralel İşleme Yetenekleri**:
  - Isolate'lerle gerçek paralel okuma/yazma, çok çekirdekli CPU'nun tam kullanımı
  - Çoklu görevlerin çarpılmış verimliliği için işbirliği yapan çok düğümlü hesaplama ağı
  - Kaynakları bilen dağıtık işleme çerçevesi, otomatik performans optimizasyonu
  - Büyük veri kümelerini işlemek için optimize edilmiş akış sorgu arayüzü

- 🔑 **Çeşitli Dağıtık Birincil Anahtar Algoritmaları**:
  - Sıralı artış algoritması - serbestçe ayarlanabilir rastgele adım uzunluğu
  - Zaman damgası tabanlı algoritma - yüksek performanslı paralel yürütme senaryoları için ideal
  - Tarih önekli algoritma - zaman aralığı göstergesine sahip veriler için uygun
  - Kısa kod algoritması - özlü benzersiz tanımlayıcılar

- 🔄 **Akıllı Şema Göçü**:
  - Tablo/alan yeniden adlandırma davranışlarının kesin tanımlanması
  - Şema değişiklikleri sırasında otomatik veri güncelleme ve göçü
  - Kesintisiz yükseltmeler, iş operasyonlarını etkilemez
  - Veri kaybını önleyen güvenli göç stratejileri

- 🛡️ **Kurumsal Düzey Güvenlik**:
  - Hassas verileri korumak için ChaCha20Poly1305 şifreleme algoritması
  - Depolanan ve iletilen verilerin güvenliğini sağlayan uçtan uca şifreleme
  - İnce taneli veri erişim kontrolü

- 🚀 **Akıllı Önbellek ve Arama Performansı**:
  - Verimli veri alımı için çok seviyeli akıllı önbellek mekanizması
  - Uygulama başlatma hızını önemli ölçüde artıran başlatma önbelleği
  - Önbellekle derinlemesine entegre depolama motoru, ek senkronizasyon kodu gerekmez
  - Adaptif ölçeklendirme, veriler büyüdükçe bile sabit performans sürdürme

- 🔄 **Yenilikçi İş Akışları**:
  - Çoklu alan veri izolasyonu, çok kiracılı ve çok kullanıcılı senaryolar için mükemmel destek
  - Hesaplama düğümleri arasında akıllı iş yükü ataması
  - Büyük ölçekli veri eğitimi ve analizi için sağlam veritabanı sağlar
  - Otomatik veri depolama, akıllı güncellemeler ve eklemeler

- 💼 **Geliştirici Deneyimi Öncelikli**:
  - Ayrıntılı iki dilli dokümantasyon ve kod yorumları (Çince ve İngilizce)
  - Zengin hata ayıklama bilgileri ve performans metrikleri
  - Yerleşik veri doğrulama ve bozulma kurtarma yetenekleri
  - Hızlı başlangıç, kutudan çıkar çıkmaz sıfır yapılandırma

## Hızlı Başlangıç

Temel kullanım:

```dart
// Veritabanı başlatma
final db = ToStore();
await db.initialize(); // İsteğe bağlı, işlemlerden önce veritabanı başlatmasının tamamlanmasını sağlar

// Veri ekleme
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
});

// Veri güncelleme
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// Veri silme
await db.delete('users').where('id', '!=', 1);

// Karmaşık zincirleme sorgular için destek
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// Otomatik veri depolama, varsa güncelleme, yoksa ekleme
await db.upsert('users', {'name': 'John','email': 'john@example.com'})
  .where('email', '=', 'john@example.com');
// Veya
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});

// Verimli kayıt sayımı
final count = await db.query('users').count();

// Akış sorgularını kullanarak büyük veri işleme
db.streamQuery('users')
  .where('email', 'like', '%@example.com')
  .listen((userData) {
    // Her kaydı gerektiği gibi işle, bellek baskısını önler
    print('Kullanıcı işleniyor: ${userData['username']}');
  });

// Global anahtar-değer çiftleri ayarlama
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// Global anahtar-değer çiftlerinden veri alma
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```

## Mobil Uygulama Örneği

```dart
// Mobil uygulamalar gibi sık başlatma senaryolarına uygun tablo yapısı tanımı, tablo yapısı değişikliklerinin hassas algılanması, otomatik veri yükseltme ve göçü
final db = ToStore(
  schemas: [
    const TableSchema(
      name: 'users', // Tablo adı
      tableId: "users",  // Benzersiz tablo tanımlayıcısı, isteğe bağlı, %100 yeniden adlandırma gereksinimleri tanımlaması için kullanılır, olmasa bile %98'den fazla hassasiyet oranına ulaşabilir
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id', // Birincil anahtar
      ),
      fields: [ // Alan tanımı, birincil anahtarı içermez
        FieldSchema(name: 'username', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'email', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'last_login', type: DataType.datetime),
      ],
      indexes: [ // İndeks tanımı
        IndexSchema(fields: ['username']),
        IndexSchema(fields: ['email']),
      ],
    ),
  ],
);

// Kullanıcı alanına geçme - veri izolasyonu
await db.switchSpace(spaceName: 'user_123');
```

## Backend Sunucu Örneği

```dart
await db.createTables([
      const TableSchema(
        name: 'users', // Tablo adı
        primaryKeyConfig: PrimaryKeyConfig(
          name: 'id', // Birincil anahtar
          type: PrimaryKeyType.timestampBased,  // Birincil anahtar türü
        ),
        fields: [
          // Alan tanımı, birincil anahtarı içermez
          FieldSchema(
              name: 'username',
              type: DataType.text,
              nullable: false,
              unique: true),
          FieldSchema(name: 'vector_data', type: DataType.blob),  // Vektör veri depolama
          // Diğer alanlar...
        ],
        indexes: [
          // İndeks tanımı
          IndexSchema(fields: ['username']),
          IndexSchema(fields: ['email']),
        ],
      ),
      // Diğer tablolar...
]);


// Tablo yapısı güncelleme
final taskId = await db.updateSchema('users')
    .renameTable('newTableName')  // Tabloyu yeniden adlandırma
    .modifyField('username',minLength: 5,maxLength: 20,unique: true)  // Alan özelliklerini değiştirme
    .renameField('oldName', 'newName')  // Alanı yeniden adlandırma
    .removeField('fieldName')  // Alanı kaldırma
    .addField('name', type: DataType.text)  // Alan ekleme
    .removeIndex(fields: ['age'])  // İndeksi kaldırma
    .setPrimaryKeyConfig(  // Birincil anahtar yapılandırmasını ayarlama
      const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
    );
    
// Göç görevi durumunu sorgulama
final status = await db.queryMigrationTaskStatus(taskId);  
print('Göç ilerlemesi: ${status?.progressPercentage}%');
```


## Dağıtık Mimari

```dart
// Dağıtık düğüm yapılandırması
final db = ToStore(
    config: DataStoreConfig(
        distributedNodeConfig: const DistributedNodeConfig(
            clusterId: 1,  // Küme üyeliği yapılandırması
            centralServerUrl: 'http://127.0.0.1:8080',
            accessToken: 'b7628a4f9b4d269b98649129'))
);

// Vektör verilerinin toplu eklemesi
await db.batchInsert('vector', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... Binlerce kayıt
]);

// Analiz için büyük veri kümelerinin akış işlemesi
await for (final record in db.streamQuery('vector')
    .where('vector_name', '=', 'face_2366')
    .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
    .stream) {
  // Akış arayüzü büyük ölçekli özellik çıkarma ve dönüştürmeyi destekler
  print(record);
}
```

## Birincil Anahtar Örnekleri
Çeşitli birincil anahtar algoritmaları, tümü dağıtık oluşturmayı destekler, sıralanmamış birincil anahtarların arama yetenekleri üzerindeki etkisinden kaçınmak için birincil anahtarları kendiniz oluşturmanız önerilmez.
Sıralı birincil anahtar PrimaryKeyType.sequential: 238978991
Zaman damgası tabanlı birincil anahtar PrimaryKeyType.timestampBased: 1306866018836946
Tarih önekli birincil anahtar PrimaryKeyType.datePrefixed: 20250530182215887631
Kısa kodlu birincil anahtar PrimaryKeyType.shortCode: 9eXrF0qeXZ

```dart
// Sıralı birincil anahtar PrimaryKeyType.sequential
// Dağıtık sistem etkinleştirildiğinde, merkezi sunucu düğümlerin kendilerinin oluşturduğu aralıklar tahsis eder, kompakt ve hatırlaması kolay, kullanıcı ID'leri ve çekici numaralar için uygundur
await db.createTables([
      const TableSchema(
        name: 'users',
        primaryKeyConfig: PrimaryKeyConfig(
          type: PrimaryKeyType.sequential,  // Sıralı birincil anahtar türü
          sequentialConfig:  SequentialIdConfig(
              initialValue: 10000, // Otomatik artış başlangıç değeri
              increment: 50,  // Artış adımı
              useRandomIncrement: true,  // İş hacmini açığa çıkarmamak için rastgele adım kullanımı
            ),
        ),
        // Alan ve indeks tanımı...
        fields: []
      ),
      // Diğer tablolar...
 ]);
```


## Güvenlik Yapılandırması

```dart
// Tablo ve alan yeniden adlandırma - otomatik tanıma ve veri koruma
final db = ToStore(
      config: DataStoreConfig(
        enableEncoding: true, // Tablo verileri için güvenli kodlama etkinleştirme
        encodingKey: 'YouEncodingKey', // Kodlama anahtarı, isteğe göre ayarlanabilir
        encryptionKey: 'YouEncryptionKey', // Şifreleme anahtarı, not: bu anahtarı değiştirmek eski verilerin şifresinin çözülmesini engelleyecektir
      ),
    );
```

## Performans Testleri

Tostore 2.0 doğrusal performans ölçeklenebilirliği uygular, paralel işleme, bölümleme mekanizmaları ve dağıtık mimarideki temel değişiklikler veri arama yeteneklerini önemli ölçüde geliştirmiş, büyük veri artışlarında bile milisaniye yanıt süreleri sağlamıştır. Büyük veri kümelerinin işlenmesi için akış sorgu arayüzü, bellek kaynaklarını tüketmeden büyük veri hacimlerini işleyebilir.



## Gelecek Planları
Tostore, çok modlu veri işleme ve semantik arama için yüksek boyutlu vektör desteği geliştiriyor.


Amacımız bir veritabanı oluşturmak değil; Tostore, sizin değerlendirmeniz için Toway framework'ünden çıkarılan basit bir bileşendir. Mobil uygulamalar geliştiriyorsanız, Flutter uygulaması geliştirmek için eksiksiz çözümü kapsayan entegre ekosistemiyle Toway framework'ünü kullanmanızı öneririz. Toway ile, altta yatan veritabanına dokunmanıza gerek kalmayacak, tüm sorgu, yükleme, depolama, önbellekleme ve veri görüntüleme işlemleri framework tarafından otomatik olarak gerçekleştirilecektir.
Toway framework'ü hakkında daha fazla bilgi için [Toway repository'sini](https://github.com/tocreator/toway) ziyaret edin.

## Dokümantasyon

Ayrıntılı dokümantasyon için [Wiki](https://github.com/tocreator/tostore) sayfamızı ziyaret edin.

## Destek ve geri bildirim

- Sorun bildirme: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- Tartışmaya katılın: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- Koda katkıda bulunun: [Katkı Kılavuzu](CONTRIBUTING.md)

## Lisans

Bu proje MIT lisansı altındadır - daha fazla ayrıntı için [LICENSE](LICENSE) dosyasına bakın.

---

<p align="center">Tostore'u faydalı bulursanız, lütfen bize bir ⭐️ vermeyi unutmayın</p>
