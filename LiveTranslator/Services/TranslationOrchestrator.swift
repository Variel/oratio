import Foundation
import Combine

/// 이중 번역 오케스트레이터
/// STT 결과를 받아 초벌/재벌 번역을 조율하고,
/// 전체 파이프라인(AudioCapture -> STT -> Translation -> UI)을 관리한다.
@MainActor
class TranslationOrchestrator: ObservableObject {

    // MARK: - Published 프로퍼티 (UI 관찰용)

    /// 번역 항목 리스트 (UI에서 관찰)
    @Published var entries: [TranslationEntry] = []

    /// 현재 진행 중인지 여부
    @Published var isRunning: Bool = false

    /// 에러 메시지 (UI에서 표시)
    @Published var errorMessage: String?

    /// 새 엔트리 추가 신호 (자동 스크롤용)
    @Published var lastAddedEntryID: UUID?

    // MARK: - 서비스 의존성

    private let audioCaptureService: AudioCaptureService
    private let quickTranslation: QuickTranslationService
    private let contextTranslation: ContextTranslationService
    private let settings: AppSettings

    // MARK: - STT 프로바이더

    /// 현재 사용 중인 STT 프로바이더
    private var sttProvider: STTProvider?

    // MARK: - 디바운싱 및 상태 관리

    /// 현재 진행 중인 부분 결과 엔트리의 ID
    private var currentPartialEntryID: UUID?

    /// 진행 중인 초벌 번역 태스크 (디바운싱을 위한 취소용)
    private var quickTranslationTask: Task<Void, Never>?

    /// 진행 중인 재벌 번역 태스크 (stop 시 취소용)
    private var contextTranslationTask: Task<Void, Never>?

    /// 맥락 유지: 최근 완성된 번역 쌍 (TranslationContext 배열)
    private var translationContextHistory: [TranslationContext] = []

    /// 맥락에 유지할 최대 문장 수
    private let maxContextSize = 10

    /// 초벌 번역 트리거를 위한 최소 단어 수
    private let minimumWordCount = 3

    /// 부분 결과 안정화 타이머 (침묵 감지용)
    /// N초간 새로운 부분 결과가 없으면 현재 텍스트를 최종 결과로 처리
    private var partialResultStabilizationTask: Task<Void, Never>?

    /// 부분 결과를 최종 결과로 전환하는 침묵 타임아웃 (초)
    private let silenceTimeout: TimeInterval = 2.0

    /// Combine 구독 관리
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

    // MARK: - 전체 파이프라인 제어

    /// 전체 파이프라인을 시작한다.
    /// AudioCapture -> STT -> Translation 콜백 연결
    func start() async {
        guard !isRunning else { return }

        // 에러 초기화
        errorMessage = nil

        // 1. STT 프로바이더 생성 (설정에 따라)
        let provider = createSTTProvider()
        self.sttProvider = provider

        // 2. STT 콜백 연결
        setupSTTCallbacks(provider: provider)

        // 3. 오디오 캡처 → STT 연결
        setupAudioToSTTPipeline(provider: provider)

        // 4. 오디오 캡처 시작
        do {
            try await audioCaptureService.startCapture()
        } catch {
            errorMessage = "오디오 캡처 시작 실패: \(error.localizedDescription)"
            e2eLog("[E2E-TEST] 오디오 캡처 에러: \(error)")
            cleanup()
            return
        }

        // 5. STT 인식 시작
        do {
            try await provider.startRecognition()
        } catch {
            errorMessage = "음성 인식 시작 실패: \(error.localizedDescription)"
            e2eLog("[E2E-TEST] STT 시작 에러: \(error)")
            audioCaptureService.stopCapture()
            cleanup()
            return
        }

        isRunning = true
        e2eLog("[E2E-TEST] ===== 파이프라인 시작 완료 (STT: \(provider.name)) =====")
        e2eLog("[E2E-TEST] 오디오 캡처 시작됨, STT 인식 시작됨, 번역 대기 중...")
    }

    /// 전체 파이프라인을 정지한다.
    func stop() {
        guard isRunning else { return }

        // 1. 진행 중인 번역 태스크 취소
        quickTranslationTask?.cancel()
        quickTranslationTask = nil
        contextTranslationTask?.cancel()
        contextTranslationTask = nil

        // 2. STT 정지
        sttProvider?.stopRecognition()

        // 3. 오디오 캡처 정지
        audioCaptureService.stopCapture()

        // 4. 현재 부분 결과 엔트리 finalize
        if let partialID = currentPartialEntryID {
            finalizePartialEntry(id: partialID)
        }

        // 정리
        cleanup()
        isRunning = false

        print("[TranslationOrchestrator] 파이프라인 정지 완료")
    }

    /// 모든 엔트리를 초기화한다.
    func clearEntries() {
        entries.removeAll()
        translationContextHistory.removeAll()
        currentPartialEntryID = nil
    }

    // MARK: - STT 프로바이더 생성

    /// AppSettings에 따라 적절한 STT 프로바이더를 생성한다.
    /// - Returns: 생성된 STTProvider 인스턴스
    private func createSTTProvider() -> STTProvider {
        switch settings.selectedSTTProvider {
        case .apple:
            return AppleSpeechSTT()
        case .whisper:
            return WhisperSTT()
        case .geminiLive:
            return GeminiLiveSTT()
        }
    }

    // MARK: - 콜백 설정

    /// STT 프로바이더의 콜백을 설정한다.
    private func setupSTTCallbacks(provider: STTProvider) {
        // 부분 결과 콜백
        provider.onPartialResult = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.handlePartialResult(text)
            }
        }

        // 최종 결과 콜백
        provider.onFinalResult = { [weak self] text in
            Task { @MainActor [weak self] in
                self?.handleFinalResult(text)
            }
        }

        // 에러 콜백
        provider.onError = { [weak self] error in
            Task { @MainActor [weak self] in
                self?.handleSTTError(error)
            }
        }
    }

    /// 오디오 캡처 서비스의 PCM 버퍼를 STT 프로바이더에 연결한다.
    private func setupAudioToSTTPipeline(provider: STTProvider) {
        audioCaptureService.onAudioPCMBuffer = { [weak provider] buffer in
            provider?.feedAudioBuffer(buffer)
        }
    }

    // MARK: - STT 부분 결과 처리

    /// STT 부분 결과를 처리한다.
    /// - 새 TranslationEntry를 만들거나 기존 것을 업데이트
    /// - 디바운싱: 3단어 미만이면 초벌 번역 스킵
    /// - 충분한 텍스트가 모이면 초벌 번역 트리거
    /// - Parameter text: 부분 인식 텍스트
    func handlePartialResult(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        e2eLog("[E2E-TEST] STT 부분 결과: \"\(trimmedText)\"")

        if let existingID = currentPartialEntryID,
           let index = entries.firstIndex(where: { $0.id == existingID }) {
            // 기존 부분 결과 엔트리 업데이트
            entries[index].originalText = trimmedText
        } else {
            // 새 부분 결과 엔트리 생성
            let newEntry = TranslationEntry(originalText: trimmedText)
            entries.append(newEntry)
            currentPartialEntryID = newEntry.id
            lastAddedEntryID = newEntry.id
        }

        // 디바운싱: 단어 수가 최소 기준 이상이면 초벌 번역 트리거
        let wordCount = trimmedText.split(separator: " ").count
        if wordCount >= minimumWordCount {
            triggerQuickTranslation(text: trimmedText)
        }

        // 침묵 감지: N초간 새 부분 결과가 없으면 최종 결과로 처리
        resetSilenceTimer(lastText: trimmedText)
    }

    /// 침묵 타이머를 리셋한다.
    /// 새 부분 결과가 올 때마다 호출되어, 마지막 부분 결과 이후 N초 침묵 시 최종 결과로 전환
    private func resetSilenceTimer(lastText: String) {
        partialResultStabilizationTask?.cancel()
        partialResultStabilizationTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(self?.silenceTimeout ?? 2.0) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            guard let self = self else { return }
            // 아직 부분 결과 상태라면 최종 결과로 승격
            if self.currentPartialEntryID != nil {
                e2eLog("[E2E-TEST] 침묵 감지 (\(self.silenceTimeout)초) - 부분 결과를 최종 결과로 전환")
                self.handleFinalResult(lastText)
            }
        }
    }

    // MARK: - STT 최종 결과 처리

    /// STT 최종 결과를 처리한다.
    /// - 해당 TranslationEntry를 finalize
    /// - 재벌 번역 트리거 (맥락 포함)
    /// - Parameter text: 최종 인식 텍스트
    func handleFinalResult(_ text: String) {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }
        e2eLog("[E2E-TEST] STT 최종 결과: \"\(trimmedText)\"")

        // 진행 중인 초벌 번역 취소
        quickTranslationTask?.cancel()
        quickTranslationTask = nil

        let entryID: UUID

        if let existingID = currentPartialEntryID,
           let index = entries.firstIndex(where: { $0.id == existingID }) {
            // 기존 부분 결과 엔트리를 최종 결과로 업데이트
            entries[index].originalText = trimmedText
            entries[index].isFinalized = true
            entryID = existingID
        } else {
            // 부분 결과 없이 바로 최종 결과가 온 경우 (Whisper 등)
            let newEntry = TranslationEntry(
                originalText: trimmedText,
                isFinalized: true
            )
            entries.append(newEntry)
            entryID = newEntry.id
            lastAddedEntryID = newEntry.id
        }

        // 부분 결과 추적 초기화 (다음 문장을 위해)
        currentPartialEntryID = nil

        // 재벌 번역 트리거
        triggerContextTranslation(text: trimmedText, entryID: entryID)

        // 초벌 번역도 아직 없으면 트리거 (Whisper처럼 부분 결과 없이 바로 오는 경우)
        if let index = entries.firstIndex(where: { $0.id == entryID }),
           entries[index].quickTranslation == nil {
            triggerQuickTranslation(text: trimmedText, entryID: entryID)
        }
    }

    // MARK: - 초벌 번역 (Quick Translation)

    /// 초벌 번역을 트리거한다.
    /// 이전 요청이 진행 중이면 취소하고 새 요청을 시작한다 (디바운싱).
    /// - Parameters:
    ///   - text: 번역할 텍스트
    ///   - entryID: 특정 엔트리 ID (nil이면 현재 부분 결과 엔트리에 반영)
    private func triggerQuickTranslation(text: String, entryID: UUID? = nil) {
        // 이전 초벌 번역 취소 (디바운싱)
        quickTranslationTask?.cancel()

        let targetID = entryID ?? currentPartialEntryID
        guard let targetID = targetID else { return }

        quickTranslationTask = Task { [weak self] in
            guard let self = self else { return }

            let startTime = CFAbsoluteTimeGetCurrent()
            do {
                let translation = try await self.quickTranslation.translate(
                    text: text,
                    context: nil
                )

                // 취소 확인
                guard !Task.isCancelled else { return }

                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                // 결과 반영
                if let index = self.entries.firstIndex(where: { $0.id == targetID }) {
                    self.entries[index].quickTranslation = translation
                    e2eLog("[E2E-TEST] 초벌 번역 완료 (소요: \(String(format: "%.2f", elapsed))초): \"\(text)\" -> \"\(translation)\"")
                }
            } catch {
                guard !Task.isCancelled else { return }
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                e2eLog("[E2E-TEST] 초벌 번역 에러 (소요: \(String(format: "%.2f", elapsed))초): \(error.localizedDescription)")
                // 초벌 번역 에러는 개별 엔트리에만 영향, 전체 파이프라인은 유지
            }
        }
    }

    // MARK: - 재벌 번역 (Context Translation)

    /// 재벌 번역을 트리거한다.
    /// 최근 완성된 번역 쌍을 맥락으로 전달한다.
    /// - Parameters:
    ///   - text: 번역할 텍스트
    ///   - entryID: 결과를 반영할 엔트리 ID
    private func triggerContextTranslation(text: String, entryID: UUID) {
        let context = translationContextHistory

        // 이전 재벌 번역 취소
        contextTranslationTask?.cancel()

        contextTranslationTask = Task { [weak self] in
            guard let self = self else { return }

            let startTime = CFAbsoluteTimeGetCurrent()
            do {
                let translation = try await self.contextTranslation.translate(
                    text: text,
                    context: context.isEmpty ? nil : context
                )

                // 취소 확인
                guard !Task.isCancelled else { return }

                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                // 결과 반영
                if let index = self.entries.firstIndex(where: { $0.id == entryID }) {
                    self.entries[index].contextTranslation = translation
                    e2eLog("[E2E-TEST] 재벌 번역 완료 (소요: \(String(format: "%.2f", elapsed))초): \"\(text)\" -> \"\(translation)\"")

                    // 맥락 히스토리에 추가
                    self.addToContextHistory(source: text, translation: translation)
                }
            } catch {
                guard !Task.isCancelled else { return }
                let elapsed = CFAbsoluteTimeGetCurrent() - startTime
                e2eLog("[E2E-TEST] 재벌 번역 에러 (소요: \(String(format: "%.2f", elapsed))초): \(error.localizedDescription)")
                // 재벌 번역 에러 시, 초벌 번역이 있으면 그대로 유지
                // 초벌 번역도 없으면 에러 표시
                if let index = self.entries.firstIndex(where: { $0.id == entryID }),
                   self.entries[index].quickTranslation == nil {
                    self.entries[index].quickTranslation = "[번역 실패]"
                }
            }
        }
    }

    // MARK: - 맥락 관리

    /// 완성된 번역 쌍을 맥락 히스토리에 추가한다.
    /// 최대 크기를 초과하면 오래된 것부터 제거한다.
    /// - Parameters:
    ///   - source: 영어 원문
    ///   - translation: 한국어 번역
    private func addToContextHistory(source: String, translation: String) {
        let context = TranslationContext(source: source, translation: translation)
        translationContextHistory.append(context)

        // 최대 크기 제한
        if translationContextHistory.count > maxContextSize {
            translationContextHistory.removeFirst(translationContextHistory.count - maxContextSize)
        }
    }

    // MARK: - 에러 처리

    /// STT 에러를 처리한다.
    /// - Parameter error: 발생한 에러
    private func handleSTTError(_ error: Error) {
        print("[TranslationOrchestrator] STT 에러: \(error.localizedDescription)")

        if let sttError = error as? STTError {
            switch sttError {
            case .apiKeyMissing:
                errorMessage = "API 키가 설정되지 않았습니다. 설정에서 API 키를 입력해주세요."
                stop()
            case .permissionDenied:
                errorMessage = "음성 인식 권한이 거부되었습니다."
                stop()
            case .recognitionNotAvailable:
                errorMessage = "음성 인식을 사용할 수 없습니다."
                stop()
            default:
                // 일시적인 에러는 표시만 하고 계속 진행
                errorMessage = error.localizedDescription
            }
        } else {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - 유틸리티

    /// 부분 결과 엔트리를 강제로 finalize한다.
    /// stop() 시 호출되어 현재 진행 중인 부분 결과를 마무리한다.
    /// - Parameter id: finalize할 엔트리 ID
    private func finalizePartialEntry(id: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else { return }
        entries[index].isFinalized = true
        currentPartialEntryID = nil
    }

    /// 내부 상태를 정리한다.
    private func cleanup() {
        quickTranslationTask?.cancel()
        quickTranslationTask = nil
        contextTranslationTask?.cancel()
        contextTranslationTask = nil
        partialResultStabilizationTask?.cancel()
        partialResultStabilizationTask = nil
        sttProvider?.onPartialResult = nil
        sttProvider?.onFinalResult = nil
        sttProvider?.onError = nil
        sttProvider = nil
        audioCaptureService.onAudioPCMBuffer = nil
        currentPartialEntryID = nil
    }
}
