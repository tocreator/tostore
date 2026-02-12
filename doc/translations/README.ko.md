# Tostore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | 한국어 | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)


## 왜 Tostore를 선택해야 할까요?

Tostore는 Dart/Flutter 생태계에서 유일한 고성능 분산형 벡터 데이터베이스 스토리지 엔진입니다. 신경망 방식의 아키텍처를 채택하여 노드 간 지능형 상호 연결 및 협업이 가능하며, 무제한 노드 수평 확장을 지원하여 유연한 데이터 토폴로지 네트워크를 구축합니다. 정밀한 테이블 구조 변경 식별, 암호화 보호 및 멀티 스페이스 데이터 격리를 제공하며, 멀티코어 CPU를 충분히 활용하여 극한의 병렬 처리를 구현합니다. 모바일 에지 장치부터 클라우드까지의 크로스 플랫폼 협업을 기본적으로 지원하며, 다양한 분산 기본 키 알고리즘을 갖추고 있어 몰입형 가상 현실 융합, 멀티모달 상호 작용, 공간 컴퓨팅, 생성형 AI, 시맨틱 벡터 공간 모델링 등의 시나리오에 강력한 데이터 기반을 제공합니다.

생성형 AI와 공간 컴퓨팅이 계산의 중심을 에지로 이동시킴에 따라, 단말 장치는 단순한 콘텐츠 디스플레이에서 로컬 생성, 환경 인지 및 실시간 의사 결정의 핵심으로 진화하고 있습니다. 기존의 단일 파일 임베디드 데이터베이스는 아키텍처 설계상의 한계로 인해 높은 동시 쓰기, 대규모 벡터 검색 및 클라우드-에지 협업 생성과 같은 지능형 애플리케이션의 극한 응답 요구 사항을 지원하기 어려운 경우가 많습니다. Tostore는 에지 장치를 위해 태어났으며, 복잡한 AI 로컬 생성과 대규모 데이터 흐름을 지원하기에 충분한 분산 스토리지 기능을 에지 측에 부여하여 클라우드와 에지의 진정한 심층 협업을 실현합니다.

**정전 및 충돌에 강함**: 예기치 않은 정전이나 애플리케이션 충돌이 발생하더라도 데이터는 자동으로 복구되어 진정한 데이터 손실 제로를 실현합니다. 데이터 작업에 대한 응답이 있을 때 데이터는 이미 안전하게 저장되어 있으므로 데이터 손실 위험을 걱정할 필요가 없습니다.

**성능의 한계 돌파**: 실제 테스트 결과, 일반 스마트폰에서도 1억 건 이상의 데이터량에서도 일정한 검색 성능을 유지하며, 데이터 규모에 영향받지 않는 경험을 제공합니다. 기존 데이터베이스를 훨씬 능가하는 사용 경험을 제공합니다.




...... 손끝에서 클라우드 애플리케이션까지, Tostore는 데이터 연산력을 해방하고 미래를 지원합니다 ......




## Tostore의 특징

- 🌐 **모든 플랫폼 완벽 지원**
  - 모바일 앱부터 클라우드 서버까지, 하나의 코드로 모든 플랫폼에서 동작.
  - 플랫폼별 스토리지 백엔드(IndexedDB, 파일 시스템 등)에 지능적으로 적응.
  - 통합 API 인터페이스로 크로스 플랫폼 데이터 동기화 걱정 해결.
  - 에지 장치에서 클라우드 서버까지 원활한 데이터 흐름.
  - 에지 장치 로컬 벡터 계산을 통한 네트워크 지연 및 클라우드 의존성 감소.

- 🧠 **신경망 방식 분산 아키텍처**
  - 노드 간 상호 연결된 신경망형 토폴로지 구조로 효율적인 데이터 흐름 구성.
  - 고성능 데이터 파티셔닝 메커니즘을 통한 진정한 분산 처리 구현.
  - 지능형 동적 워크로드 밸런싱으로 리소스 활용 극대화.
  - 노드 무제한 수평 확장을 통해 복잡한 데이터 네트워크를 쉽게 구축.

- ⚡ **극한의 병렬 처리 능력**
  - Isolate를 통한 진정한 병렬 읽기/쓰기 구현, 멀티코어 CPU 최대 속도 가동.
  - 지능형 리소스 스케줄링으로 부하를 자동 분산하고 멀티코어 성능을 최대화.
  - 멀티 노드 컴퓨팅 네트워크의 협업을 통해 작업 처리 효율 배가.
  - 리소스 인식 스케줄링 프레임워크가 실행 계획을 자동 최적화하여 리소스 경합 방지.
  - 스트리밍 쿼리 인터페이스로 대규모 데이터 세트를 쉽게 처리.

- 🔑 **다양한 분산 기본 키 알고리즘**
  - 순차 증가 알고리즘 - 무작위 단계 길이를 자유롭게 조정하여 비즈니스 규모 은폐 가능.
  - 타임스탬프 기반 알고리즘 - 고동시성 시나리오를 위한 최적의 선택.
  - 날짜 접두사 알고리즘 - 시간 범위 데이터 표시 완벽 지원.
  - 단축 코드 알고리즘 - 짧고 읽기 쉬운 고유 식별자 생성.

- 🔄 **지능형 스키마 마이그레이션 및 데이터 무결성**
  - 테이블 필드 이름 변경을 정밀하게 식별하여 데이터 손실 제로 달성.
  - 밀리초 단위의 자동 스키마 변경 감지 및 데이터 마이그레이션 완료.
  - 서비스 중단 없는 업그레이드(Zero Downtime), 비즈니스 무중단 유지.
  - 복잡한 구조 변경에 대한 안전한 마이그레이션 전략 제공.
  - 외래 키 제약 조건 자동 검증 및 캐스케이드(연쇄) 작업 지원으로 참조 무결성 확보.

- 🛡️ **엔터프라이즈급 데이터 보안 및 지속성**
  - 이중 보호 메커니즘: 데이터 변경 사항을 실시간으로 기록하여 손실 방지.
  - 자동 충돌 복구: 예기치 않은 정전이나 충돌 후 완료되지 않은 작업을 자동 복구하여 데이터 손실 제로.
  - 데이터 일관성 보장: 여러 작업이 모두 성공하거나 모두 롤백되어 데이터 정확성 유지.
  - 원자적 계산 업데이트: 표현식(Expression) 시스템이 복잡한 계산을 원자적으로 실행하여 동시성 충돌 방지.
  - 즉각적인 안전 저장: 작업 성공 응답 시 데이터가 이미 안전하게 저장되어 대기 시간 불필요.
  - 고강도 ChaCha20Poly1305 암호화 알고리즘으로 민감한 데이터 보호.
  - 스토리지부터 전송까지 전 과정을 보호하는 엔드 투 엔드 암호화.

- 🚀 **지능형 캐싱 및 검색 성능**
  - 다계층 지능형 캐싱 메커니즘을 통한 초고속 데이터 검색.
  - 스토리지 엔진과 깊이 통합된 캐싱 전략.
  - 데이터 규모 증가에도 안정적인 성능을 유지하는 적응형 확장성.
  - 실시간 데이터 변경 알림 및 쿼리 결과 자동 업데이트.

- 🔄 **지능형 데이터 워크플로우**
  - 멀티 스페이스 아키텍처를 통한 데이터 격리 및 글로벌 공유 동시 지원.
  - 컴퓨팅 노드 간의 지능형 워크로드 분산.
  - 대규모 데이터 훈련 및 분석을 위한 견고한 기반 제공.


## 설치

> [!IMPORTANT]
> **v2.x에서 업그레이드하시겠습니까?** 중요한 마이그레이션 단계 및 주요 변경 사항은 [v3.0 업그레이드 가이드](../UPGRADE_GUIDE_v3.md)를 참조하세요.

`pubspec.yaml`에 `tostore` 의존성을 추가하세요:

```yaml
dependencies:
  tostore: any # 최신 버전을 사용해 주세요
```

## 빠른 시작

> [!IMPORTANT]
> **테이블 스키마 정의가 첫 번째 단계입니다**: CRUD 작업을 수행하기 전에 반드시 테이블 스키마를 정의해야 합니다. 구체적인 정의 방법은 시나리오에 따라 다릅니다:
> - **모바일/데스크톱**: [빈번한 시작 시나리오 통합](#빈번한 시작 시나리오-통합)(정적 정의)을 권장합니다.
> - **서버 측**: [서버 측 통합](#서버-측-통합)(동적 생성)을 권장합니다.

```dart
// 1. 데이터베이스 초기화
final db = await ToStore.open();

// 2. 데이터 삽입
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. 체인형 쿼리 ([쿼리 연산자](#쿼리-연산자) 참조, =, !=, >, <, LIKE, IN 등 지원)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// 4. 업데이트 및 삭제
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. 실시간 리스닝 (데이터 변경 시 UI 자동 갱신)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('조건에 맞는 사용자가 업데이트되었습니다: $users');
});
```

### 키-값 저장소 (KV)
구조화된 테이블을 정의할 필요가 없는 시나리오에 적합하며, 설정 정보나 상태 등 흩어진 데이터를 저장하기 위해 고성능 키-값 저장소가 내장되어 있습니다. 서로 다른 스페이스(Space)의 데이터는 본질적으로 격리되어 있으나 글로벌 공유 설정이 가능합니다.

```dart
// 1. 키-값 설정 (String, int, bool, double, Map, List 등 지원)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// 2. 데이터 가져오기
final theme = await db.getValue('theme'); // 'dark'

// 3. 데이터 삭제
await db.removeValue('theme');

// 4. 글로벌 키-값 (스페이스 간 공유)
// 기본적으로 키-값 데이터는 스페이스별로 독립적입니다. isGlobal: true를 사용하여 글로벌 공유가 가능합니다.
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```



## 빈번한 시작 시나리오 통합

📱 **예제**: [mobile_quickstart.dart](example/lib/mobile_quickstart.dart)

```dart
// 모바일 앱, 데스크톱 클라이언트 등 자주 실행되는 시나리오에 적합한 스키마 정의 방식
// 스키마 변경을 정밀하게 식별하고 자동 업그레이드 및 마이그레이션을 코드 없이 실현
final db = await ToStore.open(
  schemas: [
    const TableSchema(
            name: 'global_settings',
            isGlobal: true,  // 글로벌 테이블로 설정하여 모든 스페이스에서 접근 가능
            fields: [],
    ),
    const TableSchema(
      name: 'users', // 테이블 명
      tableId: "users",  // 이름 변경을 100% 식별하기 위한 고유 식별자(선택 사항)
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id',       // 기본 키 이름
      ),
      fields: [        // 필드 정의(기본 키 제외)
        FieldSchema(
          name: 'username', 
          type: DataType.text, 
          nullable: false, 
          unique: true, // 자동으로 고유 인덱스 생성
          fieldId: 'username',  // 필드 고유 식별자(선택 사항)
        ),
        FieldSchema(
          name: 'email', 
          type: DataType.text, 
          nullable: false, 
          unique: true // 자동으로 고유 인덱스 생성
        ),
        FieldSchema(
          name: 'last_login', 
          type: DataType.datetime,
          createIndex: true // 자동으로 인덱스 생성
        ),
      ],
      // 복합 인덱스 예시
      indexes: [
        IndexSchema(fields: ['username', 'last_login']),
      ],
    ),
    // 외래 키 제약 조건 정의 예시
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
          fields: ['user_id'],              // 현재 테이블의 필드
          referencedTable: 'users',         // 참조하는 테이블
          referencedFields: ['id'],         // 참조하는 필드
          onDelete: ForeignKeyCascadeAction.cascade,  // 삭제 시 연쇄 삭제
          onUpdate: ForeignKeyCascadeAction.cascade,  // 업데이트 시 연쇄 업데이트
        ),
      ],
    ),
  ],
);

// 멀티 스페이스 아키텍처 - 사용자별 데이터 완벽 격리
await db.switchSpace(spaceName: 'user_123');
```

### 로그인 상태 유지 및 로그아웃(활성 공간)

멀티 스페이스는 **사용자별 데이터** 분리에 적합합니다. 사용자당 하나의 공간을 두고 로그인 시 전환합니다. **활성 공간**과 **close 옵션**으로 앱 재시작 후에도 현재 사용자를 유지하고 로그아웃을 지원할 수 있습니다.

- **로그인 상태 유지**: 사용자가 자신의 공간으로 전환한 후 해당 공간을 활성 공간으로 저장하면, 다음 실행 시 default로 열면 해당 공간으로 바로 들어갑니다(「default로 연 뒤 전환」 불필요).
- **로그아웃**: 로그아웃 시 `keepActiveSpace: false`로 데이터베이스를 닫으면 다음 실행 시 이전 사용자 공간이 자동으로 열리지 않습니다.

```dart

// 로그인 후: 해당 사용자 공간으로 전환하고 다음 실행을 위해 기억(로그인 상태 유지)
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// 선택: default로만 엄격히 열 때(예: 로그인 화면만) — 저장된 활성 공간 사용 안 함
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// 로그아웃 시: 닫고 활성 공간을 지워 다음 실행은 default 공간
await db.close(keepActiveSpace: false);
```

## 서버 측 통합

🖥️ **예제**: [server_quickstart.dart](example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// 실행 시 스키마 일괄 생성 - 지속 실행 시나리오에 적합
await db.createTables([
  // 3차원 공간 특징 벡터 저장 테이블
  const TableSchema(
    name: 'spatial_embeddings',
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.timestampBased,   // 고동시성 쓰기에 적합한 타임스탬프 기반 PK
    ),
    fields: [
      FieldSchema(
        name: 'video_name',
        type: DataType.text,
        nullable: false,
      ),
      FieldSchema(
        name: 'spatial_features',
        type: DataType.vector,                // 벡터 저장 유형
        vectorConfig: VectorFieldConfig(
          dimensions: 1024,                   // 고차원 벡터
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
        type: IndexType.vector,              // 벡터 인덱스
        fields: ['spatial_features'],
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh,   // 효율적인 근접 검색을 위한 NGH 알고리즘
          distanceMetric: VectorDistanceMetric.cosine,
          parameters: {
            'M': 16,
            'efConstruction': 200,
          },
        ),
      ),
    ],
  ),
  // 기타 테이블...
]);

// 온라인 스키마 업데이트 - 비즈니스 중단 없음
final taskId = await db.updateSchema('users')
  .renameTable('users_new')                // 테이블 이름 변경
  .modifyField(
    'username',
    minLength: 5,
    maxLength: 20,
    unique: true
  )                                        // 필드 속성 변경
  .renameField('old_name', 'new_name')     // 필드 이름 변경
  .removeField('deprecated_field')         // 필드 삭제
  .addField('created_at', type: DataType.datetime)  // 필드 추가
  .removeIndex(fields: ['age'])            // 인덱스 삭제
  .setPrimaryKeyConfig(                    // 기본 키 구성 변경
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
    
// 마이그레이션 진행 상태 모니터링
final status = await db.queryMigrationTaskStatus(taskId);
print('마이그레이션 진행률: ${status?.progressPercentage}%');


// 수동 쿼리 캐시 관리 (서버 측)
// 기본 키 및 인덱스 기반의 등치 조회, IN 조회의 경우, 엔진 성능이 매우 뛰어나고 최적화되어 있으므로 일반적으로 수동으로 쿼리 캐시를 관리할 필요가 없습니다.

// 쿼리 결과를 5분간 수동으로 캐시.
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// 데이터 변경 시 특정 캐시를 무효화하여 일관성 보장.
await db.query('users')
    .where('is_active', '=', true)
    .clearQueryCache();

// 최신 데이터가 반드시 필요한 쿼리는 캐시를 명시적으로 비활성화.
final freshUserData = await db.query('users')
    .where('is_active', '=', true)
    .noQueryCache();
```



## 고급 사용법

Tostore는 복잡한 비즈니스 요구 사항을 충족하기 위해 다양한 고급 기능을 제공합니다:

### 복잡한 쿼리 중첩 및 맞춤형 필터링
무제한 조건 중첩과 유연한 맞춤형 함수를 지원합니다.

```dart
// 조건 중첩: (type = 'app' OR (id >= 123 OR fans >= 200))
final idCondition = QueryCondition().where('id', '>=', 123).or().where('fans', '>=', 200);

final result = await db.query('users')
    .condition(
        QueryCondition().whereEqual('type', 'app').or().condition(idCondition)
    )
    .limit(20);

// 맞춤형 조건 함수
final customResult = await db.query('users')
    .whereCustom((record) => record['tags']?.contains('추천') ?? false);
```

### 지능형 업서트 (Upsert)
존재하면 업데이트하고, 존재하지 않으면 삽입합니다.

```dart
// By primary key or unique key in data (no where)
final result = await db.upsert('users', {'id': 1, 'username': 'john', 'email': 'john@example.com'});
await db.upsert('users', {'username': 'john', 'email': 'john@example.com', 'age': 26});
// Batch upsert
await db.batchUpsert('users', [
  {'username': 'a', 'email': 'a@example.com'},
  {'username': 'b', 'email': 'b@example.com'},
], allowPartialErrors: true);
```


### 테이블 조인 및 필드 선택
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000)
    .limit(20);
```

### 스트리밍 및 통계
```dart
// 레코드 수 집계
final count = await db.query('users').count();

// 스트리밍 쿼리 (대규모 데이터에 적합)
db.streamQuery('users').listen((data) => print(data));
```



### 쿼리 및 효율적인 페이지네이션

> [!TIP]
> **최고의 성능을 위해 `limit`을 명시하세요**: 쿼리 시 항상 `limit`을 명시적으로 지정하는 것을 강력히 권장합니다. 생략하면 엔진은 기본적으로 1000개의 레코드로 제한합니다. 엔진 자체의 쿼리 속도는 매우 빠르지만, UI에 민감한 애플리케이션에서 대량의 레코드를 직렬화하면 불필요한 성능 오버헤드가 발생할 수 있습니다.

Tostore는 데이터 규모와 성능 요구 사항에 따라 선택할 수 있는 두 가지 페이지네이션 모드를 제공합니다:

#### 1. 오프셋 모드 (Offset Mode)
데이터 양이 적거나(예: 1만 건 이하) 특정 페이지 번호로 정확하게 이동해야 하는 경우에 적합합니다.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // 처음 40개를 건너뜀
    .limit(20); // 20개 가져옴
```
> [!TIP]
> `offset`이 매우 클 경우 데이터베이스가 많은 레코드를 스캔하고 버려야 하므로 성능이 저하됩니다. 깊은 페이지네이션에는 **커서 모드**를 권장합니다.

#### 2. 고성능 커서 모드 (Cursor Mode)
**대규모 데이터 및 무한 스크롤 시나리오에 권장됩니다**. `nextCursor`를 사용하여 O(1) 수준의 성능을 구현하며, 페이지 수에 관계없이 일정한 쿼리 속도를 보장합니다.

> [!IMPORTANT]
> 인덱싱되지 않은 필드로 정렬하거나 일부 복잡한 쿼리의 경우, 엔진이 전체 테이블 스캔으로 전환하고 `null` 커서를 반환할 수 있습니다(즉, 해당 특정 쿼리에 대한 페이지네이션이 현재 지원되지 않음을 의미함).

```dart
// 1페이지 쿼리
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// 반환된 커서를 사용하여 다음 페이지 조회
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // 커서 위치로 직접 seek
}

// 마찬가지로 prevCursor를 사용하여 이전 페이지로 효율적으로 이동
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| 기능 | 오프셋 모드 | 커서 모드 |
| :--- | :--- | :--- |
| **쿼리 성능** | 페이지가 증가할수록 저하 | **항상 일정 (O(1))** |
| **적용 범위** | 적은 데이터, 페이지 이동 | **대규모 데이터, 무한 스크롤** |
| **데이터 일관성** | 데이터 변경 시 누락 발생 가능 | **변경으로 인한 중복/누락 완벽 방지** |



### 쿼리 연산자

`where(field, operator, value)` 조건에서 사용 가능한 연산자(대소문자 무시)는 다음과 같습니다.

| Operator | Description | Example / Value type |
| :--- | :--- | :--- |
| `=` | Equal | `where('status', '=', 'active')` |
| `!=`, `<>` | Not equal | `where('role', '!=', 'guest')` |
| `>` | Greater than | `where('age', '>', 18)` |
| `>=` | Greater than or equal | `where('score', '>=', 60)` |
| `<` | Less than | `where('price', '<', 100)` |
| `<=` | Less than or equal | `where('quantity', '<=', 10)` |
| `IN` | Value in list | `where('id', 'IN', ['a','b','c'])` — value: `List` |
| `NOT IN` | Value not in list | `where('status', 'NOT IN', ['banned'])` — value: `List` |
| `BETWEEN` | Between start and end (inclusive) | `where('age', 'BETWEEN', [18, 65])` — value: `[start, end]` |
| `LIKE` | Pattern match (`%` any, `_` single char) | `where('name', 'LIKE', '%John%')` — value: `String` |
| `NOT LIKE` | Pattern not match | `where('email', 'NOT LIKE', '%@test.com')` — value: `String` |
| `IS` | Is null | `where('deleted_at', 'IS', null)` — value: `null` |
| `IS NOT` | Is not null | `where('email', 'IS NOT', null)` — value: `null` |

### 시맨틱 쿼리 메서드 (권장)

연산자 문자열 대신 시맨틱 메서드를 사용하면 IDE 지원이 좋아집니다.

```dart
// Comparison
db.query('users').whereEqual('username', 'John');
db.query('users').whereNotEqual('role', 'guest');
db.query('users').whereGreaterThan('age', 18);
db.query('users').whereGreaterThanOrEqualTo('score', 60);
db.query('users').whereLessThan('price', 100);
db.query('users').whereLessThanOrEqualTo('quantity', 10);

// Membership & range
db.query('users').whereIn('id', ['id1', 'id2']);
db.query('users').whereNotIn('status', ['banned', 'pending']);
db.query('users').whereBetween('age', 18, 65);

// Null checks
db.query('users').whereNull('deleted_at');
db.query('users').whereNotNull('email');

// Pattern match
db.query('users').whereLike('name', '%John%');
db.query('users').whereNotLike('email', '%@temp.');
db.query('users').whereContains('bio', 'flutter');   // LIKE '%flutter%'
db.query('users').whereNotContains('title', 'draft');

// Equivalent to: .where('age', '>', 18).where('name', 'like', '%John%')
final users = await db.query('users')
    .whereGreaterThan('age', 18)
    .whereLike('username', '%John%')
    .orderByDesc('age')
    .limit(20);
```

## 분산 아키텍처

```dart
// 분산 노드 구성
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

// 고성능 일괄 삽입
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... 대량의 레코드를 한 번에 효율적으로 삽입
]);

// 대규모 데이터 세트 스트리밍 처리 - 일정한 메모리 사용량 유지
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // TB급 데이터도 메모리 부담 없이 효율적으로 처리 가능
  print(record);
}
```

## 기본 키 유형 예시

Tostore는 다양한 비즈니스 시나리오를 지원하기 위해 여러 분산 기본 키 알고리즘을 제공합니다:

- **순차 증가형** (PrimaryKeyType.sequential): 238978991
- **타임스탬프 기반** (PrimaryKeyType.timestampBased): 1306866018836946
- **날짜 접두사형** (PrimaryKeyType.datePrefixed): 20250530182215887631
- **단축 코드형** (PrimaryKeyType.shortCode): 9eXrF0qeXZ

```dart
// 순차 증가형 기본 키 구성 예시
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,
        increment: 50,
        useRandomIncrement: true, // 무작위 증분으로 비즈니스 규모 은폐
      ),
    ),
    fields: [/* 필드 정의 */]
  ),
]);
```


## 표현식 원자적 작업

표현식 시스템은 유형 안전한 원자적 필드 업데이트를 제공합니다. 모든 계산은 데이터베이스 계층에서 원자적으로 실행되어 동시성 충돌을 방지합니다:

```dart
// 단순 증감: balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// 복잡한 계산: total = price * quantity + tax
await db.update('orders', {
  'total': Expr.field('price') * Expr.field('quantity') + Expr.field('tax'),
}).where('id', '=', orderId);

// 다중 괄호: finalPrice = ((price * quantity) + tax) * (1 - discount)
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) * 
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// 함수 사용: price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// 타임스탬프: updatedAt = now()
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

## 트랜잭션 작업

트랜잭션은 여러 작업의 원자성을 보장하며, 모든 작업이 성공하거나 모두 롤백되어 데이터 일관성을 유지합니다.

**트랜잭션 특징**:
- 여러 작업의 원자적 제출.
- 충돌 발생 시 완료되지 않은 작업 자동 복구.
- 성공적인 커밋 시 데이터가 안전하게 영구 저장됨.

```dart
// 기본 트랜잭션 - 여러 작업 원자적 커밋
final txResult = await db.transaction(() async {
  // 사용자 삽입
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });
  
  // 표현식을 사용한 원자적 업데이트
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');
  
  // 실패 시 모든 변경 사항이 자동으로 롤백됨
});

if (txResult.isSuccess) {
  print('트랜잭션 커밋 성공');
} else {
  print('트랜잭션 롤백: ${txResult.error?.message}');
}

// 오류 발생 시 자동 롤백
final txResult2 = await db.transaction(() async {
  await db.insert('users', {
    'username': 'jane',
    'email': 'jane@example.com',
  });
  throw Exception('비즈니스 로직 오류'); // 롤백 트리거
}, rollbackOnError: true);
```

## 보안 구성

**데이터 보안 메커니즈**:
- 이중 보호 메커니즘으로 데이터 유실 방지.
- 충돌 시 완료되지 않은 작업 자동 복구.
- 작업 성공 시 데이터 즉시 안전 저장.
- 고강도 암호화 알고리즘으로 민감한 데이터 보호.

> [!WARNING]
> **키 관리**: **`encodingKey`** 는 자유롭게 변경할 수 있으며, 변경 시 엔진이 데이터를 자동으로 마이그레이션하므로 데이터 손실을 걱정하지 않아도 됩니다. **`encryptionKey`** 는 임의로 변경하면 안 됩니다. 변경 시 기존 데이터를 해독할 수 없게 됩니다(마이그레이션 제외). 보안 서버 등에서 키를 가져오고 코드에 하드코딩하지 않는 것이 좋습니다.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // 지원 알고리즘: none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305, 
      
      // 인코딩 키 (자유롭게 변경 가능, 변경 시 데이터 자동 마이그레이션)
      encodingKey: 'Your-32-Byte-Long-Encoding-Key...', 
      
      // 중요 데이터 암호화 키 (임의 변경 불가, 변경 시 기존 데이터 해독 불가, 마이그레이션 제외)
      encryptionKey: 'Your-Secure-Encryption-Key...',
      
      // 장치 결합 (Path-based binding)
      // 활성화 시 키가 데이터베이스 경로 및 장치 특징과 깊이 결합됩니다.
      // 물리적 데이터베이스 파일 복제 보안을 강화하지만, 설치 경로 변경 시 데이터 복구가 어려울 수 있습니다.
      deviceBinding: false, 
    ),
    // WAL (Write-Ahead Logging) 활성화 (기본값: 활성화)
    enableJournal: true, 
    // 커밋 시 디스크 강제 동기화 (성능 중시형은 false 설정 가능)
    persistRecoveryOnCommit: true,
  ),
);
```

### 값 수준 암호화 (ToCrypto)

위의 전체 데이터베이스 암호화는 모든 테이블과 인덱스 데이터를 암호화하여 전체 성능에 영향을 줄 수 있습니다. 민감한 필드만 암호화하려면 **ToCrypto**를 사용하세요. 데이터베이스와 독립적이며(db 인스턴스 불필요), 쓰기 전이나 읽은 후에 값을 직접 인코드/디코드합니다. 키는 앱에서 완전히 관리합니다. 출력은 Base64이며 JSON 또는 TEXT 열에 저장하기 적합합니다.

- **key** (필수): `String` 또는 `Uint8List`. 32바이트가 아니면 SHA-256으로 32바이트를 파생합니다.
- **type** (선택): 암호화 타입 [ToCryptoType]: [ToCryptoType.chacha20Poly1305] 또는 [ToCryptoType.aes256Gcm]. 기본값 [ToCryptoType.chacha20Poly1305]. 생략 시 기본값 사용.
- **aad** (선택): 추가 인증 데이터, `Uint8List`. 인코드 시 전달한 경우 디코드 시에도 동일한 바이트를 전달해야 합니다(예: 테이블명+필드명으로 컨텍스트 바인딩). 간단한 사용 시 생략 가능합니다.

```dart
const key = 'my-secret-key';
// 인코드: 평문 → Base64 암문 (DB 또는 JSON에 저장)
final cipher = ToCrypto.encode('sensitive data', key: key);
// 읽을 때 디코드
final plain = ToCrypto.decode(cipher, key: key);

// 선택: aad로 컨텍스트 바인딩 (인코드·디코드 시 동일한 aad 사용)
final aad = Uint8List.fromList(utf8.encode('users:id_number'));
final cipher2 = ToCrypto.encode('secret', key: key, aad: aad);
final plain2 = ToCrypto.decode(cipher2, key: key, aad: aad);
```

## 성능 및 경험

### 성능 지표

- **시작 속도**: 1억 건의 데이터량에서도 일반 스마트폰에서 즉시 시작 및 데이터 표시.
- **조회 성능**: 데이터 규모에 관계없이 항상 초고속 검색 성능 유지.
- **데이터 안전**: ACID 트랜잭션 보장 + 충돌 복구로 데이터 손실 제로.

### 조언 및 제안

- 📱 **예제 프로젝트**: `example` 디렉터리에 전체 Flutter 앱 예제가 제공됩니다.
- 🚀 **프로덕션 환경**: 성능이 월등한 Release 모드로 빌드하여 배포하는 것을 권장합니다.
- ✅ **표준 테스트**: 모든 핵심 기능은 표준 통합 테스트를 통과했습니다.

### 데모 영상

<p align="center">
  <img src="../media/basic-demo.gif" alt="Tostore 기본 성능 데모" width="320" />
  </p>

- **기본 성능 데모** (<a href="../media/basic-demo.mp4?raw=1" target="_blank" rel="noopener">basic-demo.mp4</a>): GIF 미리보기는 일부가 잘려 보일 수 있습니다. 전체 데모는 영상을 클릭해 확인하세요. 일반적인 스마트폰에서 데이터가 1억 건 이상인 상황에서도 앱의 시작 속도, 페이지 이동, 검색 성능이 항상 안정적이고 부드럽게 유지되는 모습을 확인할 수 있습니다. 저장 용량만 충분하다면, 에지 디바이스에서도 TB/PB 규모의 데이터셋을 다루면서도 상호작용 지연을 일관되게 낮게 유지할 수 있습니다.

<p align="center">
  <img src="../media/disaster-recovery.gif" alt="Tostore 재해 복구 스트레스 테스트" width="320" />
  </p>
  
- **재해 복구 스트레스 테스트** (<a href="../media/disaster-recovery.mp4?raw=1" target="_blank" rel="noopener">disaster-recovery.mp4</a>): 집약적인 쓰기 작업 도중에 프로세스를 의도적으로 반복 종료하여 충돌 및 정전 상황을 시뮬레이션합니다. 수만 건에 이르는 쓰기 작업이 중간에 끊기더라도, Tostore는 일반적인 스마트폰에서 매우 빠르게 자체 복구를 완료하며, 이후 앱 시작이나 데이터 가용성에 영향을 주지 않습니다.




Tostore가 도움이 되었다면 ⭐️를 눌러주세요.




## 향후 계획

Tostore는 AI 시대의 데이터 인프라 역량을 강화하기 위해 다음 기능을 적극적으로 개발하고 있습니다:

- **고차원 벡터**: 벡터 검색 및 시맨틱 검색 알고리즘 고도화.
- **멀티모달 데이터**: 원시 데이터부터 특징 벡터까지의 엔드 투 엔드 처리 지원.
- **그래프 구조**: 지식 그래프 및 복잡한 관계망의 효율적인 저장과 조회.





> **추천**: 모바일 개발자라면 데이터 요청, 로딩, 저장, 캐시 및 표시를 자동으로 처리하는 풀스택 솔루션 [Toway Framework](https://github.com/tocreator/toway) 사용을 고려해 보세요.




## 더 많은 리소스

- 📖 **문서**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **피드백**: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **토론**: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)


## 라이선스

이 프로젝트는 MIT 라이선스를 따릅니다 - 자세한 내용은 [LICENSE](LICENSE) 파일을 참조하세요.

---
