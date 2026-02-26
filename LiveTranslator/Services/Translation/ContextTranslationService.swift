import Foundation

/// 재벌 번역 서비스
/// gemini-3-pro-preview를 이용한 맥락 기반 정교 번역 (3초 이내 목표)
class ContextTranslationService: TranslationProvider {
    var name: String { "Context Translation (gemini-3-pro-preview)" }

    private static let model = "gemini-3-pro-preview"
    private static let systemPrompt = "You are an expert English to Korean translator for live conference interpretation. Translate the given English sentence to natural Korean, considering the previous conversation context. Output only the Korean translation."

    /// 타임아웃 5초 (정확한 번역 우선)
    private let client = GeminiAPIClient(timeoutInterval: 5.0)

    /// 맥락에 포함할 최대 문장 수
    private let maxContextSize = 10

    /// 맥락을 포함하여 영어 문장을 한국어로 정교하게 번역한다.
    /// - Parameters:
    ///   - text: 번역할 영어 문장
    ///   - context: 이전 번역 쌍 (최근 5~10개 문장)
    /// - Returns: 번역된 한국어 텍스트
    func translate(text: String, context: [TranslationContext]? = nil) async throws -> String {
        let userMessage = buildUserMessage(text: text, context: context)

        return try await client.generateContent(
            model: ContextTranslationService.model,
            systemPrompt: ContextTranslationService.systemPrompt,
            userMessage: userMessage,
            temperature: 0.3,
            maxOutputTokens: 1024
        )
    }

    /// 맥락 정보를 포함한 사용자 메시지를 구성한다.
    /// - Parameters:
    ///   - text: 번역할 현재 문장
    ///   - context: 이전 번역 쌍
    /// - Returns: 맥락이 포함된 사용자 메시지
    private func buildUserMessage(text: String, context: [TranslationContext]?) -> String {
        guard let context = context, !context.isEmpty else {
            return text
        }

        // 최근 N개 문장만 사용
        let recentContext = context.suffix(maxContextSize)

        var message = "Previous conversation context:\n"
        for entry in recentContext {
            message += "EN: \(entry.source)\n"
            message += "KO: \(entry.translation)\n"
        }
        message += "\nTranslate this sentence:\n\(text)"

        return message
    }
}
