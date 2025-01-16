# ToStore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | Português (Brasil) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![Build Status](https://github.com/tocreator/tostore/workflows/build/badge.svg)](https://github.com/tocreator/tostore/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

ToStore é um mecanismo de armazenamento de alto desempenho projetado especificamente para aplicativos móveis. Implementado em Dart puro, alcança desempenho excepcional através de indexação B+ tree e estratégias inteligentes de cache. Sua arquitetura multispace resolve os desafios de isolamento de dados do usuário e compartilhamento de dados globais, enquanto recursos de nível empresarial como proteção de transações, reparo automático, backup incremental e zero custo em inatividade fornecem armazenamento de dados confiável para aplicativos móveis.

## Por que ToStore?

- 🚀 **Desempenho Máximo**: 
  - Indexação B+ tree com otimização inteligente de consultas
  - Estratégia de cache inteligente com resposta em milissegundos
  - Leitura/escrita concorrente sem bloqueio com desempenho estável
- 🔄 **Evolução Inteligente de Esquemas**: 
  - Atualização automática de estrutura de tabelas através de esquemas
  - Sem migrações manuais versão por versão
  - API encadeável para mudanças complexas
  - Atualizações sem tempo de inatividade
- 🎯 **Fácil de Usar**: 
  - Design de API encadeável fluido
  - Suporte para consultas estilo SQL/Map
  - Inferência de tipos inteligente com dicas de código completas
  - Pronto para usar sem configuração complexa
- 🔄 **Arquitetura Inovadora**: 
  - Isolamento de dados multispace, perfeito para cenários multiusuário
  - Compartilhamento de dados globais resolve desafios de sincronização
  - Suporte para transações aninhadas
  - Carregamento de espaço sob demanda minimiza uso de recursos
  - Operações automáticas de dados (upsert)
- 🛡️ **Confiabilidade Empresarial**: 
  - Proteção de transações ACID garante consistência de dados
  - Mecanismo de backup incremental com recuperação rápida
  - Verificação de integridade de dados com reparo automático

## Início Rápido

Uso básico:

```dart
// Inicializar banco de dados
final db = ToStore(
  version: 2, // cada vez que o número da versão é incrementado, a estrutura da tabela em schemas será automaticamente criada ou atualizada
  schemas: [
    // Simplesmente defina seu esquema mais recente, ToStore lida com a atualização automaticamente
    const TableSchema(
      name: 'users',
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
  ],
  // atualizações e migrações complexas podem ser feitas usando db.updateSchema
  // se o número de tabelas for pequeno, recomenda-se ajustar diretamente a estrutura em schemas para atualização automática
  onUpgrade: (db, oldVersion, newVersion) async {
    if (oldVersion == 1) {
      await db.updateSchema('users')
          .addField("fans", type: DataType.array, comment: "seguidores")
          .addIndex("follow", fields: ["follow", "name"])
          .dropField("last_login")
          .modifyField('email', unique: true)
          .renameField("last_login", "last_login_time");
    }
  },
);
await db.initialize(); // Opcional, garante que o banco de dados esteja completamente inicializado antes das operações

// Inserir dados
await db.insert('users', {
  'id': 1,
  'name': 'John',
  'age': 30,
});

// Atualizar dados
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// Excluir dados
await db.delete('users').where('id', '!=', 1);

// Consulta encadeada com condições complexas
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// Contar registros
final count = await db.query('users').count();

// Consulta estilo SQL
final users = await db.queryBySql(
  'users',
  where: 'age > 20 AND name LIKE "%John%" OR id IN (1, 2, 3)',
  limit: 10
);

// Consulta estilo Map
final users = await db.queryByMap(
  'users',
  where: {
    'age': {'>=': 30},
    'name': {'like': '%John%'},
  },
  orderBy: ['age'],
  limit: 10,
);

// Inserção em lote
await db.batchInsert('users', [
  {'id': 1, 'name': 'John', 'age': 30},
  {'id': 2, 'name': 'Mary', 'age': 25},
]);
```

## Arquitetura Multi-espaço

A arquitetura multi-espaço do ToStore torna o gerenciamento de dados multi-usuário simples:

```dart
// Mudar para espaço do usuário
await db.switchBaseSpace(spaceName: 'user_123');

// Consultar dados do usuário
final followers = await db.query('followers');

// Definir ou atualizar dados chave-valor, isGlobal: true significa dados globais
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// Obter dados chave-valor globais
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```

### Armazenar Dados Automáticos

```dart
// Armazenar automaticamente dados com condições, lote de suporte
await db.upsert('users', {'name': 'John'})
  .where('email', '=', 'john@example.com');

// Armazenar automaticamente os dados com a chave primária
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});
```

## Desempenho

Em cenários de alta concorrência incluindo escritas em lote, leituras/escritas aleatórias e consultas condicionais, ToStore demonstra desempenho excepcional, superando amplamente outros bancos de dados principais disponíveis para Dart/Flutter.

## Mais Recursos

- 💫 API encadeável elegante
- 🎯 Inferência de tipos inteligente
- 📝 Dicas de código completas
- 🔐 Backup incremental automático
- 🛡️ Validação de integridade de dados
- 🔄 Recuperação automática de falhas
- 📦 Compressão inteligente de dados
- 📊 Otimização automática de índices
- 💾 Estratégia de cache em camadas

Nosso objetivo não é apenas criar outro banco de dados. ToStore é extraído do framework Toway para fornecer uma solução alternativa. Se você está desenvolvendo aplicações móveis, recomendamos usar o framework Toway, que oferece um ecossistema completo de desenvolvimento Flutter. Com Toway, você não precisará lidar diretamente com o banco de dados subjacente - requisições de dados, carregamento, armazenamento, cache e exibição são todos tratados automaticamente pelo framework.
Para mais informações sobre o framework Toway, visite o [Repositório Toway](https://github.com/tocreator/toway)

## Documentação

Visite nossa [Wiki](https://github.com/tocreator/tostore) para documentação detalhada.

## Suporte e Feedback

- Enviar Issues: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- Participar das Discussões: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- Contribuir: [Guia de Contribuição](CONTRIBUTING.md)

## Licença

Este projeto está licenciado sob a Licença MIT - veja o arquivo [LICENSE](LICENSE) para detalhes.

---

<p align="center">Se você acha o ToStore útil, por favor nos dê uma ⭐️</p> 