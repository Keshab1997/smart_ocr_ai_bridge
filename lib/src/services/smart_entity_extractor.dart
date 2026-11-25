/// Represents a single structured entity detected offline from OCR text.
enum SmartEntityType {
  email,
  phone,
  url,
  amount,
  date,
}

class SmartEntity {
  const SmartEntity({
    required this.type,
    required this.value,
  });

  final SmartEntityType type;
  final String value;
}

/// Offline zero-token extractor for emails, phone numbers, URLs, currency
/// amounts (₹, ৳, $, €, Rs.), and dates inside OCR text, plus Indic/Bengali
/// OCR artifact cleanup.
class SmartEntityExtractor {
  const SmartEntityExtractor._();

  static final RegExp _emailRegex = RegExp(
    r'[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}',
  );

  static final RegExp _urlRegex = RegExp(
    r'(?:https?:\/\/|www\.)[^\s,;)]+',
    caseSensitive: false,
  );

  static final RegExp _phoneRegex = RegExp(
    r'(?:\+?\d{1,3}[\s-]?)?(?:\(?\d{3,5}\)?[\s-]?)?\d{3,5}[\s-]?\d{4}',
  );

  static final RegExp _amountRegex = RegExp(
    r'(?:₹|৳|\$|€|£|Rs\.?|INR|BDT|USD)\s?\d+(?:[.,]\d{1,2})?',
    caseSensitive: false,
  );

  static final RegExp _dateRegex = RegExp(
    r'\b(?:\d{1,2}[\/\-]\d{1,2}[\/\-]\d{2,4}|\d{4}[\/\-]\d{1,2}[\/\-]\d{1,2})\b',
  );

  /// Extracts all unique structured entities (emails, URLs, phones, amounts,
  /// dates) from [text] completely offline (0 tokens).
  static List<SmartEntity> extractAll(String text) {
    if (text.trim().isEmpty) return const <SmartEntity>[];
    final seen = <String>{};
    final entities = <SmartEntity>[];

    void addMatches(RegExp regex, SmartEntityType type, {int minDigits = 0}) {
      for (final m in regex.allMatches(text)) {
        final raw = m.group(0)?.trim() ?? '';
        if (raw.isEmpty) continue;
        if (minDigits > 0) {
          final digitCount =
              raw.runes.where((r) => r >= 0x30 && r <= 0x39).length;
          if (digitCount < minDigits) continue;
        }
        final key = '${type.name}:$raw';
        if (seen.add(key)) {
          entities.add(SmartEntity(type: type, value: raw));
        }
      }
    }

    addMatches(_emailRegex, SmartEntityType.email);
    addMatches(_urlRegex, SmartEntityType.url);
    addMatches(_amountRegex, SmartEntityType.amount);
    addMatches(_dateRegex, SmartEntityType.date);
    addMatches(_phoneRegex, SmartEntityType.phone, minDigits: 8);

    return entities;
  }

  /// Cleans common OCR punctuation and zero-width artifacts around Bengali,
  /// Devanagari, and Latin text.
  static String cleanIndicOcrArtifacts(String text) {
    return text
        .replaceAll('\u200B', '') // zero-width space
        .replaceAll('\uFEFF', '') // BOM
        .replaceAll(RegExp(r'[ \t]+\n'), '\n')
        .trim();
  }
}
