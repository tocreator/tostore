# Tostore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | 한국어 | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![Build Status](https://github.com/tocreator/tostore/workflows/build/badge.svg)](https://github.com/tocreator/tostore/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

Tostore는 프로젝트에 깊이 통합된, 크로스 플랫폼 분산 아키텍처 데이터베이스 엔진입니다. 뉴럴 네트워크에서 영감을 받은 데이터 처리 모델은 뇌와 유사한 데이터 관리를 구현합니다. 다중 파티션 병렬 처리 메커니즘과 노드 상호 연결 토폴로지는 지능형 데이터 네트워크를 구축하는 한편, Isolate를 이용한 병렬 처리는 멀티코어 성능을 최대한 활용합니다. 다양한 분산 기본 키 알고리즘과 무제한 노드 확장으로 분산 컴퓨팅 인프라와 대규모 데이터 훈련을 위한 데이터 레이어 역할을 할 수 있으며, 엣지 디바이스에서 클라우드 서버까지 끊김 없는 데이터 흐름을 가능하게 합니다. 정확한 스키마 변경 감지, 지능형 마이그레이션, ChaCha20Poly1305 암호화, 다중 공간 아키텍처와 같은 기능들은 모바일 앱부터 서버 사이드 시스템까지 다양한 응용 시나리오를 완벽하게 지원합니다.

## Tostore를 선택해야 하는 이유?

### 1. 파티션 병렬 처리 vs. 단일 파일 저장
| Tostore | 전통적인 데이터베이스 |
|:---------|:-----------|
| ✅ 지능형 파티셔닝 엔진, 데이터를 적절한 크기의 여러 파일로 분산 | ❌ 단일 데이터 파일에 저장, 데이터 증가에 따른 선형적 성능 저하 |
| ✅ 관련 파티션 파일만 읽음, 전체 데이터 볼륨과 분리된 쿼리 성능 | ❌ 단일 레코드 쿼리에도 전체 데이터 파일 로드 필요 |
| ✅ TB급 데이터 볼륨에서도 밀리초 단위 응답 시간 유지 | ❌ 모바일 기기에서 데이터가 5MB를 초과할 경우 읽기/쓰기 지연 시간 크게 증가 |
| ✅ 총 데이터 볼륨이 아닌 조회된 데이터 양에 비례하는 자원 소비 | ❌ 제한된 자원을 가진 기기는 메모리 압박과 OOM 오류에 취약 |
| ✅ Isolate 기술로 진정한 멀티코어 병렬 처리 가능 | ❌ 단일 파일은 병렬 처리할 수 없어 CPU 자원 낭비 |

### 2. 임베디드 통합 vs. 독립 데이터 저장소
| Tostore | 전통적인 데이터베이스 |
|:---------|:-----------|
| ✅ Dart 언어 사용, Flutter/Dart 프로젝트와 완벽하게 통합 | ❌ SQL 또는 특정 쿼리 언어 학습 필요, 학습 곡선 증가 |
| ✅ 동일한 코드가 프론트엔드와 백엔드 지원, 기술 스택 전환 불필요 | ❌ 프론트엔드와 백엔드에 종종 다른 데이터베이스와 접근 방식 필요 |
| ✅ 현대적 프로그래밍 스타일에 맞는 체인 API 스타일, 뛰어난 개발자 경험 | ❌ SQL 문자열 연결은 공격과 오류에 취약, 타입 안전성 부족 |
| ✅ 반응형 프로그래밍 지원, UI 프레임워크와 자연스럽게 결합 | ❌ UI와 데이터 레이어를 연결하기 위한 추가 어댑터 레이어 필요 |
| ✅ 복잡한 ORM 매핑 설정 불필요, Dart 객체 직접 사용 | ❌ 객체-관계형 매핑 복잡성, 높은 개발 및 유지 관리 비용 |

### 3. 정확한 스키마 변경 감지 vs. 수동 마이그레이션 관리
| Tostore | 전통적인 데이터베이스 |
|:---------|:-----------|
| ✅ 자동으로 스키마 변경 감지, 버전 번호 관리 불필요 | ❌ 수동 버전 제어 및 명시적 마이그레이션 코드 의존 |
| ✅ 밀리초 수준의 테이블/필드 변경 감지 및 자동 데이터 마이그레이션 | ❌ 버전 간 업데이트를 위한 마이그레이션 로직 유지 필요 |
| ✅ 테이블/필드 이름 변경 정확히 식별, 모든 히스토리 데이터 보존 | ❌ 테이블/필드 이름 변경은 데이터 손실 초래 가능 |
| ✅ 데이터 일관성을 보장하는 원자적 마이그레이션 작업 | ❌ 마이그레이션 중단은 데이터 불일치 초래 가능 |
| ✅ 수동 개입 없는 완전 자동화된 스키마 업데이트 | ❌ 복잡한 업데이트 로직, 버전 증가에 따른 높은 유지 관리 비용 |

### 4. 다중 공간 아키텍처 vs. 단일 저장 공간
| Tostore | 전통적인 데이터베이스 |
|:---------|:-----------|
| ✅ 다중 공간 아키텍처, 다른 사용자의 데이터 완벽히 격리 | ❌ 단일 저장 공간, 여러 사용자의 데이터 혼합 저장 |
| ✅ 한 줄의 코드로 공간 전환, 간단하고 효과적 | ❌ 여러 데이터베이스 인스턴스 또는 복잡한 격리 로직 필요 |
| ✅ 유연한 공간 격리 메커니즘 및 글로벌 데이터 공유 | ❌ 사용자 데이터 격리와 공유 간의 균형 유지 어려움 |
| ✅ 공간 간 데이터 복사 또는 마이그레이션을 위한 간단한 API | ❌ 테넌트 마이그레이션 또는 데이터 복사를 위한 복잡한 작업 |
| ✅ 쿼리가 자동으로 현재 공간으로 제한, 추가 필터링 불필요 | ❌ 다른 사용자에 대한 쿼리는 복잡한 필터링 필요 |





## 기술적 하이라이트

- 🌐 **투명한 크로스 플랫폼 지원**:
  - 웹, Linux, Windows, 모바일, Mac 플랫폼에서 일관된 경험
  - 통합 API 인터페이스, 번거로움 없는 크로스 플랫폼 데이터 동기화
  - 다양한 크로스 플랫폼 스토리지 백엔드(IndexedDB, 파일 시스템 등)에 자동 적응
  - 엣지 컴퓨팅에서 클라우드까지 끊김 없는 데이터 흐름

- 🧠 **뉴럴 네트워크에서 영감을 받은 분산 아키텍처**:
  - 상호 연결된 노드의 뉴럴 네트워크 같은 토폴로지
  - 분산 처리를 위한 효율적인 데이터 파티셔닝 엔진
  - 동적 지능형 워크로드 밸런싱
  - 무제한 노드 확장 지원, 복잡한 데이터 네트워크 구축 용이

- ⚡ **결정적인 병렬 처리 능력**:
  - Isolate를 이용한 진정한 병렬 읽기/쓰기, 멀티코어 CPU 완전 활용
  - 다중 작업 효율성 증대를 위해 협력하는 다중 노드 컴퓨팅 네트워크
  - 자원 인식 분산 처리 프레임워크, 자동 성능 최적화
  - 대규모 데이터셋 처리에 최적화된 스트리밍 쿼리 인터페이스

- 🔑 **다양한 분산 기본 키 알고리즘**:
  - 순차적 증가 알고리즘 - 자유롭게 조정 가능한 무작위 스텝 길이
  - 타임스탬프 기반 알고리즘 - 고성능 병렬 실행 시나리오에 이상적
  - 날짜 접두사 알고리즘 - 시간 범위 표시가 있는 데이터에 적합
  - 짧은 코드 알고리즘 - 간결한 고유 식별자

- 🔄 **지능형 스키마 마이그레이션**:
  - 테이블/필드 이름 변경 동작 정확히 식별
  - 스키마 변경 중 자동 데이터 업데이트 및 마이그레이션
  - 다운타임 없는 업데이트, 비즈니스 운영에 영향 없음
  - 데이터 손실 방지하는 안전한 마이그레이션 전략

- 🛡️ **엔터프라이즈급 보안**:
  - 민감한 데이터 보호를 위한 ChaCha20Poly1305 암호화 알고리즘
  - 저장 및 전송 데이터 보안 보장하는 엔드투엔드 암호화
  - 세분화된 데이터 접근 제어

- 🚀 **지능형 캐싱 및 검색 성능**:
  - 효율적인 데이터 검색을 위한 다중 레벨 지능형 캐시 엔진
  - 앱 시작 속도를 크게 향상시키는 부팅 캐시
  - 캐시와 깊이 통합된 스토리지 엔진, 추가 동기화 코드 불필요
  - 증가하는 데이터에도 안정적 성능 유지하는 적응형 스케일링

- 🔄 **혁신적인 워크플로우**:
  - 다중 공간 데이터 격리, 다중 테넌트, 다중 사용자 시나리오 완벽 지원
  - 컴퓨팅 노드 간 지능형 워크로드 할당
  - 대규모 데이터 훈련 및 분석을 위한 견고한 데이터베이스 제공
  - 자동 데이터 저장, 지능형 업데이트 및 삽입

- 💼 **개발자 경험 우선**:
  - 상세한 이중 언어 문서 및 코드 주석(중국어 및 영어)
  - 풍부한 디버깅 정보 및 성능 지표
  - 내장된 데이터 검증 및 손상 복구 기능
  - 즉시 사용 가능한 제로 구성, 빠른 시작

## 빠른 시작

기본 사용법:

```dart
// 데이터베이스 초기화
final db = ToStore();
await db.initialize(); // 선택 사항, 작업 전 데이터베이스 초기화 완료 보장

// 데이터 삽입
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
});

// 데이터 업데이트
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// 데이터 삭제
await db.delete('users').where('id', '!=', 1);

// 복잡한 체인 쿼리 지원
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// 자동 데이터 저장, 존재하면 업데이트, 없으면 삽입
await db.upsert('users', {'name': 'John','email': 'john@example.com'})
  .where('email', '=', 'john@example.com');
// 또는
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});

// 효율적인 레코드 카운트
final count = await db.query('users').count();

// 스트리밍 쿼리를 사용한 대규모 데이터 처리
db.streamQuery('users')
  .where('email', 'like', '%@example.com')
  .listen((userData) {
    // 메모리 압박 없이 필요에 따라 각 레코드 처리
    print('사용자 처리 중: ${userData['username']}');
  });

// 글로벌 키-값 쌍 설정
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// 글로벌 키-값 쌍 데이터 가져오기
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```

## 모바일 앱 예제

```dart
// 모바일 앱과 같은 빈번한 시작 시나리오에 적합한 테이블 구조 정의, 정확한 테이블 구조 변경 감지, 자동 데이터 업데이트 및 마이그레이션
final db = ToStore(
  schemas: [
    const TableSchema(
      name: 'users', // 테이블 이름
      tableId: "users",  // 선택적 고유 테이블 식별자, 이름 변경 요구사항의 100% 식별에 사용, 없어도 >98% 정확도 달성 가능
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id', // 기본 키
      ),
      fields: [ // 필드 정의, 기본 키 포함하지 않음
        FieldSchema(name: 'username', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'email', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'last_login', type: DataType.datetime),
      ],
      indexes: [ // 인덱스 정의
        IndexSchema(fields: ['username']),
        IndexSchema(fields: ['email']),
      ],
    ),
  ],
);

// 사용자 공간으로 전환 - 데이터 격리
await db.switchSpace(spaceName: 'user_123');
```

## 백엔드 서버 예제

```dart
await db.createTables([
      const TableSchema(
        name: 'users', // 테이블 이름
        primaryKeyConfig: PrimaryKeyConfig(
          name: 'id', // 기본 키
          type: PrimaryKeyType.timestampBased,  // 기본 키 유형
        ),
        fields: [
          // 필드 정의, 기본 키 포함하지 않음
          FieldSchema(
              name: 'username',
              type: DataType.text,
              nullable: false,
              unique: true),
          FieldSchema(name: 'vector_data', type: DataType.blob),  // 벡터 데이터 저장
          // 기타 필드...
        ],
        indexes: [
          // 인덱스 정의
          IndexSchema(fields: ['username']),
          IndexSchema(fields: ['email']),
        ],
      ),
      // 다른 테이블...
]);


// 테이블 구조 업데이트
final taskId = await db.updateSchema('users')
    .renameTable('newTableName')  // 테이블 이름 변경
    .modifyField('username',minLength: 5,maxLength: 20,unique: true)  // 필드 속성 수정
    .renameField('oldName', 'newName')  // 필드 이름 변경
    .removeField('fieldName')  // 필드 제거
    .addField('name', type: DataType.text)  // 필드 추가
    .removeIndex(fields: ['age'])  // 인덱스 제거
    .setPrimaryKeyConfig(  // 기본 키 구성 설정
      const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
    );
    
// 마이그레이션 작업 상태 쿼리
final status = await db.queryMigrationTaskStatus(taskId);  
print('마이그레이션 진행률: ${status?.progressPercentage}%');
```


## 분산 아키텍처

```dart
// 분산 노드 구성
final db = ToStore(
    config: DataStoreConfig(
        distributedNodeConfig: const DistributedNodeConfig(
            enableDistributed: true,  // 분산 모드 활성화
            clusterId: 1,  // 클러스터 멤버십 구성
            centralServerUrl: 'http://127.0.0.1:8080',
            accessToken: 'b7628a4f9b4d269b98649129'))
);

// 벡터 데이터 일괄 삽입
await db.batchInsert('vector', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... 수천 개의 레코드
]);

// 분석을 위한 대규모 데이터셋 스트림 처리
await for (final record in db.streamQuery('vector')
    .where('vector_name', '=', 'face_2366')
    .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
    .stream) {
  // 스트리밍 인터페이스는 대규모 특성 추출 및 변환 지원
  print(record);
}
```

## 기본 키 예제
다양한 기본 키 알고리즘, 모두 분산 생성 지원, 검색 기능에 대한 무질서한 기본 키의 영향을 피하기 위해 직접 기본 키 생성은 권장하지 않습니다.
순차 기본 키 PrimaryKeyType.sequential: 238978991
타임스탬프 기반 기본 키 PrimaryKeyType.timestampBased: 1306866018836946
날짜 접두사 기본 키 PrimaryKeyType.datePrefixed: 20250530182215887631
짧은 코드 기본 키 PrimaryKeyType.shortCode: 9eXrF0qeXZ

```dart
// 순차 기본 키 PrimaryKeyType.sequential
// 분산 시스템이 활성화되면 중앙 서버가 노드가 스스로 생성하는 범위를 할당, 간결하고 기억하기 쉬움, 사용자 ID 및 매력적인 번호에 적합
await db.createTables([
      const TableSchema(
        name: 'users',
        primaryKeyConfig: PrimaryKeyConfig(
          type: PrimaryKeyType.sequential,  // 순차 기본 키 유형
          sequentialConfig:  SequentialIdConfig(
              initialValue: 10000, // 자동 증분 시작 값
              increment: 50,  // 증분 단계
              useRandomIncrement: true,  // 비즈니스 볼륨 노출 방지를 위한 무작위 단계 사용
            ),
        ),
        // 필드 및 인덱스 정의...
        fields: []
      ),
      // 다른 테이블...
 ]);
```


## 보안 구성

```dart
// 테이블 및 필드 이름 변경 - 자동 인식 및 데이터 보존
final db = ToStore(
      config: DataStoreConfig(
        enableEncoding: true, // 테이블 데이터에 대한 보안 인코딩 활성화
        encodingKey: 'YouEncodingKey', // 인코딩 키, 임의로 조정 가능
        encryptionKey: 'YouEncryptionKey', // 암호화 키, 참고: 이를 변경하면 이전 데이터 디코딩 불가
      ),
    );
```

## 성능 테스트

Tostore 2.0은 선형 성능 확장성을 구현, 병렬 처리, 파티셔닝 메커니즘 및 분산 아키텍처의 근본적인 변화가 데이터 검색 능력을 크게 향상시켜 대규모 데이터 증가에도 밀리초 단위 응답 시간 제공. 대규모 데이터셋 처리를 위해 스트리밍 쿼리 인터페이스는 메모리 자원 고갈 없이 대량의 데이터 처리 가능.



## 향후 계획
Tostore는 멀티모달 데이터 처리 및 의미 검색에 적응하기 위해 고차원 벡터 지원을 개발 중입니다.


우리의 목표는 데이터베이스를 만드는 것이 아닙니다; Tostore는 단순히 Toway 프레임워크에서 추출한 컴포넌트입니다. 모바일 앱을 개발 중이라면, 통합 생태계를 갖춘 Toway 프레임워크를 사용하는 것이 좋습니다. 이는 Flutter 앱 개발을 위한 풀스택 솔루션을 제공합니다. Toway를 사용하면 기본 데이터베이스를 직접 다룰 필요가 없으며, 모든 쿼리, 로딩, 저장, 캐싱 및 데이터 표시 작업은 프레임워크에 의해 자동으로 수행됩니다.
Toway 프레임워크에 대한 자세한 정보는 [Toway 저장소](https://github.com/tocreator/toway)를 방문하세요.

## 문서

자세한 문서는 [Wiki](https://github.com/tocreator/tostore)를 방문하세요.

## 지원 및 피드백

- 이슈 제출: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 토론 참여: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- 코드 기여: [기여 가이드](CONTRIBUTING.md)

## 라이선스

이 프로젝트는 MIT 라이선스 하에 있습니다 - 자세한 내용은 [LICENSE](LICENSE) 파일을 참조하세요.

---

<p align="center">Tostore가 유용하다고 생각하시면, ⭐️을 주세요</p>
