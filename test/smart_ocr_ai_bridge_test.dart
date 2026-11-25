import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:smart_ocr_ai_bridge/smart_ocr_ai_bridge.dart';

class _FakeApiKey {
  const _FakeApiKey({
    required this.id,
    required this.name,
    required this.key,
    required this.baseUrl,
    required this.model,
    required this.provider,
  });

  final String id;
  final String name;
  final String key;
  final String baseUrl;
  final String model;
  final String provider;
}

class _FakeApiKeyManager {
  _FakeApiKeyManager(this.keys);

  final List<_FakeApiKey> keys;
  int _idx = 0;
  final List<String> succeededIds = <String>[];
  final List<String> failedIds = <String>[];

  _FakeApiKey? getNextKey() {
    if (_idx >= keys.length) return null;
    return keys[_idx++];
  }

  void reportSuccess(Object key) {
    succeededIds.add((key as _FakeApiKey).id);
  }

  void reportFailure(
    Object key,
    int statusCode,
    String feature,
    String userId,
  ) {
    failedIds.add('${(key as _FakeApiKey).id}:$statusCode:$feature');
  }
}

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('smart_ocr_bridge_test_');
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('OCR text compaction & scoring', () {
    test('compacts redundant spaces and blank lines cleanly', () {
      const messy = '  Invoice #1042   \r\n\r\n\r\n\r\n  Total:   ₹450.00  ';
      expect(
        compactOcrText(messy),
        equals('Invoice #1042\n\nTotal: ₹450.00'),
      );
    });

    test('formats spatial blocks with [Block N] markers', () {
      final formatted = formatStructuredBlocks(<String>[
        'Header Clinic',
        'Rx: Paracetamol 500mg',
      ]);
      expect(
        formatted,
        equals('[Block 1]\nHeader Clinic\n\n[Block 2]\nRx: Paracetamol 500mg'),
      );
    });
  });

  group('SmartOcrAiBridge + ApiKeyManager failover & token saving', () {
    test(
        'hybridAuto sends text-only when OCR score >= threshold, saving ~90% tokens and rotating keys on 429',
        () async {
      final fakeManager = _FakeApiKeyManager(<_FakeApiKey>[
        const _FakeApiKey(
          id: 'key-1-rate-limited',
          name: 'OpenRouter Primary',
          key: 'sk-or-1',
          baseUrl: 'https://openrouter.ai/api/v1',
          model: 'deepseek/deepseek-chat',
          provider: 'openrouter',
        ),
        const _FakeApiKey(
          id: 'key-2-gemini-healthy',
          name: 'Gemini Backup',
          key: 'AIza-2',
          baseUrl: 'https://generativelanguage.googleapis.com/v1beta',
          model: 'gemini-2.0-flash',
          provider: 'google',
        ),
      ]);

      final extractor = MultilingualOcrExtractor(
        tempDirOverride: tempDir,
        scriptRunner: (script, _) async {
          if (script.name == 'latin') {
            return const ScriptOcrPass(
              text:
                  'Patient: Rahul Sen\nMedicine: Amoxicillin 500mg twice daily',
              blocks: <String>[
                'Patient: Rahul Sen',
                'Medicine: Amoxicillin 500mg twice daily',
              ],
            );
          }
          return const ScriptOcrPass(text: '');
        },
      );

      final mockHttp = MockClient((http.Request request) async {
        if (request.url.host.contains('openrouter.ai')) {
          return http.Response('{"error":"rate_limited"}', 429);
        }
        // Verify that Gemini request did NOT include inline_data vision bytes!
        final decodedBody = jsonDecode(request.body) as Map<String, dynamic>;
        final contents = decodedBody['contents'] as List<dynamic>;
        final parts =
            (contents.first as Map<String, dynamic>)['parts'] as List<dynamic>;
        expect(parts.length, equals(1)); // Text-only part!

        return http.Response(
          jsonEncode(<String, dynamic>{
            'candidates': <Map<String, dynamic>>[
              <String, dynamic>{
                'content': <String, dynamic>{
                  'parts': <Map<String, dynamic>>[
                    <String, dynamic>{
                      'text':
                          '{"medicine":"Amoxicillin 500mg","frequency":"BD"}',
                    },
                  ],
                },
              },
            ],
          }),
          200,
        );
      });

      final bridge = SmartOcrAiBridge(
        ocrExtractor: extractor,
        httpClient: mockHttp,
      )..bindApiKeyManager(fakeManager);

      final result = await bridge.analyzeImage(
        imageBytes: Uint8List.fromList(<int>[1, 2, 3, 4]),
        userPrompt: 'Extract prescription medicine JSON.',
        routingMode: OcrRoutingMode.hybridAuto,
        featureTag: 'rx_scan',
      );

      expect(
        result.aiResponse,
        equals('{"medicine":"Amoxicillin 500mg","frequency":"BD"}'),
      );
      expect(result.usedVisionFallback, isFalse);
      expect(result.keyIdUsed, equals('key-2-gemini-healthy'));
      expect(result.attemptsUsed, equals(2));
      expect(fakeManager.failedIds, contains('key-1-rate-limited:429:rx_scan'));
      expect(fakeManager.succeededIds, contains('key-2-gemini-healthy'));
      expect(result.tokenSavings.estimatedTokensSaved, greaterThan(1400));
      expect(result.tokenSavings.savingsPercentage, greaterThan(85.0));
    });

    test(
        'hybridAuto falls back to multimodal vision bytes when on-device OCR detects no text',
        () async {
      final fakeManager = _FakeApiKeyManager(<_FakeApiKey>[
        const _FakeApiKey(
          id: 'key-vision-1',
          name: 'OpenRouter Vision',
          key: 'sk-or-vision',
          baseUrl: 'https://openrouter.ai/api/v1',
          model: 'openai/gpt-4o-mini',
          provider: 'openrouter',
        ),
      ]);

      final extractor = MultilingualOcrExtractor(
        tempDirOverride: tempDir,
        scriptRunner: (_, __) async => const ScriptOcrPass(text: ''),
      );

      bool sawImageUrlPart = false;
      final mockHttp = MockClient((http.Request request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        final messages = body['messages'] as List<dynamic>;
        final userMsg = messages.last as Map<String, dynamic>;
        final content = userMsg['content'] as List<dynamic>;
        sawImageUrlPart = content.any(
          (item) => (item as Map<String, dynamic>)['type'] == 'image_url',
        );
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content': 'Handwritten note decoded via vision fallback',
                },
              },
            ],
          }),
          200,
        );
      });

      final bridge = SmartOcrAiBridge(
        ocrExtractor: extractor,
        httpClient: mockHttp,
      )..bindApiKeyManager(fakeManager);

      final result = await bridge.analyzeImage(
        imageBytes: Uint8List.fromList(<int>[10, 20, 30]),
        userPrompt: 'Read this handwritten note.',
        routingMode: OcrRoutingMode.hybridAuto,
      );

      expect(sawImageUrlPart, isTrue);
      expect(result.usedVisionFallback, isTrue);
      expect(result.tokenSavings.estimatedTokensSaved, equals(0));
      expect(
        result.aiResponse,
        equals('Handwritten note decoded via vision fallback'),
      );
    });

    test(
        '0-token cache serves repeat scan in 0 API calls and analyzeImageAsJson parses fenced JSON',
        () async {
      int httpCallCount = 0;
      final fakeManager = _FakeApiKeyManager(<_FakeApiKey>[
        const _FakeApiKey(
          id: 'key-json-1',
          name: 'OpenRouter JSON',
          key: 'sk-json-1',
          baseUrl: 'https://openrouter.ai/api/v1',
          model: 'openai/gpt-4o-mini',
          provider: 'openrouter',
        ),
      ]);

      final extractor = MultilingualOcrExtractor(
        tempDirOverride: tempDir,
        scriptRunner: (script, _) async {
          if (script.name == 'latin') {
            return const ScriptOcrPass(
              text:
                  'Store: Apollo Pharmacy\nDate: 26/11/2026\nTotal: ₹850.50\nSupport: help@apollo.in\nCall: +91 9876543210',
            );
          }
          return const ScriptOcrPass(text: '');
        },
      );

      final mockHttp = MockClient((http.Request request) async {
        httpCallCount++;
        return http.Response(
          jsonEncode(<String, dynamic>{
            'choices': <Map<String, dynamic>>[
              <String, dynamic>{
                'message': <String, dynamic>{
                  'content':
                      '```json\n{"merchant":"Apollo Pharmacy","total":850.50}\n```',
                },
              },
            ],
          }),
          200,
        );
      });

      final bridge = SmartOcrAiBridge(
        ocrExtractor: extractor,
        httpClient: mockHttp,
      )..bindApiKeyManager(fakeManager);

      // First call hits HTTP endpoint and parses markdown-fenced JSON
      final jsonMap = await bridge.analyzeImageAsJson(
        imageBytes: Uint8List.fromList(<int>[1, 2, 3]),
        userPrompt: 'Extract merchant and total.',
      );
      expect(jsonMap['merchant'], equals('Apollo Pharmacy'));
      expect(jsonMap['total'], equals(850.50));
      expect(httpCallCount, equals(1));

      // Repeat call with identical prompt & OCR text returns from 0-token cache!
      final cachedResult = await bridge.analyzeImage(
        imageBytes: Uint8List.fromList(<int>[1, 2, 3]),
        userPrompt:
            'Extract merchant and total.\nReturn ONLY a valid JSON object without markdown commentary.',
        systemPrompt:
            'You are a strict JSON extraction engine. Respond ONLY with valid JSON.',
      );
      expect(cachedResult.fromCache, isTrue);
      expect(cachedResult.tokenSavings.actualPromptTokens, equals(0));
      expect(cachedResult.tokenSavings.savingsPercentage, equals(100.0));
      expect(httpCallCount, equals(1)); // Still 1 HTTP call!

      // Also verify offline SmartEntityExtractor detected email, amount, date, and phone
      final types = cachedResult.detectedEntities.map((e) => e.type).toSet();
      expect(
        types,
        containsAll(<SmartEntityType>[
          SmartEntityType.email,
          SmartEntityType.amount,
          SmartEntityType.date,
          SmartEntityType.phone,
        ]),
      );
    });
  });
}
