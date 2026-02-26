import Foundation
import AVFoundation

/// Gemini Live API 기반 STT 구현
/// WebSocket 기반 실시간 스트리밍 음성인식
/// - URLSessionWebSocketTask를 사용한 양방향 통신
/// - PCM 16-bit 오디오를 실시간으로 전송
/// - 부분 결과 및 최종 결과를 실시간으로 수신
/// - 연결 끊김 시 자동 재연결
class GeminiLiveSTT: STTProvider {
    var name: String { "Gemini Live" }
    private var _isRecognizing: Bool = false
    private(set) var isRecognizing: Bool {
        get { processingQueue.sync { _isRecognizing } }
        set { processingQueue.sync { _isRecognizing = newValue } }
    }

    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - 설정 상수

    /// Gemini Live API WebSocket 엔드포인트
    private let baseEndpoint = "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"

    /// Gemini 모델명
    private let modelName = "gemini-2.0-flash-live-001"

    /// 최대 자동 재연결 시도 횟수
    private let maxReconnectAttempts = 5

    /// 재연결 지연 시간 (초)
    private let reconnectDelay: TimeInterval = 2.0

    /// 오디오 전송 간격 (초) - 너무 자주 보내면 과부하
    private let audioSendInterval: TimeInterval = 0.25

    // MARK: - Private 프로퍼티

    /// WebSocket 연결
    private var webSocketTask: URLSessionWebSocketTask?

    /// URL 세션 (WebSocket 전용)
    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300 // WebSocket은 긴 연결 유지
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    /// 현재 재연결 시도 횟수
    private var reconnectAttempts = 0

    /// 수신 중인 부분 텍스트 (누적)
    private var accumulatedText: String = ""

    /// 오디오 버퍼 큐 (전송 대기)
    private var audioBufferQueue: [Data] = []

    /// 오디오 전송 타이머
    private var audioSendTimer: Timer?

    /// 스레드 안전을 위한 큐
    private let processingQueue = DispatchQueue(
        label: "com.channy.LiveTranslator.GeminiLiveSTT",
        qos: .userInteractive
    )

    /// 명시적 정지 요청인지 여부 (자동 재연결 방지)
    private var isExplicitStop: Bool = false

    /// setup 메시지 전송 완료 여부
    private var isSetupComplete: Bool = false

    // MARK: - STTProvider 프로토콜 구현

    func startRecognition() async throws {
        let apiKey = AppSettings.shared.geminiApiKey
        guard !apiKey.isEmpty else {
            throw STTError.apiKeyMissing
        }

        if isRecognizing {
            stopRecognition()
        }

        isExplicitStop = false
        reconnectAttempts = 0
        accumulatedText = ""
        isSetupComplete = false

        try await connectWebSocket(apiKey: apiKey)

        isRecognizing = true

        // 오디오 전송 타이머 시작
        await MainActor.run {
            startAudioSendTimer()
        }

        print("[GeminiLiveSTT] 음성 인식 시작")
    }

    func stopRecognition() {
        isExplicitStop = true
        isRecognizing = false
        isSetupComplete = false

        DispatchQueue.main.async { [weak self] in
            self?.stopAudioSendTimer()
        }

        // 마지막 누적 텍스트가 있으면 최종 결과로 전달
        if !accumulatedText.isEmpty {
            onFinalResult?(accumulatedText)
            accumulatedText = ""
        }

        disconnectWebSocket()

        processingQueue.async { [weak self] in
            self?.audioBufferQueue.removeAll()
        }

        print("[GeminiLiveSTT] 음성 인식 정지")
    }

    func feedAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecognizing, isSetupComplete else { return }

        // Float32 PCM -> Int16 PCM 변환
        guard let pcmData = convertBufferToInt16PCM(buffer) else { return }

        processingQueue.async { [weak self] in
            self?.audioBufferQueue.append(pcmData)
        }
    }

    // MARK: - WebSocket 연결

    /// WebSocket에 연결한다.
    private func connectWebSocket(apiKey: String) async throws {
        let urlString = "\(baseEndpoint)?key=\(apiKey)"
        guard let url = URL(string: urlString) else {
            throw STTError.connectionFailed(NSError(domain: "GeminiLiveSTT", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid URL"]))
        }

        let task = urlSession.webSocketTask(with: url)
        self.webSocketTask = task
        task.resume()

        // setup 메시지 전송
        try await sendSetupMessage()

        // setup 응답 수신
        try await receiveSetupResponse()

        isSetupComplete = true

        // 수신 루프 시작
        startReceiving()

        print("[GeminiLiveSTT] WebSocket 연결 완료")
    }

    /// WebSocket 연결을 해제한다.
    private func disconnectWebSocket() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
    }

    // MARK: - Gemini Live API 메시지

    /// setup 메시지를 전송한다.
    /// Gemini Live API는 첫 메시지로 설정 정보를 보내야 한다.
    private func sendSetupMessage() async throws {
        let setupMessage: [String: Any] = [
            "setup": [
                "model": "models/\(modelName)",
                "generation_config": [
                    "response_modalities": ["TEXT"],
                    "speech_config": [
                        "voice_config": [
                            "prebuilt_voice_config": [
                                "voice_name": "Aoede"
                            ]
                        ]
                    ]
                ],
                "system_instruction": [
                    "parts": [
                        ["text": "You are a speech-to-text transcription service. Listen to the audio input and transcribe it accurately in English. Output only the transcribed text, nothing else. Do not add any commentary, translation, or interpretation."]
                    ]
                ]
            ]
        ]

        let jsonData = try JSONSerialization.data(withJSONObject: setupMessage)
        let jsonString = String(data: jsonData, encoding: .utf8)!

        try await webSocketTask?.send(.string(jsonString))
        print("[GeminiLiveSTT] setup 메시지 전송 완료")
    }

    /// setup 응답을 수신한다.
    private func receiveSetupResponse() async throws {
        guard let message = try await webSocketTask?.receive() else {
            throw STTError.invalidResponse
        }

        switch message {
        case .string(let text):
            print("[GeminiLiveSTT] setup 응답 수신: \(text.prefix(200))")
        case .data(let data):
            let text = String(data: data, encoding: .utf8) ?? "binary"
            print("[GeminiLiveSTT] setup 응답 수신 (binary): \(text.prefix(200))")
        @unknown default:
            break
        }
    }

    /// 오디오 데이터를 WebSocket으로 전송한다.
    private func sendAudioData(_ pcmData: Data) {
        guard isRecognizing, isSetupComplete else { return }

        let base64Audio = pcmData.base64EncodedString()

        let audioMessage: [String: Any] = [
            "realtime_input": [
                "media_chunks": [
                    [
                        "data": base64Audio,
                        "mime_type": "audio/pcm;rate=16000"
                    ]
                ]
            ]
        ]

        guard let jsonData = try? JSONSerialization.data(withJSONObject: audioMessage),
              let jsonString = String(data: jsonData, encoding: .utf8) else {
            return
        }

        webSocketTask?.send(.string(jsonString)) { [weak self] error in
            if let error = error {
                print("[GeminiLiveSTT] 오디오 전송 에러: \(error.localizedDescription)")
                self?.handleConnectionError(error)
            }
        }
    }

    // MARK: - 수신 처리

    /// WebSocket 메시지 수신 루프를 시작한다.
    private func startReceiving() {
        webSocketTask?.receive { [weak self] result in
            guard let self = self else { return }

            switch result {
            case .success(let message):
                self.handleReceivedMessage(message)
                // 계속 수신
                if self.isRecognizing {
                    self.startReceiving()
                }

            case .failure(let error):
                if !self.isExplicitStop {
                    print("[GeminiLiveSTT] 수신 에러: \(error.localizedDescription)")
                    self.handleConnectionError(error)
                }
            }
        }
    }

    /// 수신된 메시지를 처리한다.
    private func handleReceivedMessage(_ message: URLSessionWebSocketTask.Message) {
        let jsonString: String

        switch message {
        case .string(let text):
            jsonString = text
        case .data(let data):
            guard let text = String(data: data, encoding: .utf8) else { return }
            jsonString = text
        @unknown default:
            return
        }

        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        // serverContent에서 텍스트 추출
        if let serverContent = json["serverContent"] as? [String: Any] {
            processServerContent(serverContent)
        }
    }

    /// serverContent 응답을 처리하여 텍스트를 추출한다.
    private func processServerContent(_ serverContent: [String: Any]) {
        // modelTurn에서 텍스트 파트 추출
        if let modelTurn = serverContent["modelTurn"] as? [String: Any],
           let parts = modelTurn["parts"] as? [[String: Any]] {
            for part in parts {
                if let text = part["text"] as? String, !text.isEmpty {
                    accumulatedText += text
                    onPartialResult?(accumulatedText)
                }
            }
        }

        // turnComplete가 true이면 현재까지의 텍스트를 최종 결과로 전달
        if let turnComplete = serverContent["turnComplete"] as? Bool, turnComplete {
            if !accumulatedText.isEmpty {
                onFinalResult?(accumulatedText)
                accumulatedText = ""
            }
        }
    }

    // MARK: - 오디오 전송 타이머

    /// 오디오 전송 타이머를 시작한다.
    private func startAudioSendTimer() {
        stopAudioSendTimer()
        audioSendTimer = Timer.scheduledTimer(
            withTimeInterval: audioSendInterval,
            repeats: true
        ) { [weak self] _ in
            self?.flushAudioBuffers()
        }
    }

    /// 오디오 전송 타이머를 정지한다.
    private func stopAudioSendTimer() {
        audioSendTimer?.invalidate()
        audioSendTimer = nil
    }

    /// 큐에 쌓인 오디오 버퍼를 합쳐서 전송한다.
    private func flushAudioBuffers() {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.audioBufferQueue.isEmpty else { return }

            // 큐의 모든 버퍼를 하나로 합침
            var combinedData = Data()
            for buffer in self.audioBufferQueue {
                combinedData.append(buffer)
            }
            self.audioBufferQueue.removeAll()

            self.sendAudioData(combinedData)
        }
    }

    // MARK: - 오디오 변환

    /// AVAudioPCMBuffer를 Int16 PCM 데이터로 변환한다.
    /// - Parameter buffer: 변환할 오디오 버퍼 (Float32 형식)
    /// - Returns: Int16 PCM 데이터
    private func convertBufferToInt16PCM(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        var data = Data(capacity: frameLength * 2) // Int16 = 2바이트

        for frame in 0..<frameLength {
            let sample = channelData[0][frame]
            let clampedSample = max(-1.0, min(1.0, sample))
            let int16Sample = Int16(clampedSample * 32767.0)
            let littleEndian = int16Sample.littleEndian
            withUnsafePointer(to: littleEndian) { ptr in
                ptr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<Int16>.size) { bytePtr in
                    data.append(bytePtr, count: MemoryLayout<Int16>.size)
                }
            }
        }

        return data
    }

    // MARK: - 에러 및 재연결

    /// 연결 에러를 처리하고 필요시 재연결을 시도한다.
    private func handleConnectionError(_ error: Error) {
        guard !isExplicitStop else { return }

        disconnectWebSocket()

        if reconnectAttempts < maxReconnectAttempts {
            reconnectAttempts += 1
            print("[GeminiLiveSTT] 재연결 시도 \(reconnectAttempts)/\(maxReconnectAttempts)")

            let delay = reconnectDelay * Double(reconnectAttempts)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self, !self.isExplicitStop else { return }

                Task {
                    do {
                        let apiKey = AppSettings.shared.geminiApiKey
                        try await self.connectWebSocket(apiKey: apiKey)
                        self.reconnectAttempts = 0
                        print("[GeminiLiveSTT] 재연결 성공")
                    } catch {
                        print("[GeminiLiveSTT] 재연결 실패: \(error.localizedDescription)")
                        self.handleConnectionError(error)
                    }
                }
            }
        } else {
            print("[GeminiLiveSTT] 최대 재연결 시도 횟수 초과")
            isRecognizing = false
            onError?(STTError.connectionFailed(error))
        }
    }

    deinit {
        stopRecognition()
    }
}
