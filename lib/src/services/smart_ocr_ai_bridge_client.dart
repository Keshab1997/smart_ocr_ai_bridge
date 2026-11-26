import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../models/bridge_key.dart';
import '../models/ocr_routing_mode.dart';
import '../models/smart_ocr_ai_result.dart';
import 'key_pool_adapter.dart';
import 'multilingual_ocr_extractor.dart';
import 'ocr_prompt_cache.dart';
import 'ocr_text_optimizer.dart';
import 'smart_entity_extractor.dart';

/// Exception thrown when no healthy API key is available or all retry attempts
/// across the key pool failed.
class SmartOcrAiBridgeException implements Exception {
  const SmartOcrAiBridgeException(
    this.message, {
    this.lastStatusCode,
    this.attemptsMade = 0,
  });

  final String message;
  final int? lastStatusCode;
  final int attemptsMade;

  @override
  String toString() =>
      'SmartOcrAiBridgeException($message, status: $lastStatusCode, attempts: $attemptsMade)';
}

/// Main drop-in bridge combining 5-script on-device ML Kit OCR with
/// `admin_api_key_manager` key-pool rotation, 0-token LRU response caching,
/// offline entity extraction, and JSON schema parsing.
class SmartOcrAiBridge {
  SmartOcrAiBridge({
    KeyPoolAdapter? keyPool,
    MultilingualOcrExtractor? ocrExtractor,
    http.Client? httpClient,
    OcrPromptCache? cache,
  })  : _keyPool = keyPool,
        _ocrExtractor = ocrExtractor ?? MultilingualOcrExtractor(),
        _httpClient = httpClient ?? http.Client(),
        _cache = cache ?? OcrPromptCache();

  /// Shared singleton for app-wide usage.
  static final SmartOcrAiBridge instance = SmartOcrAiBridge();

  KeyPoolAdapter? _keyPool;
  MultilingualOcrExtractor _ocrExtractor;
  http.Client _httpClient;
  OcrPromptCache _cache;

  OcrPromptCache get cache => _cache;

  /// Binds `ApiKeyManager.instance` from `package:admin_api_key_manager`.
  void bindApiKeyManager(Object apiKeyManagerInstance) {
    _keyPool = KeyPoolAdapter.fromApiKeyManager(apiKeyManagerInstance);
  }

  /// Binds a custom [KeyPoolAdapter], [MultilingualOcrExtractor], [http.Client], or [OcrPromptCache].
  void configure({
    KeyPoolAdapter? keyPool,
    MultilingualOcrExtractor? ocrExtractor,
    http.Client? httpClient,
    OcrPromptCache? cache,
  }) {
    if (keyPool != null) _keyPool = keyPool;
    if (ocrExtractor != null) _ocrExtractor = ocrExtractor;
    if (httpClient != null) _httpClient = httpClient;
    if (cache != null) _cache = cache;
  }

  /// Clears the 0-token local response cache.
  void clearCache() => _cache.clear();

  /// Runs 5-script on-device OCR on [imageFile] (`dart:io` `File` or file path
  /// `String`) or [imageBytes], compacts the extracted text, routes according to
  /// [routingMode], checks the 0-token cache, and calls the LLM using keys from
  /// `admin_api_key_manager` with auto-failover.
  Future<SmartOcrAiResult> analyzeImage({
    Object? imageFile,
    Uint8List? imageBytes,
    required String userPrompt,
    String systemPrompt =
        'You are a precise assistant analyzing text extracted from an image.',
    OcrRoutingMode routingMode = OcrRoutingMode.hybridAuto,
    int minOcrScoreForTextOnly = 20,
    int maxOcrChars = 12000,
    int estimatedVisionBaselineTokens = 1550,
    int maxKeyAttempts = 3,
    double temperature = 0.2,
    bool useCache = true,
    String featureTag = 'smart_ocr_ai_bridge',
    String userId = 'anonymous',
  }) async {
    if (imageFile == null && imageBytes == null) {
      throw ArgumentError('Either imageFile or imageBytes must be provided.');
    }

    final String? resolvedFilePath = imageFile == null
        ? null
        : (imageFile is String
            ? imageFile
            : (imageFile as dynamic).path as String);

    // 1. Run 5-script on-device ML Kit OCR (0 tokens, offline)
    final OcrExtractionResult extraction = imageBytes != null
        ? await _ocrExtractor.extractFromBytes(imageBytes)
        : await _ocrExtractor.extractFromFilePath(resolvedFilePath!);

    final cleanedBest =
        SmartEntityExtractor.cleanIndicOcrArtifacts(extraction.bestText);

    // 2. Decide whether to send text-only or fall back to vision bytes
    final String compactedText = routingMode == OcrRoutingMode.structuredBlocks
        ? formatStructuredBlocks(extraction.blocks, maxChars: maxOcrChars)
        : compactOcrText(cleanedBest, maxChars: maxOcrChars);

    final bool shouldUseVisionFallback = switch (routingMode) {
      OcrRoutingMode.textOnly => false,
      OcrRoutingMode.structuredBlocks => false,
      OcrRoutingMode.visionOnly => true,
      OcrRoutingMode.hybridAuto =>
        !extraction.hasText || extraction.score < minOcrScoreForTextOnly,
    };

    if (!shouldUseVisionFallback && compactedText.isEmpty) {
      throw const SmartOcrAiBridgeException(
        'No text detected on-device for text-only routing. '
        'Use OcrRoutingMode.hybridAuto to fall back to vision automatically.',
      );
    }

    Uint8List? visionPayloadBytes;
    if (shouldUseVisionFallback) {
      visionPayloadBytes =
          imageBytes ?? await readPlatformFileBytes(resolvedFilePath!);
    }

    // 3. Build token-optimized prompt
    final String composedUserPrompt = compactedText.isNotEmpty
        ? '$userPrompt\n\n--- EXTRACTED IMAGE TEXT (OCR) ---\n$compactedText'
        : userPrompt;

    return _executeWithKeyFailover(
      systemPrompt: systemPrompt,
      composedUserPrompt: composedUserPrompt,
      rawExtractedText: cleanedBest,
      compactedOcrText: compactedText,
      ocrScore: extraction.score,
      routingMode: routingMode,
      usedVisionFallback: shouldUseVisionFallback,
      visionBytes: visionPayloadBytes,
      estimatedVisionBaselineTokens: estimatedVisionBaselineTokens,
      maxKeyAttempts: maxKeyAttempts,
      temperature: temperature,
      useCache: useCache,
      featureTag: featureTag,
      userId: userId,
    );
  }

  /// Analyzes an image and parses the AI output directly into a structured
  /// `Map<String, dynamic>` JSON object (automatically stripping markdown code
  /// fences if the model includes them).
  Future<Map<String, dynamic>> analyzeImageAsJson({
    Object? imageFile,
    Uint8List? imageBytes,
    required String userPrompt,
    Map<String, dynamic>? schemaHint,
    String systemPrompt =
        'You are a strict JSON extraction engine. Respond ONLY with valid JSON.',
    OcrRoutingMode routingMode = OcrRoutingMode.hybridAuto,
    bool useCache = true,
    String featureTag = 'smart_ocr_json',
    String userId = 'anonymous',
  }) async {
    final schemaBlock = schemaHint != null
        ? '\nReturn a valid JSON object matching this structure:\n${jsonEncode(schemaHint)}'
        : '\nReturn ONLY a valid JSON object without markdown commentary.';
    final result = await analyzeImage(
      imageFile: imageFile,
      imageBytes: imageBytes,
      userPrompt: '$userPrompt$schemaBlock',
      systemPrompt: systemPrompt,
      routingMode: routingMode,
      useCache: useCache,
      featureTag: featureTag,
      userId: userId,
    );
    return extractJsonObject(result.aiResponse);
  }

  /// Directly sends already-extracted OCR text (e.g. from `SnapText OCR`'s
  /// editable text box) to the AI pool with automatic key failover, 0-token
  /// cache lookup, and token-saving telemetry.
  Future<SmartOcrAiResult> analyzeExtractedText({
    required String extractedText,
    required String userPrompt,
    String systemPrompt =
        'You are a precise assistant analyzing text extracted from an image.',
    int maxOcrChars = 12000,
    int estimatedVisionBaselineTokens = 1550,
    int maxKeyAttempts = 3,
    double temperature = 0.2,
    bool useCache = true,
    String featureTag = 'smart_ocr_text_only',
    String userId = 'anonymous',
  }) async {
    final cleaned = SmartEntityExtractor.cleanIndicOcrArtifacts(extractedText);
    final compacted = compactOcrText(cleaned, maxChars: maxOcrChars);
    if (compacted.isEmpty) {
      throw const SmartOcrAiBridgeException(
        'Extracted text is empty; nothing to send to AI.',
      );
    }
    final score = calculateOcrScore(compacted);
    final composedUserPrompt =
        '$userPrompt\n\n--- EXTRACTED IMAGE TEXT (OCR) ---\n$compacted';

    return _executeWithKeyFailover(
      systemPrompt: systemPrompt,
      composedUserPrompt: composedUserPrompt,
      rawExtractedText: cleaned,
      compactedOcrText: compacted,
      ocrScore: score,
      routingMode: OcrRoutingMode.textOnly,
      usedVisionFallback: false,
      visionBytes: null,
      estimatedVisionBaselineTokens: estimatedVisionBaselineTokens,
      maxKeyAttempts: maxKeyAttempts,
      temperature: temperature,
      useCache: useCache,
      featureTag: featureTag,
      userId: userId,
    );
  }

  /// Directly sends already-extracted OCR text to the AI pool and parses the
  /// output into a structured `Map<String, dynamic>` JSON object.
  Future<Map<String, dynamic>> analyzeExtractedTextAsJson({
    required String extractedText,
    required String userPrompt,
    Map<String, dynamic>? schemaHint,
    String systemPrompt =
        'You are a strict JSON extraction engine. Respond ONLY with valid JSON.',
    bool useCache = true,
    String featureTag = 'smart_ocr_text_json',
    String userId = 'anonymous',
  }) async {
    final schemaBlock = schemaHint != null
        ? '\nReturn a valid JSON object matching this structure:\n${jsonEncode(schemaHint)}'
        : '\nReturn ONLY a valid JSON object without markdown commentary.';
    final result = await analyzeExtractedText(
      extractedText: extractedText,
      userPrompt: '$userPrompt$schemaBlock',
      systemPrompt: systemPrompt,
      useCache: useCache,
      featureTag: featureTag,
      userId: userId,
    );
    return extractJsonObject(result.aiResponse);
  }

  Future<SmartOcrAiResult> _executeWithKeyFailover({
    required String systemPrompt,
    required String composedUserPrompt,
    required String rawExtractedText,
    required String compactedOcrText,
    required int ocrScore,
    required OcrRoutingMode routingMode,
    required bool usedVisionFallback,
    required Uint8List? visionBytes,
    required int estimatedVisionBaselineTokens,
    required int maxKeyAttempts,
    required double temperature,
    required bool useCache,
    required String featureTag,
    required String userId,
  }) async {
    final entities = SmartEntityExtractor.extractAll(rawExtractedText);
    final baselineVisionTotal = estimatedVisionBaselineTokens +
        estimateTextTokens(
            '$systemPrompt\n${userPromptOnly(composedUserPrompt)}');

    final String cacheKey = OcrPromptCache.computeKey(
      systemPrompt: systemPrompt,
      userPrompt: composedUserPrompt,
      compactedOcrText: compactedOcrText,
      routingMode: routingMode.name,
    );

    if (useCache && !usedVisionFallback && compactedOcrText.isNotEmpty) {
      final cachedAnswer = _cache.get(cacheKey);
      if (cachedAnswer != null) {
        return SmartOcrAiResult(
          aiResponse: cachedAnswer,
          extractedText: rawExtractedText,
          compactedOcrText: compactedOcrText,
          ocrScore: ocrScore,
          routingMode: routingMode,
          usedVisionFallback: false,
          keyIdUsed: 'cache',
          providerUsed: 'cache',
          modelUsed: 'cache',
          attemptsUsed: 0,
          fromCache: true,
          detectedEntities: entities,
          tokenSavings: TokenSavingsReport(
            estimatedVisionTokens: baselineVisionTotal,
            actualPromptTokens: 0,
            usedVisionFallback: false,
            fromCache: true,
          ),
        );
      }
    }

    final pool = _keyPool;
    if (pool == null) {
      throw const SmartOcrAiBridgeException(
        'No KeyPoolAdapter configured. Call SmartOcrAiBridge.instance.bindApiKeyManager(ApiKeyManager.instance) first.',
      );
    }

    int? lastStatusCode;
    String lastError = 'No healthy API keys available in pool.';
    final maxTries = maxKeyAttempts.clamp(1, 10);

    for (var attempt = 1; attempt <= maxTries; attempt++) {
      final key = pool.getNextKey();
      if (key == null) {
        break;
      }

      try {
        final response = key.isGoogleGemini
            ? await _callGeminiEndpoint(
                key: key,
                systemPrompt: systemPrompt,
                userPrompt: composedUserPrompt,
                visionBytes: visionBytes,
                temperature: temperature,
              )
            : await _callOpenAiCompatibleEndpoint(
                key: key,
                systemPrompt: systemPrompt,
                userPrompt: composedUserPrompt,
                visionBytes: visionBytes,
                temperature: temperature,
              );

        if (response.statusCode >= 200 && response.statusCode < 300) {
          final decodedBody = utf8.decode(
            response.bodyBytes,
            allowMalformed: true,
          );
          final parsedAnswer = key.isGoogleGemini
              ? _extractGeminiText(decodedBody)
              : _extractOpenAiText(decodedBody);

          pool.reportSuccess(key);

          if (useCache && !usedVisionFallback && compactedOcrText.isNotEmpty) {
            _cache.put(cacheKey, parsedAnswer);
          }

          final promptTokens =
              estimateTextTokens('$systemPrompt\n$composedUserPrompt') +
                  (usedVisionFallback ? estimatedVisionBaselineTokens : 0);

          return SmartOcrAiResult(
            aiResponse: parsedAnswer,
            extractedText: rawExtractedText,
            compactedOcrText: compactedOcrText,
            ocrScore: ocrScore,
            routingMode: routingMode,
            usedVisionFallback: usedVisionFallback,
            keyIdUsed: key.id,
            providerUsed: key.provider,
            modelUsed: key.model,
            attemptsUsed: attempt,
            fromCache: false,
            detectedEntities: entities,
            tokenSavings: TokenSavingsReport(
              estimatedVisionTokens: baselineVisionTotal,
              actualPromptTokens: promptTokens,
              usedVisionFallback: usedVisionFallback,
              fromCache: false,
            ),
          );
        }

        lastStatusCode = response.statusCode;
        lastError = 'HTTP ${response.statusCode}: ${response.body}';
        pool.reportFailure(key, response.statusCode, featureTag, userId);
      } catch (e) {
        lastStatusCode = 0;
        lastError = e.toString();
        pool.reportFailure(key, 503, featureTag, userId);
      }
    }

    throw SmartOcrAiBridgeException(
      lastError,
      lastStatusCode: lastStatusCode,
      attemptsMade: maxTries,
    );
  }

  static String userPromptOnly(String composedPrompt) {
    final idx = composedPrompt.indexOf('\n\n--- EXTRACTED IMAGE TEXT');
    if (idx < 0) return composedPrompt;
    return composedPrompt.substring(0, idx);
  }

  Future<http.Response> _callGeminiEndpoint({
    required BridgeApiKey key,
    required String systemPrompt,
    required String userPrompt,
    required Uint8List? visionBytes,
    required double temperature,
  }) async {
    var base = key.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    final uri = Uri.parse(
      '$base/models/${key.model}:generateContent?key=${Uri.encodeQueryComponent(key.key)}',
    );

    final parts = <Map<String, dynamic>>[
      <String, dynamic>{'text': '$systemPrompt\n\n$userPrompt'},
      if (visionBytes != null && visionBytes.isNotEmpty)
        <String, dynamic>{
          'inline_data': <String, dynamic>{
            'mime_type': 'image/jpeg',
            'data': base64Encode(visionBytes),
          },
        },
    ];

    final payload = <String, dynamic>{
      'contents': <Map<String, dynamic>>[
        <String, dynamic>{'parts': parts},
      ],
      'generationConfig': <String, dynamic>{
        'temperature': temperature,
      },
    };

    return _httpClient.post(
      uri,
      headers: const <String, String>{'Content-Type': 'application/json'},
      body: jsonEncode(payload),
    );
  }

  Future<http.Response> _callOpenAiCompatibleEndpoint({
    required BridgeApiKey key,
    required String systemPrompt,
    required String userPrompt,
    required Uint8List? visionBytes,
    required double temperature,
  }) async {
    var base = key.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    final endpoint =
        base.endsWith('/chat/completions') ? base : '$base/chat/completions';
    final uri = Uri.parse(endpoint);

    final Object userContent = (visionBytes != null && visionBytes.isNotEmpty)
        ? <Map<String, dynamic>>[
            <String, dynamic>{'type': 'text', 'text': userPrompt},
            <String, dynamic>{
              'type': 'image_url',
              'image_url': <String, dynamic>{
                'url': 'data:image/jpeg;base64,${base64Encode(visionBytes)}',
              },
            },
          ]
        : userPrompt;

    final payload = <String, dynamic>{
      'model': key.model,
      'temperature': temperature,
      'messages': <Map<String, dynamic>>[
        <String, dynamic>{'role': 'system', 'content': systemPrompt},
        <String, dynamic>{'role': 'user', 'content': userContent},
      ],
    };

    return _httpClient.post(
      uri,
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer ${key.key}',
      },
      body: jsonEncode(payload),
    );
  }

  static String _extractGeminiText(String rawBody) {
    final decoded = jsonDecode(rawBody) as Map<String, dynamic>;
    final candidates = decoded['candidates'] as List<dynamic>?;
    if (candidates == null || candidates.isEmpty) {
      throw const FormatException('Gemini response contained no candidates');
    }
    final first = candidates.first as Map<String, dynamic>;
    final content = first['content'] as Map<String, dynamic>?;
    final parts = content?['parts'] as List<dynamic>?;
    if (parts == null || parts.isEmpty) {
      throw const FormatException('Gemini candidate contained no parts');
    }
    final buffer = StringBuffer();
    for (final part in parts) {
      if (part is Map<String, dynamic> && part['text'] is String) {
        buffer.write(part['text'] as String);
      }
    }
    return buffer.toString().trim();
  }

  static String _extractOpenAiText(String rawBody) {
    final decoded = jsonDecode(rawBody) as Map<String, dynamic>;
    final choices = decoded['choices'] as List<dynamic>?;
    if (choices == null || choices.isEmpty) {
      throw const FormatException('OpenAI response contained no choices');
    }
    final first = choices.first as Map<String, dynamic>;
    final message = first['message'] as Map<String, dynamic>?;
    final content = message?['content'];
    if (content is String) {
      return content.trim();
    }
    throw const FormatException('OpenAI choice contained no text content');
  }
}
