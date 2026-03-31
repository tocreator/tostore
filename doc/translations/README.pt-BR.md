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
  <a href="README.ko.md">한국어</a> | 
  <a href="README.es.md">Español</a> | 
  Português (Brasil) | 
  <a href="README.ru.md">Русский</a> | 
  <a href="README.de.md">Deutsch</a> | 
  <a href="README.fr.md">Français</a> | 
  <a href="README.it.md">Italiano</a> | 
  <a href="README.tr.md">Türkçe</a>
</p>


## Navegação Rápida

- [Por que ToStore?](#why-tostore) | [Destaques](#key-features) | [Instalação](#installation) | [Início Rápido](#quick-start)
- [Definição de Esquema](#schema-definition) | [Integração Móvel/Desktop](#mobile-integration) | [Integração Servidor](#server-integration)
- [Vetores e Busca ANN](#vector-advanced) | [TTL por Tabela](#ttl-config) | [Consulta e Paginação](#query-pagination) | [Chaves Estrangeiras](#foreign-keys) | [Operadores de Consulta](#query-operators)
- [Arquitetura Distribuída](#distributed-architecture) | [Exemplos de Chaves Primárias](#primary-key-examples) | [Operações Atômicas](#atomic-expressions) | [Transações](#transactions) | [Gerenciamento e Manutenção do Banco de Dados](#database-maintenance) | [Backup e Restauração](#backup-restore) | [Tratamento de Erros](#error-handling) | [Callback de logs e diagnóstico de banco de dados](#logging-diagnostics)
- [Configuração de Segurança](#security-config) | [Performance](#performance) | [Mais Recursos](#more-resources)


<a id="why-tostore"></a>
## Por que escolher o ToStore?

O ToStore é um motor de dados moderno concebido para a era da AGI e cenários de inteligência na borda (edge intelligence). Suporta nativamente sistemas distribuídos, fusão multimodal, dados relacionais estruturados, vetores de alta dimensão e armazenamento de dados não estruturados. Baseado numa arquitetura subjacente semelhante a uma rede neural, os nós possuem elevada autonomia e escalabilidade horizontal elástica, construindo uma rede de topologia de dados flexível para uma colaboração fluida entre a borda e a nuvem em múltiplas plataformas. Oferece transações ACID, consultas relacionais complexas (JOIN, chaves estrangeiras em cascata), TTL ao nível da tabela e cálculos de agregação. Inclui múltiplos algoritmos de chaves primárias distribuídas, expressões atômicas, identificação de alterações no esquema, proteção por criptografia, isolamento de dados em múltiplos espaços, escalonamento inteligente de carga sensível aos recursos e recuperação automática contra desastres ou falhas.

À medida que o centro de gravidade da computação continua a deslocar-se para a inteligência na borda, diversos terminais como agentes e sensores deixam de ser meros "visualizadores de conteúdo" e passam a ser nós inteligentes responsáveis pela geração local, perceção do ambiente, tomada de decisões em tempo real e colaboração de dados. As soluções de bases de dados tradicionais, limitadas pela sua arquitetura subjacente e extensões do tipo "plug-in", têm dificuldade em cumprir os requisitos de baixa latência e estabilidade das aplicações inteligentes na borda e na nuvem ao lidar com escritas de alta concorrência, dados massivos, busca vetorial e geração colaborativa.

O ToStore dá à borda capacidades distribuídas suficientes para suportar dados massivos, geração complexa de IA local e fluxos de dados a larga escala. A colaboração inteligente profunda entre os nós da borda e da nuvem proporciona uma base de dados fiável para cenários como fusão imersiva AR/VR, interação multimodal, vetores semânticos e modelação espacial.


<a id="key-features"></a>
## Destaques

- 🌐 **Motor de Dados Multiplataforma Unificado**
  - API unificada para Móvel, Desktop, Web e Servidor.
  - Suporta dados estruturados relacionais, vetores de alta dimensão e armazenamento de dados não estruturados.
  - Ideal para ciclos de vida de dados desde o armazenamento local até à colaboração entre borda e nuvem.

- 🧠 **Arquitetura Distribuída Semelhante a uma Rede Neural**
  - Elevada autonomia dos nós; a colaboração interconectada constrói topologias de dados flexíveis.
  - Suporta colaboração de nós e escalabilidade horizontal elástica.
  - Interconexão profunda entre nós inteligentes na borda e a nuvem.

- ⚡ **Execução Paralela e Escalonamento de Recursos**
  - Escalonamento inteligente de carga sensível aos recursos com alta disponibilidade.
  - Computação colaborativa paralela multinó e decomposição de tarefas.

- 🔍 **Consulta Estruturada e Busca Vetorial**
  - Suporta consultas de condições complexas, JOINs, cálculos de agregação e TTL por tabela.
  - Suporta campos vetoriais, índices vetoriais e busca de vizinhos mais próximos (ANN).
  - Dados estruturados e vetoriais podem ser usados colaborativamente no mesmo motor.

- 🔑 **Chaves Primárias, Indexação e Evolução do Esquema**
  - Algoritmos integrados de incremento sequencial, marca de tempo, prefixo de data e código curto.
  - Suporta índices únicos, índices compostos, índices vetoriais e restrições de chave estrangeira.
  - Identifica inteligentemente alterações no esquema e automatiza a migração de dados.

- 🛡️ **Transações, Segurança e Recuperação**
  - Oferece transações ACID, atualizações de expressões atómicas e chaves estrangeiras em cascata.
  - Suporta recuperação contra falhas, persistência em disco e garantias de consistência de dados.
  - Suporta criptografia ChaCha20-Poly1305 e AES-256-GCM.

- 🔄 **Multi-espaço e Fluxo de Trabalho de Dados**
  - Suporta isolamento de dados via Espaços com partilha global configurável.
  - Ouvintes de consultas em tempo real, cache inteligente multinível e paginação por cursor.
  - Perfeito para aplicações multiutilizador, de prioridade local e colaboração offline.


<a id="installation"></a>
## Instalação

> [!IMPORTANT]
> **Atualizando da v2.x?** Leia o [Guia de Atualização v3.x](../UPGRADE_GUIDE_v3.md) para passos críticos de migração e mudanças importantes.

Adicione `tostore` como dependência no seu `pubspec.yaml`:

```yaml
dependencies:
  tostore: any # Use a versão mais recente
```

<a id="quick-start"></a>
## Início Rápido

> [!TIP]
> **Suporta armazenamento híbrido de dados estruturados e não estruturados**
> Como escolher a forma de armazenamento?
> 1. **Dados centrais do negócio**: recomenda-se [Definição de Esquema](#schema-definition). Adequado para consultas complexas, validação de restrições, relacionamentos ou requisitos mais altos de segurança. Ao levar a lógica de integridade para o motor, o custo de desenvolvimento e manutenção na aplicação cai bastante.
> 2. **Dados dinâmicos/dispersos**: pode usar diretamente o [Armazenamento Chave-Valor (KV)](#quick-start) ou definir campos `DataType.json` em tabelas. Adequado para configuração ou estado disperso, priorizando adoção rápida e máxima flexibilidade.

### Modo de tabela estruturada (Table)
As operações CRUD exigem criar o esquema da tabela com antecedência (veja [Definição de Esquema](#schema-definition)). Recomendações conforme o cenário:
- **Móvel/Desktop**: para [cenários de inicialização frequente](#mobile-integration), recomenda-se passar `schemas` ao inicializar a instância.
- **Servidor/Agente**: para [cenários de execução contínua](#server-integration), recomenda-se criar dinamicamente com `createTables`.

```dart
// 1. Inicializar a base de dados
final db = await ToStore.open();

// 2. Inserir dados
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. Consultas encadeadas (veja [Operadores de Consulta](#query-operators); suporta =, !=, >, <, LIKE, IN, etc.)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(20);

// 4. Atualizar e Remover
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. Escuta em Tempo Real (a UI atualiza automaticamente quando os dados mudam)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Usuários correspondentes atualizados: $users');
});
```

### Armazenamento Chave-Valor (KV)
Adequado para cenários que não exigem tabelas estruturadas. Simples e prático, inclui um armazenamento KV de alta performance integrado para configuração, estado e outros dados dispersos. Dados em Espaços diferentes são isolados por defeito, mas podem ser configurados para partilha global.

```dart
// Inicializar a base de dados
final db = await ToStore.open();

// Definir pares chave-valor (suporta String, int, bool, double, Map, List, etc.)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// Obter dados
final theme = await db.getValue('theme'); // 'dark'

// Remover dados
await db.removeValue('theme');

// Chave-valor global (partilhado entre Espaços)
// Dados KV normais tornam-se inativos ao mudar de espaço. Use isGlobal: true para partilha global.
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```


<a id="schema-definition"></a>
## Definição de Esquema
**Uma única definição permite que o motor assuma a governança automatizada de ponta a ponta e livra a aplicação de manter validações pesadas no longo prazo.**

Os exemplos a seguir para móvel, servidor e agente reutilizam `appSchemas` definido aqui.

### Visão Geral do TableSchema

```dart
const userSchema = TableSchema(
  name: 'users', // Nome da tabela, obrigatório
  tableId: 'users', // Identificador único, opcional; para deteção 100% precisa de renomeação
  primaryKeyConfig: PrimaryKeyConfig(
    name: 'id', // Nome do campo PK, por defeito 'id'
    type: PrimaryKeyType.sequential, // Tipo de auto-geração
    sequentialConfig: SequentialIdConfig(
      initialValue: 1000, // Valor inicial
      increment: 1, // Tamanho do passo
      useRandomIncrement: false, // Usar incrementos aleatórios
    ),
  ),
  fields: [
    FieldSchema(
      name: 'username', // Nome do campo, obrigatório
      type: DataType.text, // Tipo de dado, obrigatório
      nullable: false, // Permitir null
      minLength: 3, // Comprimento mín
      maxLength: 32, // Comprimento máx
      unique: true, // Restrição de unicidade
      fieldId: 'username', // ID único do campo, opcional; para identificar renomeações
      comment: 'Nome de login', // Comentário opcional
    ),
    FieldSchema(
      name: 'status',
      type: DataType.integer,
      minValue: 0, // Limite inferior
      maxValue: 150, // Limite superior
      defaultValue: 0, // Valor padrão estático
      createIndex: true,  // Atalho para criar índice e melhorar performance
    ),
    FieldSchema(
      name: 'created_at',
      type: DataType.datetime,
      nullable: false,
      defaultValueType: DefaultValueType.currentTimestamp, // Preencher com hora atual
      createIndex: true,
    ),
  ],
  indexes: const [
    IndexSchema(
      indexName: 'idx_users_status_created_at', // Nome opcional do índice
      fields: ['status', 'created_at'], // Campos do índice composto
      unique: false, // Se é um índice único
      type: IndexType.btree, // Tipo: btree/hash/bitmap/vector
    ),
  ],
  foreignKeys: const [], // Restrições opcionais; veja exemplo em "Chaves Estrangeiras"
  isGlobal: false, // Se é global; acessível em todos os Espaços
  ttlConfig: null, // TTL por tabela; veja exemplo em "TTL por Tabela"
);

const appSchemas = [userSchema];
```

`DataType` suporta `integer`, `bigInt`, `double`, `text`, `blob`, `boolean`, `datetime`, `array`, `json`, `vector`. `PrimaryKeyType` suporta `none`, `sequential`, `timestampBased`, `datePrefixed`, `shortCode`.

### Restrições e Auto-validação

Pode definir regras de validação comuns diretamente no esquema usando `FieldSchema`, evitando lógica duplicada na UI ou serviços:

- `nullable: false`: Restrição de não-nulo.
- `minLength` / `maxLength`: Restrições de comprimento de texto.
- `minValue` / `maxValue`: Restrições de intervalo numérico.
- `defaultValue` / `defaultValueType`: Valores padrão estáticos e dinâmicos.
- `unique`: Restrição de unicidade.
- `createIndex`: Cria índice para filtragem, ordenação ou joins frequentes.
- `fieldId` / `tableId`: Ajuda a identificar campos ou tabelas renomeados durante migrações.

Estas restrições são validadas na escrita dos dados, reduzindo implementações manuais. `unique: true` gera automaticamente um índice único. `createIndex: true` e chaves estrangeiras geram índices padrão automaticamente. Use `indexes` para índices compostos ou vetoriais.


### Escolhendo um Método de Integração

- **Móvel/Desktop**: Melhor passar `appSchemas` diretamente para `ToStore.open(...)`.
- **Servidor**: Melhor criar esquemas dinamicamente via `createTables(appSchemas)`.


<a id="mobile-integration"></a>
## Integração Móvel/Desktop

📱 **Exemplo**: [mobile_quickstart.dart](../../example/lib/mobile_quickstart.dart)

```dart
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

// Android/iOS: Resolva o diretório de escrita primeiro e passe como dbPath
final docDir = await getApplicationDocumentsDirectory();
final dbRoot = p.join(docDir.path, 'common');

// Reutilizar appSchemas definidos acima
final db = await ToStore.open(
  dbPath: dbRoot,
  schemas: appSchemas,
);

// Arquitetura multi-espaço - Isolar dados de diferentes usuários
await db.switchSpace(spaceName: 'user_123');
```

### Manter Login e Logout (Espaço Ativo)

O multi-espaço é ideal para **isolar dados de utilizador**: um espaço por utilizador, trocado ao fazer login. Usando **Espaço Ativo** e **opções de Fecho**, pode manter o utilizador atual após reiniciar a app e permitir logouts limpos.

- **Persistir Login**: Quando um utilizador muda para o seu espaço, marque-o como ativo. O próximo arranque entrará diretamente nesse espaço via abertura padrão, evitando o passo "abrir padrão e depois mudar".
- **Logout**: Quando um utilizador faz logout, feche a base de dados com `keepActiveSpace: false`. O próximo arranque não entrará automaticamente no espaço do utilizador anterior.

```dart
// Após Login: Mudar para o espaço do utilizador e marcar como ativo (manter login)
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// Opcional: Usar estritamente o espaço padrão (ex: apenas tela de login)
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// No Logout: Fechar e limpar o espaço ativo para usar o espaço padrão no próximo arranque
await db.close(keepActiveSpace: false);
```


<a id="server-integration"></a>
## Integração em Servidor

🖥️ **Exemplo**: [server_quickstart.dart](../../example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// Criar ou validar estrutura de tabelas no arranque do serviço
await db.createTables(appSchemas);

// Atualizações de Esquema Online
final taskId = await db.updateSchema('users')
  .renameTable('users_new')                // Renomear tabela
  .modifyField(
    'username',
    minLength: 5,
    maxLength: 20,
    unique: true
  )                                        // Modificar atributos de campo
  .renameField('old_name', 'new_name')     // Renomear campo
  .removeField('deprecated_field')         // Remover campo
  .addField('created_at', type: DataType.datetime)  // Adicionar campo
  .removeIndex(fields: ['age'])            // Remover índice
  .setPrimaryKeyConfig(                    // Mudar tipo de PK; dados devem estar vazios
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
    
// Monitorizar progresso da migração
final status = await db.queryMigrationTaskStatus(taskId);
print('Progresso da Migração: ${status?.progressPercentage}%');


// Gestão Manual de Cache de Consultas (Servidor)
Consultas de igualdade ou IN em PKs ou campos indexados são extremamente rápidas; gestão manual raramente é necessária.

// Cache manual de resultado por 5 minutos. Sem expiração se duração não for fornecida.
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// Invalidar cache específica quando os dados mudam.
await db.query('users')
    .where('is_active', '=', true)
    .clearQueryCache();

// Desativar explicitamente a cache para dados em tempo real.
final freshUserData = await db.query('users')
    .where('is_active', '=', true)
    .noQueryCache();
```


<a id="advanced-usage"></a>
## Uso Avançado

O ToStore oferece um conjunto rico de funcionalidades avançadas:


<a id="vector-advanced"></a>
### Vetores e Busca ANN

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
        type: DataType.vector,  // Declarar tipo vetorial
        nullable: false,
        vectorConfig: VectorFieldConfig(
          dimensions: 128, // Dimensões; deve coincidir na escrita e consulta
          precision: VectorPrecision.float32, // Precisão; float32 equilibra acuidade e espaço
        ),
      ),
    ],
    indexes: [
      IndexSchema(
        fields: ['embedding'], // Campo a indexar
        type: IndexType.vector,  // Construir índice vetorial
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh,  // Algoritmo; NGH integrado
          distanceMetric: VectorDistanceMetric.cosine, // Métrica; ideal para embeddings normalizados
          maxDegree: 32, // Máx vizinhos; maior aumenta recall mas usa mais memória
          efSearch: 64, // Factor expansão busca; maior é mais preciso mas lento
          constructionEf: 128, // Qualidade índice; maior é melhor mas lento a construir
        ),
      ),
    ],
  ),
]);

final queryVector =
    VectorData.fromList(List.generate(128, (i) => i * 0.01)); // Deve coincidir dimensões

// Busca Vetorial
final results = await db.vectorSearch(
  'embeddings', 
  fieldName: 'embedding', 
  queryVector: queryVector, 
  topK: 5, // Devolver top 5
  efSearch: 64, // Sobrescrever factor padrão
);

for (final r in results) {
  print('pk=${r.primaryKey}, score=${r.score}, distance=${r.distance}');
}
```

**Parâmetros**:
- `dimensions`: Deve coincidir com os embeddings de entrada.
- `precision`: `float64`, `float32`, `int8`; maior precisão aumenta custo.
- `distanceMetric`: `cosine` para semântica, `l2` para Euclidiana, `innerProduct` para produto escalar.
- `maxDegree`: Vizinhos máx no grafo NGH.
- `efSearch`: Expansão na busca; valores altos melhoram recall mas aumentam latência.
- `topK`: Número de resultados.

**Resultados**:
- `score`: Pontuação normalizada (0 a 1); maior é mais similar.
- `distance`: Maior distância significa menor similaridade em `l2` e `cosine`.


<a id="ttl-config"></a>
### TTL por Tabela (Expiração Automática)

Para logs ou eventos, defina `ttlConfig` no esquema. Dados expirados são limpos em segundo plano:

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
    ttlMs: 7 * 24 * 60 * 60 * 1000, // Manter por 7 dias
    // sourceField: omitido usa índice auto-criado.
    // Requisitos campo personalizado:
    // 1) DataType.datetime
    // 2) non-nullable (nullable: false)
    // 3) DefaultValueType.currentTimestamp
    // sourceField: 'created_at',
  ),
);
```


### Consultas Aninhadas e Filtros
Suporta aninhamento infinito e funções personalizadas.

```dart
// Aninhamento: (type = 'app' OR (id >= 123 OR fans >= 200))
final idCondition = QueryCondition().where('id', '>=', 123).or().where('fans', '>=', 200);

final result = await db.query('users')
    .condition(
        QueryCondition().whereEqual('type', 'app').or().condition(idCondition)
    )
    .limit(20);

// Função personalizada
final customResult = await db.query('users')
    .whereCustom((record) => record['tags']?.contains('recomendado') ?? false);
```

### Escrita Inteligente (Upsert)
Atualiza se PK ou chave única existe, senão insere. Sem cláusula `where`; conflito determinado pelos dados.

```dart
// Por chave primária
final result = await db.upsert('users', {
  'id': 1,
  'username': 'john',
  'email': 'john@example.com',
});

// Por chave única (deve conter campos do índice único e requeridos)
await db.upsert('users', {
  'username': 'john',
  'email': 'john@example.com',
  'age': 26,
});

// Batch upsert
final batchResult = await db.batchUpsert('users', [
  {'username': 'a', 'email': 'a@example.com'},
  {'username': 'b', 'email': 'b@example.com'},
], allowPartialErrors: true);
```


### JOINs e Seleção de Campos
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000)
    .limit(20);
```

### Streaming e Agregação
```dart
// Contar registros
final count = await db.query('users').count();

// Verificar existência de tabela (independente de espaço)
final usersTableDefined = await db.tableExists('users');

// Existência eficiente sem carregar registro
final emailExists = await db.query('users')
    .where('email', '=', 'test@example.com')
    .exists();

// Funções de agregação
final totalAge = await db.query('users').where('age', '>', 18).sum('age');
final avgAge = await db.query('users').avg('age');
final maxAge = await db.query('users').max('age');
final minAge = await db.query('users').min('age');

// Agrupamento e Filtro
final result = await db.query('orders')
    .select(['status', Agg.sum('amount', alias: 'total')])
    .groupBy(['status'])
    .having(Agg.sum('amount'), '>', 1000)
    .limit(20);

// Consulta Distinct
final uniqueCities = await db.query('users').distinct(['city']);

// Streaming (ideal para dados massivos)
db.streamQuery('users').listen((data) => print(data));
```


<a id="query-pagination"></a>
### Consulta e Paginação Eficiente

> [!TIP]
> **Especifique `limit` para melhor performance**: Fortemente recomendado. Se omitido, o padrão é 1000 registros. Serializar lotes grandes na app pode causar latência.

O ToStore oferece paginação de modo duplo:

#### 1. Modo Offset
Ideal para conjuntos pequenos (<10k registros) ou saltos específicos.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // Pular primeiros 40
    .limit(20); // Pegar 20
```
> [!TIP]
> Performance cai linearmente conforme `offset` aumenta. Use o **Modo Cursor** para paginação profunda.

#### 2. Modo Cursor
**Recomendado para dados massivos e scroll infinito**. Usa `nextCursor` para retomar da posição atual, evitando o custo de offsets grandes.

> [!IMPORTANT]
> Em consultas complexas ou campos não indexados, o motor pode fazer escaneamento total e retornar cursor `null`.

```dart
// Página 1
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// Próxima página via cursor
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // Busca direta da posição
}

// Retroceder com prevCursor
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| Funcionalidade | Modo Offset | Modo Cursor |
| :--- | :--- | :--- |
| **Performance** | Cai conforme página aumenta | **Sempre Constante (O(1))** |
| **Uso** | Dados pequenos, saltos | **Dados massivos, scroll infinito** |
| **Consistência** | Mudanças podem causar saltos | **Evita duplicidade/omissões** |


<a id="foreign-keys"></a>
### Chaves Estrangeiras e Cascata

Garanta integridade referencial e configure atualizações/remoções em cascata. Restrições são verificadas na escrita; políticas de cascata tratam dados relacionados automaticamente.

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
          fields: ['user_id'],              // Campo tabela atual
          referencedTable: 'users',         // Tabela referenciada
          referencedFields: ['id'],         // Campo referenciado
          onDelete: ForeignKeyCascadeAction.cascade,  // Apagar em cascada
          onUpdate: ForeignKeyCascadeAction.cascade,  // Atualizar em cascada
        ),
    ],
  ),
]);
```


<a id="query-operators"></a>
### Operadores de Consulta

Todas as condições `where(campo, operador, valor)` suportam estes operadores (insensível a maiúsculas):

| Operador | Descrição | Exemplo / Tipo |
| :--- | :--- | :--- |
| `=` | Igual | `where('status', '=', 'active')` |
| `!=`, `<>` | Diferente | `where('role', '!=', 'guest')` |
| `>` | Maior que | `where('age', '>', 18)` |
| `>=` | Maior ou igual | `where('score', '>=', 60)` |
| `<` | Menor que | `where('price', '<', 100)` |
| `<=` | Menor ou igual | `where('quantity', '<=', 10)` |
| `IN` | Na lista | `where('id', 'IN', ['a','b','c'])` — valor: `List` |
| `NOT IN` | Fora da lista | `where('status', 'NOT IN', ['banned'])` — valor: `List` |
| `BETWEEN` | Entre (inclusive) | `where('age', 'BETWEEN', [18, 65])` — valor: `[início, fim]` |
| `LIKE` | Padrão (`%` qualquer, `_` um) | `where('name', 'LIKE', '%John%')` — valor: `String` |
| `NOT LIKE` | Fora do padrão | `where('email', 'NOT LIKE', '%@test.com')` — valor: `String` |
| `IS` | É nulo | `where('deleted_at', 'IS', null)` — valor: `null` |
| `IS NOT` | Não é nulo | `where('email', 'IS NOT', null)` — valor: `null` |

### Métodos Semânticos (Recomendado)

Evitam strings manuais e oferecem melhor suporte do IDE:

```dart
// Comparação
db.query('users').whereEqual('username', 'John');
db.query('users').whereNotEqual('role', 'guest');
db.query('users').whereGreaterThan('age', 18);
db.query('users').whereGreaterThanOrEqualTo('score', 60);
db.query('users').whereLessThan('price', 100);
db.query('users').whereLessThanOrEqualTo('quantity', 10);

// Conjuntos e Intervalos
db.query('users').whereIn('id', ['id1', 'id2']);
db.query('users').whereNotIn('status', ['banned', 'pending']);
db.query('users').whereBetween('age', 18, 65);

// Nulos
db.query('users').whereNull('deleted_at');
db.query('users').whereNotNull('email');

// Padrões
db.query('users').whereLike('name', '%John%');
db.query('users').whereNotLike('email', '%@temp.');
db.query('users').whereContains('bio', 'flutter');   // LIKE '%flutter%'
db.query('users').whereNotContains('title', 'draft');

// Equivalente a: .where('age', '>', 18).where('name', 'like', '%John%')
final users = await db.query('users')
    .whereGreaterThan('age', 18)
    .whereLike('username', '%John%')
    .orderByDesc('age')
    .limit(20);
```


<a id="distributed-architecture"></a>
## Arquitetura Distribuída

```dart
// Configurar Nós Distribuídos
final db = await ToStore.open(
  config: DataStoreConfig(
    distributedNodeConfig: const DistributedNodeConfig(
      enableDistributed: true,
      clusterId: 1,
      centralServerUrl: 'https://127.0.0.1:8080',
      accessToken: 'b7628a4f9b4d269b98649129'
    )
  )
);

// Inserção em Bloco de Alta Performance
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... inserção massiva eficiente
]);

// Stream de Dados Massivos
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // Processar sequencialmente para evitar picos de memória
  print(record);
}
```


<a id="primary-key-examples"></a>
## Chaves Primárias

O ToStore oferece vários algoritmos de PK:

- **Sequencial** (PrimaryKeyType.sequential): 238978991
- **Baseado em Marca de Tempo** (PrimaryKeyType.timestampBased): 1306866018836946
- **Prefixo de Data** (PrimaryKeyType.datePrefixed): 20250530182215887631
- **Código Curto** (PrimaryKeyType.shortCode): 9eXrF0qeXZ

```dart
// Exemplo PK Sequencial
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,
        increment: 50,
        useRandomIncrement: true, // Ocultar volume real
      ),
    ),
    fields: [/* campos */]
  ),
]);
```


<a id="atomic-expressions"></a>
## Expressões Atômicas

Atualizações atômicas ao nível de base de dados para evitar conflitos:

```dart
// Incremento: balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// Cálculo: total = preço * qtd + taxa
await db.update('orders', {
  'total': (Expr.field('price') * Expr.field('quantity')) + Expr.field('tax'),
}).where('id', '=', orderId);

// Funções: price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// Marca de tempo
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

**Condicionais (ex: Upserts)**: Use `Expr.isUpdate()` / `Expr.isInsert()` com `Expr.ifElse` ou `Expr.when`:

```dart
// Upsert: Incrementa no update, define 1 no insert
await db.upsert('counters', {
  'key': 'visits',
  'count': Expr.ifElse(
    Expr.isUpdate(),
    Expr.field('count') + Expr.value(1),
    1, // insert: literal, ignorado na avaliação
  ),
});
```


<a id="transactions"></a>
## Transações

Garantem que todas as operações tenham sucesso ou todas sejam revertidas.

**Destaques**:
- Commit atômico.
- Recuperação automática pós-crash.
- Dados salvos com segurança no commit.

```dart
// Transação Básica
final txResult = await db.transaction(() async {
  await db.insert('users', {'username': 'john', 'fans': 100});
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');
});

if (txResult.isSuccess) {
  print('Transação ok');
} else {
  print('Erro: ${txResult.error?.message}');
}
```


<a id="database-maintenance"></a>
### Gerenciamento e Manutenção do Banco de Dados

As APIs a seguir são voltadas para administração, diagnóstico e tarefas de manutenção:

- **Manutenção de tabelas**
  `createTable(schema)`: Cria uma única tabela em tempo de execução.
  `getTableSchema(tableName)`: Lê a definição de esquema atualmente ativa.
  `getTableInfo(tableName)`: Consulta estatísticas da tabela, como quantidade de registros, índices, tamanho do arquivo, data de criação e se é global.
  `clear(tableName)`: Remove todos os dados mantendo esquema, índices e restrições.
  `dropTable(tableName)`: Remove a tabela inteira, incluindo esquema e dados.
- **Gerenciamento de espaços**
  `currentSpaceName`: Obtém o nome do espaço ativo atual.
  `listSpaces()`: Lista todos os espaços da instância atual.
  `getSpaceInfo(useCache: true)`: Obtém estatísticas do espaço atual; use `useCache: false` para forçar os dados mais recentes.
  `deleteSpace(spaceName)`: Remove um espaço. Não é possível remover o espaço `default` nem o espaço atualmente ativo.
- **Metadados da instância**
  `config`: Lê o `DataStoreConfig` efetivo.
  `instancePath`: Obtém o diretório final de armazenamento da instância.
  `getVersion()` / `setVersion(version)`: Lê e grava sua versão de negócio. Esse valor não participa da lógica interna do motor.
- **Operações de manutenção**
  `flush(flushStorage: true)`: Força a gravação dos dados pendentes em disco. Quando `true`, também descarrega os buffers do armazenamento subjacente.
  `deleteDatabase()`: Remove a instância atual do banco e seus arquivos. É uma operação destrutiva.
- **Entrada unificada de diagnóstico**
  `db.status.memory()`: Consulta o uso de cache e memória.
  `db.status.space()`: Consulta o estado geral do espaço atual.
  `db.status.table(tableName)`: Consulta o diagnóstico de uma tabela específica.
  `db.status.config()`: Consulta o snapshot da configuração efetiva.
  `db.status.migration(taskId)`: Consulta o estado de uma tarefa de migração de esquema.

```dart
print('current space: ${db.currentSpaceName}');
print('instance path: ${db.instancePath}');

final spaces = await db.listSpaces();
final spaceInfo = await db.getSpaceInfo(useCache: false);
final tableInfo = await db.getTableInfo('users');

final userVersion = await db.getVersion();
await db.setVersion(userVersion + 1);
await db.flush();

final memoryInfo = await db.status.memory();
print(spaces);
print(spaceInfo.toJson());
print(tableInfo?.toJson());
print(memoryInfo.toJson());
```

Se você quer apenas limpar os dados e preservar esquema e índices, use `clear(...)`; use `dropTable(...)` para remover a tabela inteira. `deleteSpace(...)`, `dropTable(...)` e `deleteDatabase(...)` são operações destrutivas e exigem cuidado.


<a id="backup-restore"></a>
### Backup e Restauração

Indicado para importação/exportação local, migração de dados de usuário, rollback e snapshots operacionais:

- `backup(compress: true, scope: ...)`: Cria um backup e retorna o caminho do arquivo. `compress: true` gera um pacote compactado, e `scope` controla o alcance do backup.
- `restore(backupPath, deleteAfterRestore: false, cleanupBeforeRestore: true)`: Restaura a partir de um backup. `cleanupBeforeRestore: true` limpa os dados relacionados antes da restauração para evitar mistura entre dados antigos e novos, e `deleteAfterRestore: true` remove o arquivo após uma restauração bem-sucedida.
- `BackupScope.database`: Faz backup da instância inteira, incluindo todos os espaços, tabelas globais e metadados relacionados.
- `BackupScope.currentSpace`: Faz backup apenas do espaço atual, excluindo tabelas globais.
- `BackupScope.currentSpaceWithGlobal`: Faz backup do espaço atual junto com as tabelas globais. É útil para exportação/importação de um único usuário.

```dart
final backupPath = await db.backup(
  compress: true,
  scope: BackupScope.currentSpaceWithGlobal,
);

final restored = await db.restore(
  backupPath,
  cleanupBeforeRestore: true,
  deleteAfterRestore: false,
);

print(backupPath);
print(restored);
```

Sempre que possível, pause as gravações da aplicação antes de restaurar.


<a id="error-handling"></a>
### Tratamento de Erros

Modelo unificado:
- `ResultType`: Enum para lógica.
- `result.code`: Código numérico.
- `result.message`: Descrição.
- `successKeys` / `failedKeys`: Listas de chaves primárias em operações em lote.

```dart
final result = await db.insert('users', {
  'username': 'john',
  'email': 'john@example.com',
});

if (!result.isSuccess) {
  switch (result.type) {
    case ResultType.notFound:
      print('Recurso não encontrado: ${result.message}');
      break;
    case ResultType.notNullViolation:
    case ResultType.validationFailed:
      print('Validação falhou: ${result.message}');
      break;
    case ResultType.primaryKeyViolation:
    case ResultType.uniqueViolation:
      print('Conflito: ${result.message}');
      break;
    case ResultType.foreignKeyViolation:
      print('Falha de chave estrangeira: ${result.message}');
      break;
    case ResultType.resourceExhausted:
    case ResultType.timeout:
      print('Sistema ocupado, tente novamente mais tarde: ${result.message}');
      break;
    case ResultType.ioError:
    case ResultType.dbError:
      print('Erro de armazenamento, registre no log: ${result.message}');
      break;
    default:
      print('Tipo: ${result.type}, Código: ${result.code}, Mensagem: ${result.message}');
  }
}
```

**Códigos de status comuns**:
Sucesso é `0`; valores negativos indicam erros.
- `ResultType.success` (`0`): Operação bem-sucedida.
- `ResultType.partialSuccess` (`1`): Operação em lote parcialmente bem-sucedida.
- `ResultType.unknown` (`-1`): Erro desconhecido.
- `ResultType.uniqueViolation` (`-2`): Conflito de índice único.
- `ResultType.primaryKeyViolation` (`-3`): Conflito de chave primária.
- `ResultType.foreignKeyViolation` (`-4`): Violação de chave estrangeira.
- `ResultType.notNullViolation` (`-5`): Campo obrigatório ausente ou `null` não permitido.
- `ResultType.validationFailed` (`-6`): Falha em validação de tamanho, faixa, formato ou restrição.
- `ResultType.notFound` (`-11`): Tabela, espaço ou recurso alvo não encontrado.
- `ResultType.resourceExhausted` (`-15`): Recursos do sistema insuficientes; reduza a carga ou tente novamente.
- `ResultType.ioError` (`-90`): Erro de I/O do sistema de arquivos ou do armazenamento.
- `ResultType.dbError` (`-91`): Erro interno do banco de dados.
- `ResultType.timeout` (`-92`): Tempo limite excedido.

### Tratamento do Resultado da Transação

```dart
final txResult = await db.transaction(() async {
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
  });
});

if (txResult.isFailed) {
  print('Tipo de erro da transação: ${txResult.error?.type}');
  print('Mensagem de erro da transação: ${txResult.error?.message}');
}
```

Tipos de erro de transação:
- `TransactionErrorType.operationError`: Falha de operação normal dentro da transação, como validação de campo, estado inválido de recurso ou outra exceção de negócio.
- `TransactionErrorType.integrityViolation`: Conflito de integridade ou restrição, como chave primária, chave única, chave estrangeira ou não-nulo.
- `TransactionErrorType.timeout`: A transação excedeu o tempo limite.
- `TransactionErrorType.io`: Erro de I/O no armazenamento subjacente ou sistema de arquivos.
- `TransactionErrorType.conflict`: A transação falhou devido a um conflito.
- `TransactionErrorType.userAbort`: Abortado pelo usuário. O aborto manual lançando exceção ainda não é suportado.
- `TransactionErrorType.unknown`: Qualquer outro erro inesperado.


<a id="logging-diagnostics"></a>
### Callback de logs e diagnóstico de banco de dados

O ToStore pode usar `LogConfig.setConfig(...)` para devolver à camada de aplicação logs de inicialização, recuperação, migração automática e conflitos de restrições em tempo de execução.

- `onLogHandler` recebe todos os logs filtrados pelo `enableLog` e `logLevel` atuais.
- Chame `LogConfig.setConfig(...)` antes da inicialização para que os logs de inicialização e migração automática também possam ser capturados.

```dart
  // Configurar parâmetros de log ou callback
  LogConfig.setConfig(
    enableLog: true,
    logLevel: debugMode ? LogLevel.debug : LogLevel.warn,
    publicLabel: 'my_app_db',
    onLogHandler: (message, type, label) {
      // Em produção, warn/error podem ser enviados ao backend ou à plataforma de logs
      if (!debugMode && (type == LogType.warn || type == LogType.error)) {
        developer.log(message, name: label);
      }
    },
  );

  final db = await ToStore.open();
```


### Modo Memória Pura

Para cache ou ambientes sem disco, use `ToStore.memory()`. Dados (esquemas, índices, KV) estritamente em RAM.

**Nota**: Dados perdidos ao fechar ou reiniciar a app.

```dart
final db = await ToStore.memory(schemas: []);
await db.insert('temp_cache', {'key': 'session', 'value': 'admin'});
```


<a id="security-config"></a>
## Segurança

> [!WARNING]
> **Gestão de Chaves**: **`encodingKey`** pode ser trocada (migração automática). **`encryptionKey`** é crítica; trocá-la sem migração torna dados antigos ilegíveis.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      encryptionType: EncryptionType.chacha20Poly1305, 
      encodingKey: 'Sua-Chave-De-Codificacao-De-32-Bytes...', 
      encryptionKey: 'Sua-Chave-De-Criptografia-Segura...',
      deviceBinding: false, 
    ),
    enableJournal: true, // WAL
    persistRecoveryOnCommit: true,
  ),
);
```

### Criptografia de Campo (ToCrypto)

Para criptografar apenas campos sensíveis, use **ToCrypto**: utilitário independente para Base64, ideal para JSON ou TEXT.

```dart
const key = 'minha-chave';
final cipher = ToCrypto.encode('dados sensíveis', key: key);
final plain = ToCrypto.decode(cipher, key: key);
```


<a id="performance"></a>
## Performance

- 📱 **Exemplo**: Veja o diretório `example` para uma app Flutter completa.
- 🚀 **Produção**: Performance em modo Release é muito superior ao Debug.
- ✅ **Testado**: Funções núcleo cobertas por testes exaustivos.

### Benchmarks

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="Demonstração de Desempenho do ToStore" width="320" />
</p>

- **Vitrine de Desempenho**: Mesmo com mais de 100 milhões de registros, a inicialização, a rolagem e a recuperação permanecem suaves em dispositivos móveis padrão. (Ver [Vídeo](https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4))

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="Recuperação de Desastres do ToStore" width="320" />
</p>

- **Recuperação de Desastres**: O ToStore se recupera rapidamente, mesmo se a energia for cortada ou o processo for interrompido durante gravações de alta frequência. (Ver [Vídeo](https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4))


Se o ToStore ajudar, por favor dê-nos uma ⭐️! É o maior apoio ao código aberto.

---

> **Recomendação**: Use o [ToApp Framework](https://github.com/tocreator/toapp) para front-end. Automatiza pedidos, carga, armazenamento, cache e estado.


<a id="more-resources"></a>
## Mais Recursos

- 📖 **Wiki**: [GitHub](https://github.com/tocreator/tostore)
- 📢 **Feedback**: [Issues](https://github.com/tocreator/tostore/issues)
- 💬 **Discussão**: [Discussions](https://github.com/tocreator/tostore/discussions)
