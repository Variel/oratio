import Foundation
import Combine
import AVFoundation

/// 이중 번역 오케스트레이터
/// Soniox STT 결과를 받아 초벌/재벌 번역을 조율하고,
/// 전체 파이프라인(AudioCapture -> Soniox STT -> Translation -> UI)을 관리한다.
@MainActor
class TranslationOrchestrator: ObservableObject {

    // MARK: - Published 프로퍼티 (UI 관찰용)

    @Published var entries: [TranslationEntry] = []
    @Published var isRunning: Bool = false
    @Published var errorMessage: String?
    @Published var lastAddedEntryID: UUID?

    // MARK: - 서비스 의존성

    private let audioCaptureService: AudioCaptureService
    private let quickTranslation: QuickTranslationService
    private let contextTranslation: ContextTranslationService
    private let settings: AppSettings

    // MARK: - Soniox STT

    private var soniox: SonioxSTT?

    // MARK: - 상태 관리

    /// 현재 진행 중인 부분 결과 엔트리의 ID
    private var currentPartialEntryID: UUID?

    /// 현재 엔트리의 화자
    private var currentSpeaker: String?

    /// 초벌 번역 스로틀 타이머 태스크
    private var quickTranslationTask: Task<Void, Never>?

    /// 진행 중인 초벌 번역 API 태스크
    private var quickTranslationRequestTask: Task<Void, Never>?

    /// 초벌 번역 최신 요청 (스로틀 대기열: 최신 1개만 유지)
    private var pendingQuickTranslation: (text: String, entryID: UUID)?

    /// 맥락 유지: 최근 완성된 번역 쌍
    private var translationContextHistory: [TranslationContext] = []

    /// 맥락에 유지할 최대 문장 수
    private let maxContextSize = 10

    /// 초벌 번역 트리거를 위한 최소 단어 수
    private let minimumWordCount = 3

    /// 초벌 번역 스로틀 간격 (초)
    private let quickTranslationThrottleInterval: TimeInterval = 0.7

    /// 마지막 초벌 번역 디스패치 시각
    private var lastQuickTranslationDispatchAt: Date = .distantPast

    /// 마지막으로 초벌 번역을 트리거한 stableText 길이
    private var lastQuickTranslationStableLength: Int = 0

    /// 사용자가 정지를 눌러 파이프라인을 내리는 중인지 여부
    private var isStopping: Bool = false

    private var cancellables = Set<AnyCancellable>()

    // MARK: - 초기화

    init(
        audioCaptureService: AudioCaptureService,
        quickTranslation: QuickTranslationService = QuickTranslationService(),
        contextTranslation: ContextTranslationService = ContextTranslationService(),
        settings: AppSettings = AppSettings.shared
    ) {
        self.audioCaptureService = audioCaptureService
        self.quickTranslation = quickTranslation
        self.contextTranslation = contextTranslation
        self.settings = settings
    }

    // MARK: - 파이프라인 제어

    func start() async {
        guard !isRunning else { return }
        errorMessage = nil
        isStopping = false
        lastQuickTranslationStableLength = 0

        let stt = SonioxSTT()
        self.soniox = stt

        // Soniox 콜백 설정
        await stt.setHandlers(
            onTokenUpdate: { [weak self] update in
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
            cleanup()
            return
        }

        do {
            try await stt.connect(apiKey: settings.sonioxApiKey)
        } catch {
            errorMessage = "Soniox 연결 실패: \(error.localizedDescription)"
            audioCaptureService.stopCapture()
            cleanup()
            return
        }

        isRunning = true
        print("[Oratio] ===== 파이프라인 시작 (STT: Soniox) =====")
    }

    func stop() {
        guard isRunning else { return }
        isStopping = true
        isRunning = false

        quickTranslationTask?.cancel()
        quickTranslationTask = nil
        quickTranslationRequestTask?.cancel()
        quickTranslationRequestTask = nil
        pendingQuickTranslation = nil

        audioCaptureService.onAudioPCMBuffer = nil

        // Soniox 비동기 종료
        let stt = soniox
        Task {
            await stt?.setHandlers(onTokenUpdate: nil, onError: nil)
            await stt?.stop()
        }

        audioCaptureService.stopCapture()

        if let partialID = currentPartialEntryID {
            finalizePartialEntry(id: partialID)
        }

        cleanup()
        isStopping = false
    }

    func clearEntries() {
        entries.removeAll()
        translationContextHistory.removeAll()
        currentPartialEntryID = nil
        currentSpeaker = nil
        lastQuickTranslationStableLength = 0
    }

    // MARK: - Soniox 토큰 업데이트 처리

    private func handleSonioxUpdate(_ update: SonioxTokenUpdate) {
        guard isRunning, !isStopping else { return }

        let fullText = (update.stableText + update.unstableText)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else { return }

        // 화자 변경 감지 → 현재 엔트리 확정 후 새 엔트리 시작
        if let newSpeaker = update.speaker,
           let current = currentSpeaker,
           newSpeaker != current,
           currentPartialEntryID != nil {
            finalizeCurrentEntry(stableText: update.stableText)
        }

        currentSpeaker = update.speaker

        // 현재 엔트리 업데이트 또는 생성
        if let existingID = currentPartialEntryID,
           let index = entries.firstIndex(where: { $0.id == existingID }) {
            entries[index].originalText = fullText
            entries[index].speaker = update.speaker
        } else {
            let newEntry = TranslationEntry(
                originalText: fullText,
                speaker: update.speaker
            )
            entries.append(newEntry)
            currentPartialEntryID = newEntry.id
            lastAddedEntryID = newEntry.id
            lastQuickTranslationStableLength = 0
            print("[SonioxSTT] 새 엔트리 생성 (speaker: \(update.speaker ?? "-"))")
        }

        // stableText가 갱신되었을 때만 초벌 번역 트리거
        let stableWordCount = update.stableText.split(separator: " ").count
        if stableWordCount >= minimumWordCount,
           update.stableText.count > lastQuickTranslationStableLength {
            lastQuickTranslationStableLength = update.stableText.count
            triggerQuickTranslation(text: update.stableText)
        }

        // Endpoint 감지 → 엔트리 확정 + 재벌 번역
        if update.isEndpoint {
            finalizeCurrentEntry(stableText: update.stableText)
        }
    }

    /// 현재 진행 중인 엔트리를 확정하고 재벌 번역을 트리거한다.
    private func finalizeCurrentEntry(stableText: String) {
        guard let entryID = currentPartialEntryID,
              let index = entries.firstIndex(where: { $0.id == entryID }) else { return }

        let finalText = stableText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !finalText.isEmpty else {
            currentPartialEntryID = nil
            lastQuickTranslationStableLength = 0
            return
        }

        entries[index].originalText = finalText
        entries[index].isFinalized = true
        currentPartialEntryID = nil
        lastQuickTranslationStableLength = 0

        // 초벌 번역 (아직 없으면)
        if entries[index].quickTranslation == nil {
            triggerQuickTranslation(text: finalText, entryID: entryID)
        }

        // 재벌 번역 (이전 endpoint까지의 문장들을 맥락으로)
        fireContextTranslation(text: finalText, entryID: entryID)

        print("[SonioxSTT] 엔트리 확정 (endpoint): \"\(finalText.prefix(60))\"")
    }

    // MARK: - 초벌 번역 (Quick Translation)

    private func triggerQuickTranslation(text: String, entryID: UUID? = nil) {
        let targetID = entryID ?? currentPartialEntryID
        guard let targetID = targetID else { return }

        pendingQuickTranslation = (text: text, entryID: targetID)
        scheduleQuickTranslationIfNeeded()
    }

    private func scheduleQuickTranslationIfNeeded() {
        guard isRunning, !isStopping else { return }
        guard quickTranslationRequestTask == nil else { return } // in-flight 동안은 최신 요청만 누적
        guard pendingQuickTranslation != nil else { return }

        let elapsed = Date().timeIntervalSince(lastQuickTranslationDispatchAt)
        let remaining = quickTranslationThrottleInterval - elapsed

        if remaining > 0 {
            quickTranslationTask?.cancel()
            quickTranslationTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.quickTranslationTask = nil
                    self?.scheduleQuickTranslationIfNeeded()
                }
            }
            return
        }

        guard let request = pendingQuickTranslation else { return }
        pendingQuickTranslation = nil
        lastQuickTranslationDispatchAt = Date()
        quickTranslationTask?.cancel()
        quickTranslationTask = nil

        let requestText = request.text
        let targetID = request.entryID

        quickTranslationRequestTask = Task { [weak self] in
            guard let self = self else { return }
            defer {
                self.quickTranslationRequestTask = nil
                self.scheduleQuickTranslationIfNeeded()
            }
            guard self.isRunning, !self.isStopping else { return }

            let startTime = CFAbsoluteTimeGetCurrent()
            do {
                let translation = try await self.quickTranslation.translate(text: requestText, context: nil)
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime

                guard self.isRunning, !self.isStopping,
                      let index = self.entries.firstIndex(where: { $0.id == targetID }) else { return }

                let latestText = self.entries[index].originalText
                guard latestText == requestText || latestText.hasPrefix(requestText) else { return }
                if let prevSource = self.entries[index].quickTranslationSourceText,
                   prevSource.count > requestText.count {
                    return
                }

                self.entries[index].quickTranslation = translation
                self.entries[index].quickTranslationSourceText = requestText
                print("[Oratio] 초벌 번역 완료 (\(String(format: "%.2f", elapsed))초): \"\(requestText.prefix(30))\" -> \"\(translation.prefix(30))\"")
            } catch {
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                print("[Oratio] 초벌 번역 에러 (\(String(format: "%.2f", elapsed))초): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - 재벌 번역 (Context Translation)

    private func fireContextTranslation(text: String, entryID: UUID) {
        let context = translationContextHistory
        executeContextTranslation(text: text, entryID: entryID, context: context)
    }

    private func executeContextTranslation(text: String, entryID: UUID, context: [TranslationContext]) {
        Task { [weak self] in
            guard let self = self else { return }
            guard self.isRunning, !self.isStopping else { return }
            let startTime = CFAbsoluteTimeGetCurrent()
            do {
                let translation = try await self.contextTranslation.translate(
                    text: text,
                    context: context.isEmpty ? nil : context
                )
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                if self.isRunning, !self.isStopping,
                   let index = self.entries.firstIndex(where: { $0.id == entryID }) {
                    self.entries[index].contextTranslation = translation
                    print("[Oratio] 재벌 번역 완료 (\(String(format: "%.2f", elapsed))초): \"\(text.prefix(30))\" -> \"\(translation.prefix(30))\"")
                    self.addToContextHistory(source: text, translation: translation)
                }
            } catch {
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                print("[Oratio] 재벌 번역 에러 (\(String(format: "%.2f", elapsed))초): \(error.localizedDescription)")
                if self.isRunning, !self.isStopping,
                   let index = self.entries.firstIndex(where: { $0.id == entryID }),
                   self.entries[index].quickTranslation == nil {
                    self.entries[index].quickTranslation = "[번역 실패]"
                }
            }
        }
    }

    // MARK: - 맥락 관리

    private func addToContextHistory(source: String, translation: String) {
        let context = TranslationContext(source: source, translation: translation)
        translationContextHistory.append(context)
        if translationContextHistory.count > maxContextSize {
            translationContextHistory.removeFirst(translationContextHistory.count - maxContextSize)
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

    // MARK: - 유틸리티

    private func finalizePartialEntry(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isFinalized = true
        currentPartialEntryID = nil
    }

    private func cleanup() {
        quickTranslationTask?.cancel()
        quickTranslationTask = nil
        quickTranslationRequestTask?.cancel()
        quickTranslationRequestTask = nil
        pendingQuickTranslation = nil
        soniox = nil
        audioCaptureService.onAudioPCMBuffer = nil
        currentPartialEntryID = nil
        currentSpeaker = nil
        lastQuickTranslationStableLength = 0
    }
}
