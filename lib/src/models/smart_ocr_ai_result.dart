import 'ocr_routing_mode.dart';

/// Quantifies the LLM token reduction achieved by extracting text on-device
/// before calling the AI provider.
class TokenSavingsReport {
  const TokenSavingsReport({
    required this.estimatedVisionTokens,
    required this.actualPromptTokens,
    required this.usedVisionFallback,
  });

  /// Typical token cost of sending a high-resolution image to a Vision LLM
  /// (standard 1080p/4K mobile capture ≈ 1,550 vision tokens).
  final int estimatedVisionTokens;

  /// Actual token count of the compacted OCR text + prompt sent to the LLM.
  final int actualPromptTokens;

  /// True if the request sent raw image bytes to a Vision LLM instead of text-only.
  final bool usedVisionFallback;

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
    return (estimatedTokensSaved / estimatedVisionTokens) * 100.0;
  }

  String get summaryLabel => usedVisionFallback
      ? 'Vision fallback used ($actualPromptTokens prompt tokens)'
      : 'Saved ~$estimatedTokensSaved tokens (${savingsPercentage.toStringAsFixed(1)}% reduction)';
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

  /// ID of the winning key from `admin_api_key_manager`.
  final String keyIdUsed;

  /// Provider of the winning key (`'google'`, `'openrouter'`, `'custom'`).
  final String providerUsed;

  /// Model identifier used for the completion.
  final String modelUsed;

  /// Number of key attempts taken before succeeding (1 = first key succeeded).
  final int attemptsUsed;

  /// Detailed token savings telemetry.
  final TokenSavingsReport tokenSavings;
}
