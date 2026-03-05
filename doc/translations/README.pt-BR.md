# Tostore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | Português (Brasil) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![License](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](https://opensource.org/licenses/Apache-2.0)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)


## Por que escolher o Tostore?

O Tostore é o único mecanismo de armazenamento de alto desempenho para bancos de dados de vetores distribuídos no ecossistema Dart/Flutter. Utilizando uma arquitetura semelhante a uma rede neural, ele apresenta interconectividade inteligente e colaboração entre nós, suportando escalonamento horizontal infinito. Ele constrói uma rede de topologia de dados flexível e fornece identificação precisa de mudanças de esquema, proteção por criptografia e isolamento de dados multiespaciais. O Tostore aproveita totalmente as CPUs multi-core para processamento paralelo extremo e oferece suporte nativo à colaboração multiplataforma, desde dispositivos de borda (edge) móveis até a nuvem. Com vários algoritmos de chaves primárias distribuídas, ele fornece uma base de dados poderosa para cenários como realidade virtual imersiva, interação multimodal, computação espacial, IA generativa e modelagem de espaço vetorial semântico.

À medida que a IA generativa e a computação espacial deslocam o centro de gravidade para a borda (edge), os dispositivos terminais estão evoluindo de meros visualizadores de conteúdo para núcleos de geração local, percepção ambiental e tomada de decisão em tempo real. Os bancos de dados incorporados tradicionais de arquivo único são limitados pelo seu design arquitetônico, muitas vezes lutando para suportar os requisitos de resposta imediata de aplicações inteligentes diante de gravações de alta simultaneidade, recuperação de vetores massivos e geração colaborativa nuvem-borda. O Tostore nasceu para dispositivos de borda, dotando-os de capacidades de armazenamento distribuído suficientes para suportar a geração local de IA complexa e o fluxo de dados em larga escala, alcançando uma verdadeira colaboração profunda entre a nuvem e a borda.

**Resistente a falhas de energia e travamentos**: Mesmo em caso de uma interrupção inesperada de energia ou travamento da aplicação, os dados podem ser recuperados automaticamente, alcançando uma perda zero real. Quando uma operação de dados responde, os dados já foram salvos com segurança, eliminando o risco de perda de dados.

**Superando os limites de desempenho**: Testes mostram que, mesmo com mais de 100 milhões de registros, um smartphone típico pode manter desempenho de busca constante independente da escala dos dados, oferecendo uma experiência que supera em muito a dos bancos de dados tradicionais.




...... Da ponta dos dedos às aplicações em nuvem, o Tostore ajuda você a liberar o poder de computação de dados e a impulsionar o futuro ......




## Características do Tostore

- 🌐 **Suporte total multiplataforma contínuo**
  - Execute o mesmo código em todas as plataformas, desde aplicativos móveis até servidores em nuvem.
  - Adapta-se inteligentemente a diferentes backends de armazenamento de plataforma (IndexedDB, sistema de arquivos, etc.).
  - Interface API unificada para sincronização de dados multiplataforma sem preocupações.
  - Fluxo de dados contínuo de dispositivos de borda para servidores em nuvem.
  - Computação vetorial local em dispositivos de borda, reduzindo a latência de rede e a dependência da nuvem.

- 🧠 **Arquitetura distribuída tipo rede neural**
  - Estrutura de topologia de nós interconectados para uma organização eficiente do fluxo de dados.
  - Mecanismo de particionamento de dados de alto desempenho para um verdadeiro processamento distribuído.
  - Equilíbrio dinâmico inteligente de carga de trabalho para maximizar a utilização de recursos.
  - Escalonamento horizontal infinito de nós para construir facilmente redes de dados complexas.

- ⚡ **Máxima capacidade de processamento paralelo**
  - Leitura/gravação paralela real usando Isolates, funcionando em velocidade máxima em CPUs multi-core.
  - O agendamento inteligente de recursos equilibra automaticamente a carga para maximizar o desempenho multi-core.
  - A rede de computação multinó colaborativa dobra a eficiência do processamento de tarefas.
  - O framework de agendamento consciente de recursos otimiza automaticamente os planos de execução para evitar conflitos de recursos.
  - A interface de consulta por fluxo (streaming) lida com conjuntos de dados massivos com facilidade.

- 🔑 **Diversos algoritmos de chaves primárias distribuídas**
  - Algoritmo de incremento sequencial - Ajuste livremente os tamanhos de passo aleatórios para ocultar a escala do negócio.
  - Algoritmo baseado em timestamp - A melhor escolha para cenários de alta simultaneidade.
  - Algoritmo de prefixo de data - Suporte perfeito para exibição de dados em intervalos de tempo.
  - Algoritmo de código curto - Gera identificadores únicos curtos e fáceis de ler.

- 🔄 **Migração inteligente de esquema e integridade de dados**
  - Identifica com precisão campos de tabela renomeados com zero perda de dados.
  - Detecção automática de mudanças de esquema e migração de dados em milissegundos.
  - Atualizações sem tempo de inatividade, imperceptíveis para o negócio.
  - Estratégias de migração seguras para mudanças de estrutura complexas.
  - Validação automática de restrições de chaves estrangeiras com suporte a cascata, garantindo a integridade referencial.

- 🛡️ **Segurança e durabilidade de nível empresarial**
  - Mecanismo de dupla proteção: o registro em tempo real das alterações de dados garante que nada seja perdido.
  - Recuperação automática de travamentos: retoma automaticamente operações inacabadas após falha de energia ou travamento.
  - Garantia de consistência de dados: as operações ou têm sucesso total ou são totalmente revertidas (rollback).
  - Atualizações computacionais atômicas: o sistema de expressões suporta cálculos complexos, executados atomicamente para evitar conflitos de concorrência.
  - Persistência segura instantânea: os dados são salvos com segurança quando a operação tem sucesso.
  - O algoritmo de criptografia de alta resistência ChaCha20Poly1305 protege dados sensíveis.
  - Criptografia de ponta a ponta para segurança durante todo o armazenamento e transmissão.

- 🚀 **Cache inteligente e desempenho de recuperação**
  - Mecanismo de cache inteligente multinível para recuperação de dados ultrarrápida.
  - Estratégias de cache profundamente integradas com o mecanismo de armazenamento.
  - O escalonamento adaptativo mantém o desempenho estável à medida que a escala de dados cresce.
  - Notificações de alterações de dados em tempo real com atualizações automáticas dos resultados de consulta.

- 🔄 **Fluxo de trabalho de dados inteligente**
  - A arquitetura multiespacial fornece isolamento de dados junto com o compartilhamento global.
  - Distribuição inteligente da carga de trabalho entre nós de computação.
  - Fornece uma base sólida para treinamento e análise de dados em larga escala.


## Instalação

> [!IMPORTANT]
> **Atualizando da v2.x?** Leia o [Guia de atualização v3.0](../UPGRADE_GUIDE_v3.md) para etapas críticas de migração e alterações significativas.

Adicione `tostore` como dependência em seu `pubspec.yaml`:

```yaml
dependencies:
  tostore: any # Por favor, use a versão mais recente
```

## Início Rápido

> [!IMPORTANT]
> **Definir o esquema da tabela é o primeiro passo**: Antes de realizar operações CRUD, você deve definir o esquema da tabela. O método de definição específico depende do seu cenário:
> - **Móvel/Desktop**: Recomendado [Definição estática](#integração-para-cenários-de-inicialização-frequente).
> - **Lado do servidor**: Recomendado [Criação dinâmica](#integração-no-lado-do-servidor).

```dart
// 1. Inicializar o banco de dados
final db = await ToStore.open();

// 2. Inserir dados
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
  'age': 25,
});

// 3. Consultas encadeadas ([operadores de consulta](#operadores-de-consulta), suporta =, !=, >, <, LIKE, IN, etc.)
final users = await db.query('users')
    .where('age', '>', 20)
    .where('username', 'like', '%John%')
    .orderByDesc('age')
    .limit(10);

// 4. Atualizar e Excluir
await db.update('users', {'age': 26}).where('username', '=', 'John');
await db.delete('users').where('username', '=', 'John');

// 5. Escuta em tempo real (a interface se atualiza automaticamente)
db.query('users').where('age', '>', 18).watch().listen((users) {
  print('Usuários correspondentes atualizados: $users');
});
```

### Armazenamento Chave-Valor (KV)
Adequado para cenários que não exigem definir tabelas estruturadas. É simples, prático e inclui um armazenamento KV de alto desempenho integrado para configurações, estados e outros datos dispersos. Os dados em espaços (Spaces) diferentes são naturalmente isolados, mas podem ser configurados para compartilhamento global.

```dart
// 1. Definir pares chave-valor (Suporta String, int, bool, double, Map, List, etc.)
await db.setValue('theme', 'dark');
await db.setValue('login_attempts', 3);

// 2. Obter dados
final theme = await db.getValue('theme'); // 'dark'

// 3. Excluir dados
await db.removeValue('theme');

// 4. Chave-valor global (compartilhado entre Spaces)
// Dados KV por padrão são específicos do espaço. Use isGlobal: true para compartilhamento.
await db.setValue('app_version', '1.0.0', isGlobal: true);
final version = await db.getValue('app_version', isGlobal: true);
```



## Integração para Cenários de Inicialização Frequente

📱 **Exemplo**: [mobile_quickstart.dart](example/lib/mobile_quickstart.dart)

```dart
// Definição de esquema adequada para aplicativos móveis e desktop de inicialização frequente.
// Identifica com precisão as mudanças de esquema e migra automaticamente os dados.
final db = await ToStore.open(
  schemas: [
    const TableSchema(
            name: 'global_settings',
            isGlobal: true,  // Tabela global acessível a todos os espaços
            fields: [],
    ),
    const TableSchema(
      name: 'users', // Nome da tabela
      tableId: "users",  // Identificador exclusivo para detecção de renomeação de 100%
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id',       // Nome da chave primária
      ),
      fields: [        // Definições de campo (excluindo a chave primária)
        FieldSchema(
          name: 'username', 
          type: DataType.text, 
          nullable: false, 
          unique: true, // Cria automaticamente um índice único
          fieldId: 'username',  // Identificador de campo exclusivo
        ),
        FieldSchema(
          name: 'email', 
          type: DataType.text, 
          nullable: false, 
          unique: true // Cria automaticamente um índice único
        ),
        FieldSchema(
          name: 'last_login', 
          type: DataType.datetime,
          createIndex: true // Cria automaticamente um índice
        ),
      ],
      // Exemplo de índice composto
      indexes: [
        IndexSchema(fields: ['username', 'last_login']),
      ],
    ),
    // Exemplo de restrição de chave estrangeira
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
          fields: ['user_id'],              // Campos da tabela atual
          referencedTable: 'users',         // Tabela referenciada
          referencedFields: ['id'],         // Campos referenciados
          onDelete: ForeignKeyCascadeAction.cascade,  // Exclusão em cascata
          onUpdate: ForeignKeyCascadeAction.cascade,  // Atualização em cascata
        ),
      ],
    ),
  ],
);

// Arquitetura multiespacial - isolamento perfeito de dados de diferentes usuários
await db.switchSpace(spaceName: 'user_123');
```

### Manter estado de login e logout (espaço ativo)

O multi-espaço funciona bem para **dados por usuário**: um espaço por usuário e troca no login. Com **espaço ativo** e as opções de **close** você mantém o usuário atual entre reinícios e suporta logout.

- **Manter estado de login**: Ao trocar o usuário para o espaço dele, salve como espaço ativo para que na próxima abertura com default entre direto nesse espaço (sem precisar «abrir default e depois trocar»).
- **Logout**: No logout, feche o banco com `keepActiveSpace: false` para que a próxima abertura não abra automaticamente no espaço do usuário anterior.

```dart

// Após o login: trocar para o espaço deste usuário e lembrar na próxima abertura (manter login)
await db.switchSpace(spaceName: 'user_$userId', keepActive: true);

// Opcional: abrir estritamente em default (ex.: só tela de login) — não usar o espaço ativo salvo
// final db = await ToStore.open(..., applyActiveSpaceOnDefault: false);

// No logout: fechar e limpar espaço ativo para que a próxima abertura use o espaço default
await db.close(keepActiveSpace: false);
```

## Integração no Lado do Servidor

🖥️ **Exemplo**: [server_quickstart.dart](example/lib/server_quickstart.dart)

```dart
final db = await ToStore.open();

// Criação massiva de esquemas em tempo de execução
await db.createTables([
  // Tabela de armazenamento de vetores de características espaciais 3D
  const TableSchema(
    name: 'spatial_embeddings',
    primaryKeyConfig: PrimaryKeyConfig(
      name: 'id',
      type: PrimaryKeyType.timestampBased,   // PK de timestamp para alta simultaneidade
    ),
    fields: [
      FieldSchema(
        name: 'video_name',
        type: DataType.text,
        nullable: false,
      ),
      FieldSchema(
        name: 'spatial_features',
        type: DataType.vector,                // Tipo de armazenamento vetorial
        vectorConfig: VectorFieldConfig(
          dimensions: 1024,                   // Vetor de alta dimensão
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
        type: IndexType.vector,              // Índice vetorial
        fields: ['spatial_features'],
        vectorConfig: VectorIndexConfig(
          indexType: VectorIndexType.ngh,   // Algoritmo NGH para ANN eficiente
          distanceMetric: VectorDistanceMetric.cosine,
          parameters: {
            'M': 16,
            'efConstruction': 200,
          },
        ),
      ),
    ],
  ),
  // Outras tabelas...
]);

// Atualizações de Esquema Online - Sem interrupção para o negócio
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
  .setPrimaryKeyConfig(                    // Alterar config de PK
    const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
  );
    
// Monitorar progresso da migração
final status = await db.queryMigrationTaskStatus(taskId);
print('Progresso da migração: ${status?.progressPercentage}%');


// Gerenciamento Manual de Cache de Consulta (Lado do Servidor)
// Gerenciado automaticamente em plataformas de cliente.
// Para servidor ou dados em larga escala, use essas APIs para controle preciso.

// Armazenar manualmente o resultado de uma consulta por 5 minutos.
final activeUsers = await db.query('users')
    .where('is_active', '=', true)
    .useQueryCache(const Duration(minutes: 5));

// Invalidar cache específica quando os dados mudam.
await db.query('users')
    .where('is_active', '=', true)
    .clearQueryCache();

// Desabilitar explicitamente o cache para consultas com dados em tempo real.
final freshUserData = await db.query('users')
    .where('is_active', '=', true)
    .noQueryCache();
```



## Uso Avançado

O Tostore fornece um conjunto rico de recursos avançados para requisitos complexos:

### TTL em nível de tabela (expiração automática baseada em tempo)

Para logs, eventos e outros dados que devem expirar automaticamente com base no tempo, você pode definir um TTL em nível de tabela usando `ttlConfig`. Os dados expirados são limpos em segundo plano em pequenos lotes, sem precisar percorrer manualmente todos os registros na sua lógica de negócio:

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
    ttlMs: 7 * 24 * 60 * 60 * 1000, // manter por 7 dias
    // Quando sourceField é omitido, o mecanismo usa o horário de escrita
    // e gerencia automaticamente o índice necessário.
    // Opcional: ao definir um sourceField personalizado, o campo deve:
    // 1) ter tipo DataType.datetime
    // 2) ser não nulo (nullable: false)
    // 3) usar DefaultValueType.currentTimestamp como defaultValueType
    // sourceField: 'created_at',
  ),
);
```

### Consultas Aninhadas e Filtragem Personalizada
Suporta aninhamento infinito de condições e funções personalizadas flexíveis.

```dart
// Aninhamento de condições: (type = 'app' OR (id >= 123 OR fans >= 200))
final idCondition = QueryCondition().where('id', '>=', 123).or().where('fans', '>=', 200);

final result = await db.query('users')
    .condition(
        QueryCondition().whereEqual('type', 'app').or().condition(idCondition)
    )
    .limit(20);

// Função de condição personalizada
final customResult = await db.query('users')
    .whereCustom((record) => record['tags']?.contains('recomendado') ?? false);
```

### Upsert Inteligente
Atualiza se existir, caso contrário insere.

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


### Junções (Joins) e Seleção de Campos
```dart
final orders = await db.query('orders')
    .select(['orders.id', 'users.name as user_name'])
    .join('users', 'orders.user_id', '=', 'users.id')
    .where('orders.amount', '>', 1000);
```

### Fluxo (Streaming) e Estatísticas
```dart
// Contar registros
final count = await db.query('users').count();

// Verificar se a tabela está definida no schema do banco de dados (independente do Space)
// Nota: isso NÃO indica se a tabela possui dados
final usersTableDefined = await db.tableExists('users');

// Verificação eficiente de existência baseada em condições (sem carregar registros completos)
final emailExists = await db.query('users')
    .where('email', '=', 'test@example.com')
    .exists();

// Funções de agregação
final totalAge = await db.query('users').where('age', '>', 18).sum('age');
final avgAge = await db.query('users').avg('age');
final maxAge = await db.query('users').max('age');
final minAge = await db.query('users').min('age');

// Agrupamento e filtragem
final result = await db.query('orders')
    .select(['status', Agg.sum('amount', alias: 'total')])
    .groupBy(['status'])
    .having(Agg.sum('amount'), '>', 1000)
    .limit(20);

// Consulta de valores distintos
final uniqueCities = await db.query('users').distinct(['city']);

// Consulta por fluxo (adequada para dados massivos)
db.streamQuery('users').listen((data) => print(data));
```



### Consultas e Paginação Eficiente

O Tostore oferece suporte a paginação de modo duplo:

#### 1. Modo Offset
Adequado para pequenos conjuntos de dados ou quando o salto para uma página específica é necessário.

```dart
final result = await db.query('users')
    .orderByDesc('created_at')
    .offset(40) // Pular os primeiros 40
    .limit(20); // Pegar 20
```
> [!TIP]
> Quando o `offset` é muito grande, o banco de dados deve escanear e descartar muitos registros, levando à degradação do desempenho. Use o **Modo Cursor** para paginação profunda.

#### 2. Modo Cursor de Alto Desempenho
**Recomendado para dados massivos e cenários de rolagem infinita**. Utiliza `nextCursor` para desempenho O(1), garantindo velocidade de consulta constante.

> [!IMPORTANT]
> Se ordenar por um campo não indexado ou para certas consultas complexas, o motor pode voltar para a varredura completa da tabela e retornar um cursor `null` (o que significa que a paginação para essa consulta específica ainda não é suportada).

```dart
// Página 1
final page1 = await db.query('users')
    .orderByDesc('id')
    .limit(20);

// Buscar próxima página usando o cursor
if (page1.nextCursor != null) {
  final page2 = await db.query('users')
      .orderByDesc('id')
      .limit(20)
      .cursor(page1.nextCursor); // Buscar diretamente a posição
}

// Retroceder eficientemente com prevCursor
final prevPage = await db.query('users')
    .limit(20)
    .cursor(page2.prevCursor);
```

| Recurso | Modo Offset | Modo Cursor |
| :--- | :--- | :--- |
| **Desempenho** | Diminui conforme a página aumenta | **Constante (O(1))** |
| **Complexidade** | Dados pequenos, saltos de página | **Dados massivos, rolagem infinita** |
| **Consistência** | Alterações podem causar saltos | **Perfeita integridade diante de alterações** |



### Operadores de consulta

Operadores (insensíveis a maiúsculas) para `where(field, operator, value)`:

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

### Métodos de consulta semânticos (recomendado)

Prefira métodos semânticos em vez de digitar operadores manualmente.

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

## Arquitetura Distribuída

```dart
// Configurar Nós Distribuídos
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

// Inserção em lote de alto desempenho (Batch Insert)
await db.batchInsert('vector_data', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... Registros inseridos eficientemente em lote
]);

// Processar grandes conjuntos de dados por fluxo - Memória constante
await for (final record in db.streamQuery('vector_data')
  .where('vector_name', '=', 'face_2366')
  .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
  .stream) {
  // Processa eficientemente até dados em escala TB sem alto consumo de memória
  print(record);
}
```

## Exemplos de Chaves Primárias

O Tostore fornece vários algoritmos de chaves primárias distribuídas:

- **Sequencial** (PrimaryKeyType.sequential): 238978991
- **Baseado em timestamp** (PrimaryKeyType.timestampBased): 1306866018836946
- **Prefixo de data** (PrimaryKeyType.datePrefixed): 20250530182215887631
- **Código curto** (PrimaryKeyType.shortCode): 9eXrF0qeXZ

```dart
// Exemplo de configuração de chave primária sequencial
await db.createTables([
  const TableSchema(
    name: 'users',
    primaryKeyConfig: PrimaryKeyConfig(
      type: PrimaryKeyType.sequential,
      sequentialConfig: SequentialIdConfig(
        initialValue: 10000,
        increment: 50,
        useRandomIncrement: true, // Ocultar volume de negócios
      ),
    ),
    fields: [/* Definição de campos */]
  ),
]);
```


## Operações Atômicas com Expressões

O sistema de expressões fornece atualizações de campo atômicas e seguras. Todos os cálculos são executados atomicamente no nível do banco de dados para evitar conflitos de simultaneidade:

```dart
// Incremento Simples: balance = balance + 100
await db.update('accounts', {
  'balance': Expr.field('balance') + Expr.value(100),
}).where('id', '=', accountId);

// Cálculo Complexo: total = price * quantity + tax
await db.update('orders', {
  'total': Expr.field('price') * Expr.field('quantity') + Expr.field('tax'),
}).where('id', '=', orderId);

// Parênteses aninhados: finalPrice = ((price * quantity) + tax) * (1 - discount)
await db.update('orders', {
  'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) * 
                 (Expr.value(1) - Expr.field('discount')),
}).where('id', '=', orderId);

// Uso de funções: price = min(price, maxPrice)
await db.update('products', {
  'price': Expr.min(Expr.field('price'), Expr.field('maxPrice')),
}).where('id', '=', productId);

// Símbolo de tempo: updatedAt = now()
await db.update('users', {
  'updatedAt': Expr.now(),
}).where('id', '=', userId);
```

## Transações

As transações asseguram a atomicidade de múltiplas operações: ou todas têm sucesso ou todas são revertidas, garantindo a consistência dos dados.

**Características das Transações**:
- Execução atômica de múltiplas operações.
- Recuperação automática de operações inacabadas após um travamento.
- Os dados são salvos com segurança ao confirmar (commit) com sucesso.

```dart
// Transação básica
final txResult = await db.transaction(() async {
  // Inserir usuário
  await db.insert('users', {
    'username': 'john',
    'email': 'john@example.com',
    'fans': 100,
  });
  
  // Atualização atômica usando expressões
  await db.update('users', {
    'fans': Expr.field('fans') + Expr.value(50),
  }).where('username', '=', 'john');
  
  // Se qualquer operação falhar, todas as alterações são revertidas automaticamente.
});

if (txResult.isSuccess) {
  print('Transação confirmada com sucesso');
} else {
  print('Transação revertida: ${txResult.error?.message}');
}

// Reversão automática em caso de erro
final txResult2 = await db.transaction(() async {
  await db.insert('users', {
    'username': 'jane',
    'email': 'jane@example.com',
  });
  throw Exception('Erro de lógica de negócio'); // Ativa a reversão
}, rollbackOnError: true);
```

### Modo de Memória Puro (Memory Mode)

Para cenários como cache de dados, computações temporárias ou ambientes sem disco em que a persistência em disco não é necessária, você pode inicializar um banco de dados totalmente em memória usando `ToStore.memory()`. Neste modo, todos os dados (incluindo esquemas, índices e pares chave-valor) são mantidos estritamente na memória.

**Nota**: Os dados criados no modo de memória são completamente perdidos após o fechamento ou reinicialização do aplicativo.

```dart
// Inicializa o banco de dados no modo de memória pura
final db = await ToStore.memory(
  schemas: [],
);

// Todas as operações (CRUD e pesquisa) são executadas instantaneamente na memória
await db.insert('temp_cache', {'key': 'session_1', 'value': {'user': 'admin'}});

```


## Configuração de Segurança

**Mecanismos de Segurança de Dados**:
- Mecanismos de dupla proteção garantem que os dados nunca sejam perdidos.
- Recuperação automática de travamentos para operações incompletas.
- Persistência segura instantânea ao sucesso da operação.
- Criptografia de alta resistência protege dados sensíveis.

> [!WARNING]
> **Gestão de Chaves**: **`encodingKey`** pode ser alterada livremente; o motor migrará os dados automaticamente ao alterá-la, sem risco de perda. **`encryptionKey`** não deve ser alterada arbitrariamente: alterá-la tornará os dados antigos ilegíveis, a menos que uma migração seja realizada. Não codifique chaves sensíveis; obtenha-as de um servidor seguro.

```dart
final db = await ToStore.open(
  config: DataStoreConfig(
    encryptionConfig: EncryptionConfig(
      // Algoritmos suportados: none, xorObfuscation, chacha20Poly1305, aes256Gcm
      encryptionType: EncryptionType.chacha20Poly1305, 
      
      // Chave de codificação (pode ser alterada livremente; os dados são migrados automaticamente)
      encodingKey: 'Sua-Chave-De-Codificacao-De-32-Bytes...', 
      
      // Chave de criptografia para dados críticos (não alterar arbitrariamente; dados antigos ilegíveis salvo migração)
      encryptionKey: 'Sua-Chave-De-Criptografia-Segura...',
      
      // Vinculação ao dispositivo (Baseada em caminho)
      // Quando habilitado, as chaves são vinculadas ao caminho e às características do dispositivo.
      // Aumenta a segurança contra a cópia de arquivos de banco de dados.
      deviceBinding: false, 
    ),
    // Registro prévio à gravação (WAL) habilitado por padrão
    enableJournal: true, 
    // Forçar o despejo em disco no commit (desativar para maior desempenho)
    persistRecoveryOnCommit: true,
  ),
);
```

### Criptografia em nível de valor (ToCrypto)

A criptografia de toda a base de dados acima criptografa todas as tabelas e índices e pode afetar o desempenho geral. Para criptografar apenas campos sensíveis, use **ToCrypto**: é independente do banco de dados (não requer instância db). Você codifica ou decodifica os valores antes de escrever ou após ler; a chave é gerenciada inteiramente pelo seu app. A saída é Base64, adequada para colunas JSON ou TEXT.

- **key** (obrigatório): `String` ou `Uint8List`. Se não for 32 bytes, uma chave de 32 bytes é derivada via SHA-256.
- **type** (opcional): Tipo de criptografia [ToCryptoType]: [ToCryptoType.chacha20Poly1305] ou [ToCryptoType.aes256Gcm]. Padrão [ToCryptoType.chacha20Poly1305]. Omitir para usar o padrão.
- **aad** (opcional): Dados autenticados adicionais — `Uint8List`. Se passado na codificação, você deve passar os mesmos bytes na decodificação (ex.: nome da tabela + campo para vincular contexto). Omitir para uso simples.

```dart
const key = 'my-secret-key';
// Codificar: texto plano → Base64 cifrado (armazenar em DB ou JSON)
final cipher = ToCrypto.encode('sensitive data', key: key);
// Decodificar ao ler
final plain = ToCrypto.decode(cipher, key: key);

// Opcional: vincular contexto com aad (mesmo aad na codificação e decodificação)
final aad = Uint8List.fromList(utf8.encode('users:id_number'));
final cipher2 = ToCrypto.encode('secret', key: key, aad: aad);
final plain2 = ToCrypto.decode(cipher2, key: key, aad: aad);
```

## Desempenho e Experiência

### Especificações de Desempenho

- **Velocidade de Início**: Início instantâneo e exibição de dados mesmo com mais de 100M de registros em smartphones típicos.
- **Desempenho de Consulta**: Independente da escala, desempenho de busca ultrarrápido constante.
- **Segurança de Dados**: Garantias de transação ACID + recuperação de falhas para zero perda de dados.

### Recomendações

- 📱 **Projeto de Exemplo**: Um exemplo completo de aplicativo Flutter é fornecido no diretório `example`.
- 🚀 **Produção**: Use o modo Release para desempenho superior ao modo Debug.
- ✅ **Testes Padrão**: Todas as funcionalidades principais passaram nos testes de integração.

### Vídeos de demonstração

<p align="center">
  <img src="../media/basic-demo.gif" alt="Demo básica de desempenho do Tostore" width="320" />
  </p>

- **Demo básica de desempenho** (<a href="../media/basic-demo.mp4?raw=1" target="_blank" rel="noopener">basic-demo.mp4</a>): A prévia em GIF pode estar cortada; clique no vídeo para ver a demo completa. Mostra que, mesmo em um smartphone comum com mais de 100 M de registros, o tempo de inicialização do app, a paginação e as consultas permanecem sempre estáveis e fluidas. Desde que haja armazenamento suficiente, dispositivos de borda conseguem lidar com conjuntos de dados em escala de TB/PB mantendo a latência de interação consistentemente baixa.

<p align="center">
  <img src="../media/disaster-recovery.gif" alt="Teste de recuperação de desastres do Tostore" width="320" />
  </p>
  
- **Teste de recuperação de desastres** (<a href="../media/disaster-recovery.mp4?raw=1" target="_blank" rel="noopener">disaster-recovery.mp4</a>): Interrompe deliberadamente o processo durante cargas intensas de gravação para simular travamentos e quedas de energia. Mesmo quando dezenas de milhares de operações de escrita são abruptamente interrompidas, o Tostore consegue se recuperar muito rapidamente em um smartphone típico, sem afetar a próxima inicialização nem a disponibilidade dos dados.




Se o Tostore te ajuda, por favor nos dê uma ⭐️




## Roadmap

O Tostore está desenvolvendo ativamente recursos para aprimorar a infraestrutura de dados na era da IA:

- **Vetores de Alta Dimensão**: Adicionando recuperação de vetores e algoritmos de busca semântica.
- **Dados Multimodais**: Fornecendo processamento de ponta a ponta, de dados brutos a vetores de características.
- **Estruturas de Dados de Grafos**: Suporte para armazenamento e consulta eficiente de grafos de conhecimento e redes relacionais complexas.





> **Recomendação**: Desenvolvedores móveis também podem considerar o [Framework Toway](https://github.com/tocreator/toway), uma solução full-stack que automatiza solicitações de dados, carregamento, armazenamento, cache e exibição.




---

## Recursos Adicionais

- 📖 **Documentação**: [Wiki](https://github.com/tocreator/tostore)
- 📢 **Feedback**: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- 💬 **Discussão**: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)


## Licença

Este projeto está sob a Licença Apache 2.0 - veja o arquivo [LICENSE](LICENSE) para detalhes.

---
