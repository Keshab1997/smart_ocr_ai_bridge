/// Lightweight representation of an API key from `admin_api_key_manager`
/// (or a custom key pool) used by `SmartOcrAiBridge`.
class BridgeApiKey {
  const BridgeApiKey({
    required this.id,
    required this.name,
    required this.key,
    this.baseUrl = 'https://openrouter.ai/api/v1',
    this.model = 'openai/gpt-4o-mini',
    this.provider = 'openrouter',
    this.rawHandle,
  });

  /// Converts an `AdminApiKey` instance from `package:admin_api_key_manager`
  /// (or a Map) into a [BridgeApiKey] while preserving the original object in
  /// [rawHandle] so `ApiKeyManager.instance.reportSuccess/reportFailure` can
  /// be called with the exact original `AdminApiKey` reference.
  factory BridgeApiKey.fromDynamic(Object raw) {
    if (raw is BridgeApiKey) {
      return raw;
    }
    if (raw is Map<String, dynamic>) {
      final baseUrl =
          (raw['baseUrl'] as String?) ?? 'https://openrouter.ai/api/v1';
      return BridgeApiKey(
        id: (raw['id'] as String?) ?? 'map-key',
        name: (raw['name'] as String?) ?? 'Map Key',
        key: (raw['key'] as String?) ?? '',
        baseUrl: baseUrl,
        model: (raw['model'] as String?) ?? 'openai/gpt-4o-mini',
        provider: (raw['provider'] as String?) ?? inferProvider(baseUrl),
        rawHandle: raw,
      );
    }

    // Duck-typed extraction from AdminApiKey (package:admin_api_key_manager)
    final dynamic dyn = raw;
    final String baseUrl =
        (dyn.baseUrl as String?) ?? 'https://openrouter.ai/api/v1';
    final String provider = (dyn.provider as String?) ?? inferProvider(baseUrl);
    return BridgeApiKey(
      id: (dyn.id as String?) ?? '',
      name: (dyn.name as String?) ?? '',
      key: (dyn.key as String?) ?? '',
      baseUrl: baseUrl,
      model: (dyn.model as String?) ?? 'gpt-4o-mini',
      provider: provider,
      rawHandle: raw,
    );
  }

  final String id;
  final String name;
  final String key;
  final String baseUrl;
  final String model;

  /// `'google'` (Gemini API), `'openrouter'`, or `'custom'` (OpenAI-compatible).
  final String provider;

  /// Original `AdminApiKey` instance when sourced from `ApiKeyManager.instance`.
  final Object? rawHandle;

  bool get isGoogleGemini =>
      provider == 'google' ||
      baseUrl.toLowerCase().contains('generativelanguage');

  static String inferProvider(String baseUrl) {
    final lower = baseUrl.toLowerCase();
    if (lower.contains('generativelanguage')) return 'google';
    if (lower.contains('openrouter')) return 'openrouter';
    return 'custom';
  }
}
