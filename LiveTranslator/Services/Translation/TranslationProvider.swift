import Foundation

/// 번역 맥락 정보
/// 이전 문장의 원문과 번역 쌍을 담는다.
struct TranslationContext {
    let source: String       // 영어 원문
    let translation: String  // 한국어 번역
}

/// 번역 제공자 프로토콜
/// 초벌/재벌 번역 서비스 모두 이 프로토콜을 준수한다.
protocol TranslationProvider {
    /// 프로바이더 이름
    var name: String { get }

    /// 텍스트를 번역한다.
    /// - Parameters:
    ///   - text: 번역할 영어 텍스트
    ///   - context: 이전 번역 쌍 (맥락 정보, 옵션)
    /// - Returns: 번역된 한국어 텍스트
    func translate(text: String, context: [TranslationContext]?) async throws -> String
}
