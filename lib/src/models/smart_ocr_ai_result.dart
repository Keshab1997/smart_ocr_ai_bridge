import '../services/smart_entity_extractor.dart';
import 'ocr_routing_mode.dart';

/// Quantifies the LLM token reduction achieved by extracting text on-device
/// before calling the AI provider.
class TokenSavingsReport {
  const TokenSavingsReport({
    required this.estimatedVisionTokens,
    required this.actualPromptTokens,
    required this.usedVisionFallback,
    this.fromCache = false,
  });

  /// Typical token cost of sending a high-resolution image to a Vision LLM
  /// (standard 1080p/4K mobile capture ≈ 1,550 vision tokens).
  final int estimatedVisionTokens;

  /// Actual token count of the compacted OCR text + prompt sent to the LLM
  /// (`0` when [fromCache] is true).
  final int actualPromptTokens;

  /// True if the request sent raw image bytes to a Vision LLM instead of text-only.
  final bool usedVisionFallback;

  /// True if the response was served from the 0-token local cache.
  final bool fromCache;

  /// Total tokens saved on this call (`0` if vision fallback was used).
  int get estimatedTokensSaved => usedVisionFallback
      ? 0
      : (estimatedVisionTokens - actualPromptTokens)
          .clamp(0, estimatedVisionTokens);

  /// Percentage of tokens saved (`0.0` to `100.0`).
  double get savingsPercentage {
    if (usedVisionFallback || estimatedVisionTokens <= 0) {
      return 0.0;
    }
    if (fromCache) {
      return 100.0;
    }
    return (estimatedTokensSaved / estimatedVisionTokens) * 100.0;
  }

  String get summaryLabel {
    if (fromCache) {
      return 'Served from 0-token cache (100% saved)';
    }
    if (usedVisionFallback) {
      return 'Vision fallback used ($actualPromptTokens prompt tokens)';
    }
    return 'Saved ~$estimatedTokensSaved tokens (${savingsPercentage.toStringAsFixed(1)}% reduction)';
  }
}

/// Complete response returned by `SmartOcrAiBridge.instance.analyzeImage(...)`.
class SmartOcrAiResult {
  const SmartOcrAiResult({
    required this.aiResponse,
    required this.extractedText,
    required this.compactedOcrText,
    required this.ocrScore,
    required this.routingMode,
    required this.usedVisionFallback,
    required this.keyIdUsed,
    required this.providerUsed,
    required this.modelUsed,
    required this.attemptsUsed,
    required this.tokenSavings,
    this.fromCache = false,
    this.detectedEntities = const <SmartEntity>[],
  });

  /// The text or JSON string returned by the AI model.
  final String aiResponse;

  /// Raw text extracted on-device by the 5-script ML Kit OCR pipeline.
  final String extractedText;

  /// Whitespace-compacted / layout-structured text sent in the prompt.
  final String compactedOcrText;

  /// Character-weighted confidence/quality score from `calculateOcrScore`.
  final int ocrScore;

  /// Routing mode requested by the caller.
  final OcrRoutingMode routingMode;

  /// Whether multimodal image bytes were sent (`true`) or text-only (`false`).
  final bool usedVisionFallback;

  /// ID of the winning key from `admin_api_key_manager` (or `'cache'` on cache hit).
  final String keyIdUsed;

  /// Provider of the winning key (`'google'`, `'openrouter'`, `'custom'`, or `'cache'`).
  final String providerUsed;

  /// Model identifier used for the completion.
  final String modelUsed;

  /// Number of key attempts taken before succeeding (`0` on cache hit).
  final int attemptsUsed;

  /// Detailed token savings telemetry.
  final TokenSavingsReport tokenSavings;

  /// Whether this response was returned from the 0-token local cache.
  final bool fromCache;

  /// Structured entities (emails, phones, URLs, currency amounts, dates)
  /// detected offline from the extracted text at 0 token cost.
  final List<SmartEntity> detectedEntities;
}
