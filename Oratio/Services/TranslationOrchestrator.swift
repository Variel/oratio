import Foundation
import Combine

/// 이중 번역 오케스트레이터
/// STT 결과를 받아 초벌/재벌 번역을 조율하고,
/// 전체 파이프라인(AudioCapture -> STT -> Translation -> UI)을 관리한다.
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

    // MARK: - STT 프로바이더

    private var sttProvider: STTProvider?

    // MARK: - 상태 관리

    /// 현재 진행 중인 부분 결과 엔트리의 ID
    private var currentPartialEntryID: UUID?

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

    /// 강제 분리하는 최대 단어 수
    private let sentenceSplitMaxWordCount = 20

    /// 부분 결과 안정화 타이머 (침묵 감지용)
    private var partialResultStabilizationTask: Task<Void, Never>?

    /// 침묵 타임아웃 (초)
    private let silenceTimeout: TimeInterval = 2.0

    /// 초벌 번역 스로틀 간격 (초)
    private let quickTranslationThrottleInterval: TimeInterval = 0.7

    /// 마지막 초벌 번역 디스패치 시각
    private var lastQuickTranslationDispatchAt: Date = .distantPast

    /// STT 누적 텍스트 중 이미 finalize된 부분의 길이
    /// Apple Speech용 — 다른 STT는 세션 누적이 아니므로 사용하지 않음
    private var processedTextLength: Int = 0

    /// 사용자가 정지를 눌러 파이프라인을 내리는 중인지 여부
    private var isStopping: Bool = false

    /// Apple Speech, Google Cloud STT는 세션 내 누적 텍스트를 보냄
    private var isCumulativeProvider: Bool {
        settings.selectedSTTProvider == .apple || settings.selectedSTTProvider == .googleCloud
    }

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
        processedTextLength = 0
        isStopping = false

        let provider = createSTTProvider()
        self.sttProvider = provider
        setupSTTCallbacks(provider: provider)
        setupAudioToSTTPipeline(provider: provider)

        do {
            try await audioCaptureService.startCapture()
        } catch {
            errorMessage = "오디오 캡처 시작 실패: \(error.localizedDescription)"
            cleanup()
            return
        }

        do {
            try await provider.startRecognition()
        } catch {
            errorMessage = "음성 인식 시작 실패: \(error.localizedDescription)"
            audioCaptureService.stopCapture()
            cleanup()
            return
        }

        isRunning = true
        print("[Oratio] ===== 파이프라인 시작 (STT: \(provider.name)) =====")
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

        // stop() 시 STT 구현체가 synthetic final을 올려도 무시되도록 먼저 콜백 해제
        sttProvider?.onPartialResult = nil
        sttProvider?.onFinalResult = nil
        sttProvider?.onError = nil
        audioCaptureService.onAudioPCMBuffer = nil

        sttProvider?.stopRecognition()
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
        processedTextLength = 0
    }

    // MARK: - STT 프로바이더 생성

    private func createSTTProvider() -> STTProvider {
        switch settings.selectedSTTProvider {
        case .apple:
            return AppleSpeechSTT()
        case .whisper:
            return WhisperSTT()
        case .googleCloud:
            return GoogleCloudSTT()
        }
    }

    // MARK: - 콜백 설정

    private func setupSTTCallbacks(provider: STTProvider) {
        provider.onPartialResult = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.handlePartialResult(text)
            }
        }

        provider.onFinalResult = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.handleFinalResult(text)
            }
        }

        provider.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleSTTError(error)
            }
        }
    }

    private func setupAudioToSTTPipeline(provider: STTProvider) {
        audioCaptureService.onAudioPCMBuffer = { [weak provider] buffer in
            provider?.feedAudioBuffer(buffer)
        }
    }

    // MARK: - 누적 텍스트 처리

    /// 누적 텍스트에서 현재 진행 중인 부분만 추출한다.
    /// Apple Speech: 세션 전체 누적 → processedTextLength로 잘라냄
    /// Google Cloud 등: 누적이 아니므로 전체 반환
    private func extractCurrentText(from fullText: String) -> String {
        guard isCumulativeProvider,
              processedTextLength > 0,
              processedTextLength <= fullText.count else {
            return fullText
        }
        return String(fullText.dropFirst(processedTextLength))
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - STT 부분 결과 처리

    func handlePartialResult(_ text: String) {
        guard isRunning, !isStopping else { return }

        let fullText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else { return }

        let currentText = extractCurrentText(from: fullText)
        guard !currentText.isEmpty else { return }

        // 현재 엔트리 업데이트
        if let existingID = currentPartialEntryID,
           let index = entries.firstIndex(where: { $0.id == existingID }) {
            entries[index].originalText = currentText
            print("[Oratio] 엔트리 업데이트 (\(currentText.count)자): \"\(currentText.prefix(60))\"")
        } else {
            let newEntry = TranslationEntry(originalText: currentText)
            entries.append(newEntry)
            currentPartialEntryID = newEntry.id
            lastAddedEntryID = newEntry.id
            print("[Oratio] 새 엔트리 생성 (\(currentText.count)자): \"\(currentText.prefix(60))\"")
        }

        let wordCount = currentText.split(separator: " ").count

        // 최대 단어 수 초과 시 강제 분리 (세션 누적 STT만 — Google Cloud 등은 자체 utterance 경계 사용)
        if isCumulativeProvider, wordCount >= sentenceSplitMaxWordCount, let entryID = currentPartialEntryID {
            forceFinalize(text: currentText, entryID: entryID, fullTextLength: fullText.count)
            return
        }

        // 번역 트리거
        if wordCount >= minimumWordCount {
            triggerQuickTranslation(text: currentText)
        }

        // 침묵 감지
        resetSilenceTimer(fullText: fullText)
    }

    /// 최대 단어 수 초과 시 엔트리를 강제 분리한다.
    private func forceFinalize(text: String, entryID: UUID, fullTextLength: Int) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[index].originalText = text
        entries[index].isFinalized = true
        currentPartialEntryID = nil
        if isCumulativeProvider {
            processedTextLength = fullTextLength
        }

        // 번역 트리거 (즉시)
        triggerQuickTranslation(text: text, entryID: entryID)
        fireContextTranslation(text: text, entryID: entryID)

        print("[Oratio] 강제 분리 (\(text.split(separator: " ").count)단어): \"\(text.prefix(50))...\"")
    }

    private func resetSilenceTimer(fullText: String) {
        partialResultStabilizationTask?.cancel()
        partialResultStabilizationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.silenceTimeout ?? 2.0) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self = self else { return }
            guard let entryID = self.currentPartialEntryID else { return }

            print("[Oratio] 침묵 감지 (\(self.silenceTimeout)초)")

            if self.isCumulativeProvider {
                // Apple Speech: 세션 전체 누적이므로 handleFinalResult로 processedTextLength 갱신
                self.handleFinalResult(fullText, isSessionEnd: false)
            } else {
                // Google Cloud 등: utterance 단위 누적이므로
                // 엔트리만 finalize하고 currentPartialEntryID는 유지한다.
                // Google이 같은 utterance에서 추가 interim을 보내면 같은 엔트리에 누적되고,
                // isFinal이 오면 onFinalResult 콜백에서 정상 finalize된다.
                let currentText = self.extractCurrentText(from: fullText)
                guard !currentText.isEmpty else { return }

                // 침묵 구간에서는 현재 문장이 안정된 것으로 보고 재벌 번역을 트리거한다.
                self.fireContextTranslation(text: currentText, entryID: entryID)

                if let index = self.entries.firstIndex(where: { $0.id == entryID }),
                   self.entries[index].quickTranslation == nil {
                    self.triggerQuickTranslation(text: currentText, entryID: entryID)
                }
            }
        }
    }

    // MARK: - STT 최종 결과 처리

    func handleFinalResult(_ text: String, isSessionEnd: Bool = false) {
        guard isRunning, !isStopping else { return }

        let fullText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !fullText.isEmpty else { return }

        let currentText = extractCurrentText(from: fullText)
        guard !currentText.isEmpty else { return }

        // 침묵 타이머 취소 (final 도착 시 더 이상 불필요)
        partialResultStabilizationTask?.cancel()
        partialResultStabilizationTask = nil

        quickTranslationTask?.cancel()
        quickTranslationTask = nil

        let entryID: UUID

        if let existingID = currentPartialEntryID,
           let index = entries.firstIndex(where: { $0.id == existingID }) {
            entries[index].originalText = currentText
            entries[index].isFinalized = true
            entryID = existingID
        } else {
            let newEntry = TranslationEntry(originalText: currentText, isFinalized: true)
            entries.append(newEntry)
            entryID = newEntry.id
            lastAddedEntryID = newEntry.id
        }

        currentPartialEntryID = nil
        if isCumulativeProvider {
            processedTextLength = isSessionEnd ? 0 : fullText.count
        }

        // finalized → 즉시 재벌 번역
        fireContextTranslation(text: currentText, entryID: entryID)
        triggerQuickTranslation(text: currentText, entryID: entryID)
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
                // 최신 텍스트가 더 길어졌다면(prefix) 이전 결과도 우선 표시해 체감 지연을 줄인다.
                guard latestText == requestText || latestText.hasPrefix(requestText) else { return }
                if let prevSource = self.entries[index].quickTranslationSourceText,
                   prevSource.count > requestText.count {
                    return // 더 최신 source 기준 번역이 이미 있으면 역행 업데이트 방지
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

    /// finalized 엔트리용: 즉시 실행, 취소 불가
    private func fireContextTranslation(text: String, entryID: UUID) {
        let context = translationContextHistory
        executeContextTranslation(text: text, entryID: entryID, context: context)
    }

    /// 재벌 번역 API 호출 (별도 Task)
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

        print("[Oratio] STT 에러: \(error.localizedDescription)")
        if let sttError = error as? STTError {
            switch sttError {
            case .apiKeyMissing:
                errorMessage = "API 키가 설정되지 않았습니다."
                stop()
            case .permissionDenied:
                errorMessage = "음성 인식 권한이 거부되었습니다."
                stop()
            case .recognitionNotAvailable:
                errorMessage = "음성 인식을 사용할 수 없습니다."
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
        partialResultStabilizationTask?.cancel()
        partialResultStabilizationTask = nil
        sttProvider?.onPartialResult = nil
        sttProvider?.onFinalResult = nil
        sttProvider?.onError = nil
        sttProvider = nil
        audioCaptureService.onAudioPCMBuffer = nil
        currentPartialEntryID = nil
        processedTextLength = 0
    }
}
