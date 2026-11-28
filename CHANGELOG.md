# Changelog

## 1.1.0

- Web support: `SmartOcrAiBridge` is now web-compatible (ML Kit paths gated to Android/iOS).
- Fixed dart2js compatibility by replacing 64-bit hex literals in `OcrPromptCache`.
- Fixed Bengali/Hindi/CJK replies: LLM HTTP response bytes are now decoded as UTF-8.
- Build artifacts gitignored.

## 1.0.0

- `SmartOcrAiBridge` with 5-script ML Kit OCR (Latin, Chinese, Devanagari, Japanese, Korean) and hybrid on-device/LLM routing.
- `admin_api_key_manager` pool rotation with automatic failover across LLM API keys.
- Zero-token LRU prompt cache (`OcrPromptCache`).
- JSON schema extractor and offline `SmartEntityExtractor`.
- README note: 4 of the 5 ML Kit scripts need Android wiring.
