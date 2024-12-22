# ToStore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | 한국어 | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

ToStore는 모바일 애플리케이션을 위해 특별히 설계된 고성능 스토리지 엔진입니다. Pure Dart로 구현되었으며, B+ 트리 인덱싱과 지능형 캐싱 전략을 통해 탁월한 성능을 실현합니다. 멀티스페이스 아키텍처로 사용자 데이터 격리와 전역 데이터 공유 문제를 해결하며, 트랜잭션 보호, 자동 복구, 증분 백업, 유휴 시 제로 코스트 등의 엔터프라이즈급 기능으로 모바일 애플리케이션을 위한 안정적인 데이터 스토리지를 제공합니다.

## ToStore를 선택하는 이유

- 🚀 **최고의 성능**: 
  - 스마트 쿼리 최적화가 포함된 B+ 트리 인덱싱
  - 밀리초 단위 응답의 지능형 캐싱 전략
  - 안정적인 성능의 논블로킹 동시 읽기/쓰기
- 🎯 **사용 편의성**: 
  - 유연한 체이닝 API 디자인
  - SQL/Map 스타일 쿼리 지원
  - 스마트한 타입 추론과 완벽한 코드 힌트
  - 설정 없이 바로 사용 가능
- 🔄 **혁신적인 아키텍처**: 
  - 다중 사용자 시나리오에 완벽한 멀티스페이스 데이터 격리
  - 설정 동기화 문제를 해결하는 전역 데이터 공유
  - 중첩 트랜잭션 지원
  - 리소스 사용을 최소화하는 온디맨드 스페이스 로딩
- 🛡️ **엔터프라이즈급 신뢰성**: 
  - 데이터 일관성을 보장하는 ACID 트랜잭션 보호
  - 빠른 복구가 가능한 증분 백업 메커니즘
  - 자동 오류 복구 기능이 있는 데이터 무결성 검증

## 빠른 시작

기본 사용법:

```dart
// 데이터베이스 초기화
final db = ToStore(
  version: 1,
  onCreate: (db) async {
    // 테이블 생성
    await db.createTable(
      'users',
      TableSchema(
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
    );
  },
);
await db.initialize(); // 선택사항, 데이터베이스 작업 전 초기화 완료를 보장

// 데이터 삽입
await db.insert('users', {
  'id': 1,
  'name': 'John',
  'age': 30,
});

// 데이터 업데이트
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// 데이터 삭제
await db.delete('users').where('id', '!=', 1);

// 복잡한 조건을 가진 체인 쿼리
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// 레코드 수 계산
final count = await db.query('users').count();

// SQL 스타일 쿼리
final users = await db.queryBySql(
  'users',
  where: 'age > 20 AND name LIKE "%John%" OR id IN (1, 2, 3)',
  limit: 10
);

// Map 스타일 쿼리
final users = await db.queryByMap(
  'users',
  where: {
    'age': {'>=': 30},
    'name': {'like': '%John%'},
  },
  orderBy: ['age'],
  limit: 10,
);

// 일괄 삽입
await db.batchInsert('users', [
  {'id': 1, 'name': 'John', 'age': 30},
  {'id': 2, 'name': 'Mary', 'age': 25},
]);
```

## 멀티스페이스 아키텍처

ToStore의 멀티스페이스 아키텍처로 다중 사용자 데이터 관리가 쉬워집니다:

```dart
// 사용자 스페이스로 전환
await db.switchBaseSpace(spaceName: 'user_123');

// 사용자 데이터 쿼리
final followers = await db.query('followers');

// 키-값 데이터 설정 또는 업데이트, isGlobal: true는 전역 데이터를 의미
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// 전역 키-값 데이터 가져오기
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```

## 성능

일괄 쓰기, 랜덤 읽기/쓰기, 조건부 쿼리를 포함한 고동시성 시나리오에서 ToStore는 Dart/Flutter에서 사용 가능한 다른 주요 데이터베이스들을 크게 능가하는 뛰어난 성능을 보여줍니다.

## 추가 기능

- 💫 우아한 체이닝 API
- 🎯 스마트한 타입 추론
- 📝 완벽한 코드 힌트
- 🔐 자동 증분 백업
- 🛡️ 데이터 무결성 검증
- 🔄 충돌 자동 복구
- 📦 스마트 데이터 압축
- 📊 자동 인덱스 최적화
- 💾 계층형 캐싱 전략

우리의 목표는 단순히 또 하나의 데이터베이스를 만드는 것이 아닙니다. ToStore는 Toway 프레임워크에서 추출된 대안 솔루션입니다. 모바일 애플리케이션을 개발하고 계시다면, 완전한 Flutter 개발 생태계를 제공하는 Toway 프레임워크를 추천드립니다. Toway를 사용하면 기본 데이터베이스를 직접 다룰 필요가 없습니다 - 데이터 요청, 로딩, 저장, 캐싱, 표시 등이 모두 프레임워크에 의해 자동으로 처리됩니다.
Toway 프레임워크에 대한 자세한 정보는 [Toway 저장소](https://github.com/tocreator/toway)를 참조하세요.

## 문서

자세한 문서는 [Wiki](https://github.com/tocreator/tostore)를 참조하세요.

## 지원 및 피드백

- 이슈 제출: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 토론 참여: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- 기여하기: [Contributing Guide](CONTRIBUTING.md)

## 라이선스

이 프로젝트는 MIT 라이선스를 따릅니다 - 자세한 내용은 [LICENSE](LICENSE) 파일을 참조하세요.

---

<p align="center">ToStore가 도움이 되었다면 ⭐️를 눌러주세요</p> 