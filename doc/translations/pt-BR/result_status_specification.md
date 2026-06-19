# Especificação de Diagnóstico Automático & Resolução de Estado do ToStore ResultStatus

Para permitir que operações automatizadas (Ops), agentes de IA, scripts de teste automatizados e aplicações cliente identifiquem com precisão vários resultados de execução de banco de dados e estados de exceção, o ToStore introduz um sistema estruturado de `ResultStatus` em sua versão mais recente.

Este documento de especificação detalha os princípios de design de códigos de status, as especificações de chaves de identificadores semânticos e as estruturas de campos dedicados de vários tipos de status para ajudar os usuários do banco de dados e desenvolvedores a implementar a resolução de status de forma independente.

---

## 1. Princípios Fundamentais de Design

### 1.1 Especificação Numérica do Código de Status (code)

Todos os códigos de status numéricos (`code`) são definidos usando um comprimento fixo de 5 dígitos (exceto para o estado de sucesso):

- **Estado de Sucesso (Código de Sucesso Especial)**: Especialmente fixado em `0`.
- **Outros Estados (Códigos de Erro e Diagnóstico)**: Unificados em 5 dígitos.
- **Código de Classe**: Os dois primeiros dígitos do código de status, usados para identificar rapidamente a categoria principal.
- **Código Folha**: Os últimos três dígitos do código de status, representando o cenário de erro específico.

> [!TIP]
> Ao desenvolver Ops automatizadas, agentes de IA ou scripts de teste externos, os desenvolvedores podem rotear para os manipuladores de exceção correspondentes usando os dois primeiros dígitos (Código de Classe) ou o intervalo, e então realizar um tratamento detalhado com base no Código Folha.

> [!IMPORTANT]
> **Melhor Prática para Verificação em Memória (In-Memory Check)**:
> Ao ler os resultados das operações do banco de dados em memória (por exemplo, no código do cliente ou Dart/Flutter), **o método mais recomendado e eficiente é usar diretamente as propriedades de apenas leitura (getters) integradas** do `ResultStatus` ou `ResultType` (como `isBusinessError`, `isCriticalError`, etc., consulte a [Seção 3.2](#32-getters-auxiliares-em-mem%C3%B3ria)), evitando a análise manual de intervalos numéricos ou a correspondência de prefixo de string.

### 1.2 Especificação do Identificador Semântico de Estado (codeKey)

Cada status corresponde a um identificador de string exclusivo `codeKey`:

- **Formato de Nomeação**: `[Prefixo_Categoria_Principal]_[Identificador_Detalhe_Multinível]`.
- **Regra de Nomeação**: Composto por letras maiúsculas em inglês e sublinhados `_`, sem espaços ou caracteres especiais.
- **Prefixo de Categoria Principal**: Indica a qual categoria de negócios principal o estado pertence. Se existirem vários níveis de categoria, o prefixo mais genérico é colocado na frente para facilitar a pesquisa de prefixo e filtragem de intervalo.

---

## 2. Tabela de Referência Rápida de Códigos de Classe

Abaixo está a definição de mapeamento de todos os Códigos de Classe no ToStore:

| Intervalo de Código | Código de Classe (Primeiros 2 dígitos) | Prefixo Semântico | Categoria | Estratégia de Exceção |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `00` | `SUCCESS` | **Operação bem-sucedida** | Não lança exceção, retorna normalmente. |
| `10000 - 19999` | `10 - 19` | `BIZ_` | **Erro de Negócio** (Erros de entrada do usuário final, por exemplo, violações de restrição) | Não lança exceção, sempre respondido via `DbResult` ou `QueryResult`. |
| `20000 - 49999` | `20 - 49` | `DEV_` | **Erro de Desenvolvedor** (Parâmetros de API inválidos, configuração de esquema de tabela inválida, etc.) | **Lança `DbException` diretamente em ambientes de depuração** para alertar os desenvolvedores; **retorna normalmente como resultado em ambientes de produção**. *(Nota: a incompatibilidade da versão do motor e falhas de execução de lotes de migração principais são erros críticos, que lançam exceções mesmo em produção)* |
| `50000 - 79999` | `50 - 79` | `SYS_` | **Erro do Sistema** (Disco cheio, exceções de E/S, tempo limite de aquisição de bloqueio, etc.) | Lança exceção quando a execução normal é bloqueada; outros (por exemplo, conflito de transação) são respondidos como resultados. |
| `99000 - 99999` | `99` | `ENG_` | **Erro do Motor** (Erro lógico do motor, corrupção de arquivo de dados, erro interno desconhecido) | Geralmente não lança exceções; lança exceções para casos graves. |

---

## 3. Estrutura de Campos Comuns de ResultStatus e Auxiliares em Memória

### 3.1 Campos Comuns (Estrutura JSON Serializada)

Todos os tipos de `ResultStatus`, quando serializados para JSON, contêm os seguintes 4 campos comuns básicos. Os usuários podem ler esses campos diretamente para verificações preliminares.

| Campo | Tipo | Descrição |
| :--- | :--- | :--- |
| `index` | `int` | Índice de sequência em operações em lote. Para operações únicas, este valor é fixado em `0`. |
| `code` | `int` | Código de status numérico (`0` para sucesso, número de 5 dígitos para exceção). |
| `codeKey` | `String` | Chave do identificador semântico de estado, por exemplo, `CONSTRAINT_VIOLATION_UNIQUE`. |
| `message` | `String` | Descrição detalhada do status legível por humanos. |

### 3.2 Getters Auxiliares em Memória

No Dart/Flutter, `ResultStatus` e `ResultType` encapsulam propriedades de apenas leitura (Getters) altamente eficientes de `O(1)` para verificar a categoria e a gravidade em memória sem verificações manuais de intervalo ou correspondência de strings:

| Propriedade | Tipo | Descrição |
| :--- | :--- | :--- |
| `isBusinessError` | `bool` | Se é um **Erro de Negócio** (por exemplo, conflito de restrição, falha de conversão de tipo; intervalo `10000 - 19999`). |
| `isDeveloperError` | `bool` | Se é um **Erro de Desenvolvedor** (por exemplo, esquema inválido, incompatibilidade de parâmetros, tabela não encontrada; intervalo `20000 - 49999`). |
| `isSystemError` | `bool` | Se é um **Erro do Sistema** (por exemplo, tempo limite de bloqueio, disco cheio, bloqueio de arquivo; intervalo `50000 - 79999`). |
| `isEngineError` | `bool` | Se é um **Erro do Motor** (intervalo `99000 - 99999`). |
| `isCriticalError` | `bool` | Se é um **Erro Crítico / Evento de nível de desastre** (requer intervenção manual ou de operações, por exemplo, disco cheio, memória insuficiente, corrupção grave de arquivo de dados, falha de migração incompatível, etc.). |

---

## 4. Estruturas de Resolução Detalhadas e Campos Dedicados

Dependendo do intervalo de `code` / `codeKey` e da subclasse específica de `ResultStatus`, a estrutura JSON serializada carregará diferentes **campos de diagnóstico dedicados**. Abaixo estão as especificações dos campos e o mapeamento de aplicativos para as 5 subclasses de status.

### 4.1 SuccessStatus (Operação bem-sucedida)

- **Intervalo de Categoria**: `code == 0`, `codeKey == "SUCCESS"`
- **Cenário Aplicável**: Registros inseridos, modificados ou excluídos com sucesso.
- **Definição de Campo Dedicado**:

  | Campo | Tipo | Detalhes |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **Opcional**. Retornado apenas em gravações de linha única (por exemplo, `insert`) ou atualizações (por exemplo, `update`) representando a chave primária do registro gerado ou modificado fisicamente. |

- **Exemplo JSON**:
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

### 4.2 ConstraintStatus (Integridade de dados & conflitos de restrições)

- **Intervalo de Categoria**: `code` dentro de `[10000, 19999]` (principalmente validação e conflitos de restrição de integridade).
- **Definición de Campo Dedicado**:

  | Campo | Tipo | Detalhes |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **Obrigatório**. Nome da tabela onde ocorreu o conflito de restrição de integridade ou o erro de não encontrado. |
  | `constraintName` | `String?` | **Opcional**. O nome da restrição específica que causou o erro (por exemplo, `fk_users_profile` para chave estrangeira, nome do índice para conflito de unicidade ou `null` para erros de not-null ou de conversão de tipo). |
  | `fields` | `List<String>` | **Obrigatório**. Lista de campos que causaram o conflito. |
  | `conflictingKeys` | `List<dynamic>` | **Obrigatório**. Lista de valores de entrada que causaram o conflito, mapeando 1:1 com `fields`. Se um campo for nulo, o item correspondente na lista será `null`. |
  | `primaryKey` | `String?` | **Opcional**. Chave primária do registro associado. Se não for uma gravação de linha única, ou se foi bloqueado na fase de memória, será `null`. |
  | `referencedTable` | `String?` | **Opcional**. Nome da tabela pai em conflitos de chave estrangeira. |

- **Diretrizes para os Códigos Folha**:

  | Código & ResultType | Cenário | Diretrizes de Campos |
  | :--- | :--- | :--- |
  | `10000`<br>`bizValidationFailed` | Falha na validação do formato ou intervalo dos dados | <ul><li>`tableName`: Tabela afetada</li><li>`constraintName`: `null`</li><li>`fields`: Campos que violam a validação, por exemplo `["email"]`</li><li>`conflictingKeys`: Valores inválidos que causaram a falha, por exemplo `["invalid-email"]`</li><li>`primaryKey`: Chave primária do registro (se houver)</li></ul> |
  | `10001`<br>`bizNotNullViolation` | Violação de restrição not null | <ul><li>`tableName`: Tabela afetada</li><li>`constraintName`: `null`</li><li>`fields`: Campos que violam a restrição not-null, por exemplo `["email"]`</li><li>`conflictingKeys`: Sempre `[null]`</li><li>`primaryKey`: Chave primária do registro (se houver)</li></ul> |
  | `10002`<br>`bizTypeCastFailed` | Falha na conversão ou tipo de dados (cast) | <ul><li>`tableName`: Tabela afetada</li><li>`constraintName`: `null`</li><li>`fields`: Campos cuja conversão falhou, por exemplo `["age"]`</li><li>`conflictingKeys`: Valores inválidos que causaram a falha, por exemplo `["not_a_number"]`</li><li>`primaryKey`: Chave primária do registro (se houver)</li></ul> |
  | `11001`<br>`bizPrimaryKeyViolation` | Conflito de chave primária (já existe) | <ul><li>`tableName`: Tabela afetada</li><li>`constraintName`: `"PRIMARY"` ou nome da restrição</li><li>`fields`: Campos da chave primária, por exemplo `["id"]`</li><li>`conflictingKeys`: Valores duplicados, por exemplo `["usr_101"]`</li><li>`primaryKey`: Valor conflitante, por exemplo `"usr_101"`</li></ul> |
  | `11002`<br>`bizUniqueViolation` | Violação de restrição de unicidade | <ul><li>`tableName`: Tabela afetada</li><li>`constraintName`: Nome do índice exclusivo, por exemplo `"uk_email"`</li><li>`fields`: Campos que compõem a unicidade, por exemplo `["email"]`</li><li>`conflictingKeys`: Valores que causaram o conflito, por exemplo `["test@a.com"]`</li><li>`primaryKey`: Chave primária do registro conflitante (se houver)</li></ul> |
  | `11003`<br>`bizForeignKeyViolation` | Violação de restrição de chave estrangeira (Genérico) | <ul><li>`tableName`: Tabela filha (child)</li><li>`constraintName`: Nome da restrição de chave estrangeira</li><li>`fields`: Colunas de chave estrangeira</li><li>`conflictingKeys`: Valores de entrada que causaram o conflito</li><li>`primaryKey`: Chave primária do registro (se houver)</li><li>`referencedTable`: Tabela pai (parent)</li></ul> |
  | `11004`<br>`bizCheckViolation` | Violação de restrição check | <ul><li>`tableName`: Tabela afetada</li><li>`constraintName`: Nome da restrição check</li><li>`fields`: Campos verificados</li><li>`conflictingKeys`: Valores que violam o check</li><li>`primaryKey`: Chave primária del registro (se houver)</li></ul> |
  | `11005`<br>`bizForeignKeyParentNotExist` | A chave pai referenciada não existe | <ul><li>`tableName`: Tabela filha (child)</li><li>`constraintName`: Nome da restrição de chave estrangeira</li><li>`fields`: Colunas de chave estrangeira, por exemplo `["userId"]`</li><li>`conflictingKeys`: Valor de referência inexistente, por exemplo `["non_parent"]`</li><li>`primaryKey`: Chave primária do registro (se houver)</li><li>`referencedTable`: Tabela pai (parent)</li></ul> |
  | `11006`<br>`bizForeignKeyChildRestrict` | Exclusão/atualização restrita por registros filhos | <ul><li>`tableName`: Tabela pai (parent)</li><li>`constraintName`: Nome da restrição de chave estrangeira</li><li>`fields`: Colunas referenciadas da tabela pai</li><li>`conflictingKeys`: Valores da chave pai referenciados pela tabela filha</li><li>`primaryKey`: Valores da chave pai</li><li>`referencedTable`: Tabela filha (child)</li></ul> |
  | `11007`<br>`bizForeignKeyCompositeMismatch` | Valores de chave estrangeira composta incompletos | <ul><li>`tableName`: Tabela filha (child)</li><li>`constraintName`: Nome da restrição de chave estrangeira</li><li>`fields`: Colunas de chave estrangeira composta</li><li>`conflictingKeys`: Valores de entrada (contém nulos parciais)</li><li>`primaryKey`: Chave primária do registro (se houver)</li><li>`referencedTable`: Tabela pai (parent)</li></ul> |
  | `11008`<br>`bizForeignKeyTypeMismatch` | Incompatibilidade de tipo de chave estrangeira | <ul><li>`tableName`: Tabela filha (child)</li><li>`constraintName`: Nome da restrição de chave estrangeira</li><li>`fields`: Colunas de chave estrangeira</li><li>`conflictingKeys`: Valores cuja conversão falhou</li><li>`primaryKey`: Chave primária do registro (se houver)</li><li>`referencedTable`: Tabela pai (parent)</li></ul> |
  | `11009`<br>`bizValueExceedsMaxLength` | Comprimento do valor excede a restrição máxima | <ul><li>`tableName`: Tabela afetada</li><li>`constraintName`: `null`</li><li>`fields`: Campos que violam o limite, por exemplo `["name"]`</li><li>`conflictingKeys`: Valores transgressores, por exemplo `["a" * 1000]`</li><li>`primaryKey`: Chave primária do registro (se houver)</li></ul> |
  | `11010`<br>`bizValueLessThanMinLength` | Comprimento do valor é menor que a restrição mínima | <ul><li>`tableName`: Tabela afetada</li><li>`constraintName`: `null`</li><li>`fields`: Campos que violam o limite, por exemplo `["code"]`</li><li>`conflictingKeys`: Valores mais curtos que o mínimo, por exemplo `["ab"]`</li><li>`primaryKey`: Chave primária do registro (se houver)</li></ul> |
  | `11011`<br>`bizValueLessThanMinValue` | Valor numérico é menor que a restrição mínima | <ul><li>`tableName`: Tabela afetada</li><li>`constraintName`: `null`</li><li>`fields`: Campos que violam o limite, por exemplo `["age"]`</li><li>`conflictingKeys`: Valores menores que o mínimo, por exemplo `[-5]`</li><li>`primaryKey`: Chave primária do registro (se houver)</li></ul> |
  | `11012`<br>`bizValueExceedsMaxValue` | Valor numérico excede a restrição máxima | <ul><li>`tableName`: Tabela afetada</li><li>`constraintName`: `null`</li><li>`fields`: Campos que violan o limite, por exemplo `["score"]`</li><li>`conflictingKeys`: Valores que excedem o máximo, por exemplo `[105]`</li><li>`primaryKey`: Chave primária do registro (se houver)</li></ul> |
  | `12002`<br>`bizRecordNotFound` | Recurso não existe / Registro não encontrado | <ul><li>`tableName`: Tabela afetada</li><li>`constraintName`: `null`</li><li>`fields`: Campos de busca de destino, por exemplo `["id"]`</li><li>`conflictingKeys`: Chaves de destino não encontradas, por exemplo `["non_exist_id"]`</li><li>`primaryKey`: Valor da chave ausente, por exemplo `"non_exist_id"`</li></ul> |

- **Exemplo JSON** (Registro pai de chave estrangeira não existe):
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

### 4.3 SchemaValidationStatus (Validação de esquema de tabela & migração incompatível)

- **Intervalo de Categoria**: `code` dentro de `[30000, 39999]` (erros de verificação de configuração de esquema e incompatibilidades de migração física).
- **Definição de Campo Dedicado**:

  | Campo | Tipo | Detalhes |
  | :--- | :--- | :--- |
  | `tableName` | `String` | **Obrigatório**. Nome da tabela sendo validada ou migrada fisicamente. |
  | `field` | `String?` | **Opcional**. O nome do campo específico que desencadeou o erro de esquema ou migração. |
  | `wrongValue` | `dynamic` | **Opcional**. Valor de configuração inválido ou configuração de diferença de migração que causou o conflito. |

- **Diretrizes para os Códigos Folha**:

  | Código & ResultType | Cenário | Diretrizes de Campos |
  | :--- | :--- | :--- |
  | `30000`<br>`devInvalidSchema` | Definição de esquema de tabela inválida | <ul><li>`tableName`: Nome da tabela</li><li>`field`: `null`</li><li>`wrongValue`: Map de configuração inválida, ou `null`</li></ul> |
  | `30001`<br>`devInvalidSchemaTableName` | Falha na validação do nome da tabela (caracteres ilegais ou muito longo) | <ul><li>`tableName`: Nome transgressor</li><li>`field`: `null`</li><li>`wrongValue`: String transgressora</li></ul> |
  | `30002`<br>`devInvalidSchemaFieldName` | Falha na validação do nome do campo (caracteres ilegais) | <ul><li>`tableName`: Nome da tabela</li><li>`field`: Nome do campo transgressor</li><li>`wrongValue`: String transgressora</li></ul> |
  | `30003`<br>`devInvalidSchemaPrimaryKey` | Falha na validação da chave primária (ausente ou formato inválido) | <ul><li>`tableName`: Nome da tabela</li><li>`field`: `"primaryKey"` ou nome do campo da chave primária</li><li>`wrongValue`: Detalhes de configuração da chave primária</li></ul> |
  | `30004`<br>`devInvalidSchemaIndexLimit` | Contagem de índices da tabela excede o limite do sistema de 16 | <ul><li>`tableName`: Nome da tabela</li><li>`field`: `null`</li><li>`wrongValue`: Lista de configurações de índice</li></ul> |
  | `30005`<br>`devSchemaTableExists` | Tabela já existe | <ul><li>`tableName`: Nome da tabela</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30006`<br>`devSchemaFieldExists` | Atualização de esquema: adicionando um campo que já existe | <ul><li>`tableName`: Nome da tabela</li><li>`field`: Nome do campo conflitante</li><li>`wrongValue`: `null`</li></ul> |
  | `30007`<br>`devSchemaIndexExists` | Atualização de esquema: adicionando um índice que já existe | <ul><li>`tableName`: Nome da tabela</li><li>`field`: Nome do índice</li><li>`wrongValue`: `null`</li></ul> |
  | `30008`<br>`devInvalidSchemaForeignKey` | Definição de chave estrangeira inválida (por exemplo, colunas incompatíveis) | <ul><li>`tableName`: Nome da tabela</li><li>`field`: Nome da chave estrangeira</li><li>`wrongValue`: Detalhes de configuração da chave estrangeira</li></ul> |
  | `30009`<br>`devInvalidSchemaSpaceMismatch` | Incompatibilidade de limite global/específico do espaço | <ul><li>`tableName`: Nome da tabela</li><li>`field`: `null`</li><li>`wrongValue`: `null`</li></ul> |
  | `30010`<br>`devMigrationNotAllowedWithData` | A migração requer modificação de dados e não foi explicitamente permitida | <ul><li>`tableName`: Nome da tabela</li><li>`field`: `null`</li><li>`wrongValue`: Map de diferenças de atualização de migração</li></ul> |
  | `30011`<br>`devMigrationUnsafeTypeConversion` | Migração física: conversão de tipo não suportada para o campo | <ul><li>`tableName`: Nome da tabela</li><li>`field`: Nome do campo</li><li>`wrongValue`: Map de tipos conflitantes, por exemplo `{ "from": "text", "to": "integer" }`</li></ul> |
  | `30013`<br>`devMigrationCannotAddNonNullField` | Não é possível adicionar campo não-nulo sem um valor padrão a uma tabela não vazia | <ul><li>`tableName`: Nome da tabela</li><li>`field`: Nome do campo transgressor</li><li>`wrongValue`: Parâmetros de migração, por exemplo `{ "nullable": false, "defaultValue": null }`</li></ul> |
  | `30014`<br>`devMigrationNullableToNonNullNotAllowed` | Migração física: alterar campo de nullable para não-nullable | <ul><li>`tableName`: Nome da tabela</li><li>`field`: Nome do campo</li><li>`wrongValue`: Parâmetros de migração, idêntico a 30013</li></ul> |
  | `30015`<br>`devMigrationUniqueTighteningNotAllowed` | Migração física: restringir a restrição do campo para UNIQUE | <ul><li>`tableName`: Nome da tabela</li><li>`field`: Nome del campo</li><li>`wrongValue`: Definição do índice que causa a restrição exclusiva</li></ul> |
  | `30016`<br>`devInvalidSchemaTtlConfig` | Falha na validação da configuração TTL | <ul><li>`tableName`: Nome da tabela</li><li>`field`: Campo de registro de data/hora TTL</li><li>`wrongValue`: Map de configuração TTL inválido, por exemplo, `{ "enabled": true, "fieldName": "expire_at" }`</li></ul> |
  | `30017`<br>`devInvalidSchemaDuplicateFieldName` | Nome de campo duplicado no esquema da tabela | <ul><li>`tableName`: Nome da tabela</li><li>`field`: Nome de campo duplicado</li><li>`wrongValue`: `null`</li></ul> |
  | `30018`<br>`devInvalidSchemaIndexField` | Índice faz referência a um campo inexistente | <ul><li>`tableName`: Nome da tabela</li><li>`field`: Nome do índice</li><li>`wrongValue`: Nome do campo que causa a incompatibilidade</li></ul> |

- **Exemplo JSON** (Adicionar campo não-nulo sem valor padrão a uma tabela não vazia):
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

### 4.4 InvalidArgumentStatus (Argumentos de API & validação de paginação por cursor)

- **Intervalo de Categoria**: `code` dentro de `[20000, 20999]` (falhas de validação de parâmetros de API, estruturas de consulta ou tokens de paginação).
- **Definição de Campo Dedicado**:

  | Campo | Tipo | Detalhes |
  | :--- | :--- | :--- |
  | `parameterName` | `String` | **Obrigatório**. Nome do argumento que causou a falha de validação (por exemplo, `"cursor"`, `"orderBy"` ou chave de coluna específica). |
  | `passedValue` | `dynamic` | **Opcional**. Valor de entrada não conforme passado pelo chamador. Objetos complexos são convertidos em strings. |
  | `primaryKey` | `String?` | **Opcional**. Chave primária do registro associado. |

- **Diretrizes para os Códigos Folha**:

  | Código & ResultType | Cenário | Diretrizes de Campos |
  | :--- | :--- | :--- |
  | `20001`<br>`devInvalidArgumentFormat` | Erro de formato do argumento | <ul><li>`parameterName`: Nome do argumento inválido</li><li>`passedValue`: Valor passado, por exemplo `"twenty"`</li><li>`primaryKey`: Chave primária do registro (se houver)</li></ul> |
  | `20002`<br>`devInvalidArgumentType` | Incompatibilidade de tipo de argumento | <ul><li>`parameterName`: Nome do parâmetro</li><li>`passedValue`: Valor passado, por exemplo `{"foo": "bar"}` (quando String esperada)</li><li>`primaryKey`: Chave primária do registro (se houver)</li></ul> |
  | `20003`<br>`devInvalidArgumentMissing` | O argumento obrigatório está ausente | <ul><li>`parameterName`: Nome do parâmetro ausente, por exemplo `"dbPath"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: Chave primária do registro (se houver)</li></ul> |
  | `20005`<br>`devInvalidPrimaryKeyFormat` | Formato de chave primária inválido | <ul><li>`parameterName`: `"primaryKey"` ou campo de chave primária</li><li>`passedValue`: Valor de chave primária inválido, por exemplo, `"invalid_id_value"`</li><li>`primaryKey`: Valor de chave primária inválido</li></ul> |
  | `20010`<br>`devVectorDimensionMismatch` | Incompatibilidade de dimensões vetoriais | <ul><li>`parameterName`: `"other"`</li><li>`passedValue`: Tamanho de dimensão transgressor</li><li>`primaryKey`: `null`</li></ul> |
  | `20011`<br>`devIndexFieldMissing` | Campo de índice obrigatório está ausente no registro para o cursor | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Campo de índice ausente</li><li>`primaryKey`: `null`</li></ul> |
  | `20201`<br>`devInvalidCursorPagination` | A paginação por cursor e o offset são mutuamente exclusivos | <ul><li>`parameterName`: `"cursor"` / `"offset"`</li><li>`passedValue`: Parâmetros de paginação conflitantes</li><li>`primaryKey`: `null`</li></ul> |
  | `20202`<br>`devInvalidCursorTable` | O cursor não corresponde à tabela de destino | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Token do cursor</li><li>`primaryKey`: `null`</li></ul> |
  | `20203`<br>`devInvalidCursorSignature` | Assinatura do cursor incompatível (adulterada) | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Token do cursor</li><li>`primaryKey`: `null`</li></ul> |
  | `20204`<br>`devInvalidCursorOrderBy` | Configuração orderBy do cursor inválida ou incompatível | <ul><li>`parameterName`: `"orderBy"`</li><li>`passedValue`: Lista orderBy, por exemplo `["-age", "id"]`</li><li>`primaryKey`: `null`</li></ul> |
  | `20205`<br>`devInvalidCursorMode` | Incompatibilidade do modo de token do cursor | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: Modo token, por exemplo, `"sortKey"`</li><li>`primaryKey`: `null`</li></ul> |
  | `20206`<br>`devInvalidCursorPayload` | Carga útil do cursor inválida (indecodificável) | <ul><li>`parameterName`: `"cursor"`</li><li>`passedValue`: `null`</li><li>`primaryKey`: `null`</li></ul> |
  | `20301`<br>`devInvalidQuerySelectField` | Campo de seleção de consulta deve ser String ou QueryAggregation | <ul><li>`parameterName`: `"select"`</li><li>`passedValue`: Definição de campo select inválida</li><li>`primaryKey`: `null`</li></ul> |
  | `20302`<br>`devInvalidQueryForeignKeyJoin` | Nenhuma relação de chave estrangeira para auto-join | <ul><li>`parameterName`: `"join"` / `"tableName"`</li><li>`passedValue`: Tabela de destino sem relação</li><li>`primaryKey`: `null`</li></ul> |
  | `20303`<br>`devInvalidQueryFieldAlias` | Formato de alias de campo de consulta inválido | <ul><li>`parameterName`: `"alias"`</li><li>`passedValue`: String de alias inválida</li><li>`primaryKey`: `null`</li></ul> |
  | `20304`<br>`devInvalidExpression` | Configuração de expressão inválida ou exceção de execução | <ul><li>`parameterName`: Aspecto do erro (por exemplo, `"arguments"`, `"functionName"`, `"node"`)</li><li>`passedValue`: Valor ou contagem inválida</li><li>`primaryKey`: `null`</li></ul> |
  | `22005`<br>`devFieldNotFound` | Campo não encontrado | <ul><li>`parameterName`: Nome de campo desconhecido, por exemplo, `"extra"`</li><li>`passedValue`: Valor de entrada passado para o campo</li><li>`primaryKey`: Chave primária do registro (se houver)</li></ul> |

- **Exemplo JSON** (Os campos orderBy do cursor não correspondem à consulta atual orderBy):
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

### 4.5 TransactionOperationStatus (Conflito e aborto de transação)

- **Intervalo de Categoria**: `code` dentro de `[50000, 50999]` (rollback de transação, aborto explícito ou conflitos de serializabilidade).
- **Definição de Campo Dedicado**:

  | Campo | Tipo | Detalhes |
  | :--- | :--- | :--- |
  | `txId` | `String` | **Obrigatório**. Identificador de fluxo de transação exclusivo globalmente. Usado para rastrear o ciclo de vida da transação. |

- **Diretrizes para os Códigos Folha**:

  | Código & ResultType | Cenário | Diretrizes de Campos |
  | :--- | :--- | :--- |
  | `50001`<br>`sysTransactionAborted` | Transação abortada (rollback explícito ou falha em cascata) | <ul><li>`txId`: ID da transação ativa</li></ul> |
  | `50002`<br>`sysTransactionConflict` | Conflito de transação (atualizações simultâneas na mesma chave no SSI/WAL) | <ul><li>`txId`: ID da transação conflitante</li></ul> |

- **Exemplo JSON** (Conflito de escrita-escrita concorrente SSI):
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

### 4.6 GeneralStatus (Exceções genéricas e a nível de sistema)

- **Intervalo de Categoria**: Reserva para quaisquer outros códigos de status (E/S de baixo nível, erros de hardware, tempos limite do sistema, etc.).
- **Definição de Campo Dedicado**:

  | Campo | Tipo | Detalhes |
  | :--- | :--- | :--- |
  | `primaryKey` | `String?` | **Opcional**. Chave primária do registro associado. |
  | `target` | `String?` | **Opcional**. Recurso físico de destino, por exemplo, caminhos de arquivo físico, bloqueios ou URLs. |
  | `operation` | `String?` | **Opcional**. Nome da chamada de sistema ativa, por exemplo, `'readAsString'`, `'delete'`, `'acquire'`. |

- **Diretrizes para os Códigos Folha**:

  | Código & ResultType | Cenário / Nível | Diretrizes de Campos |
  | :--- | :--- | :--- |
  | `20007`<br>`devIndexOutOfBounds` | Índice ou intervalo fora dos limites (Erro de Desenvolvedor) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `20008`<br>`devUnsupportedOperation` | Operação não suportada no contexto atual (Erro de Desenvolvedor) | <ul><li>`primaryKey`: `null`</li><li>`target`: Tabela/recurso de destino (se houver)</li><li>`operation`: Nome do método (se houver)</li></ul> |
  | `22001`<br>`devTableNotFound` | Tabela não encontrada (Erro de Desenvolvedor) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22003`<br>`devIndexNotFound` | Índice não encontrado (Erro de Desenvolvedor) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `22004`<br>`devSpaceNotFound` | Espaço não encontrado (Erro de Desenvolvedor) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `23001`<br>`devLargeScaleOperationBypassRequired` | Pular detalhes é necessário para evitar OOM (Erro de Desenvolvedor) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `24001`<br>`devEngineIncompatible` | **Crítico**: Versão do motor incompatível | <ul><li>`primaryKey`: `null`</li></ul> |
  | `50003`<br>`sysMigrationBatchExecutionFailed` | Falha na execução do lote de migração (Erro do Sistema) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51001`<br>`sysTimeoutLockAcquisition` | Tempo limite de aquisição de bloqueio (Erro do Sistema) | <ul><li>`primaryKey`: Chave de destino (se houver)</li><li>`target`: ID do recurso de bloqueio</li><li>`operation`: `"acquire"`</li></ul> |
  | `51002`<br>`sysTimeout` | Tempo limite da operação (Erro do Sistema) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `51003`<br>`sysDbClosed` | O banco de dados está fechado, a operação foi cancelada com segurança (Erro do Sistema) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52001`<br>`sysResourceExhaustedMemory` | Recursos de memória esgotados (Erro do Sistema) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `52002`<br>`sysResourceExhausted` | Recursos do sistema esgotados, por exemplo, disco cheio (Erro do Sistema) | <ul><li>`primaryKey`: `null`</li></ul> |
  | `53001`<br>`sysIoNotFound` | Arquivo ou caminho físico não existe (Erro do Sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Caminho do arquivo ou pasta</li><li>`operation`: Operação de E/S</li></ul> |
  | `53002`<br>`sysIoPermissionDenied` | Permissão negada para acesso ao arquivo (Erro do Sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Caminho do arquivo</li><li>`operation`: Operação de E/S</li></ul> |
  | `53003`<br>`sysIoDiskFull` | Disco cheio ou cota de armazenamento excedida (Erro do Sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Caminho do arquivo</li><li>`operation`: Operação de E/S</li></ul> |
  | `53004`<br>`sysIoFileLocked` | Arquivo está bloqueado ou em uso por outro processo (Erro do Sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Caminho do arquivo</li><li>`operation`: Operação de E/S</li></ul> |
  | `53005`<br>`sysIoDeviceFault` | Falha no dispositivo ou mídia de armazenamento (Erro do Sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Caminho do arquivo</li><li>`operation`: Operação de E/S</li></ul> |
  | `53006`<br>`sysIoWebStorageUnavailable` | IndexedDB Web ou armazenamento não disponível (Erro do Sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Recurso IndexedDB</li><li>`operation`: Operação de E/S</li></ul> |
  | `53007`<br>`sysBackupCorrupted` | Pacote de backup corrompido ou metadados ausentes (Erro do Sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Caminho de backup</li><li>`operation`: Leitura/gravação de backup</li></ul> |
  | `53008`<br>`sysIoDataCorrupted` | Arquivo de dados do banco de dados corrompido ou falha de soma de verificação (Erro do Sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Caminho do arquivo de dados</li><li>`operation`: Operação de E/S</li></ul> |
  | `53009`<br>`sysInvalidDataFormat` | Falha na formatação ou análise do fluxo de dados (Erro do Sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Chave do fluxo de dados</li><li>`operation`: `"decode"` / `"deserialize"`</li></ul> |
  | `53099`<br>`sysIoGeneric` | Erro genérico de E/S do sistema (Erro do Sistema) | <ul><li>`primaryKey`: `null`</li><li>`target`: Caminho do arquivo</li><li>`operation`: Operação de E/S</li></ul> |
  | `99001`<br>`engError` | Erro do motor (Erro do motor) | <ul><li>`primaryKey`: `null`</li></ul> |

- **Exemplo JSON** (Erro de tabela não encontrada):
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

## 5. Recomendações de Resolução de Estado & Tratamento de Exceções (Exemplos Dart/Flutter)

No ToStore, todas as operações de gravação principais (Insert, Update, Delete) retornam um `DbResult`. Consultas retornam um `QueryResult` e operações de transação retornam um `TransactionResult`. Erros de configuração estrutural lançam uma `DbException`.

Abaixo estão exemplos de código que ilustram como as aplicações do desenvolvedor devem consumir, analisar e manipular adequadamente os status do banco de dados:

### 5.1 Tratando Respostas de Operação de Gravação (`DbResult`)

```dart
import 'package:tostore/tostore.dart';

void handleDatabaseWriteResult(DbResult result) {
  // 1. Verificar instantaneamente se a gravação foi concluída inteiramente sem erros
  if (!result.hasErrors) {
    print("Todas as operações de gravação foram bem-sucedidas. Afetados: ${result.successCount}");

    // Para gravações de linha única, obtenha a chave diretamente sem iterar status
    if (result.firstPrimaryKey != null) {
      print("Chave primária do primeiro registro bem-sucedido: ${result.firstPrimaryKey}");
    }
  } else {
    print("🛑 Erro detectado. Sucesso: ${result.successCount}, Falha: ${result.failedCount}");
    print("Primeiro erro: ${result.firstType.codeKey} (${result.firstType.code})");

    // 2. Iterar status (o índice se alinha 1:1 com a matriz de lote de entrada)
    for (final status in result.statuses) {
      final int idx = status.index;

      // 3. Casar padrões de subclasses para rotear a lógica de tratamento
      if (status is SuccessStatus) {
        print("Índice [$idx] Bem-sucedido. Chave primária: ${status.primaryKey}");
      } 
      else if (status is ConstraintStatus) {
        // Tratar violação de restrição (chave primária, unicidade, check, chave estrangeira, etc.)
        print("Índice [$idx] Violação de restrição! Tabela: ${status.tableName}, Colunas: ${status.fields}");
        print("Valores conflitantes: ${status.conflictingKeys}, PK: ${status.primaryKey}");
        print("Mensagem de Erro: ${status.message}");
      } 
      else if (status is InvalidArgumentStatus) {
        // Tratar erros de parâmetro
        print("Índice [$idx] Parâmetro inválido! Parâmetro: ${status.parameterName}, Valor Passado: ${status.passedValue}");
      } 
      else if (status is GeneralStatus) {
        // Tratar tempo limite de bloqueio, disco cheio, problemas de E/S do sistema, etc.
        print("Índice [$idx] Exceção genérica! Código: ${status.code} (${status.codeKey})");
        print("Mensagem: ${status.message}");
      }
    }
  }
}
```

### 5.2 Capturando Exceções de Esquema de Tabela e Operação (`DbException`)

Para criação de tabelas (`createTable`) ou alterações de esquema (`updateSchema`), ou em casos onde definições de esquema falham em verificações no nível do código, o ToStore lança uma `DbException` em produção:

```dart
try {
  // Abrir o banco de dados com atualizações de esquema
  await ToStore.open(schemas: [..]);
} on DbException catch (e) {
  print("❌ Exceção fatal de banco de dados! Erro agregado: \n${e.message}");
  
  // Iterar pelos status individuais na exceção
  for (final status in e.statuses) {
    if (status is SchemaValidationStatus) {
      // Problemas do validador de esquema
      print("Validação de esquema falhou! Tabela: ${status.tableName}");
      if (status.field != null) {
        print("Campo transgressor: ${status.field}, Configuração inválida: ${status.wrongValue}");
      }
    } else {
      print("Diagnóstico: [${status.codeKey}] (Código ${status.code}): ${status.message}");
    }
  }
}
```

### 5.3 Tratando Operações de Consulta (`QueryResult`) & Controles de Transação (`TransactionResult`)

- **Para Consultas**:
  ```dart
  final queryResult = await db.query('users').where('age', '>', 18);
  if (queryResult.hasErrors) {
    // Tratar exceções de consulta (por exemplo, cursor inválido, tabela ausente)
    print("Consulta falhou! Código: ${queryResult.type.code}, Mensagem: ${queryResult.message}");
  } else {
    // Consulta executada com sucesso
    final List<Map<String, dynamic>> users = queryResult.data;
    print("Recuperados ${users.length} registros. Tem mais: ${queryResult.hasMore}");
  }
  ```
- **Para Transações**:
  ```dart
  final txnResult = await db.transaction(() async {
    await db.insert('users', newUser);
  });

  if (txnResult.hasErrors) {
    print("Transação revertida! TxId: ${txnResult.txId}");
    // Puxar falhas detalhadas de suboperações individuais
    for (final status in txnResult.statuses) {
      if (status.type != ResultType.success) {
        print("Causa da falha: [${status.codeKey}] ${status.message}");
      }
    }
  }
  ```

---

## 6. Referência Completa de Códigos de Status Folha e Identificadores Semânticos

Consulte a tabela abaixo para roteamento e análise exatos do status:

| Código de Status (Code) | Identificador (CodeKey) | Enum em Memória (ResultType) | Categoria | Descrição |
| :--- | :--- | :--- | :--- | :--- |
| `0` | `SUCCESS` | `ResultType.success` | Sucesso | Operação executada com sucesso |
| **10000** | `BIZ_VALIDATION_FAILED` | `ResultType.bizValidationFailed` | Erro de Negócio | Falha na validação do formato ou intervalo dos dados |
| **10001** | `BIZ_NOT_NULL_VIOLATION` | `ResultType.bizNotNullViolation` | Erro de Negócio | Violação de restrição not null |
| **10002** | `BIZ_VALIDATION_TYPE_CAST` | `ResultType.bizTypeCastFailed` | Erro de Negócio | Falha na conversão ou tipo de dados (cast) |
| **11001** | `BIZ_CONSTRAINT_PRIMARY_KEY` | `ResultType.bizPrimaryKeyViolation` | Erro de Negócio | Conflito de chave primária (já existe) |
| **11002** | `BIZ_CONSTRAINT_UNIQUE` | `ResultType.bizUniqueViolation` | Erro de Negócio | Violação de restrição de unicidade |
| **11003** | `BIZ_CONSTRAINT_FOREIGN_KEY` | `ResultType.bizForeignKeyViolation` | Erro de Negócio | Violação de restrição de chave estrangeira (Genérico) |
| **11004** | `BIZ_CONSTRAINT_CHECK` | `ResultType.bizCheckViolation` | Erro de Negócio | Violação de restrição check |
| **11005** | `BIZ_CONSTRAINT_FOREIGN_KEY_PARENT_NOT_EXIST` | `ResultType.bizForeignKeyParentNotExist` | Erro de Negócio | A chave pai referenciada não existe |
| **11006** | `BIZ_CONSTRAINT_FOREIGN_KEY_CHILD_RESTRICT` | `ResultType.bizForeignKeyChildRestrict` | Erro de Negócio | Exclusão/atualização restrita por registros filhos |
| **11007** | `BIZ_CONSTRAINT_FOREIGN_KEY_COMPOSITE_MISMATCH` | `ResultType.bizForeignKeyCompositeMismatch` | Erro de Negócio | Valores de chave estrangeira composta incompletos |
| **11008** | `BIZ_CONSTRAINT_FOREIGN_KEY_TYPE_MISMATCH` | `ResultType.bizForeignKeyTypeMismatch` | Erro de Negócio | Incompatibilidade de tipo de chave estrangeira |
| **11009** | `BIZ_CONSTRAINT_MAX_LENGTH` | `ResultType.bizValueExceedsMaxLength` | Erro de Negócio | Comprimento do valor excede a restrição máxima |
| **11010** | `BIZ_CONSTRAINT_MIN_LENGTH` | `ResultType.bizValueLessThanMinLength` | Erro de Negócio | Comprimento do valor é menor que a restrição mínima |
| **11011** | `BIZ_CONSTRAINT_MIN_VALUE` | `ResultType.bizValueLessThanMinValue` | Erro de Negócio | Valor numérico é menor que a restrição mínima |
| **11012** | `BIZ_CONSTRAINT_MAX_VALUE` | `ResultType.bizValueExceedsMaxValue` | Erro de Negócio | Valor numérico excede a restrição máxima |
| **12002** | `BIZ_NOT_FOUND_RECORD` | `ResultType.bizRecordNotFound` | Erro de Negócio | Recurso não existe / Registro não encontrado |
| **20001** | `DEV_INVALID_ARGUMENT_FORMAT` | `ResultType.devInvalidArgumentFormat` | Erro de Desenvolvedor | Erro de formato do argumento |
| **20002** | `DEV_INVALID_ARGUMENT_TYPE` | `ResultType.devInvalidArgumentType` | Erro de Desenvolvedor | Incompatibilidade de tipo de argumento |
| **20003** | `DEV_INVALID_ARGUMENT_MISSING` | `ResultType.devInvalidArgumentMissing` | Erro de Desenvolvedor | O argumento obrigatório está ausente |
| **20005** | `DEV_INVALID_PRIMARY_KEY_FORMAT` | `ResultType.devInvalidPrimaryKeyFormat` | Erro de Desenvolvedor | Formato de chave primária inválido |
| **20007** | `DEV_INDEX_OUT_OF_BOUNDS` | `ResultType.devIndexOutOfBounds` | Erro de Desenvolvedor | Índice ou intervalo fora dos limites |
| **20008** | `DEV_UNSUPPORTED_OPERATION` | `ResultType.devUnsupportedOperation` | Erro de Desenvolvedor | Operação não suportada no contexto atual |
| **20010** | `DEV_VECTOR_DIMENSION_MISMATCH` | `ResultType.devVectorDimensionMismatch` | Erro de Desenvolvedor | Incompatibilidade de dimensões vetoriais |
| **20011** | `DEV_INDEX_FIELD_MISSING` | `ResultType.devIndexFieldMissing` | Erro de Desenvolvedor | Campo de índice obrigatório está ausente no registro para o cursor |
| **20201** | `DEV_INVALID_CURSOR_PAGINATION` | `ResultType.devInvalidCursorPagination` | Erro de Desenvolvedor | Paginação por cursor e offset são mutuamente exclusivos |
| **20202** | `DEV_INVALID_CURSOR_TABLE` | `ResultType.devInvalidCursorTable` | Erro de Desenvolvedor | O cursor não corresponde à tabela de destino |
| **20203** | `DEV_INVALID_CURSOR_SIGNATURE` | `ResultType.devInvalidCursorSignature` | Erro de Desenvolvedor | Assinatura do cursor incompatível (adulterada) |
| **20204** | `DEV_INVALID_CURSOR_ORDERBY` | `ResultType.devInvalidCursorOrderBy` | Erro de Desenvolvedor | Configuração orderBy do cursor inválida ou incompatível |
| **20205** | `DEV_INVALID_CURSOR_MODE` | `ResultType.devInvalidCursorMode` | Erro de Desenvolvedor | Incompatibilidade do modo de token do cursor |
| **20206** | `DEV_INVALID_CURSOR_PAYLOAD` | `ResultType.devInvalidCursorPayload` | Erro de Desenvolvedor | Carga útil do cursor inválida (indecodificável) |
| **20301** | `DEV_INVALID_QUERY_SELECT_FIELD` | `ResultType.devInvalidQuerySelectField` | Erro de Desenvolvedor | Campo de seleção de consulta deve ser String ou QueryAggregation |
| **20302** | `DEV_INVALID_QUERY_FOREIGN_KEY_JOIN` | `ResultType.devInvalidQueryForeignKeyJoin` | Erro de Desenvolvedor | Nenhuma relação de chave estrangeira para auto-join |
| **20303** | `DEV_INVALID_QUERY_FIELD_ALIAS` | `ResultType.devInvalidQueryFieldAlias` | Erro de Desenvolvedor | Formato de alias de campo de consulta inválido |
| **20304** | `DEV_INVALID_EXPRESSION` | `ResultType.devInvalidExpression` | Erro de Desenvolvedor | Configuração de expressão inválida ou exceção de execução |
| **22001** | `DEV_NOT_FOUND_TABLE` | `ResultType.devTableNotFound` | Erro de Desenvolvedor | Tabela não encontrada |
| **22003** | `DEV_NOT_FOUND_INDEX` | `ResultType.devIndexNotFound` | Erro de Desenvolvedor | Índice não encontrado |
| **22004** | `DEV_NOT_FOUND_SPACE` | `ResultType.devSpaceNotFound` | Erro de Desenvolvedor | Espaço não encontrado |
| **22005** | `DEV_NOT_FOUND_FIELD` | `ResultType.devFieldNotFound` | Erro de Desenvolvedor | Campo não encontrado |
| **23001** | `DEV_LARGE_SCALE_OPERATION_REQUIRED_BYPASS` | `ResultType.devLargeScaleOperationBypassRequired` | Erro de Desenvolvedor | Operação em larga escala requer omitir detalhes para evitar OOM |
| **24001** | `DEV_ENGINE_INCOMPATIBLE` | `ResultType.devEngineIncompatible` | Erro de Desenvolvedor | **Crítico**: Versão do motor incompatível |
| **30000** | `DEV_INVALID_SCHEMA` | `ResultType.devInvalidSchema` | Erro de Desenvolvedor | Definição de esquema de tabela inválida |
| **30001** | `DEV_INVALID_SCHEMA_TABLE_NAME` | `ResultType.devInvalidSchemaTableName` | Erro de Desenvolvedor | Falha na validação do nome da tabela |
| **30002** | `DEV_INVALID_SCHEMA_FIELD_NAME` | `ResultType.devInvalidSchemaFieldName` | Erro de Desenvolvedor | Falha na validação del nome do campo |
| **30003** | `DEV_INVALID_SCHEMA_PRIMARY_KEY` | `ResultType.devInvalidSchemaPrimaryKey` | Erro de Desenvolvedor | Falha na validação da chave primária |
| **30004** | `DEV_INVALID_SCHEMA_INDEX_LIMIT` | `ResultType.devInvalidSchemaIndexLimit` | Erro de Desenvolvedor | Falha na validação da contagem de índices |
| **30005** | `DEV_SCHEMA_TABLE_EXISTS` | `ResultType.devSchemaTableExists` | Erro de Desenvolvedor | Tabela já existe |
| **30006** | `DEV_SCHEMA_FIELD_EXISTS` | `ResultType.devSchemaFieldExists` | Erro de Desenvolvedor | Campo já existe |
| **30007** | `DEV_SCHEMA_INDEX_EXISTS` | `ResultType.devSchemaIndexExists` | Erro de Desenvolvedor | Índice já existe |
| **30008** | `DEV_INVALID_SCHEMA_FOREIGN_KEY` | `ResultType.devInvalidSchemaForeignKey` | Erro de Desenvolvedor | Definição de chave estrangeira inválida |
| **30009** | `DEV_INVALID_SCHEMA_SPACE_MISMATCH` | `ResultType.devInvalidSchemaSpaceMismatch` | Erro de Desenvolvedor | Incompatibilidade de limite global/específico do espaço |
| **30010** | `DEV_MIGRATION_NOT_ALLOWED_WITH_DATA` | `ResultType.devMigrationNotAllowedWithData` | Erro de Desenvolvedor | A migração requer modificação de dados e não foi explicitamente permitida |
| **30011** | `DEV_MIGRATION_UNSAFE_TYPE_CONVERSION` | `ResultType.devMigrationUnsafeTypeConversion` | Erro de Desenvolvedor | Alteração de tipo de dados não suportada para o campo |
| **30013** | `DEV_MIGRATION_CANNOT_ADD_NON_NULL_FIELD` | `ResultType.devMigrationCannotAddNonNullField` | Erro de Desenvolvedor | Não é permitido adicionar campo não-nulo sem valor padrão |
| **30014** | `DEV_MIGRATION_NULLABLE_TO_NON_NULL_NOT_ALLOWED` | `ResultType.devMigrationNullableToNonNullNotAllowed` | Erro de Desenvolvedor | Não é permitido alterar campo de nullable para não-nullable |
| **30015** | `DEV_MIGRATION_UNIQUE_TIGHTENING_NOT_ALLOWED` | `ResultType.devMigrationUniqueTighteningNotAllowed` | Erro de Desenvolvedor | Restringir para UNIQUE não é permitido |
| **30016** | `DEV_INVALID_SCHEMA_TTL_CONFIG` | `ResultType.devInvalidSchemaTtlConfig` | Erro de Desenvolvedor | Falha na validação da configuração TTL |
| **30017** | `DEV_INVALID_SCHEMA_DUPLICATE_FIELD_NAME` | `ResultType.devInvalidSchemaDuplicateFieldName` | Erro de Desenvolvedor | Nome de campo duplicado no esquema da tabela |
| **30018** | `DEV_INVALID_SCHEMA_INDEX_FIELD` | `ResultType.devInvalidSchemaIndexField` | Erro de Desenvolvedor | Índice faz referência a um campo inexistente |
| **50001** | `SYS_TRANSACTION_ABORTED` | `ResultType.sysTransactionAborted` | Erro do Sistema | Transação abortada |
| **50002** | `SYS_TRANSACTION_CONFLICT` | `ResultType.sysTransactionConflict` | Erro do Sistema | Conflito de transação |
| **50003** | `SYS_MIGRATION_BATCH_EXECUTION_FAILED` | `ResultType.sysMigrationBatchExecutionFailed` | Erro do Sistema | **Crítico**: Falha na execução do lote de migração |
| **51001** | `SYS_TIMEOUT_LOCK_ACQUISITION` | `ResultType.sysTimeoutLockAcquisition` | Erro do Sistema | Tempo limite de aquisição de bloqueio |
| **51002** | `SYS_TIMEOUT` | `ResultType.sysTimeout` | Erro do Sistema | Tempo limite da operação |
| **51003** | `SYS_DB_CLOSED` | `ResultType.sysDbClosed` | Erro do Sistema | O banco de dados está fechado, a operação foi cancelada com segurança |
| **52001** | `SYS_RESOURCE_EXHAUSTED_MEMORY` | `ResultType.sysResourceExhaustedMemory` | Erro do Sistema | **Crítico**: Recursos de memória esgotados |
| **52002** | `SYS_RESOURCE_EXHAUSTED` | `ResultType.sysResourceExhausted` | Erro do Sistema | **Crítico**: Recursos do sistema esgotados |
| **53001** | `SYS_IO_NOT_FOUND` | `ResultType.sysIoNotFound` | Erro do Sistema | Arquivo ou caminho físico não existe |
| **53002** | `SYS_IO_PERMISSION_DENIED` | `ResultType.sysIoPermissionDenied` | Erro do Sistema | Permissão negada para acesso ao arquivo |
| **53003** | `SYS_IO_DISK_FULL` | `ResultType.sysIoDiskFull` | Erro do Sistema | **Crítico**: Disco cheio ou cota de armazenamento excedida |
| **53004** | `SYS_IO_FILE_LOCKED` | `ResultType.sysIoFileLocked` | Erro do Sistema | Arquivo está bloqueado ou em uso por outro processo |
| **53005** | `SYS_IO_DEVICE_FAULT` | `ResultType.sysIoDeviceFault` | Erro do Sistema | **Crítico**: Falha no dispositivo ou mídia de armazenamento |
| **53006** | `SYS_IO_WEB_STORAGE_UNAVAILABLE` | `ResultType.sysIoWebStorageUnavailable` | Erro do Sistema | Web IndexedDB ou armazenamento não disponível |
| **53007** | `SYS_BACKUP_CORRUPTED` | `ResultType.sysBackupCorrupted` | Erro do Sistema | Pacote de backup corrompido ou metadados ausentes |
| **53008** | `SYS_IO_DATA_CORRUPTED` | `ResultType.sysIoDataCorrupted` | Erro do Sistema | **Crítico**: Arquivo de dados do banco de dados corrompido ou falha de soma de verificação |
| **53009** | `SYS_INVALID_DATA_FORMAT` | `ResultType.sysInvalidDataFormat` | Erro do Sistema | Falha na formatação ou análise do fluxo de dados |
| **53099** | `SYS_IO_GENERIC` | `ResultType.sysIoGeneric` | Erro do Sistema | Erro genérico de E/S do sistema |
| **99001** | `ENG_ERROR` | `ResultType.engError` | Erro do Motor | Erro do motor |
