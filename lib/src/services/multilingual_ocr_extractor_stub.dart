import 'dart:typed_data';

import 'ocr_extraction_types.dart';

/// Web fallback: ML Kit native channels do not exist in browsers, so on-device
/// OCR returns an empty pass (`score: 0`) and `OcrRoutingMode.hybridAuto`
/// seamlessly falls back to multimodal Vision AI.
Future<ScriptOcrPass> defaultPlatformScriptRunner(
  OcrScript script,
  Object inputImage,
) async =>
    const ScriptOcrPass(text: '');

/// Extracts text on web (uses custom [runner] if injected, else empty pass).
Future<OcrExtractionResult> extractPlatformFromFilePath({
  required String path,
  required List<OcrScript> scripts,
  required ScriptPassRunner runner,
}) =>
    runScriptPasses(
      scripts: scripts,
      inputImage: path,
      runner: runner,
    );

/// Extracts text from bytes on web (uses custom [runner] if injected, else empty pass).
Future<OcrExtractionResult> extractPlatformFromBytes({
  required Uint8List bytes,
  required List<OcrScript> scripts,
  required ScriptPassRunner runner,
  Object? tempDirOverride,
}) =>
    runScriptPasses(
      scripts: scripts,
      inputImage: bytes,
      runner: runner,
    );

/// Web stub: pass `imageBytes` directly on web instead of a local file path.
Future<Uint8List> readPlatformFileBytes(String path) => throw UnsupportedError(
    'Pass imageBytes instead of imageFile on Flutter Web.');
