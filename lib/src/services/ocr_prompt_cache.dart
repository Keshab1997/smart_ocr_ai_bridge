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
  ///
  /// Uses 32-bit FNV-1a masks (`<= 0xffffffff`) so the integer literals are
  /// 100% compatible with both 64-bit native Dart VM and `dart2js` / Flutter Web.
  static String computeKey({
    required String systemPrompt,
    required String userPrompt,
    required String compactedOcrText,
    required String routingMode,
  }) {
    final payload = '$routingMode|$systemPrompt|$userPrompt|$compactedOcrText';
    var h1 = 0x811c9dc5;
    var h2 = 0x01000193;
    final bytes = utf8.encode(payload);
    for (final b in bytes) {
      h1 ^= b;
      h1 = (h1 * 0x01000193) & 0xffffffff;
      h2 ^= (b + 0x9e) & 0xff;
      h2 = (h2 * 0x01000193) & 0xffffffff;
    }
    return '${h1.toRadixString(16)}${h2.toRadixString(16)}_${bytes.length}';
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
