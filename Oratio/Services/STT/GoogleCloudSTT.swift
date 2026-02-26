import Foundation
import AVFoundation
import GRPC
import NIOCore
import NIOPosix
import SwiftProtobuf

/// Google Cloud Speech-to-Text gRPC 스트리밍 STT 구현
/// - 실시간 양방향 gRPC 스트리밍
/// - 자동 구두점 (문장 경계 감지)
/// - interim/final 결과 구분
/// - Service Account 인증 (JWT → access token)
class GoogleCloudSTT: STTProvider {
    var name: String { "Google Cloud Speech" }
    private var _isRecognizing: Bool = false
    private(set) var isRecognizing: Bool {
        get { processingQueue.sync { _isRecognizing } }
        set { processingQueue.sync { _isRecognizing = newValue } }
    }

    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - 설정

    /// 오디오 전송 간격 (초)
    private let audioSendInterval: TimeInterval = 0.25

    /// 최대 스트리밍 시간 (초) - Google 제한 ~305초
    private let maxStreamDuration: TimeInterval = 290.0

    // MARK: - gRPC 프로퍼티

    private var group: EventLoopGroup?
    private var channel: ClientConnection?
    private var streamingCall: BidirectionalStreamingCall<Speech_StreamingRecognizeRequest, Speech_StreamingRecognizeResponse>?

    // MARK: - 인증

    private let auth = GoogleServiceAccountAuth()

    // MARK: - 오디오 버퍼

    private var audioBufferQueue: [Data] = []
    private var audioSendTimer: Timer?
    private let processingQueue = DispatchQueue(
        label: "ing.unlimit.oratio.GoogleCloudSTT",
        qos: .userInteractive
    )

    /// 현재 누적된 interim 텍스트
    private var currentInterimText: String = ""

    /// 스트리밍 시작 시간 (자동 재시작용)
    private var streamStartTime: Date?

    /// 명시적 정지 요청 여부
    private var isExplicitStop: Bool = false

    /// 연속 재연결 시도 횟수
    private var reconnectAttempts: Int = 0
    private let maxReconnectAttempts: Int = 3

    // MARK: - STTProvider 구현

    func startRecognition() async throws {
        let filePath = AppSettings.shared.googleCloudServiceAccountPath
        guard !filePath.isEmpty else {
            throw STTError.apiKeyMissing
        }

        // Service Account 인증 정보 로드
        do {
            try auth.loadCredentials(from: filePath)
        } catch {
            throw STTError.connectionFailed(error)
        }

        if isRecognizing {
            stopRecognition()
        }

        isExplicitStop = false
        currentInterimText = ""
        reconnectAttempts = 0

        try await startGRPCStream()

        isRecognizing = true
        streamStartTime = Date()

        await MainActor.run {
            startAudioSendTimer()
        }

        print("[GoogleCloudSTT] 음성 인식 시작")
    }

    func stopRecognition() {
        isExplicitStop = true
        isRecognizing = false

        DispatchQueue.main.async { [weak self] in
            self?.stopAudioSendTimer()
        }

        // 명시적 stop에서는 synthetic final을 만들지 않는다.
        currentInterimText = ""

        closeGRPCStream()

        processingQueue.async { [weak self] in
            self?.audioBufferQueue.removeAll()
        }

        print("[GoogleCloudSTT] 음성 인식 정지")
    }

    func feedAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        guard isRecognizing else { return }

        guard let pcmData = convertBufferToInt16PCM(buffer) else { return }

        processingQueue.async { [weak self] in
            self?.audioBufferQueue.append(pcmData)
        }
    }

    // MARK: - gRPC 스트리밍

    private func startGRPCStream() async throws {
        // access token 획득
        let accessToken = try await auth.getAccessToken()
        print("[GoogleCloudSTT] access token 획득 완료 (길이: \(accessToken.count))")

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.group = group

        let channel = ClientConnection
            .usingPlatformAppropriateTLS(for: group)
            .connect(host: "speech.googleapis.com", port: 443)
        self.channel = channel

        let callOptions = CallOptions(
            customMetadata: ["authorization": "Bearer \(accessToken)"]
        )

        let call: BidirectionalStreamingCall<Speech_StreamingRecognizeRequest, Speech_StreamingRecognizeResponse> =
            channel.makeBidirectionalStreamingCall(
                path: "/google.cloud.speech.v1.Speech/StreamingRecognize",
                callOptions: callOptions,
                handler: { [weak self] response in
                    self?.handleResponse(response)
                }
            )
        self.streamingCall = call

        // 에러/종료 핸들링
        call.status.whenComplete { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let status):
                print("[GoogleCloudSTT] gRPC 스트림 종료 - 코드: \(status.code), 메시지: \(status.message ?? "없음")")
                if !self.isExplicitStop {
                    let isNormalEnd = (status.code == .ok || status.code == .outOfRange)
                    self.handleStreamEnd(isError: !isNormalEnd)
                }
            case .failure(let error):
                print("[GoogleCloudSTT] gRPC 에러: \(error)")
                if !self.isExplicitStop {
                    self.handleStreamEnd(isError: true)
                }
            }
        }

        // 초기 설정 메시지 전송
        var configRequest = Speech_StreamingRecognizeRequest()
        var streamingConfig = Speech_StreamingRecognitionConfig()
        var recognitionConfig = Speech_RecognitionConfig()

        recognitionConfig.encoding = .linear16
        recognitionConfig.sampleRateHertz = 16000
        recognitionConfig.languageCode = "en-US"
        recognitionConfig.enableAutomaticPunctuation = true
        recognitionConfig.model = "latest_long"

        streamingConfig.config = recognitionConfig
        streamingConfig.interimResults = true
        streamingConfig.singleUtterance = false

        configRequest.streamingConfig = streamingConfig

        _ = call.sendMessage(configRequest)

        print("[GoogleCloudSTT] gRPC 스트림 시작, 설정 전송 완료")
    }

    private func closeGRPCStream() {
        streamingCall?.sendEnd(promise: nil)
        streamingCall = nil

        let ch = channel
        let gr = group
        channel = nil
        group = nil

        DispatchQueue.global().async {
            _ = try? ch?.close().wait()
            try? gr?.syncShutdownGracefully()
        }
    }

    // MARK: - 응답 처리

    private func handleResponse(_ response: Speech_StreamingRecognizeResponse) {
        // Google은 한 응답에 여러 result를 보낼 수 있음 (안정 부분 + 신규 부분)
        // final과 interim을 분리하여 처리
        var finalParts: [String] = []
        var interimParts: [String] = []

        for result in response.results {
            guard let alternative = result.alternatives.first else { continue }
            let transcript = alternative.transcript.trimmingCharacters(in: .whitespaces)
            guard !transcript.isEmpty else { continue }

            if result.isFinal {
                finalParts.append(transcript)
            } else {
                interimParts.append(transcript)
            }
        }

        // final 결과 처리
        if !finalParts.isEmpty {
            let finalText = finalParts.joined(separator: " ")
            currentInterimText = ""
            print("[GoogleCloudSTT] Final: \"\(finalText.prefix(100))\"")

            DispatchQueue.main.async { [weak self] in
                self?.onFinalResult?(finalText)
            }
        }

        // interim 결과 처리: 모든 파트를 합쳐서 하나의 partial로 전달
        if !interimParts.isEmpty {
            let combined = (finalParts + interimParts).joined(separator: " ")
            currentInterimText = combined
            print("[GoogleCloudSTT] Interim (\(combined.count)자): \"\(combined.prefix(100))\"")

            DispatchQueue.main.async { [weak self] in
                self?.onPartialResult?(combined)
            }
        }
    }

    /// 스트림 종료 시 자동 재시작 (에러 시에만 카운트)
    private func handleStreamEnd(isError: Bool) {
        guard !isExplicitStop, isRecognizing else { return }

        if isError {
            reconnectAttempts += 1
            if reconnectAttempts > maxReconnectAttempts {
                print("[GoogleCloudSTT] 최대 재연결 횟수(\(maxReconnectAttempts)) 초과, 정지")
                DispatchQueue.main.async { [weak self] in
                    self?.onError?(STTError.connectionFailed(
                        NSError(domain: "GoogleCloudSTT", code: -1,
                                userInfo: [NSLocalizedDescriptionKey: "스트림 재연결 반복 실패"])
                    ))
                }
                stopRecognition()
                return
            }
            print("[GoogleCloudSTT] 에러로 스트림 종료, 재시작 시도 (\(reconnectAttempts)/\(maxReconnectAttempts))")
        } else {
            reconnectAttempts = 0
            print("[GoogleCloudSTT] 정상 스트림 종료, 재시작")
        }

        closeGRPCStream()

        Task {
            do {
                try await Task.sleep(nanoseconds: isError ? 1_000_000_000 : 100_000_000)
                guard !self.isExplicitStop, self.isRecognizing else { return }
                try await self.startGRPCStream()
                self.streamStartTime = Date()
                print("[GoogleCloudSTT] 스트림 재시작 성공")
            } catch {
                print("[GoogleCloudSTT] 스트림 재시작 실패: \(error)")
                self.onError?(STTError.connectionFailed(error))
                self.stopRecognition()
            }
        }
    }

    // MARK: - 오디오 전송 타이머

    private func startAudioSendTimer() {
        stopAudioSendTimer()
        audioSendTimer = Timer.scheduledTimer(
            withTimeInterval: audioSendInterval,
            repeats: true
        ) { [weak self] _ in
            self?.flushAudioBuffers()
        }
    }

    private func stopAudioSendTimer() {
        audioSendTimer?.invalidate()
        audioSendTimer = nil
    }

    private func flushAudioBuffers() {
        if let start = streamStartTime,
           Date().timeIntervalSince(start) > maxStreamDuration {
            print("[GoogleCloudSTT] 최대 스트리밍 시간 초과, 재시작")
            handleStreamEnd(isError: false)
            return
        }

        processingQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.audioBufferQueue.isEmpty else { return }

            var combinedData = Data()
            for buffer in self.audioBufferQueue {
                combinedData.append(buffer)
            }
            self.audioBufferQueue.removeAll()

            self.sendAudioData(combinedData)
        }
    }

    /// processingQueue에서 호출됨 - _isRecognizing 직접 접근
    private func sendAudioData(_ pcmData: Data) {
        guard _isRecognizing else { return }

        let bytes = pcmData.count
        let durationMs = Int(Double(bytes) / 32.0) // 16kHz * 2bytes = 32 bytes/ms
        print("[GoogleCloudSTT] 오디오 전송: \(bytes) bytes (\(durationMs)ms)")

        var request = Speech_StreamingRecognizeRequest()
        request.audioContent = pcmData
        _ = streamingCall?.sendMessage(request)
    }

    // MARK: - 오디오 변환

    private func convertBufferToInt16PCM(_ buffer: AVAudioPCMBuffer) -> Data? {
        guard let channelData = buffer.floatChannelData else { return nil }
        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return nil }

        var data = Data(capacity: frameLength * 2)

        for frame in 0..<frameLength {
            let sample = channelData[0][frame]
            let clampedSample = max(-1.0, min(1.0, sample))
            let int16Sample = Int16(clampedSample * 32767.0)
            var littleEndian = int16Sample.littleEndian
            data.append(Data(bytes: &littleEndian, count: MemoryLayout<Int16>.size))
        }

        return data
    }

    deinit {
        stopRecognition()
    }
}
