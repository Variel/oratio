import Foundation
import AVFoundation

/// OpenAI Whisper API 기반 STT 구현
/// 오디오 청크를 일정 시간(약 4초) 모아서 Whisper API로 전송하여 텍스트 변환
/// - 청크 단위로 API 호출하므로 부분 결과 없이 최종 결과만 전달
/// - 높은 정확도의 전사 제공
class WhisperSTT: STTProvider, @unchecked Sendable {
    var name: String { "OpenAI Whisper" }
    private var _isRecognizing: Bool = false
    private(set) var isRecognizing: Bool {
        get { processingQueue.sync { _isRecognizing } }
        set { processingQueue.sync { _isRecognizing = newValue } }
    }

    var onPartialResult: ((String) -> Void)?
    var onFinalResult: ((String) -> Void)?
    var onError: ((Error) -> Void)?

    // MARK: - 설정 상수

    /// Whisper API 엔드포인트
    private let apiEndpoint = "https://api.openai.com/v1/audio/transcriptions"

    /// Whisper 모델명
    private let modelName = "whisper-1"

    /// 인식 언어 (영어)
    private let language = "en"

    /// 오디오 청크 수집 시간 (초)
    private let chunkDuration: TimeInterval = 4.0

    /// 최소 전송 오디오 길이 (초) - 너무 짧은 청크는 스킵
    private let minimumChunkDuration: TimeInterval = 0.5

    // MARK: - Private 프로퍼티

    /// 오디오 버퍼 수집용 배열
    private var audioBuffers: [AVAudioPCMBuffer] = []

    /// 수집된 프레임 수
    private var collectedFrameCount: AVAudioFrameCount = 0

    /// 타겟 샘플레이트 (AudioCaptureService와 동일)
    private let sampleRate: Double = AudioCaptureService.sampleRate

    /// 청크 전송 타이머
    private var chunkTimer: Timer?

    /// API 호출 중인지 여부 (동시 호출 방지)
    private var isProcessingChunk: Bool = false

    /// 스레드 안전을 위한 큐
    private let processingQueue = DispatchQueue(
        label: "com.channy.LiveTranslator.WhisperSTT",
        qos: .userInteractive
    )

    /// URL 세션
    private let urlSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        return URLSession(configuration: config)
    }()

    // MARK: - STTProvider 프로토콜 구현

    func startRecognition() async throws {
        // API 키 확인
        let apiKey = AppSettings.shared.openaiApiKey
        guard !apiKey.isEmpty else {
            throw STTError.apiKeyMissing
        }

        if isRecognizing {
            stopRecognition()
        }

        processingQueue.sync {
            audioBuffers.removeAll()
            collectedFrameCount = 0
            isProcessingChunk = false
        }

        isRecognizing = true

        // 청크 타이머 시작 (메인 스레드에서)
        await MainActor.run {
            startChunkTimer()
        }

        print("[WhisperSTT] 음성 인식 시작 (청크 길이: \(chunkDuration)초)")
    }

    func stopRecognition() {
        isRecognizing = false

        DispatchQueue.main.async { [weak self] in
            self?.stopChunkTimer()
        }

        // 남은 버퍼가 있으면 마지막 청크로 처리
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            let remainingBuffers = self.audioBuffers
            let remainingFrames = self.collectedFrameCount
            self.audioBuffers.removeAll()
            self.collectedFrameCount = 0

            if !remainingBuffers.isEmpty {
                let duration = Double(remainingFrames) / self.sampleRate
                if duration >= self.minimumChunkDuration {
                    self.processChunk(buffers: remainingBuffers)
                }
            }
        }

        print("[WhisperSTT] 음성 인식 정지")
    }

    func feedAudioBuffer(_ buffer: AVAudioPCMBuffer) {
        processingQueue.async { [weak self] in
            guard let self = self, self.isRecognizing else { return }
            self.audioBuffers.append(buffer)
            self.collectedFrameCount += buffer.frameLength
        }
    }

    // MARK: - 청크 타이머

    /// 청크 전송 타이머를 시작한다.
    private func startChunkTimer() {
        stopChunkTimer()
        chunkTimer = Timer.scheduledTimer(
            withTimeInterval: chunkDuration,
            repeats: true
        ) { [weak self] _ in
            self?.flushCurrentChunk()
        }
    }

    /// 청크 전송 타이머를 정지한다.
    private func stopChunkTimer() {
        chunkTimer?.invalidate()
        chunkTimer = nil
    }

    /// 현재 수집된 오디오 버퍼를 청크로 전송한다.
    private func flushCurrentChunk() {
        processingQueue.async { [weak self] in
            guard let self = self else { return }
            guard !self.isProcessingChunk else { return } // 이전 청크 처리 중이면 스킵

            let buffers = self.audioBuffers
            let frameCount = self.collectedFrameCount
            self.audioBuffers.removeAll()
            self.collectedFrameCount = 0

            guard !buffers.isEmpty else { return }

            // 최소 길이 확인
            let duration = Double(frameCount) / self.sampleRate
            guard duration >= self.minimumChunkDuration else { return }

            self.processChunk(buffers: buffers)
        }
    }

    // MARK: - 청크 처리

    /// 오디오 버퍼 배열을 WAV로 인코딩하여 Whisper API로 전송한다.
    private func processChunk(buffers: [AVAudioPCMBuffer]) {
        isProcessingChunk = true

        // 오디오 버퍼를 WAV 데이터로 변환
        guard let wavData = encodeBuffersToWAV(buffers) else {
            isProcessingChunk = false
            onError?(STTError.audioEncodingFailed)
            return
        }

        // "현재 처리 중" 부분 결과로 표시
        onPartialResult?("[Whisper: 처리 중...]")

        // Whisper API 호출
        Task { [weak self] in
            guard let self = self else { return }

            defer {
                self.processingQueue.async { [weak self] in
                    self?.isProcessingChunk = false
                }
            }

            do {
                let text = try await self.callWhisperAPI(wavData: wavData)
                if !text.isEmpty {
                    self.onFinalResult?(text)
                }
            } catch {
                self.onError?(STTError.networkError(error))
            }
        }
    }

    // MARK: - WAV 인코딩

    /// AVAudioPCMBuffer 배열을 WAV 형식 데이터로 변환한다.
    /// - Parameter buffers: 변환할 오디오 버퍼 배열
    /// - Returns: WAV 형식 Data, 실패 시 nil
    private func encodeBuffersToWAV(_ buffers: [AVAudioPCMBuffer]) -> Data? {
        // 총 프레임 수 계산
        let totalFrames = buffers.reduce(0) { $0 + Int($1.frameLength) }
        guard totalFrames > 0 else { return nil }

        let channelCount: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let sampleRateInt = UInt32(sampleRate)
        let bytesPerSample = bitsPerSample / 8
        let dataSize = UInt32(totalFrames * Int(channelCount) * Int(bytesPerSample))

        var wavData = Data()

        // WAV 헤더 작성
        // RIFF 헤더
        wavData.append(contentsOf: "RIFF".utf8)
        wavData.append(uint32LittleEndian: 36 + dataSize) // 파일 크기 - 8
        wavData.append(contentsOf: "WAVE".utf8)

        // fmt 서브청크
        wavData.append(contentsOf: "fmt ".utf8)
        wavData.append(uint32LittleEndian: 16) // 서브청크 크기
        wavData.append(uint16LittleEndian: 1)  // PCM 포맷
        wavData.append(uint16LittleEndian: channelCount)
        wavData.append(uint32LittleEndian: sampleRateInt)
        wavData.append(uint32LittleEndian: sampleRateInt * UInt32(channelCount) * UInt32(bytesPerSample)) // 바이트 레이트
        wavData.append(uint16LittleEndian: channelCount * bytesPerSample) // 블록 정렬
        wavData.append(uint16LittleEndian: bitsPerSample)

        // data 서브청크
        wavData.append(contentsOf: "data".utf8)
        wavData.append(uint32LittleEndian: dataSize)

        // PCM Float32 -> Int16 변환하여 데이터 기록
        for buffer in buffers {
            guard let channelData = buffer.floatChannelData else { continue }
            let frameLength = Int(buffer.frameLength)

            for frame in 0..<frameLength {
                let sample = channelData[0][frame]
                // Float32 (-1.0 ~ 1.0)를 Int16 (-32768 ~ 32767)로 변환
                let clampedSample = max(-1.0, min(1.0, sample))
                let int16Sample = Int16(clampedSample * 32767.0)
                wavData.append(uint16LittleEndian: UInt16(bitPattern: int16Sample))
            }
        }

        return wavData
    }

    // MARK: - Whisper API 호출

    /// Whisper API에 오디오 데이터를 전송하여 텍스트 전사 결과를 받는다.
    /// - Parameter wavData: WAV 형식의 오디오 데이터
    /// - Returns: 전사된 텍스트
    private func callWhisperAPI(wavData: Data) async throws -> String {
        let apiKey = AppSettings.shared.openaiApiKey
        guard !apiKey.isEmpty else {
            throw STTError.apiKeyMissing
        }

        let boundary = "Boundary-\(UUID().uuidString)"

        var request = URLRequest(url: URL(string: apiEndpoint)!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        // multipart/form-data 본문 구성
        var body = Data()

        // model 필드
        body.appendMultipartField(name: "model", value: modelName, boundary: boundary)

        // language 필드
        body.appendMultipartField(name: "language", value: language, boundary: boundary)

        // response_format 필드
        body.appendMultipartField(name: "response_format", value: "json", boundary: boundary)

        // file 필드 (WAV 오디오 데이터)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/wav\r\n\r\n".data(using: .utf8)!)
        body.append(wavData)
        body.append("\r\n".data(using: .utf8)!)

        // 종료 boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body

        let (data, response) = try await urlSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
            let responseBody = String(data: data, encoding: .utf8) ?? "unknown"
            print("[WhisperSTT] API 에러 (status: \(statusCode)): \(responseBody)")
            throw STTError.invalidResponse
        }

        // JSON 응답 파싱
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = json["text"] as? String else {
            throw STTError.invalidResponse
        }

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    deinit {
        stopRecognition()
    }
}

// MARK: - Data 확장: WAV 인코딩 헬퍼

private extension Data {
    /// UInt32 값을 리틀 엔디안으로 추가한다.
    mutating func append(uint32LittleEndian value: UInt32) {
        let littleEndian = value.littleEndian
        withUnsafePointer(to: littleEndian) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<UInt32>.size) { bytePtr in
                self.append(bytePtr, count: MemoryLayout<UInt32>.size)
            }
        }
    }

    /// UInt16 값을 리틀 엔디안으로 추가한다.
    mutating func append(uint16LittleEndian value: UInt16) {
        let littleEndian = value.littleEndian
        withUnsafePointer(to: littleEndian) { ptr in
            ptr.withMemoryRebound(to: UInt8.self, capacity: MemoryLayout<UInt16>.size) { bytePtr in
                self.append(bytePtr, count: MemoryLayout<UInt16>.size)
            }
        }
    }

    /// multipart/form-data 텍스트 필드를 추가한다.
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        append("--\(boundary)\r\n".data(using: .utf8)!)
        append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
        append("\(value)\r\n".data(using: .utf8)!)
    }
}
