import AVFoundation
import Foundation

// MARK: - 에러 정의

enum MicrophoneCaptureError: LocalizedError {
    case permissionDenied
    case noInputDevice
    case engineStartFailed(Error)
    case alreadyCapturing

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "마이크 권한이 거부되었습니다. 시스템 설정 > 개인 정보 보호 및 보안 > 마이크에서 Oratio를 허용해 주세요."
        case .noInputDevice:
            return "사용 가능한 마이크 입력 장치를 찾을 수 없습니다."
        case .engineStartFailed(let error):
            return "마이크 캡처 시작 실패: \(error.localizedDescription)"
        case .alreadyCapturing:
            return "이미 마이크 캡처가 진행 중입니다."
        }
    }
}

/// 마이크 오디오 캡처 서비스
final class MicrophoneCaptureService: NSObject, ObservableObject {
    @Published var isCapturing: Bool = false
    @Published var audioLevel: Float = 0.0
    @Published var lastError: MicrophoneCaptureError?

    var onAudioPCMBuffer: ((AVAudioPCMBuffer) -> Void)?

    private let engine = AVAudioEngine()
    private let processingQueue = DispatchQueue(
        label: "ing.unlimit.oratio.microphoneCaptureQueue",
        qos: .userInteractive
    )

    private lazy var targetAudioFormat: AVAudioFormat? = {
        AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioCaptureService.sampleRate,
            channels: AVAudioChannelCount(AudioCaptureService.channelCount),
            interleaved: false
        )
    }()

    private var audioConverter: AVAudioConverter?

    func checkPermission() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                AVCaptureDevice.requestAccess(for: .audio) { granted in
                    continuation.resume(returning: granted)
                }
            }
        default:
            return false
        }
    }

    func startCapture() async throws {
        guard !isCapturing else {
            throw MicrophoneCaptureError.alreadyCapturing
        }

        guard await checkPermission() else {
            await MainActor.run {
                self.lastError = .permissionDenied
            }
            throw MicrophoneCaptureError.permissionDenied
        }

        let inputNode = engine.inputNode
        let inputFormat = inputNode.inputFormat(forBus: 0)

        guard inputFormat.channelCount > 0 else {
            await MainActor.run {
                self.lastError = .noInputDevice
            }
            throw MicrophoneCaptureError.noInputDevice
        }

        inputNode.removeTap(onBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] buffer, _ in
            guard let self else { return }
            guard let ownedBuffer = self.copyBuffer(buffer) else { return }
            self.processingQueue.async { [weak self] in
                self?.handleInputBuffer(ownedBuffer)
            }
        }

        do {
            try engine.start()
        } catch {
            inputNode.removeTap(onBus: 0)
            await MainActor.run {
                self.lastError = .engineStartFailed(error)
            }
            throw MicrophoneCaptureError.engineStartFailed(error)
        }

        await MainActor.run {
            self.isCapturing = true
            self.lastError = nil
        }

        print("[MicrophoneCaptureService] 마이크 캡처 시작")
    }

    func stopCapture() {
        guard isCapturing else { return }

        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        engine.reset()

        isCapturing = false
        audioLevel = 0.0
        audioConverter = nil

        print("[MicrophoneCaptureService] 마이크 캡처 정지")
    }

    private func handleInputBuffer(_ buffer: AVAudioPCMBuffer) {
        let outputBuffer: AVAudioPCMBuffer
        if let resampled = resampleToTarget(buffer) {
            outputBuffer = resampled
        } else {
            outputBuffer = buffer
        }

        let level = calculateAudioLevel(from: outputBuffer)
        DispatchQueue.main.async { [weak self] in
            self?.audioLevel = level
        }

        onAudioPCMBuffer?(outputBuffer)
    }

    private func copyBuffer(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copiedBuffer = AVAudioPCMBuffer(
            pcmFormat: buffer.format,
            frameCapacity: buffer.frameLength
        ) else {
            return nil
        }

        copiedBuffer.frameLength = buffer.frameLength

        let bytesPerFrame = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
        let frameCount = Int(buffer.frameLength)
        let channelCount = Int(buffer.format.channelCount)

        if buffer.format.isInterleaved {
            guard let source = buffer.floatChannelData?[0],
                  let destination = copiedBuffer.floatChannelData?[0] else {
                return nil
            }
            memcpy(destination, source, frameCount * bytesPerFrame)
            return copiedBuffer
        }

        guard let sourceChannelData = buffer.floatChannelData,
              let destinationChannelData = copiedBuffer.floatChannelData else {
            return nil
        }

        let bytesPerChannel = frameCount * MemoryLayout<Float>.size
        for channel in 0..<channelCount {
            memcpy(destinationChannelData[channel], sourceChannelData[channel], bytesPerChannel)
        }

        return copiedBuffer
    }

    private func resampleToTarget(_ sourceBuffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let targetFormat = targetAudioFormat else { return nil }

        let sourceFormat = sourceBuffer.format
        let needsConversion =
            sourceFormat.sampleRate != targetFormat.sampleRate ||
            sourceFormat.channelCount != targetFormat.channelCount ||
            sourceFormat.commonFormat != targetFormat.commonFormat ||
            sourceFormat.isInterleaved != targetFormat.isInterleaved

        if !needsConversion {
            return nil
        }

        if audioConverter == nil || audioConverter?.inputFormat != sourceFormat {
            audioConverter = AVAudioConverter(from: sourceFormat, to: targetFormat)
        }
        guard let converter = audioConverter else { return nil }

        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrameCount = AVAudioFrameCount(max(1, Int((Double(sourceBuffer.frameLength) * ratio).rounded(.up))))

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

        if let error {
            print("[MicrophoneCaptureService] 리샘플링 에러: \(error.localizedDescription)")
            return nil
        }

        return outputBuffer.frameLength > 0 ? outputBuffer : nil
    }

    private func calculateAudioLevel(from buffer: AVAudioPCMBuffer) -> Float {
        guard let samples = buffer.monoFloatSamples(), !samples.isEmpty else { return 0.0 }

        var sum: Float = 0.0
        for sample in samples {
            sum += sample * sample
        }

        let rms = sqrt(sum / Float(samples.count))
        let minDb: Float = -60.0
        let db = 20.0 * log10(max(rms, 1e-10))
        return max(0.0, min(1.0, (db - minDb) / (-minDb)))
    }
}
