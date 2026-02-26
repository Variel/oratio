import Foundation

// MARK: - Gemini API Error Types

/// Gemini API 관련 에러
enum GeminiAPIError: LocalizedError {
    case apiKeyMissing
    case invalidURL
    case networkError(Error)
    case httpError(statusCode: Int, message: String)
    case decodingError(Error)
    case emptyResponse
    case timeout

    var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "Gemini API 키가 설정되지 않았습니다. 설정에서 API 키를 입력해주세요."
        case .invalidURL:
            return "잘못된 API URL입니다."
        case .networkError(let error):
            return "네트워크 에러: \(error.localizedDescription)"
        case .httpError(let statusCode, let message):
            return "HTTP 에러 (\(statusCode)): \(message)"
        case .decodingError(let error):
            return "응답 파싱 에러: \(error.localizedDescription)"
        case .emptyResponse:
            return "API 응답이 비어있습니다."
        case .timeout:
            return "API 요청 시간이 초과되었습니다."
        }
    }
}

// MARK: - Gemini API Request/Response Models

/// Gemini API 요청 모델
struct GeminiRequest: Encodable {
    let contents: [GeminiContent]
    let systemInstruction: GeminiContent?
    let generationConfig: GeminiGenerationConfig?

    enum CodingKeys: String, CodingKey {
        case contents
        case systemInstruction = "system_instruction"
        case generationConfig
    }
}

/// Gemini 콘텐츠 모델
struct GeminiContent: Codable {
    let role: String?
    let parts: [GeminiPart]

    init(role: String? = nil, parts: [GeminiPart]) {
        self.role = role
        self.parts = parts
    }
}

/// Gemini 파트 모델
struct GeminiPart: Codable {
    let text: String?

    init(text: String) {
        self.text = text
    }
}

/// Gemini thinking 설정
/// - gemini-2.5 계열: thinkingBudget = 0으로 thinking 완전 비활성화 가능
/// - gemini-3 계열: thinkingBudget = 0 불가, thinkingLevel = "LOW"로 최소화
struct GeminiThinkingConfig: Encodable {
    let thinkingBudget: Int?
    let thinkingLevel: String?

    enum CodingKeys: String, CodingKey {
        case thinkingBudget
        case thinkingLevel
    }

    /// gemini-2.5 계열용: thinking 완전 비활성화
    static let disableThinking = GeminiThinkingConfig(thinkingBudget: 0, thinkingLevel: nil)

    /// gemini-3 계열용: thinking 최소화 (완전 비활성화 불가)
    static let minimizeThinking = GeminiThinkingConfig(thinkingBudget: nil, thinkingLevel: "LOW")
}

/// Gemini 생성 설정
struct GeminiGenerationConfig: Encodable {
    let temperature: Double?
    let maxOutputTokens: Int?
    let thinkingConfig: GeminiThinkingConfig?

    enum CodingKeys: String, CodingKey {
        case temperature
        case maxOutputTokens
        case thinkingConfig
    }

    init(temperature: Double? = nil, maxOutputTokens: Int? = nil, thinkingConfig: GeminiThinkingConfig? = nil) {
        self.temperature = temperature
        self.maxOutputTokens = maxOutputTokens
        self.thinkingConfig = thinkingConfig
    }
}

/// Gemini API 응답 모델
struct GeminiResponse: Decodable {
    let candidates: [GeminiCandidate]?
    let error: GeminiErrorResponse?
}

/// Gemini 응답 후보
struct GeminiCandidate: Decodable {
    let content: GeminiContent?
}

/// Gemini API 에러 응답
struct GeminiErrorResponse: Decodable {
    let code: Int?
    let message: String?
    let status: String?
}

// MARK: - Gemini API Client

/// Gemini REST API 공통 클라이언트
/// URLSession 기반, 외부 라이브러리 미사용
final class GeminiAPIClient {
    private static let baseURL = "https://generativelanguage.googleapis.com/v1beta/models"

    private let session: URLSession

    /// 지정된 타임아웃으로 클라이언트를 생성한다.
    /// - Parameter timeoutInterval: 요청 타임아웃 (초)
    init(timeoutInterval: TimeInterval) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeoutInterval
        configuration.timeoutIntervalForResource = timeoutInterval
        self.session = URLSession(configuration: configuration)
    }

    /// Gemini API에 텍스트 생성 요청을 보낸다.
    /// - Parameters:
    ///   - model: Gemini 모델 이름 (예: "gemini-2.5-flash-lite")
    ///   - systemPrompt: 시스템 프롬프트 (옵션)
    ///   - userMessage: 사용자 메시지
    ///   - temperature: 생성 온도 (옵션)
    ///   - maxOutputTokens: 최대 출력 토큰 수 (옵션)
    /// - Returns: 생성된 텍스트
    func generateContent(
        model: String,
        systemPrompt: String? = nil,
        userMessage: String,
        temperature: Double? = nil,
        maxOutputTokens: Int? = nil
    ) async throws -> String {
        // API 키 확인
        let apiKey = AppSettings.shared.geminiApiKey
        guard !apiKey.isEmpty else {
            throw GeminiAPIError.apiKeyMissing
        }

        // URL 생성
        let urlString = "\(GeminiAPIClient.baseURL)/\(model):generateContent"
        guard let url = URL(string: urlString) else {
            throw GeminiAPIError.invalidURL
        }

        // 요청 본문 구성
        let systemInstruction: GeminiContent? = systemPrompt.map {
            GeminiContent(parts: [GeminiPart(text: $0)])
        }

        let contents = [
            GeminiContent(role: "user", parts: [GeminiPart(text: userMessage)])
        ]

        // 모델별 thinking 설정:
        // - gemini-3 계열: thinkingBudget=0 사용 불가, thinkingLevel="LOW"로 최소화
        // - gemini-2.5 계열: thinkingBudget=0으로 완전 비활성화
        let thinkingConfig: GeminiThinkingConfig = model.hasPrefix("gemini-3")
            ? .minimizeThinking
            : .disableThinking

        var generationConfig: GeminiGenerationConfig? = nil
        if temperature != nil || maxOutputTokens != nil {
            generationConfig = GeminiGenerationConfig(
                temperature: temperature,
                maxOutputTokens: maxOutputTokens,
                thinkingConfig: thinkingConfig
            )
        }

        let requestBody = GeminiRequest(
            contents: contents,
            systemInstruction: systemInstruction,
            generationConfig: generationConfig
        )

        // HTTP 요청 생성 (API 키는 헤더로 전달)
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")

        let encoder = JSONEncoder()
        request.httpBody = try encoder.encode(requestBody)

        // API 호출
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .timedOut {
            throw GeminiAPIError.timeout
        } catch {
            throw GeminiAPIError.networkError(error)
        }

        // HTTP 상태 코드 확인
        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            // 에러 응답 파싱 시도
            let errorMessage: String
            if let geminiResponse = try? JSONDecoder().decode(GeminiResponse.self, from: data),
               let apiError = geminiResponse.error {
                errorMessage = apiError.message ?? "Unknown API error"
            } else {
                errorMessage = String(data: data, encoding: .utf8) ?? "Unknown error"
            }
            throw GeminiAPIError.httpError(
                statusCode: httpResponse.statusCode,
                message: errorMessage
            )
        }

        // 응답 파싱
        let geminiResponse: GeminiResponse
        do {
            geminiResponse = try JSONDecoder().decode(GeminiResponse.self, from: data)
        } catch {
            throw GeminiAPIError.decodingError(error)
        }

        // 텍스트 추출
        guard let candidate = geminiResponse.candidates?.first,
              let content = candidate.content,
              let text = content.parts.first?.text,
              !text.isEmpty else {
            throw GeminiAPIError.emptyResponse
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
