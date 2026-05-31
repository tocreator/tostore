/// Write mode for background operations defining target storage components.
enum BackgroundWriteMode {
  /// Only write index data.
  indexOnly,

  /// Only write table raw data.
  tableOnly,

  /// Write both table raw data and index data.
  tableAndIndex,
}
