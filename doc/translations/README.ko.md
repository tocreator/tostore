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

- [왜 ToStore인가?](#why-tostore) | [주요 기능](#key-features) | [설치](#installation) | [빠른 시작](#quick-start)
- [스키마 정의](#schema-definition) | [모바일/데스크톱 통합](#mobile-integration) | [서버 사이드 통합](#server-integration)
- [벡터 및 ANN 검색](#vector-advanced) | [테이블 수준 TTL](#ttl-config) | [쿼리 및 페이지네이션](#query-pagination) | [외래 키](#foreign-keys) | [쿼리 연산자](#query-operators)
- [분산 아키텍처](#distributed-architecture) | [기본 키 예시](#primary-key-examples) | [원자적 표현식 작업](#atomic-expressions) | [트랜잭션](#transactions) | [오류 처리](#error-handling)
- [보안 구성](#security-config) | [성능](#performance) | [추가 리소스](#more-resources)


<a id="why-tostore"></a>
## 왜 ToStore인가?

ToStore는 AGI 시대와 에지 인텔리전스 시나리오를 위해 설계된 현대적인 데이터 엔진입니다. 분산 시스템, 멀티모달 융합, 관계형 구조화 데이터, 고차원 벡터 및 비구조화 데이터 저장을 기본적으로 지원합니다. 신경망과 유사한 기본 아키텍처를 기반으로 하여 노드는 높은 자율성과 탄력적인 수평 확장성을 갖추고 있으며, 에지와 클라우드를 가로지르는 원활한 크로스 플랫폼 협업을 가능하게 하는 유연한 데이터 토폴로지 네트워크를 구축합니다. ACID 트랜잭션, 복잡한 관계형 쿼리(JOIN, 계층형 외래 키), 테이블 수준 TTL 및 집계 계산 기능을 제공합니다. 또한 여러 분산 기본 키 알고리즘, 원자적 표현식, 스키마 변경 식별, 암호화 보호, 멀티 스페이스 데이터 격리, 리소스 인식 지능형 부하 분산 및 재해/크래시 자동 복구 기능을 갖추고 있습니다.

컴퓨팅의 중심이 에지 인텔리전스로 계속 이동함에 따라 에이전트 및 센서와 같은 다양한 터미널은 단순한 "콘텐츠 디스플레이"가 아니라 로컬 생성, 환경 인식, 실시간 의사 결정 및 데이터 협업을 담당하는 인텔리전트 노드가 되고 있습니다. 기존 데이터베이스 솔루션은 기본 아키텍처 및 애드온 방식의 확장에 제한되어 있어 고빈도 쓰기, 방대한 데이터, 벡터 검색 및 협업 생성에 직면했을 때 에지 인텔리전스 애플리케이션이 요구하는 낮은 대기 시간과 안정성을 충족하는 데 어려움을 겪고 있습니다.

ToStore는 방대한 데이터, 복잡한 로컬 AI 생성 및 대규모 데이터 흐름을 지원할 수 있는 분산 기능을 에지에 부여합니다. 에지와 클라우드 노드 간의 심층적인 인텔리전트 협업을 통해 몰입형 AR/VR 융합, 멀티모달 상호 작용, 시맨틱 벡터, 공간 모델링 등의 시나리오에 신뢰할 수 있는 데이터 기반을 제공합니다.


<a id="key-features"></a>
## 주요 기능

- 🌐 **통합 크로스 플랫폼 데이터 엔진**
  - 모바일, 데스크톱, 웹 및 서버를 위한 통합 API.
  - 관계형 구조화 데이터, 고차원 벡터 및 비구조화 데이터 저장 지원.
  - 로컬 저장소에서 에지-클라우드 협업까지의 데이터 수명 주기에 이상적입니다.

- 🧠 **신경망 유사 분산 아키텍처**
  - 노드의 높은 자율성; 상호 연결된 협업으로 유연한 데이터 토폴로지 구축.
  - 노드 협업 및 탄력적인 수평 확장성 지원.
  - 에지 인텔리전트 노드와 클라우드 간의 심층 연결.

- ⚡ **병렬 실행 및 리소스 스케줄링**
  - 리소스 인식 지능형 부하 분산으로 고가용성 실현.
  - 다중 노드 병렬 협업 컴퓨팅 및 작업 분해.

- 🔍 **구조화된 쿼리 및 벡터 검색**
  - 복잡한 조건 쿼리, JOIN, 집계 계산 및 테이블 수준 TTL 지원.
  - 벡터 필드, 벡터 인덱스 및 근사 근접 이웃(ANN) 검색 지원.
  - 구조화된 데이터와 벡터 데이터를 동일 엔진 내에서 협업하여 사용 가능.

- 🔑 **기본 키, 인덱싱 및 스키마 진화**
  - 순차 증분, 타임스탬프, 날짜 접두사 및 단축 코드 PK 알고리즘 내장.
  - 유니크 인덱스, 복합 인덱스, 벡터 인덱스 및 외래 키 제약 조건 지원.
  - 스키마 변경을 지능적으로 인식하고 데이터 마이그레이션 자동화.

- 🛡️ **트랜잭션, 보안 및 복구**
  - ACID 트랜잭션, 원자적 표현식 업데이트 및 계층형 외래 키 제공.
  - 크래시 복구, 지속적 플러시 및 데이터 일관성 보장.
  - ChaCha20-Poly1305 및 AES-256-GCM 암호화 지원.

- 🔄 **멀티 스페이스 및 데이터 워크플로우**
  - 스페이스를 통한 데이터 격리 및 구성 가능한 글로벌 공유 지원.
  - 실시간 쿼리 리스너, 다단계 지능형 캐싱 및 커서 페이지네이션.
  - 다중 사용자, 로컬 우선 및 오프라인 협업 애플리케이션에 최적입니다.


<a id="installation"></a>
## 설치

> [!IMPORTANT]
> **v2.x에서 업그레이드하시나요?** 중요한 마이그레이션 단계와 주요 변경 사항은 [v3.x 업그레이드 가이드](../UPGRADE_GUIDE_v3.md)를 읽어보세요.

`pubspec.yaml`에 `tostore`를 종속성으로 추가합니다:

```yaml
dependencies:
  tostore: any # 최신 버전을 사용하세요
```

<a id="quick-start"></a>
## 빠른 시작

> [!IMPORTANT]
> **테이블 스키마 정의가 첫 번째 단계입니다**: CRUD 작업을 수행하기 전에 테이블 스키마를 정의해야 합니다(KV 저장소만 사용하는 경우 제외). 구체적인 정의 방법은 시나리오에 따라 다릅니다:
> - 정의 및 제약 조건에 대한 자세한 내용은 [스키마 정의](#schema-definition)를 참조하세요.
> - **모바일/데스크톱**: 인스턴스 초기화 시 `schemas`를 전달합니다. 자세한 내용은 [모바일/데스크톱 통합](#mobile-integration)을 참조하세요.
> - **서버 사이드**: 런타임에 `createTables`를 사용합니다. 자세한 내용은 [서버 사이드 통합](#server-integration)을 참조하세요.

```dart
// 1. 데이터베이스 초기화
final db = await ToStore.open();

// 2. 데이터 삽입
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. 체인형 쿼리 ([쿼리 연산자](#query-operators) 참조; =, !=, >, <, LIKE, IN 등 지원)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// 4. 업데이트 및 삭제
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. 실시간 리스닝 (데이터 변경 시 UI가 자동으로 업데이트됨)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('일치하는 사용자 업데이트됨: $users');
});
```

### 키-값 저장소 (KV)
구조화된 테이블이 필요하지 않은 시나리오에 적합합니다. 간단하고 실용적이며 구성, 상태 및 기타 분산된 데이터를 위한 고성능 KV 저장소가 내장되어 있습니다. 서로 다른 스페이스의 데이터는 기본적으로 격리되지만 전체 공유로 설정할 수 있습니다.

```dart
// 데이터베이스 초기화
final db = await ToStore.open();

// 키-값 쌍 설정 (String, int, bool, double, Map, List 등 지원)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// 데이터 가져오기
final theme = await db.getValue('theme'); // 'dark'

// 데이터 삭제
await db.removeValue('theme');

// 글로벌 키-값 (스페이스 간 공유)
// 일반 KV 데이터는 스페이스를 전환하면 비활성화됩니다. 글로벌 공유에는 isGlobal: true를 사용하세요.
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```


<a id="schema-definition"></a>
## 스키마 정의
다음 모바일 및 서버 사이드 예제는 여기서 정의된 `appSchemas`를 재사용합니다.

### TableSchema 개요

```dart
const userSchema = TableSchema(
  name: 'users', // 테이블 이름, 필수
  tableId: 'users', // 고유 식별자, 선택 사항; 테이블 이름 변경을 100% 정확하게 감지하는 데 사용
  primaryKeyConfig: PrimaryKeyConfig(
    name: 'id', // PK 필드 이름, 기본값은 'id'
    type: PrimaryKeyType.sequential, // 자동 생성 유형
    sequentialConfig: SequentialIdConfig(
      initialValue: 1000, // 시작 값
      increment: 1, // 증가 단계
      useRandomIncrement: false, // 무작위 증가 사용 여부
    ),
  ),
  fields: [
    FieldSchema(
      name: 'username', // 필드 이름, 필수
      type: DataType.text, // 데이터 유형, 필수
      nullable: false, // null 허용 여부
      minLength: 3, // 최소 길이
      maxLength: 32, // 최대 길이
      unique: true, // 고유 제약 조건
      fieldId: 'username', // 필드 고유 식별자, 선택 사항; 이름 변경 감지용
      comment: '로그인 이름', // 선택적 주석
    ),
    FieldSchema(
      name: 'status',
      type: DataType.integer,
      minValue: 0, // 하한
      maxValue: 150, // 상한
      defaultValue: 0, // 정적 기본값
      createIndex: true,  // 성능 향상을 위한 인덱스 생성 단축키
    ),
    FieldSchema(
      name: 'created_at',
      type: DataType.datetime,
      nullable: false,
      defaultValueType: DefaultValueType.currentTimestamp, // 현재 시간으로 자동 채우기
      createIndex: true,
    ),
  ],
  indexes: const [
    IndexSchema(
      indexName: 'idx_users_status_created_at', // 선택적 인덱스 이름
      fields: ['status', 'created_at'], // 복합 인덱스 필드
      unique: false, // 유니크 인덱스 여부
      type: IndexType.btree, // 인덱스 유형: btree/hash/bitmap/vector
    ),
  ],
  foreignKeys: const [], // 선택적 외래 키 제약 조건; 자세한 내용은 "외래 키" 예시 참조
  isGlobal: false, // 글로벌 테이블 여부; 모든 스페이스에서 액세스 가능
  ttlConfig: null, // 테이블 수준 TTL; 자세한 내용은 "테이블 수준 TTL" 예시 참조
);

const appSchemas = [userSchema];
```

`DataType`은 `integer`, `bigInt`, `double`, `text`, `blob`, `boolean`, `datetime`, `array`, `json`, `vector`를 지원합니다. `PrimaryKeyType`은 `none`, `sequential`, `timestampBased`, `datePrefixed`, `shortCode`를 지원합니다.

### 제약 조건 및 자동 유효성 검사

`FieldSchema`를 사용하여 스키마에 직접 일반적인 유효성 검사 규칙을 작성할 수 있으므로 UI 또는 서비스 계층에서 중복 로직을 방지할 수 있습니다:

- `nullable: false`: Non-null 제약 조건.
- `minLength` / `maxLength`: 텍스트 길이 제약 조건.
- `minValue` / `maxValue`: 숫자 범위 제약 조건.
- `defaultValue` / `defaultValueType`: 정적 및 동적 기본값.
- `unique`: 고유성 제약 조건.
- `createIndex`: 빈도가 높은 필터링, 정렬 또는 조인을 위한 인덱스를 생성합니다.
- `fieldId` / `tableId`: 마이그레이션 중에 이름이 변경된 필드 또는 테이블을 식별하는 데 도움이 됩니다.

이러한 제약 조건은 데이터 쓰기 경로에서 유효성이 검사되므로 중복 구현을 줄일 수 있습니다. `unique: true`는 유니크 인덱스를 자동으로 생성합니다. `createIndex: true` 및 외래 키는 표준 인덱스를 자동으로 생성합니다. 복합 또는 벡터 인덱스에는 `indexes`를 사용하세요.


### 통합 방법 선택

- **모바일/데스크톱**: `appSchemas`를 `ToStore.open(...)`에 직접 전달하는 것이 가장 좋습니다.
- **서버 사이드**: 런타임에 `createTables(appSchemas)`를 통해 동적으로 스키마를 생성하는 것이 좋습니다.


<a id="mobile-integration"></a>
## 모바일/데스크톱 통합

📱 **예제**: [mobile_quickstart.dart](../../example/lib/mobile_quickstart.dart)

```dart
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// Android/iOS: 쓰기 가능한 디렉토리를 먼저 확인한 다음 dbPath로 전달합니다.
final docDir = await getApplicationDocumentsDirectory();
final dbRoot = p.join(docDir.path, 'common');

// 위에서 정의한 appSchemas 재사용
final db = await ToStore.open(
  dbPath: dbRoot,
  schemas: appSchemas,
);

// 멀티 스페이스 아키텍처 - 서로 다른 사용자의 데이터 격리
await db.switchSpace(spaceName: 'user_123');
```

### 로그인 상태 유지 및 로그아웃 (활성 스페이스)

멀티 스페이스는 **사용자 데이터 격리**에 이상적입니다: 사용자당 하나의 스페이스를 사용하며 로그인 시 전환합니다. **활성 스페이스** 및 **종료 옵션**을 사용하여 앱 재시작 후에도 현재 사용자를 유지하고 로그아웃을 지원할 수 있습니다.

- **로그인 상태 유지**: 사용자가 자신의 스페이스로 전환하면 해당 스페이스를 활성 상태로 표시합니다. 다음 실행 시 기본 열기를 통해 해당 스페이스에 직접 진입하므로 "기본 열기 후 전환" 단계를 건너뛸 수 있습니다.
- **로그아웃**: 사용자가 로그아웃하면 `keepActiveSpace: false`로 데이터베이스를 닫습니다. 다음 실행 시 이전 사용자의 스페이스가 자동으로 열리지 않습니다.

```dart
// 로그인 후: 사용자 스페이스로 전환하고 활성 상태로 저장 (로그인 유지)
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// 선택 사항: 기본 스페이스만 엄격하게 사용해야 하는 경우 (예: 로그인 화면 전용)
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// 로그아웃 시: 데이터베이스를 닫고 활성 스페이스를 지워 다음 실행 시 기본 스페이스 사용
await db.close(keepActiveSpace: false);
```


<a id="server-integration"></a>
## 서버 사이드 통합

🖥️ **예제**: [server_quickstart.dart](../../example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// 서비스 시작 시 테이블 구조 생성 또는 유효성 검사
await db.createTables(appSchemas);

// 온라인 스키마 업데이트
final taskId = await db.updateSchema('users')
  .renameTable('users_new')                // 테이블 이름 변경
  .modifyField(
    'username',
    minLength: 5,
    maxLength: 20,
    unique: true
  )                                        // 필드 속성 수정
  .renameField('old_name', 'new_name')     // 필드 이름 변경
  .removeField('deprecated_field')         // 필드 삭제
  .addField('created_at', type: DataType.datetime)  // 필드 추가
  .removeIndex(fields: ['age'])            // 인덱스 삭제
  .setPrimaryKeyConfig(                    // PK 유형 변경; 데이터가 비어 있어야 함
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
    
// 마이그레이션 진행 상태 모니터링
final status = await db.queryMigrationTaskStatus(taskId);
print('마이그레이션 진행률: ${status?.progressPercentage}%');


// 수동 쿼리 캐시 관리 (서버 사이드)
PK 또는 인덱싱된 필드에 대한 등가 또는 IN 쿼리는 매우 빠르므로 수동 캐시 관리는 거의 필요하지 않습니다.

// 쿼리 결과를 5분 동안 수동으로 캐싱합니다. 기간을 지정하지 않으면 만료되지 않습니다.
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// 데이터 변경 시 특정 캐시를 무효화하여 일관성을 보장합니다.
await db.query('users')
    .where('is_active', '=', true)
    .clearQueryCache();

// 실시간 데이터가 필요한 쿼리에 대해 캐시를 명시적으로 비활성화합니다.
final freshUserData = await db.query('users')
    .where('is_active', '=', true)
    .noQueryCache();
```


<a id="advanced-usage"></a>
## 고급 사용법

ToStore는 복잡한 비즈니스 요구 사항을 충족하기 위한 풍부한 고급 기능을 제공합니다:


<a id="vector-advanced"></a>
### 벡터 및 ANN 검색

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
        type: DataType.vector,  // 벡터 유형 선언
        nullable: false,
        vectorConfig: VectorFieldConfig(
          dimensions: 128, // 벡터 차원; 쓰기 및 쿼리 시 일치해야 함
          precision: VectorPrecision.float32, // 정밀도; float32는 정확도와 공간의 균형 유지
        ),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['embedding'], // 인덱싱할 필드
        type: IndexType.vector,  // 벡터 인덱스 구축
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh,  // 인덱스 알고리즘; 기본 제공 NGH
          distanceMetric: VectorDistanceMetric.cosine, // 지표; 정규화된 임베딩에 적합
          maxDegree: 32, // 노드당 최대 인접 노드 수; 클수록 재현율은 높아지지만 메모리 사용량 증가
          efSearch: 64, // 검색 확장 계수; 클수록 정확하지만 속도가 느려짐
          constructionEf: 128, // 인덱스 품질 계수; 클수록 품질은 좋아지지만 구축 속도 느려짐
        ),
      ),
    ],
  ),
]);

final queryVector =
    VectorData.fromList(List.generate(128, (i) => i * 0.01)); // 차원이 일치해야 함

// 벡터 검색
final results = await db.vectorSearch(
  'embeddings', 
  fieldName: 'embedding', 
  queryVector: queryVector, 
  topK: 5, // 상위 5개 결과 반환
  efSearch: 64, // 기본 검색 확장 계수 재정의
);

for (final r in results) {
  print('pk=${r.primaryKey}, score=${r.score}, distance=${r.distance}');
}
```

**매개변수 설명**:
- `dimensions`: 입력 임베딩의 너비와 일치해야 합니다.
- `precision`: 선택 사항으로 `float64`, `float32`, `int8`; 정밀도가 높을수록 저장 비용이 증가합니다.
- `distanceMetric`: 시맨틱 유사성에는 `cosine`, 유클리드 거리에는 `l2`, 내적 검색에는 `innerProduct` 사용.
- `maxDegree`: NGH 그래프의 최대 인접 노드 수.
- `efSearch`: 검색 시 확장 너비.
- `topK`: 반환할 결과 수.

**결과 설명**:
- `score`: 정규화된 유사도 점수 (0~1); 클수록 더 유사함.
- `distance`: `l2` 및 `cosine`에서 거리가 클수록 유사도가 낮음.


<a id="ttl-config"></a>
### 테이블 수준 TTL (자동 만료)

로그 또는 이벤트와 같은 시계열 데이터의 경우 스키마에서 `ttlConfig`를 정의합니다. 만료된 데이터는 백그라운드에서 자동으로 정리됩니다:

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
    ttlMs: 7 * 24 * 60 * 60 * 1000, // 7일간 유지
    // sourceField: 생략 시 자동으로 생성된 인덱스가 사용됨.
    // 사용자 정의 sourceField 규칙:
    // 1) DataType.datetime
    // 2) null 불가 (nullable: false)
    // 3) DefaultValueType.currentTimestamp
    // sourceField: 'created_at',
  ),
);
```


### 중첩 쿼리 및 사용자 정의 필터링
무한 중첩 및 유연한 사용자 정의 함수를 지원합니다.

```dart
// 조건 중첩: (type = 'app' OR (id >= 123 OR fans >= 200))
final idCondition = QueryCondition().where('id', '>=', 123).or().where('fans', '>=', 200);

final result = await db.query('users')
    .condition(
        QueryCondition().whereEqual('type', 'app').or().condition(idCondition)
    )
    .limit(20);

// 사용자 정의 조건 함수
final customResult = await db.query('users')
    .whereCustom((record) => record['tags']?.contains('추천') ?? false);
```

### 지능형 저장 (Upsert)
PK 또는 고유 키가 존재하면 업데이트하고, 그렇지 않으면 삽입합니다. `where` 절은 지원하지 않으며 충돌 대상은 데이터에 의해 결정됩니다.

```dart
// 기본 키 기준
final result = await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});

// 고유 키 기준 (레코드는 고유 인덱스의 모든 필드와 필수 필드를 포함해야 함)
await db.upsert('users', {
  'username': 'john',
  'email': 'john@example.com',
  'age': 26,
});

// 배치 upsert
final batchResult = await db.batchUpsert('users', [
  {'username': 'a', 'email': 'a@example.com'},
  {'username': 'b', 'email': 'b@example.com'},
], allowPartialErrors: true);
```


### 조인 및 필드 선택
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000)
    .limit(20);
```

### 스트리밍 및 집계
```dart
// 레코드 수 계산
final count = await db.query('users').count();

// 테이블 존재 여부 확인 (스페이스 무관)
final usersTableDefined = await db.tableExists('users');

// 효율적인 비로딩 존재 확인
final emailExists = await db.query('users')
    .where('email', '=', 'test@example.com')
    .exists();

// 집계 함수
final totalAge = await db.query('users').where('age', '>', 18).sum('age');
final avgAge = await db.query('users').avg('age');
final maxAge = await db.query('users').max('age');
final minAge = await db.query('users').min('age');

// 그룹화 및 필터링
final result = await db.query('orders')
    .select(['status', Agg.sum('amount', alias: 'total')])
    .groupBy(['status'])
    .having(Agg.sum('amount'), '>', 1000)
    .limit(20);

// 고유 쿼리
final uniqueCities = await db.query('users').distinct(['city']);

// 스트리밍 (방대한 데이터에 이상적)
db.streamQuery('users').listen((data) => print(data));
```


<a id="query-pagination"></a>
### 쿼리 및 효율적인 페이지네이션

> [!TIP]
> **최고의 성능을 위해 `limit`를 명시적으로 지정하세요**: 항상 `limit`를 지정하는 것이 좋습니다. 지정하지 않으면 기본적으로 1000개 레코드로 제한됩니다. 엔진 코어는 빠르지만 앱 레이어에서 대량의 데이터를 직렬화하면 불필요한 대기 시간이 발생할 수 있습니다.

ToStore는 데이터 규모에 맞는 이중 모드 페이지네이션을 제공합니다:

#### 1. 오프셋 모드
소규모 데이터셋(1만 개 미만) 또는 특정 페이지 점프가 필요한 경우에 적합합니다.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // 처음 40개 건너뛰기
    .limit(20); // 20개 가져오기
```
> [!TIP]
> `offset`이 커지면 DB가 레코드를 스캔하고 버려야 하므로 성능이 선형적으로 저하됩니다. 깊은 페이지의 경우 **커서 모드**를 사용하세요.

#### 2. 커서 모드
**방대한 데이터 및 무한 스크롤에 권장됩니다**. `nextCursor`를 사용하여 현재 위치에서 읽기를 다시 시작하므로 큰 오프셋으로 인한 부하를 피할 수 있습니다.

> [!IMPORTANT]
> 복잡한 쿼리나 인덱싱되지 않은 필드에 대한 정렬의 경우 엔진이 전체 테이블 스캔으로 전환하고 `null` 커서를 반환할 수 있습니다(해당 쿼리에 대해 페이지네이션이 지원되지 않음을 의미).

```dart
// 1페이지
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// 커서를 통한 다음 페이지 가져오기
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // 해당 위치로 직접 이동
}

// prevCursor를 통한 효율적인 이전 페이지 이동
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| 기능 | 오프셋 모드 | 커서 모드 |
| :--- | :--- | :--- |
| **성능** | 페이지가 뒤로 갈수록 저하됨 | **항상 일정 (O(1))** |
| **사용 사례** | 소규모 데이터, 페이지 점프 | **방대한 데이터, 무한 스크롤** |
| **일관성** | 데이터 변경 시 누락 발생 가능 | **중복 및 누락 방지** |


<a id="foreign-keys"></a>
### 외래 키 및 계층형 구조

참조 무결성을 강제하고 계층적 업데이트 또는 삭제를 구성합니다. 제약 조건은 데이터 쓰기 시 확인됩니다. 계층형 정책은 관련 데이터를 자동으로 처리하여 앱 내 일관성 로직을 줄여줍니다.

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
          fields: ['user_id'],              // 현재 테이블 필드
          referencedTable: 'users',         // 참조된 테이블
          referencedFields: ['id'],         // 참조된 필드
          onDelete: ForeignKeyCascadeAction.cascade,  // 계층 삭제
          onUpdate: ForeignKeyCascadeAction.cascade,  // 계층 업데이트
        ),
    ],
  ),
]);
```


<a id="query-operators"></a>
### 쿼리 연산자

모든 `where(field, operator, value)` 조건은 다음 연산자를 지원합니다(대소문자 구분 없음):

| 연산자 | 설명 | 예시 / 값 유형 |
| :--- | :--- | :--- |
| `=` | 같음 | `where('status', '=', 'active')` |
| `!=`, `<>` | 같지 않음 | `where('role', '!=', 'guest')` |
| `>` | 큼 | `where('age', '>', 18)` |
| `>=` | 크거나 같음 | `where('score', '>=', 60)` |
| `<` | 작음 | `where('price', '<', 100)` |
| `<=` | 작거나 같음 | `where('quantity', '<=', 10)` |
| `IN` | 목록에 있음 | `where('id', 'IN', ['a','b','c'])` — 값: `List` |
| `NOT IN` | 목록에 없음 | `where('status', 'NOT IN', ['banned'])` — 값: `List` |
| `BETWEEN` | 범위 내 (포함) | `where('age', 'BETWEEN', [18, 65])` — 값: `[시작, 끝]` |
| `LIKE` | 패턴 매칭 (`%` 전체, `_` 단일) | `where('name', 'LIKE', '%John%')` — 값: `String` |
| `NOT LIKE` | 패턴 불일치 | `where('email', 'NOT LIKE', '%@test.com')` — 값: `String` |
| `IS` | null임 | `where('deleted_at', 'IS', null)` — 값: `null` |
| `IS NOT` | null이 아님 | `where('email', 'IS NOT', null)` — 값: `null` |

### 시맨틱 쿼리 메서드 (권장)

시맨틱 메서드는 연산자 문자열을 수동으로 입력할 필요가 없으며 더 나은 IDE 지원을 제공합니다:

```dart
// 비교
db.query('users').whereEqual('username', 'John');
db.query('users').whereNotEqual('role', 'guest');
db.query('users').whereGreaterThan('age', 18);
db.query('users').whereGreaterThanOrEqualTo('score', 60);
db.query('users').whereLessThan('price', 100);
db.query('users').whereLessThanOrEqualTo('quantity', 10);

// 집합 및 범위
db.query('users').whereIn('id', ['id1', 'id2']);
db.query('users').whereNotIn('status', ['banned', 'pending']);
db.query('users').whereBetween('age', 18, 65);

// Null 확인
db.query('users').whereNull('deleted_at');
db.query('users').whereNotNull('email');

// 패턴 매칭
db.query('users').whereLike('name', '%John%');
db.query('users').whereNotLike('email', '%@temp.');
db.query('users').whereContains('bio', 'flutter');   // LIKE '%flutter%'
db.query('users').whereNotContains('title', 'draft');

// 다음과 동일함: .where('age', '>', 18).where('name', 'like', '%John%')
final users = await db.query('users')
    .whereGreaterThan('age', 18)
    .whereLike('username', '%John%')
    .orderByDesc('age')
    .limit(20);
```


<a id="distributed-architecture"></a>
## 분산 아키텍처

```dart
// 분산 노드 구성
final db = await ToStore.open(
  config: DataStoreConfig(
    distributedNodeConfig: const DistributedNodeConfig(
      enableDistributed: true,            // 분산 모드 활성화
      clusterId: 1,                       // 클러스터 ID
      centralServerUrl: 'https://127.0.0.1:8080',
      accessToken: 'b7628a4f9b4d269b98649129'
    )
  )
);

// 고성능 배치 삽입
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... 효율적인 대량 삽입
]);

// 대규모 데이터셋 스트리밍
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // 메모리 급증을 방지하기 위해 레코드를 순차적으로 처리합니다.
  print(record);
}
```


<a id="primary-key-examples"></a>
## 기본 키

ToStore는 다양한 시나리오를 위한 다채로운 분산 PK 알고리즘을 제공합니다:

- **순차 증분** (PrimaryKeyType.sequential): 238978991
- **타임스탬프 기반** (PrimaryKeyType.timestampBased): 1306866018836946
- **날짜 접두사** (PrimaryKeyType.datePrefixed): 20250530182215887631
- **단축 코드** (PrimaryKeyType.shortCode): 9eXrF0qeXZ

```dart
// 순차 PK 구성 예시
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,
        increment: 50,
        useRandomIncrement: true, // 비즈니스 지표 숨기기
      ),
    ),
    fields: [/* 필드 정의 */]
  ),
]);
```


<a id="atomic-expressions"></a>
## 원자적 표현식

표현식 시스템은 유형이 안전한 원자적 필드 업데이트를 제공합니다. 모든 계산은 동시성 충돌을 방지하기 위해 데이터베이스 레벨에서 수행됩니다:

```dart
// 단순 증분: balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// 복잡한 계산: total = price * quantity + tax
await db.update('orders', {
  'total': (Expr.field('price') * Expr.field('quantity')) + Expr.field('tax'),
}).where('id', '=', orderId);

// 중첩 괄호
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) * 
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// 함수: price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// 타임스탬프
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

**조건부 표현식 (예: Upsert 시)**: `Expr.isUpdate()` / `Expr.isInsert()`를 `Expr.ifElse` 또는 `Expr.when`과 함께 사용하여 업데이트 또는 삽입 중에만 실행되도록 설정합니다:

```dart
// Upsert: 업데이트 시 증분, 삽입 시 1로 설정
await db.upsert('counters', {
  'key': 'visits',
  'count': Expr.ifElse(
    Expr.isUpdate(),
    Expr.field('count') + Expr.value(1),
    1, // 삽입용: 리터럴 값, 평가는 무시됨
  ),
});

// Expr.when 사용
await db.upsert('orders', {
  'id': orderId,
  'updatedAt': Expr.when(Expr.isUpdate(), Expr.now(), otherwise: Expr.now()),
});
```


<a id="transactions"></a>
## 트랜잭션

트랜잭션은 원자성을 보장합니다. 모든 작업이 성공하거나 모두 롤백되어 절대적인 일관성을 유지합니다.

**트랜잭션 기능**:
- 다단계 작업의 원자적 커밋.
- 크래시 후 완료되지 않은 작업의 자동 복구.
- 커밋 성공 시 데이터가 안전하게 유지됩니다.

```dart
// 기본 트랜잭션
final txResult = await db.transaction(() async {
  // 사용자 삽입
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });
  
  // 표현식을 통한 원자적 업데이트
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');
  
  // 여기서 오류가 발생하면 모든 변경 사항이 자동으로 롤백됩니다.
});

if (txResult.isSuccess) {
  print('트랜잭션 커밋됨');
} else {
  print('트랜잭션 롤백됨: ${txResult.error?.message}');
}

// 예외 발생 시 자동 롤백
final txResult2 = await db.transaction(() async {
  await db.insert('users', {
    'username': 'jane',
    'email': 'jane@example.com',
  });
  throw Exception('비즈니스 로직 오류'); 
}, rollbackOnError: true);
```


<a id="error-handling"></a>
### 오류 처리

ToStore는 데이터 작업에 대해 통합된 응답 모델을 사용합니다:
- `ResultType`: 분기 로직을 위한 고정 상태 열거형.
- `result.code`: `ResultType`에 해당하는 숫자 코드.
- `result.message`: 읽기 쉬운 오류 설명.
- `successKeys` / `failedKeys`: 배치 작업의 기본 키 목록.

```dart
final result = await db.insert('users', {
  'username': 'john',
  'email': 'john@example.com',
});

if (!result.isSuccess) {
  switch (result.type) {
    case ResultType.notFound:
      print('리소스 없음: ${result.message}');
      break;
    case ResultType.notNullViolation:
    case ResultType.validationFailed:
      print('유효성 검사 실패: ${result.message}');
      break;
    case ResultType.uniqueViolation:
      print('충돌 발생: ${result.message}');
      break;
    default:
      print('코드: ${result.code}, 메시지: ${result.message}');
  }
}
```

**일반 상태 코드**:
성공은 0, 음수 값은 오류입니다.
- `ResultType.success` (0)
- `ResultType.partialSuccess` (1)
- `ResultType.uniqueViolation` (-2)
- `ResultType.primaryKeyViolation` (-3)
- `ResultType.foreignKeyViolation` (-4)
- `ResultType.notNullViolation` (-5)
- `ResultType.validationFailed` (-6)
- `ResultType.notFound` (-11)
- `ResultType.resourceExhausted` (-15)


### 순수 메모리 모드

데이터 캐싱 또는 디스크를 사용하지 않는 환경의 경우 `ToStore.memory()`를 사용하세요. 모든 데이터(스키마, 인덱스, KV)는 RAM 내에 보관됩니다.

**참고**: 앱 종료 또는 재시작 시 데이터가 손실됩니다.

```dart
// 인메모리 데이터베이스 초기화
final db = await ToStore.memory(schemas: []);

// 모든 작업이 거의 즉시 수행됨
await db.insert('temp_cache', {'key': 'session_1', 'value': 'admin'});
```


<a id="security-config"></a>
## 보안 구성

> [!WARNING]
> **키 관리**: **`encodingKey`**는 변경 가능하며 엔진이 데이터를 자동 마이그레이션합니다. **`encryptionKey`**는 매우 중요하며 마이그레이션 없이 변경하면 이전 데이터를 읽을 수 없습니다. 중요한 키를 하드코딩하지 마세요.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // 지원: none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305, 
      
      // 인코딩 키 (유연하며 데이터를 자동 마이그레이션함)
      encodingKey: 'Your-32-Byte-Long-Encoding-Key...', 
      
      // 암호화 키 (매우 중요, 마이그레이션 없이 변경 불가)
      encryptionKey: 'Your-Secure-Encryption-Key...',
      
      // 장치 바인딩 (경로 기반)
      // 키를 DB 경로 및 장치 특성과 바인딩합니다. 
      // DB 파일 이동 시 암호 해독을 방지합니다.
      deviceBinding: false, 
    ),
    enableJournal: true, // Write-Ahead Logging (WAL)
    persistRecoveryOnCommit: true, // 커밋 시 강제 플러시
  ),
);
```

### 필드 레벨 암호화 (ToCrypto)

전체 데이터베이스 암호화는 성능에 영향을 줄 수 있습니다. 특정 민감한 필드의 경우 **ToCrypto**를 사용하세요. DB 인스턴스가 필요 없는 독립 실행형 유틸리티로 Base64 출력을 사용하여 값을 인코딩/디코딩하므로 JSON 또는 TEXT 열에 이상적입니다.

```dart
const key = 'my-secret-key';
// 인코딩: 평문 -> Base64 암호문
final cipher = ToCrypto.encode('민감한 데이터', key: key);
// 디코딩
final plain = ToCrypto.decode(cipher, key: key);

// 선택 사항: AAD를 사용하여 컨텍스트를 바인딩 (디코딩 시 일치해야 함)
final aad = Uint8List.fromList(utf8.encode('users:id_number'));
final cipher2 = ToCrypto.encode('secret', key: key, aad: aad);
final plain2 = ToCrypto.decode(cipher2, key: key, aad: aad);
```


<a id="performance"></a>
## 성능

### 권장 사항
- 📱 **예제 프로젝트**: 전체 Flutter 앱 예제는 `example` 디렉토리를 참조하세요.
- 🚀 **실제 프로덕션**: 릴리스 모드에서의 성능은 디버그 모드를 훨씬 앞지릅니다.
- ✅ **표준화**: 모든 핵심 기능은 포괄적인 테스트 스위트로 지원됩니다.

### 벤치마크

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="ToStore 성능 데모" width="320" />
</p>

- **성능 시연**: 1억 개 이상의 레코드가 있어도 일반 모바일 기기에서 실행, 스크롤 및 검색이 매끄럽게 유지됩니다. ([비디오](https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4) 참조)

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="ToStore 재해 복구" width="320" />
</p>

- **재해 복구**: 고빈도 쓰기 도중 전원이 차단되거나 프로세스가 강제 종료되어도 ToStore는 신속하게 자동 복구됩니다. ([비디오](https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4) 참조)


ToStore가 도움이 되었다면 ⭐️를 눌러주세요! 오픈 소스에 대한 가장 큰 힘이 됩니다.

---

> **권장 사항**: 프런트엔드 개발에는 [ToApp 프레임워크](https://github.com/tocreator/toapp) 사용을 고려해 보세요. 데이터 요청, 로딩, 저장, 캐싱 및 상태 관리를 자동화하는 풀스택 솔루션을 제공합니다.


<a id="more-resources"></a>
## 리소스

- 📖 **문서**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **피드백**: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **토론**: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
