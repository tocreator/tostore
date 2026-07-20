/// Join types supported in the query
enum JoinType {
  /// Inner join - only returns records that have matches in both tables
  inner,

  /// Left join - returns all records from the left table, and matched records from the right table
  left,

  /// Right join - returns all records from the right table, and matched records from the left table
  right
}

/// Represents a join clause in a query
class JoinClause {
  /// Type of join (inner, left, right)
  final JoinType type;

  /// The table to join with
  final String table;

  /// The key from the first table
  final String firstKey;

  /// The operator to use for comparison (`=`, `<`, `>`, etc.)
  final String operator;

  /// The key from the second table
  final String secondKey;

  /// Create a new join clause
  JoinClause({
    required this.type,
    required this.table,
    required this.firstKey,
    required this.operator,
    required this.secondKey,
  });

  /// Convert to a string representation for debugging
  @override
  String toString() {
    final joinTypeStr = type.toString().split('.').last.toUpperCase();
    return '$joinTypeStr JOIN $table ON $firstKey $operator $secondKey';
  }
}

/// Internal class to store pending foreign key join requests
class PendingForeignKeyJoin {
  final String tableName;
  final JoinType type;

  PendingForeignKeyJoin({
    required this.tableName,
    required this.type,
  });
}
