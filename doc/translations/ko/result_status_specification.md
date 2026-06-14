# ToStore ResultStatus 자동 진단 및 상태 분석 명세서

자동화된 운영(Ops), AI 에이전트, 자동화 테스트 스크립트 및 클라이언트 프로그램이 데이터베이스의 다양한 실행 결과 및 예외 상태를 정확하게 식별할 수 있도록, ToStore는 최신 버전에서 구조화된 `ResultStatus` 체계를 도입했습니다.

본 명세서는 데이터베이스 사용자 및 개발자가 자체적으로 상태 분석을 구현할 수 있도록 상태 코드 설계 원칙, 의미론적 식별자 키 규격, 다양한 상태 유형의 전용 필드 구조에 대해 상세히 설명합니다.

---

## 1. 핵심 설계 원칙

### 1.1 상태 코드(code) 숫자 규격

모든 숫자 상태 코드(`code`)는 고정된 5자리 숫자로 정의됩니다 (성공 상태 제외):

- **성공 상태 (Special Success Code)**: 특별히 `0`으로 고정됩니다.
- **기타 상태 (Error & Diagnostic Codes)**: 5자리 숫자로 통일됩니다.
- **클래스 코드 (대분류 코드)**: 상태 코드의 첫 2자리. 대략적인 오류 범주를 빠르게 식별하는 데 사용됩니다.
- **리프 코드 (상세 코드)**: 상태 코드의 마지막 3자리. 구체적인 오류 시나리오를 나타냅니다.

> [!TIP]
> 자동화된 운영, AI 에이전트 또는 외부 테스트 스크립트를 개발할 때, 개발자는 첫 2자리(클래스 코드) 또는 값의 범위를 사용하여 로직 내에서 해당하는 예외 핸들러로 빠르게 라우팅한 다음, 리프 코드에 따라 세부적인 처리를 수행할 수 있습니다.

> [!IMPORTANT]
> **메모리 내 판단 베스트 프랙티스 (In-Memory Check)**:
> 클라이언트 또는 Dart/Flutter 코드 등 메모리 내에서 데이터베이스 작업 결과를 읽을 때, **가장 권장되고 효율적인 방법은 `ResultStatus` 또는 `ResultType`에 내장된 읽기 전용 속성(예: `isBusinessError`, `isCriticalError` 등, 자세한 내용은 [제3.2절](#32-메모리-내-판단용-편리한-getter-in-memory-helper-getters) 참조)을 직접 사용하는 것**입니다. 이를 통해 값 범위의 수동 분석이나 문자열 접두사 매칭을 피할 수 있습니다.

### 1.2 의미론적 상태 식별자(codeKey) 규격

각 상태는 고유한 문자열 식별자 `codeKey`에 대응합니다:

- **명명 형식**: `[대분류 접두사]_[다단계 상세 식별자]`.
- **명명 규칙**: 대문자 영문자와 언더스코어`_`로 구성되며, 공백이나 특수 문자는 포함되지 않습니다.
- **대분류 접두사**: 해당 상태가 속한 핵심 비즈니스 대분류를 나타냅니다. 여러 분류 수준이 존재하는 경우, 접두사 검색 및 범위 필터링을 용이하게 하기 위해 가장 일반적인 접두사가 맨 앞에 배치됩니다.

---

## 2. 클래스 코드(대분류 코드) 빠른 조회 테이블

ToStore의 모든 클래스 코드 매핑 정의는 다음과 같습니다:

| 코드 범위 | 클래스 코드 (첫 2자리) | 의미론적 접두사 | 범주 | 예외 발생 전략 |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `00` | `SUCCESS` | **작업 성공** | 예외를 발생시키지 않고 정상적으로 반환합니다. |
| `10000 - 19999` | `10 - 19` | `BIZ_` | **비즈니스 오류** (엔드 유저의 입력 오류, 제약 조건 위반 등) | 예외를 발생시키지 않으며, 항상 `DbResult` 또는 `QueryResult`를 통해 반환됩니다. |
| `20000 - 49999` | `20 - 49` | `DEV_` | **개발자 오류** (잘못된 API 매개변수, 잘못된 테이블 스키마 구성 등) | **디버그 환경에서는 `DbException`을 직접 발생**시켜 개발자에게 경고합니다. **프로덕션 환경에서는 정상적으로 결과로 반환됩니다**. *(주의: 엔진 버전 불일치 및 마이그레이션 배치 실행 실패는 심각한 오류로, 프로덕션 환경에서도 예외를 강제 발생시킵니다)* |
| `50000 - 79999` | `50 - 79` | `SYS_` | **시스템 오류** (디스크 공간 부족, IO 예외, 락 획득 타임아웃 등) | 정상적인 실행이 차단되는 경우 예외를 발생시킵니다. 기타(트랜잭션 충돌 등)는 결과로 반환됩니다. |
| `99000 - 99999` | `99` | `ENG_` | **엔진 오류** (엔진 로직 오류, 데이터 파일 손상, 알 수 없는 내부 오류) | 일반적으로 예외를 발생시키지 않으며, 매우 심각한 경우에만 예외를 발생시킵니다. |

---

## 3. ResultStatus 공통 필드 구조 및 메모리 내 편리한 판단 Getter

### 3.1 공통 필드 (직렬화된 JSON 구조)

모든 유형의 `ResultStatus`는 JSON으로 직렬화되면 다음 4가지 기본적인 공통 필드를 포함합니다. 사용자는 이 필드를 직접 읽어 예비적인 확인을 수행할 수 있습니다.

| 필드 | 유형 | 설명 |
| :--- | :--- | :--- |
| `index` | `int` | 배치 작업의 순서 인덱스. 단일 작업의 경우 `0`으로 고정됩니다. |
| `code` | `int` | 숫자 상태 코드(성공 시 `0`, 예외 시 5자리 숫자). |
| `codeKey` | `String` | 의미론적 상태 식별자 키(예: `CONSTRAINT_VIOLATION_UNIQUE`). |
| `message` | `String` | 사람이 읽을 수 있는 상태 상세 설명. |

### 3.2 메모리 내 판단용 편리한 Getter (In-Memory Helper Getters)

Dart/Flutter에서 `ResultStatus`와 `ResultType`은 수동 범위 체크나 문자열 매칭 없이 메모리 내에서 범주 및 심각도를 확인하기 위해 매우 효율적인 `O(1)` 읽기 전용 속성(Getter)을 캡슐화합니다:

| 속성 | 유형 | 설명 |
| :--- | :--- | :--- |
| `isBusinessError` | `bool` | **비즈니스 오류**인지 여부(제약 조건 위반, 캐스팅 실패 등. 범위: `10000 - 19999`). |
| `isDeveloperError` | `bool` | **개발자 오류**인지 여부(잘못된 스키마, 매개변수 불일치, 테이블 미검출 등. 범위: `20000 - 49999`). |
| `isSystemError` | `bool` | **시스템 오류**인지 여부(락 타임아웃, 디스크 풀, 파일 잠금 등. 범위: `50000 - 79999`). |
| `isEngineError` | `bool` | **엔진 오류**인지 여부(범위: `99000 - 99999`). |
| `isCriticalError` | `bool` | **심각한 오류/재난 수준의 이벤트**인지 여부(디스크 풀, 메모리 부족, 심각한 데이터 파일 손상, 호환되지 않는 마이그레이션 실패 등 수동 또는 운영상의 개입이 필요한 경우). |

---

## 4. 상세 분석 구조 및 전용 필드 설명

`code` / `codeKey` 범위와 `ResultStatus`의 구체적인 하위 클래스에 따라 직렬화된 JSON 구조는 서로 다른 **전용 진단 필드**를 갖습니다. 아래에 5가지 상태 하위 클래스의 필드 규격과 애플리케이션 매핑을 보여줍니다.

### 4.1 SuccessStatus (작업 성공 상태)

- **범주 범위**: `code == 0`, `codeKey == "SUCCESS"`
- **적용 시나리오**: 레코드 삽입, 수정 또는 삭제가 완전히 성공한 경우.
- **전용 필드 정의**:

  | 필드 | 유형 | 상세 내용 |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **옵션**. 단일 레코드 쓰기(`insert` 등) 또는 업데이트(`update` 등)가 성공한 경우에만 반환되며, 물리적으로 생성 또는 변경된 레코드의 주키 값을 나타냅니다. |

- **JSON 물리 표현 예**:
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

### 4.2 ConstraintStatus (데이터 무결성 및 제약 조건 충돌 상태)

- **범주 범위**: `code`가 `[10000, 19999]` 범위(주로 데이터 검증 및 무결성 제약 조건 충돌).
- **전용 필드 정의**:

  | 필드 | 유형 | 상세 내용 |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **필수**. 무결성 제약 조건 충돌 또는 미검출 오류가 발생한 구체적인 테이블 이름. |
  | `constraintName` | `String?` | **옵션**. 오류를 유발한 구체적인 제약 조건 이름(외래키 충돌인 경우 `fk_users_profile`, 고유성 충돌인 경우 인덱스 이름, NOT NULL 또는 캐스트 오류 등 이름이 없는 제약 조건의 경우 `null`). |
  | `fields` | `List<String>` | **필수**. 충돌의 원인이 된 필드 목록. |
  | `conflictingKeys` | `List<dynamic>` | **필수**. 충돌을 일으킨 구체적인 입력값 목록. `fields` 목록과 1:1로 대응합니다. 필드가 null이면 목록의 해당하는 항목은 `null`이 됩니다. |
  | `primaryKey` | `String?` | **옵션**. 연관된 레코드의 물리 주키. 단일 레코드 작업이 아니거나 메모리 단계에서 차단된 경우 `null`이 됩니다. |
  | `referencedTable` | `String?` | **옵션**. 외래키 제약 조건 충돌(부모 레코드 미존재, 자식 레코드 제한 등)의 부모 테이블 이름. |

- **리프 코드 가이드라인**:

  | 코드 및 메모리 내 유형 | 시나리오 | 필드 가이드라인 |
  | :--- | :--- | :--- |
  | `10000`<br>`bizValidationFailed` | 데이터 형식 또는 범위 검증 실패 | <ul><li>`tableName`: 대상 테이블</li><li>`constraintName`: `null`</li><li>`fields`: 검증에 위배된 필드, 예 `["email"]`</li><li>`conflictingKeys`: 실패 원인이 된 유효하지 않은 값, 예 `["invalid-email"]`</li><li>`primaryKey`: 레코드 주키(존재하는 경우)</li></ul> |
  | `10001`<br>`bizNotNullViolation` | NOT NULL 제약 조건 위반 | <ul><li>`tableName`: 대상 테이블</li><li>`constraintName`: `null`</li><li>`fields`: 제약 조건에 위배된 필드, 예 `["email"]`</li><li>`conflictingKeys`: 항상 `[null]`</li><li>`primaryKey`: 레코드 주키(존재하는 경우)</li></ul> |
  | `10002`<br>`bizTypeCastFailed` | 데이터 형식 변환 또는 캐스팅 실패 | <ul><li>`tableName`: 대상 테이블</li><li>`constraintName`: `null`</li><li>`fields`: 캐스팅 실패 필드, 예 `["age"]`</li><li>`conflictingKeys`: 실패 원인이 된 유효하지 않은 값, 예 `["not_a_number"]`</li><li>`primaryKey`: 레코드 주키(존재하는 경우)</li></ul> |
  | `11001`<br>`bizPrimaryKeyViolation` | 주키 충돌(이미 존재합니다) | <ul><li>`tableName`: 대상 테이블</li><li>`constraintName`: `"PRIMARY"` 또는 제약 조건 이름</li><li>`fields`: 주키 필드, 예 `["id"]`</li><li>`conflictingKeys`: 중복된 값, 예 `["usr_101"]`</li><li>`primaryKey`: 충돌하는 값, 예 `"usr_101"`</li></ul> |
  | `11002`<br>`bizUniqueViolation` | 고유 제약 조건 위반 | <ul><li>`tableName`: 대상 테이블</li><li>`constraintName`: 고유 인덱스 이름, 예 `"uk_email"`</li><li>`fields`: 고유성을 구성하는 필드, 예 `["email"]`</li><li>`conflictingKeys`: 충돌을 일으키는 값, 예 `["test@a.com"]`</li><li>`primaryKey`: 충돌하는 레코드 주키(존재하는 경우)</li></ul> |
  | `11003`<br>`bizForeignKeyViolation` | 외래키 제약 조건 위반 (일반) | <ul><li>`tableName`: 자식 테이블</li><li>`constraintName`: 외래키 제약 조건 이름</li><li>`fields`: 외래키 열</li><li>`conflictingKeys`: 충돌을 일으키는 입력값</li><li>`primaryKey`: 레코드 주키(존재하는 경우)</li><li>`referencedTable`: 부모 테이블</li></ul> |
  | `11004`<br>`bizCheckViolation` | CHECK 제약 조건 위반 | <ul><li>`tableName`: 대상 테이블</li><li>`constraintName`: CHECK 제약 조건 이름</li><li>`fields`: 체크된 필드</li><li>`conflictingKeys`: CHECK에 위배되는 값</li><li>`primaryKey`: 레코드 주키(존재하는 경우)</li></ul> |
  | `11005`<br>`bizForeignKeyParentNotExist` | 참조된 부모 키가 존재하지 않습니다 | <ul><li>`tableName`: 자식 테이블</li><li>`constraintName`: 외래키 제약 조건 이름</li><li>`fields`: 외래키 열, 예 `["userId"]`</li><li>`conflictingKeys`: 존재하지 않는 참조값, 예 `["non_parent"]`</li><li>`primaryKey`: 레코드 주키(존재하는 경우)</li><li>`referencedTable`: 부모 테이블</li></ul> |
  | `11006`<br>`bizForeignKeyChildRestrict` | 자식 레코드에 의해 삭제/수정이 제한됨 | <ul><li>`tableName`: 부모 테이블</li><li>`constraintName`: 외래키 제약 조건 이름</li><li>`fields`: 부모 테이블 참조열</li><li>`conflictingKeys`: 자식 테이블에서 참조 중인 부모 테이블 키값</li><li>`primaryKey`: 부모 키값</li><li>`referencedTable`: 자식 테이블</li></ul> |
  | `11007`<br>`bizForeignKeyCompositeMismatch` | 복합 외래키의 값이 불완전합니다 | <ul><li>`tableName`: 자식 테이블</li><li>`constraintName`: 외래키 제약 조건 이름</li><li>`fields`: 복합 외래키 열</li><li>`conflictingKeys`: 입력값(부분적인 null 포함)</li><li>`primaryKey`: 레코드 주키(존재하는 경우)</li><li>`referencedTable`: 부모 테이블</li></ul> |
  | `11008`<br>`bizForeignKeyTypeMismatch` | 외래키 형식이 일치하지 않습니다 | <ul><li>`tableName`: 자식 테이블</li><li>`constraintName`: 외래키 제약 조건 이름</li><li>`fields`: 외래키 열</li><li>`conflictingKeys`: 캐스팅 실패한 값</li><li>`primaryKey`: 레코드 주키(존재하는 경우)</li><li>`referencedTable`: 부모 테이블</li></ul> |
  | `11009`<br>`bizValueExceedsMaxLength` | 값의 길이가 스키마 제한을 초과합니다 | <ul><li>`tableName`: 대상 테이블</li><li>`constraintName`: `null`</li><li>`fields`: 제약 조건 위반 필드, 예 `["name"]`</li><li>`conflictingKeys`: 제한 초과한 값, 예 `["a" * 1000]`</li><li>`primaryKey`: 레코드 주키(존재하는 경우)</li></ul> |
  | `11010`<br>`bizValueLessThanMinLength` | 값의 길이가 스키마 제한 미만입니다 | <ul><li>`tableName`: 대상 테이블</li><li>`constraintName`: `null`</li><li>`fields`: 제약 조건 위반 필드, 예 `["code"]`</li><li>`conflictingKeys`: 최소값보다 짧은 값, 예 `["ab"]`</li><li>`primaryKey`: 레코드 주키(존재하는 경우)</li></ul> |
  | `11011`<br>`bizValueLessThanMinValue` | 숫자가 스키마 제한 미만입니다 | <ul><li>`tableName`: 대상 테이블</li><li>`constraintName`: `null`</li><li>`fields`: 제약 조건 위반 필드, 예 `["age"]`</li><li>`conflictingKeys`: 최소값 미만의 값, 예 `[-5]`</li><li>`primaryKey`: 레코드 주키(존재하는 경우)</li></ul> |
  | `11012`<br>`bizValueExceedsMaxValue` | 숫자가 스키마 제한을 초과합니다 | <ul><li>`tableName`: 대상 테이블</li><li>`constraintName`: `null`</li><li>`fields`: 제약 조건 위반 필드, 예 `["score"]`</li><li>`conflictingKeys`: 최대값 초과한 값, 예 `[105]`</li><li>`primaryKey`: 레코드 주키(존재하는 경우)</li></ul> |
  | `12002`<br>`bizRecordNotFound` | 리소스가 존재하지 않음 / 레코드 미검출 | <ul><li>`tableName`: 대상 테이블</li><li>`constraintName`: `null`</li><li>`fields`: 검색 대상 필드, 예 `["id"]`</li><li>`conflictingKeys`: 검출되지 않은 대상 키, 예 `["non_exist_id"]`</li><li>`primaryKey`: 누락된 키의 값, 예 `"non_exist_id"`</li></ul> |

- **JSON 물리 표현 예** (외래키 부모 레코드가 존재하지 않는 오류):
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

### 4.3 SchemaValidationStatus (테이블 스키마 검증 및 호환 불가 마이그레이션 상태)

- **범주 범위**: `code`가 `[30000, 39999]` 범위(스키마 구성 검증 오류 및 물리적 마이그레이션 불일치).
- **전용 필드 정의**:

  | 필드 | 유형 | 상세 내용 |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **필수**. 검증 또는 물리적 마이그레이션이 진행 중인 테이블 이름. |
  | `field` | `String?` | **옵션**. 스키마 또는 마이그레이션 오류를 유발한 구체적인 필드 이름. |
  | `wrongValue` | `dynamic` | **옵션**. 충돌의 원인이 된 유효하지 않은 설정값 또는 마이그레이션 차분 구성. |

- **리프 코드 가이드라인**:

  | 코드 및 메모리 내 유형 | 시나리오 | 필드 가이드라인 |
  | :--- | :--- | :--- |
  | `30000`<br>`devInvalidSchema` | 유효하지 않은 테이블 스키마 정의 | <ul><li>`tableName`: 테이블 이름</li><li>`field`: `null`</li><li>`wrongValue`: 무효한 설정 맵, 또는 `null`</li></ul> |
  | `30001`<br>`devInvalidSchemaTableName` | 테이블 이름 검증 오류(잘못된 문자 또는 너무 긺) | <ul><li>`tableName`: 위배되는 이름</li><li>`field`: `null`</li><li>`wrongValue`: 위배되는 문자열</li></ul> |
  | `30002`<br>`devInvalidSchemaFieldName` | 필드 이름 검증 오류(잘못된 문자) | <ul><li>`tableName`: 테이블 이름</li><li>`field`: 위배되는 필드 이름</li><li>`wrongValue`: 위배되는 문자열</li></ul> |
  | `30003`<br>`devInvalidSchemaPrimaryKey` | 주키 검증 오류(누락 또는 유효하지 않은 형식) | <ul><li>`tableName`: 테이블 이름</li><li>`field`: `"primaryKey"` 또는 주키 필드 이름</li><li>`wrongValue`: 주키 설정 상세</li></ul> |
  | `30004`<br>`devInvalidSchemaIndexLimit` | 테이블의 인덱스 수가 시스템 제한(16개) 초과 | <ul><li>`tableName`: 테이블 이름</li><li>`field`: `null`</li><li>`wrongValue`: 인덱스 설정 목록</li></ul> |
  | `30005`<br>`devSchemaTableExists` | 테이블이 이미 존재합니다 | <ul><li>`tableName`: 테이블 이름</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30006`<br>`devSchemaFieldExists` | 스키마 업그레이드: 이미 존재하는 필드를 추가하려 함 | <ul><li>`tableName`: 테이블 이름</li><li>`field`: 충돌하는 필드 이름</li><li>`wrongValue`: `null`</li></ul> |
  | `30007`<br>`devSchemaIndexExists` | 스키마 업그레이드: 이미 존재하는 인덱스를 추가하려 함 | <ul><li>`tableName`: 테이블 이름</li><li>`field`: 인덱스 이름</li><li>`wrongValue`: `null`</li></ul> |
  | `30008`<br>`devInvalidSchemaForeignKey` | 외래키 정의가 무효(열 불일치 등) | <ul><li>`tableName`: 테이블 이름</li><li>`field`: 외래키 이름</li><li>`wrongValue`: 외래키 설정 상세</li></ul> |
  | `30009`<br>`devInvalidSchemaSpaceMismatch` | 글로벌/스페이스 고유의 경계 불일치 | <ul><li>`tableName`: 테이블 이름</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30010`<br>`devMigrationNotAllowedWithData` | 마이그레이션에 데이터 변경이 필요하지만 명시적으로 허용되지 않음 | <ul><li>`tableName`: 테이블 이름</li><li>`field`: `null`</li><li>`wrongValue`: 마이그레이션 업그레이드 차분 맵</li></ul> |
  | `30011`<br>`devMigrationUnsafeTypeConversion` | 물리 마이그레이션: 필드의 지원되지 않는 유형 변환 | <ul><li>`tableName`: 테이블 이름</li><li>`field`: 필드 이름</li><li>`wrongValue`: 충돌하는 유형 맵, 예 `{ "from": "text", "to": "integer" }`</li></ul> |
  | `30013`<br>`devMigrationCannotAddNonNullField` | 데이터가 있는 테이블에 기본값 없이 비NULL 필드를 추가할 수 없음 | <ul><li>`tableName`: 테이블 이름</li><li>`field`: 위배되는 필드 이름</li><li>`wrongValue`: 마이그레이션 매개변수, 예 `{ "nullable": false, "defaultValue": null }`</li></ul> |
  | `30014`<br>`devMigrationNullableToNonNullNotAllowed` | 물리 마이그레이션: 필드를 NULL 허용에서 비NULL로 변경 | <ul><li>`tableName`: 테이블 이름</li><li>`field`: 필드 이름</li><li>`wrongValue`: 마이그레이션 매개변수(30013과 동일)</li></ul> |
  | `30015`<br>`devMigrationUniqueTighteningNotAllowed` | 물리 마이그레이션: 필드 제약 조건을 UNIQUE로 강화 | <ul><li>`tableName`: 테이블 이름</li><li>`field`: 필드 이름</li><li>`wrongValue`: 고유성 제약을 유발하는 인덱스 정의</li></ul> |
  | `30016`<br>`devInvalidSchemaTtlConfig` | TTL 구성 검증 실패 | <ul><li>`tableName`: 테이블 이름</li><li>`field`: TTL 타임스탬프 필드</li><li>`wrongValue`: 무효한 TTL 설정 맵, 예 `{ "enabled": true, "fieldName": "expire_at" }`</li></ul> |
  | `30017`<br>`devInvalidSchemaDuplicateFieldName` | 테이블 스키마 내 중복된 필드 이름 | <ul><li>`tableName`: 테이블 이름</li><li>`field`: 중복된 필드 이름</li><li>`wrongValue`: `null`</li></ul> |
  | `30018`<br>`devInvalidSchemaIndexField` | 인덱스가 존재하지 않는 필드를 참조합니다 | <ul><li>`tableName`: 테이블 이름</li><li>`field`: 인덱스 이름</li><li>`wrongValue`: 불일치 유발 필드 이름</li></ul> |

- **JSON 물리 표현 예** (데이터가 있는 테이블에 기본값 없이 비NULL 필드를 추가하는 오류):
  ```json
  {
    "index": 0,
    "code": 30013,
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

### 4.4 InvalidArgumentStatus (API 인수 및 커서 페이지네이션 검증 예외)

- **범주 범위**: `code`가 `[20000, 20999]` 범위(API 매개변수, 쿼리 구조 또는 페이지네이션 토큰 검증 오류).
- **전용 필드 정의**:

  | 필드 | 유형 | 상세 내용 |
  | :--- | :--- | :--- |
  | `parameterName` | `String` | **필수**. 검증 오류를 유발한 매개변수 이름(예: `"cursor"`, `"orderBy"` 또는 특정 열 키). |
  | `passedValue` | `dynamic` | **옵션**. 호출처에서 전달한 유효하지 않은 값. 복잡한 개체는 문자열로 변환됩니다. |
  | `primaryKey` | `String?` | **옵션**. 연관된 레코드의 물리 주키. |

- **리프 코드 가이드라인**:

  | 코드 및 메모리 내 유형 | 시나리오 | 필드 가이드라인 |
  | :--- | :--- | :--- |
  | `20001`<br>`devInvalidArgumentFormat` | 인수 형식 오류 | <ul><li>`parameterName`: 무효한 매개변수 이름</li><li>`passedValue`: 전달된 값, 예 `"twenty"`</li><li>`primaryKey`: 레코드 주키(존재하는 경우)</li></ul> |
  | `20002`<br>`devInvalidArgumentType` | 인수 형식 불일치 | <ul><li>`parameterName`: 매개변수 이름</li><li>`passedValue`: 전달된 값, 예 `{"foo": "bar"}` (String이 기대된 경우)</li><li>`primaryKey`: 레코드 주키(존재하는 경우)</li></ul> |
  | `20003`<br>`devInvalidArgumentMissing` | 필수 인수가 누락되었습니다 | <ul><li>`parameterName`: 누락된 매개변수 이름, 예 `"dbPath"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: 레코드 주키(존재하는 경우)</li></ul> |
  | `20005`<br>`devInvalidPrimaryKeyFormat` | 무효한 주키 형식 | <ul><li>`parameterName`: `"primaryKey"` 또는 주키 필드</li><li>`passedValue`: 무효한 주키 값, 예 `"invalid_id_value"`</li><li>`primaryKey`: 무효한 주키 값</li></ul> |
  | `20010`<br>`devVectorDimensionMismatch` | 벡터 차원 불일치 | <ul><li>`parameterName`: `"other"`</li><li>`passedValue`: 위배되는 차원 크기</li><li>`primaryKey`: `null`</li></ul> |
  | `20011`<br>`devIndexFieldMissing` | 커서용 레코드에서 필요한 인덱스 필드 누락 | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: 누락된 인덱스 필드</li><li>`primaryKey`: `null`</li></ul> |
  | `20201`<br>`devInvalidCursorPagination` | 커서 페이지네이션과 오프셋은 상호 배타적입니다 | <ul><li>`parameterName`: `"cursor"` / `"offset"`</li><li>`passedValue`: 충돌하는 페이지네이션 매개변수</li><li>`primaryKey`: `null`</li></ul> |
  | `20202`<br>`devInvalidCursorTable` | 커서가 대상 테이블과 일치하지 않습니다 | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: 커서 토큰</li><li>`primaryKey`: `null`</li></ul> |
  | `20203`<br>`devInvalidCursorSignature` | 커서 서명 불일치(변조됨) | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: 커서 토큰</li><li>`primaryKey`: `null`</li></ul> |
  | `20204`<br>`devInvalidCursorOrderBy` | 커서 orderBy 구성이 무효 또는 불일치 | <ul><li>`parameterName`: `"orderBy"`</li><li>`passedValue`: orderBy 목록, 예 `["-age", "id"]`</li><li>`primaryKey`: `null`</li></ul> |
  | `20205`<br>`devInvalidCursorMode` | 커서 토큰 모드 불일치 | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: 토큰 모드, 예 `"sortKey"`</li><li>`primaryKey`: `null`</li></ul> |
  | `20206`<br>`devInvalidCursorPayload` | 무효한 커서 페이로드(디코드 불가) | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: `null`</li></ul> |
  | `20301`<br>`devInvalidQuerySelectField` | 쿼리 선택 필드는 String 또는 QueryAggregation이어야 합니다 | <ul><li>`parameterName`: `"select"`</li><li>`passedValue`: 무효한 선택 필드 정의</li><li>`primaryKey`: `null`</li></ul> |
  | `20302`<br>`devInvalidQueryForeignKeyJoin` | 자동 조인용 외래키 관계가 존재하지 않습니다 | <ul><li>`parameterName`: `"join"` / `"tableName"`</li><li>`passedValue`: 관계가 없는 대상 테이블</li><li>`primaryKey`: `null`</li></ul> |
  | `20303`<br>`devInvalidQueryFieldAlias` | 쿼리 필드 에일리어스 형식이 무효입니다 | <ul><li>`parameterName`: `"alias"`</li><li>`passedValue`: 무효한 에일리어스 문자열</li><li>`primaryKey`: `null`</li></ul> |
  | `20304`<br>`devInvalidExpression` | 무효한 식 구성 또는 실행 예외 | <ul><li>`parameterName`: 에러 측면(예: `"arguments"`, `"functionName"`, `"node"`)</li><li>`passedValue`: 무효한 값 또는 카운트</li><li>`primaryKey`: `null`</li></ul> |
  | `22005`<br>`devFieldNotFound` | 필드를 찾을 수 없습니다 | <ul><li>`parameterName`: 알 수 없는 필드 이름, 예 `"extra"`</li><li>`passedValue`: 전달된 필드의 값</li><li>`primaryKey`: 레코드 주키(존재하는 경우)</li></ul> |

- **JSON 물리 표현 예** (커서의 정렬 순서가 쿼리의 정렬 순서와 충돌하는 오류):
  ```json
  {
    "index": 0,
    "code": 20204,
    "codeKey": "DEV_INVALID_CURSOR_ORDERBY",
    "message": "Cursor orderBy fields do not match current query orderBy.",
    "parameterName": "orderBy",
    "passedValue": ["age DESC", "id ASC"],
    "primaryKey": null
  }
  ```

---

### 4.5 TransactionOperationStatus (트랜잭션 충돌 및 중단)

- **범주 범위**: `code`가 `[50000, 50999]` 범위(트랜잭션 롤백, 명시적 중단 또는 직렬화 가능성 충돌).
- **전용 필드 정의**:

  | 필드 | 유형 | 상세 내용 |
  | :--- | :--- | :--- |
  | `txId` | `String` | **필수**. 트랜잭션 수명을 추적하는 데 사용되는 전역 고유 트랜잭션 스트림 식별자 ID. |

- **리프 코드 가이드라인**:

  | 코드 및 메모리 내 유형 | 시나리오 | 필드 가이드라인 |
  | :--- | :--- | :--- |
  | `50001`<br>`sysTransactionAborted` | 트랜잭션 중단(명시적 롤백 또는 연쇄 실패) | <ul><li>`txId`: 활성 트랜잭션 ID</li></ul> |
  | `50002`<br>`sysTransactionConflict` | 트랜잭션 충돌(SSI/WAL에서 동일 키에 대한 동시 업데이트) | <ul><li>`txId`: 충돌하는 트랜잭션 ID</li></ul> |

- **JSON 물리 표현 예** (SSI 동시 쓰기 충돌):
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

### 4.6 GeneralStatus (일반 및 시스템 수준 예외 상태)

- **범주 범위**: 다른 모든 상태 코드의 폴백(저수준 I/O, 하드웨어 오류, 시스템 타임아웃 등).
- **전용 필드 정의**:

  | 필드 | 유형 | 상세 내용 |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **옵션**. 연관된 레코드의 물리 주키. |
  | `target` | `String?` | **옵션**. 대상 물리 리소스(물리 파일 경로, 잠금 이름, URL 리소스 등). |
  | `operation` | `String?` | **옵션**. 활성 시스템 호출 이름(예: `'readAsString'`, `'delete'`, `'acquire'`). |

- **리프 코드 가이드라인**:

  | 코드 및 메모리 내 유형 | 시나리오 / 레벨 | 필드 가이드라인 |
  | :--- | :--- | :--- |
  | `20007`<br>`devIndexOutOfBounds` | 인덱스 또는 범위가 곙계 외(개발자 오류) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `20008`<br>`devUnsupportedOperation` | 현재 컨텍스트에서는 작업이 지원되지 않음(개발자 오류) | <ul><li>`primaryKey`: `null`</li><li>`target`: 대상 테이블/리소스(존재 시)</li><li>`operation`: 메서드 이름(존재 시)</li></ul> |
  | `22001`<br>`devTableNotFound` | 테이블을 찾을 수 없음(개발자 오류) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22003`<br>`devIndexNotFound` | 인덱스를 찾을 수 없음(개발자 오류) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22004`<br>`devSpaceNotFound` | 스페이스를 찾을 수 없음(개발자 오류) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `23001`<br>`devLargeScaleOperationBypassRequired` | OOM 방지를 위해 결과 상세 건너뛰기 필요(개발자 오류) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `24001`<br>`devEngineIncompatible` | **심각**: 엔진 버전 불일치(개발자 오류) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `50003`<br>`sysMigrationBatchExecutionFailed` | 마이그레이션 배치 실행 실패(시스템 오류) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51001`<br>`sysTimeoutLockAcquisition` | 락 획득 타임아웃(시스템 오류) | <ul><li>`primaryKey`: 대상 키(존재 시)</li><li>`target`: 락 리소스 ID</li><li>`operation`: `"acquire"`</li></ul> |
  | `51002`<br>`sysTimeout` | 작업 타임아웃(시스템 오류) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51003`<br>`sysCancellation` | 작업이 취소되었습니다(시스템 오류) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52001`<br>`sysResourceExhaustedMemory` | 심각한 메모리 리소스 고갈(시스템 오류) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52002`<br>`sysResourceExhausted` | 심각한 시스템 리소스 고갈(예: 디스크 풀)(시스템 오류) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `53001`<br>`sysIoNotFound` | 물리 파일 또는 경로가 존재하지 않음(시스템 오류) | <ul><li>`primaryKey`: `null`</li><li>`target`: 파일 또는 폴더 경로</li><li>`operation`: I/O 작업명</li></ul> |
  | `53002`<br>`sysIoPermissionDenied` | 파일 액세스 권한이 없음(시스템 오류) | <ul><li>`primaryKey`: `null`</li><li>`target`: 파일 경로</li><li>`operation`: I/O 작업명</li></ul> |
  | `53003`<br>`sysIoDiskFull` | 심각한 디스크 공간 부족 또는 할당량 초과(시스템 오류) | <ul><li>`primaryKey`: `null`</li><li>`target`: 파일 경로</li><li>`operation`: I/O 작업명</li></ul> |
  | `53004`<br>`sysIoFileLocked` | 파일이 다른 프로세스에 의해 잠김(시스템 오류) | <ul><li>`primaryKey`: `null`</li><li>`target`: File path</li><li>`operation`: I/O 작업명</li></ul> |
  | `53005`<br>`sysIoDeviceFault` | 심각한 스토리지 장치 또는 미디어 장애(시스템 오류) | <ul><li>`primaryKey`: `null`</li><li>`target`: 파일 경로</li><li>`operation`: I/O 작업명</li></ul> |
  | `53006`<br>`sysIoWebStorageUnavailable` | Web IndexedDB 또는 스토리지를 사용할 수 없음(시스템 오류) | <ul><li>`primaryKey`: `null`</li><li>`target`: IndexedDB 리소스</li><li>`operation`: I/O 작업명</li></ul> |
  | `53007`<br>`sysBackupCorrupted` | 백업 패키지 손상 또는 메타데이터 누락(시스템 오류) | <ul><li>`primaryKey`: `null`</li><li>`target`: 백업 경로</li><li>`operation`: 백업 처리</li></ul> |
  | `53008`<br>`sysIoDataCorrupted` | 심각한 데이터 파일 손상 또는 체크섬 실패(시스템 오류) | <ul><li>`primaryKey`: `null`</li><li>`target`: 데이터 파일 경로</li><li>`operation`: I/O 작업명</li></ul> |
  | `53009`<br>`sysInvalidDataFormat` | 데이터 스트림의 형식 또는 분석 실패(시스템 오류) | <ul><li>`primaryKey`: `null`</li><li>`target`: 데이터 스트림 키</li><li>`operation`: `"decode"` / `"deserialize"`</li></ul> |
  | `53099`<br>`sysIoGeneric` | 일반적인 시스템 I/O 에러(시스템 오류) | <ul><li>`primaryKey`: `null`</li><li>`target`: 파일 경로</li><li>`operation`: I/O 작업명</li></ul> |
  | `99001`<br>`engError` | 엔진 에러(엔진 에러) | <ul><li>`primaryKey`: `null`</li></ul> |

- **JSON 물리 표현 예** (테이블 미검출 에러):
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

## 5. 데이터베이스 사용자 상태 분석 및 예외 처리 권장 사항(Dart/Flutter 예제)

ToStore에서 모든 핵심 데이터 작업(삽입, 수정, 삭제)은 `DbResult`를 반환합니다. 쿼리는 `QueryResult`를 반환하고, 트랜잭션 작업은 `TransactionResult`를 반환합니다. 구조적 구성 오류는 `DbException`을 발생시킵니다.

아래는 개발자 애플리케이션이 데이터베이스 상태를 어떻게 처리, 분석하고 적절히 예외 처리를 수행하는지 보여주는 코드 예제입니다:

### 5.1 쓰기 작업 응답 처리 (`DbResult`)

```dart
import 'package:tostore/tostore.dart';

void handleDatabaseWriteResult(DbResult result) {
  // 1. 쓰기가 에러 없이 완료되었는지 즉시 확인
  if (!result.hasErrors) {
    print("모든 쓰기 작업에 성공했습니다. 영향 건수: ${result.successCount}");

    // 단일 레코드 쓰기의 경우, statuses를 루프하지 않고 직접 키를 획득
    if (result.firstPrimaryKey != null) {
      print("첫 번째 성공 레코드의 주키: ${result.firstPrimaryKey}");
    }
  } else {
    print("🛑 에러가 검출되었습니다. 성공: ${result.successCount}, 실패: ${result.failedCount}");
    print("첫 번째 에러: ${result.firstType.codeKey} (${result.firstType.code})");

    // 2. statuses를 반복 처리(인덱스는 입력 배치 배열과 1:1로 일치)
    for (final status in result.statuses) {
      final int idx = status.index;

      // 3. 하위 클래스를 패턴 매칭하여 처리 로직을 라우팅
      if (status is SuccessStatus) {
        print("인덱스 [$idx] 성공. 주키: ${status.primaryKey}");
      } 
      else if (status is ConstraintStatus) {
        // 제약 조건 위반(주키, 고유, 체크, 외래키 등) 처리
        print("인덱스 [$idx] 제약 조건 위반! 테이블: ${status.tableName}, 열: ${status.fields}");
        print("충돌하는 값: ${status.conflictingKeys}, 주키: ${status.primaryKey}");
        print("에러 메시지: ${status.message}");
      } 
      else if (status is InvalidArgumentStatus) {
        // 매개변수 에러 처리
        print("인덱스 [$idx] 무효한 매개변수! 매개변수명: ${status.parameterName}, 전달된 값: ${status.passedValue}");
      } 
      else if (status is GeneralStatus) {
        // 락 타임아웃, 디스크 풀, 시스템 I/O 문제 등의 처리
        print("인덱스 [$idx] 일반적인 예외! 코드: ${status.code} (${status.codeKey})");
        print("메시지: ${status.message}");
      }
    }
  }
}
```

### 5.2 테이블 스키마 및 작업 예외 캐치 (`DbException`)

테이블 생성(`createTable`)이나 스키마 변경(`updateSchema`)에 있어서, 또는 스키마 정의가 코드 수준의 체크에 실패한 경우 ToStore는 프로덕션 환경에서 `DbException`을 발생시킵니다:

```dart
try {
  // 스키마 업데이트를 동반한 데이터베이스 오픈
  await ToStore.open(schemas: [..]);
} on DbException catch (e) {
  print("❌ 치명적인 데이터베이스 예외! 집계된 에러: \n${e.message}");
  
  // 예외 내의 개별 상태를 반복 처리
  for (final status in e.statuses) {
    if (status is SchemaValidationStatus) {
      // 스키마 유효성 검사기 문제
      print("스키마 검증 실패! 테이블: ${status.tableName}");
      if (status.field != null) {
        print("위배되는 필드: ${status.field}, 무효한 구성: ${status.wrongValue}");
      }
    } else {
      print("진단 정보: [${status.codeKey}] (Code ${status.code}): ${status.message}");
    }
  }
}
```

### 5.3 쿼리 작업 (`QueryResult`) 및 트랜잭션 제어 (`TransactionResult`) 처리

- **쿼리의 경우**:
  ```dart
  final queryResult = await db.query('users').where('age', '>', 18);
  if (queryResult.hasErrors) {
    // 쿼리 예외(유효하지 않은 커서, 누락된 테이블 등) 처리
    print("쿼리 실패! 코드: ${queryResult.type.code}, 메시지: ${queryResult.message}");
  } else {
    // 쿼리 실행 성공
    final List<Map<String, dynamic>> users = queryResult.data;
    print("${users.length} 건의 레코드를 가져왔습니다. 추가 데이터 있음: ${queryResult.hasMore}");
  }
  ```
- **트랜잭션의 경우**:
  ```dart
  final txnResult = await db.transaction(() async {
    await db.insert('users', newUser);
  });

  if (txnResult.hasErrors) {
    print("트랜잭션이 롤백되었습니다! TxId: ${txnResult.txId}");
    // 상세한 하위 작업 실패 이유 획득
    for (final status in txnResult.statuses) {
      if (status.type != ResultType.success) {
        print("실패 원인: [${status.codeKey}] ${status.message}");
      }
    }
  }
  ```

---

## 6. 전체 리프 상태 코드 및 의미론적 식별자 참조

정확한 상태 라우팅 및 분석에 대해서는 아래 표를 참조하십시오:

| 상태 코드 | 식별자（CodeKey） | 메모리 내 열거형（ResultType） | 범주 | 설명 |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `SUCCESS` | `ResultType.success` | 성공 | 작업이 성공적으로 실행되었습니다 |
| **10000** | `BIZ_VALIDATION_FAILED` | `ResultType.bizValidationFailed` | 비즈니스 오류 | 데이터 형식 또는 범위 검증 실패 |
| **10001** | `BIZ_NOT_NULL_VIOLATION` | `ResultType.bizNotNullViolation` | 비즈니스 오류 | NOT NULL 제약 조건 위반 |
| **10002** | `BIZ_VALIDATION_TYPE_CAST` | `ResultType.bizTypeCastFailed` | 비즈니스 오류 | 데이터 형식 변환 또는 캐스팅 실패 |
| **11001** | `BIZ_CONSTRAINT_PRIMARY_KEY` | `ResultType.bizPrimaryKeyViolation` | 비즈니스 오류 | 주키 충돌(이미 존재합니다) |
| **11002** | `BIZ_CONSTRAINT_UNIQUE` | `ResultType.bizUniqueViolation` | 비즈니스 오류 | 고유 제약 조건 위반 |
| **11003** | `BIZ_CONSTRAINT_FOREIGN_KEY` | `ResultType.bizForeignKeyViolation` | 비즈니스 오류 | 외래키 제약 조건 위반 (일반) |
| **11004** | `BIZ_CONSTRAINT_CHECK` | `ResultType.bizCheckViolation` | 비즈니스 오류 | CHECK 제약 조건 위반 |
| **11005** | `BIZ_CONSTRAINT_FOREIGN_KEY_PARENT_NOT_EXIST` | `ResultType.bizForeignKeyParentNotExist` | 비즈니스 오류 | 참조된 부모 키가 존재하지 않습니다 |
| **11006** | `BIZ_CONSTRAINT_FOREIGN_KEY_CHILD_RESTRICT` | `ResultType.bizForeignKeyChildRestrict` | 비즈니스 오류 | 자식 레코드에 의해 삭제/수정이 제한됨 |
| **11007** | `BIZ_CONSTRAINT_FOREIGN_KEY_COMPOSITE_MISMATCH` | `ResultType.bizForeignKeyCompositeMismatch` | 비즈니스 오류 | 복합 외래키의 값이 불완전합니다 |
| **11008** | `BIZ_CONSTRAINT_FOREIGN_KEY_TYPE_MISMATCH` | `ResultType.bizForeignKeyTypeMismatch` | 비즈니스 오류 | 외래키 형식이 일치하지 않습니다 |
| **11009** | `BIZ_CONSTRAINT_MAX_LENGTH` | `ResultType.bizValueExceedsMaxLength` | 비즈니스 오류 | 값의 길이가 스키마 제한을 초과합니다 |
| **11010** | `BIZ_CONSTRAINT_MIN_LENGTH` | `ResultType.bizValueLessThanMinLength` | 비즈니스 오류 | 값의 길이가 스키마 제한 미만입니다 |
| **11011** | `BIZ_CONSTRAINT_MIN_VALUE` | `ResultType.bizValueLessThanMinValue` | 비즈니스 오류 | 숫자가 스키마 제한 미만입니다 |
| **11012** | `BIZ_CONSTRAINT_MAX_VALUE` | `ResultType.bizValueExceedsMaxValue` | 비즈니스 오류 | 숫자가 스키마 제한을 초과합니다 |
| **12002** | `BIZ_NOT_FOUND_RECORD` | `ResultType.bizRecordNotFound` | 비즈니스 오류 | 리소스가 존재하지 않음 / 레코드 미검출 |
| **20001** | `DEV_INVALID_ARGUMENT_FORMAT` | `ResultType.devInvalidArgumentFormat` | 개발자 오류 | 인수 형식 오류 |
| **20002** | `DEV_INVALID_ARGUMENT_TYPE` | `ResultType.devInvalidArgumentType` | 개발자 오류 | 인수 형식 불일치 |
| **20003** | `DEV_INVALID_ARGUMENT_MISSING` | `ResultType.devInvalidArgumentMissing` | 개발자 오류 | 필수 인수가 누락되었습니다 |
| **20005** | `DEV_INVALID_PRIMARY_KEY_FORMAT` | `ResultType.devInvalidPrimaryKeyFormat` | 개발자 오류 | 무효한 PrimaryKey 형식 |
| **20007** | `DEV_INDEX_OUT_OF_BOUNDS` | `ResultType.devIndexOutOfBounds` | 개발자 오류 | 인덱스 또는 범위가 경계 외 |
| **20008** | `DEV_UNSUPPORTED_OPERATION` | `ResultType.devUnsupportedOperation` | 개발자 오류 | 현재 컨텍스트에서는 작업이 지원되지 않음 |
| **20010** | `DEV_VECTOR_DIMENSION_MISMATCH` | `ResultType.devVectorDimensionMismatch` | 개발자 오류 | 벡터 차원 불일치 |
| **20011** | `DEV_INDEX_FIELD_MISSING` | `ResultType.devIndexFieldMissing` | 개발자 오류 | 커서용 레코드에서 필요한 인덱스 필드 누락 |
| **20201** | `DEV_INVALID_CURSOR_PAGINATION` | `ResultType.devInvalidCursorPagination` | 개발자 오류 | 커서 페이지네이션과 오프셋은 상호 배타적입니다 |
| **20202** | `DEV_INVALID_CURSOR_TABLE` | `ResultType.devInvalidCursorTable` | 개발자 오류 | 커서가 대상 테이블과 일치하지 않습니다 |
| **20203** | `DEV_INVALID_CURSOR_SIGNATURE` | `ResultType.devInvalidCursorSignature` | 개발자 오류 | 커서 서명 불일치(변조됨) |
| **20204** | `DEV_INVALID_CURSOR_ORDERBY` | `ResultType.devInvalidCursorOrderBy` | 개발자 오류 | 커서 orderBy 구성이 무효 또는 불일치 |
| **20205** | `DEV_INVALID_CURSOR_MODE` | `ResultType.devInvalidCursorMode` | 개발자 오류 | 커서 토큰 모드 불일치 |
| **20206** | `DEV_INVALID_CURSOR_PAYLOAD` | `ResultType.devInvalidCursorPayload` | 개발자 오류 | 무효한 커서 페이로드(디코드 불가) |
| **20301** | `DEV_INVALID_QUERY_SELECT_FIELD` | `ResultType.devInvalidQuerySelectField` | 개발자 오류 | 쿼리 선택 필드는 String 또는 QueryAggregation이어야 합니다 |
| **20302** | `DEV_INVALID_QUERY_FOREIGN_KEY_JOIN` | `ResultType.devInvalidQueryForeignKeyJoin` | 개발자 오류 | 자동 조인용 외래키 관계가 존재하지 않습니다 |
| **20303** | `DEV_INVALID_QUERY_FIELD_ALIAS` | `ResultType.devInvalidQueryFieldAlias` | 개발자 오류 | 쿼리 필드 에일리어스 형식이 무효입니다 |
| **20304** | `DEV_INVALID_EXPRESSION` | `ResultType.devInvalidExpression` | 개발자 오류 | 무효한 식 구성 또는 실행 예외 |
| **22001** | `DEV_NOT_FOUND_TABLE` | `ResultType.devTableNotFound` | 개발자 오류 | 테이블을 찾을 수 없음 |
| **22003** | `DEV_NOT_FOUND_INDEX` | `ResultType.devIndexNotFound` | 개발자 오류 | 인덱스를 찾을 수 없음 |
| **22004** | `DEV_NOT_FOUND_SPACE` | `ResultType.devSpaceNotFound` | 개발자 오류 | 스페이스를 찾을 수 없음 |
| **22005** | `DEV_NOT_FOUND_FIELD` | `ResultType.devFieldNotFound` | 개발자 오류 | 필드를 찾을 수 없음 |
| **23001** | `DEV_LARGE_SCALE_OPERATION_REQUIRED_BYPASS` | `ResultType.devLargeScaleOperationBypassRequired` | 개발자 오류 | OOM 방지를 위해 결과 상세 건너뛰기 필요 |
| **24001** | `DEV_ENGINE_INCOMPATIBLE` | `ResultType.devEngineIncompatible` | 개발자 오류 | **심각**: 엔진 버전 불일치 |
| **30000** | `DEV_INVALID_SCHEMA` | `ResultType.devInvalidSchema` | 개발자 오류 | 유효하지 않은 테이블 스키마 정의 |
| **30001** | `DEV_INVALID_SCHEMA_TABLE_NAME` | `ResultType.devInvalidSchemaTableName` | 개발者 오류 | 테이블 이름 검증 오류 |
| **30002** | `DEV_INVALID_SCHEMA_FIELD_NAME` | `ResultType.devInvalidSchemaFieldName` | 개발자 오류 | 필드 이름 검증 오류 |
| **30003** | `DEV_INVALID_SCHEMA_PRIMARY_KEY` | `ResultType.devInvalidSchemaPrimaryKey` | 개발자 오류 | 주키 검증 오류 |
| **30004** | `DEV_INVALID_SCHEMA_INDEX_LIMIT` | `ResultType.devInvalidSchemaIndexLimit` | 개발자 오류 | 인덱스 수 검증 오류 |
| **30005** | `DEV_SCHEMA_TABLE_EXISTS` | `ResultType.devSchemaTableExists` | 개발자 오류 | 테이블이 이미 존재합니다 |
| **30006** | `DEV_SCHEMA_FIELD_EXISTS` | `ResultType.devSchemaFieldExists` | 개발자 오류 | 필드가 이미 존재합니다 |
| **30007** | `DEV_SCHEMA_INDEX_EXISTS` | `ResultType.devSchemaIndexExists` | 개발자 오류 | 인덱스가 이미 존재합니다 |
| **30008** | `DEV_INVALID_SCHEMA_FOREIGN_KEY` | `ResultType.devInvalidSchemaForeignKey` | 개발자 오류 | 외래키 정의가 무효 |
| **30009** | `DEV_INVALID_SCHEMA_SPACE_MISMATCH` | `ResultType.devInvalidSchemaSpaceMismatch` | 개발자 오류 | 글로벌/스페이스 고유의 경계 불일치 |
| **30010** | `DEV_MIGRATION_NOT_ALLOWED_WITH_DATA` | `ResultType.devMigrationNotAllowedWithData` | 개발자 오류 | 마이그레이션에 데이터 변경이 필요하지만 명시적으로 허용되지 않음 |
| **30011** | `DEV_MIGRATION_UNSAFE_TYPE_CONVERSION` | `ResultType.devMigrationUnsafeTypeConversion` | 개발자 오류 | 지원되지 않는 유형 변환 |
| **30013** | `DEV_MIGRATION_CANNOT_ADD_NON_NULL_FIELD` | `ResultType.devMigrationCannotAddNonNullField` | 개발자 오류 | 데이터가 있는 테이블에 기본값 없이 비NULL 필드를 추가할 수 없음 |
| **30014** | `DEV_MIGRATION_NULLABLE_TO_NON_NULL_NOT_ALLOWED` | `ResultType.devMigrationNullableToNonNullNotAllowed` | 개발자 오류 | 필드를 NULL 허용에서 비NULL로 변경할 수 없음 |
| **30015** | `DEV_MIGRATION_UNIQUE_TIGHTENING_NOT_ALLOWED` | `ResultType.devMigrationUniqueTighteningNotAllowed` | 개발자 오류 | 필드 제약 조건을 UNIQUE로 강화할 수 없음 |
| **30016** | `DEV_INVALID_SCHEMA_TTL_CONFIG` | `ResultType.devInvalidSchemaTtlConfig` | 개발자 오류 | TTL 구성 검증 실패 |
| **30017** | `DEV_INVALID_SCHEMA_DUPLICATE_FIELD_NAME` | `ResultType.devInvalidSchemaDuplicateFieldName` | 개발자 오류 | 테이블 스키마 내 중복된 필드 이름 |
| **30018** | `DEV_INVALID_SCHEMA_INDEX_FIELD` | `ResultType.devInvalidSchemaIndexField` | 개발자 오류 | 인덱스가 존재하지 않는 필드를 참조합니다 |
| **50001** | `SYS_TRANSACTION_ABORTED` | `ResultType.sysTransactionAborted` | 시스템 오류 | 트랜잭션이 중단되었습니다 |
| **50002** | `SYS_TRANSACTION_CONFLICT` | `ResultType.sysTransactionConflict` | 시스템 오류 | 트랜잭션 충돌 |
| **50003** | `SYS_MIGRATION_BATCH_EXECUTION_FAILED` | `ResultType.sysMigrationBatchExecutionFailed` | 시스템 오류 | **심각**: 마이그레이션 배치 실행 실패 |
| **51001** | `SYS_TIMEOUT_LOCK_ACQUISITION` | `ResultType.sysTimeoutLockAcquisition` | 시스템 오류 | 락 획득 타임아웃 |
| **51002** | `SYS_TIMEOUT` | `ResultType.sysTimeout` | 시스템 오류 | 작업 타임아웃 |
| **51003** | `SYS_CANCELLATION` | `ResultType.sysCancellation` | 시스템 오류 | 작업이 취소되었습니다 |
| **52001** | `SYS_RESOURCE_EXHAUSTED_MEMORY` | `ResultType.sysResourceExhaustedMemory` | 시스템 오류 | **심각**: 심각한 메모리 리소스 고갈 |
| **52002** | `SYS_RESOURCE_EXHAUSTED` | `ResultType.sysResourceExhausted` | 시스템 오류 | **심각**: 심각한 시스템 리소스 고갈 |
| **53001** | `SYS_IO_NOT_FOUND` | `ResultType.sysIoNotFound` | 시스템 오류 | 물리 파일 또는 경로가 존재하지 않음 |
| **53002** | `SYS_IO_PERMISSION_DENIED` | `ResultType.sysIoPermissionDenied` | 시스템 오류 | 파일 액세스 권한이 없음 |
| **53003** | `SYS_IO_DISK_FULL` | `ResultType.sysIoDiskFull` | 시스템 오류 | **심각**: 심각한 디스크 공간 부족 |
| **53004** | `SYS_IO_FILE_LOCKED` | `ResultType.sysIoFileLocked` | 시스템 오류 | 파일이 다른 프로세스에 의해 잠김 |
| **53005** | `SYS_IO_DEVICE_FAULT` | `ResultType.sysIoDeviceFault` | 시스템 오류 | **심각**: 심각한 스토리지 장치 또는 미디어 장애 |
| **53006** | `SYS_IO_WEB_STORAGE_UNAVAILABLE` | `ResultType.sysIoWebStorageUnavailable` | 시스템 오류 | Web IndexedDB 또는 스토리지를 사용할 수 없음 |
| **53007** | `SYS_BACKUP_CORRUPTED` | `ResultType.sysBackupCorrupted` | 시스템 오류 | 백업 패키지 손상 또는 메타데이터 누락 |
| **53008** | `SYS_IO_DATA_CORRUPTED` | `ResultType.sysIoDataCorrupted` | 시스템 오류 | **심각**: 심각한 데이터 파일 손상 |
| **53009** | `SYS_INVALID_DATA_FORMAT` | `ResultType.sysInvalidDataFormat` | 시스템 오류 | 데이터 스트림의 형식 또는 분석 실패 |
| **53099** | `SYS_IO_GENERIC` | `ResultType.sysIoGeneric` | 시스템 오류 | 일반적인 시스템 I/O 에러 |
| **99001** | `ENG_ERROR` | `ResultType.engError` | 엔진 에러 | 엔진 에러 |
