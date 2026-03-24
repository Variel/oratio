import Foundation

/// 오디오 소스 구분
enum AudioSource {
    case systemAudio   // 시스템 오디오 (상대방 음성) — 영어→한국어
    case microphone    // 마이크 입력 (내 음성) — 한국어→영어
}

/// 번역 항목 데이터 모델
/// 각 인식된 문장/구에 대한 원문과 번역 결과를 담는다.
struct TranslationEntry: Identifiable {
    let id: UUID
    var originalText: String          // 원문
    var translatedText: String?       // 번역 (Soniox 실시간 번역)
    var timestamp: Date               // 생성 시간
    var isFinalized: Bool             // 문장 완성 여부 (endpoint)
    var speaker: String?              // 화자 ID (Soniox diarization: "1", "2", ...)
    var source: AudioSource           // 오디오 소스

    init(
        id: UUID = UUID(),
        originalText: String,
        translatedText: String? = nil,
        timestamp: Date = Date(),
        isFinalized: Bool = false,
        speaker: String? = nil,
        source: AudioSource = .systemAudio
    ) {
        self.id = id
        self.originalText = originalText
        self.translatedText = translatedText
        self.timestamp = timestamp
        self.isFinalized = isFinalized
        self.speaker = speaker
        self.source = source
    }
}
