import '../models/bridge_key.dart';

typedef NextKeyGetter = BridgeApiKey? Function();
typedef KeySuccessReporter = void Function(BridgeApiKey key);
typedef KeyFailureReporter = void Function(
  BridgeApiKey key,
  int statusCode,
  String featureTag,
  String userId,
);

/// Connects `SmartOcrAiBridge` to `ApiKeyManager.instance` from
/// `package:admin_api_key_manager` (or an in-memory key pool).
///
/// Example with `admin_api_key_manager`:
/// ```dart
/// SmartOcrAiBridge.instance.bindApiKeyManager(ApiKeyManager.instance);
/// ```
class KeyPoolAdapter {
  const KeyPoolAdapter({
    required this.getNextKey,
    required this.reportSuccess,
    required this.reportFailure,
  });

  /// Creates an adapter bound directly to `ApiKeyManager.instance` from
  /// `package:admin_api_key_manager/admin_api_key_manager.dart`.
  ///
  /// Uses dynamic invocation on `rawHandle` (`AdminApiKey`) so the host app's
  /// Firestore/Hive key pool, round-robin rotation, cooldowns, and batched
  /// error logging work seamlessly.
  factory KeyPoolAdapter.fromApiKeyManager(Object apiKeyManagerInstance) {
    final dynamic manager = apiKeyManagerInstance;
    return KeyPoolAdapter(
      getNextKey: () {
        final dynamic rawKey = manager.getNextKey();
        if (rawKey == null) return null;
        return BridgeApiKey.fromDynamic(rawKey as Object);
      },
      reportSuccess: (BridgeApiKey key) {
        final target = key.rawHandle ?? key;
        manager.reportSuccess(target);
      },
      reportFailure: (
        BridgeApiKey key,
        int statusCode,
        String featureTag,
        String userId,
      ) {
        final target = key.rawHandle ?? key;
        manager.reportFailure(target, statusCode, featureTag, userId);
      },
    );
  }

  /// Creates a simple round-robin adapter from a static list of [BridgeApiKey]s
  /// (useful for tests or apps without Firestore).
  factory KeyPoolAdapter.fromStaticKeys(
    List<BridgeApiKey> keys, {
    KeySuccessReporter? onSuccess,
    KeyFailureReporter? onFailure,
  }) {
    var cursor = 0;
    final failedIds = <String>{};
    return KeyPoolAdapter(
      getNextKey: () {
        if (keys.isEmpty) return null;
        for (var i = 0; i < keys.length; i++) {
          final candidate = keys[(cursor + i) % keys.length];
          if (!failedIds.contains(candidate.id)) {
            cursor = (cursor + i + 1) % keys.length;
            return candidate;
          }
        }
        return null;
      },
      reportSuccess: (key) {
        onSuccess?.call(key);
      },
      reportFailure: (key, statusCode, featureTag, userId) {
        if (statusCode == 401 ||
            statusCode == 403 ||
            statusCode == 429 ||
            statusCode >= 500) {
          failedIds.add(key.id);
        }
        onFailure?.call(key, statusCode, featureTag, userId);
      },
    );
  }

  final NextKeyGetter getNextKey;
  final KeySuccessReporter reportSuccess;
  final KeyFailureReporter reportFailure;
}
