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
- **Primeiros passos**: [Por que armazenar](#why-tostore) | [Principais recursos](#key-features) | [Guia de instalação](#installation) | [Modo KV](#quick-start-kv) | [Modo Tabela](#quick-start-table) | [Modo de memória](#quick-start-memory)
- **Arquitetura e Modelo**: [Definição de Esquema](#schema-definition) | [Arquitetura Distribuída](#distributed-architecture) | [Chaves estrangeiras em cascata](#foreign-keys) | [Celular/Desktop](#mobile-integration) | [Servidor/Agente](#server-integration) | [Algoritmos de chave primária](#primary-key-examples)
- **Consultas Avançadas**: [Consultas Avançadas (JOIN)](#query-advanced) | [Agregação e estatísticas](#aggregation-stats) | [Lógica Complexa (Condição de Consulta)](#query-condition) | [Consulta reativa (assistir)](#reactive-query) | [Consulta de streaming](#streaming-query)
- **Avançado e Desempenho**: [Pesquisa vetorial](#vector-advanced) | [TTL em nível de tabela](#ttl-config) | [Paginação Eficiente](#query-pagination) | [Cache de consulta](#query-cache) | [Expressões Atômicas](#atomic-expressions) | [Transações](#transactions)
- **Operações e Segurança**: [Administração](#database-maintenance) | [Configuração de segurança](#security-config) | [Tratamento de erros](#error-handling) | [Desempenho e diagnóstico](#performance) | [Mais recursos](#more-resources)

## <a id="why-tostore"></a>Por que escolher a ToStore?

ToStore é um mecanismo de dados moderno projetado para a era AGI e cenários de inteligência de ponta. Ele oferece suporte nativo a sistemas distribuídos, fusão multimodal, dados estruturados relacionais, vetores de alta dimensão e armazenamento de dados não estruturados. Construído em uma arquitetura de nós com roteamento automático e um mecanismo inspirado em redes neurais, ele oferece aos nós alta autonomia e escalabilidade horizontal elástica, ao mesmo tempo em que desvincula logicamente o desempenho da escala de dados. Inclui transações ACID, consultas relacionais complexas (JOINs e chaves estrangeiras em cascata), TTL em nível de tabela e agregações, juntamente com vários algoritmos de chave primária distribuídos, expressões atômicas, reconhecimento de alterações de esquema, criptografia, isolamento de dados em vários espaços, agendamento de carga inteligente com reconhecimento de recursos e recuperação de autocorreção de desastres/travamentos.

À medida que a computação continua migrando para a inteligência de ponta, agentes, sensores e outros dispositivos não são mais apenas “exibições de conteúdo”. São nós inteligentes responsáveis ​​pela geração local, consciência ambiental, tomada de decisões em tempo real e fluxos de dados coordenados. As soluções de banco de dados tradicionais são limitadas por sua arquitetura subjacente e extensões integradas, tornando cada vez mais difícil satisfazer os requisitos de baixa latência e estabilidade de aplicativos inteligentes de nuvem de ponta sob gravações de alta simultaneidade, conjuntos de dados massivos, recuperação de vetores e geração colaborativa.

O ToStore oferece recursos distribuídos de borda fortes o suficiente para conjuntos de dados massivos, geração local complexa de IA e movimentação de dados em grande escala. A colaboração inteligente profunda entre nós de borda e de nuvem fornece uma base de dados confiável para realidade mista imersiva, interação multimodal, vetores semânticos, modelagem espacial e cenários semelhantes.

## <a id="key-features"></a>Principais recursos

- 🌐 **Mecanismo de dados unificado entre plataformas**
  - API unificada em ambientes móveis, desktop, web e servidores
  - Suporta dados estruturados relacionais, vetores de alta dimensão e armazenamento de dados não estruturados
  - Cria um pipeline de dados desde o armazenamento local até a colaboração na nuvem

- 🧠 **Arquitetura distribuída em estilo de rede neural**
  - Arquitetura de nó de auto-roteamento que separa o endereçamento físico da escala
  - Nós altamente autônomos colaboram para construir uma topologia de dados flexível
  - Suporta cooperação de nós e dimensionamento horizontal elástico
  - Interconexão profunda entre nós inteligentes de ponta e a nuvem

- ⚡ **Execução paralela e agendamento de recursos**
  - Programação de carga inteligente com reconhecimento de recursos e alta disponibilidade
  - Colaboração paralela de vários nós e decomposição de tarefas
  - O corte de tempo mantém as animações da interface do usuário suaves, mesmo sob carga pesada

- 🔍 **Consultas estruturadas e recuperação de vetores**
  - Suporta predicados complexos, JOINs, agregações e TTL em nível de tabela
  - Suporta campos vetoriais, índices vetoriais e recuperação do vizinho mais próximo
  - Dados estruturados e vetoriais podem trabalhar juntos dentro do mesmo mecanismo

- 🔑 **Chaves primárias, índices e evolução do esquema**
  - Algoritmos de chave primária integrados, incluindo estratégias sequenciais, de carimbo de data/hora, com prefixo de data e de código curto
  - Suporta índices exclusivos, índices compostos, índices vetoriais e restrições de chave estrangeira
  - Detecta automaticamente alterações de esquema e conclui o trabalho de migração

- 🛡️ **Transações, Segurança e Recuperação**
  - Fornece transações ACID, atualizações de expressões atômicas e chaves estrangeiras em cascata
  - Suporta recuperação de falhas, commits duráveis e garantias de consistência
  - Suporta criptografia ChaCha20-Poly1305 e AES-256-GCM

- 🔄 **Fluxos de trabalho multiespaços e de dados**
  - Suporta espaços isolados com dados opcionais compartilhados globalmente
  - Suporta ouvintes de consulta em tempo real, cache inteligente multinível e paginação de cursor
  - Adapta-se a aplicativos colaborativos multiusuários, locais e off-line

## <a id="installation"></a>Instalação

> [!IMPORTANT]
> **Atualizando da v2.x?** Leia o [Guia de atualização da v3.x](../UPGRADE_GUIDE_v3.md) para etapas críticas de migração e alterações significativas.

Adicione `tostore` ao seu `pubspec.yaml`:

```yaml
dependencies:
  tostore: any # Please use the latest version
```

## <a id="quick-start"></a>Início rápido

> [!TIP]
> **Como você deve escolher um modo de armazenamento?**
> 1. [**Modo de valor-chave (KV)**](#quick-start-kv): Melhor para acesso de configuração, gerenciamento de estado disperso ou armazenamento de dados JSON. É a maneira mais rápida de começar.
> 2. [**Modo de tabela estruturada**](#quick-start-table): Melhor para dados comerciais essenciais que precisam de consultas complexas, validação de restrições ou governança de dados em grande escala. Ao inserir a lógica de integridade no mecanismo, você pode reduzir significativamente os custos de desenvolvimento e manutenção da camada de aplicação.
> 3. [**Modo de memória**](#quick-start-memory): Melhor para computação temporária, testes de unidade ou **gerenciamento de estado global ultrarrápido**. Com consultas globais e ouvintes `watch`, você pode remodelar a interação do aplicativo sem manter uma pilha de variáveis ​​globais.

### <a id="quick-start-kv"></a>Armazenamento de valor-chave (KV)
Este modo é adequado quando você não precisa de tabelas estruturadas predefinidas. É simples, prático e apoiado por um mecanismo de armazenamento de alto desempenho. **Sua arquitetura de indexação eficiente mantém o desempenho da consulta altamente estável e extremamente responsivo, mesmo em dispositivos móveis comuns em escalas de dados muito grandes.** Os dados em diferentes espaços são naturalmente isolados, enquanto o compartilhamento global também é suportado.

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

#### Exemplo de atualização automática da interface do Flutter
No Flutter, `StreamBuilder` mais `watchValue` oferece um fluxo de atualização reativa muito conciso:

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

### <a id="quick-start-table"></a>Modo Tabela Estruturada
O CRUD em tabelas estruturadas exige que o esquema seja criado antecipadamente (consulte [Definição do esquema](#schema-definition)). Abordagens de integração recomendadas para diferentes cenários:
- **Móvel/Desktop**: Para [cenários de inicialização frequentes](#mobile-integration), é recomendado passar `schemas` durante a inicialização.
- **Servidor/Agente**: Para [cenários de longa duração](#server-integration), é recomendado criar tabelas dinamicamente por meio de `createTables`.

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

### <a id="quick-start-memory"></a>Modo de memória

Para cenários como armazenamento em cache, computação temporária ou cargas de trabalho que não precisam de persistência em disco, você pode inicializar um banco de dados puro na memória por meio de `ToStore.memory()`. Nesse modo, todos os dados, incluindo esquemas, índices e pares de valores-chave, residem inteiramente na memória para desempenho máximo de leitura/gravação.

#### 💡 Também funciona como gerenciamento de estado global
Você não precisa de uma pilha de variáveis globais ou de uma estrutura pesada de gerenciamento de estado. Ao combinar o modo de memória com `watchValue` ou `watch()`, você pode obter atualização de interface do usuário totalmente automática em widgets e páginas. Ele mantém as poderosas habilidades de recuperação de um banco de dados e, ao mesmo tempo, oferece uma experiência reativa muito além das variáveis ​​comuns, tornando-o ideal para estado de login, configuração em tempo real ou contadores de mensagens globais.

> [!CAUTION]
> **Nota**: Os dados criados no modo de memória pura são completamente perdidos depois que o aplicativo é fechado ou reiniciado. Não o use para dados comerciais essenciais.

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


## <a id="schema-definition"></a>Definição de esquema
**Defina uma vez e deixe o mecanismo lidar com a governança automatizada de ponta a ponta para que seu aplicativo não precise mais de manutenção pesada de validação.**

Os seguintes exemplos móveis, do lado do servidor e de agente reutilizam `appSchemas` definidos aqui.


### Visão geral do esquema de tabela

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

- **Mapeamentos `DataType` comuns**:
  | Tipo | Tipo de dardo correspondente | Descrição |
  | :--- | :--- | :--- |
| `integer` | `int` | Inteiro padrão, adequado para IDs, contadores e dados semelhantes |
  | `bigInt` | `BigInt` / `String` | Inteiros grandes; recomendado quando os números excedem 18 dígitos para evitar perda de precisão |
  | `double` | `double` | Número de ponto flutuante, adequado para preços, coordenadas e dados semelhantes |
  | `text` | `String` | String de texto com restrições de comprimento opcionais |
  | `blob` | `Uint8List` | Dados binários brutos |
  | `boolean` | `bool` | Valor booleano |
  | `datetime` | `DateTime` / `String` | Data/hora; armazenado internamente como ISO8601 |
  | `array` | `List` | Tipo de lista ou array |
  | `json` | `Map<String, dynamic>` | Objeto JSON, adequado para dados estruturados dinâmicos |
  | `vector` | `VectorData` / `List<num>` | Dados vetoriais de alta dimensão para recuperação semântica de IA (incorporação) |

- **`PrimaryKeyType` estratégias de geração automática**:
  | Estratégia | Descrição | Características |
  | :--- | :--- | :--- |
| `none` | Sem geração automática | Você deve fornecer manualmente a chave primária durante a inserção |
  | `sequential` | Incremento sequencial | Bom para IDs amigáveis, mas menos adequado para desempenho distribuído |
  | `timestampBased` | Baseado em carimbo de data/hora | Recomendado para ambientes distribuídos |
  | `datePrefixed` | Prefixado por data | Útil quando a legibilidade da data é importante para o negócio |
  | `shortCode` | Chave primária de código curto | Compacto e adequado para exibição externa |

> Todas as chaves primárias são armazenadas como `text` (`String`) por padrão.


### Restrições e validação automática

Você pode escrever regras de validação comuns diretamente em `FieldSchema`, evitando lógica duplicada no código da aplicação:

- `nullable: false`: restrição não nula
- `minLength` / `maxLength`: restrições de comprimento de texto
- `minValue` / `maxValue`: restrições de intervalo inteiro ou de ponto flutuante
- `defaultValue` / `defaultValueType`: valores padrão estáticos e valores padrão dinâmicos
- `unique`: restrição única
- `createIndex`: crie índices para filtragem, classificação ou relacionamentos de alta frequência
- `fieldId` / `tableId`: auxilia na detecção de renomeação de campos e tabelas durante a migração

Além disso, `unique: true` cria automaticamente um índice exclusivo de campo único. `createIndex: true` e chaves estrangeiras criam automaticamente índices normais de campo único. Use `indexes` quando precisar de índices compostos, índices nomeados ou índices vetoriais.


### Escolhendo um método de integração

- **Celular/Desktop**: Melhor ao passar `appSchemas` diretamente para `ToStore.open(...)`
- **Servidor/Agente**: Melhor ao criar esquemas dinamicamente em tempo de execução via `createTables(appSchemas)`


## <a id="mobile-integration"></a>Integração para dispositivos móveis, desktop e outros cenários de inicialização frequentes

📱 **Exemplo**: [mobile_quickstart.dart](../../example/lib/mobile_quickstart.dart)

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

### Evolução do esquema

Durante `ToStore.open()`, o mecanismo detecta automaticamente alterações estruturais em `schemas`, como adicionar, remover, renomear ou alterar tabelas e campos, bem como alterações de índice, e então conclui o trabalho de migração necessário. Você não precisa manter manualmente os números de versão do banco de dados ou escrever scripts de migração.


### Mantendo o estado de login e logout (espaço ativo)

Multiespaço é ideal para **isolar dados do usuário**: um espaço por usuário, ativado no login. Com o **Active Space** e opções de fechamento, você pode manter o usuário atual durante as reinicializações do aplicativo e oferecer suporte a um comportamento de logout limpo.

- **Manter estado de login**: depois de mudar um usuário para seu próprio espaço, marque esse espaço como ativo. A próxima inicialização pode entrar nesse espaço diretamente ao abrir a instância padrão, sem uma etapa "padrão primeiro, depois alterne".
- **Logout**: Quando o usuário efetuar logout, feche o banco de dados com `keepActiveSpace: false`. O próximo lançamento não entrará automaticamente no espaço do usuário anterior.

```dart
// After login: switch to the user's space and mark it active
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// Optional: strictly stay in default when needed (for example, login screen only)
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// On logout: close and clear the active space so the next launch starts from default
await db.close(keepActiveSpace: false);
```


## <a id="server-integration"></a>Integração do lado do servidor/agente (cenários de longa duração)

🖥️ **Exemplo**: [server_quickstart.dart](../../example/lib/server_quickstart.dart)

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


## <a id="advanced-usage"></a>Uso Avançado

ToStore fornece um rico conjunto de recursos avançados para cenários de negócios complexos:


### <a id="vector-advanced"></a>Campos vetoriais, índices vetoriais e pesquisa vetorial

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

Notas de parâmetro:

- `dimensions`: deve corresponder à largura real de incorporação que você escreve
- `precision`: escolhas comuns incluem `float64`, `float32` e `int8`; maior precisão geralmente custa mais armazenamento
- `distanceMetric`: `cosine` é comum para embeddings semânticos, `l2` é adequado para distância euclidiana e `innerProduct` é adequado para pesquisa de produtos pontuais
- `maxDegree`: limite superior de vizinhos retidos por nó no grafo NGH; valores mais altos geralmente melhoram a recuperação ao custo de mais memória e tempo de construção
- `efSearch`: largura de expansão do tempo de busca; aumentá-lo geralmente melhora a recuperação, mas aumenta a latência
- `constructionEf`: largura de expansão em tempo de construção; aumentá-lo geralmente melhora a qualidade do índice, mas aumenta o tempo de construção
- `topK`: número de resultados a retornar

Notas de resultado:

- `score`: pontuação de similaridade normalizada, normalmente na faixa `0 ~ 1`; maior significa mais semelhante
- `distance`: valor da distância; para `l2` e `cosine`, menor geralmente significa mais semelhante

### <a id="ttl-config"></a>TTL em nível de tabela (expiração automática baseada em tempo)

Para logs, telemetria, eventos e outros dados que devem expirar com o tempo, você pode definir o TTL em nível de tabela por meio de `ttlConfig`. O mecanismo limpará automaticamente os registros expirados em segundo plano:

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


### Armazenamento Inteligente (Upsert)
ToStore decide se deseja atualizar ou inserir com base na chave primária ou chave exclusiva incluída em `data`. `where` não é suportado aqui; o alvo do conflito é determinado pelos próprios dados.

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


### <a id="query-advanced"></a>Consultas Avançadas

ToStore fornece uma API de consulta declarativa encadeada com manipulação flexível de campos e relacionamentos complexos com várias tabelas.

#### 1. Seleção de campo (`select`)
O método `select` especifica quais campos são retornados. Se você não chamar, todos os campos serão retornados por padrão.
- **Aliases**: suporta sintaxe `field as alias` (sem distinção entre maiúsculas e minúsculas) para renomear chaves no conjunto de resultados
- **Campos qualificados de tabela**: em junções de múltiplas tabelas, `table.field` evita conflitos de nomenclatura
- **Mistura de agregação**: objetos `Agg` podem ser colocados diretamente dentro da lista `select`

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

#### 2. Associações (`join`)
Suporta `join` padrão (junção interna), `leftJoin` e `rightJoin`.

#### 3. Junções inteligentes baseadas em chave estrangeira (recomendado)
Se `foreignKeys` estiver definido corretamente em `TableSchema`, você não precisará escrever à mão as condições de junção. O mecanismo pode resolver relacionamentos de referência e gerar automaticamente o caminho JOIN ideal.

- **`joinReferencedTable(tableName)`**: junta-se automaticamente à tabela pai referenciada pela tabela atual
- **`joinReferencingTable(tableName)`**: une automaticamente tabelas filhas que fazem referência à tabela atual

```dart
// Assume posts defines a foreign key to users
final posts = await db.query('posts')
    .joinReferencedTable('users') // Automatically resolves to ON posts.user_id = users.id
    .select(['posts.title', 'users.username'])
    .limit(20);
```

---

### <a id="aggregation-stats"></a>Agregação, agrupamento e estatísticas (Agg e GroupBy)

#### 1. Agregação (`Agg` fábrica)
Funções agregadas calculam estatísticas em um conjunto de dados. Com o parâmetro `alias`, você pode personalizar os nomes dos campos de resultados.

| Método | Finalidade | Exemplo |
| :--- | :--- | :--- |
| `Agg.count(field)` | Contar registros não nulos | `Agg.count('id', alias: 'total')` |
| `Agg.sum(field)` | Valores de soma | `Agg.sum('amount', alias: 'total_price')` |
| `Agg.avg(field)` | Valor médio | `Agg.avg('score', alias: 'average_score')` |
| `Agg.max(field)` | Valor máximo | `Agg.max('age')` |
| `Agg.min(field)` | Valor mínimo | `Agg.min('price')` |

> [!TIP]
> **Dois estilos de agregação comuns**
> 1. **Métodos de atalho (recomendados para métricas únicas)**: chame diretamente na cadeia e recupere o valor calculado imediatamente.
> `num? totalAge = await db.query('users').sum('age');`
> 2. **Incorporado em `select` (para múltiplas métricas ou agrupamento)**: passe objetos `Agg` para a lista `select`.
> `final stats = await db.query('orders').select(['status', Agg.sum('amount')]).groupBy(['status']);`

#### 2. Agrupamento e filtragem (`groupBy` / `having`)
Use `groupBy` para categorizar registros e `having` para filtrar resultados agregados, semelhante ao comportamento HAVING do SQL.

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

#### 3. Métodos de consulta auxiliares
- **`exists()` (alto desempenho)**: verifica se algum registro corresponde. Ao contrário do `count() > 0`, ele entra em curto-circuito assim que uma correspondência é encontrada, o que é excelente para conjuntos de dados muito grandes.
- **`count()`**: retorna com eficiência o número de registros correspondentes.
- **`first()`**: um método de conveniência equivalente a `limit(1)` e retornando a primeira linha diretamente como `Map`.
- **`distinct([fields])`**: desduplica resultados. Se `fields` forem fornecidos, a exclusividade será calculada com base nesses campos.

```dart
// Efficient existence check
if (await db.query('users').whereEqual('email', 'test@test.com').exists()) {
  print('Email is already registered');
}

// Get a deduplicated city list
final cities = await db.query('users').distinct(['city']);
```

#### <a id="query-condition"></a>4. Lógica Complexa com `QueryCondition`
`QueryCondition` é a principal ferramenta do ToStore para lógica aninhada e construção de consultas entre parênteses. Quando simples chamadas `where` encadeadas não são suficientes para expressões como `(A AND B) OR (C AND D)`, esta é a ferramenta a ser usada.

- **`condition(QueryCondition sub)`**: abre um grupo aninhado `AND`
- **`orCondition(QueryCondition sub)`**: abre um grupo aninhado `OR`
- **`or()`**: altera o próximo conector para `OR` (o padrão é `AND`)

##### Exemplo 1: Condições OR mistas
SQL equivalente: `WHERE is_active = true AND (role = 'admin' OR fans >= 1000)`

```dart
final subGroup = QueryCondition()
    .whereEqual('role', 'admin')
    .or()
    .whereGreaterThanOrEqualTo('fans', 1000);

final results = await db.query('users')
    .whereEqual('is_active', true)
    .condition(subGroup);
```

##### Exemplo 2: fragmentos de condição reutilizáveis
Você pode definir fragmentos de lógica de negócios reutilizáveis uma vez e combiná-los em consultas diferentes:

```dart
final hotUser = QueryCondition().whereGreaterThan('fans', 5000);
final recentLogin = QueryCondition().whereGreaterThan('last_login', '2024-01-01');

final targetUsers = await db.query('users')
    .condition(hotUser)
    .condition(recentLogin);
```


#### <a id="streaming-query"></a>5. Consulta de streaming
Adequado para conjuntos de dados muito grandes quando você não deseja carregar tudo na memória de uma só vez. Os resultados podem ser processados ​​à medida que são lidos.

```dart
db.streamQuery('users').listen((data) {
  print('Processing one record: $data');
});
```

#### <a id="reactive-query"></a>6. Consulta reativa
O método `watch()` permite monitorar os resultados da consulta em tempo real. Ele retorna um `Stream` e executa novamente a consulta automaticamente sempre que os dados correspondentes são alterados na tabela de destino.
- **Debounce automático**: o debounce inteligente integrado evita explosões redundantes de consultas
- **Sincronização de UI**: funciona naturalmente com Flutter `StreamBuilder` para listas de atualização ao vivo

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

### <a id="query-cache"></a>Cache manual de resultados de consulta (opcional)

> [!IMPORTANT]
> **O ToStore já inclui internamente um cache LRU inteligente e eficiente de vários níveis.**
> **O gerenciamento manual de cache de rotina não é recomendado.** Considere-o apenas em casos especiais:
> 1. Varreduras completas caras em dados não indexados que raramente mudam
> 2. Requisitos persistentes de latência ultrabaixa, mesmo para consultas não intensas

- `useQueryCache([Duration? expiry])`: habilite o cache e opcionalmente defina uma expiração
- `noQueryCache()`: desabilita explicitamente o cache para esta consulta
- `clearQueryCache()`: invalida manualmente o cache para este padrão de consulta

```dart
final results = await db.query('heavy_table')
    .where('non_indexed_field', '=', 'value')
    .useQueryCache(const Duration(minutes: 10)); // Manual acceleration for a heavy query only
```


### <a id="query-pagination"></a>Consulta e paginação eficiente

> [!TIP]
> **Sempre especifique `limit` para obter melhor desempenho**: é altamente recomendável fornecer `limit` explicitamente em cada consulta. Se omitido, o mecanismo será padronizado para 1.000 linhas. O mecanismo de consulta principal é rápido, mas a serialização de conjuntos de resultados muito grandes na camada de aplicativo ainda pode adicionar sobrecarga desnecessária.

ToStore fornece dois modos de paginação para que você possa escolher com base nas necessidades de escala e desempenho:

#### 1. Paginação Básica (Modo Offset)
Adequado para conjuntos de dados relativamente pequenos ou casos em que você precisa de saltos de página precisos.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // Skip the first 40 rows
    .limit(20); // Take 20 rows
```
> [!TIP]
> Quando `offset` fica muito grande, o banco de dados deve varrer e descartar muitas linhas, então o desempenho cai linearmente. Para paginação profunda, prefira **Modo Cursor**.

#### 2. Paginação do Cursor (Modo Cursor)
Ideal para conjuntos de dados massivos e rolagem infinita. Ao usar `nextCursor`, o mecanismo continua a partir da posição atual e evita o custo extra de varredura que acompanha os deslocamentos profundos.

> [!IMPORTANT]
> Para algumas consultas complexas ou classificações em campos não indexados, o mecanismo pode voltar para uma verificação completa e retornar um cursor `null`, o que significa que a paginação não é atualmente suportada para essa consulta específica.

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

| Recurso | Modo de deslocamento | Modo Cursor |
| :--- | :--- | :--- |
| **Desempenho de consulta** | Degrada à medida que as páginas se aprofundam | Estável para paginação profunda |
| **Melhor para** | Conjuntos de dados menores, saltos de página exatos | **Conjuntos de dados enormes, rolagem infinita** |
| **Consistência sob alterações** | Alterações de dados podem causar linhas ignoradas | Evita duplicatas e omissões causadas por alterações de dados |


### <a id="foreign-keys"></a>Chaves Estrangeiras e Cascata

As chaves estrangeiras garantem a integridade referencial e permitem configurar atualizações e exclusões em cascata. Os relacionamentos são validados na gravação e na atualização. Se as políticas em cascata estiverem habilitadas, os dados relacionados serão atualizados automaticamente, reduzindo o trabalho de consistência no código do aplicativo.

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


### <a id="query-operators"></a>Operadores de consulta

Todas as condições `where(field, operator, value)` suportam os seguintes operadores (sem distinção entre maiúsculas e minúsculas):

| Operador | Descrição | Exemplo / Desempenho |
| :--- | :--- | :--- |
| `=` | Igual | `where('status', '=', 'val')` — **[Recomendado]** Busca por índice (Seek) |
| `!=`, `<>` | Diferente | `where('role', '!=', 'val')` — **[Cuidado]** Varredura completa da tabela |
| `>` , `>=`, `<`, `<=` | Comparação | `where('age', '>', 18)` — **[Recomendado]** Varredura por índice |
| `IN` | Na lista | `where('id', 'IN', [...])` — **[Recomendado]** Busca por índice (Seek) |
| `NOT IN` | Não está na lista | `where('status', 'NOT IN', [...])` — **[Cuidado]** Varredura completa da tabela |
| `BETWEEN` | Intervalo | `where('age', 'BETWEEN', [18, 65])` — **[Recomendado]** Varredura por índice |
| `LIKE` | Correspondência de padrão (`%` = qualquer caractere, `_` = caractere único) | `where('name', 'LIKE', 'John%')` — **[Cuidado]** Veja a nota abaixo |
| `NOT LIKE` | Incompatibilidade de padrões | `where('email', 'NOT LIKE', '...')` — **[Cuidado]** Varredura completa da tabela |
| `IS` | É null | `where('deleted_at', 'IS', null)` — **[Recomendado]** Busca por índice (Seek) |
| `IS NOT` | Não é null | `where('email', 'IS NOT', null)` — **[Cuidado]** Varredura completa da tabela |

### Métodos de consulta semântica (recomendado)

Recomendado para evitar sequências de operadores escritas à mão e para obter melhor assistência IDE.

#### 1. Comparação
Usado para comparações diretas numéricas ou de strings.

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

#### 2. Coleção e alcance
Usado para testar se um campo está dentro de um conjunto ou intervalo.

```dart
db.query('users').whereIn('id', ['id1', 'id2']);                 // In list
db.query('users').whereNotIn('status', ['banned', 'pending']);   // Not in list
db.query('users').whereBetween('age', 18, 65);                   // In range (inclusive)
```

#### 3. Verificação de nulo
Usado para testar se um campo tem um valor.

```dart
db.query('users').whereNull('deleted_at');    // Is null
db.query('users').whereNotNull('email');      // Is not null
db.query('users').whereEmpty('nickname');     // Is null or empty string
db.query('users').whereNotEmpty('bio');       // Is not null and not empty
```

#### 4. Correspondência de padrões
Suporta pesquisa curinga no estilo SQL (`%` corresponde a qualquer número de caracteres, `_` corresponde a um único caractere).

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
> **Guia de Desempenho de Consulta (Índice vs Varredura Completa)**
>
> Em cenários de dados em larga escala (millones de linhas ou mais), siga estes princípios para evitar atrasos na thread principal e timeouts de consulta:
>
> 1. **Otimizado por índice - [Recomendado]**:
>    *   **Métodos semânticos**: `whereEqual`, `whereGreaterThan`, `whereLessThan`, `whereIn`, `whereBetween`, `whereNull`, `whereTrue`, `whereFalse` e **`whereStartsWith`** (correspondência de prefixo).
>    *   **Operadores**: `=`, `>`, `<`, `>=`, `<=`, `IN`, `BETWEEN`, `IS null`, `LIKE 'prefix%'`.
>    *   *Explicação: Essas operações alcançam um posicionamento ultrarrápido por meio de índices. Para `whereStartsWith` / `LIKE 'abc%'`, o índice ainda pode realizar uma varredura de intervalo de prefixo.*
>
> 2. **Riscos de varredura completa - [Cuidado]**:
>    *   **Correspondência difusa**: `whereContains` (`LIKE '%val%'`), `whereEndsWith` (`LIKE '%val'`), `whereContainsAny`.
>    *   **Consultas de negação**: `whereNotEqual` (`!=`, `<>`), `whereNotIn` (`NOT IN`), `whereNotNull` (`IS NOT null`/`whereNotEmpty`).
>    *   **Incompatibilidade de padrões**: `NOT LIKE`.
>    *   *Explicação: As operações acima geralmente exigem percorrer toda a área de armazenamento de dados, mesmo que um índice tenha sido criado. Embora o impacto seja mínimo em dispositivos móveis ou pequenos conjuntos de dados, em cenários de análise de dados distribuídos ou de tamanho extra grande, elas devem ser usadas com cautela, combinadas com outras condições de índice (por exemplo, restringir dados por ID ou intervalo de tempo) e a cláusula `limit`.*

## <a id="distributed-architecture"></a>Arquitetura Distribuída

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

## <a id="primary-key-examples"></a>Exemplos de chave primária

ToStore fornece vários algoritmos de chave primária distribuídos para diferentes cenários de negócios:

- **Chave primária sequencial** (`PrimaryKeyType.sequential`): `238978991`
- **Chave primária baseada em carimbo de data/hora** (`PrimaryKeyType.timestampBased`): `1306866018836946`
- **Chave primária com prefixo de data** (`PrimaryKeyType.datePrefixed`): `20250530182215887631`
- **Chave primária de código curto** (`PrimaryKeyType.shortCode`): `9eXrF0qeXZ`

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


## <a id="atomic-expressions"></a>Expressões Atômicas

O sistema de expressão fornece atualizações de campo atômico com segurança de tipo. Todos os cálculos são executados atomicamente na camada do banco de dados, evitando conflitos simultâneos:

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

**Expressões condicionais (por exemplo, diferenciando update vs insert em um upsert)**: use `Expr.isUpdate()` / `Expr.isInsert()` junto com `Expr.ifElse` ou `Expr.when` para que a expressão seja avaliada somente na atualização ou somente na inserção.

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

## <a id="transactions"></a>Transações

As transações garantem a atomicidade em múltiplas operações: ou tudo é bem-sucedido ou tudo é revertido, preservando a consistência dos dados.

**Características da transação**
- múltiplas operações, todas bem-sucedidas ou todas revertidas
- o trabalho inacabado é recuperado automaticamente após falhas
- operações bem-sucedidas são persistidas com segurança

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


### <a id="database-maintenance"></a>Administração e Manutenção

As APIs a seguir cobrem administração de banco de dados, diagnóstico e manutenção para desenvolvimento estilo plug-in, painéis de administração e cenários operacionais:

- **Gerenciamento de mesa**
  - `createTable(schema)`: cria uma única tabela manualmente; útil para carregamento de módulo ou criação de tabela de tempo de execução sob demanda
  - `getTableSchema(tableName)`: recupera as informações do esquema definido; útil para validação automatizada ou geração de modelo de UI
  - `getTableInfo(tableName)`: recupera estatísticas da tabela de tempo de execução, incluindo contagem de registros, contagem de índices, tamanho do arquivo de dados, tempo de criação e se a tabela é global
  - `clear(tableName)`: limpe todos os dados da tabela enquanto retém com segurança o esquema, os índices e as restrições de chave internas/externas
  - `dropTable(tableName)`: destrói completamente uma tabela e seu esquema; não reversível
- **Gerenciamento de espaço**
  - `currentSpaceName`: obtenha o espaço ativo atual em tempo real
  - `listSpaces()`: lista todos os espaços alocados na instância atual do banco de dados
  - `getSpaceInfo(useCache: true)`: audita o espaço atual; use `useCache: false` para ignorar o cache e ler o estado em tempo real
  - `deleteSpace(spaceName)`: exclui um espaço específico e todos os seus dados, exceto `default` e o espaço ativo atual
- **Descoberta de instância**
  - `config`: inspeciona o instantâneo `DataStoreConfig` efetivo final da instância
  - `instancePath`: localize o diretório de armazenamento físico com precisão
  - `getVersion()` / `setVersion(version)`: controle de versão definido pelo negócio para decisões de migração em nível de aplicativo (não a versão do mecanismo)
- **Manutenção**
  - `flush(flushStorage: true)`: força dados pendentes para disco; se `flushStorage: true`, o sistema também será solicitado a liberar buffers de armazenamento de nível inferior
  - `deleteDatabase()`: remove todos os arquivos físicos e metadados da instância atual; use com cuidado
- **Diagnóstico**
  - `db.status.memory()`: inspeciona as taxas de acertos do cache, o uso da página de índice e a alocação geral de heap
  - `db.status.space()` / `db.status.table(tableName)`: inspeciona estatísticas ao vivo e informações de integridade de espaços e tabelas
  - `db.status.config()`: inspeciona o instantâneo de configuração do tempo de execução atual
  - `db.status.migration(taskId)`: acompanhe o progresso da migração assíncrona em tempo real

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


### <a id="backup-restore"></a>Backup e restauração

Especialmente útil para importação/exportação local de usuário único, grande migração de dados offline e reversão do sistema após falha:

- **Backup (`backup`)**
  - `compress`: habilita a compactação; recomendado e ativado por padrão
  - `scope`: controla o intervalo de backup
    - `BackupScope.database`: faz backup de **toda a instância do banco de dados**, incluindo todos os espaços e tabelas globais
    - `BackupScope.currentSpace`: faz backup apenas do **espaço ativo atual**, excluindo tabelas globais
    - `BackupScope.currentSpaceWithGlobal`: faz backup do **espaço atual mais suas tabelas globais relacionadas**, ideal para migração de locatário único ou usuário único
- **Restaurar (`restore`)**
  - `backupPath`: caminho físico para o pacote de backup
  - `cleanupBeforeRestore`: se deseja limpar silenciosamente os dados atuais relacionados antes da restauração; `true` é recomendado para evitar estados lógicos mistos
  - `deleteAfterRestore`: exclui automaticamente o arquivo de origem do backup após uma restauração bem-sucedida

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

### <a id="error-handling"></a>Códigos de status e tratamento de erros


ToStore usa um modelo de resposta unificado para operações de dados:

- `ResultType`: a enumeração de status unificada usada para lógica de ramificação
- `result.code`: um código numérico estável correspondente a `ResultType`
- `result.message`: uma mensagem legível descrevendo o erro atual
- `successKeys` / `failedKeys`: listas de chaves primárias bem-sucedidas e com falha em operações em massa


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

Exemplos de códigos de status comuns:
O sucesso retorna `0`; números negativos indicam erros.
- `ResultType.success` (`0`): operação bem-sucedida
- `ResultType.partialSuccess` (`1`): operação em massa parcialmente bem-sucedida
- `ResultType.unknown` (`-1`): erro desconhecido
- `ResultType.uniqueViolation` (`-2`): conflito de índice exclusivo
- `ResultType.primaryKeyViolation` (`-3`): conflito de chave primária
- `ResultType.foreignKeyViolation` (`-4`): referência de chave estrangeira não satisfaz restrições
- `ResultType.notNullViolation` (`-5`): um campo obrigatório está faltando ou um `null` não permitido foi aprovado
- `ResultType.validationFailed` (`-6`): comprimento, intervalo, formato ou outra validação falhou
- `ResultType.notFound` (`-11`): tabela, espaço ou recurso de destino não existe
- `ResultType.resourceExhausted` (`-15`): recursos de sistema insuficientes; reduza a carga ou tente novamente
- `ResultType.dbError` (`-91`): erro de banco de dados
- `ResultType.ioError` (`-90`): erro no sistema de arquivos
- `ResultType.timeout` (`-92`): tempo limite

### Tratamento de resultados de transações
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

Tipos de erros de transação:
- `TransactionErrorType.operationError`: uma operação regular falhou dentro da transação, como falha na validação de campo, estado de recurso inválido ou outro erro de nível de negócio
- `TransactionErrorType.integrityViolation`: conflito de integridade ou restrição, como chave primária, chave única, chave estrangeira ou falha não nula
- `TransactionErrorType.timeout`: tempo limite
- `TransactionErrorType.io`: armazenamento subjacente ou erro de E/S do sistema de arquivos
- `TransactionErrorType.conflict`: um conflito causou falha na transação
- `TransactionErrorType.userAbort`: aborto iniciado pelo usuário (abortamento manual baseado em lançamento não é suportado atualmente)
- `TransactionErrorType.unknown`: qualquer outro erro


### <a id="logging-diagnostics"></a>Log de retorno de chamada e diagnóstico de banco de dados

O ToStore pode rotear logs de inicialização, recuperação, migração automática e conflitos de restrição de tempo de execução de volta para a camada de negócios por meio de `LogConfig.setConfig(...)`.

- `onLogHandler` recebe todos os logs que passam pelos filtros `enableLog` e `logLevel` atuais.
- Chame `LogConfig.setConfig(...)` antes da inicialização para que os logs gerados durante a inicialização e a migração automática também sejam capturados.

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


## <a id="security-config"></a>Configuração de segurança

> [!WARNING]
> **Gerenciamento de chaves**: **`encodingKey`** pode ser alterado livremente e o mecanismo migrará os dados automaticamente, para que os dados permaneçam recuperáveis. **`encryptionKey`** não deve ser alterado casualmente. Depois de alterados, os dados antigos não podem ser descriptografados, a menos que você os migre explicitamente. Nunca codifique chaves sensíveis; é recomendável buscá-los em um serviço seguro.

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

### Criptografia em nível de valor (ToCrypto)

A criptografia completa do banco de dados protege todos os dados de tabelas e índices, mas pode afetar o desempenho geral. Se você precisar proteger apenas alguns valores confidenciais, use **ToCrypto**. Ele é desacoplado do banco de dados, não requer instância `db` e permite que seu aplicativo codifique/decodifique valores antes da gravação ou após a leitura. A saída é Base64, que cabe naturalmente em colunas JSON ou TEXT.

- **`key`** (obrigatório): `String` ou `Uint8List`. Se não tiver 32 bytes, SHA-256 será usado para derivar uma chave de 32 bytes.
- **`type`** (opcional): tipo de criptografia de `ToCryptoType`, como `ToCryptoType.chacha20Poly1305` ou `ToCryptoType.aes256Gcm`. O padrão é `ToCryptoType.chacha20Poly1305`.
- **`aad`** (opcional): dados adicionais autenticados do tipo `Uint8List`. Se fornecidos durante a codificação, os mesmos bytes também deverão ser fornecidos durante a decodificação.

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


## <a id="advanced-config"></a>Explicação da configuração avançada (DataStoreConfig)

> [!TIP]
> **Inteligência de configuração zero**
> O ToStore detecta automaticamente a plataforma, as características de desempenho, a memória disponível e o comportamento de E/S para otimizar parâmetros como simultaneidade, tamanho do fragmento e orçamento de cache. **Em 99% dos cenários de negócios comuns, você não precisa ajustar `DataStoreConfig` manualmente.** Os padrões já oferecem excelente desempenho para a plataforma atual.


| Parâmetro | Padrão | Objetivo e recomendação |
| :--- | :--- | :--- |
| **`yieldDurationMs`** | **8ms** | **Recomendação principal.** O intervalo de tempo usado quando tarefas longas resultam. `8ms` se alinha bem com a renderização de 120fps/60fps e ajuda a manter a interface do usuário suave durante grandes consultas ou migrações. |
| **`maxQueryOffset`** | **10.000** | **Proteção de consulta.** Quando `offset` excede esse limite, um erro é gerado. Isso evita E/S patológica de paginação de deslocamento profundo. |
| **`defaultQueryLimit`** | **1000** | **Proteção de recursos.** Aplicado quando uma consulta não especifica `limit`, evitando o carregamento acidental de conjuntos de resultados massivos e possíveis problemas de OOM. |
| **`cacheMemoryBudgetMB`** | (automático) | **Gerenciamento de memória refinado.** Orçamento total de memória cache. O mecanismo o utiliza para conduzir a recuperação de LRU automaticamente. |
| **`enableJournal`** | **verdade** | **Autocorreção de falhas.** Quando ativado, o mecanismo pode se recuperar automaticamente após falhas ou falhas de energia. |
| **`persistRecoveryOnCommit`** | **verdade** | **Forte garantia de durabilidade.** Quando verdadeira, as transações confirmadas são sincronizadas com o armazenamento físico. Quando falso, a liberação é feita de forma assíncrona em segundo plano para melhor velocidade, com um pequeno risco de perda de uma pequena quantidade de dados em falhas extremas. |
| **`ttlCleanupIntervalMs`** | **300.000** | **Pesquisa TTL global.** O intervalo em segundo plano para verificação de dados expirados quando o mecanismo não está ocioso. Valores mais baixos excluem os dados expirados mais cedo, mas custam mais despesas gerais. |
| **`maxConcurrency`** | (automático) | **Controle de simultaneidade computacional.** Define a contagem máxima de trabalhadores paralelos para tarefas intensivas, como computação vetorial e criptografia/descriptografia. Mantê-lo automático geralmente é melhor. |

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

## <a id="performance"></a>Desempenho e Experiência

### Referências

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.gif" alt="ToStore Basic Performance Demo" width="320" />
</p>

- **Demonstração de desempenho básico** (<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/basic-demo.mp4" target="_blank" rel="noopener">basic-demo.mp4</a>): a visualização do GIF pode não mostrar tudo. Por favor, abra o vídeo para a demonstração completa. Mesmo em dispositivos móveis comuns, a inicialização, a paginação e a recuperação permanecem estáveis ​​e suaves mesmo quando o conjunto de dados excede 100 milhões de registros.

<p align="center">
  <img src="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.gif" alt="ToStore Disaster Recovery Stress Test" width="320" />
</p>

- **Teste de estresse de recuperação de desastres** (<a href="https://raw.githubusercontent.com/tocreator/.toway-assets/main/tostore/disaster-recovery.mp4" target="_blank" rel="noopener">disaster-recovery.mp4</a>): durante gravações de alta frequência, o processo é interrompido intencionalmente repetidas vezes para simular travamentos e falhas de energia. ToStore é capaz de se recuperar rapidamente.


### Dicas de experiência

- 📱 **Exemplo de projeto**: o diretório `example` inclui um aplicativo Flutter completo
- 🚀 **Builds de produção**: empacotar e testar em modo release; o desempenho da versão está muito além do modo de depuração
- ✅ **Testes padrão**: os principais recursos são cobertos por testes padronizados


Se o ToStore ajudar você, dê-nos um ⭐️
É uma das melhores formas de apoiar o projeto. Muito obrigado.


> **Recomendação**: Para desenvolvimento de aplicativos frontend, considere a [estrutura ToApp](https://github.com/tocreator/toapp), que fornece uma solução full-stack que automatiza e unifica solicitações de dados, carregamento, armazenamento, cache e apresentação.


## <a id="more-resources"></a>Mais recursos

- 📖 **Documentação**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **Relatório de problemas**: [Problemas do GitHub](https://github.com/tocreator/tostore/issues)
- 💬 **Discussão técnica**: [Discussões no GitHub](https://github.com/tocreator/tostore/discussions)



