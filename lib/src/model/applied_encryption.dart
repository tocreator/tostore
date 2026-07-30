/// Plain encodingKey material stored inside GlobalConfig (protected by encryptionKey shell).
class EncryptionKeyInfo {
  /// Plaintext encodingKey (not wrapped). Empty when encryption is inactive.
  final String key;

  /// Monotonic key identifier used in on-disk ciphertext headers.
  final int keyId;

  /// When this key finished full EncodingDomain migration (incl. natural turnover).
  ///
  /// Used to compute the history purge watermark. Keys without completedAt may
  /// still be purged once a *later* keyId has completedAt past retention.
  final DateTime? migrationCompletedAt;

  const EncryptionKeyInfo({
    required this.key,
    required this.keyId,
    this.migrationCompletedAt,
  });

  factory EncryptionKeyInfo.fromJson(Map<String, dynamic> json) {
    DateTime? completed;
    final raw = json['migrationCompletedAt'];
    if (raw is String && raw.isNotEmpty) {
      completed = DateTime.tryParse(raw);
    } else if (raw is int) {
      completed = DateTime.fromMillisecondsSinceEpoch(raw, isUtc: true);
    }
    return EncryptionKeyInfo(
      key: json['key'] as String? ?? '',
      keyId: json['keyId'] as int? ?? 0,
      migrationCompletedAt: completed,
    );
  }

  EncryptionKeyInfo copyWith({
    String? key,
    int? keyId,
    DateTime? migrationCompletedAt,
    bool clearMigrationCompletedAt = false,
  }) {
    return EncryptionKeyInfo(
      key: key ?? this.key,
      keyId: keyId ?? this.keyId,
      migrationCompletedAt: clearMigrationCompletedAt
          ? null
          : (migrationCompletedAt ?? this.migrationCompletedAt),
    );
  }
}

/// Database-wide applied encoding keyring (lives in [GlobalConfig]).
class AppliedEncryption {
  final EncryptionKeyInfo current;
  final List<EncryptionKeyInfo> historyKeys;

  AppliedEncryption({
    required this.current,
    List<EncryptionKeyInfo>? historyKeys,
  }) : historyKeys = List<EncryptionKeyInfo>.unmodifiable(
          historyKeys ?? const <EncryptionKeyInfo>[],
        );

  factory AppliedEncryption.empty() => AppliedEncryption(
        current: const EncryptionKeyInfo(key: '', keyId: 0),
      );

  AppliedEncryption copyWith({
    EncryptionKeyInfo? current,
    List<EncryptionKeyInfo>? historyKeys,
  }) {
    return AppliedEncryption(
      current: current ?? this.current,
      historyKeys: historyKeys ?? this.historyKeys,
    );
  }

  /// current first, then history (non-empty keys only).
  List<EncryptionKeyInfo> getAllKeys() {
    return [
      current,
      ...historyKeys,
    ]..removeWhere((key) => key.key.isEmpty);
  }

  EncryptionKeyInfo? getKeyById(int keyId) {
    if (current.keyId == keyId) return current;
    for (final key in historyKeys) {
      if (key.keyId == keyId) return key;
    }
    return null;
  }

  /// History keys eligible for purge under the watermark rule.
  ///
  /// Watermark = max keyId among keys (current + history) whose
  /// [EncryptionKeyInfo.migrationCompletedAt] is at least [retention] ago.
  /// Once a later key fully completed that long ago, every history entry with
  /// `keyId ≤ watermark` (except [current]) is purged — including entries that
  /// never received their own `migrationCompletedAt` — because a completed
  /// migration rewrote all ciphertext past those older keyIds.
  static const Duration historyRetention = Duration(days: 30);

  List<EncryptionKeyInfo> keysEligibleForPurge({
    DateTime? now,
    Duration retention = historyRetention,
  }) {
    final at = now ?? DateTime.now().toUtc();
    var watermark = -1;
    for (final k in getAllKeys()) {
      final completed = k.migrationCompletedAt;
      if (completed == null) continue;
      if (at.difference(completed.toUtc()) < retention) continue;
      if (k.keyId > watermark) watermark = k.keyId;
    }
    if (watermark < 0) return const [];

    return historyKeys
        .where((k) => k.keyId <= watermark && k.keyId != current.keyId)
        .toList();
  }

  /// Drop purged history keys; keep current and ineligible history.
  AppliedEncryption purgeEligibleHistory({
    DateTime? now,
    Duration retention = historyRetention,
  }) {
    final purgeIds = keysEligibleForPurge(now: now, retention: retention)
        .map((k) => k.keyId)
        .toSet();
    if (purgeIds.isEmpty) return this;
    return copyWith(
      historyKeys:
          historyKeys.where((k) => !purgeIds.contains(k.keyId)).toList(),
    );
  }
}
