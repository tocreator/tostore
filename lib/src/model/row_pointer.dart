/// row pointer
class RowPointer {
  final int offset; // row offset in file
  final int length; // record length
  final int version; // record version, for update processing
  final String checksum; // record checksum, for integrity verification

  const RowPointer({
    required this.offset,
    required this.length,
    this.version = 1,
    String? checksum,
  }) : checksum = checksum ?? '';

  /// create from string
  factory RowPointer.fromString(String value) {
    final parts = value.split(':');
    return RowPointer(
      offset: int.parse(parts[0]),
      length: int.parse(parts[1]),
      version: parts.length > 2 ? int.parse(parts[2]) : 1,
      checksum: parts.length > 3 ? parts[3] : '',
    );
  }

  /// convert to string
  @override
  String toString() => '$offset:$length:$version:$checksum';

  /// calculate checksum
  static String calculateChecksum(String content) {
    return content.hashCode.toString();
  }

  /// create new row pointer
  static Future<RowPointer> create(
    String content,
    int offset, {
    int version = 1,
  }) async {
    return RowPointer(
      offset: offset,
      length: content.length,
      version: version,
      checksum: calculateChecksum(content),
    );
  }

  /// verify record integrity
  bool verifyContent(String content) {
    return checksum.isEmpty || checksum == calculateChecksum(content);
  }

  /// create new version
  RowPointer newVersion() {
    return RowPointer(
      offset: offset,
      length: length,
      version: version + 1,
      checksum: checksum,
    );
  }
}
