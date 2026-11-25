final RegExp _unicodeLetterOrDigit = RegExp(r'^[\p{L}\p{Nd}]$', unicode: true);
final RegExp _multipleSpaces = RegExp(r'[ \t]{2,}');
final RegExp _multipleBlankLines = RegExp(r'\n{3,}');

/// Checks whether [rune] is a Unicode letter or decimal digit.
bool isUnicodeLetterOrDigit(int rune) {
  if ((rune >= 0x30 && rune <= 0x39) ||
      (rune >= 0x41 && rune <= 0x5A) ||
      (rune >= 0x61 && rune <= 0x7A)) {
    return true;
  }
  if (rune < 0x80) {
    return false;
  }
  return _unicodeLetterOrDigit.hasMatch(String.fromCharCode(rune));
}

/// Checks whether [rune] is Unicode whitespace.
bool isUnicodeWhitespace(int rune) {
  if (rune == 0x20 || (rune >= 0x09 && rune <= 0x0D)) {
    return true;
  }
  if (rune >= 0x1C && rune <= 0x1F) {
    return true;
  }
  if (rune == 0x85 ||
      rune == 0xA0 ||
      rune == 0x1680 ||
      (rune >= 0x2000 && rune <= 0x200A) ||
      rune == 0x2028 ||
      rune == 0x2029 ||
      rune == 0x202F ||
      rune == 0x205F ||
      rune == 0x3000) {
    return true;
  }
  return false;
}

/// Character-weighted OCR quality scoring function:
/// - CJK, Hiragana/Katakana, Hangul, Devanagari: +5 per rune
/// - Other Unicode letters/digits (Latin, Bengali, Arabic, etc.): +2 per rune
/// - Whitespace: +1 per rune
/// - Plus `text.length`.
int calculateOcrScore(String text) {
  var score = 0;
  for (final c in text.runes) {
    if ((c >= 19968 && c < 40960) ||
        (c >= 12352 && c < 12448) ||
        (c >= 12448 && c < 12544) ||
        (c >= 44032 && c < 55216) ||
        (c >= 2304 && c < 2432)) {
      score += 5;
    } else if (isUnicodeLetterOrDigit(c)) {
      score += 2;
    } else if (isUnicodeWhitespace(c)) {
      score += 1;
    }
  }
  return score + text.length;
}

/// Picks the non-blank trimmed result with the highest [calculateOcrScore].
/// Ties go to the first result.
String? selectBestOcrResult(Iterable<String> candidates) {
  String? bestText;
  int? bestScore;

  for (final raw in candidates) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) continue;
    final score = calculateOcrScore(trimmed);
    if (bestScore == null || score > bestScore) {
      bestScore = score;
      bestText = trimmed;
    }
  }
  return bestText;
}

/// Compacts raw OCR text before sending it to an LLM so no tokens are wasted
/// on trailing spaces, repeated blank lines, or OCR noise artifacts.
String compactOcrText(String rawText, {int maxChars = 12000}) {
  final normalizedLines = rawText
      .replaceAll('\r\n', '\n')
      .replaceAll('\r', '\n')
      .split('\n')
      .map((line) => line.replaceAll(_multipleSpaces, ' ').trim())
      .toList(growable: false);

  final joined =
      normalizedLines.join('\n').replaceAll(_multipleBlankLines, '\n\n').trim();

  if (joined.length <= maxChars) {
    return joined;
  }
  return joined.substring(0, maxChars);
}

/// Formats spatial OCR blocks into compact numbered sections so text-only LLMs
/// preserve receipt/prescription/document structure without vision tokens.
String formatStructuredBlocks(List<String> blocks, {int maxChars = 12000}) {
  final nonEmpty = <String>[];
  for (final b in blocks) {
    final cleaned = compactOcrText(b);
    if (cleaned.isNotEmpty) {
      nonEmpty.add(cleaned);
    }
  }
  if (nonEmpty.isEmpty) return '';
  final buffer = StringBuffer();
  for (var i = 0; i < nonEmpty.length; i++) {
    if (i > 0) {
      buffer.writeln();
      buffer.writeln();
    }
    buffer.writeln('[Block ${i + 1}]');
    buffer.write(nonEmpty[i]);
  }
  final out = buffer.toString().trim();
  return out.length <= maxChars ? out : out.substring(0, maxChars);
}

/// Estimates LLM token count for a text string (~4 chars per token for Latin,
/// ~1.5 chars per token for CJK/Indic scripts).
int estimateTextTokens(String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return 0;
  var nonAscii = 0;
  for (final rune in trimmed.runes) {
    if (rune > 127) nonAscii++;
  }
  final asciiChars = (trimmed.length - nonAscii).clamp(0, trimmed.length);
  final estimated = (asciiChars / 4.0) + (nonAscii / 1.6);
  return estimated.ceil().clamp(1, 1000000);
}
