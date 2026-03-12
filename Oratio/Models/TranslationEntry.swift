import Foundation

/// 번역 항목 데이터 모델
/// 각 인식된 문장/구에 대한 원문과 번역 결과를 담는다.
struct TranslationEntry: Identifiable {
    let id: UUID
    var originalText: String          // 영어 원문
    var translatedText: String?       // 한국어 번역 (Soniox 실시간 번역)
    var timestamp: Date               // 생성 시간
    var isFinalized: Bool             // 문장 완성 여부 (endpoint)
    var speaker: String?              // 화자 ID (Soniox diarization: "1", "2", ...)

    init(
        id: UUID = UUID(),
        originalText: String,
        translatedText: String? = nil,
        timestamp: Date = Date(),
        isFinalized: Bool = false,
        speaker: String? = nil
    ) {
        self.id = id
        self.originalText = originalText
        self.translatedText = translatedText
        self.timestamp = timestamp
        self.isFinalized = isFinalized
        self.speaker = speaker
    }
}
