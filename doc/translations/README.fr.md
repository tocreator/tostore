# ToStore

[English](../../README.md) | [简体中文](README.zh-CN.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Deutsch](README.de.md) | Français | [Italiano](README.it.md) | [Türkçe](README.tr.md)

[![pub package](https://img.shields.io/pub/v/tostore.svg)](https://pub.dev/packages/tostore)
[![Build Status](https://github.com/tocreator/tostore/workflows/build/badge.svg)](https://github.com/tocreator/tostore/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Platform](https://img.shields.io/badge/Platform-Flutter-02569B?logo=flutter)](https://flutter.dev)
[![Dart Version](https://img.shields.io/badge/Dart-3.5+-00B4AB.svg?logo=dart)](https://dart.dev)

ToStore est un moteur de stockage haute performance spécialement conçu pour les applications mobiles. Implémenté en Dart pur, il atteint des performances exceptionnelles grâce à l'indexation B+ tree et aux stratégies de cache intelligentes. Son architecture multi-espace résout les défis d'isolation des données utilisateur et de partage des données globales, tandis que des fonctionnalités de niveau entreprise comme la protection des transactions, la réparation automatique, la sauvegarde incrémentielle et le coût nul en inactivité fournissent un stockage de données fiable pour les applications mobiles.

## Pourquoi ToStore ?

- 🚀 **Performance Maximale**: 
  - Indexation B+ tree avec optimisation intelligente des requêtes
  - Stratégie de cache intelligente avec réponse en millisecondes
  - Lecture/écriture concurrente non bloquante avec performance stable
- 🔄 **Évolution Intelligente des Schémas**: 
  - Mise à jour automatique de la structure des tables via les schémas
  - Pas de migrations manuelles version par version
  - API chaînable pour les changements complexes
  - Mises à niveau sans temps d'arrêt
- 🎯 **Facile à Utiliser**: 
  - Design d'API chaînable fluide
  - Support des requêtes style SQL/Map
  - Inférence de type intelligente avec suggestions de code complètes
  - Prêt à l'emploi sans configuration complexe
- 🔄 **Architecture Innovante**: 
  - Isolation des données multi-espace, parfait pour les scénarios multi-utilisateurs
  - Partage de données globales résout les défis de synchronisation
  - Support des transactions imbriquées
  - Chargement d'espace à la demande minimise l'utilisation des ressources
  - Opérations automatiques sur les données (upsert)
- 🛡️ **Fiabilité Niveau Entreprise**: 
  - Protection des transactions ACID garantit la cohérence des données
  - Mécanisme de sauvegarde incrémentielle avec récupération rapide
  - Vérification d'intégrité des données avec réparation automatique

## Démarrage Rapide

Utilisation basique:

```dart
// Initialiser la base de données
final db = ToStore(
  version: 1,
  onCreate: (db) async {
    // Créer une table
    await db.createTable(
      'users',
      TableSchema(
        primaryKey: 'id',
        fields: [
          FieldSchema(name: 'id', type: DataType.integer, nullable: false),
          FieldSchema(name: 'name', type: DataType.text, nullable: false),
          FieldSchema(name: 'age', type: DataType.integer),
          FieldSchema(name: 'tags', type: DataType.array),
        ],
        indexes: [
          IndexSchema(fields: ['name'], unique: true),
        ],
      ),
    );
  },
);
await db.initialize(); // Optionnel, assure que la base de données est entièrement initialisée avant les opérations

// Insérer des données
await db.insert('users', {
  'id': 1,
  'name': 'John',
  'age': 30,
});

// Mettre à jour des données
await db.update('users', {
  'age': 31,
}).where('id', '=', 1);

// Supprimer des données
await db.delete('users').where('id', '!=', 1);

// Requête chaînée avec conditions complexes
final users = await db.query('users')
    .where('age', '>', 20)
    .where('name', 'like', '%John%')
    .or()
    .whereIn('id', [1, 2, 3])
    .orderByDesc('age')
    .limit(10);

// Compter les enregistrements
final count = await db.query('users').count();

// Requête style SQL
final users = await db.queryBySql(
  'users',
  where: 'age > 20 AND name LIKE "%John%" OR id IN (1, 2, 3)',
  limit: 10
);

// Requête style Map
final users = await db.queryByMap(
  'users',
  where: {
    'age': {'>=': 30},
    'name': {'like': '%John%'},
  },
  orderBy: ['age'],
  limit: 10,
);

// Insertion par lot
await db.batchInsert('users', [
  {'id': 1, 'name': 'John', 'age': 30},
  {'id': 2, 'name': 'Mary', 'age': 25},
]);
```

## Architecture Multi-espace

L'architecture multi-espace de ToStore rend la gestion des données multi-utilisateurs simple:

```dart
// Changer vers l'espace utilisateur
await db.switchBaseSpace(spaceName: 'user_123');

// Requête des données utilisateur
final followers = await db.query('followers');

// Définir ou mettre à jour des données clé-valeur, isGlobal: true signifie données globales
await db.setValue('isAgreementPrivacy', true, isGlobal: true);

// Obtenir des données clé-valeur globales
final isAgreementPrivacy = await db.getValue('isAgreementPrivacy', isGlobal: true);
```



### Stockage Automatique des Données

```dart
// Stockage automatique avec condition
await db.upsert('users', {'name': 'John'})
  .where('email', '=', 'john@example.com');

// Stockage automatique avec clé primaire
await db.upsert('users', {
  'id': 1,
  'name': 'John',
  'email': 'john@example.com'
});
``` 


## Performance

Dans les scénarios de haute concurrence incluant les écritures par lot, les lectures/écritures aléatoires et les requêtes conditionnelles, ToStore démontre des performances exceptionnelles, surpassant largement les autres bases de données principales disponibles pour Dart/Flutter.

## Plus de Fonctionnalités

- 💫 API chaînable élégante
- 🎯 Inférence de type intelligente
- 📝 Suggestions de code complètes
- 🔐 Sauvegarde incrémentielle automatique
- 🛡️ Validation d'intégrité des données
- 🔄 Récupération automatique après crash
- 📦 Compression intelligente des données
- 📊 Optimisation automatique des index
- 💾 Stratégie de mise en cache à plusieurs niveaux

Notre objectif n'est pas simplement de créer une autre base de données. ToStore est extrait du framework Toway pour fournir une solution alternative. Si vous développez des applications mobiles, nous recommandons d'utiliser le framework Toway, qui offre un écosystème complet de développement Flutter. Avec Toway, vous n'aurez pas besoin de gérer directement la base de données sous-jacente - les requêtes de données, le chargement, le stockage, la mise en cache et l'affichage sont tous gérés automatiquement par le framework.
Pour plus d'informations sur le framework Toway, visitez le [Dépôt Toway](https://github.com/tocreator/toway)

## Documentation

Visitez notre [Wiki](https://github.com/tocreator/tostore) pour une documentation détaillée.

## Support & Retour

- Soumettre des Issues: [GitHub Issues](https://github.com/tocreator/tostore/issues)
- Rejoindre les Discussions: [GitHub Discussions](https://github.com/tocreator/tostore/discussions)
- Contribuer: [Guide de Contribution](CONTRIBUTING.md)

## Licence

Ce projet est sous licence MIT - voir le fichier [LICENSE](LICENSE) pour plus de détails.

---

<p align="center">Si vous trouvez ToStore utile, donnez-nous une ⭐️</p> 