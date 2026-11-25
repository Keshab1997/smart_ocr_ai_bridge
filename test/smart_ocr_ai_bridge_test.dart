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
  });
}
