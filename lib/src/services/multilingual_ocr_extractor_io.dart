import 'dart:io';
import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:path_provider/path_provider.dart';

import 'ocr_extraction_types.dart';

TextRecognitionScript _toMlKitScript(OcrScript script) => switch (script) {
      OcrScript.latin => TextRecognitionScript.latin,
      OcrScript.chinese => TextRecognitionScript.chinese,
      OcrScript.devanagiri => TextRecognitionScript.devanagiri,
      OcrScript.japanese => TextRecognitionScript.japanese,
      OcrScript.korean => TextRecognitionScript.korean,
    };

/// Default on-device ML Kit script pass runner for Android/iOS (`dart:io`).
Future<ScriptOcrPass> defaultPlatformScriptRunner(
  OcrScript script,
  Object inputImage,
) async {
  final recognizer = TextRecognizer(script: _toMlKitScript(script));
  try {
    final recognized = await recognizer.processImage(inputImage as InputImage);
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

/// Extracts text from a local file path on `dart:io` platforms.
Future<OcrExtractionResult> extractPlatformFromFilePath({
  required String path,
  required List<OcrScript> scripts,
  required ScriptPassRunner runner,
}) async {
  final file = File(path);
  if (!file.existsSync()) {
    throw FileSystemException('Image file does not exist', path);
  }
  return runScriptPasses(
    scripts: scripts,
    inputImage: InputImage.fromFilePath(path),
    runner: runner,
  );
}

/// Extracts text from image bytes via a temporary file on `dart:io` platforms.
Future<OcrExtractionResult> extractPlatformFromBytes({
  required Uint8List bytes,
  required List<OcrScript> scripts,
  required ScriptPassRunner runner,
  Object? tempDirOverride,
}) async {
  final dir = tempDirOverride is Directory
      ? tempDirOverride
      : await getTemporaryDirectory();
  final ts = DateTime.now().microsecondsSinceEpoch;
  final tempFile = File('${dir.path}/smart_ocr_$ts.jpg');
  tempFile.writeAsBytesSync(bytes, flush: true);
  try {
    return await runScriptPasses(
      scripts: scripts,
      inputImage: InputImage.fromFilePath(tempFile.path),
      runner: runner,
    );
  } finally {
    if (tempFile.existsSync()) {
      try {
        tempFile.deleteSync();
      } catch (_) {}
    }
  }
}

/// Reads raw bytes from a local file path on `dart:io` platforms.
Future<Uint8List> readPlatformFileBytes(String path) =>
    File(path).readAsBytes();
