// ============================================================================
// Expression System for Atomic Field Operations
// ============================================================================
//
// This file provides a unified, type-safe expression system for atomic field
// operations. All field updates (single-field and multi-field) use ExprNode
// expressions, ensuring consistency and preventing injection attacks.
//
// Usage examples:
// ```dart
// // Map literal usage (recommended)
// await db.update('orders', {
//   'total': Expr.field('price') * Expr.field('quantity'),
//   'balance': Expr.field('balance') + Expr.value(100),
//   'finalPrice': ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) * (Expr.value(1) - Expr.field('discount')),
//   'updatedAt': Expr.now(),
// });
//
// // Chain builder usage
// await db.update('orders')
//   .increment('balance', 100)  // Syntax sugar, internally uses Expr
//   .set('total', Expr.field('price') * Expr.field('quantity'))
//   .compute('finalPrice', ((Expr.field('price') * Expr.field('quantity')) + Expr.field('tax')) * (Expr.value(1) - Expr.field('discount')))
//   .set('updatedAt', Expr.now())
//   .where('id', '=', orderId)
//   .future;
// ```

/// Base class for all expression nodes in the expression AST.
///
/// This type-safe system prevents injection attacks by disallowing arbitrary
/// string expressions and only allowing structured, validated operations.
///
/// All expressions are evaluated atomically using current field values from
/// the record at update time, preventing race conditions.
abstract class ExprNode {
  const ExprNode();
}

/// Represents a reference to a field in the current record.
///
/// Field names are validated against the table schema at evaluation time
/// to ensure they exist and are accessible.
class FieldRef extends ExprNode {
  /// The name of the field to reference
  final String fieldName;

  const FieldRef(this.fieldName);

  @override
  String toString() => 'FieldRef($fieldName)';
}

/// Represents a constant numeric value in an expression.
class Constant extends ExprNode {
  /// The constant value
  final num value;

  const Constant(this.value);

  @override
  String toString() => 'Constant($value)';
}

/// Represents the current server timestamp.
///
/// This is evaluated at update time to get the current timestamp.
class TimestampExpr extends ExprNode {
  const TimestampExpr();

  @override
  String toString() => 'TimestampExpr()';
}

/// Represents a binary operation (e.g., +, -, *, /, %).
class BinaryOp extends ExprNode {
  /// The left operand
  final ExprNode left;

  /// The operator type
  final BinaryOperator op;

  /// The right operand
  final ExprNode right;

  const BinaryOp(this.left, this.op, this.right);

  @override
  String toString() => 'BinaryOp($left $op $right)';
}

/// Represents a unary operation (e.g., negation, absolute value).
class UnaryOp extends ExprNode {
  /// The operator type
  final UnaryOperator op;

  /// The operand
  final ExprNode operand;

  const UnaryOp(this.op, this.operand);

  @override
  String toString() => 'UnaryOp($op $operand)';
}

/// Represents a function call (e.g., min, max, round, abs).
class FunctionCall extends ExprNode {
  /// The function name
  final String functionName;

  /// The arguments to the function
  final List<ExprNode> arguments;

  const FunctionCall(this.functionName, this.arguments);

  @override
  String toString() => 'FunctionCall($functionName, $arguments)';
}

/// Binary operators supported in expressions.
enum BinaryOperator {
  add, // +
  subtract, // -
  multiply, // *
  divide, // /
  modulo, // %
  min, // min(a, b)
  max, // max(a, b)
}

/// Unary operators supported in expressions.
enum UnaryOperator {
  negate, // -x
  abs, // abs(x)
}

/// Helper class for building expressions in a type-safe, fluent manner.
///
/// This class provides a builder pattern that prevents injection attacks
/// by only allowing structured expression construction.
///
/// All atomic field operations (increment, multiply, etc.) can be expressed
/// using this unified expression system.
///
/// Example usage:
/// ```dart
/// // Simple expression: price * quantity
/// Expr.field('price') * Expr.field('quantity')
///
/// // Increment: balance + 100
/// Expr.field('balance') + Expr.value(100)
///
/// // Multiply: price * 0.9 (10% discount)
/// Expr.field('price') * Expr.value(0.9)
///
/// // Complex expression with parentheses: (price * quantity) + tax - discount
/// (Expr.field('price') * Expr.field('quantity')) + Expr.field('tax') - Expr.field('discount')
///
/// // Multi-level parentheses: ((a + b) * c) / (d - e)
/// ((Expr.field('a') + Expr.field('b')) * Expr.field('c')) / (Expr.field('d') - Expr.field('e'))
///
/// // Nested expressions with functions: min((price * quantity), maxPrice)
/// Expr.min(
///   (Expr.field('price') * Expr.field('quantity')),
///   Expr.field('maxPrice')
/// )
///
/// // Complex calculation: ((base * rate) + tax) * (1 - discount)
/// ((Expr.field('base') * Expr.field('rate')) + Expr.field('tax')) * (Expr.value(1) - Expr.field('discount'))
///
/// // With functions: min(price, maxPrice)
/// Expr.min(Expr.field('price'), Expr.field('maxPrice'))
///
/// // Server timestamp
/// Expr.now()
/// ```
///
/// **Parentheses Support**: The expression system fully supports parentheses for controlling
/// evaluation order. Dart's operator precedence rules apply, and parentheses can be nested
/// to any depth. The expression AST correctly represents the parenthesized structure.
class Expr {
  /// Creates a field reference expression.
  ///
  /// The field name will be validated against the table schema at evaluation time.
  ///
  /// Example:
  /// ```dart
  /// Expr.field('price')  // References the 'price' field
  /// ```
  static FieldRef field(String fieldName) => FieldRef(fieldName);

  /// Creates a constant value expression.
  ///
  /// Example:
  /// ```dart
  /// Expr.value(100)  // Constant value 100
  /// Expr.value(0.9)  // Constant value 0.9
  /// ```
  static Constant value(num value) => Constant(value);

  /// Creates a server timestamp expression.
  ///
  /// This will be evaluated at update time to get the current timestamp.
  ///
  /// Example:
  /// ```dart
  /// Expr.now()  // Current server timestamp
  /// ```
  static TimestampExpr now() => const TimestampExpr();

  /// Creates a min function call: min(a, b)
  ///
  /// Returns the minimum of two values.
  ///
  /// Example:
  /// ```dart
  /// Expr.min(Expr.field('price'), Expr.field('maxPrice'))
  /// ```
  static FunctionCall min(ExprNode a, ExprNode b) =>
      FunctionCall('min', [a, b]);

  /// Creates a max function call: max(a, b)
  ///
  /// Returns the maximum of two values.
  ///
  /// Example:
  /// ```dart
  /// Expr.max(Expr.field('price'), Expr.field('minPrice'))
  /// ```
  static FunctionCall max(ExprNode a, ExprNode b) =>
      FunctionCall('max', [a, b]);

  /// Creates a round function call: round(x)
  ///
  /// Rounds a number to the nearest integer.
  ///
  /// Example:
  /// ```dart
  /// Expr.round(Expr.field('price'))
  /// ```
  static FunctionCall round(ExprNode x) => FunctionCall('round', [x]);

  /// Creates a floor function call: floor(x)
  ///
  /// Rounds a number down to the nearest integer.
  ///
  /// Example:
  /// ```dart
  /// Expr.floor(Expr.field('price'))
  /// ```
  static FunctionCall floor(ExprNode x) => FunctionCall('floor', [x]);

  /// Creates a ceil function call: ceil(x)
  ///
  /// Rounds a number up to the nearest integer.
  ///
  /// Example:
  /// ```dart
  /// Expr.ceil(Expr.field('price'))
  /// ```
  static FunctionCall ceil(ExprNode x) => FunctionCall('ceil', [x]);

  /// Creates an absolute value function call: abs(x)
  ///
  /// Returns the absolute value of a number.
  ///
  /// Example:
  /// ```dart
  /// Expr.abs(Expr.field('balance'))
  /// ```
  static FunctionCall abs(ExprNode x) => FunctionCall('abs', [x]);
}

/// Extension methods on ExprNode to enable operator overloading for fluent expression building.
///
/// These operators allow you to write expressions in a natural, mathematical way.
extension ExprNodeOperators on ExprNode {
  /// Addition operator: this + other
  ///
  /// Example:
  /// ```dart
  /// Expr.field('balance') + Expr.value(100)  // Increment by 100
  /// ```
  BinaryOp operator +(ExprNode other) =>
      BinaryOp(this, BinaryOperator.add, other);

  /// Subtraction operator: this - other
  ///
  /// Example:
  /// ```dart
  /// Expr.field('balance') - Expr.value(50)  // Decrement by 50
  /// ```
  BinaryOp operator -(ExprNode other) =>
      BinaryOp(this, BinaryOperator.subtract, other);

  /// Multiplication operator: this * other
  ///
  /// Example:
  /// ```dart
  /// Expr.field('price') * Expr.value(0.9)  // Multiply by 0.9
  /// ```
  BinaryOp operator *(ExprNode other) =>
      BinaryOp(this, BinaryOperator.multiply, other);

  /// Division operator: this / other
  ///
  /// Example:
  /// ```dart
  /// Expr.field('total') / Expr.value(2)  // Divide by 2
  /// ```
  BinaryOp operator /(ExprNode other) =>
      BinaryOp(this, BinaryOperator.divide, other);

  /// Modulo operator: this % other
  ///
  /// Example:
  /// ```dart
  /// Expr.field('count') % Expr.value(10)  // Modulo 10
  /// ```
  BinaryOp operator %(ExprNode other) =>
      BinaryOp(this, BinaryOperator.modulo, other);

  /// Unary negation operator: -this
  ///
  /// Example:
  /// ```dart
  /// -Expr.field('balance')  // Negate balance
  /// ```
  UnaryOp operator -() => UnaryOp(UnaryOperator.negate, this);
}
