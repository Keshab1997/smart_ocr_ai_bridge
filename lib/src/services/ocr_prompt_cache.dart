import 'dart:collection';
import 'dart:convert';

/// Deterministic in-memory LRU cache for OCR+Prompt responses so repeat scans
/// of the same document/receipt cost 0 API tokens and return in 0 ms.
class OcrPromptCache {
  OcrPromptCache({this.maxEntries = 100});

  final int maxEntries;
  final LinkedHashMap<String, String> _store = LinkedHashMap<String, String>();

  int get length => _store.length;

  /// Builds a deterministic cache key from the prompt and compacted OCR text.
  static String computeKey({
    required String systemPrompt,
    required String userPrompt,
    required String compactedOcrText,
    required String routingMode,
  }) {
    final payload = '$routingMode|$systemPrompt|$userPrompt|$compactedOcrText';
    // 64-bit FNV-1a hash encoded as hex + length suffix for collision safety
    var hash = 0xcbf29ce484222325;
    final bytes = utf8.encode(payload);
    for (final b in bytes) {
      hash ^= b;
      hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
    }
    return '${hash.toRadixString(16)}_${bytes.length}';
  }

  String? get(String key) {
    final val = _store.remove(key);
    if (val != null) {
      // Re-insert as most recently used
      _store[key] = val;
    }
    return val;
  }

  void put(String key, String response) {
    if (maxEntries <= 0) return;
    _store.remove(key);
    _store[key] = response;
    while (_store.length > maxEntries) {
      _store.remove(_store.keys.first);
    }
  }

  void clear() => _store.clear();
}

/// Extracts and parses a JSON object or array from an LLM response that may be
/// wrapped in Markdown code fences (` ```json ... ``` `) or explanatory prose.
Map<String, dynamic> extractJsonObject(String rawAiResponse) {
  var cleaned = rawAiResponse.trim();

  // Strip ```json ... ``` or ``` ... ``` fences if present
  final fenceMatch =
      RegExp(r'```(?:json)?\s*([\s\S]*?)```', caseSensitive: false)
          .firstMatch(cleaned);
  if (fenceMatch != null && fenceMatch.group(1) != null) {
    cleaned = fenceMatch.group(1)!.trim();
  }

  final startBrace = cleaned.indexOf('{');
  final endBrace = cleaned.lastIndexOf('}');
  if (startBrace >= 0 && endBrace > startBrace) {
    cleaned = cleaned.substring(startBrace, endBrace + 1);
  }

  final decoded = jsonDecode(cleaned);
  if (decoded is Map<String, dynamic>) {
    return decoded;
  }
  if (decoded is List<dynamic>) {
    return <String, dynamic>{'items': decoded};
  }
  throw const FormatException(
      'AI response did not contain a valid JSON object');
}
