# Tostore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | Português (Brasil) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![Build Status](https://github.com/tocreator/tostore/workflows/build/badge.svg)](https://github.com/tocreator/tostore/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

Tostore é um mecanismo de banco de dados de arquitetura distribuída multiplataforma profundamente integrado ao seu projeto. Seu modelo de processamento de dados inspirado em redes neurais implementa gerenciamento de dados semelhante ao cérebro. Mecanismos de paralelismo de múltiplas partições e topologia de interconexão de nós criam uma rede de dados inteligente, enquanto o processamento paralelo com Isolate aproveita ao máximo as capacidades multicore. Com vários algoritmos de chave primária distribuídos e extensão ilimitada de nós, pode servir como uma camada de dados para infraestruturas de computação distribuída e treinamento de dados em larga escala, permitindo fluxo de dados contínuo de dispositivos de borda a servidores na nuvem. Recursos como detecção precisa de alterações de esquema, migração inteligente, criptografia ChaCha20Poly1305 e arquitetura multiespaco suportam perfeitamente vários cenários de aplicação, desde aplicativos móveis até sistemas do lado do servidor.

## Por que escolher Tostore?

### 1. Processamento Paralelo de Partições vs. Armazenamento em Arquivo Único
| Tostore | Bancos de Dados Tradicionais |
|:---------|:-----------|
| ✅ Mecanismo inteligente de particionamento, dados distribuídos em múltiplos arquivos de tamanho apropriado | ❌ Armazenamento em um único arquivo de dados, degradação linear de desempenho com o crescimento dos dados |
| ✅ Lê apenas os arquivos de partição relevantes, desempenho de consulta desacoplado do volume total de dados | ❌ Necessidade de carregar todo o arquivo de dados, mesmo para consultar um único registro |
| ✅ Mantém tempos de resposta em milissegundos mesmo com volumes de dados em nível de TB | ❌ Aumento significativo na latência de leitura/escrita em dispositivos móveis quando os dados excedem 5MB |
| ✅ Consumo de recursos proporcional à quantidade de dados consultados, não ao volume total de dados | ❌ Dispositivos com recursos limitados sujeitos a pressão de memória e erros OOM |
| ✅ Tecnologia Isolate permite verdadeiro processamento paralelo multicore | ❌ Um único arquivo não pode ser processado em paralelo, desperdício de recursos de CPU |

### 2. Integração Incorporada vs. Armazenamentos de Dados Independentes
| Tostore | Bancos de Dados Tradicionais |
|:---------|:-----------|
| ✅ Usa linguagem Dart, integra-se perfeitamente com projetos Flutter/Dart | ❌ Requer aprendizado de SQL ou linguagens de consulta específicas, aumentando a curva de aprendizado |
| ✅ O mesmo código suporta frontend e backend, sem necessidade de mudar a stack tecnológica | ❌ Frontend e backend geralmente requerem diferentes bancos de dados e métodos de acesso |
| ✅ Estilo de API encadeada correspondendo a estilos de programação modernos, excelente experiência para desenvolvedores | ❌ Concatenação de strings SQL vulnerável a ataques e erros, falta de segurança de tipos |
| ✅ Suporte para programação reativa, combina naturalmente com frameworks de UI | ❌ Requer camadas de adaptação adicionais para conectar UI e camada de dados |
| ✅ Não há necessidade de configuração complexa de mapeamento ORM, uso direto de objetos Dart | ❌ Complexidade do mapeamento objeto-relacional, altos custos de desenvolvimento e manutenção |

### 3. Detecção Precisa de Alterações de Esquema vs. Gerenciamento Manual de Migração
| Tostore | Bancos de Dados Tradicionais |
|:---------|:-----------|
| ✅ Detecta automaticamente alterações de esquema, sem necessidade de gerenciamento de número de versão | ❌ Dependência de controle manual de versão e código de migração explícito |
| ✅ Detecção em nível de milissegundos de alterações de tabela/campo e migração automática de dados | ❌ Necessidade de manter lógica de migração para atualizações entre versões |
| ✅ Identifica com precisão renomeações de tabela/campo, preserva todos os dados históricos | ❌ Renomeações de tabela/campo podem levar à perda de dados |
| ✅ Operações de migração atômicas garantindo consistência de dados | ❌ Interrupções de migração podem causar inconsistências de dados |
| ✅ Atualizações de esquema totalmente automatizadas sem intervenção manual | ❌ Lógica de atualização complexa e altos custos de manutenção com o aumento das versões |

### 4. Arquitetura Multi-Espaço vs. Espaço de Armazenamento Único
| Tostore | Bancos de Dados Tradicionais |
|:---------|:-----------|
| ✅ Arquitetura multi-espaço, isolando perfeitamente dados de diferentes usuários | ❌ Espaço de armazenamento único, armazenamento misto de dados de múltiplos usuários |
| ✅ Alternância de espaço com uma linha de código, simples e eficaz | ❌ Requer múltiplas instâncias de banco de dados ou lógica de isolamento complexa |
| ✅ Mecanismo flexível de isolamento de espaço e compartilhamento de dados global | ❌ Difícil equilibrar isolamento e compartilhamento de dados do usuário |
| ✅ API simples para copiar ou migrar dados entre espaços | ❌ Operações complexas para migração de inquilinos ou cópia de dados |
| ✅ Consultas automaticamente limitadas ao espaço atual, sem necessidade de filtragem adicional | ❌ Consultas para diferentes usuários requerem filtragem complexa |





## Destaques Técnicos

- 🌐 **Suporte Multiplataforma Transparente**:
  - Experiência consistente em plataformas Web, Linux, Windows, Mobile, Mac
  - Interface de API unificada, sincronização de dados multiplataforma sem complicações
  - Adaptação automática a vários backends de armazenamento multiplataforma (IndexedDB, sistemas de arquivos, etc.)
  - Fluxo de dados contínuo da computação de borda à nuvem

- 🧠 **Arquitetura Distribuída Inspirada em Redes Neurais**:
  - Topologia semelhante a redes neurais de nós interconectados
  - Mecanismo eficiente de particionamento de dados para processamento distribuído
  - Balanceamento inteligente de carga de trabalho dinâmico
  - Suporte para extensão ilimitada de nós, fácil construção de redes de dados complexas

- ⚡ **Capacidades Definitivas de Processamento Paralelo**:
  - Leitura/escrita verdadeiramente paralela com Isolates, utilização completa de CPU multicore
  - Rede de computação multi-nó cooperando para eficiência multiplicada de múltiplas tarefas
  - Framework de processamento distribuído com consciência de recursos, otimização automática de desempenho
  - Interface de consulta em streaming otimizada para processar conjuntos de dados massivos

- 🔑 **Vários Algoritmos de Chave Primária Distribuídos**:
  - Algoritmo de incremento sequencial - comprimento de passo aleatório livremente ajustável
  - Algoritmo baseado em carimbo de data/hora - ideal para cenários de execução paralela de alto desempenho
  - Algoritmo com prefixo de data - adequado para dados com indicação de intervalo de tempo
  - Algoritmo de código curto - identificadores únicos concisos

- 🔄 **Migração de Esquema Inteligente**:
  - Identificação precisa de comportamentos de renomeação de tabela/campo
  - Atualização automática de dados e migração durante alterações de esquema
  - Atualizações sem tempo de inatividade, sem impacto nas operações de negócios
  - Estratégias de migração seguras prevenindo perda de dados

- 🛡️ **Segurança de Nível Empresarial**:
  - Algoritmo de criptografia ChaCha20Poly1305 para proteger dados sensíveis
  - Criptografia de ponta a ponta, garantindo segurança de dados armazenados e transmitidos
  - Controle de acesso a dados de granularidade fina

- 🚀 **Cache Inteligente e Desempenho de Busca**:
  - Mecanismo de cache inteligente multinível para recuperação eficiente de dados
  - Cache de inicialização melhorando drasticamente a velocidade de lançamento de aplicativos
  - Motor de armazenamento profundamente integrado com cache, sem código de sincronização adicional necessário
  - Escalonamento adaptativo, mantendo desempenho estável mesmo com dados crescentes

- 🔄 **Fluxos de Trabalho Inovadores**:
  - Isolamento de dados multi-espaço, suporte perfeito para cenários multi-inquilino, multi-usuário
  - Atribuição inteligente de carga de trabalho entre nós de computação
  - Fornece banco de dados robusto para treinamento e análise de dados em larga escala
  - Armazenamento automático de dados, atualizações e inserções inteligentes

- 💼 **Experiência do Desenvolvedor é Prioridade**:
  - Documentação bilíngue detalhada e comentários de código (Chinês e Inglês)
  - Informações ricas de depuração e métricas de desempenho
  - Capacidades integradas de validação de dados e recuperação de corrupção
  - Configuração zero pronta para uso, início rápido

## Início Rápido

Uso básico:

```dart
// Inicialização do banco de dados
final db = ToStore();
await db.initialize(); // Opcional, garante que a inicialização do banco de dados seja concluída antes das operações

// Inserção de dados
await db.insert('users', {
  'username': 'John',
  'email': 'john@example.com',
});

// Atualização de dados
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// Exclusão de dados
await db.delete('users').where('id', '!=', 1);

// Suporte para consultas encadeadas complexas
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// Armazenamento automático de dados, atualiza se existir, insere se não
await db.upsert('users', {'name': 'John','email': 'john@example.com'})
  .where('email', '=', 'john@example.com');
// Ou
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});

// Contagem eficiente de registros
final count = await db.query('users').count();

// Processamento de dados massivos usando consultas em streaming
db.streamQuery('users')
  .where('email', 'like', '%@example.com')
  .listen((userData) {
    // Processa cada registro conforme necessário, evitando pressão de memória
    print('Processando usuário: ${userData['username']}');
  });

// Definir pares chave-valor globais
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// Obter dados de pares chave-valor globais
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```

## Exemplo de Aplicativo Móvel

```dart
// Definição de estrutura de tabela adequada para cenários de inicialização frequente como aplicativos móveis, detecção precisa de alterações na estrutura da tabela, atualização automática de dados e migração
final db = ToStore(
  schemas: [
    const TableSchema(
      name: 'users', // Nome da tabela
      tableId: "users",  // Identificador único de tabela, opcional, usado para identificação 100% de requisitos de renomeação, mesmo sem pode alcançar taxa de precisão >98%
      primaryKeyConfig: PrimaryKeyConfig(
        name: 'id', // Chave primária
      ),
      fields: [ // Definição de campo, não inclui chave primária
        FieldSchema(name: 'username', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'email', type: DataType.text, nullable: false, unique: true),
        FieldSchema(name: 'last_login', type: DataType.datetime),
      ],
      indexes: [ // Definição de índice
        IndexSchema(fields: ['username']),
        IndexSchema(fields: ['email']),
      ],
    ),
  ],
);

// Mudar para espaço do usuário - isolamento de dados
await db.switchSpace(spaceName: 'user_123');
```

## Exemplo de Servidor Backend

```dart
await db.createTables([
      const TableSchema(
        name: 'users', // Nome da tabela
        primaryKeyConfig: PrimaryKeyConfig(
          name: 'id', // Chave primária
          type: PrimaryKeyType.timestampBased,  // Tipo de chave primária
        ),
        fields: [
          // Definição de campo, não inclui chave primária
          FieldSchema(
              name: 'username',
              type: DataType.text,
              nullable: false,
              unique: true),
          FieldSchema(name: 'vector_data', type: DataType.blob),  // Armazenamento de dados vetoriais
          // Outros campos...
        ],
        indexes: [
          // Definição de índice
          IndexSchema(fields: ['username']),
          IndexSchema(fields: ['email']),
        ],
      ),
      // Outras tabelas...
]);


// Atualização de estrutura de tabela
final taskId = await db.updateSchema('users')
    .renameTable('newTableName')  // Renomear tabela
    .modifyField('username',minLength: 5,maxLength: 20,unique: true)  // Modificar propriedades de campo
    .renameField('oldName', 'newName')  // Renomear campo
    .removeField('fieldName')  // Remover campo
    .addField('name', type: DataType.text)  // Adicionar campo
    .removeIndex(fields: ['age'])  // Remover índice
    .setPrimaryKeyConfig(  // Definir configuração de chave primária
      const PrimaryKeyConfig(type: PrimaryKeyType.shortCode)
    );
    
// Consultar status da tarefa de migração
final status = await db.queryMigrationTaskStatus(taskId);  
print('Progresso da migração: ${status?.progressPercentage}%');
```


## Arquitetura Distribuída

```dart
// Configuração de nó distribuído
final db = ToStore(
    config: DataStoreConfig(
        distributedNodeConfig: const DistributedNodeConfig(
            enableDistributed: true,  // Habilitar modo distribuído
            clusterId: 1,  // Configuração de associação ao cluster
            centralServerUrl: 'http://127.0.0.1:8080',
            accessToken: 'b7628a4f9b4d269b98649129'))
);

// Inserção em lote de dados vetoriais
await db.batchInsert('vector', [
  {'vector_name': 'face_2365', 'timestamp': DateTime.now()},
  {'vector_name': 'face_2366', 'timestamp': DateTime.now()},
  // ... Milhares de registros
]);

// Processamento em streaming de grandes conjuntos de dados para análise
await for (final record in db.streamQuery('vector')
    .where('vector_name', '=', 'face_2366')
    .where('timestamp', '>=', DateTime.now().subtract(Duration(days: 30)))
    .stream) {
  // Interface de streaming suporta extração e transformação de características em larga escala
  print(record);
}
```

## Exemplos de Chave Primária
Vários algoritmos de chave primária, todos suportando geração distribuída, não recomendado gerar chaves primárias você mesmo para evitar o impacto de chaves primárias desordenadas nas capacidades de busca.
Chave primária sequencial PrimaryKeyType.sequential: 238978991
Chave primária baseada em carimbo de data/hora PrimaryKeyType.timestampBased: 1306866018836946
Chave primária com prefixo de data PrimaryKeyType.datePrefixed: 20250530182215887631
Chave primária de código curto PrimaryKeyType.shortCode: 9eXrF0qeXZ

```dart
// Chave primária sequencial PrimaryKeyType.sequential
// Quando o sistema distribuído está habilitado, o servidor central aloca intervalos que os nós geram eles mesmos, compacto e fácil de lembrar, adequado para IDs de usuário e números atrativos
await db.createTables([
      const TableSchema(
        name: 'users',
        primaryKeyConfig: PrimaryKeyConfig(
          type: PrimaryKeyType.sequential,  // Tipo de chave primária sequencial
          sequentialConfig:  SequentialIdConfig(
              initialValue: 10000, // Valor inicial de auto-incremento
              increment: 50,  // Passo de incremento
              useRandomIncrement: true,  // Usar passo aleatório para evitar revelar volume de negócios
            ),
        ),
        // Definição de campo e índice...
        fields: []
      ),
      // Outras tabelas...
 ]);
```


## Configuração de Segurança

```dart
// Renomeação de tabela e campo - reconhecimento automático e preservação de dados
final db = ToStore(
      config: DataStoreConfig(
        enableEncoding: true, // Habilitar codificação segura para dados de tabela
        encodingKey: 'YouEncodingKey', // Chave de codificação, pode ser ajustada arbitrariamente
        encryptionKey: 'YouEncryptionKey', // Chave de criptografia, nota: alterar isso impedirá a decodificação de dados antigos
      ),
    );
```

## Testes de Desempenho

Tostore 2.0 implementa escalabilidade de desempenho linear, mudanças fundamentais no processamento paralelo, mecanismos de particionamento e arquitetura distribuída melhoraram significativamente as capacidades de busca de dados, fornecendo tempos de resposta em milissegundos mesmo com crescimento massivo de dados. Para processar grandes conjuntos de dados, a interface de consulta em streaming pode processar volumes massivos de dados sem esgotar recursos de memória.



## Planos Futuros
Tostore está desenvolvendo suporte para vetores de alta dimensão para se adaptar ao processamento de dados multimodais e busca semântica.


Nosso objetivo não é criar um banco de dados; Tostore é simplesmente um componente extraído do framework Toway para sua consideração. Se você está desenvolvendo aplicativos móveis, recomendamos usar o framework Toway com seu ecossistema integrado, que cobre a solução full-stack para desenvolvimento de aplicativos Flutter. Com Toway, você não precisará tocar no banco de dados subjacente, todas as operações de consulta, carregamento, armazenamento, cache e exibição de dados serão realizadas automaticamente pelo framework.
Para mais informações sobre o framework Toway, visite o [repositório Toway](https://github.com/tocreator/toway).

## Documentação

Visite nossa [Wiki](https://github.com/tocreator/tostore) para documentação detalhada.

## Suporte e Feedback

- Envie problemas: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- Participe da discussão: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- Contribua com código: [Guia de Contribuição](CONTRIBUTING.md)

## Licença

Este projeto está licenciado sob a Licença MIT - veja o arquivo [LICENSE](LICENSE) para detalhes.

---

<p align="center">Se você acha o Tostore útil, por favor nos dê uma ⭐️</p>
