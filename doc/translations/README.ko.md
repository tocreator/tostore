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
  한국어 | 
  <a href="README.es.md">Español</a> | 
  <a href="README.pt-BR.md">Português (Brasil)</a> | 
  <a href="README.ru.md">Русский</a> | 
  <a href="README.de.md">Deutsch</a> | 
  <a href="README.fr.md">Français</a> | 
  <a href="README.it.md">Italiano</a> | 
  <a href="README.tr.md">Türkçe</a>
</p>

## 빠른 탐색
- **시작하기**: [ToStore를 선택해야 하는 이유](#why-tostore) | [주요 기능](#key-features) | [설치 안내](#installation) | [KV 모드](#quick-start-kv) | [테이블 모드](#quick-start-table) | [메모리 모드](#quick-start-memory)
- **아키텍처 및 모델**: [스키마 정의](#schema-definition) | [분산 아키텍처](#distributed-architecture) | [계단식 외래 키](#foreign-keys) | [모바일/데스크톱](#mobile-integration) | [서버/에이전트](#server-integration) | [기본 키 알고리즘](#primary-key-examples)
- **고급 쿼리**: [고급 쿼리(JOIN)](#query-advanced) | [집계 및 통계](#aggregation-stats) | [복잡한 논리(쿼리조건)](#query-condition) | [반응형 쿼리(보기)](#reactive-query) | [스트리밍 쿼리](#streaming-query)
- **고급 및 성능**: [벡터 검색](#vector-advanced) | [테이블 수준 TTL](#ttl-config) | [효율적인 페이지 매김](#query-pagination) | [쿼리 캐시](#query-cache) | [원자 표현](#atomic-expressions) | [거래](#transactions)
- **운영 및 보안**: [관리](#database-maintenance) | [보안설정](#security-config) | [오류 처리](#error-handling) | [성능 및 진단](#performance) | [추가 자료](#more-resources)

## <a id="why-tostore"></a>왜 ToStore를 선택해야 할까요?

ToStore는 AGI 시대와 엣지 인텔리전스 시나리오를 위해 설계된 최신 데이터 엔진입니다. 기본적으로 분산 시스템, 다중 모드 융합, 관계형 구조 데이터, 고차원 벡터 및 구조화되지 않은 데이터 스토리지를 지원합니다. 자체 라우팅 노드 아키텍처와 신경망에서 영감을 받은 엔진을 기반으로 구축된 이 솔루션은 노드에 높은 자율성과 탄력적인 수평 확장성을 제공하는 동시에 데이터 규모에서 성능을 논리적으로 분리합니다. 여기에는 ACID 트랜잭션, 복잡한 관계형 쿼리(JOIN 및 계단식 외래 키), 테이블 수준 TTL 및 집계가 포함되며, 다중 분산 기본 키 알고리즘, 원자 표현식, 스키마 변경 인식, 암호화, 다중 공간 데이터 격리, 리소스 인식 지능형 로드 스케줄링, 재해/충돌 자가 치유 복구도 포함됩니다.

컴퓨팅이 엣지 인텔리전스로 계속 전환함에 따라 에이전트, 센서 및 기타 장치는 더 이상 단순한 "콘텐츠 디스플레이"가 아닙니다. 이는 지역 생성, 환경 인식, 실시간 의사 결정 및 조정된 데이터 흐름을 담당하는 지능형 노드입니다. 기존 데이터베이스 솔루션은 기본 아키텍처와 결합된 확장으로 인해 제한되어 있어 높은 동시성 쓰기, 대규모 데이터 세트, 벡터 검색 및 협업 생성에서 엣지 클라우드 지능형 애플리케이션의 낮은 대기 시간 및 안정성 요구 사항을 충족하기가 점점 더 어려워지고 있습니다.

ToStore는 대규모 데이터 세트, 복잡한 로컬 AI 생성 및 대규모 데이터 이동에 충분히 강력한 엣지 분산 기능을 제공합니다. 엣지 노드와 클라우드 노드 간의 심층적인 지능형 협업은 몰입형 혼합 현실, 다중 모드 상호 작용, 의미 체계 벡터, 공간 모델링 및 유사한 시나리오를 위한 안정적인 데이터 기반을 제공합니다.

## <a id="key-features"></a>주요 기능

- 🌐 **통합 크로스 플랫폼 데이터 엔진**
  - 모바일, 데스크톱, 웹, 서버 환경 전반에 걸친 통합 API
  - 관계형 정형 데이터, 고차원 벡터, 비정형 데이터 저장 지원
  - 로컬 스토리지부터 엣지-클라우드 협업까지 데이터 파이프라인 구축

- 🧠 **신경망 스타일 분산 아키텍처**
  - 규모에서 물리적 주소 지정을 분리하는 자체 라우팅 노드 아키텍처
  - 고도로 자율적인 노드가 협력하여 유연한 데이터 토폴로지를 구축합니다.
  - 노드 협력 및 탄력적인 수평 확장 지원
  - 엣지 인텔리전트 노드와 클라우드 간의 깊은 상호 연결

- ⚡ **병렬 실행 및 리소스 예약**
  - 고가용성을 갖춘 리소스 인식 지능형 로드 스케줄링
  - 다중 노드 병렬 협업 및 작업 분해
  - 타임 슬라이싱은 부하가 심한 경우에도 UI 애니메이션을 부드럽게 유지합니다.

- 🔍 **구조적 쿼리 및 벡터 검색**
  - 복잡한 조건자, JOIN, 집계 및 테이블 수준 TTL을 지원합니다.
  - 벡터 필드, 벡터 인덱스 및 최근접 이웃 검색 지원
  - 구조화된 데이터와 벡터 데이터는 동일한 엔진 내에서 함께 작동할 수 있습니다.

- 🔑 **기본 키, 인덱스 및 스키마 진화**
  - 순차, 타임스탬프, 날짜 접두사 및 단축 코드 전략을 포함한 기본 키 알고리즘 내장
  - 고유 인덱스, 복합 인덱스, 벡터 인덱스, 외래 키 제약 조건 지원
  - 스키마 변경을 자동으로 감지하고 마이그레이션 작업을 완료합니다.

- 🛡️ **거래, 보안 및 복구**
  - ACID 트랜잭션, 원자 표현식 업데이트 및 계단식 외래 키 제공
  - 충돌 복구, 내구성 있는 커밋 및 일관성 보장을 지원합니다.
  - ChaCha20-Poly1305 및 AES-256-GCM 암호화 지원

- 🔄 **다중 공간 및 데이터 워크플로우**
  - 선택적으로 전역적으로 공유되는 데이터로 격리된 공간을 지원합니다.
  - 실시간 쿼리 리스너, 다단계 지능형 캐싱 및 커서 페이지 매김 지원
  - 다중 사용자, 로컬 우선, 오프라인 협업 애플리케이션에 적합

## <a id="installation"></a>설치

> [!IMPORTANT]
> **v2.x에서 업그레이드하시겠습니까?** 중요한 마이그레이션 단계 및 주요 변경 사항에 대해서는 [v3.x 업그레이드 가이드](../UPGRADE_GUIDE_v3.md)를 읽어보세요.

`pubspec.yaml`에 `tostore`을 추가하세요.

```yaml
dependencies:
  tostore: any # Please use the latest version
```

## <a id="quick-start"></a>빠른 시작

> [!TIP]
> **저장 모드를 어떻게 선택해야 합니까?**
> 1. [**키-값 모드(KV)**](#quick-start-kv): 구성 액세스, 분산 상태 관리 또는 JSON 데이터 저장에 가장 적합합니다. 시작하는 가장 빠른 방법입니다.
> 2. [**구조화된 테이블 모드**](#quick-start-table): 복잡한 쿼리, 제약 조건 확인 또는 대규모 데이터 거버넌스가 필요한 핵심 비즈니스 데이터에 가장 적합합니다. 무결성 로직을 엔진에 적용하면 애플리케이션 계층 개발 및 유지 관리 비용을 크게 줄일 수 있습니다.
> 3. [**메모리 모드**](#quick-start-memory): 임시 계산, 단위 테스트 또는 **초고속 전역 상태 관리**에 가장 적합합니다. 글로벌 쿼리와 `watch` 리스너를 사용하면 수많은 글로벌 변수를 유지하지 않고도 애플리케이션 상호 작용을 재구성할 수 있습니다.

### <a id="quick-start-kv"></a>키-값 저장소(KV)
이 모드는 사전 정의된 구조화된 테이블이 필요하지 않은 경우에 적합합니다. 간단하고 실용적이며 고성능 스토리지 엔진이 지원됩니다. **효율적인 인덱싱 아키텍처는 매우 큰 데이터 규모의 일반 모바일 장치에서도 쿼리 성능을 매우 안정적으로 유지하고 응답성이 뛰어납니다.** 서로 다른 공간의 데이터는 자연스럽게 격리되는 동시에 글로벌 공유도 지원됩니다.

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

#### Flutter UI 자동 새로고침 예시
Flutter에서 `StreamBuilder`과 `watchValue`은 매우 간결한 반응형 새로 고침 흐름을 제공합니다.

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

### <a id="quick-start-table"></a>구조화된 테이블 모드
구조화된 테이블의 CRUD를 사용하려면 스키마를 미리 생성해야 합니다([스키마 정의](#schema-definition) 참조). 다양한 시나리오에 권장되는 통합 접근 방식:
- **모바일/데스크톱**: [자주 시작하는 시나리오](#mobile-integration)의 경우 초기화 시 `schemas`을 전달하는 것이 좋습니다.
- **서버/에이전트**: [장기 실행 시나리오](#server-integration)의 경우 `createTables`을 통해 동적으로 테이블을 생성하는 것이 좋습니다.

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

### <a id="quick-start-memory"></a>메모리 모드

캐싱, 임시 계산 또는 디스크에 대한 지속성이 필요하지 않은 작업 부하와 같은 시나리오의 경우 `ToStore.memory()`을 통해 순수 메모리 내 데이터베이스를 초기화할 수 있습니다. 이 모드에서는 스키마, 인덱스, 키-값 쌍을 포함한 모든 데이터가 최대 읽기/쓰기 성능을 위해 메모리에 완전히 저장됩니다.

#### 💡 전역 상태 관리로도 작동
전역 변수 더미나 무거운 상태 관리 프레임워크가 필요하지 않습니다. 메모리 모드를 `watchValue` 또는 `watch()`과 결합하면 위젯과 페이지 전체에서 완전 자동 UI 새로 고침을 달성할 수 있습니다. 데이터베이스의 강력한 검색 기능을 유지하면서 일반 변수를 훨씬 뛰어넘는 반응형 경험을 제공하므로 로그인 상태, 실시간 구성 또는 글로벌 메시지 카운터에 이상적입니다.

> [!CAUTION]
> **참고**: 순수 메모리 모드에서 생성된 데이터는 앱을 닫거나 다시 시작하면 완전히 손실됩니다. 핵심 비즈니스 데이터에는 사용하지 마세요.

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


## <a id="schema-definition"></a>스키마 정의
**한 번 정의하면 엔진이 엔드투엔드 자동화 거버넌스를 처리하게 되므로 애플리케이션이 더 이상 과도한 검증 유지 관리를 수행하지 않아도 됩니다.**

다음 모바일, 서버 측 및 에이전트 예제는 모두 여기에 정의된 `appSchemas`을 재사용합니다.


### 테이블스키마 개요

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

- **공통 `DataType` 매핑**:
  | 유형 | 해당 다트 유형 | 설명 |
  | :--- | :--- | :--- |
| `integer` | `int` | ID, 카운터 및 유사한 데이터에 적합한 표준 정수 |
  | `bigInt` | `BigInt` / `String` | 큰 정수; 정밀도 손실을 방지하기 위해 숫자가 18자리를 초과하는 경우 권장됨 |
  | `double` | `double` | 가격, 좌표 및 유사한 데이터에 적합한 부동 소수점 숫자 |
  | `text` | `String` | 선택적 길이 제약 조건이 있는 텍스트 문자열 |
  | `blob` | `Uint8List` | 원시 바이너리 데이터 |
  | `boolean` | `bool` | 부울 값 |
  | `datetime` | `DateTime` / `String` | 날짜/시간 내부적으로 ISO8601로 저장됨 |
  | `array` | `List` | 목록 또는 배열 유형 |
  | `json` | `Map<String, dynamic>` | 동적 구조화된 데이터에 적합한 JSON 객체 |
  | `vector` | `VectorData` / `List<num>` | AI 의미 검색을 위한 고차원 벡터 데이터(임베딩) |

- **`PrimaryKeyType` 자동 생성 전략**:
  | 전략 | 설명 | 특징 |
  | :--- | :--- | :--- |
| `none` | 자동 생성 없음 | 삽입 중에 기본 키를 수동으로 제공해야 합니다 |
  | `sequential` | 순차적 증가 | 인간 친화적인 ID에는 적합하지만 분산 성능에는 적합하지 않음 |
  | `timestampBased` | 타임스탬프 기반 | 분산 환경에 권장 |
  | `datePrefixed` | 날짜 접두어 | 비즈니스에 날짜 가독성이 중요한 경우에 유용합니다 |
  | `shortCode` | 단축 코드 기본 키 | 컴팩트하고 외부 디스플레이에 적합 |

> 모든 기본 키는 기본적으로 `text`(`String`)으로 저장됩니다.


### 제약 조건 및 자동 유효성 검사

애플리케이션 코드에서 중복된 논리를 피하면서 공통 유효성 검사 규칙을 `FieldSchema`에 직접 작성할 수 있습니다.

- `nullable: false`: null이 아닌 제약 조건
- `minLength` / `maxLength`: 텍스트 길이 제한
- `minValue` / `maxValue`: 정수 또는 부동 소수점 범위 제약 조건
- `defaultValue` / `defaultValueType`: 정적 기본값 및 동적 기본값
- `unique`: 고유 제약 조건
- `createIndex`: 고주파 필터링, 정렬 또는 관계를 위한 인덱스 생성
- `fieldId` / `tableId`: 마이그레이션 중 필드 및 테이블에 대한 이름 변경 감지 지원

또한 `unique: true`은 단일 필드 고유 인덱스를 자동으로 생성합니다. `createIndex: true` 및 외래 키는 자동으로 단일 필드 일반 인덱스를 생성합니다. 복합 인덱스, 명명된 인덱스 또는 벡터 인덱스가 필요한 경우 `indexes`을 사용하세요.


### 통합 방법 선택

- **모바일/데스크톱**: `appSchemas`을 `ToStore.open(...)`에 직접 전달할 때 가장 좋습니다.
- **서버/에이전트**: `createTables(appSchemas)`을 통해 런타임에 스키마를 동적으로 생성할 때 가장 적합합니다.


## <a id="mobile-integration"></a>모바일, 데스크탑 및 기타 빈번한 시작 시나리오를 위한 통합

📱 **예**: [mobile_quickstart.dart](../../example/lib/mobile_quickstart.dart)

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

### 스키마 진화

`ToStore.open()` 중에 엔진은 인덱스 변경은 물론 테이블과 필드 추가, 제거, 이름 바꾸기, 변경 등 `schemas`의 구조적 변경 사항을 자동으로 감지한 다음 필요한 마이그레이션 작업을 완료합니다. 데이터베이스 버전 번호를 수동으로 유지 관리하거나 마이그레이션 스크립트를 작성할 필요가 없습니다.


### 로그인 상태 유지 및 로그아웃(활성 공간)

다중 공간은 **사용자 데이터 격리**에 이상적입니다. 사용자당 하나의 공간, 로그인이 활성화되어 있습니다. **Active Space** 및 닫기 옵션을 사용하면 앱을 다시 시작해도 현재 사용자를 유지하고 깔끔한 로그아웃 동작을 지원할 수 있습니다.

- **로그인 상태 유지**: 사용자를 자신의 공간으로 전환한 후 해당 공간을 활성 상태로 표시합니다. 다음 실행에서는 "기본값을 먼저 사용한 후 전환" 단계 없이 기본 인스턴스를 열 때 해당 공간에 직접 들어갈 수 있습니다.
- **로그아웃**: 사용자가 로그아웃하면 `keepActiveSpace: false`으로 데이터베이스를 닫습니다. 다음 실행 시 이전 사용자의 공간에 자동으로 들어가지 않습니다.

```dart
// After login: switch to the user's space and mark it active
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// Optional: strictly stay in default when needed (for example, login screen only)
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// On logout: close and clear the active space so the next launch starts from default
await db.close(keepActiveSpace: false);
```


## <a id="server-integration"></a>서버측/에이전트 통합(장기 실행 시나리오)

🖥️ **예**: [server_quickstart.dart](../../example/lib/server_quickstart.dart)

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


## <a id="advanced-usage"></a>고급 사용법

ToStore는 복잡한 비즈니스 시나리오를 위한 풍부한 고급 기능 세트를 제공합니다.


### <a id="vector-advanced"></a>벡터 필드, 벡터 인덱스 및 벡터 검색

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

매개변수 참고 사항:

- `dimensions`: 작성하는 실제 임베딩 너비와 일치해야 합니다.
- `precision`: 일반적인 선택에는 `float64`, `float32` 및 `int8`이 포함됩니다. 정밀도가 높을수록 일반적으로 더 많은 저장 공간이 필요합니다.
- `distanceMetric`: `cosine`은 의미론적 임베딩에 일반적이고, `l2`은 유클리드 거리에 적합하고, `innerProduct`은 내적 검색에 적합합니다.
- `maxDegree`: NGH 그래프에서 노드당 유지되는 이웃의 상한; 값이 높을수록 일반적으로 더 많은 메모리와 빌드 시간이 필요하지만 재현율이 향상됩니다.
- `efSearch`: 검색 시간 확장 폭; 늘리면 일반적으로 회상이 향상되지만 대기 시간이 늘어납니다.
- `constructionEf`: 빌드 시 확장 너비; 늘리면 일반적으로 인덱스 품질이 향상되지만 빌드 시간이 늘어납니다.
- `topK`: 반환할 결과 개수

결과 참고 사항:

- `score`: 정규화된 유사성 점수(일반적으로 `0 ~ 1` 범위) 클수록 더 비슷하다는 뜻
- `distance`: 거리 값; `l2` 및 `cosine`의 경우 일반적으로 작을수록 더 유사함을 의미합니다.

### <a id="ttl-config"></a>테이블 수준 TTL(자동 시간 기반 만료)

시간이 지남에 따라 만료되어야 하는 로그, 원격 분석, 이벤트 및 기타 데이터의 경우 `ttlConfig`을 통해 테이블 ​​수준 TTL을 정의할 수 있습니다. 엔진은 백그라운드에서 만료된 레코드를 자동으로 정리합니다.

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


### 지능형 스토리지(Upsert)
ToStore에서는 `data`에 포함된 기본 키 또는 고유 키를 기준으로 업데이트할지 삽입할지 결정합니다. `where`은 여기서 지원되지 않습니다. 충돌 대상은 데이터 자체에 의해 결정됩니다.

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


### <a id="query-advanced"></a>고급 쿼리

ToStore는 유연한 필드 처리 및 복잡한 다중 테이블 관계를 갖춘 선언적 연결 가능 쿼리 API를 제공합니다.

#### 1. 필드 선택(`select`)
`select` 메서드는 반환되는 필드를 지정합니다. 호출하지 않으면 기본적으로 모든 필드가 반환됩니다.
- **별칭**: 결과 집합의 키 이름을 바꾸기 위해 `field as alias` 구문(대소문자 구분 안 함) 지원
- **테이블 한정 필드**: 다중 테이블 조인에서 `table.field`은 이름 충돌을 방지합니다.
- **집계 혼합**: `Agg` 개체를 `select` 목록 내부에 직접 배치할 수 있습니다.

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

#### 2. 가입(`join`)
표준 `join`(내부 조인), `leftJoin` 및 `rightJoin`을 지원합니다.

#### 3. 스마트 외래 키 기반 조인(권장)
`foreignKeys`이 `TableSchema`에 올바르게 정의되어 있으면 조인 조건을 직접 작성할 필요가 없습니다. 엔진은 참조 관계를 분석하고 최적의 JOIN 경로를 자동으로 생성할 수 있습니다.

- **`joinReferencedTable(tableName)`**: 현재 테이블이 참조하는 상위 테이블을 자동으로 조인합니다.
- **`joinReferencingTable(tableName)`**: 현재 테이블을 참조하는 하위 테이블을 자동으로 조인합니다.

```dart
// Assume posts defines a foreign key to users
final posts = await db.query('posts')
    .joinReferencedTable('users') // Automatically resolves to ON posts.user_id = users.id
    .select(['posts.title', 'users.username'])
    .limit(20);
```

---

### <a id="aggregation-stats"></a>집계, 그룹화 및 통계(Agg 및 GroupBy)

#### 1. 집계(`Agg` 공장)
집계 함수는 데이터 세트에 대한 통계를 계산합니다. `alias` 매개변수를 사용하면 결과 필드 이름을 사용자 정의할 수 있습니다.

| 방법 | 목적 | 예 |
| :--- | :--- | :--- |
| `Agg.count(field)` | Null이 아닌 레코드 수 계산 | `Agg.count('id', alias: 'total')` |
| `Agg.sum(field)` | 합계 값 | `Agg.sum('amount', alias: 'total_price')` |
| `Agg.avg(field)` | 평균값 | `Agg.avg('score', alias: 'average_score')` |
| `Agg.max(field)` | 최대값 | `Agg.max('age')` |
| `Agg.min(field)` | 최소값 | `Agg.min('price')` |

> [!TIP]
> **두 가지 일반적인 집계 스타일**
> 1. **단축 방법(단일 측정항목에 권장)**: 체인에서 직접 호출하고 계산된 값을 즉시 다시 가져옵니다.
> `num? totalAge = await db.query('users').sum('age');`
> 2. **`select`에 포함됨(여러 측정항목 또는 그룹화용)**: `Agg` 개체를 `select` 목록에 전달합니다.
> `final stats = await db.query('orders').select(['status', Agg.sum('amount')]).groupBy(['status']);`

#### 2. 그룹화 및 필터링(`groupBy` / `having`)
SQL의 HAVING 동작과 유사하게 `groupBy`을 사용하여 레코드를 분류한 다음 `having`을 사용하여 집계된 결과를 필터링합니다.

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

#### 3. 도우미 쿼리 방법
- **`exists()`(고성능)**: 일치하는 레코드가 있는지 확인합니다. `count() > 0`과 달리 하나의 일치 항목이 발견되자마자 단락되므로 매우 큰 데이터 세트에 적합합니다.
- **`count()`**: 일치하는 레코드 수를 효율적으로 반환합니다.
- **`first()`**: `limit(1)`과 동일하고 첫 번째 행을 `Map`으로 직접 반환하는 편의 메서드입니다.
- **`distinct([fields])`**: 결과를 중복 제거합니다. `fields`이 제공되면 해당 필드를 기반으로 고유성이 계산됩니다.

```dart
// Efficient existence check
if (await db.query('users').whereEqual('email', 'test@test.com').exists()) {
  print('Email is already registered');
}

// Get a deduplicated city list
final cities = await db.query('users').distinct(['city']);
```

#### <a id="query-condition"></a>4. `QueryCondition`을 사용한 복잡한 논리
`QueryCondition`은 중첩 논리 및 괄호로 묶인 쿼리 구성을 위한 ToStore의 핵심 도구입니다. 단순한 연결 `where` 호출로는 `(A AND B) OR (C AND D)`과 같은 표현이 충분하지 않을 때 사용할 수 있는 도구입니다.

- **`condition(QueryCondition sub)`**: `AND` 중첩된 그룹을 엽니다.
- **`orCondition(QueryCondition sub)`**: `OR` 중첩된 그룹을 엽니다.
- **`or()`**: 다음 커넥터를 `OR`으로 변경합니다(기본값은 `AND`).

##### 예 1: 혼합 OR 조건
동등한 SQL: `WHERE is_active = true AND (role = 'admin' OR fans >= 1000)`

```dart
final subGroup = QueryCondition()
    .whereEqual('role', 'admin')
    .or()
    .whereGreaterThanOrEqualTo('fans', 1000);

final results = await db.query('users')
    .whereEqual('is_active', true)
    .condition(subGroup);
```

##### 예시 2: 재사용 가능한 조건 조각
재사용 가능한 비즈니스 논리 조각을 한 번 정의하고 이를 다른 쿼리로 결합할 수 있습니다.

```dart
final hotUser = QueryCondition().whereGreaterThan('fans', 5000);
final recentLogin = QueryCondition().whereGreaterThan('last_login', '2024-01-01');

final targetUsers = await db.query('users')
    .condition(hotUser)
    .condition(recentLogin);
```


#### <a id="streaming-query"></a>5. 스트리밍 쿼리
모든 것을 한 번에 메모리에 로드하고 싶지 않은 매우 큰 데이터 세트에 적합합니다. 결과를 읽으면서 처리할 수 있습니다.

```dart
db.streamQuery('users').listen((data) {
  print('Processing one record: $data');
});
```

#### <a id="reactive-query"></a>6. 반응형 쿼리
`watch()` 메서드를 사용하면 쿼리 결과를 실시간으로 모니터링할 수 있습니다. `Stream`을 반환하고 대상 테이블에서 일치하는 데이터가 변경될 때마다 자동으로 쿼리를 다시 실행합니다.
- **자동 디바운스**: 내장된 지능형 디바운싱으로 중복된 쿼리 급증을 방지합니다.
- **UI 동기화**: 실시간 업데이트 목록을 위해 Flutter `StreamBuilder`와 자연스럽게 작동합니다.

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

### <a id="query-cache"></a>수동 쿼리 결과 캐싱(선택 사항)

> [!IMPORTANT]
> **ToStore에는 이미 내부적으로 효율적인 다단계 지능형 LRU 캐시가 포함되어 있습니다.**
> **일상적인 수동 캐시 관리는 권장되지 않습니다.** 특별한 경우에만 고려하십시오.
> 1. 거의 변경되지 않는 인덱싱되지 않은 데이터에 대한 비용이 많이 드는 전체 검색
> 2. 핫 쿼리가 아닌 경우에도 지속적인 초저 지연 요구 사항

- `useQueryCache([Duration? expiry])`: 캐시를 활성화하고 선택적으로 만료를 설정합니다.
- `noQueryCache()`: 이 쿼리에 대한 캐시를 명시적으로 비활성화합니다.
- `clearQueryCache()`: 이 쿼리 패턴에 대한 캐시를 수동으로 무효화합니다.

```dart
final results = await db.query('heavy_table')
    .where('non_indexed_field', '=', 'value')
    .useQueryCache(const Duration(minutes: 10)); // Manual acceleration for a heavy query only
```


### <a id="query-pagination"></a>쿼리 및 효율적인 페이지 매김

> [!TIP]
> **최고의 성능을 위해 항상 `limit`을 지정하세요**: 모든 쿼리에 `limit`을 명시적으로 제공하는 것이 좋습니다. 생략하면 엔진의 기본값은 1000행입니다. 핵심 쿼리 엔진은 빠르지만 애플리케이션 계층에서 매우 큰 결과 집합을 직렬화하면 여전히 불필요한 오버헤드가 추가될 수 있습니다.

ToStore는 규모와 성능 요구 사항에 따라 선택할 수 있도록 두 가지 페이지 매김 모드를 제공합니다.

#### 1. 기본 페이지 매김(오프셋 모드)
상대적으로 작은 데이터세트나 정확한 페이지 이동이 필요한 경우에 적합합니다.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // Skip the first 40 rows
    .limit(20); // Take 20 rows
```
> [!TIP]
> `offset`이 매우 커지면 데이터베이스가 많은 행을 스캔하고 삭제해야 하므로 성능이 선형적으로 떨어집니다. 깊은 페이지 매김을 위해서는 **커서 모드**를 선호하세요.

#### 2. 커서 페이지 매김(커서 모드)
대규모 데이터 세트와 무한 스크롤에 이상적입니다. `nextCursor`을 사용하면 엔진이 현재 위치에서 계속 작동하며 깊은 오프셋으로 인한 추가 스캔 비용을 피할 수 있습니다.

> [!IMPORTANT]
> 인덱싱되지 않은 필드에 대한 일부 복잡한 쿼리 또는 정렬의 경우 엔진이 전체 스캔으로 대체되어 `null` 커서를 반환할 수 있습니다. 이는 현재 해당 특정 쿼리에 대해 페이지 매김이 지원되지 않음을 의미합니다.

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

| 기능 | 오프셋 모드 | 커서 모드 |
| :--- | :--- | :--- |
| **쿼리 성능** | 페이지가 깊어질수록 성능 저하 | 딥 페이징에 안정적 |
| **최고의 대상** | 더 작은 데이터 세트, 정확한 페이지 점프 | **대량 데이터세트, 무한 스크롤** |
| **변경 시 일관성** | 데이터 변경으로 인해 행 건너뛰기가 발생할 수 있음 | 데이터 변경으로 인한 중복 및 누락 방지 |


### <a id="foreign-keys"></a>외래 키 및 계단식 배열

외래 키는 참조 무결성을 보장하고 계단식 업데이트 및 삭제를 구성할 수 있도록 해줍니다. 쓰기 및 업데이트 시 관계의 유효성이 검사됩니다. 캐스케이드 정책이 활성화되면 관련 데이터가 자동으로 업데이트되어 애플리케이션 코드의 일관성 작업이 줄어듭니다.

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


### <a id="query-operators"></a>쿼리 연산자

모든 `where(field, operator, value)` 조건은 다음 연산자를 지원합니다(대소문자 구분 안 함).

| 연산자 | 설명 | 예제 / 성능 |
| :--- | :--- | :--- |
| `=` | 같음 | `where('status', '=', 'val')` — **[권장]** 인덱스 Seek |
| `!=`, `<>` | 같지 않음 | `where('role', '!=', 'val')` — **[주의]** 전체 테이블 스캔 |
| `>` , `>=`, `<`, `<=` | 범위 비교 | `where('age', '>', 18)` — **[권장]** 인덱스 Scan |
| `IN` | 포함 | `where('id', 'IN', [...])` — **[권장]** 인덱스 Seek |
| `NOT IN` | 포함되지 않음 | `where('status', 'NOT IN', [...])` — **[주의]** 전체 테이블 스캔 |
| `BETWEEN` | 범위 | `where('age', 'BETWEEN', [18, 65])` — **[권장]** 인덱스 Scan |
| `LIKE` | 패턴 일치 (`%` = 모든 문자, `_` = 단일 문자) | `where('name', 'LIKE', 'John%')` — **[주의]** 아래 참고 사항 참조 |
| `NOT LIKE` | 패턴 불일치 | `where('email', 'NOT LIKE', '...')` — **[주의]** 전체 테이블 스캔 |
| `IS` | null임 | `where('deleted_at', 'IS', null)` — **[권장]** 인덱스 Seek |
| `IS NOT` | null이 아님 | `where('email', 'IS NOT', null)` — **[주의]** 전체 테이블 스캔 |

### 의미론적 쿼리 방법(권장)

손으로 쓴 연산자 문자열을 피하고 더 나은 IDE 지원을 받으려면 권장됩니다.

#### 1. 비교
직접적인 숫자 또는 문자열 비교에 사용됩니다.

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

#### 2. 수집 및 범위
필드가 세트 또는 범위 내에 속하는지 여부를 테스트하는 데 사용됩니다.

```dart
db.query('users').whereIn('id', ['id1', 'id2']);                 // In list
db.query('users').whereNotIn('status', ['banned', 'pending']);   // Not in list
db.query('users').whereBetween('age', 18, 65);                   // In range (inclusive)
```

#### 3. Null 확인
필드에 값이 있는지 테스트하는 데 사용됩니다.

```dart
db.query('users').whereNull('deleted_at');    // Is null
db.query('users').whereNotNull('email');      // Is not null
db.query('users').whereEmpty('nickname');     // Is null or empty string
db.query('users').whereNotEmpty('bio');       // Is not null and not empty
```

#### 4. 패턴 매칭
SQL 스타일 와일드카드 검색을 지원합니다(`%`은 임의 개수의 문자와 일치하고, `_`은 단일 문자와 일치합니다).

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
> **쿼리 성능 가이드 (인덱스 vs 전체 스캔)**
>
> 대규모 데이터 세트(수백만 행 이상) 시나리오에서는 메인 스레드 지연 및 쿼리 타임아웃을 방지하기 위해 다음 원칙을 준수하십시오.
>
> 1. **인덱스 최적화 - [권장]**:
>    *   **의미론적 메서드**: `whereEqual`, `whereGreaterThan`, `whereLessThan`, `whereIn`, `whereBetween`, `whereNull`, `whereTrue`, `whereFalse` 및 **`whereStartsWith`** (접두사 일치).
>    *   **연산자**: `=`, `>`, `<`, `>=`, `<=`, `IN`, `BETWEEN`, `IS null`, `LIKE 'prefix%'`.
>    *   *설명: 이러한 작업은 인덱스를 통해 매우 빠른 위치 지정을 달성합니다. `whereStartsWith` / `LIKE 'abc%'`의 경우에도 인덱스는 접두사 범위 스캔을 수행할 수 있습니다.*
>
> 2. **전체 스캔 위험 - [주의]**:
>    *   **모호한 일치**: `whereContains` (`LIKE '%val%'`), `whereEndsWith` (`LIKE '%val'`), `whereContainsAny`.
>    *   **부정 쿼리**: `whereNotEqual` (`!=`, `<>`), `whereNotIn` (`NOT IN`), `whereNotNull` (`IS NOT null`/`whereNotEmpty`).
>    *   **패턴 불일치**: `NOT LIKE`.
>    *   *설명: 위 작업은 인덱스가 구성되어 있더라도 일반적으로 전체 데이터 저장 영역을 탐색해야 합니다. 모바일이나 작은 데이터 세트에서는 영향이 미미하지만, 분산형 또는 초대형 데이터 분석 시나리오에서는 다른 인덱스 조건(예: ID 또는 시간 범위별 데이터 필터링) 및 `limit` 절과 결합하여 신중하게 사용해야 합니다.*

## <a id="distributed-architecture"></a>분산 아키텍처

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

## <a id="primary-key-examples"></a>기본 키 예

ToStore는 다양한 비즈니스 시나리오에 대해 여러 분산 기본 키 알고리즘을 제공합니다.

- **순차 기본 키**(`PrimaryKeyType.sequential`): `238978991`
- **타임스탬프 기반 기본 키**(`PrimaryKeyType.timestampBased`): `1306866018836946`
- **날짜가 앞에 붙는 기본 키**(`PrimaryKeyType.datePrefixed`): `20250530182215887631`
- **단축 코드 기본 키**(`PrimaryKeyType.shortCode`): `9eXrF0qeXZ`

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


## <a id="atomic-expressions"></a>원자 표현

표현식 시스템은 유형이 안전한 원자 필드 업데이트를 제공합니다. 모든 계산은 데이터베이스 계층에서 원자적으로 실행되어 동시 충돌을 방지합니다.

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

**조건식(예: upsert에서 업데이트와 삽입 구별)**: `Expr.isUpdate()` / `Expr.isInsert()`을 `Expr.ifElse` 또는 `Expr.when`과 함께 사용하면 식이 업데이트 시에만 평가되거나 삽입 시에만 평가됩니다.

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

## <a id="transactions"></a>거래

트랜잭션은 여러 작업에서 원자성을 보장합니다. 즉, 모든 것이 성공하거나 모든 것이 롤백되어 데이터 일관성이 유지됩니다.

**거래 특성**
- 여러 작업이 모두 성공하거나 모두 롤백됩니다.
- 미완성 작업은 충돌 후 자동으로 복구됩니다.
- 성공적인 운영은 안전하게 지속됩니다.

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


### <a id="database-maintenance"></a>관리 및 유지 관리

다음 API는 플러그인 스타일 개발, 관리 패널 및 운영 시나리오를 위한 데이터베이스 관리, 진단 및 유지 관리를 다룹니다.

- **테이블 관리**
  - `createTable(schema)`: 단일 테이블을 수동으로 생성합니다. 모듈 로딩 또는 주문형 런타임 테이블 생성에 유용합니다.
  - `getTableSchema(tableName)`: 정의된 스키마 정보를 검색합니다. 자동화된 유효성 검사 또는 UI 모델 생성에 유용합니다.
  - `getTableInfo(tableName)`: 레코드 수, 인덱스 수, 데이터 파일 크기, 생성 시간 및 테이블이 전역인지 여부를 포함한 런타임 테이블 통계를 검색합니다.
  - `clear(tableName)`: 스키마, 인덱스, 내부/외부 키 제약 조건을 안전하게 유지하면서 모든 테이블 데이터를 지웁니다.
  - `dropTable(tableName)`: 테이블과 해당 스키마를 완전히 삭제합니다. 되돌릴 수 없음
- **공간 관리**
  - `currentSpaceName`: 현재 활성 공간을 실시간으로 가져옵니다.
  - `listSpaces()`: 현재 데이터베이스 인스턴스에 할당된 모든 공간을 나열합니다.
  - `getSpaceInfo(useCache: true)`: 현재 공간을 감사합니다. `useCache: false`을 사용하여 캐시를 우회하고 실시간 상태를 읽습니다.
  - `deleteSpace(spaceName)`: `default` 및 현재 활성 공간을 제외한 특정 공간 및 해당 공간의 모든 데이터를 삭제합니다.
- **인스턴스 검색**
  - `config`: 인스턴스에 대한 최종 유효 `DataStoreConfig` 스냅샷을 검사합니다.
  - `instancePath`: 물리적 저장소 디렉터리를 정확하게 찾습니다.
  - `getVersion()` / `setVersion(version)`: 애플리케이션 수준 마이그레이션 결정을 위한 비즈니스 정의 버전 제어(엔진 버전 아님)
- **유지관리**
  - `flush(flushStorage: true)`: 보류 중인 데이터를 디스크에 강제로 저장합니다. `flushStorage: true`인 경우 시스템은 하위 수준 저장소 버퍼도 플러시하도록 요청받습니다.
  - `deleteDatabase()`: 현재 인스턴스에 대한 모든 실제 파일과 메타데이터를 제거합니다. 조심해서 사용하세요
- **진단**
  - `db.status.memory()`: 캐시 적중률, 인덱스 페이지 사용량 및 전체 힙 할당을 검사합니다.
  - `db.status.space()` / `db.status.table(tableName)`: 공간 및 테이블에 대한 실시간 통계 및 건강 정보 확인
  - `db.status.config()`: 현재 런타임 구성 스냅샷을 검사합니다.
  - `db.status.migration(taskId)`: 비동기 마이그레이션 진행 상황을 실시간으로 추적합니다.

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


### <a id="backup-restore"></a>백업 및 복원

단일 사용자 로컬 가져오기/내보내기, 대규모 오프라인 데이터 마이그레이션 및 오류 후 시스템 롤백에 특히 유용합니다.

- **백업(`backup`)**
  - `compress`: 압축 활성화 여부; 권장되며 기본적으로 활성화되어 있습니다.
  - `scope` : 백업 범위를 제어합니다.
    - `BackupScope.database`: 모든 공간과 전역 테이블을 포함하여 **전체 데이터베이스 인스턴스**를 백업합니다.
    - `BackupScope.currentSpace`: 전역 테이블을 제외하고 **현재 활성 공간**만 백업합니다.
    - `BackupScope.currentSpaceWithGlobal`: 단일 테넌트 또는 단일 사용자 마이그레이션에 이상적인 **현재 공간과 관련 전역 테이블**을 백업합니다.
- **복원(`restore`)**
  - `backupPath`: 백업 패키지의 물리적 경로
  - `cleanupBeforeRestore`: 복원하기 전에 관련 현재 데이터를 자동으로 삭제할지 여부. 혼합된 논리 상태를 방지하려면 `true`을 사용하는 것이 좋습니다.
  - `deleteAfterRestore`: 복원 성공 후 백업 소스 파일을 자동으로 삭제합니다.

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

### <a id="error-handling"></a>상태 코드 및 오류 처리


ToStore는 데이터 작업에 통합 응답 모델을 사용합니다.

- `ResultType`: 분기 논리에 사용되는 통합 상태 열거형
- `result.code`: `ResultType`에 해당하는 안정적인 숫자 코드
- `result.message`: 현재 오류를 설명하는 읽을 수 있는 메시지
- `successKeys` / `failedKeys`: 대량 작업에서 성공 및 실패한 기본 키 목록


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

일반적인 상태 코드 예:
성공하면 `0`이 반환됩니다. 음수는 오류를 나타냅니다.
- `ResultType.success` (`0`) : 작업 성공
- `ResultType.partialSuccess` (`1`) : 일괄 작업이 부분적으로 성공했습니다.
- `ResultType.unknown`(`-1`): 알 수 없는 오류
- `ResultType.uniqueViolation` (`-2`): 고유 인덱스 충돌
- `ResultType.primaryKeyViolation` (`-3`): 기본 키 충돌
- `ResultType.foreignKeyViolation`(`-4`): 외래 키 참조가 제약 조건을 충족하지 않습니다.
- `ResultType.notNullViolation`(`-5`): 필수 필드가 누락되었거나 허용되지 않는 `null`이 전달되었습니다.
- `ResultType.validationFailed`(`-6`): 길이, 범위, 형식 또는 기타 유효성 검사에 실패했습니다.
- `ResultType.notFound`(`-11`): 대상 테이블, 공간 또는 리소스가 존재하지 않습니다.
- `ResultType.resourceExhausted`(`-15`): 시스템 리소스가 부족합니다. 로드를 줄이거나 다시 시도하세요.
- `ResultType.dbError`(`-91`): 데이터베이스 오류
- `ResultType.ioError` (`-90`): 파일 시스템 오류
- `ResultType.timeout`(`-92`): 시간 초과

### 거래결과 처리
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

거래 오류 유형:
- `TransactionErrorType.operationError`: 필드 유효성 검사 실패, 잘못된 리소스 상태 또는 기타 비즈니스 수준 오류 등 트랜잭션 내부의 일반 작업이 실패했습니다.
- `TransactionErrorType.integrityViolation`: 기본 키, 고유 키, 외래 키 또는 null이 아닌 오류와 같은 무결성 또는 제약 조건 충돌
- `TransactionErrorType.timeout`: 시간 초과
- `TransactionErrorType.io`: 기본 저장소 또는 파일 시스템 I/O 오류
- `TransactionErrorType.conflict`: 충돌로 인해 거래가 실패했습니다.
- `TransactionErrorType.userAbort`: 사용자가 시작한 중단(throw 기반 수동 중단은 현재 지원되지 않음)
- `TransactionErrorType.unknown`: 기타 오류


### <a id="logging-diagnostics"></a>로그 콜백 및 데이터베이스 진단

ToStore는 시작, 복구, 자동 마이그레이션 및 런타임 제약 조건 충돌 로그를 `LogConfig.setConfig(...)`을 통해 비즈니스 계층으로 다시 라우팅할 수 있습니다.

- `onLogHandler`은 현재 `enableLog` 및 `logLevel` 필터를 통과하는 모든 로그를 수신합니다.
- 초기화 전에 `LogConfig.setConfig(...)`을 호출하면 초기화 및 자동 마이그레이션 중에 생성된 로그도 캡처됩니다.

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


## <a id="security-config"></a>보안 구성

> [!WARNING]
> **키 관리**: **`encodingKey`** 자유롭게 변경할 수 있으며 엔진이 자동으로 데이터를 마이그레이션하므로 데이터를 복구 가능한 상태로 유지합니다. **`encryptionKey`** 임의로 변경하면 안 됩니다. 변경된 후에는 명시적으로 마이그레이션하지 않는 한 오래된 데이터를 해독할 수 없습니다. 민감한 키를 하드코딩하지 마세요. 보안 서비스에서 가져오는 것이 좋습니다.

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

### 값 수준 암호화(ToCrypto)

전체 데이터베이스 암호화는 모든 테이블 및 인덱스 데이터를 보호하지만 전반적인 성능에 영향을 미칠 수 있습니다. 몇 가지 중요한 값만 보호해야 하는 경우 대신 **ToCrypto**를 사용하세요. 데이터베이스에서 분리되고 `db` 인스턴스가 필요하지 않으며 쓰기 전이나 읽기 후에 애플리케이션에서 값을 인코딩/디코딩할 수 있습니다. 출력은 JSON 또는 TEXT 열에 자연스럽게 맞는 Base64입니다.

- **`key`** (필수): `String` 또는 `Uint8List`. 32바이트가 아닌 경우 SHA-256을 사용하여 32바이트 키를 파생합니다.
- **`type`** (선택 사항): `ToCryptoType`의 암호화 유형(예: `ToCryptoType.chacha20Poly1305` 또는 `ToCryptoType.aes256Gcm`). 기본값은 `ToCryptoType.chacha20Poly1305`입니다.
- **`aad`** (선택 사항): `Uint8List` 유형의 추가 인증 데이터입니다. 인코딩 중에 제공되는 경우 디코딩 중에도 정확히 동일한 바이트를 제공해야 합니다.

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


## <a id="advanced-config"></a>고급 구성 설명(DataStoreConfig)

> [!TIP]
> **제로 구성 인텔리전스**
> ToStore는 플랫폼, 성능 특성, 사용 가능한 메모리, I/O 동작을 자동으로 감지하여 동시성, 샤드 크기, 캐시 예산과 같은 매개변수를 최적화합니다. **일반적인 비즈니스 시나리오의 99%에서는 `DataStoreConfig`을 수동으로 미세 조정할 필요가 없습니다.** 기본값은 이미 현재 플랫폼에 탁월한 성능을 제공합니다.


| 매개변수 | 기본값 | 목적 및 권고사항 |
| :--- | :--- | :--- |
| **`yieldDurationMs`** | **8ms** | **핵심 권장 사항.** 장기 작업이 산출될 때 사용되는 시간 조각입니다. `8ms`은 120fps/60fps 렌더링에 적합하며 대규모 쿼리 또는 마이그레이션 중에 UI를 원활하게 유지하는 데 도움이 됩니다. |
| **`maxQueryOffset`** | **10000** | **쿼리 보호.** `offset`이 이 임계값을 초과하면 오류가 발생합니다. 이는 깊은 오프셋 페이지 매김으로 인한 병리적 I/O를 방지합니다. |
| **`defaultQueryLimit`** | **1000** | **리소스 가드레일.** 쿼리가 `limit`을 지정하지 않을 때 적용되어 실수로 대규모 결과 세트가 로드되고 잠재적인 OOM 문제가 발생하는 것을 방지합니다. |
| **`cacheMemoryBudgetMB`** | (자동) | **세밀한 메모리 관리.** 총 캐시 메모리 예산. 엔진은 이를 사용하여 LRU 회수를 자동으로 실행합니다. |
| **`enableJournal`** | **사실** | **충돌 자가 치유.** 활성화되면 충돌이나 정전 후 엔진이 자동으로 복구될 수 있습니다. |
| **`persistRecoveryOnCommit`** | **사실** | **강력한 내구성 보장.** true인 경우 커밋된 트랜잭션이 물리적 스토리지에 동기화됩니다. false인 경우 더 나은 속도를 위해 플러시가 백그라운드에서 비동기적으로 수행되며 극단적인 충돌 시 소량의 데이터가 손실될 위험이 적습니다. |
| **`ttlCleanupIntervalMs`** | **300000** | **글로벌 TTL 폴링.** 엔진이 유휴 상태가 아닐 때 만료된 데이터를 검색하는 백그라운드 간격입니다. 값이 낮을수록 만료된 데이터가 더 빨리 삭제되지만 오버헤드가 더 많이 발생합니다. |
| **`maxConcurrency`** | (자동) | **컴퓨팅 동시성 제어.** 벡터 계산 및 암호화/암호 해독과 같은 집약적인 작업을 위한 최대 병렬 작업자 수를 설정합니다. 일반적으로 자동으로 유지하는 것이 가장 좋습니다. |

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

## <a id="performance"></a>성능 및 경험

### 벤치마크

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="ToStore Basic Performance Demo" width="320" />
</p>

- **기본 성능 데모**(<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4" target="_blank" rel="noopener">basic-demo.mp4</a>): GIF 미리보기에 모든 내용이 표시되지 않을 수 있습니다. 전체 데모를 보려면 비디오를여십시오. 일반 모바일 기기에서도 데이터 세트가 1억 레코드를 초과하더라도 시작, 페이징, 검색이 안정적이고 원활하게 유지됩니다.

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="ToStore Disaster Recovery Stress Test" width="320" />
</p>

- **재해 복구 스트레스 테스트**(<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4" target="_blank" rel="noopener">disaster-recovery.mp4</a>): 빈도가 높은 쓰기 중에는 충돌 및 정전을 시뮬레이션하기 위해 프로세스가 의도적으로 계속해서 중단됩니다. 투스토어는 빠른 복구가 가능합니다.


### 경험 팁

- 📱 **예제 프로젝트**: `example` 디렉토리에는 완전한 Flutter 애플리케이션이 포함되어 있습니다.
- 🚀 **프로덕션 빌드**: 릴리스 모드에서 패키징하고 테스트합니다. 릴리스 성능은 디버그 모드를 훨씬 뛰어넘습니다.
- ✅ **표준 테스트**: 핵심 기능은 표준화된 테스트로 다룹니다.


ToStore가 도움이 되셨다면 ⭐️댓글 부탁드려요
이는 프로젝트를 지원하는 가장 좋은 방법 중 하나입니다. 매우 감사합니다.


> **권장사항**: 프런트엔드 앱 개발의 경우 데이터 요청, 로드, 저장, 캐싱 및 프레젠테이션을 자동화하고 통합하는 풀 스택 솔루션을 제공하는 [ToApp 프레임워크](https://github.com/tocreator/toapp)을 고려하세요.


## <a id="more-resources"></a>추가 리소스

- 📖 **문서**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **문제 보고**: [GitHub 문제](https://github.com/tocreator/tostore/issues)
- 💬 **기술적 토론**: [GitHub 토론](https://github.com/tocreator/tostore/discussions)



