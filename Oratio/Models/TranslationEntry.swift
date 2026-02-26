import Foundation

/// 번역 항목 데이터 모델
/// 각 인식된 문장/구에 대한 원문과 번역 결과를 담는다.
struct TranslationEntry: Identifiable {
    let id: UUID
    var originalText: String          // 영어 원문
    var quickTranslation: String?     // 초벌 번역 (gemini-2.5-flash-lite)
    var quickTranslationSourceText: String? // 현재 quickTranslation이 생성된 기준 원문
    var contextTranslation: String?   // 재벌 번역 (gemini-3-pro-preview)
    var timestamp: Date               // 생성 시간
    var isFinalized: Bool             // 문장 완성 여부

    init(
        id: UUID = UUID(),
        originalText: String,
        quickTranslation: String? = nil,
        quickTranslationSourceText: String? = nil,
        contextTranslation: String? = nil,
        timestamp: Date = Date(),
        isFinalized: Bool = false
    ) {
        self.id = id
        self.originalText = originalText
        self.quickTranslation = quickTranslation
        self.quickTranslationSourceText = quickTranslationSourceText
        self.contextTranslation = contextTranslation
        self.timestamp = timestamp
        self.isFinalized = isFinalized
    }

    /// 현재 표시할 번역 텍스트 (재벌 번역 우선)
    var displayTranslation: String? {
        contextTranslation ?? quickTranslation
    }

    /// 번역 상태
    var translationState: TranslationState {
        if contextTranslation != nil {
            return .contextCompleted
        } else if quickTranslation != nil {
            return .quickCompleted
        } else {
            return .pending
        }
    }
}

/// 번역 진행 상태
enum TranslationState {
    case pending            // 번역 대기 중
    case quickCompleted     // 초벌 번역 완료
    case contextCompleted   // 재벌 번역 완료
}
