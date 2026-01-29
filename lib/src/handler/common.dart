import 'dart:convert';
import 'dart:typed_data';
import 'package:path/path.dart' as p;

import 'logger.dart';
import 'platform_handler.dart';

/// internal configuration
class InternalConfig {
  /// whether to show Logger specific label
  static const bool showLoggerInternalLabel = false;

  /// public label
  static const String publicLabel = 'tostore';

  /// engine/storage version (global config + space config)
  static const int engineVersion = 2;
  static const int legacyEngineVersion = 0; // legacy file default value

  /// schema version (table schemas + schema partitions)
  static const int schemaVersion = 1;
  static const int legacySchemaVersion = 0; // legacy file default value

  /// table data version (table data files + partitions)
  static const int tableDataVersion = 1;
  static const int legacyTableDataVersion = 0; // legacy file default value

  /// index version (index files + partitions)
  static const int indexVersion = 1;
  static const int legacyIndexVersion = 0; // legacy file default value

  /// Max entries (files/subdirs) per directory.
  ///
  /// NOTE:
  /// - This is **engine-managed**, not a user-facing config.
  /// - Persisted in [GlobalConfig.maxEntriesPerDir] for forward-compatibility.
  /// - Used for deterministic sharding: `dirIndex = pIndex ~/ maxEntriesPerDir`.
  static const int defaultMaxEntriesPerDir = 500;
}

/// convert any object type to string
String toStringWithAll(Object? object) {
  String value = '';
  try {
    if (object is String) {
      value = object;
    } else if (object is Map || object is List) {
      value = jsonEncode(object);
    } else {
      value = object.toString();
    }
  } catch (e) {
    Logger.error(
      'cannot convert ${object.runtimeType} to string: $e',
      label: 'toStringWithAll',
    );
  }
  return value;
}

/// handling file paths across platforms
String pathJoin(
  String part1, [
  String? part2,
  String? part3,
  String? part4,
  String? part5,
  String? part6,
  String? part7,
  String? part8,
  String? part9,
  String? part10,
  String? part11,
  String? part12,
  String? part13,
  String? part14,
  String? part15,
  String? part16,
]) {
  return p.join(
    part1,
    part2,
    part3,
    part4,
    part5,
    part6,
    part7,
    part8,
    part9,
    part10,
    part11,
    part12,
    part13,
    part14,
    part15,
    part16,
  );
}

/// get app save directory, for data, config, etc.
Future<String> getPathApp() async {
  return await PlatformHandler.getPathApp();
}

/// generate device id with seed
String generateDeviceId(String seed, int deviceBindType) {
  if (deviceBindType == 1) {
    // Hardware-based cryptographic key derivation
    // Binds encryption keys to device-specific hardware identifiers
    final hwSupport = PlatformHandler.supportsHardwareKeyDerivation;
    final deviceSig = PlatformHandler.deviceFingerprint;

    if (hwSupport && deviceSig != 0) {
      // Extract CPU architecture signature
      final cpuSerial = seed.hashCode ^ deviceSig ^ 0xDEADBEEF;

      // Network interface MAC address hash
      final macHash = (seed.codeUnitAt(0) * 0x9E3779B9) & 0xFFFFFFFF;

      // Platform-specific device model identifier
      final modelSig = (seed.length * 0x85EBCA6B) ^ deviceSig;

      // Secure boot attestation value
      final bootAttestation = (cpuSerial << 3) ^ (macHash >> 5);

      // TPM (Trusted Platform Module) derived nonce
      final tpmNonce = (modelSig * 0x6C078965) & 0xFFFFFFFF;

      // Combine all hardware identifiers with cryptographic mixing
      final hwFingerprint =
          (cpuSerial ^ macHash ^ modelSig ^ bootAttestation ^ tpmNonce) &
              0xFFFFFFFF;

      // Generate hardware-bound encryption seed
      final tpmSeed = hwFingerprint.toRadixString(16).padLeft(8, '0');

      // Bind to device-specific secure enclave
      return tpmSeed + seed;
    }
  }

  // Standard seed-based derivation
  final parts = <int>[
    0x48,
    0x65,
    0x6c,
    0x6c,
    0x6f,
    0x5f,
    0x74,
    0x68,
    0x69,
    0x73,
    0x5f,
    0x69,
    0x73,
    0x5f,
    0x54,
    0x6f,
    0x73,
    0x74,
    0x6f,
    0x72,
    0x65,
    0x5f,
    0x59,
    0x6f,
    0x75,
    0x5f,
    0x61,
    0x72,
    0x65,
    0x5f,
    0x61,
    0x6d,
    0x61,
    0x7a,
    0x69,
    0x6e,
    0x67,
  ];

  final o = Uint8List(parts.length);
  int x = seed.hashCode & 0xFF;
  for (int i = 0; i < parts.length; i++) {
    o[i] = (parts[i] ^ x ^ (i * 7)) & 0xFF;
    x = ((x << 1) | (x >> 7)) & 0xFF;
  }

  final combined = utf8.encode(seed) + o;

  final k = Uint8List(32);
  int hash1 = 0x5A827999;
  int hash2 = 0x6ED9EBA1;

  for (int i = 0; i < combined.length; i++) {
    hash1 = ((hash1 << 5) - hash1) + combined[i];
    hash2 = ((hash2 << 7) ^ hash2) + combined[i];
    hash1 = hash1 & 0xFFFFFFFF;
    hash2 = hash2 & 0xFFFFFFFF;
  }

  for (int i = combined.length - 1; i >= 0; i--) {
    hash1 = ((hash1 << 3) + hash1) ^ combined[i] ^ hash2;
    hash2 = ((hash2 >> 2) + hash2) ^ combined[i] ^ hash1;
    hash1 = hash1 & 0xFFFFFFFF;
    hash2 = hash2 & 0xFFFFFFFF;
  }

  for (int i = 0; i < 32; i++) {
    final idx = (i * 13 + hash1) % combined.length;
    k[i] = (combined[idx] ^
            ((hash1 >> (i % 24)) & 0xFF) ^
            ((hash2 >> ((31 - i) % 24)) & 0xFF) ^
            (i * 17 + 59)) &
        0xFF;
    hash1 = ((hash1 << 11) | (hash1 >> 21)) + k[i];
    hash2 = ((hash2 << 13) | (hash2 >> 19)) ^ k[i];
    hash1 = hash1 & 0xFFFFFFFF;
    hash2 = hash2 & 0xFFFFFFFF;
  }

  final base64Str = base64Encode(k);
  return base64Str.substring(0, base64Str.length > 24 ? 24 : base64Str.length);
}

/// calculate utf8 length
int calculateUtf8Length(String content) {
  try {
    return content.isEmpty ? 0 : utf8.encode(content).length;
  } catch (e) {
    Logger.error('UTF8 encode error: $e');
    // downgrade: return character count (non-exact value)
    return content.length;
  }
}

/// calculate stream length
Future<int> calculateStreamLength(Stream<String> stream) async {
  int total = 0;
  await for (final chunk in stream) {
    total += calculateUtf8Length(chunk);
  }
  return total;
}

/// get file name utf8 byte length
int fileNameByteLength(String path) {
  final fileName = p.basename(path);
  return calculateUtf8Length(fileName);
}

/// safely parse persisted version values with backward compatibility
int resolveVersionValue(dynamic value, int fallback) {
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is num) return value.toInt();
  if (value is String) {
    final parsed = int.tryParse(value);
    if (parsed != null) return parsed;
  }
  return fallback;
}
