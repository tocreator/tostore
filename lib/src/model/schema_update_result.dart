import 'result_status.dart';
import 'migration_write_mode.dart';
import 'result_type.dart';

/// Schema update result model
class SchemaUpdateResult {
  /// Validation statuses of the schema update operation
  final List<ResultStatus> validationStatuses;

  /// Task identifier for the asynchronous migration task, null if validation fails
  final String? taskId;

  /// Estimated duration for the data migration to complete
  final Duration estimateDuration;

  /// Write mode defining which components are rewritten
  final MigrationWriteMode writeMode;

  /// Convenience getter to check if there are any validation errors
  bool get hasValidationErrors =>
      validationStatuses.any((s) => s.type != ResultType.success);

  SchemaUpdateResult({
    required this.validationStatuses,
    this.taskId,
    required this.estimateDuration,
    required this.writeMode,
  });
}
