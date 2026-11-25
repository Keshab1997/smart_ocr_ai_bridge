/// smart_ocr_ai_bridge
///
/// A drop-in Flutter package combining 5-script on-device ML Kit OCR with
/// `admin_api_key_manager` key-pool rotation to reduce LLM vision token usage
/// by ~85–95%.
library smart_ocr_ai_bridge;

export 'src/models/bridge_key.dart';
export 'src/models/ocr_routing_mode.dart';
export 'src/models/smart_ocr_ai_result.dart';
export 'src/services/key_pool_adapter.dart';
export 'src/services/multilingual_ocr_extractor.dart';
export 'src/services/ocr_text_optimizer.dart';
export 'src/services/smart_ocr_ai_bridge_client.dart';
