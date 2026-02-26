import Foundation
import AVFoundation
import ScreenCaptureKit
import Combine
import CoreMedia

// MARK: - 에러 정의

/// 오디오 캡처 관련 에러
enum AudioCaptureError: LocalizedError {
    case screenCaptureNotAvailable
    case noShareableContent
    case permissionDenied
    case streamCreationFailed(Error)
    case streamStartFailed(Error)
    case audioConversionFailed
    case alreadyCapturing
    case notCapturing

    var errorDescription: String? {
        switch self {
        case .screenCaptureNotAvailable:
            return "ScreenCaptureKit을 사용할 수 없습니다. macOS 13.0 이상이 필요합니다."
        case .noShareableContent:
            return "캡처 가능한 콘텐츠를 찾을 수 없습니다."
        case .permissionDenied:
            return "화면 녹화 권한이 거부되었습니다. 시스템 설정 > 개인 정보 보호 및 보안 > 화면 녹화에서 Oratio를 허용해 주세요."
        case .streamCreationFailed(let error):
            return "오디오 스트림 생성 실패: \(error.localizedDescription)"
        case .streamStartFailed(let error):
            return "오디오 스트림 시작 실패: \(error.localizedDescription)"
        case .audioConversionFailed:
            return "오디오 데이터 변환에 실패했습니다."
        case .alreadyCapturing:
            return "이미 오디오 캡처가 진행 중입니다."
        case .notCapturing:
            return "오디오 캡처가 진행 중이 아닙니다."
        }
    }
}

// MARK: - AudioCaptureService

/// 시스템 오디오 캡처 서비스
/// ScreenCaptureKit을 이용하여 시스템 오디오를 캡처한다.
/// 캡처된 오디오 버퍼는 콜백을 통해 후속 STT 서비스에 전달된다.
class AudioCaptureService: NSObject, ObservableObject {

    // MARK: - Published 상태

    @Published var isCapturing: Bool = false
    @Published var audioLevel: Float = 0.0
    @Published var lastError: AudioCaptureError?

    // MARK: - 콜백

    /// CMSampleBuffer 기반 콜백 (원본 오디오 데이터)
    /// nonisolated(unsafe): 오디오 콜백(백그라운드 큐)에서 접근하므로 MainActor 격리 제외
    var onAudioSampleBuffer: ((CMSampleBuffer) -> Void)?

    /// AVAudioPCMBuffer 기반 콜백 (변환된 PCM 버퍼)
    /// nonisolated(unsafe): 오디오 콜백(백그라운드 큐)에서 접근하므로 MainActor 격리 제외
    var onAudioPCMBuffer: ((AVAudioPCMBuffer) -> Void)?

    // MARK: - 오디오 설정 상수

    /// STT에 최적화된 샘플레이트 (16kHz)
    static let sampleRate: Double = 16000.0

    /// 채널 수 (모노)
    static let channelCount: Int = 1

    /// 비트 뎁스 (Float32)
    static let bitDepth: Int = 32

    // MARK: - Private 프로퍼티

    private var stream: SCStream?
    private var contentFilter: SCContentFilter?

    /// 오디오 스트림 출력 처리를 위한 전용 디스패치 큐
    private let audioCaptureQueue = DispatchQueue(
        label: "ing.unlimit.oratio.audioCaptureQueue",
        qos: .userInteractive
    )

    /// PCM 변환용 오디오 포맷 (16kHz 모노)
    private lazy var targetAudioFormat: AVAudioFormat? = {
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.sampleRate,
            channels: AVAudioChannelCount(Self.channelCount),
            interleaved: false
        )
    }()

    /// 48kHz → 16kHz 리샘플링 컨버터
    private var audioConverter: AVAudioConverter?

    // MARK: - 권한 확인

    /// 화면 녹화 권한을 확인한다.
    /// ScreenCaptureKit은 시스템 오디오 캡처 시 화면 녹화 권한이 필요하다.
    /// - Returns: 권한이 부여되었는지 여부
    func checkPermission() async -> Bool {
        do {
            // SCShareableContent 조회를 시도하여 권한 상태를 확인한다.
            // 권한이 없으면 시스템이 자동으로 권한 요청 다이얼로그를 표시한다.
            let _ = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            return true
        } catch {
            return false
        }
    }

    // MARK: - 캡처 시작

    /// 오디오 캡처를 시작한다.
    /// - Throws: AudioCaptureError
    func startCapture() async throws {
        guard !isCapturing else {
            throw AudioCaptureError.alreadyCapturing
        }

        // 1. 캡처 가능한 콘텐츠 조회 (권한 요청도 동시에 수행됨)
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
        } catch {
            let nsError = error as NSError
            print("[AudioCaptureService] SCShareableContent 에러: domain=\(nsError.domain) code=\(nsError.code) desc=\(nsError.localizedDescription)")
            if nsError.code == -3801 {
                await MainActor.run {
                    self.lastError = .permissionDenied
                }
                throw AudioCaptureError.permissionDenied
            }
            await MainActor.run {
                self.lastError = .noShareableContent
            }
            throw AudioCaptureError.noShareableContent
        }

        // 2. SCContentFilter 설정 - 전체 시스템 오디오 캡처
        // 디스플레이 기반 필터를 사용하되, 특정 앱을 제외하지 않음 (전체 오디오)
        guard let display = content.displays.first else {
            await MainActor.run {
                self.lastError = .noShareableContent
            }
            throw AudioCaptureError.noShareableContent
        }

        // 전체 디스플레이의 오디오를 캡처하되, 자기 자신(Oratio)의 오디오는 제외
        let selfApp = content.applications.filter {
            $0.bundleIdentifier == Bundle.main.bundleIdentifier
        }
        let filter = SCContentFilter(display: display, excludingApplications: selfApp, exceptingWindows: [])
        self.contentFilter = filter

        // 3. SCStreamConfiguration 설정 - 오디오 전용
        let configuration = SCStreamConfiguration()

        // 비디오 설정 - 오디오만 필요하지만 유효한 해상도가 필수 (macOS 15+)
        configuration.width = max(Int(display.width), 2)
        configuration.height = max(Int(display.height), 2)
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1) // 최소 프레임레이트
        configuration.showsCursor = false

        // 오디오 활성화
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true // 자기 자신의 오디오 제외
        configuration.sampleRate = 48000  // 시스템 기본값 사용 (STT 변환은 별도 처리)
        configuration.channelCount = 2     // 스테레오 (시스템 기본값)

        // 4. SCStream 생성
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        self.stream = stream

        // 5. 오디오 출력 핸들러 추가
        do {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioCaptureQueue)
        } catch {
            self.stream = nil
            await MainActor.run {
                self.lastError = .streamCreationFailed(error)
            }
            throw AudioCaptureError.streamCreationFailed(error)
        }

        // 6. 스트림 시작
        do {
            try await stream.startCapture()
        } catch {
            self.stream = nil
            await MainActor.run {
                self.lastError = .streamStartFailed(error)
            }
            throw AudioCaptureError.streamStartFailed(error)
        }
        await MainActor.run {
            self.isCapturing = true
            self.lastError = nil
        }

        print("[AudioCaptureService] 시스템 오디오 캡처 시작 (sampleRate: \(Self.sampleRate)Hz, channels: \(Self.channelCount))")
    }

    // MARK: - 캡처 정지

    /// 오디오 캡처를 정지한다.
    func stopCapture() {
        guard isCapturing, let stream = self.stream else {
            return
        }

        // 즉시 상태를 false로 설정하여 빠른 stop/start 시 상태 불일치 방지
        self.isCapturing = false
        self.audioLevel = 0.0

        // 비동기로 스트림 정지 및 정리
        Task {
            do {
                try await stream.stopCapture()
            } catch {
                print("[AudioCaptureService] 스트림 정지 중 에러: \(error.localizedDescription)")
            }

            await MainActor.run {
                self.stream = nil
                self.contentFilter = nil
            }

            print("[AudioCaptureService] 시스템 오디오 캡처 정지")
        }
    }

    // MARK: - 오디오 변환 유틸리티

    /// CMSampleBuffer를 AVAudioPCMBuffer로 변환한다.
    /// - Parameter sampleBuffer: 변환할 CMSampleBuffer
    /// - Returns: 변환된 AVAudioPCMBuffer, 실패 시 nil
    static func convertToAudioPCMBuffer(_ sampleBuffer: CMSampleBuffer) -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) else {
            print("[AudioCaptureService] FormatDescription을 가져올 수 없습니다.")
            return nil
        }

        let audioStreamBasicDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
        guard let asbd = audioStreamBasicDescription?.pointee else {
            print("[AudioCaptureService] AudioStreamBasicDescription을 가져올 수 없습니다.")
            return nil
        }

        guard let avAudioFormat = AVAudioFormat(streamDescription: &UnsafeMutablePointer(mutating: audioStreamBasicDescription!).pointee) else {
            print("[AudioCaptureService] AVAudioFormat 생성 실패")
            return nil
        }

        let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
        guard frameCount > 0 else {
            return nil
        }

        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: avAudioFormat, frameCapacity: AVAudioFrameCount(frameCount)) else {
            print("[AudioCaptureService] AVAudioPCMBuffer 생성 실패")
            return nil
        }
        pcmBuffer.frameLength = AVAudioFrameCount(frameCount)

        // CMSampleBuffer에서 오디오 데이터를 AVAudioPCMBuffer로 복사
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            print("[AudioCaptureService] DataBuffer를 가져올 수 없습니다.")
            return nil
        }

        var lengthAtOffset: Int = 0
        var totalLength: Int = 0
        var dataPointer: UnsafeMutablePointer<Int8>?

        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: &lengthAtOffset,
            totalLengthOut: &totalLength,
            dataPointerOut: &dataPointer
        )

        guard status == kCMBlockBufferNoErr, let sourceData = dataPointer else {
            print("[AudioCaptureService] BlockBuffer 데이터 접근 실패")
            return nil
        }

        // Float32 데이터를 PCM 버퍼에 복사
        if let channelData = pcmBuffer.floatChannelData {
            let bytesPerFrame = Int(asbd.mBytesPerFrame)
            let channelCount = Int(asbd.mChannelsPerFrame)

            if asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 {
                // Non-interleaved: 각 채널이 별도의 버퍼에 저장됨
                let framesDataSize = frameCount * Int(asbd.mBytesPerFrame)
                for channel in 0..<channelCount {
                    let sourceOffset = channel * framesDataSize
                    memcpy(channelData[channel], sourceData.advanced(by: sourceOffset), min(framesDataSize, totalLength - sourceOffset))
                }
            } else {
                // Interleaved: 채널 데이터가 교차 저장됨
                // 모노인 경우 직접 복사
                if channelCount == 1 {
                    memcpy(channelData[0], sourceData, min(totalLength, frameCount * bytesPerFrame))
                } else {
                    // 멀티채널 interleaved -> non-interleaved 변환
                    let sourceFloats = UnsafeBufferPointer(
                        start: UnsafeRawPointer(sourceData).assumingMemoryBound(to: Float.self),
                        count: frameCount * channelCount
                    )
                    for frame in 0..<frameCount {
                        for channel in 0..<channelCount {
                            channelData[channel][frame] = sourceFloats[frame * channelCount + channel]
                        }
                    }
                }
            }
        }

        return pcmBuffer
    }

    // MARK: - 리샘플링

    /// 소스 버퍼를 targetAudioFormat(16kHz 모노)으로 리샘플링한다.
    private func resampleToTarget(_ sourceBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let targetFormat = targetAudioFormat else { return nil }

        let sourceFormat = sourceBuffer.format

        // 이미 같은 포맷이면 변환 불필요
        if sourceFormat.sampleRate == targetFormat.sampleRate
            && sourceFormat.channelCount == targetFormat.channelCount {
            return nil
        }

        // 컨버터 생성 (최초 1회 또는 포맷 변경 시)
        if audioConverter == nil || audioConverter?.inputFormat != sourceFormat {
            audioConverter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let converter = audioConverter else { return nil }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(Double(sourceBuffer.frameLength) * ratio)
        guard outputFrameCount > 0 else { return nil }

        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrameCount) else {
            return nil
        }

        var error: NSError?
        var consumed = false
        converter.convert(to: outputBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return sourceBuffer
        }

        if let error = error {
            print("[AudioCaptureService] 리샘플링 에러: \(error)")
            return nil
        }

        return outputBuffer.frameLength > 0 ? outputBuffer : nil
    }

    // MARK: - 오디오 레벨 계산

    /// PCM 버퍼에서 오디오 레벨(RMS)을 계산한다.
    /// - Parameter buffer: 분석할 AVAudioPCMBuffer
    /// - Returns: 0.0 ~ 1.0 사이의 오디오 레벨
    private func calculateAudioLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let channelData = buffer.floatChannelData else { return 0.0 }

        let frameLength = Int(buffer.frameLength)
        guard frameLength > 0 else { return 0.0 }

        let channelDataValue = channelData[0]
        var sum: Float = 0.0

        for i in 0..<frameLength {
            let sample = channelDataValue[i]
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(frameLength))

        // RMS를 0.0 ~ 1.0 범위로 정규화 (dB 스케일 기반)
        // -60dB 이하는 0.0, 0dB는 1.0
        let minDb: Float = -60.0
        let db = 20.0 * log10(max(rms, 1e-10))
        let normalizedLevel = max(0.0, min(1.0, (db - minDb) / (-minDb)))

        return normalizedLevel
    }
}

// MARK: - SCStreamDelegate

extension AudioCaptureService: SCStreamDelegate {

    /// 스트림이 에러로 인해 중단되었을 때 호출된다.
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        print("[AudioCaptureService] 스트림 에러로 중단: \(error.localizedDescription)")

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.isCapturing = false
            self.audioLevel = 0.0
            self.stream = nil
            self.contentFilter = nil

            let nsError = error as NSError
            if nsError.code == -3802 {
                self.lastError = .permissionDenied
            } else {
                self.lastError = .streamStartFailed(error)
            }
        }
    }
}

// MARK: - SCStreamOutput

extension AudioCaptureService: SCStreamOutput {

    /// 스트림에서 새로운 오디오/비디오 샘플이 도착했을 때 호출된다.
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        // 오디오 타입만 처리
        guard type == .audio else { return }

        // CMSampleBuffer가 유효한지 확인
        guard CMSampleBufferIsValid(sampleBuffer) else { return }
        guard CMSampleBufferGetNumSamples(sampleBuffer) > 0 else { return }

        // 콜백 1: CMSampleBuffer 원본 전달
        onAudioSampleBuffer?(sampleBuffer)

        // 콜백 2: AVAudioPCMBuffer로 변환 → 16kHz 리샘플링 후 전달
        if let pcmBuffer = Self.convertToAudioPCMBuffer(sampleBuffer) {
            // 리샘플링 (48kHz → 16kHz)
            let outputBuffer: AVAudioPCMBuffer
            if let resampled = resampleToTarget(pcmBuffer) {
                outputBuffer = resampled
            } else {
                outputBuffer = pcmBuffer
            }

            // 오디오 레벨 업데이트
            let level = calculateAudioLevel(from: outputBuffer)
            DispatchQueue.main.async { [weak self] in
                self?.audioLevel = level
            }

            onAudioPCMBuffer?(outputBuffer)
        }
    }
}
