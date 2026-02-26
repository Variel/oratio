import SwiftUI
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

        Settings {
            SettingsView()
                .environmentObject(appDelegate.appState)
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
    @Published var showSettings: Bool = false

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
        let audioService = AudioCaptureService()
        self.audioCaptureService = audioService
        self.orchestrator = TranslationOrchestrator(
            audioCaptureService: audioService
        )
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
}

// MARK: - App Delegate

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    var floatingPanel: FloatingPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupFloatingPanel()
        // 앱 시작 시 자동으로 패널 표시
        showPanel()
    }

    private func setupFloatingPanel() {
        let contentView = TranslationView()
            .environmentObject(appState)

        floatingPanel = FloatingPanel(contentView: contentView)
    }

    func togglePanel() {
        guard let panel = floatingPanel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
            appState.isPanelVisible = false
        } else {
            panel.orderFront(nil)
            appState.isPanelVisible = true
        }
    }

    func showPanel() {
        floatingPanel?.orderFront(nil)
        appState.isPanelVisible = true
    }

    func hidePanel() {
        floatingPanel?.orderOut(nil)
        appState.isPanelVisible = false
    }
}

// MARK: - Menu Bar View

struct MenuBarView: View {
    @EnvironmentObject var appState: AppState

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

            Button("종료") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}
