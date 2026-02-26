import Foundation

/// 초벌 번역 서비스
/// gemini-2.5-flash-lite를 이용한 빠른 단어/구 단위 번역 (1초 이내 목표)
class QuickTranslationService: TranslationProvider {
    var name: String { "Quick Translation (gemini-2.5-flash-lite)" }

    private static let model = "gemini-2.5-flash-lite"
    private static let systemPrompt = "You are a fast English to Korean translator. Translate the given English text to Korean. Be concise and fast. Output only the Korean translation."

    /// 타임아웃 2초 (빠른 응답 우선)
    private let client = GeminiAPIClient(timeoutInterval: 2.0)

    /// 영어 텍스트를 한국어로 빠르게 번역한다.
    /// - Parameters:
    ///   - text: 번역할 영어 텍스트
    ///   - context: 사용하지 않음 (속도 우선, 맥락 불필요)
    /// - Returns: 번역된 한국어 텍스트
    func translate(text: String, context: [TranslationContext]? = nil) async throws -> String {
        return try await client.generateContent(
            model: QuickTranslationService.model,
            systemPrompt: QuickTranslationService.systemPrompt,
            userMessage: text,
            temperature: 0.1,
            maxOutputTokens: 256
        )
    }
}
