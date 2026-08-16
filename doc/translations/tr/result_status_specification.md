# ToStore ResultStatus Otomatik Teşhis ve Durum Çözümleme Spesifikasyonu

Otomatik operasyonların (Ops), yapay zeka (AI) ajanlarının, otomatik test betiklerinin ve istemci uygulamalarının veritabanı yürütme sonuçlarını ve istisna durumlarını doğru bir şekilde tanımlamasını sağlamak için ToStore, en son sürümünde yapılandırılmış bir `ResultStatus` sistemini kullanıma sunmuştur.

Bu spesifikasyon belgesi; veritabanı kullanıcılarının ve geliştiricilerinin durum çözümlemeyi bağımsız olarak uygulayabilmelerine yardımcı olmak amacıyla durum kodlarının tasarım ilkelerini, anlamsal belirteç anahtarı spesifikasyonlarını ve çeşitli durum türlerinin özel alan yapılarını ayrıntılı olarak açıklamaktadır.

---

## 1. Temel Tasarım İlkeleri

### 1.1 Sayısal Durum Kodu (code) Spesifikasyonu

Tüm sayısal durum kodları (`code`), başarılı durum hariç olmak üzere sabit 5 basamaklı bir uzunlukta tanımlanır:

- **Başarılı Durum (Özel Başarı Kodu)**: Özel olarak `0` değerine sabitlenmiştir.
- **Diğer Durumlar (Hata ve Teşhis Kodları)**: Tek tip olarak 5 basamaklıdır.
- **Sınıf Kodu**: Durum kodunun ilk iki basamağıdır ve ana kategoriyi hızlıca tanımlamak için kullanılır.
- **Yaprak Kod**: Durum kodunun son üç basamağıdır ve belirli hata senaryosunu temsil eder.

> [!TIP]
> Otomatik operasyonlar (Ops), AI ajanları veya harici test betikleri geliştirirken geliştiriciler; durum kodunun ilk iki basamağını (Sınıf Kodu) veya aralığını kullanarak ilgili istisna yöneticilerine yönlendirme yapabilir ve ardından Yaprak Koduna göre ayrıntılı işlemler gerçekleştirebilir.

> [!IMPORTANT]
> **Bellek İçi Kontrol En İyi Pratiği**:
> Veritabanı işlem sonuçlarını bellek içinde okurken (örneğin, istemci veya Dart/Flutter kodunda), **en çok önerilen ve en verimli yöntem, doğrudan `ResultStatus` veya `ResultType` içindeki yerleşik salt okunur özellikleri (Getters)** (örneğin `isBusinessError`, `isCriticalError` vb., bkz. [Bölüm 3.2](#32-bellek-i%C3%A7i-yard%C4%B1mc%C4%B1-%C3%B6zellikler-getters)) kullanmaktır. Böylece sayısal aralıkların manuel olarak ayrıştırılmasından veya dize ön eki eşleştirmelerinden kaçınılır.

### 1.2 Anlamsal Durum Belirteci (codeKey) Spesifikasyonu

Her durum, benzersiz bir dize belirteci olan `codeKey` değerine karşılık gelir:

- **Adlandırma Formatı**: `[Ana_Kategori_Öneki]_[Çok_Düzeyli_Detay_Belirteci]`.
- **Adlandırma Kuralı**: İngilizce büyük harfler ve alt çizgilerden `_` oluşur; boşluk veya özel karakter içermez.
- **Ana Kategori Ön Eki**: Durumun hangi temel iş mantığı kategorisine ait olduğunu belirtir. Birden fazla kategori düzeyi varsa, ön ek aramayı ve aralık filtrelemeyi kolaylaştırmak için en genel ön ek en başa yerleştirilir.

---

## 2. Sınıf Kodları Hızlı Başvuru Tablosu

Aşağıda, ToStore'daki tüm Sınıf Kodlarının eşleme tanımları yer almaktadır:

| Kod Aralığı | Sınıf Kodu (İlk 2 Basamak) | Anlamsal Ön Ek | Kategori | İstisna Stratejisi |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `00` | `SUCCESS` | **İşlem Başarılı** | İstisna fırlatmaz, normal şekilde döner. |
| `10000 - 19999` | `10 - 19` | `BIZ_` | **İş Mantığı Hatası** (Son kullanıcı girdi hataları, kısıt ihlalleri vb.) | İstisna fırlatmaz, her zaman `DbResult` veya `QueryResult` aracılığıyla yanıtlanır. |
| `20000 - 49999` | `20 - 49` | `DEV_` | **Geliştirici Hatası** (Geçersiz API parametreleri, geçersiz tablo şeması yapılandırması vb.) | Geliştiricileri uyarmak için **hata ayıklama (debug) ortamlarında doğrudan `DbException` fırlatır**; **üretim (production) ortamlarında ise normal sonuçlar olarak döner**. *(Not: Motor sürümü uyumsuzluğu ve ana geçiş grubu yürütme hataları kritik hatalardır ve üretim ortamında bile istisna fırlatır)* |
| `50000 - 79999` | `50 - 79` | `SYS_` | **Sistem Hatası** (Disk dolu, G/Ç istisnaları, kilit alma zaman aşımı vb.) | Normal yürütme engellendiğinde istisna fırlatır; diğerleri (örneğin işlem çakışması) sonuç olarak döndürülür. |
| `99000 - 99999` | `99` | `ENG_` | **Motor Hatası** (Motor mantık hatası, veri dosyası bozulması, bilinmeyen dahili hata) | Genellikle istisna fırlatmaz; ciddi durumlarda istisna fırlatır. |

---

## 3. ResultStatus Ortak Alan Yapısı ve Bellek İçi Yardımcılar

### 3.1 Ortak Alanlar (Serileştirilmiş JSON Yapısı)

Tüm `ResultStatus` türleri, JSON olarak serileştirildiğinde aşağıdaki 4 temel ortak alanı içerir. Kullanıcılar ön kontroller için bu alanları doğrudan okuyabilir.

| Alan | Tür | Açıklama |
| :--- | :--- | :--- |
| `index` | `int` | Toplu işlemlerdeki sıra dizini. Tekli işlemler için bu değer `0` olarak sabitlenmiştir. |
| `code` | `int` | Sayısal durum kodu (başarı için `0`, istisna için 5 basamaklı sayı). |
| `codeKey` | `String` | Anlamsal durum belirteç anahtarı, örneğin `BIZ_CONSTRAINT_UNIQUE`. |
| `message` | `String` | İnsan tarafından okunabilir durum ayrıntısı açıklaması. |

### 3.2 Bellek İçi Yardımcı Özellikler (Getters)

Dart/Flutter'da `ResultStatus` ve `ResultType`, manuel aralık kontrolleri veya dize eşleştirmesi yapmadan bellek içinde kategori ve önem derecesini kontrol etmek için son derece verimli `O(1)` salt okunur özellikleri (Getters) sarmalar:

| Özellik | Tür | Açıklama |
| :--- | :--- | :--- |
| `isBusinessError` | `bool` | Bunun bir **İş Mantığı Hatası** olup olmadığını belirtir (örneğin kısıt çakışması, tür dönüştürme hatası; aralık `10000 - 19999`). |
| `isConstraintError` | `bool` | **ConstraintStatus** ile eşleşip eşleşmediğini belirtir (`isBusinessError` ile aynı sayısal aralık: `10000 - 19999`). |
| `isDeveloperError` | `bool` | Bunun bir **Geliştirici Hatası** olup olmadığını belirtir (örneğin geçersiz Şema, parametre uyuşmazlığı, tablo bulunamadı; aralık `20000 - 49999`). |
| `isSystemError` | `bool` | Bunun bir **Sistem Hatası** olup olmadığını belirtir (örneğin kilit zaman aşımı, disk dolu, dosya kilidi; aralık `50000 - 79999`). |
| `isEngineError` | `bool` | Bunun bir **Motor Hatası** olup olmadığını belirtir (aralık `99000 - 99999`). |
| `isCriticalError` | `bool` | Bunun bir **Kritik Hata / Afet Düzeyinde Olay** olup olmadığını belirtir (manuel veya operasyonel müdahale gerektirir, örneğin disk dolu, bellek yetersiz, ciddi veri dosyası bozulması, uyumsuz geçiş hatası vb.). |

---

## 4. Ayrıntılı Çözümleme Yapıları ve Özel Alanlar

`code` / `codeKey` aralığına ve `ResultStatus` uygulamasının belirli alt sınıfına bağlı olarak, serileştirilmiş JSON yapısı farklı **özel teşhis alanları** taşıyacaktır. Aşağıda, 5 durum alt sınıfı için alan spesifikasyonları ve uygulama eşlemeleri yer almaktadır.

### 4.1 SuccessStatus (İşlem Başarılı)

- **Kategori Aralığı**: `code == 0`, `codeKey == "SUCCESS"`
- **Uygulanabilir Senaryo**: Kayıtlar başarıyla eklendi, güncellendi veya silindi.
- **Özel Alan Tanımı**:

  | Alan | Tür | Ayrıntılar |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **İsteğe bağlı**. Yalnızca tek satırlı yazma (örneğin `insert`) veya güncelleme (örneğin `update`) işlemlerinde döndürülür ve fiziksel olarak oluşturulan veya değiştirilen kayıt birincil anahtarını temsil eder. |

- **JSON Örneği**:
  ```json
  {
    "index": 0,
    "code": 0,
    "codeKey": "SUCCESS",
    "message": "Operation successful",
    "primaryKey": "usr_9a8f4c2b"
  }
  ```

---

### 4.2 ConstraintStatus (Veri Bütünlüğü ve Kısıt Çakışmaları)

- **Kategori Aralığı**: `[10000, 19999]` arasındaki `code` değerleri (tüm İş Mantığı Hatası yaprak kodları: doğrulama, bütünlük kısıtları ve kayıt bulunamadı). `ResultType.isConstraintError` ile uyumlu.
- **Özel Alan Tanımı**:

  | Alan | Tür | Ayrıntılar |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **Zorunlu**. Bütünlük kısıtı çakışmasının veya bulunamadı hatasının oluştuğu tablo adı. |
  | `constraintName` | `String?` | **İsteğe bağlı**. Hataya neden olan belirli kısıtın adı (örneğin yabancı anahtar için `fk_users_profile`, benzersizlik çakışması için dizin adı veya null olamaz/tür dönüşüm hataları için `null`). |
  | `fields` | `List<String>` | **Zorunlu**. Çakışmaya neden olan alanların listesi. |
  | `conflictingKeys` | `List<dynamic>` | **Zorunlu**. Çakışmaya neden olan girdi değerlerinin listesi, `fields` ile 1:1 eşleşir. Bir alan null ise, listedeki karşılık gelen öğe `null` olur. |
  | `primaryKey` | `String?` | **İsteğe bağlı**. İlişkili kayıt birincil anahtarı. Tek satırlı bir yazma işlemi değilse veya bellek aşamasında engellendiyse bu alan `null` olur. |
  | `referencedTable` | `String?` | **İsteğe bağlı**. Yabancı anahtar çakışmalarındaki üst tablo adı. |

- **Yaprak Kod Kılavuzu**:

  | Kod ve ResultType | Senaryo | Alan Kılavuzu |
  | :--- | :--- | :--- |
  | `10000`<br>`bizValidationFailed` | Veri biçimi veya aralık doğrulaması başarısız oldu | <ul><li>`tableName`: Etkilenen tablo</li><li>`constraintName`: `null`</li><li>`fields`: Doğrulamayı ihlal eden alanlar, örneğin `["email"]`</li><li>`conflictingKeys`: Başarısızlığa neden olan geçersiz değerler, örneğin `["invalid-email"]`</li><li>`primaryKey`: Kayıt birincil anahtarı (varsa)</li></ul> |
  | `10001`<br>`bizNotNullViolation` | Null olamaz kısıtı ihlali | <ul><li>`tableName`: Etkilenen tablo</li><li>`constraintName`: `null`</li><li>`fields`: Null kısıtlamasını ihlal eden alanlar, örneğin `["email"]`</li><li>`conflictingKeys`: Her zaman `[null]`</li><li>`primaryKey`: Kayıt birincil anahtarı (varsa)</li></ul> |
  | `10002`<br>`bizTypeCastFailed` | Veri türü dönüşümü veya cast işlemi başarısız oldu | <ul><li>`tableName`: Etkilenen tablo</li><li>`constraintName`: `null`</li><li>`fields`: Dönüşümü başarısız olan alanlar, örneğin `["age"]`</li><li>`conflictingKeys`: Başarısızlığa neden olan geçersiz değerler, örneğin `["not_a_number"]`</li><li>`primaryKey`: Kayıt birincil anahtarı (varsa)</li></ul> |
  | `11001`<br>`bizPrimaryKeyViolation` | Birincil anahtar çakışması (zaten mevcut) | <ul><li>`tableName`: Etkilenen tablo</li><li>`constraintName`: `"PRIMARY"` veya kısıt adı</li><li>`fields`: Birincil anahtar alanları, örneğin `["id"]`</li><li>`conflictingKeys`: Yinelenen değerler, örneğin `["usr_101"]`</li><li>`primaryKey`: Çakışan değer, örneğin `"usr_101"`</li></ul> |
  | `11002`<br>`bizUniqueViolation` | Benzersizlik kısıtı ihlali | <ul><li>`tableName`: Etkilenen tablo</li><li>`constraintName`: Benzersiz dizin adı, örneğin `"uk_email"`</li><li>`fields`: Benzersizliği oluşturan alanlar, örneğin `["email"]`</li><li>`conflictingKeys`: Çakışmaya neden olan değerler, örneğin `["test@a.com"]`</li><li>`primaryKey`: Çakışan kayıt birincil anahtarı (varsa)</li></ul> |
  | `11003`<br>`bizForeignKeyViolation` | Yabancı anahtar kısıt ihlali (Genel) | <ul><li>`tableName`: Alt tablo (child)</li><li>`constraintName`: Yabancı anahtar kısıt adı</li><li>`fields`: Yabancı anahtar sütunları</li><li>`conflictingKeys`: Çakışmaya neden olan girdi değerleri</li><li>`primaryKey`: Kayıt birincil anahtarı (varsa)</li><li>`referencedTable`: Üst tablo (parent)</li></ul> |
  | `11004`<br>`bizCheckViolation` | Kontrol (check) kısıtı ihlali | <ul><li>`tableName`: Etkilenen tablo</li><li>`constraintName`: Kontrol kısıt adı</li><li>`fields`: Kontrol edilen alanlar</li><li>`conflictingKeys`: Kontrolü ihlal eden değerler</li><li>`primaryKey`: Kayıt birincil anahtarı (varsa)</li></ul> |
  | `11005`<br>`bizForeignKeyParentNotExist` | Başvurulan üst anahtar mevcut değil | <ul><li>`tableName`: Alt tablo (child)</li><li>`constraintName`: Yabancı anahtar kısıt adı</li><li>`fields`: Yabancı anahtar sütunları, örneğin `["userId"]`</li><li>`conflictingKeys`: Mevcut olmayan referans değeri, örneğin `["non_parent"]`</li><li>`primaryKey`: Kayıt birincil anahtarı (varsa)</li><li>`referencedTable`: Üst tablo (parent)</li></ul> |
  | `11006`<br>`bizForeignKeyChildRestrict` | Silme/güncelleme alt kayıtlar tarafından kısıtlanmış | <ul><li>`tableName`: Üst tablo (parent)</li><li>`constraintName`: Yabancı anahtar kısıt adı</li><li>`fields`: Üst başvurulan sütunlar</li><li>`conflictingKeys`: Alt tablo tarafından başvurulan üst anahtar değerleri</li><li>`primaryKey`: Üst anahtar değerleri</li><li>`referencedTable`: Alt tablo (child)</li></ul> |
  | `11007`<br>`bizForeignKeyCompositeMismatch` | Eksik bileşik yabancı anahtar değerleri | <ul><li>`tableName`: Alt tablo (child)</li><li>`constraintName`: Yabancı anahtar kısıt adı</li><li>`fields`: Bileşik yabancı anahtar sütunları</li><li>`conflictingKeys`: Girdi değerleri (kısmi null değerler içerir)</li><li>`primaryKey`: Kayıt birincil anahtarı (varsa)</li><li>`referencedTable`: Üst tablo (parent)</li></ul> |
  | `11008`<br>`bizForeignKeyTypeMismatch` | Yabancı anahtar tür uyuşmazlığı | <ul><li>`tableName`: Alt tablo (child)</li><li>`constraintName`: Yabancı anahtar kısıt adı</li><li>`fields`: Yabancı anahtar sütunları</li><li>`conflictingKeys`: Dönüşümü başarısız olan değerler</li><li>`primaryKey`: Kayıt birincil anahtarı (varsa)</li><li>`referencedTable`: Üst tablo (parent)</li></ul> |
  | `11009`<br>`bizValueExceedsMaxLength` | Değer uzunluğu maksimum kısıtı aşıyor | <ul><li>`tableName`: Etkilenen tablo</li><li>`constraintName`: `null`</li><li>`fields`: Sınırı ihlal eden alanlar, örneğin `["name"]`</li><li>`conflictingKeys`: Sınırı aşan değerler, örneğin `["a" * 1000]`</li><li>`primaryKey`: Kayıt birincil anahtarı (varsa)</li></ul> |
  | `11010`<br>`bizValueLessThanMinLength` | Değer uzunluğu minimum kısıtından az | <ul><li>`tableName`: Etkilenen tablo</li><li>`constraintName`: `null`</li><li>`fields`: Sınırı ihlal eden alanlar, örneğin `["code"]`</li><li>`conflictingKeys`: Minimum değerden kısa değerler, örneğin `["ab"]`</li><li>`primaryKey`: Kayıt birincil anahtarı (varsa)</li></ul> |
  | `11011`<br>`bizValueLessThanMinValue` | Sayısal değer minimum kısıtından az | <ul><li>`tableName`: Etkilenen tablo</li><li>`constraintName`: `null`</li><li>`fields`: Sınırı ihlal eden alanlar, örneğin `["age"]`</li><li>`conflictingKeys`: Minimum değerden küçük değerler, örneğin `[-5]`</li><li>`primaryKey`: Kayıt birincil anahtarı (varsa)</li></ul> |
  | `11012`<br>`bizValueExceedsMaxValue` | Sayısal değer maksimum kısıtını aşıyor | <ul><li>`tableName`: Etkilenen tablo</li><li>`constraintName`: `null`</li><li>`fields`: Sınırı ihlal eden alanlar, örneğin `["score"]`</li><li>`conflictingKeys`: Maksimum değeri aşan değerler, örneğin `[105]`</li><li>`primaryKey`: Kayıt birincil anahtarı (varsa)</li></ul> |
  | `12001`<br>`bizRecordNotFound` | Kaynak mevcut değil / Kayıt bulunamadı | <ul><li>`tableName`: Etkilenen tablo</li><li>`constraintName`: `null`</li><li>`fields`: Arama hedef alanları, örneğin `["id"]`</li><li>`conflictingKeys`: Bulunamayan hedef anahtarlar, örneğin `["non_exist_id"]`</li><li>`primaryKey`: Eksik anahtarın değeri, örneğin `"non_exist_id"`</li></ul> |

- **JSON Örneği** (Yabancı anahtarın üst kaydı mevcut değil hatası):
  ```json
  {
    "index": 0,
    "code": 11005,
    "codeKey": "BIZ_CONSTRAINT_FOREIGN_KEY_PARENT_NOT_EXIST",
    "message": "Foreign key constraint violation on table \"profiles\" (Constraint: \"fk_profiles_userId\"): Referenced record does not exist in table \"users\" for fields (userId) referencing (id). Conflicting values: [usr_999]",
    "tableName": "profiles",
    "constraintName": "fk_profiles_userId",
    "fields": ["userId"],
    "conflictingKeys": ["usr_999"],
    "primaryKey": "prof_112233",
    "referencedTable": "users"
  }
  ```

---

### 4.3 SchemaValidationStatus (Tablo Şeması Doğrulama ve Uyumsuz Geçiş)

- **Kategori Aralığı**: `[30000, 39999]` — `30000–30013` statik şema doğrulama, `31001–31006` geçiş korumaları.
- **Özel Alan Tanımı**:

  | Alan | Tür | Ayrıntılar |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **Zorunlu**. Doğrulanan veya fiziksel olarak geçiş yapılan tablonun adı. |
  | `field` | `String?` | **İsteğe bağlı**. Şema veya geçiş hatasını tetikleyen belirli alan adı. |
  | `wrongValue` | `dynamic` | **İsteğe bağlı**. Çakışmaya neden olan geçersiz yapılandırma değeri veya geçiş farkı yapılandırması. |

- **Yaprak Kod Kılavuzu**:

  | Kod ve ResultType | Senaryo | Alan Kılavuzu |
  | :--- | :--- | :--- |
  | `30000`<br>`devInvalidSchema` | Geçersiz tablo şeması tanımı | <ul><li>`tableName`: Tablo adı</li><li>`field`: `null`</li><li>`wrongValue`: Geçersiz yapılandırma eşlemesi veya `null`</li></ul> |
  | `30001`<br>`devInvalidSchemaTableName` | Tablo adı doğrulaması başarısız (geçersiz karakterler veya çok uzun) | <ul><li>`tableName`: Hatalı isim</li><li>`field`: `null`</li><li>`wrongValue`: Hatalı dize</li></ul> |
  | `30002`<br>`devInvalidSchemaFieldName` | Alan adı doğrulaması başarısız (geçersiz karakterler) | <ul><li>`tableName`: Tablo adı</li><li>`field`: Hatalı alan adı</li><li>`wrongValue`: Hatalı dize</li></ul> |
  | `30003`<br>`devInvalidSchemaDuplicateFieldName` | Tablo şemasında yinelenen alan adı | <ul><li>`tableName`: Tablo adı</li><li>`field`: Yinelenen alan adı</li><li>`wrongValue`: `null`</li></ul> |
  | `30004`<br>`devInvalidSchemaPrimaryKey` | Birincil anahtar doğrulaması başarısız (eksik veya geçersiz biçim) | <ul><li>`tableName`: Tablo adı</li><li>`field`: `"primaryKey"` veya birincil anahtar alan adı</li><li>`wrongValue`: Birincil anahtar yapılandırma ayrıntıları</li></ul> |
  | `30005`<br>`devInvalidSchemaIndexLimit` | Tablo dizin sayısı 16 olan sistem sınırını aşıyor | <ul><li>`tableName`: Tablo adı</li><li>`field`: `null`</li><li>`wrongValue`: Dizin yapılandırmaları listesi</li></ul> |
  | `30006`<br>`devInvalidSchemaIndexField` | Dizin mevcut olmayan bir alana başvuruyor | <ul><li>`tableName`: Tablo adı</li><li>`field`: Dizin adı</li><li>`wrongValue`: Uyuşmazlığa neden olan alan adı</li></ul> |
  | `30007`<br>`devInvalidSchemaIndexType` | Dizin türü alan veri türü veya yapılandırmasıyla uyumsuz | <ul><li>`tableName`: Tablo adı</li><li>`field`: Dizin/alan adı</li><li>`wrongValue`: Çakışma bilgisi, örn. `{ "indexType": "btree", "fieldType": "vector" }`</li></ul> |
  | `30008`<br>`devInvalidSchemaForeignKey` | Yabancı anahtar tanımı geçersiz (örneğin sütun eşleşmesi yok) | <ul><li>`tableName`: Tablo adı</li><li>`field`: Yabancı anahtar adı</li><li>`wrongValue`: Yabancı anahtar yapılandırma ayrıntıları</li></ul> |
  | `30009`<br>`devInvalidSchemaSpaceMismatch` | Küresel/Alana özgü sınır uyuşmazlığı | <ul><li>`tableName`: Tablo adı</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30010`<br>`devInvalidSchemaTtlConfig` | TTL yapılandırma doğrulaması başarısız oldu | <ul><li>`tableName`: Tablo adı</li><li>`field`: TTL zaman damgası alanı</li><li>`wrongValue`: Geçersiz TTL yapılandırma eşlemesi, örneğin, `{ "enabled": true, "fieldName": "expire_at" }`</li></ul> |
  | `30011`<br>`devSchemaTableExists` | Tablo zaten mevcut | <ul><li>`tableName`: Tablo adı</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30012`<br>`devSchemaFieldExists` | Şema yükseltme: zaten mevcut olan bir alan eklenmeye çalışılıyor | <ul><li>`tableName`: Tablo adı</li><li>`field`: Çakışan alan adı</li><li>`wrongValue`: `null`</li></ul> |
  | `30013`<br>`devSchemaIndexExists` | Şema yükseltme: zaten mevcut olan bir dizin eklenmeye çalışılıyor | <ul><li>`tableName`: Tablo adı</li><li>`field`: Dizin adı</li><li>`wrongValue`: `null`</li></ul> |
  | `31001`<br>`devMigrationNotAllowedWithData` | Geçiş veri değişikliği gerektiriyor ancak açıkça izin verilmemiş | <ul><li>`tableName`: Tablo adı</li><li>`field`: `null`</li><li>`wrongValue`: Geçiş yükseltme farkları eşlemesi</li></ul> |
  | `31002`<br>`devMigrationUnsafeTypeConversion` | Fiziksel geçiş: alan için desteklenmeyen tür dönüşümü | <ul><li>`tableName`: Tablo adı</li><li>`field`: Alan adı</li><li>`wrongValue`: Çakışan türler eşlemesi, örneğin `{ "from": "text", "to": "integer" }`</li></ul> |
  | `31003`<br>`devMigrationCannotAddNonNullField` | Boş olmayan tabloya varsayılan değer olmadan null olamaz alan eklenemez | <ul><li>`tableName`: Tablo adı</li><li>`field`: Hatalı alan adı</li><li>`wrongValue`: Geçiş parametreleri, örneğin `{ "nullable": false, "defaultValue": null }`</li></ul> |
  | `31004`<br>`devMigrationNullableToNonNullNotAllowed` | Fiziksel geçiş: alanı null olabilir durumdan null olamaz duruma getirme | <ul><li>`tableName`: Tablo adı</li><li>`field`: Alan adı</li><li>`wrongValue`: Geçiş parametreleri, 31003 ile aynı</li></ul> |
  | `31005`<br>`devMigrationUniqueTighteningNotAllowed` | Fiziksel geçiş: alan kısıtlamasını UNIQUE olarak sıkılaştırma | <ul><li>`tableName`: Tablo adı</li><li>`field`: Alan adı</li><li>`wrongValue`: Benzersizlik kısıtlamasına neden olan dizin tanımı</li></ul> |
  | `31006`<br>`devMigrationPromoteLargeOpNotAllowed` | promoteFieldToPrimaryKey sırasında büyük ölçekli işlemler engellenir | <ul><li>`tableName`: Tablo adı</li><li>`field`: `null`</li><li>`wrongValue`: Promote aşaması / görev id (varsa)</li></ul> |

- **JSON Örneği** (Boş olmayan tabloya varsayılan değer olmadan null olamaz alan ekleme hatası):
  ```json
  {
    "index": 0,
    "code": 31003,
    "codeKey": "DEV_MIGRATION_CANNOT_ADD_NON_NULL_FIELD",
    "message": "Cannot add non-nullable field \"phone\" without a default value to non-empty table \"users\". This operation is physically impossible and would fail during data write.",
    "tableName": "users",
    "field": "phone",
    "wrongValue": {
      "nullable": false,
      "defaultValue": null
    }
  }
  ```

---

### 4.4 InvalidArgumentStatus (API Argümanları ve İmleç Sayfalama Doğrulaması)

- **Kategori Aralığı**: `[20000, 20999]` arasındaki `code` değerleri (**hariç** `20005` / `20006`), **artı** `22004` (`devFieldNotFound`). `20005` / `20006` ve diğer `2200x` bulunamadı kodları GeneralStatus (§4.6) kullanır.
- **Özel Alan Tanımı**:

  | Alan | Tür | Ayrıntılar |
  | :--- | :--- | :--- |
  | `parameterName` | `String` | **Zorunlu**. Doğrulama hatasını tetikleyen argüman adı (örneğin `"cursor"`, `"orderBy"` veya belirli sütun anahtarı). |
  | `passedValue` | `dynamic` | **İsteğe bağlı**. Arayan tarafından iletilen uygun olmayan giriş değeri. Karmaşık nesneler dizelere dönüştürülür. |
  | `primaryKey` | `String?` | **İsteğe bağlı**. İlişkili kayıt birincil anahtarı. |

- **Yaprak Kod Kılavuzu**:

  | Kod ve ResultType | Senaryo | Alan Kılavuzu |
  | :--- | :--- | :--- |
  | `20001`<br>`devInvalidArgumentFormat` | Argüman biçim hatası | <ul><li>`parameterName`: Geçersiz argüman adı</li><li>`passedValue`: İletilen değer, örneğin `"twenty"`</li><li>`primaryKey`: Kayıt birincil anahtarı (varsa)</li></ul> |
  | `20002`<br>`devInvalidArgumentType` | Argüman türü uyuşmazlığı | <ul><li>`parameterName`: Parametre adı</li><li>`passedValue`: İletilen değer, örneğin `{"foo": "bar"}` (String beklendiğinde)</li><li>`primaryKey`: Kayıt birincil anahtarı (varsa)</li></ul> |
  | `20003`<br>`devInvalidArgumentMissing` | Gerekli argüman eksik | <ul><li>`parameterName`: Eksik parametre adı, örneğin `"dbPath"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: Kayıt birincil anahtarı (varsa)</li></ul> |
  | `20004`<br>`devInvalidPrimaryKeyFormat` | Geçersiz birincil anahtar biçimi | <ul><li>`parameterName`: `"primaryKey"` veya birincil anahtar alanı</li><li>`passedValue`: Geçersiz birincil anahtar değeri, örneğin, `"invalid_id_value"`</li><li>`primaryKey`: Geçersiz birincil anahtar değeri</li></ul> |
  | `20007`<br>`devVectorDimensionMismatch` | Vektör boyutları uyuşmuyor | <ul><li>`parameterName`: `"other"`</li><li>`passedValue`: Hatalı boyut boyutu</li><li>`primaryKey`: `null`</li></ul> |
  | `20008`<br>`devIndexFieldMissing` | İmleç için kayıtta gerekli dizin alanı eksik | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Eksik dizin alanı</li><li>`primaryKey`: `null`</li></ul> |
  | `20101`<br>`devInvalidCursorPagination` | İmleç sayfalama ve ofset (offset) birbirini dışlar | <ul><li>`parameterName`: `"cursor"` / `"offset"`</li><li>`passedValue`: Çakışan sayfalama parametreleri</li><li>`primaryKey`: `null`</li></ul> |
  | `20102`<br>`devInvalidCursorTable` | İmleç hedef tabloyla eşleşmiyor | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: İmleç belirteci</li><li>`primaryKey`: `null`</li></ul> |
  | `20103`<br>`devInvalidCursorSignature` | Uyuşmayan imleç imzası (tahrif edilmiş) | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: İmleç belirteci</li><li>`primaryKey`: `null`</li></ul> |
  | `20104`<br>`devInvalidCursorOrderBy` | İmleç orderBy yapılandırması geçersiz veya uyuşmuyor | <ul><li>`parameterName`: `"orderBy"`</li><li>`passedValue`: OrderBy listesi, örneğin `["-age", "id"]`</li><li>`primaryKey`: `null`</li></ul> |
  | `20105`<br>`devInvalidCursorMode` | İmleç belirteç modu uyuşmazlığı | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Belirteç modu, örneğin, `"sortKey"`</li><li>`primaryKey`: `null`</li></ul> |
  | `20106`<br>`devInvalidCursorPayload` | Geçersiz imleç yükü (kod çözülemez) | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: `null`</li></ul> |
  | `20201`<br>`devInvalidQuerySelectField` | Sorgu seçme alanı String veya QueryAggregation olmalıdır | <ul><li>`parameterName`: `"select"`</li><li>`passedValue`: Geçersiz seçme alanı tanımı</li><li>`primaryKey`: `null`</li></ul> |
  | `20202`<br>`devInvalidQueryForeignKeyJoin` | Otomatik birleştirme için yabancı anahtar ilişkisi yok | <ul><li>`parameterName`: `"join"` / `"tableName"`</li><li>`passedValue`: İlişkisi olmayan hedef tablo</li><li>`primaryKey`: `null`</li></ul> |
  | `20203`<br>`devInvalidQueryFieldAlias` | Sorgu alanı takma adı biçimi geçersiz | <ul><li>`parameterName`: `"alias"`</li><li>`passedValue`: Geçersiz takma ad dizesi</li><li>`primaryKey`: `null`</li></ul> |
  | `20204`<br>`devInvalidExpression` | Geçersiz ifade yapılandırması veya yürütme istisnası | <ul><li>`parameterName`: Hata yönü (örneğin `"arguments"`, `"functionName"`, `"node"`)</li><li>`passedValue`: Geçersiz değer veya sayı</li><li>`primaryKey`: `null`</li></ul> |
  | `22004`<br>`devFieldNotFound` | Alan bulunamadı | <ul><li>`parameterName`: Bilinmeyen alan adı, örneğin `"extra"`</li><li>`passedValue`: Alan için iletilen girdi değeri</li><li>`primaryKey`: Kayıt birincil anahtarı (varsa)</li></ul> |

- **JSON Örneği** (İmleç sıralama alanları mevcut sorgu sıralama alanlarıyla eşleşmiyor hatası):
  ```json
  {
    "index": 0,
    "code": 20104,
    "codeKey": "DEV_INVALID_CURSOR_ORDERBY",
    "message": "Cursor orderBy fields do not match current query orderBy.",
    "parameterName": "orderBy",
    "passedValue": ["age DESC", "id ASC"],
    "primaryKey": null
  }
  ```

---

### 4.5 TransactionOperationStatus (İşlem Çakışması ve İptali)

- **Kategori Aralığı**: yalnızca `50001` (`sysTransactionAborted`) ve `50002` (`sysTransactionConflict`). Diğer `500xx` kodları (örn. `50003` / `50004`) GeneralStatus (§4.6) kullanır.
- **Özel Alan Tanımı**:

  | Alan | Tür | Ayrıntılar |
  | :--- | :--- | :--- |
  | `txId` | `String` | **Zorunlu**. Küresel düzeyde benzersiz işlem akışı tanımlayıcı kimliği. İşlem yaşam döngüsünü izlemek için kullanılır. |

- **Yaprak Kod Kılavuzu**:

  | Kod ve ResultType | Senaryo | Alan Kılavuzu |
  | :--- | :--- | :--- |
  | `50001`<br>`sysTransactionAborted` | İşlem iptal edildi (açıkça geri alma veya zincirleme hata) | <ul><li>`txId`: Etkin işlem kimliği</li></ul> |
  | `50002`<br>`sysTransactionConflict` | İşlem çakışması (SSI/WAL'da aynı anahtara eşzamanlı güncellemeler) | <ul><li>`txId`: Çakışan işlem kimliği</li></ul> |

- **JSON Örneği** (SSI Eşzamanlı Yazma-Yazma çakışması):
  ```json
  {
    "index": 0,
    "code": 50002,
    "codeKey": "SYS_TRANSACTION_CONFLICT",
    "message": "Transaction conflict, concurrent updates detected on entity version mismatch (record: usr_123456)",
    "txId": "tx_88ff3b2a99c1"
  }
  ```

---

### 4.6 GeneralStatus (Genel ve Sistem Düzeyinde İstisnalar)

- **Kategori Aralığı**: §§4.1–4.5 dışında kalan kodlar için yedek — `20005` / `20006`, `22001`–`22003`, `230xx` / `240xx`, kalan `50xxx`–`53xxx` ve `99001` dahil.
- **Özel Alan Tanımı**:

  | Alan | Tür | Ayrıntılar |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **İsteğe bağlı**. İlişkili kayıt birincil anahtarı. |
  | `target` | `String?` | **İsteğe bağlı**. Hedef fiziksel kaynak, örneğin fiziksel dosya yolları, kilitler veya URL'ler. |
  | `operation` | `String?` | **İsteğe bağlı**. Etkin sistem çağrısı adı, örneğin `'readAsString'`, `'delete'`, `'acquire'`. |

- **Yaprak Kod Kılavuzu**:

  | Kod ve ResultType | Senaryo / Seviye | Alan Kılavuzu |
  | :--- | :--- | :--- |
  | `20005`<br>`devIndexOutOfBounds` | Dizin veya aralık sınırların dışında (Geliştirici Hatası) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `20006`<br>`devUnsupportedOperation` | İşlem mevcut bağlamda desteklenmiyor (Geliştirici Hatası) | <ul><li>`primaryKey`: `null`</li><li>`target`: Hedef tablo/kaynak (varsa)</li><li>`operation`: Yöntem adı (varsa)</li></ul> |
  | `22001`<br>`devTableNotFound` | Tablo bulunamadı (Geliştirici Hatası) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22002`<br>`devIndexNotFound` | Dizin bulunamadı (Geliştirici Hatası) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22003`<br>`devSpaceNotFound` | Alan bulunamadı (Geliştirici Hatası) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `23001`<br>`devLargeScaleOperationRequired` | Large-scale data operation requires `allowLargeScaleOperation()` (Developer Error) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `23002`<br>`devLargeScaleOperationNotAllowedInTransaction` | Large-scale data operation is not allowed inside a transaction (Developer Error) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `24001`<br>`devEngineIncompatible` | **Kritik**: Motor sürümü uyumsuz | <ul><li>`primaryKey`: `null`</li></ul> |
  | `50003`<br>`sysTransactionLimitExceeded` | İşlem arabelleğindeki veriler bellek baskısı altında güvenli sınırı aşıyor (Sistem Hatası) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `50004`<br>`sysMigrationBatchExecutionFailed` | Toplu geçiş yürütmesi başarısız oldu (Sistem Hatası) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51001`<br>`sysTimeoutLockAcquisition` | Kilit alma zaman aşımı (Sistem Hatası) | <ul><li>`primaryKey`: Hedef anahtar (varsa)</li><li>`target`: Kilit kaynak kimliği</li><li>`operation`: `"acquire"`</li></ul> |
  | `51002`<br>`sysTimeout` | İşlem zaman aşımı (Sistem Hatası) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51003`<br>`sysDbClosed` | Veritabanı kapalı, işlem güvenli bir şekilde iptal edildi (Sistem Hatası) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52001`<br>`sysResourceExhaustedMemory` | Bellek kaynağı tükendi (Sistem Hatası) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52002`<br>`sysResourceExhausted` | Sistem kaynakları tükendi, örneğin disk dolu (Sistem Hatası) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `53001`<br>`sysIoNotFound` | Fiziksel dosya veya yol mevcut değil (Sistem Hatası) | <ul><li>`primaryKey`: `null`</li><li>`target`: Dosya veya klasör yolu</li><li>`operation`: G/Ç işlemi</li></ul> |
  | `53002`<br>`sysIoPermissionDenied` | Dosya erişimi için izin reddedildi (Sistem Hatası) | <ul><li>`primaryKey`: `null`</li><li>`target`: Dosya yolu</li><li>`operation`: G/Ç işlemi</li></ul> |
  | `53003`<br>`sysIoDiskFull` | Disk dolu veya depolama kotası aşıldı (Sistem Hatası) | <ul><li>`primaryKey`: `null`</li><li>`target`: Dosya yolu</li><li>`operation`: G/Ç işlemi</li></ul> |
  | `53004`<br>`sysIoFileLocked` | Dosya kilitli veya başka bir işlem tarafından kullanılıyor (Sistem Hatası) | <ul><li>`primaryKey`: `null`</li><li>`target`: Dosya yolu</li><li>`operation`: G/Ç işlemi</li></ul> |
  | `53005`<br>`sysIoDeviceFault` | Depolama aygıtı veya ortam hatası (Sistem Hatası) | <ul><li>`primaryKey`: `null`</li><li>`target`: Dosya yolu</li><li>`operation`: G/Ç işlemi</li></ul> |
  | `53006`<br>`sysIoWebStorageUnavailable` | Web IndexedDB veya depolama alanı kullanılamıyor (Sistem Hatası) | <ul><li>`primaryKey`: `null`</li><li>`target`: IndexedDB kaynağı</li><li>`operation`: G/Ç işlemi</li></ul> |
  | `53007`<br>`sysBackupCorrupted` | Yedekleme paketi bozuk veya meta verileri eksik (Sistem Hatası) | <ul><li>`primaryKey`: `null`</li><li>`target`: Yedekleme yolu</li><li>`operation`: Yedekleme okuma/yazma</li></ul> |
  | `53008`<br>`sysIoDataCorrupted` | Veritabanı veri dosyası bozuk veya sağlama toplamı başarısız (Sistem Hatası) | <ul><li>`primaryKey`: `null`</li><li>`target`: Veri dosyası yolu</li><li>`operation`: G/Ç işlemi</li></ul> |
  | `53009`<br>`sysInvalidDataFormat` | Veri akışı biçimlendirmesi veya ayrıştırılması başarısız oldu (Sistem Hatası) | <ul><li>`primaryKey`: `null`</li><li>`target`: Veri akışı anahtarı</li><li>`operation`: `"decode"` / `"deserialize"`</li></ul> |
  | `53099`<br>`sysIoGeneric` | Genel sistem G/Ç hatası (Sistem Hatası) | <ul><li>`primaryKey`: `null`</li><li>`target`: Dosya yolu</li><li>`operation`: G/Ç işlemi</li></ul> |
  | `99001`<br>`engError` | Motor hatası (Motor Hatası) | <ul><li>`primaryKey`: `null`</li></ul> |

- **JSON Örneği** (Tablo bulunamadı hatası):
  ```json
  {
    "index": 0,
    "code": 22001,
    "codeKey": "DEV_NOT_FOUND_TABLE",
    "message": "Table \"orders\" not found in database metadata schema.",
    "primaryKey": null
  }
  ```

---

## 5. Veritabanı Kullanıcıları İçin Çözümleme ve İstisna Yönetimi Önerileri (Dart/Flutter Örnekleri)

ToStore'da tüm temel yazma işlemleri (Insert, Update, Delete) `DbResult` döndürür. Sorgular `QueryResult` döndürür ve işlem (transaction) operasyonları `TransactionResult` döndürür. Yapısal yapılandırma hataları `DbException` fırlatır.

Aşağıda, geliştirici uygulamalarının veritabanı durumlarını nasıl tüketmesi, ayrıştırması ve düzgün bir şekilde yönetmesi gerektiğini gösteren kod örnekleri yer almaktadır:

### 5.1 Yazma İşlemi Yanıtlarını Yönetme (`DbResult`)

```dart
import 'package:tostore/tostore.dart';

void handleDatabaseWriteResult(DbResult result) {
  // 1. Yazma işleminin tamamen hatasız tamamlanıp tamamlanmadığını anında kontrol edin
  if (!result.hasErrors) {
    print("Tüm yazma işlemleri başarılı oldu. Etkilenen: ${result.successCount}");

    // Tek satırlı yazma işlemleri için durumları döngüye sokmadan doğrudan anahtarı alın
    if (result.firstPrimaryKey != null) {
      print("İlk başarılı kaydın birincil anahtarı: ${result.firstPrimaryKey}");
    }
  } else {
    print("🛑 Hata algılandı. Başarılı: ${result.successCount}, Başarısız: ${result.failedCount}");
    print("İlk hata: ${result.firstType.codeKey} (${result.firstType.code})");

    // 2. Durumları döngüyle dönün (dizin, girdi toplu dizisi ile 1:1 eşleşir)
    for (final status in result.statuses) {
      final int idx = status.index;

      // 3. Yönetim mantığını yönlendirmek için alt sınıfları kalıpla eşleştirin (pattern match)
      if (status is SuccessStatus) {
        print("Dizin [$idx] Başarılı. Birincil anahtar: ${status.primaryKey}");
      } 
      else if (status is ConstraintStatus) {
        // Kısıt ihlalini yönetin (birincil anahtar, benzersizlik, kontrol, yabancı anahtar vb.)
        print("Dizin [$idx] Kısıt ihlali! Tablo: ${status.tableName}, Sütunlar: ${status.fields}");
        print("Çakışan değerler: ${status.conflictingKeys}, PK: ${status.primaryKey}");
        print("Hata Mesajı: ${status.message}");
      } 
      else if (status is InvalidArgumentStatus) {
        // Parametre hatalarını yönetin
        print("Dizin [$idx] Geçersiz parametre! Parametre: ${status.parameterName}, İletilen Değer: ${status.passedValue}");
      } 
      else if (status is GeneralStatus) {
        // Kilit zaman aşımı, disk dolu, sistem G/Ç sorunları vb. durumları yönetin.
        print("Dizin [$idx] Genel istisna! Kod: ${status.code} (${status.codeKey})");
        print("Mesaj: ${status.message}");
      }
    }
  }
}
```

### 5.2 Tablo Şeması ve İşlem İstisnalarını Yakalama (`DbException`)

Tablo oluşturma (`createTable`) veya şema değişiklikleri (`updateSchema`) için veya şema tanımlarının kod düzeyindeki kontrollerden geçemediği durumlarda ToStore, üretim ortamında bir `DbException` fırlatır:

```dart
try {
  // Şema güncellemeleriyle veritabanını açma
  await ToStore.open(schemas: [..]);
} on DbException catch (e) {
  print("❌ Kritik veritabanı istisnası! Birleştirilmiş hata: \n${e.message}");
  
  // İstisnadaki bağımsız durumları döngüyle dönün
  for (final status in e.statuses) {
    if (status is SchemaValidationStatus) {
      // Şema doğrulayıcı sorunları
      print("Şema doğrulaması başarısız oldu! Tablo: ${status.tableName}");
      if (status.field != null) {
        print("İhlal eden alan: ${status.field}, Geçersiz yapılandırma: ${status.wrongValue}");
      }
    } else {
      print("Teşhis: [${status.codeKey}] (Kod ${status.code}): ${status.message}");
    }
  }
}
```

### 5.3 Sorgu İşlemlerini (`QueryResult`) ve İşlem Kontrollerini (`TransactionResult`) Yönetme

- **Sorgular İçin**:
  ```dart
  final queryResult = await db.query('users').where('age', '>', 18);
  if (queryResult.hasErrors) {
    // Sorgu istisnalarını yönetin (örneğin geçersiz imleç, eksik tablo)
    print("Sorgu başarısız oldu! Kod: ${queryResult.type.code}, Mesaj: ${queryResult.message}");
  } else {
    // Sorgu başarıyla yürütüldü
    final List<Map<String, dynamic>> users = queryResult.data;
    print("${users.length} kayıt getirildi. Devamı var mı: ${queryResult.hasMore}");
  }
  ```
- **İşlemler (Transactions) İçin**:
  ```dart
  final txnResult = await db.transaction(() async {
    await db.insert('users', newUser);
  });

  if (txnResult.hasErrors) {
    print("İşlem geri alındı (rolled back)! TxId: ${txnResult.txId}");
    // Ayrıntılı alt işlem hatalarını çekin
    for (final status in txnResult.statuses) {
      if (status.type != ResultType.success) {
        print("Başarısızlık nedeni: [${status.codeKey}] ${status.message}");
      }
    }
  }
  ```

---

## 6. Tüm Yaprak Durum Kodları ve Anlamsal Belirteç Başvurusu

Tam durum yönlendirmesi ve ayrıştırması için aşağıdaki tabloya bakın:

| Durum Kodu (Code) | Belirteç (CodeKey) | Bellek İçi Enum (ResultType) | Kategori | Açıklama |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `SUCCESS` | `ResultType.success` | Başarı | İşlem başarıyla yürütüldü |
| **10000** | `BIZ_VALIDATION_FAILED` | `ResultType.bizValidationFailed` | İş Mantığı Hatası | Veri biçimi veya aralık doğrulaması başarısız oldu |
| **10001** | `BIZ_NOT_NULL_VIOLATION` | `ResultType.bizNotNullViolation` | İş Mantığı Hatası | Null olamaz kısıtı ihlali |
| **10002** | `BIZ_VALIDATION_TYPE_CAST` | `ResultType.bizTypeCastFailed` | İş Mantığı Hatası | Veri türü dönüşümü veya cast işlemi başarısız oldu |
| **11001** | `BIZ_CONSTRAINT_PRIMARY_KEY` | `ResultType.bizPrimaryKeyViolation` | İş Mantığı Hatası | Birincil anahtar çakışması (zaten mevcut) |
| **11002** | `BIZ_CONSTRAINT_UNIQUE` | `ResultType.bizUniqueViolation` | İş Mantığı Hatası | Benzersizlik kısıtı ihlali |
| **11003** | `BIZ_CONSTRAINT_FOREIGN_KEY` | `ResultType.bizForeignKeyViolation` | İş Mantığı Hatası | Yabancı anahtar kısıt ihlali (Genel) |
| **11004** | `BIZ_CONSTRAINT_CHECK` | `ResultType.bizCheckViolation` | İş Mantığı Hatası | Kontrol (check) kısıtı ihlali |
| **11005** | `BIZ_CONSTRAINT_FOREIGN_KEY_PARENT_NOT_EXIST` | `ResultType.bizForeignKeyParentNotExist` | İş Mantığı Hatası | Başvurulan üst anahtar mevcut değil |
| **11006** | `BIZ_CONSTRAINT_FOREIGN_KEY_CHILD_RESTRICT` | `ResultType.bizForeignKeyChildRestrict` | İş Mantığı Hatası | Silme/güncelleme alt kayıtlar tarafından kısıtlanmış |
| **11007** | `BIZ_CONSTRAINT_FOREIGN_KEY_COMPOSITE_MISMATCH` | `ResultType.bizForeignKeyCompositeMismatch` | İş Mantığı Hatası | Eksik bileşik yabancı anahtar değerleri |
| **11008** | `BIZ_CONSTRAINT_FOREIGN_KEY_TYPE_MISMATCH` | `ResultType.bizForeignKeyTypeMismatch` | İş Mantığı Hatası | Yabancı anahtar tür uyuşmazlığı |
| **11009** | `BIZ_CONSTRAINT_MAX_LENGTH` | `ResultType.bizValueExceedsMaxLength` | İş Mantığı Hatası | Değer uzunluğu maksimum kısıtı aşıyor |
| **11010** | `BIZ_CONSTRAINT_MIN_LENGTH` | `ResultType.bizValueLessThanMinLength` | İş Mantığı Hatası | Değer uzunluğu minimum kısıtından az |
| **11011** | `BIZ_CONSTRAINT_MIN_VALUE` | `ResultType.bizValueLessThanMinValue` | İş Mantığı Hatası | Sayısal değer minimum kısıtından az |
| **11012** | `BIZ_CONSTRAINT_MAX_VALUE` | `ResultType.bizValueExceedsMaxValue` | İş Mantığı Hatası | Sayısal değer maksimum kısıtını aşıyor |
| **12001** | `BIZ_NOT_FOUND_RECORD` | `ResultType.bizRecordNotFound` | İş Mantığı Hatası | Kaynak mevcut değil / Kayıt bulunamadı |
| **20001** | `DEV_INVALID_ARGUMENT_FORMAT` | `ResultType.devInvalidArgumentFormat` | Geliştirici Hatası | Argüman biçim hatası |
| **20002** | `DEV_INVALID_ARGUMENT_TYPE` | `ResultType.devInvalidArgumentType` | Geliştirici Hatası | Argüman türü uyuşmazlığı |
| **20003** | `DEV_INVALID_ARGUMENT_MISSING` | `ResultType.devInvalidArgumentMissing` | Geliştirici Hatası | Gerekli argüman eksik |
| **20004** | `DEV_INVALID_PRIMARY_KEY_FORMAT` | `ResultType.devInvalidPrimaryKeyFormat` | Geliştirici Hatası | Geçersiz birincil anahtar biçimi |
| **20005** | `DEV_INDEX_OUT_OF_BOUNDS` | `ResultType.devIndexOutOfBounds` | Geliştirici Hatası | Dizin veya aralık sınırların dışında |
| **20006** | `DEV_UNSUPPORTED_OPERATION` | `ResultType.devUnsupportedOperation` | Geliştirici Hatası | İşlem mevcut bağlamda desteklenmiyor |
| **20007** | `DEV_VECTOR_DIMENSION_MISMATCH` | `ResultType.devVectorDimensionMismatch` | Geliştirici Hatası | Vektör boyutları uyuşmuyor |
| **20008** | `DEV_INDEX_FIELD_MISSING` | `ResultType.devIndexFieldMissing` | Geliştirici Hatası | İmleç için kayıtta gerekli dizin alanı eksik |
| **20101** | `DEV_INVALID_CURSOR_PAGINATION` | `ResultType.devInvalidCursorPagination` | Geliştirici Hatası | İmleç sayfalama ve ofset birbirini dışlar |
| **20102** | `DEV_INVALID_CURSOR_TABLE` | `ResultType.devInvalidCursorTable` | Geliştirici Hatası | İmleç hedef tabloyla eşleşmiyor |
| **20103** | `DEV_INVALID_CURSOR_SIGNATURE` | `ResultType.devInvalidCursorSignature` | Geliştirici Hatası | Uyuşmayan imleç imzası (tahrif edilmiş) |
| **20104** | `DEV_INVALID_CURSOR_ORDERBY` | `ResultType.devInvalidCursorOrderBy` | Geliştirici Hatası | İmleç orderBy yapılandırması geçersiz veya uyuşmuyor |
| **20105** | `DEV_INVALID_CURSOR_MODE` | `ResultType.devInvalidCursorMode` | Geliştirici Hatası | İmleç belirteç modu uyuşmazlığı |
| **20106** | `DEV_INVALID_CURSOR_PAYLOAD` | `ResultType.devInvalidCursorPayload` | Geliştirici Hatası | Geçersiz imleç yükü (kod çözülemez) |
| **20201** | `DEV_INVALID_QUERY_SELECT_FIELD` | `ResultType.devInvalidQuerySelectField` | Geliştirici Hatası | Sorgu seçme alanı String veya QueryAggregation olmalıdır |
| **20202** | `DEV_INVALID_QUERY_FOREIGN_KEY_JOIN` | `ResultType.devInvalidQueryForeignKeyJoin` | Geliştirici Hatası | Otomatik birleştirme için yabancı anahtar ilişkisi yok |
| **20203** | `DEV_INVALID_QUERY_FIELD_ALIAS` | `ResultType.devInvalidQueryFieldAlias` | Geliştirici Hatası | Sorgu alanı takma adı biçimi geçersiz |
| **20204** | `DEV_INVALID_EXPRESSION` | `ResultType.devInvalidExpression` | Geliştirici Hatası | Geçersiz ifade yapılandırması veya yürütme istisnası |
| **22001** | `DEV_NOT_FOUND_TABLE` | `ResultType.devTableNotFound` | Geliştirici Hatası | Tablo bulunamadı |
| **22002** | `DEV_NOT_FOUND_INDEX` | `ResultType.devIndexNotFound` | Geliştirici Hatası | Dizin bulunamadı |
| **22003** | `DEV_NOT_FOUND_SPACE` | `ResultType.devSpaceNotFound` | Geliştirici Hatası | Alan bulunamadı |
| **22004** | `DEV_NOT_FOUND_FIELD` | `ResultType.devFieldNotFound` | Geliştirici Hatası | Alan bulunamadı |
| **23001** | `DEV_LARGE_SCALE_OPERATION_REQUIRED` | `ResultType.devLargeScaleOperationRequired` | Geliştirici Hatası | Large-scale data operation requires `allowLargeScaleOperation()` to prevent OOM |
| **23002** | `DEV_LARGE_SCALE_OPERATION_NOT_ALLOWED_IN_TRANSACTION` | `ResultType.devLargeScaleOperationNotAllowedInTransaction` | Developer Error | Large-scale data operation is not allowed inside a transaction |
| **24001** | `DEV_ENGINE_INCOMPATIBLE` | `ResultType.devEngineIncompatible` | Geliştirici Hatası | **Kritik**: Motor sürümü uyumsuz |
| **30000** | `DEV_INVALID_SCHEMA` | `ResultType.devInvalidSchema` | Geliştirici Hatası | Geçersiz tablo şeması tanımı |
| **30001** | `DEV_INVALID_SCHEMA_TABLE_NAME` | `ResultType.devInvalidSchemaTableName` | Geliştirici Hatası | Tablo adı doğrulaması başarısız |
| **30002** | `DEV_INVALID_SCHEMA_FIELD_NAME` | `ResultType.devInvalidSchemaFieldName` | Geliştirici Hatası | Alan adı doğrulaması başarısız |
| **30003** | `DEV_INVALID_SCHEMA_DUPLICATE_FIELD_NAME` | `ResultType.devInvalidSchemaDuplicateFieldName` | Geliştirici Hatası | Tablo şemasında yinelenen alan adı |
| **30004** | `DEV_INVALID_SCHEMA_PRIMARY_KEY` | `ResultType.devInvalidSchemaPrimaryKey` | Geliştirici Hatası | Birincil anahtar doğrulaması başarısız |
| **30005** | `DEV_INVALID_SCHEMA_INDEX_LIMIT` | `ResultType.devInvalidSchemaIndexLimit` | Geliştirici Hatası | Dizin sayısı doğrulaması başarısız |
| **30006** | `DEV_INVALID_SCHEMA_INDEX_FIELD` | `ResultType.devInvalidSchemaIndexField` | Geliştirici Hatası | Dizin mevcut olmayan bir alana başvuruyor |
| **30007** | `DEV_INVALID_SCHEMA_INDEX_TYPE` | `ResultType.devInvalidSchemaIndexType` | Geliştirici Hatası | Dizin türü alan veri türü veya yapılandırmasıyla uyumsuz |
| **30008** | `DEV_INVALID_SCHEMA_FOREIGN_KEY` | `ResultType.devInvalidSchemaForeignKey` | Geliştirici Hatası | Yabancı anahtar tanımı geçersiz |
| **30009** | `DEV_INVALID_SCHEMA_SPACE_MISMATCH` | `ResultType.devInvalidSchemaSpaceMismatch` | Geliştirici Hatası | Küresel/Alana özgü sınır uyuşmazlığı |
| **30010** | `DEV_INVALID_SCHEMA_TTL_CONFIG` | `ResultType.devInvalidSchemaTtlConfig` | Geliştirici Hatası | TTL yapılandırma doğrulaması başarısız oldu |
| **30011** | `DEV_SCHEMA_TABLE_EXISTS` | `ResultType.devSchemaTableExists` | Geliştirici Hatası | Tablo zaten mevcut |
| **30012** | `DEV_SCHEMA_FIELD_EXISTS` | `ResultType.devSchemaFieldExists` | Geliştirici Hatası | Alan zaten mevcut |
| **30013** | `DEV_SCHEMA_INDEX_EXISTS` | `ResultType.devSchemaIndexExists` | Geliştirici Hatası | Dizin zaten mevcut |
| **31001** | `DEV_MIGRATION_NOT_ALLOWED_WITH_DATA` | `ResultType.devMigrationNotAllowedWithData` | Geliştirici Hatası | Geçiş veri değişikliği gerektiriyor ancak açıkça izin verilmemiş |
| **31002** | `DEV_MIGRATION_UNSAFE_TYPE_CONVERSION` | `ResultType.devMigrationUnsafeTypeConversion` | Geliştirici Hatası | Alan için desteklenmeyen veri türü değişikliği |
| **31003** | `DEV_MIGRATION_CANNOT_ADD_NON_NULL_FIELD` | `ResultType.devMigrationCannotAddNonNullField` | Geliştirici Hatası | Varsayılan değer olmadan null olamaz alan eklenmesine izin verilmez |
| **31004** | `DEV_MIGRATION_NULLABLE_TO_NON_NULL_NOT_ALLOWED` | `ResultType.devMigrationNullableToNonNullNotAllowed` | Geliştirici Hatası | Alanın null olabilir durumdan null olamaz duruma getirilmesine izin verilmez |
| **31005** | `DEV_MIGRATION_UNIQUE_TIGHTENING_NOT_ALLOWED` | `ResultType.devMigrationUniqueTighteningNotAllowed` | Geliştirici Hatası | UNIQUE olarak sıkılaştırmaya izin verilmez |
| **31006** | `DEV_MIGRATION_PROMOTE_LARGE_OP_NOT_ALLOWED` | `ResultType.devMigrationPromoteLargeOpNotAllowed` | Geliştirici Hatası | promoteFieldToPrimaryKey sırasında büyük ölçekli işlemler engellenir |
| **50001** | `SYS_TRANSACTION_ABORTED` | `ResultType.sysTransactionAborted` | Sistem Hatası | İşlem iptal edildi |
| **50002** | `SYS_TRANSACTION_CONFLICT` | `ResultType.sysTransactionConflict` | Sistem Hatası | İşlem çakışması |
| **50003** | `SYS_TRANSACTION_LIMIT_EXCEEDED` | `ResultType.sysTransactionLimitExceeded` | Sistem Hatası | İşlem, bellek baskısı altında güvenli bellek sınırını aşıyor |
| **50004** | `SYS_MIGRATION_BATCH_EXECUTION_FAILED` | `ResultType.sysMigrationBatchExecutionFailed` | Sistem Hatası | **Kritik**: Toplu geçiş yürütmesi başarısız oldu |
| **51001** | `SYS_TIMEOUT_LOCK_ACQUISITION` | `ResultType.sysTimeoutLockAcquisition` | Sistem Hatası | Kilit alma zaman aşımı |
| **51002** | `SYS_TIMEOUT` | `ResultType.sysTimeout` | Sistem Hatası | İşlem zaman aşımı |
| **51003** | `SYS_DB_CLOSED` | `ResultType.sysDbClosed` | Sistem Hatası | Veritabanı kapalı, işlem güvenli bir şekilde iptal edildi |
| **52001** | `SYS_RESOURCE_EXHAUSTED_MEMORY` | `ResultType.sysResourceExhaustedMemory` | Sistem Hatası | **Kritik**: Bellek kaynağı tükendi |
| **52002** | `SYS_RESOURCE_EXHAUSTED` | `ResultType.sysResourceExhausted` | Sistem Hatası | **Kritik**: Sistem kaynakları tükendi |
| **53001** | `SYS_IO_NOT_FOUND` | `ResultType.sysIoNotFound` | Sistem Hatası | Fiziksel dosya veya yol mevcut değil |
| **53002** | `SYS_IO_PERMISSION_DENIED` | `ResultType.sysIoPermissionDenied` | Sistem Hatası | Dosya erişimi için izin reddedildi |
| **53003** | `SYS_IO_DISK_FULL` | `ResultType.sysIoDiskFull` | Sistem Hatası | **Kritik**: Disk dolu veya depolama kotası aşıldı |
| **53004** | `SYS_IO_FILE_LOCKED` | `ResultType.sysIoFileLocked` | Sistem Hatası | Dosya kilitli veya başka bir işlem tarafından kullanılıyor |
| **53005** | `SYS_IO_DEVICE_FAULT` | `ResultType.sysIoDeviceFault` | Sistem Hatası | **Kritik**: Depolama aygıtı veya ortam hatası |
| **53006** | `SYS_IO_WEB_STORAGE_UNAVAILABLE` | `ResultType.sysIoWebStorageUnavailable` | Sistem Hatası | Web IndexedDB veya depolama alanı kullanılamıyor |
| **53007** | `SYS_BACKUP_CORRUPTED` | `ResultType.sysBackupCorrupted` | Sistem Hatası | Yedekleme paketi bozuk veya meta verileri eksik |
| **53008** | `SYS_IO_DATA_CORRUPTED` | `ResultType.sysIoDataCorrupted` | Sistem Hatası | **Kritik**: Veritabanı veri dosyası bozuk veya sağlama toplamı başarısız |
| **53009** | `SYS_INVALID_DATA_FORMAT` | `ResultType.sysInvalidDataFormat` | Sistem Hatası | Veri akışı biçimlendirmesi veya ayrıştırılması başarısız oldu |
| **53099** | `SYS_IO_GENERIC` | `ResultType.sysIoGeneric` | Sistem Hatası | Genel sistem G/Ç hatası |
| **99001** | `ENG_ERROR` | `ResultType.engError` | Motor Hatası | Motor hatası |
