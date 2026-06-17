/// Database startup/initialization stage
enum DbStartupStage {
  /// Loading configuration and preparing the base engine
  opening,

  /// Performing security checks and recovery (e.g., after an abnormal exit)
  recovering,

  /// Performing structural evolution and optimization (e.g., handling multiple table versions to avoid conflicts)
  optimizing,

  /// Finalizing, ready for use
  ready,
}

/// Callback definition for database startup progress
/// [progress] Overall startup progress (0.0 ~ 1.0)
/// [stage] Current startup stage
typedef StartupProgressCallback = void Function(
    double progress, DbStartupStage stage);
