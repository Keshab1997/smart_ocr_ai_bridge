import 'dart:io';
import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

import 'ocr_text_optimizer.dart';

/// Output from a single script recognizer including both full text and spatial blocks.
class ScriptOcrPass {
  const ScriptOcrPass({
    required this.text,
    this.blocks = const <String>[],
  });

  final String text;
  final List<String> blocks;
}

/// Complete extraction result from the 5-script on-device ML Kit pipeline.
class OcrExtractionResult {
  const OcrExtractionResult({
    required this.bestText,
    required this.blocks,
    required this.score,
  });

  final String bestText;
  final List<String> blocks;
  final int score;

  bool get hasText => bestText.trim().isNotEmpty;
}

typedef ScriptPassRunner = Future<ScriptOcrPass> Function(
  TextRecognitionScript script,
  InputImage inputImage,
);

/// Runs all 5 Google ML Kit Text Recognition v2 scripts concurrently on-device
/// (0 API cost, offline) and picks the highest-scoring script output.
class MultilingualOcrExtractor {
  MultilingualOcrExtractor({
    ScriptPassRunner? scriptRunner,
    Directory? tempDirOverride,
  })  : _scriptRunner = scriptRunner ?? _defaultScriptRunner,
        _tempDirOverride = tempDirOverride;

  final ScriptPassRunner _scriptRunner;
  final Directory? _tempDirOverride;

  static const List<TextRecognitionScript> scripts = <TextRecognitionScript>[
    TextRecognitionScript.latin,
    TextRecognitionScript.chinese,
    TextRecognitionScript.devanagiri,
    TextRecognitionScript.japanese,
    TextRecognitionScript.korean,
  ];

  static Future<ScriptOcrPass> _defaultScriptRunner(
    TextRecognitionScript script,
    InputImage inputImage,
  ) async {
    final recognizer = TextRecognizer(script: script);
    try {
      final recognized = await recognizer.processImage(inputImage);
      final blockStrings = recognized.blocks
          .map((b) => b.text.trim())
          .where((t) => t.isNotEmpty)
          .toList(growable: false);
      return ScriptOcrPass(
        text: recognized.text.trim(),
        blocks: blockStrings,
      );
    } finally {
      await recognizer.close();
    }
  }

  /// Runs all 5 script recognisers concurrently on [inputImage] and returns
  /// the highest-scoring [OcrExtractionResult] (ties broken in favour of the
  /// first script in [scripts]).
  Future<OcrExtractionResult> extractFromInputImage(
    InputImage inputImage,
  ) async {
    final futures = scripts.map((script) async {
      try {
        final pass = await _scriptRunner(script, inputImage);
        final trimmed = pass.text.trim();
        if (trimmed.isEmpty) return null;
        return ScriptOcrPass(text: trimmed, blocks: pass.blocks);
      } catch (_) {
        return null;
      }
    }).toList(growable: false);

    final passes =
        (await Future.wait<ScriptOcrPass?>(futures)).whereType<ScriptOcrPass>();

    ScriptOcrPass? bestPass;
    int? bestScore;
    for (final pass in passes) {
      final score = calculateOcrScore(pass.text);
      if (bestScore == null || score > bestScore) {
        bestScore = score;
        bestPass = pass;
      }
    }

    if (bestPass == null || bestScore == null) {
      return const OcrExtractionResult(
        bestText: '',
        blocks: <String>[],
        score: 0,
      );
    }

    return OcrExtractionResult(
      bestText: bestPass.text,
      blocks: bestPass.blocks.isNotEmpty
          ? bestPass.blocks
          : <String>[bestPass.text],
      score: bestScore,
    );
  }

  /// Extracts text from an image file path on disk.
  Future<OcrExtractionResult> extractFromFilePath(String path) async {
    final file = File(path);
    if (!file.existsSync()) {
      throw FileSystemException('Image file does not exist', path);
    }
    return extractFromInputImage(InputImage.fromFilePath(path));
  }

  /// Extracts text from in-memory image bytes (JPEG/PNG).
  Future<OcrExtractionResult> extractFromBytes(Uint8List bytes) async {
    if (bytes.isEmpty) {
      throw ArgumentError('Image bytes are empty');
    }
    final dir = _tempDirOverride ?? await getTemporaryDirectory();
    final ts = DateTime.now().microsecondsSinceEpoch;
    final tempFile = File('${dir.path}/smart_ocr_$ts.jpg');
    tempFile.writeAsBytesSync(bytes, flush: true);
    try {
      return await extractFromInputImage(
          InputImage.fromFilePath(tempFile.path));
    } finally {
      if (tempFile.existsSync()) {
        try {
          tempFile.deleteSync();
        } catch (_) {}
      }
    }
  }
}
