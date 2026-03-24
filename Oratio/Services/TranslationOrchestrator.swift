import Foundation
import Combine
import AVFoundation

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
    private let settings: AppSettings

    // MARK: - Soniox STT (시스템 오디오용)

    private var soniox: SonioxSTT?

    // MARK: - Soniox STT (마이크용)

    private var micSoniox: SonioxSTT?

    // MARK: - 상태 관리 (시스템 오디오)

    /// 현재 진행 중인 부분 결과 엔트리의 ID
    private var currentPartialEntryID: UUID?

    /// 현재 엔트리의 화자
    private var currentSpeaker: String?

    /// 사용자가 정지를 눌러 파이프라인을 내리는 중인지 여부
    private var isStopping: Bool = false

    /// 현재 엔트리의 stableText에서 확인된 문장 수
    private var currentSentenceCount: Int = 0

    /// 최대 문장 수 (이 수에 도달하면 엔트리 분리)
    private let maxSentencesPerEntry = 5

    /// 이전 엔트리들에서 이미 소비(확정)된 stableText 길이
    /// Soniox의 stableText는 endpoint까지 계속 누적되므로,
    /// 5문장 분리 시 이미 확정된 부분을 건너뛰기 위해 사용
    private var consumedStableOriginalCount: Int = 0
    private var consumedStableTranslationCount: Int = 0

    // MARK: - 상태 관리 (마이크)

    private var micPartialEntryID: UUID?
    private var micSentenceCount: Int = 0
    private var isMicStopping: Bool = false

    // MARK: - 초기화

    init(
        audioCaptureService: AudioCaptureService,
        micCaptureService: MicCaptureService = MicCaptureService(),
        settings: AppSettings = AppSettings.shared
    ) {
        self.audioCaptureService = audioCaptureService
        self.micCaptureService = micCaptureService
        self.settings = settings
    }

    // MARK: - 파이프라인 제어

    func start() async {
        guard !isRunning else { return }
        errorMessage = nil
        isStopping = false

        let stt = SonioxSTT()
        self.soniox = stt

        // Soniox 콜백 설정
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

        // 오디오 캡처 → Soniox 파이프라인 연결
        audioCaptureService.onAudioPCMBuffer = { [weak stt] buffer in
            guard let data = buffer.int16Data() else { return }
            Task {
                try? await stt?.sendAudioData(data)
            }
        }

        do {
            try await audioCaptureService.startCapture()
        } catch {
            errorMessage = "오디오 캡처 시작 실패: \(error.localizedDescription)"
            cleanupSystemAudio()
            return
        }

        do {
            try await stt.connect(apiKey: settings.sonioxApiKey)
        } catch {
            errorMessage = "Soniox 연결 실패: \(error.localizedDescription)"
            audioCaptureService.stopCapture()
            cleanupSystemAudio()
            return
        }

        isRunning = true
        print("[Oratio] ===== 파이프라인 시작 (Soniox STT + 실시간 번역) =====")
    }

    func stop() {
        guard isRunning else { return }
        isStopping = true
        isRunning = false

        audioCaptureService.onAudioPCMBuffer = nil

        // Soniox 비동기 종료
        let stt = soniox
        Task {
            await stt?.setHandlers(onUpdate: nil, onError: nil)
            await stt?.stop()
        }

        audioCaptureService.stopCapture()

        if let partialID = currentPartialEntryID {
            finalizePartialEntry(id: partialID)
        }

        cleanupSystemAudio()
        isStopping = false
    }

    // MARK: - 마이크 파이프라인 제어

    func startMic() async {
        guard !isMicRunning else { return }
        isMicStopping = false

        let stt = SonioxSTT()
        self.micSoniox = stt

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

        micCaptureService.onAudioPCMBuffer = { [weak stt] buffer in
            guard let data = buffer.int16Data() else { return }
            Task {
                try? await stt?.sendAudioData(data)
            }
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
                targetLanguage: "en"
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
        Task {
            await stt?.setHandlers(onUpdate: nil, onError: nil)
            await stt?.stop()
        }

        micCaptureService.stopCapture()

        if let partialID = micPartialEntryID {
            finalizePartialEntry(id: partialID)
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

    // MARK: - Soniox 업데이트 처리

    private func handleSonioxUpdate(_ update: SonioxUpdate) {
        guard isRunning, !isStopping else { return }

        // Soniox stableText는 endpoint까지 계속 누적됨.
        // 5문장 분리로 이미 확정된 부분을 제외한 "현재 엔트리" 텍스트만 추출
        let currentStableOriginal = String(update.stableText.dropFirst(consumedStableOriginalCount))
        let currentStableTranslation = String(update.stableTranslation.dropFirst(consumedStableTranslationCount))

        let fullOriginal = (currentStableOriginal + update.unstableText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fullTranslation = (currentStableTranslation + update.unstableTranslation)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !fullOriginal.isEmpty else { return }

        // 화자 변경 감지 → 현재 엔트리 확정 후 새 엔트리 시작
        if let newSpeaker = update.speaker,
           let current = currentSpeaker,
           newSpeaker != current,
           let entryID = currentPartialEntryID {
            finalizePartialEntry(id: entryID)
            consumedStableOriginalCount = update.stableText.count
            consumedStableTranslationCount = update.stableTranslation.count
        }

        currentSpeaker = update.speaker

        // 5문장 도달 체크 — 현재 엔트리의 stableText 기준
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
            // 소비된 위치 업데이트 — 다음 엔트리는 여기서부터 시작
            consumedStableOriginalCount = update.stableText.count
            consumedStableTranslationCount = update.stableTranslation.count
            print("[Oratio] 엔트리 분리 (\(sentenceCount)문장): \"\(trimmedOriginal.prefix(60))\"")
            // unstable 부분은 다음 업데이트에서 새 엔트리로 생성됨
            return
        }
        currentSentenceCount = sentenceCount

        // 현재 엔트리 업데이트 또는 생성
        if let existingID = currentPartialEntryID,
           let index = entries.firstIndex(where: { $0.id == existingID }) {
            entries[index].originalText = fullOriginal
            entries[index].translatedText = fullTranslation.isEmpty ? nil : fullTranslation
            entries[index].speaker = update.speaker
        } else {
            let newEntry = TranslationEntry(
                originalText: fullOriginal,
                translatedText: fullTranslation.isEmpty ? nil : fullTranslation,
                speaker: update.speaker
            )
            entries.append(newEntry)
            currentPartialEntryID = newEntry.id
            lastAddedEntryID = newEntry.id
            currentSentenceCount = 0
            print("[Oratio] 새 엔트리 생성 (speaker: \(update.speaker ?? "-"))")
        }

        // Endpoint 감지 → 엔트리 확정
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
                    print("[Oratio] 엔트리 확정 (endpoint): \"\(trimmedOriginal.prefix(60))\"")
                }
                currentPartialEntryID = nil
                currentSentenceCount = 0
            }
            // Endpoint 후 Soniox가 stableText를 리셋하므로 consumed 카운터도 리셋
            consumedStableOriginalCount = 0
            consumedStableTranslationCount = 0
        }
    }

    // MARK: - 마이크 업데이트 처리

    private func handleMicSonioxUpdate(_ update: SonioxUpdate) {
        guard isMicRunning, !isMicStopping else { return }

        let fullOriginal = (update.stableText + update.unstableText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fullTranslation = (update.stableTranslation + update.unstableTranslation)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !fullOriginal.isEmpty else { return }

        // 에코 필터: 마이크는 한국어 입력용이므로 원문에 한글이 없으면
        // 스피커에서 나온 영어 에코가 인식된 것으로 판단하여 무시한다.
        if !containsKorean(fullOriginal) {
            // 에코로 만들어진 진행 중 엔트리가 있으면 제거
            if let entryID = micPartialEntryID,
               let index = entries.firstIndex(where: { $0.id == entryID }) {
                entries.remove(at: index)
                micPartialEntryID = nil
                micSentenceCount = 0
            }
            return
        }

        // 5문장 도달 체크
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

        // 현재 엔트리 업데이트 또는 생성
        if let existingID = micPartialEntryID,
           let index = entries.firstIndex(where: { $0.id == existingID }) {
            entries[index].originalText = fullOriginal
            entries[index].translatedText = fullTranslation.isEmpty ? nil : fullTranslation
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
            print("[Oratio] 마이크 새 엔트리 생성")
        }

        // Endpoint 감지 → 엔트리 확정
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

    /// 텍스트에 한글(Hangul)이 포함되어 있는지 확인
    private func containsKorean(_ text: String) -> Bool {
        return text.unicodeScalars.contains { scalar in
            (0xAC00...0xD7A3).contains(scalar.value) ||  // 완성형 한글
            (0x1100...0x11FF).contains(scalar.value) ||  // 한글 자모
            (0x3130...0x318F).contains(scalar.value)     // 호환용 한글 자모
        }
    }

    /// stableText 내 문장 수 카운트 (마침표/물음표/느낌표 + 공백 기준)
    private func countSentences(in text: String) -> Int {
        var count = 0
        let chars = Array(text)
        for i in 0..<chars.count {
            if ".?!".contains(chars[i]) {
                let nextIdx = i + 1
                if nextIdx < chars.count && chars[nextIdx] == " " {
                    count += 1
                } else if nextIdx == chars.count {
                    count += 1 // 마지막 문자가 구두점
                }
            }
        }
        return count
    }

    private func finalizePartialEntry(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isFinalized = true
        currentPartialEntryID = nil
    }

    private func cleanupSystemAudio() {
        soniox = nil
        audioCaptureService.onAudioPCMBuffer = nil
        currentPartialEntryID = nil
        currentSpeaker = nil
        currentSentenceCount = 0
        consumedStableOriginalCount = 0
        consumedStableTranslationCount = 0
    }

    private func cleanupMic() {
        micSoniox = nil
        micCaptureService.onAudioPCMBuffer = nil
        micPartialEntryID = nil
        micSentenceCount = 0
    }
}
