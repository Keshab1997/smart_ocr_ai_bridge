# smart_ocr_ai_bridge

A drop-in **Flutter package** that combines **5-script on-device Google ML Kit OCR** (`Latin`, `Chinese`, `Devanagari`, `Japanese`, `Korean`) with **`admin_api_key_manager`** pool rotation and automatic failover to cut LLM Vision token usage by **85%–95%**.

Instead of uploading a 1,500+ token base64 image on every AI call, `smart_ocr_ai_bridge` extracts and compacts text on-device in ~200 ms (0 API tokens, offline-capable) and sends only the compacted text (or spatial layout blocks) to your `ApiKeyManager.instance` key pool — automatically falling back to multimodal vision only when an image has low/no readable text.

---

## Why Use `smart_ocr_ai_bridge`?

- **~90% Token Savings**: A standard camera photo costs ~1,550 vision tokens; compacted OCR text of a receipt, prescription, book page, or screenshot typically costs only 60–180 text tokens.
- **Unlocks Text-Only Free/Cheap Models for Image Tasks**: Because on-device OCR turns images into structured text first, text-only models in your `admin_api_key_manager` pool (DeepSeek, Llama-3.3, Qwen, Gemini Flash) can now handle document/image analysis!
- **Smart Hybrid Fallback (`OcrRoutingMode.hybridAuto`)**:
  - If `ocrScore >= minOcrScoreForTextOnly` → sends **text-only** (saving ~90% tokens).
  - If `ocrScore < minOcrScoreForTextOnly` (e.g. blurry handwriting or pure diagram) → automatically falls back to sending base64 vision bytes!
- **Native `admin_api_key_manager` Integration**:
  - Binds directly to `ApiKeyManager.instance` (`getNextKey()`, `reportSuccess(key)`, `reportFailure(key, statusCode, featureTag, userId)`).
  - Supports both **Google Gemini** (`/v1beta/models/...:generateContent`) and **OpenRouter / Custom OpenAI** (`/chat/completions`) keys out of the box.
- **Built-in Token Savings Telemetry**: Every call returns `result.tokenSavings` (`estimatedVisionTokens`, `actualPromptTokens`, `estimatedTokensSaved`, `savingsPercentage`, `summaryLabel`).

---

## Installation

Add to any Flutter project's `pubspec.yaml`:

```yaml
dependencies:
  admin_api_key_manager:
    git:
      url: https://github.com/Keshab1997/admin_api_key_manager.git
      ref: master
  smart_ocr_ai_bridge:
    git:
      url: https://github.com/Keshab1997/smart_ocr_ai_bridge.git
      ref: main
```

Then run:

```bash
flutter pub get
```

---

## Android setup — required, or 4 of the 5 scripts silently do nothing

`google_mlkit_text_recognition` declares the four non-Latin script artifacts as
**`compileOnly`**. They reach the compile classpath but are **never packaged
into your APK** — the host app has to bring them in itself. A package cannot do
this on your behalf, so every app that depends on `smart_ocr_ai_bridge` needs
these four lines in its **own** `android/app/build.gradle(.kts)`:

```kotlin
dependencies {
    implementation("com.google.mlkit:text-recognition-chinese:16.0.1")
    implementation("com.google.mlkit:text-recognition-devanagari:16.0.1")
    implementation("com.google.mlkit:text-recognition-japanese:16.0.1")
    implementation("com.google.mlkit:text-recognition-korean:16.0.1")
}
```

(Groovy `build.gradle` is the same, with `implementation "…"` instead.)

Without them only `latin` exists in the build, and the failure is quiet rather
than loud, because `MultilingualOcrExtractor` wraps each script pass in its own
`try/catch`: the Chinese recogniser throws
`NoClassDefFoundError: ...vision.text.chinese.ChineseTextRecognizerOptions$Builder`
the moment it runs, the catch swallows it, and `extractFromInputImage` returns
a perfectly valid result scored from **latin text only**. Bengali, Hindi,
Chinese, Japanese and Korean scans then look like "no text detected".

Symptom to look for in `adb logcat`:

```
NoClassDefFoundError: Failed resolution of:
  Lcom/google/mlkit/vision/text/chinese/ChineseTextRecognizerOptions$Builder;
```

These are the **bundled-model** artifacts: the models ship inside the APK and
work offline, but they add roughly 2 MB per script. If APK size matters more
than offline first-run, swap them for the Play-Services variants
(`com.google.android.gms:play-services-mlkit-text-recognition-*`), which
download models on demand.

**Verify the build actually has them** instead of trusting the Gradle file — a
rename can still happen later, and a name-only check is what misses this bug:

```bash
# one entry per script should be listed
unzip -l build/app/outputs/flutter-apk/app-release.apk \
  | grep mlkit-google-ocr-models | grep -c gocr
```

---

## Quick Start

### 1. Bind `ApiKeyManager.instance` once at startup (e.g. in `main.dart`)

```dart
import 'package:admin_api_key_manager/admin_api_key_manager.dart';
import 'package:smart_ocr_ai_bridge/smart_ocr_ai_bridge.dart';

Future<void> initAiServices() async {
  await KeyCache.init();
  await ApiKeyManager.instance.initialize();

  // Connect SmartOcrAiBridge to your Firestore-backed key pool:
  SmartOcrAiBridge.instance.bindApiKeyManager(ApiKeyManager.instance);
}
```

### 2. Analyze any image with ~90% fewer tokens

```dart
final result = await SmartOcrAiBridge.instance.analyzeImage(
  imageFile: pickedImageFile,
  systemPrompt: 'You are a medical prescription & document assistant.',
  userPrompt: 'Extract all medicine names, dosage, and instructions as JSON.',
  routingMode: OcrRoutingMode.hybridAuto,
  featureTag: 'prescription_scan',
);

print(result.aiResponse);
// -> {"medicines": [...]}

print(result.tokenSavings.summaryLabel);
// -> "Saved ~1460 tokens (91.8% reduction)"
```

### 3. Or analyze already-extracted OCR text directly

```dart
final result = await SmartOcrAiBridge.instance.analyzeExtractedText(
  extractedText: textController.text,
  userPrompt: 'Summarize this text in Bengali and bullet points.',
  featureTag: 'snaptext_summary',
);
```

---

## Routing Modes (`OcrRoutingMode`)

| Mode | Behaviour | Token Cost |
|---|---|---|
| `OcrRoutingMode.textOnly` | Always sends compacted on-device OCR text only | **Lowest (~50–200 tokens)** |
| `OcrRoutingMode.hybridAuto` *(Default)* | Sends text-only when `ocrScore >= threshold`; auto-falls back to vision bytes when low/blank | **~90% cheaper on documents, 100% resilient on handwriting** |
| `OcrRoutingMode.structuredBlocks` | Formats spatial OCR blocks (`[Block 1]`, `[Block 2]`) for receipts/tables | **Low (~70–230 tokens)** |
| `OcrRoutingMode.visionOnly` | Always sends multimodal image bytes + OCR hint | Standard Vision cost (~1,550+ tokens) |
