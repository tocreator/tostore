# ToStore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | Português (Brasil) | [Русский](README.ru.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Türkçe](README.tr.md)

ToStore é um motor de armazenamento de alto desempenho desenvolvido especificamente para aplicações móveis. Implementado puramente em Dart, alcança desempenho excepcional através de indexação B+ tree e estratégias inteligentes de cache. Sua arquitetura multi-espaço resolve os desafios de isolamento de dados do usuário e compartilhamento de dados globais, enquanto recursos de nível empresarial como proteção de transações, reparo automático, backup incremental e custo zero em ociosidade garantem armazenamento de dados confiável para aplicações móveis.

## Por que ToStore?

- 🚀 **Desempenho Máximo**: 
  - Indexação B+ tree com otimização inteligente de consultas
  - Estratégia de cache inteligente com resposta em milissegundos
  - Leitura/escrita concorrente sem bloqueio com desempenho estável
- 🎯 **Fácil de Usar**: 
  - Design de API fluente e encadeável
  - Suporte para consultas estilo SQL/Map
  - Inferência de tipos inteligente com dicas de código completas
  - Sem configuração, pronto para usar
- 🔄 **Arquitetura Inovadora**: 
  - Isolamento de dados multi-espaço, perfeito para cenários multi-usuário
  - Compartilhamento de dados globais resolve desafios de sincronização
  - Suporte para transações aninhadas
  - Carregamento de espaço sob demanda minimiza uso de recursos
- 🛡️ **Confiabilidade Empresarial**: 
  - Proteção de transações ACID garante consistência de dados
  - Mecanismo de backup incremental com recuperação rápida
  - Validação de integridade de dados com reparo automático de erros

## Início Rápido

Uso básico:

```dart
// Inicializar banco de dados
final db = ToStore(
  version: 1,
  onCreate: (db) async {
    // Criar tabela
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
await db.initialize(); // Opcional, garante que o banco de dados esteja inicializado antes das operações

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