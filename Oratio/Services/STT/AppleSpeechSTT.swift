import Foundation
import Speech
import AVFoundation

/// Apple Speech Framework 기반 STT 구현
/// SFSpeechRecognizer를 이용한 실시간 영어 음성인식
/// - 부분 결과(partialResults)를 실시간으로 전달
/// - 60초 제한 시 자동 재시작
class AppleSpeechSTT: STTProvider {
    var name: String { "Apple Speech" }
    private(set) var isRecognizing: Bool = false

    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - Private 프로퍼티

    /// 영어(미국) 로케일의 SFSpeechRecognizer
    private let speechRecognizer: SFSpeechRecognizer? = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))

    /// 현재 활성화된 인식 요청
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?

    /// 현재 활성화된 인식 태스크
    private var recognitionTask: SFSpeechRecognitionTask?

    /// 마지막으로 전달된 부분 결과 텍스트 (중복 전달 방지)
    private var lastPartialResult: String = ""

    /// 인식 시작 시간 (60초 제한 관리)
    private var recognitionStartTime: Date?

    /// 60초 자동 재시작 타이머
    private var restartTimer: Timer?

    /// Apple Speech Framework의 연속 인식 제한 시간 (초)
    private let maxRecognitionDuration: TimeInterval = 55.0 // 60초 제한 전 여유를 두고 55초

    /// 재시작 중인지 여부 (재시작 중 오디오 버퍼 손실 최소화)
    private var isRestarting: Bool = false

    /// 재시작 중 버퍼를 임시 보관
    private var pendingBuffers: [AVAudioPCMBuffer] = []

    /// 스레드 안전을 위한 큐
    private let processingQueue = DispatchQueue(
        label: "ing.unlimit.oratio.AppleSpeechSTT",
        qos: .userInteractive
    )

    // MARK: - 권한 요청

    /// 음성 인식 권한을 요청한다.
    /// - Returns: 권한이 부여되었는지 여부
    private func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    // MARK: - STTProvider 프로토콜 구현

    func startRecognition() async throws {
        guard let speechRecognizer = speechRecognizer, speechRecognizer.isAvailable else {
            throw STTError.recognitionNotAvailable
        }

        // 권한 확인
        let authorized = await requestAuthorization()
        guard authorized else {
            throw STTError.permissionDenied
        }

        // 이미 인식 중이면 정지 후 재시작
        if isRecognizing {
            stopRecognitionInternal()
        }

        try startRecognitionSession()
    }

    func stopRecognition() {
        processingQueue.sync {
            isRestarting = false
            pendingBuffers.removeAll()
        }
        stopRecognitionInternal()
        stopRestartTimer()
    }

    func feedAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        processingQueue.async { [weak self] in
            guard let self = self else { return }

            if self.isRestarting {
                // 재시작 중에는 버퍼를 임시 보관
                self.pendingBuffers.append(buffer)
                return
            }

            self.recognitionRequest?.append(buffer)
        }
    }

    // MARK: - 인식 세션 관리

    /// 새 인식 세션을 시작한다.
    private func startRecognitionSession() throws {
        guard let speechRecognizer = speechRecognizer else {
            throw STTError.recognitionNotAvailable
        }

        // 인식 요청 생성
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true

        // macOS 13+ 에서 on-device 인식이 가능하면 사용
        if #available(macOS 13, *) {
            request.requiresOnDeviceRecognition = false // 네트워크 인식도 허용 (정확도 우선)
        }

        self.recognitionRequest = request
        self.lastPartialResult = ""
        self.recognitionStartTime = Date()

        // 인식 태스크 시작
        recognitionTask = speechRecognizer.recognitionTask(with: request) { [weak self] result, error in
            guard let self = self else { return }

            if let error = error {
                // 사용자가 명시적으로 정지한 경우는 에러로 처리하지 않음
                let nsError = error as NSError
                if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 216 {
                    // 인식 취소됨 - 정상적인 정지
                    return
                }
                if nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 209 {
                    // 인식 시간 제한 도달 - 자동 재시작
                    self.handleRecognitionTimeout()
                    return
                }
                self.onError?(STTError.recognitionFailed(error))
                return
            }

            guard let result = result else { return }

            let transcription = result.bestTranscription.formattedString

            if result.isFinal {
                // 최종 결과
                if !transcription.isEmpty {
                    self.onFinalResult?(transcription)
                }
                self.lastPartialResult = ""
            } else {
                // 부분 결과 - 변경이 있을 때만 전달
                if transcription != self.lastPartialResult && !transcription.isEmpty {
                    self.lastPartialResult = transcription
                    self.onPartialResult?(transcription)
                }
            }
        }

        isRecognizing = true

        // 60초 제한 타이머 시작
        startRestartTimer()

        print("[AppleSpeechSTT] 음성 인식 세션 시작")
    }

    /// 현재 인식 세션을 정지한다.
    private func stopRecognitionInternal() {
        recognitionTask?.cancel()
        recognitionTask = nil

        recognitionRequest?.endAudio()
        recognitionRequest = nil

        isRecognizing = false
        lastPartialResult = ""
        recognitionStartTime = nil

        print("[AppleSpeechSTT] 음성 인식 세션 정지")
    }

    // MARK: - 60초 제한 자동 재시작

    /// 60초 제한 도달 시 자동으로 인식을 재시작한다.
    private func handleRecognitionTimeout() {
        print("[AppleSpeechSTT] 인식 시간 제한 도달 - 자동 재시작")
        restartRecognition()
    }

    /// 인식을 재시작한다.
    private func restartRecognition() {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            self.isRestarting = true
            self.pendingBuffers.removeAll()
        }

        // 현재 세션 정지
        stopRecognitionInternal()
        stopRestartTimer()

        // 짧은 지연 후 새 세션 시작
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self = self else { return }
            do {
                try self.startRecognitionSession()

                // 재시작 중 쌓인 버퍼를 새 세션에 전달
                self.processingQueue.async { [weak self] in
                    guard let self = self else { return }
                    let buffered = self.pendingBuffers
                    self.pendingBuffers.removeAll()
                    self.isRestarting = false

                    for buffer in buffered {
                        self.recognitionRequest?.append(buffer)
                    }
                }
            } catch {
                self.processingQueue.async { [weak self] in
                    self?.isRestarting = false
                    self?.pendingBuffers.removeAll()
                }
                self.onError?(error)
            }
        }
    }

    /// 자동 재시작 타이머를 시작한다.
    private func startRestartTimer() {
        stopRestartTimer()
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.restartTimer = Timer.scheduledTimer(
                withTimeInterval: self.maxRecognitionDuration,
                repeats: false
            ) { [weak self] _ in
                self?.restartRecognition()
            }
        }
    }

    /// 자동 재시작 타이머를 정지한다.
    private func stopRestartTimer() {
        DispatchQueue.main.async { [weak self] in
            self?.restartTimer?.invalidate()
            self?.restartTimer = nil
        }
    }

    deinit {
        stopRecognition()
    }
}
