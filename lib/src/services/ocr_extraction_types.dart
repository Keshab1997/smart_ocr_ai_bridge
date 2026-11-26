import 'dart:typed_data';

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

/// Script identifiers matching ML Kit Text Recognition v2 scripts without
/// pulling native-only `dart:io` imports into web builds.
enum OcrScript {
  latin,
  chinese,
  devanagiri,
  japanese,
  korean,
}

typedef ScriptPassRunner = Future<ScriptOcrPass> Function(
  OcrScript script,
  Object inputImage,
);

/// Picks the highest-scoring [OcrExtractionResult] from concurrent script passes.
Future<OcrExtractionResult> runScriptPasses({
  required List<OcrScript> scripts,
  required Object inputImage,
  required ScriptPassRunner runner,
}) async {
  final futures = scripts.map((script) async {
    try {
      final pass = await runner(script, inputImage);
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
    blocks:
        bestPass.blocks.isNotEmpty ? bestPass.blocks : <String>[bestPass.text],
    score: bestScore,
  );
}

/// Abstract contract for platform OCR extraction.
abstract interface class PlatformOcrExtractor {
  Future<OcrExtractionResult> extractFromFilePath(String path);
  Future<OcrExtractionResult> extractFromBytes(Uint8List bytes);
}
