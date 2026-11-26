import 'dart:typed_data';

import 'multilingual_ocr_extractor_stub.dart'
    if (dart.library.io) 'multilingual_ocr_extractor_io.dart';
import 'ocr_extraction_types.dart';

export 'multilingual_ocr_extractor_stub.dart'
    if (dart.library.io) 'multilingual_ocr_extractor_io.dart'
    show readPlatformFileBytes;
export 'ocr_extraction_types.dart';

/// Runs all 5 Google ML Kit Text Recognition v2 scripts concurrently on-device
/// (0 API cost, offline) and picks the highest-scoring script output.
///
/// On Flutter Web (where ML Kit native channels do not exist), returns an empty
/// OCR pass (`score: 0`) so `OcrRoutingMode.hybridAuto` seamlessly falls back
/// to multimodal Vision AI.
class MultilingualOcrExtractor implements PlatformOcrExtractor {
  MultilingualOcrExtractor({
    ScriptPassRunner? scriptRunner,
    Object? tempDirOverride,
  })  : _scriptRunner = scriptRunner ?? defaultPlatformScriptRunner,
        _tempDirOverride = tempDirOverride;

  final ScriptPassRunner _scriptRunner;
  final Object? _tempDirOverride;

  static const List<OcrScript> scripts = <OcrScript>[
    OcrScript.latin,
    OcrScript.chinese,
    OcrScript.devanagiri,
    OcrScript.japanese,
    OcrScript.korean,
  ];

  /// Runs all 5 script recognisers concurrently on [inputImage] and returns
  /// the highest-scoring [OcrExtractionResult] (ties broken in favour of the
  /// first script in [scripts]).
  Future<OcrExtractionResult> extractFromInputImage(Object inputImage) =>
      runScriptPasses(
        scripts: scripts,
        inputImage: inputImage,
        runner: _scriptRunner,
      );

  /// Extracts text from an image file path on disk.
  @override
  Future<OcrExtractionResult> extractFromFilePath(String path) =>
      extractPlatformFromFilePath(
        path: path,
        scripts: scripts,
        runner: _scriptRunner,
      );

  /// Extracts text from in-memory image bytes (JPEG/PNG).
  @override
  Future<OcrExtractionResult> extractFromBytes(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw ArgumentError('Image bytes are empty');
    }
    return extractPlatformFromBytes(
      bytes: bytes,
      scripts: scripts,
      runner: _scriptRunner,
      tempDirOverride: _tempDirOverride,
    );
  }
}
