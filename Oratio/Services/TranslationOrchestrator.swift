import AVFoundation
import Combine
import Foundation

/// Soniox 실시간 STT + 번역 오케스트레이터
/// 파이프라인: AudioCapture → Soniox STT (+ 실시간 번역) → UI
/// 양방향: 시스템 오디오 (en→ko) + 마이크 (ko→en)
@MainActor
class TranslationOrchestrator: ObservableObject {

    // MARK: - Published 프로퍼티 (UI 관찰용)

    @Published var entries: [TranslationEntry] = []
    @Published var isRunning: Bool = false
    @Published var isMicRunning: Bool = false
    @Published var errorMessage: String?
    @Published var lastAddedEntryID: UUID?

    // MARK: - 서비스 의존성

    private let audioCaptureService: AudioCaptureService
    let micCaptureService: MicCaptureService
    private let rawMixMicrophoneCaptureService: MicrophoneCaptureService
    private let settings: AppSettings

    // MARK: - Soniox STT (시스템 오디오용)

    private var soniox: SonioxSTT?
    private var audioMixingService: AudioMixingService?
    private var systemAudioPump: SonioxAudioPump?

    // MARK: - Soniox STT (마이크용)

    private var micSoniox: SonioxSTT?
    private var micAudioPump: SonioxAudioPump?

    // MARK: - 상태 관리 (시스템 오디오)

    private var currentPartialEntryID: UUID?
    private var currentSpeaker: String?
    private var isStopping: Bool = false
    private var currentSentenceCount: Int = 0
    private let maxSentencesPerEntry = 5
    private var consumedStableOriginalCount: Int = 0
    private var consumedStableTranslationCount: Int = 0
    private var isSystemRunRawMixExperiment: Bool = false

    // MARK: - 상태 관리 (마이크)

    private var micPartialEntryID: UUID?
    private var micSentenceCount: Int = 0
    private var isMicStopping: Bool = false

    // MARK: - 초기화

    init(
        audioCaptureService: AudioCaptureService,
        micCaptureService: MicCaptureService = MicCaptureService(),
        rawMixMicrophoneCaptureService: MicrophoneCaptureService = MicrophoneCaptureService(),
        settings: AppSettings = AppSettings.shared
    ) {
        self.audioCaptureService = audioCaptureService
        self.micCaptureService = micCaptureService
        self.rawMixMicrophoneCaptureService = rawMixMicrophoneCaptureService
        self.settings = settings
    }

    // MARK: - 시스템 오디오 파이프라인 제어

    func start() async {
        guard !isRunning else { return }
        errorMessage = nil
        isStopping = false

        let stt = SonioxSTT()
        self.soniox = stt
        self.systemAudioPump = SonioxAudioPump(
            stt: stt,
            label: "ing.unlimit.oratio.systemAudioPump"
        )

        await stt.setHandlers(
            onUpdate: { [weak self] update in
                Task { @MainActor [weak self] in
                    self?.handleSonioxUpdate(update)
                }
            },
            onError: { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.handleSTTError(error)
                }
            }
        )

        let isMixExperimentEnabled = settings.isMicrophoneMixExperimentEnabled
        isSystemRunRawMixExperiment = isMixExperimentEnabled
        if isMixExperimentEnabled, isMicRunning {
            print("[Oratio] raw mix 실험 시작 전 기존 마이크 전용 파이프라인을 정리합니다.")
            stopMic()
        }
        configureAudioPipeline(for: stt, isMixExperimentEnabled: isMixExperimentEnabled)

        do {
            try await audioCaptureService.startCapture()
            if isMixExperimentEnabled {
                try await rawMixMicrophoneCaptureService.startCapture()
            }
        } catch {
            errorMessage = "오디오 캡처 시작 실패: \(error.localizedDescription)"
            rawMixMicrophoneCaptureService.stopCapture()
            audioCaptureService.stopCapture()
            cleanupSystemAudio()
            return
        }

        do {
            let translationMode: SonioxTranslationMode = isMixExperimentEnabled
                ? .twoWay(languageA: "en", languageB: "ko")
                : .oneWay(targetLanguage: "ko")
            let languageHints = isMixExperimentEnabled ? ["en", "ko"] : ["en"]
            try await stt.connect(
                apiKey: settings.sonioxApiKey,
                languageHints: languageHints,
                translationMode: translationMode
            )
        } catch {
            errorMessage = "Soniox 연결 실패: \(error.localizedDescription)"
            rawMixMicrophoneCaptureService.stopCapture()
            audioCaptureService.stopCapture()
            cleanupSystemAudio()
            return
        }

        isRunning = true
        if isMixExperimentEnabled {
            print("[Oratio] ===== 시스템 파이프라인 시작 (raw mix 실험, Soniox en↔ko two-way) =====")
        } else {
            print("[Oratio] ===== 시스템 파이프라인 시작 (Soniox STT + 실시간 번역 en→ko) =====")
        }
    }

    func stop() {
        guard isRunning else { return }
        isStopping = true
        isRunning = false

        audioCaptureService.onAudioPCMBuffer = nil
        rawMixMicrophoneCaptureService.onAudioPCMBuffer = nil

        rawMixMicrophoneCaptureService.stopCapture()
        audioCaptureService.stopCapture()
        audioMixingService?.flush()

        let stt = soniox
        let pump = systemAudioPump
        Task {
            await pump?.flush()
            pump?.close()
            await stt?.setHandlers(onUpdate: nil, onError: nil)
            await stt?.stop()
        }

        if let partialID = currentPartialEntryID {
            finalizeSystemPartialEntry(id: partialID)
        }

        cleanupSystemAudio()
        isStopping = false
    }

    // MARK: - 마이크 파이프라인 제어

    func startMic() async {
        guard !isMicRunning else { return }

        if settings.isMicrophoneMixExperimentEnabled {
            errorMessage = "raw mix 실험 모드에서는 별도 마이크 스트림 대신 시작 버튼만 사용하세요."
            return
        }

        isMicStopping = false

        let stt = SonioxSTT()
        self.micSoniox = stt
        self.micAudioPump = SonioxAudioPump(
            stt: stt,
            label: "ing.unlimit.oratio.micAudioPump"
        )

        await stt.setHandlers(
            onUpdate: { [weak self] update in
                Task { @MainActor [weak self] in
                    self?.handleMicSonioxUpdate(update)
                }
            },
            onError: { [weak self] error in
                Task { @MainActor [weak self] in
                    self?.handleMicSTTError(error)
                }
            }
        )

        let micPump = micAudioPump
        micCaptureService.onAudioPCMBuffer = { [weak micPump] buffer in
            guard let data = buffer.int16Data() else { return }
            micPump?.append(data)
        }

        do {
            try micCaptureService.startCapture()
        } catch {
            errorMessage = "마이크 캡처 시작 실패: \(error.localizedDescription)"
            cleanupMic()
            return
        }

        do {
            try await stt.connect(
                apiKey: settings.sonioxApiKey,
                languageHints: ["ko"],
                translationMode: .oneWay(targetLanguage: "en")
            )
        } catch {
            errorMessage = "마이크 Soniox 연결 실패: \(error.localizedDescription)"
            micCaptureService.stopCapture()
            cleanupMic()
            return
        }

        isMicRunning = true
        print("[Oratio] ===== 마이크 파이프라인 시작 (Soniox STT + 실시간 번역 ko→en) =====")
    }

    func stopMic() {
        guard isMicRunning else { return }
        isMicStopping = true
        isMicRunning = false

        micCaptureService.onAudioPCMBuffer = nil

        let stt = micSoniox
        let pump = micAudioPump
        Task {
            await pump?.flush()
            pump?.close()
            await stt?.setHandlers(onUpdate: nil, onError: nil)
            await stt?.stop()
        }

        micCaptureService.stopCapture()

        if let partialID = micPartialEntryID {
            finalizeMicPartialEntry(id: partialID)
        }

        cleanupMic()
        isMicStopping = false
    }

    func clearEntries() {
        entries.removeAll()
        currentPartialEntryID = nil
        currentSpeaker = nil
        currentSentenceCount = 0
        consumedStableOriginalCount = 0
        consumedStableTranslationCount = 0
        micPartialEntryID = nil
        micSentenceCount = 0
    }

    // MARK: - Soniox 업데이트 처리 (시스템)

    private func handleSonioxUpdate(_ update: SonioxUpdate) {
        guard isRunning, !isStopping else { return }

        let currentStableOriginal = String(update.stableText.dropFirst(consumedStableOriginalCount))
        let currentStableTranslation = String(update.stableTranslation.dropFirst(consumedStableTranslationCount))

        let fullOriginal = (currentStableOriginal + update.unstableText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fullTranslation = (currentStableTranslation + update.unstableTranslation)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !fullOriginal.isEmpty else { return }

        if let newSpeaker = update.speaker,
           let current = currentSpeaker,
           newSpeaker != current,
           let entryID = currentPartialEntryID {
            finalizeSystemPartialEntry(id: entryID)
            consumedStableOriginalCount = update.stableText.count
            consumedStableTranslationCount = update.stableTranslation.count
        }

        currentSpeaker = update.speaker

        let sentenceCount = countSentences(in: currentStableOriginal)
        if sentenceCount >= maxSentencesPerEntry,
           let entryID = currentPartialEntryID,
           let index = entries.firstIndex(where: { $0.id == entryID }) {
            let trimmedOriginal = currentStableOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedTranslation = currentStableTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedOriginal.isEmpty {
                entries[index].originalText = trimmedOriginal
                entries[index].translatedText = trimmedTranslation.isEmpty ? nil : trimmedTranslation
            }
            entries[index].isFinalized = true
            currentPartialEntryID = nil
            currentSentenceCount = 0
            consumedStableOriginalCount = update.stableText.count
            consumedStableTranslationCount = update.stableTranslation.count
            print("[Oratio] 시스템 엔트리 분리 (\(sentenceCount)문장): \"\(trimmedOriginal.prefix(60))\"")
            return
        }
        currentSentenceCount = sentenceCount

        if let existingID = currentPartialEntryID,
           let index = entries.firstIndex(where: { $0.id == existingID }) {
            entries[index].originalText = fullOriginal
            entries[index].translatedText = fullTranslation.isEmpty ? nil : fullTranslation
            entries[index].speaker = update.speaker
            entries[index].source = isSystemRunRawMixExperiment ? .rawMix : .systemAudio
        } else {
            let newEntry = TranslationEntry(
                originalText: fullOriginal,
                translatedText: fullTranslation.isEmpty ? nil : fullTranslation,
                speaker: update.speaker,
                source: isSystemRunRawMixExperiment ? .rawMix : .systemAudio
            )
            entries.append(newEntry)
            currentPartialEntryID = newEntry.id
            lastAddedEntryID = newEntry.id
            currentSentenceCount = 0
        }

        if update.isEndpoint {
            if let entryID = currentPartialEntryID {
                if let index = entries.firstIndex(where: { $0.id == entryID }) {
                    let trimmedOriginal = currentStableOriginal.trimmingCharacters(in: .whitespacesAndNewlines)
                    let trimmedTranslation = currentStableTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmedOriginal.isEmpty {
                        entries[index].originalText = trimmedOriginal
                        entries[index].translatedText = trimmedTranslation.isEmpty ? nil : trimmedTranslation
                    }
                    entries[index].isFinalized = true
                }
                currentPartialEntryID = nil
                currentSentenceCount = 0
            }
            consumedStableOriginalCount = 0
            consumedStableTranslationCount = 0
        }
    }

    // MARK: - Soniox 업데이트 처리 (마이크)

    private func handleMicSonioxUpdate(_ update: SonioxUpdate) {
        guard isMicRunning, !isMicStopping else { return }

        let fullOriginal = (update.stableText + update.unstableText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fullTranslation = (update.stableTranslation + update.unstableTranslation)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !fullOriginal.isEmpty else { return }

        let sentenceCount = countSentences(in: update.stableText)
        if sentenceCount >= maxSentencesPerEntry,
           let entryID = micPartialEntryID,
           let index = entries.firstIndex(where: { $0.id == entryID }) {
            let stableOriginal = update.stableText.trimmingCharacters(in: .whitespacesAndNewlines)
            let stableTranslation = update.stableTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
            if !stableOriginal.isEmpty {
                entries[index].originalText = stableOriginal
                entries[index].translatedText = stableTranslation.isEmpty ? nil : stableTranslation
            }
            entries[index].isFinalized = true
            micPartialEntryID = nil
            micSentenceCount = 0
            return
        }
        micSentenceCount = sentenceCount

        if let existingID = micPartialEntryID,
           let index = entries.firstIndex(where: { $0.id == existingID }) {
            entries[index].originalText = fullOriginal
            entries[index].translatedText = fullTranslation.isEmpty ? nil : fullTranslation
            entries[index].source = .microphone
        } else {
            let newEntry = TranslationEntry(
                originalText: fullOriginal,
                translatedText: fullTranslation.isEmpty ? nil : fullTranslation,
                source: .microphone
            )
            entries.append(newEntry)
            micPartialEntryID = newEntry.id
            lastAddedEntryID = newEntry.id
            micSentenceCount = 0
        }

        if update.isEndpoint {
            if let entryID = micPartialEntryID {
                if let index = entries.firstIndex(where: { $0.id == entryID }) {
                    let stableOriginal = update.stableText.trimmingCharacters(in: .whitespacesAndNewlines)
                    let stableTranslation = update.stableTranslation.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !stableOriginal.isEmpty {
                        entries[index].originalText = stableOriginal
                        entries[index].translatedText = stableTranslation.isEmpty ? nil : stableTranslation
                    }
                    entries[index].isFinalized = true
                }
                micPartialEntryID = nil
                micSentenceCount = 0
            }
        }
    }

    // MARK: - 에러 처리

    private func handleSTTError(_ error: Error) {
        guard isRunning, !isStopping else { return }

        print("[Oratio] Soniox 에러: \(error.localizedDescription)")
        if let sonioxError = error as? SonioxError {
            switch sonioxError {
            case .apiKeyMissing:
                errorMessage = "Soniox API 키가 설정되지 않았습니다."
                stop()
            default:
                errorMessage = error.localizedDescription
            }
        } else {
            errorMessage = error.localizedDescription
        }
    }

    private func handleMicSTTError(_ error: Error) {
        guard isMicRunning, !isMicStopping else { return }

        print("[Oratio] 마이크 Soniox 에러: \(error.localizedDescription)")
        if let sonioxError = error as? SonioxError {
            switch sonioxError {
            case .apiKeyMissing:
                errorMessage = "Soniox API 키가 설정되지 않았습니다."
                stopMic()
            default:
                errorMessage = error.localizedDescription
            }
        } else {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 유틸리티

    private func configureAudioPipeline(for stt: SonioxSTT, isMixExperimentEnabled: Bool) {
        let systemPump = systemAudioPump
        if isMixExperimentEnabled {
            let mixer = AudioMixingService(
                micGainDb: settings.mixMicrophoneGainDb,
                micDelayMs: settings.mixMicrophoneDelayMs
            )
            mixer.onMixedPCMBuffer = { [weak systemPump] buffer in
                guard let data = buffer.int16Data() else { return }
                systemPump?.append(data)
            }
            audioMixingService = mixer

            audioCaptureService.onAudioPCMBuffer = { [weak mixer] buffer in
                mixer?.appendSystemAudioBuffer(buffer)
            }
            rawMixMicrophoneCaptureService.onAudioPCMBuffer = { [weak mixer] buffer in
                mixer?.appendMicrophoneBuffer(buffer)
            }
        } else {
            audioMixingService = nil
            rawMixMicrophoneCaptureService.onAudioPCMBuffer = nil
            audioCaptureService.onAudioPCMBuffer = { [weak systemPump] buffer in
                guard let data = buffer.int16Data() else { return }
                systemPump?.append(data)
            }
        }
    }

    private func countSentences(in text: String) -> Int {
        var count = 0
        let chars = Array(text)
        for i in 0..<chars.count {
            if ".?!".contains(chars[i]) {
                let nextIdx = i + 1
                if nextIdx < chars.count && chars[nextIdx] == " " {
                    count += 1
                } else if nextIdx == chars.count {
                    count += 1
                }
            }
        }
        return count
    }

    private func finalizeSystemPartialEntry(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isFinalized = true
        currentPartialEntryID = nil
    }

    private func finalizeMicPartialEntry(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isFinalized = true
        micPartialEntryID = nil
    }

    private func cleanupSystemAudio() {
        soniox = nil
        audioMixingService = nil
        systemAudioPump = nil
        audioCaptureService.onAudioPCMBuffer = nil
        rawMixMicrophoneCaptureService.onAudioPCMBuffer = nil
        currentPartialEntryID = nil
        currentSpeaker = nil
        currentSentenceCount = 0
        consumedStableOriginalCount = 0
        consumedStableTranslationCount = 0
        isSystemRunRawMixExperiment = false
    }

    private func cleanupMic() {
        micSoniox = nil
        micAudioPump = nil
        micCaptureService.onAudioPCMBuffer = nil
        micPartialEntryID = nil
        micSentenceCount = 0
    }
}

private final class SonioxAudioPump: @unchecked Sendable {
    private let stt: SonioxSTT
    private let queue: DispatchQueue
    private let bytesPerChunk: Int
    private let samplesPerChunk: Int

    private var pending = Data()
    private var isSending = false
    private var isClosed = false
    private var lastBacklogLogDate: Date?

    init(stt: SonioxSTT, label: String, chunkDurationMs: Int = 40) {
        self.stt = stt
        self.queue = DispatchQueue(label: label, qos: .userInteractive)
        self.samplesPerChunk = max(1, chunkDurationMs) * SonioxSTT.sampleRate / 1_000
        self.bytesPerChunk = samplesPerChunk * SonioxSTT.numChannels * MemoryLayout<Int16>.size
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }

        queue.async { [weak self] in
            guard let self, !self.isClosed else { return }
            self.pending.append(data)
            self.logBacklogIfNeeded()
            self.scheduleNextSendIfNeeded()
        }
    }

    func flush() async {
        let chunks: [Data] = queue.sync {
            guard !isClosed, !pending.isEmpty else { return [] }

            var drainedChunks: [Data] = []
            while !pending.isEmpty {
                let chunkSize = min(bytesPerChunk, pending.count)
                drainedChunks.append(pending.prefix(chunkSize))
                pending.removeFirst(chunkSize)
            }
            return drainedChunks
        }

        for chunk in chunks {
            try? await stt.sendAudioData(chunk)
        }
    }

    func close() {
        queue.sync {
            isClosed = true
            pending.removeAll(keepingCapacity: false)
            isSending = false
        }
    }

    private func scheduleNextSendIfNeeded() {
        guard !isClosed, !isSending, pending.count >= bytesPerChunk else { return }

        let chunk = pending.prefix(bytesPerChunk)
        pending.removeFirst(bytesPerChunk)
        isSending = true

        Task { [weak self, stt] in
            try? await stt.sendAudioData(chunk)
            self?.queue.async { [weak self] in
                guard let self else { return }
                self.isSending = false
                self.scheduleNextSendIfNeeded()
            }
        }
    }

    private func logBacklogIfNeeded() {
        guard bytesPerChunk > 0 else { return }

        let queuedSamples = pending.count / (SonioxSTT.numChannels * MemoryLayout<Int16>.size)
        let queuedDurationMs = Int((Double(queuedSamples) / Double(SonioxSTT.sampleRate) * 1000.0).rounded())
        guard queuedDurationMs >= 500 else { return }

        let now = Date()
        if let lastBacklogLogDate,
           now.timeIntervalSince(lastBacklogLogDate) < 2.0 {
            return
        }

        lastBacklogLogDate = now
        let approxChunkCount = max(1, queuedSamples / samplesPerChunk)
        print("[SonioxAudioPump] 송신 backlog 감지: 약 \(queuedDurationMs)ms (\(approxChunkCount) chunks)")
    }
}
