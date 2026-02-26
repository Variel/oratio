import Foundation

/// 초벌 번역 서비스
/// gemini-2.5-flash-lite를 이용한 빠른 단어/구 단위 번역 (1초 이내 목표)
class QuickTranslationService: TranslationProvider {
    var name: String { "Quick Translation (gemini-2.5-flash-lite)" }

    private static let model = "gemini-2.5-flash-lite"
    private static let systemPrompt = """
    You are a fast real-time English to Korean translator for streaming ASR text.
    Preserve the original English structure and order as much as possible.
    Do not reorganize clause order for natural Korean.
    Do not summarize, omit, or add information.
    If the source sentence is incomplete, still translate literally in source order.
    Output only Korean translation.
    """

    /// 타임아웃 2초 (빠른 응답 우선)
    private let client = GeminiAPIClient(timeoutInterval: 2.0)

    /// 영어 텍스트를 한국어로 빠르게 번역한다.
    func translate(text: String, context: [TranslationContext]? = nil) async throws -> String {
        return try await client.generateContent(
            model: QuickTranslationService.model,
            systemPrompt: QuickTranslationService.systemPrompt,
            userMessage: text,
            temperature: 0.0,
            maxOutputTokens: 256
        )
    }
}
