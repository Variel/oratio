import SwiftUI
import Combine
import os.log

private let logger = Logger(subsystem: "ing.unlimit.oratio", category: "App")

@main
struct OratioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Oratio", systemImage: "bubble.left.and.text.bubble.right") {
            MenuBarView()
                .environmentObject(appDelegate.appState)
        }
        .commands {
            CommandMenu("보기") {
                Button("텍스트 키우기") {
                    appDelegate.appState.increaseTextScale()
                }
                .keyboardShortcut("=", modifiers: .command)

                Button("텍스트 줄이기") {
                    appDelegate.appState.decreaseTextScale()
                }
                .keyboardShortcut("-", modifiers: .command)

                Button("텍스트 기본 크기") {
                    appDelegate.appState.resetTextScale()
                }
                .keyboardShortcut("0", modifiers: .command)
            }
        }

        Settings {
            SettingsView()
                .frame(minWidth: 560, minHeight: 480)
        }
    }
}

// MARK: - App State

@MainActor
class AppState: ObservableObject {
    /// TranslationOrchestrator - 전체 파이프라인을 소유하고 관리
    let orchestrator: TranslationOrchestrator

    /// AudioCaptureService 참조 (오디오 레벨 표시용)
    let audioCaptureService: AudioCaptureService

    @Published var isPanelVisible: Bool = false
    @Published var textScale: CGFloat {
        didSet {
            UserDefaults.standard.set(Double(textScale), forKey: "oratio.textScale")
        }
    }

    /// Combine 구독 관리 (nested ObservableObject 전파용)
    private var cancellables = Set<AnyCancellable>()

    /// orchestrator.isRunning의 편의 프록시
    var isTranslating: Bool {
        orchestrator.isRunning
    }

    /// orchestrator의 현재 상태 메시지
    var statusMessage: String {
        if let error = orchestrator.errorMessage {
            return "에러: \(error)"
        }
        return orchestrator.isRunning ? "캡처 중" : "대기 중"
    }

    init() {
        let storedScale = UserDefaults.standard.double(forKey: "oratio.textScale")
        self.textScale = storedScale > 0 ? CGFloat(storedScale) : 1.0

        let audioService = AudioCaptureService()
        self.audioCaptureService = audioService
        self.orchestrator = TranslationOrchestrator(
            audioCaptureService: audioService
        )

        // orchestrator의 변경을 AppState로 전파하여 UI 갱신
        orchestrator.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    /// 번역 시작/정지 토글
    func toggleTranslation() {
        if orchestrator.isRunning {
            orchestrator.stop()
        } else {
            Task { @MainActor in
                await orchestrator.start()
            }
        }
    }

    func increaseTextScale() {
        updateTextScale(by: 0.1)
    }

    func decreaseTextScale() {
        updateTextScale(by: -0.1)
    }

    func resetTextScale() {
        textScale = 1.0
    }

    private func updateTextScale(by delta: CGFloat) {
        let next = ((textScale + delta) * 10).rounded() / 10
        textScale = min(2.0, max(0.8, next))
    }
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let appState = AppState()
    var floatingPanel: FloatingPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupFloatingPanel()
        showPanel()
    }

    private func setupFloatingPanel() {
        let contentView = TranslationView()
            .environmentObject(appState)

        let panel = FloatingPanel(contentView: contentView)
        panel.delegate = self
        panel.collectionBehavior = [.canJoinAllSpaces, .moveToActiveSpace, .fullScreenAuxiliary]
        floatingPanel = panel
        updatePanelVisibilityState()
    }

    private func getOrCreatePanel() -> FloatingPanel? {
        if floatingPanel == nil {
            setupFloatingPanel()
        }
        return floatingPanel
    }

    private func presentPanel(_ panel: FloatingPanel) {
        if panel.isMiniaturized {
            panel.deminiaturize(nil)
        }
        ensurePanelOnActiveScreen(panel)
        activateForWindowPresentation()
        panel.alphaValue = 1.0
        panel.orderFrontRegardless()
        panel.makeKeyAndOrderFront(nil)
    }

    private func recreateAndPresentPanel() {
        floatingPanel?.orderOut(nil)
        floatingPanel = nil
        setupFloatingPanel()
        guard let panel = floatingPanel else { return }
        presentPanel(panel)
        updatePanelVisibilityState()
    }

    func activateForWindowPresentation() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func isPanelActuallyVisible() -> Bool {
        floatingPanel?.isVisible == true
    }

    func showPanel() {
        guard let panel = getOrCreatePanel() else { return }
        presentPanel(panel)

        // 메뉴바 팝오버 닫힘/포커스 전환 이후에도 표시되는지 다음 런루프에서 재검증한다.
        DispatchQueue.main.async { [weak self, weak panel] in
            guard let self else { return }
            if panel?.isVisible == true {
                self.updatePanelVisibilityState()
                return
            }

            logger.error("Panel reopen failed after menu/action cycle; recreating panel")
            self.recreateAndPresentPanel()
        }
    }

    func hidePanel() {
        floatingPanel?.orderOut(nil)
        updatePanelVisibilityState()
    }

    func forceRecreateAndShowPanel() {
        recreateAndPresentPanel()
    }

    func showSettings() {
        DispatchQueue.main.async {
            self.activateForWindowPresentation()
            let opened = NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            if !opened {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: NSApp, from: nil)
            }
        }
    }

    func windowWillClose(_ notification: Notification) {
        if let window = notification.object as? NSWindow {
            if window === floatingPanel {
                updatePanelVisibilityState()
            }
        }
    }

    /// 닫기 버튼 클릭 시 실제 close 대신 숨김 처리하여
    /// 메뉴바에서 항상 다시 열 수 있도록 보장한다.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard sender === floatingPanel else { return true }
        hidePanel()
        return false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag || !isPanelActuallyVisible() {
            showPanel()
        }
        return true
    }

    private func updatePanelVisibilityState() {
        appState.isPanelVisible = isPanelActuallyVisible()
    }

    private func ensurePanelOnActiveScreen(_ panel: NSWindow) {
        let targetScreen = NSScreen.main ?? panel.screen ?? NSScreen.screens.first
        guard let screen = targetScreen else { return }

        // 메뉴바/독 영역과 너무 붙지 않도록 여유를 둔다.
        var visibleFrame = screen.visibleFrame.insetBy(dx: 20, dy: 20)
        if visibleFrame.width < 300 || visibleFrame.height < 250 {
            visibleFrame = screen.visibleFrame
        }

        var frame = panel.frame

        if frame.width > visibleFrame.width {
            frame.size.width = visibleFrame.width
        }
        if frame.height > visibleFrame.height {
            frame.size.height = visibleFrame.height
        }

        if !visibleFrame.intersects(frame) {
            frame.origin.x = visibleFrame.midX - frame.width / 2
            frame.origin.y = visibleFrame.midY - frame.height / 2
            panel.setFrame(frame, display: false)
            return
        }

        var changed = false
        if frame.minX < visibleFrame.minX {
            frame.origin.x = visibleFrame.minX
            changed = true
        }
        if frame.maxX > visibleFrame.maxX {
            frame.origin.x = visibleFrame.maxX - frame.width
            changed = true
        }
        if frame.minY < visibleFrame.minY {
            frame.origin.y = visibleFrame.minY
            changed = true
        }
        if frame.maxY > visibleFrame.maxY {
            frame.origin.y = visibleFrame.maxY - frame.height
            changed = true
        }

        if changed {
            panel.setFrame(frame, display: false)
        }
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettingsAction
    private var panelVisible: Bool {
        (NSApp.delegate as? AppDelegate)?.isPanelActuallyVisible() ?? appState.isPanelVisible
    }

    var body: some View {
        VStack {
            Button(panelVisible ? "패널 숨기기" : "패널 표시") {
                DispatchQueue.main.async {
                    if let appDelegate = NSApp.delegate as? AppDelegate {
                        if appDelegate.isPanelActuallyVisible() {
                            appDelegate.hidePanel()
                        } else {
                            appDelegate.showPanel()
                        }
                    }
                }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

            Button("패널 강제 복구") {
                DispatchQueue.main.async {
                    if let appDelegate = NSApp.delegate as? AppDelegate {
                        appDelegate.forceRecreateAndShowPanel()
                    }
                }
            }

            Divider()

            Button(appState.orchestrator.isRunning ? "번역 정지" : "번역 시작") {
                appState.toggleTranslation()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])

            Divider()

            Text("상태: \(appState.statusMessage)")
                .font(.caption)

            Divider()

            Button("설정...") {
                DispatchQueue.main.async {
                    if let appDelegate = NSApp.delegate as? AppDelegate {
                        appDelegate.activateForWindowPresentation()
                    }
                    openSettingsAction()
                }
            }

            Divider()

            Button("텍스트 키우기") {
                appState.increaseTextScale()
            }

            Button("텍스트 줄이기") {
                appState.decreaseTextScale()
            }

            Button("텍스트 기본 크기") {
                appState.resetTextScale()
            }

            Divider()

            Button("종료") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
