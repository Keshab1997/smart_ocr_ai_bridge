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
