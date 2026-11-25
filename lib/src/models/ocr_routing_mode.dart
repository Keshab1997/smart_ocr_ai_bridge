/// Controls how `SmartOcrAiBridge` routes an image to the AI model to
/// minimize token usage.
enum OcrRoutingMode {
  /// **Maximum Token Savings (~85–95% cheaper)**:
  /// Runs 5-script on-device ML Kit OCR first, compacts the text, and sends
  /// ONLY the text + prompt to the LLM. Works with any text-only model
  /// (DeepSeek, Llama, Qwen, Gemini Flash, GPT-4o-mini).
  textOnly,

  /// **Smart Hybrid Auto-Fallback (Recommended)**:
  /// Runs on-device 5-script OCR first. If `ocrScore >= minOcrScoreForTextOnly`
  /// (clear printed text, receipts, documents, prescriptions), sends ONLY
  /// the compacted text (~90% token savings). If the score is below the
  /// threshold (e.g. blurry handwriting or diagram with no text), automatically
  /// falls back to sending the image bytes to a multimodal vision endpoint.
  hybridAuto,

  /// **Structured Layout Blocks (Token Saver + Spatial Context)**:
  /// Sends the on-device OCR text organized into numbered spatial blocks
  /// (`[Block 1]`, `[Block 2]`) so the LLM understands tables, headers, and
  /// columns without needing vision tokens.
  structuredBlocks,

  /// **Direct Vision Mode**:
  /// Sends the image directly as base64 multimodal input (along with any
  /// extracted OCR text as a hint).
  visionOnly,
}
