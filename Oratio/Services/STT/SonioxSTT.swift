import AVFoundation
import Foundation

// MARK: - Soniox 에러

enum SonioxError: LocalizedError {
    case apiKeyMissing
    case invalidURL
    case connectionFailed(Error)
    case serverError(code: String, message: String)
    case sessionClosed
    case invalidMessage

    var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "Soniox API 키가 설정되지 않았습니다."
        case .invalidURL:
            return "Soniox WebSocket URL이 올바르지 않습니다."
        case .connectionFailed(let error):
            return "Soniox 연결 실패: \(error.localizedDescription)"
        case .serverError(_, let message):
            return "Soniox 서버 에러: \(message)"
        case .sessionClosed:
            return "Soniox 세션이 종료되었습니다."
        case .invalidMessage:
            return "Soniox 응답을 해석하지 못했습니다."
        }
    }
}

// MARK: - Soniox 토큰 업데이트 콜백 데이터

struct SonioxTokenUpdate {
    let stableText: String
    let unstableText: String
    let speaker: String?
    let isEndpoint: Bool
}

// MARK: - SonioxSTT

/// Soniox 실시간 WebSocket 기반 음성 인식 서비스
/// wss://stt-rt.soniox.com/transcribe-websocket 에 직접 연결하여 스트리밍 STT를 수행한다.
actor SonioxSTT {
    // MARK: - 상수

    static let websocketURL = "wss://stt-rt.soniox.com/transcribe-websocket"
    static let model = "stt-rt-preview"
    static let audioFormat = "pcm_s16le"
    static let sampleRate = 16_000
    static let numChannels = 1
    static let maxEndpointDelayMs = 750

    // MARK: - 콜백

    private var onTokenUpdate: ((SonioxTokenUpdate) -> Void)?
    private var onError: ((Error) -> Void)?

    // MARK: - WebSocket 상태

    private let urlSession: URLSession
    private let encoder = JSONEncoder()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private var webSocketTask: URLSessionWebSocketTask?
    private var isReceiving = false
    private var isClosing = false
    private var hasFinished = false

    // MARK: - 텍스트 상태

    private var stableText = ""
    private var unstableText = ""
    private var currentSpeaker: String?

    // MARK: - Finalization

    private var finishContinuation: CheckedContinuation<Void, Error>?

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    // MARK: - 핸들러 설정

    func setHandlers(
        onTokenUpdate: ((SonioxTokenUpdate) -> Void)?,
        onError: ((Error) -> Void)?
    ) {
        self.onTokenUpdate = onTokenUpdate
        self.onError = onError
    }

    // MARK: - 연결

    func connect(apiKey: String) async throws {
        guard !apiKey.isEmpty else {
            throw SonioxError.apiKeyMissing
        }

        guard let url = URL(string: Self.websocketURL) else {
            throw SonioxError.invalidURL
        }

        let request = URLRequest(url: url)
        let task = urlSession.webSocketTask(with: request)
        self.webSocketTask = task
        self.isClosing = false
        self.hasFinished = false
        self.stableText = ""
        self.unstableText = ""
        self.currentSpeaker = nil

        task.resume()

        isReceiving = true
        Task { await self.receiveLoop() }

        // 설정 메시지 전송
        let config = SonioxConfigMessage(
            apiKey: apiKey,
            model: Self.model,
            audioFormat: Self.audioFormat,
            sampleRate: Self.sampleRate,
            numChannels: Self.numChannels,
            enableEndpointDetection: true,
            maxEndpointDelayMs: Self.maxEndpointDelayMs,
            enableSpeakerDiarization: true,
            languageHints: ["en"],
            clientReferenceID: UUID().uuidString
        )

        try await sendEncodable(config)
        print("[SonioxSTT] 연결 완료 (model: \(Self.model), endpoint: \(Self.maxEndpointDelayMs)ms, diarization: on)")
    }

    // MARK: - 오디오 전송

    func sendAudioData(_ data: Data) async throws {
        guard !isClosing else { return }
        guard let task = webSocketTask else {
            throw SonioxError.sessionClosed
        }
        try await task.send(.data(data))
    }

    // MARK: - 종료

    func stop() async {
        isClosing = true

        // Silence padding 전송 (500ms)
        if webSocketTask != nil {
            let silenceData = Self.makeSilenceChunk(milliseconds: 500)
            try? await sendAudioData(silenceData)

            // End-of-audio 신호 전송
            try? await webSocketTask?.send(.string(""))

            // finished 응답 대기 (최대 3초)
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask {
                        try await self.waitForFinished()
                    }
                    group.addTask {
                        try await Task.sleep(nanoseconds: 3_000_000_000)
                        throw SonioxError.sessionClosed
                    }
                    // 먼저 완료되는 것만 취함
                    try await group.next()
                    group.cancelAll()
                }
            } catch {
                // 타임아웃이면 무시하고 진행
            }
        }

        webSocketTask?.cancel(with: .normalClosure, reason: nil)
        webSocketTask = nil
        isReceiving = false
        failPending(with: SonioxError.sessionClosed)
        print("[SonioxSTT] 세션 종료")
    }

    // MARK: - Private: 수신 루프

    private func receiveLoop() async {
        while isReceiving, let task = webSocketTask {
            do {
                let message = try await task.receive()
                try handleMessage(message)
            } catch {
                if isClosing || hasFinished { break }
                failPending(with: error)
                onError?(error)
                break
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) throws {
        let data: Data
        switch message {
        case .data(let payload):
            data = payload
        case .string(let text):
            guard let payload = text.data(using: .utf8) else {
                throw SonioxError.invalidMessage
            }
            data = payload
        @unknown default:
            throw SonioxError.invalidMessage
        }

        let response = try decoder.decode(SonioxRealtimeResponse.self, from: data)

        if let errorCode = response.errorCode {
            throw SonioxError.serverError(
                code: errorCode,
                message: response.errorMessage ?? "Soniox 요청이 실패했습니다."
            )
        }

        var isEndpoint = false
        var latestUnstableText = ""
        var sawToken = false
        var latestSpeaker: String? = currentSpeaker

        for token in response.tokens ?? [] {
            sawToken = true
            let text = token.text

            if let speaker = token.speaker {
                latestSpeaker = speaker
            }

            if token.isFinal {
                if text == "<end>" {
                    isEndpoint = true
                    continue
                }
                if text == "<fin>" {
                    // Manual finalization — 종료 시 사용
                    isEndpoint = true
                    continue
                }
                stableText += text
            } else {
                latestUnstableText += text
            }
        }

        unstableText = latestUnstableText
        currentSpeaker = latestSpeaker

        if sawToken || isEndpoint {
            let update = SonioxTokenUpdate(
                stableText: stableText,
                unstableText: unstableText,
                speaker: currentSpeaker,
                isEndpoint: isEndpoint
            )
            onTokenUpdate?(update)
        }

        // Endpoint 이후 stableText 초기화 (새 문장 시작)
        if isEndpoint {
            stableText = ""
            unstableText = ""
        }

        if response.finished == true {
            hasFinished = true
            isClosing = true
            resumeFinishContinuation(with: .success(()))
        }
    }

    // MARK: - Private: 유틸리티

    private func sendEncodable<T: Encodable>(_ value: T) async throws {
        guard let task = webSocketTask else {
            throw SonioxError.sessionClosed
        }
        let data = try encoder.encode(value)
        guard let text = String(data: data, encoding: .utf8) else {
            throw SonioxError.invalidMessage
        }
        try await task.send(.string(text))
    }

    private func waitForFinished() async throws {
        if hasFinished { return }
        try await withCheckedThrowingContinuation { continuation in
            finishContinuation = continuation
        }
    }

    private func failPending(with error: Error) {
        resumeFinishContinuation(with: .failure(error))
    }

    private func resumeFinishContinuation(with result: Result<Void, Error>) {
        guard let continuation = finishContinuation else { return }
        finishContinuation = nil
        continuation.resume(with: result)
    }

    private static func makeSilenceChunk(milliseconds: Int) -> Data {
        let frameCount = max(0, milliseconds) * sampleRate / 1_000
        let byteCount = frameCount * numChannels * MemoryLayout<Int16>.size
        return Data(count: byteCount)
    }
}

// MARK: - Soniox Protocol Messages

private struct SonioxConfigMessage: Encodable {
    let apiKey: String
    let model: String
    let audioFormat: String
    let sampleRate: Int
    let numChannels: Int
    let enableEndpointDetection: Bool
    let maxEndpointDelayMs: Int
    let enableSpeakerDiarization: Bool
    let languageHints: [String]?
    let clientReferenceID: String

    enum CodingKeys: String, CodingKey {
        case apiKey = "api_key"
        case model
        case audioFormat = "audio_format"
        case sampleRate = "sample_rate"
        case numChannels = "num_channels"
        case enableEndpointDetection = "enable_endpoint_detection"
        case maxEndpointDelayMs = "max_endpoint_delay_ms"
        case enableSpeakerDiarization = "enable_speaker_diarization"
        case languageHints = "language_hints"
        case clientReferenceID = "client_reference_id"
    }
}

private struct SonioxRealtimeResponse: Decodable {
    let tokens: [SonioxToken]?
    let finished: Bool?
    let errorCode: String?
    let errorMessage: String?

    enum CodingKeys: String, CodingKey {
        case tokens
        case finished
        case errorCode = "error_code"
        case errorMessage = "error_message"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tokens = try container.decodeIfPresent([SonioxToken].self, forKey: .tokens)
        finished = try container.decodeIfPresent(Bool.self, forKey: .finished)

        if let numericErrorCode = try? container.decodeIfPresent(Int.self, forKey: .errorCode) {
            errorCode = String(numericErrorCode)
        } else {
            errorCode = try container.decodeIfPresent(String.self, forKey: .errorCode)
        }

        errorMessage = try container.decodeIfPresent(String.self, forKey: .errorMessage)
    }
}

private struct SonioxToken: Decodable {
    let text: String
    let isFinal: Bool
    let speaker: String?

    enum CodingKeys: String, CodingKey {
        case text
        case isFinal = "is_final"
        case speaker
    }
}
