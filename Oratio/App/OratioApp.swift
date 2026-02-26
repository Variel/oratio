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
        floatingPanel = panel
    }

    func activateForWindowPresentation() {
        NSApp.activate(ignoringOtherApps: true)
    }

    func togglePanel() {
        guard let panel = floatingPanel else { return }
        if panel.isVisible {
            hidePanel()
        } else {
            showPanel()
        }
    }

    func showPanel() {
        guard let panel = floatingPanel else { return }
        if panel.isMiniaturized {
            panel.deminiaturize(nil)
        }
        activateForWindowPresentation()
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        appState.isPanelVisible = true
    }

    func hidePanel() {
        floatingPanel?.orderOut(nil)
        appState.isPanelVisible = false
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
                appState.isPanelVisible = false
            }
        }
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettingsAction

    var body: some View {
        VStack {
            Button(appState.isPanelVisible ? "패널 숨기기" : "패널 표시") {
                if let appDelegate = NSApp.delegate as? AppDelegate {
                    appDelegate.togglePanel()
                }
            }
            .keyboardShortcut("t", modifiers: [.command, .shift])

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
