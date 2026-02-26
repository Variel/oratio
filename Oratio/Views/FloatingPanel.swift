import SwiftUI
import AppKit

/// NSPanel 기반 플로팅 패널
/// 항상 위에 표시되며, 드래그 가능하고, 반투명 배경을 가진다.
class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    init<Content: View>(contentView: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )

        // 패널 설정
        self.level = .floating
        self.isMovableByWindowBackground = true
        self.titlebarAppearsTransparent = true
        self.titleVisibility = .hidden
        self.isOpaque = false
        self.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92)
        self.isFloatingPanel = true

        // 패널이 키 윈도우가 되더라도 앱이 활성화되지 않도록
        self.hidesOnDeactivate = false
        self.isReleasedWhenClosed = false

        // 최소 크기 제한
        self.minSize = NSSize(width: 300, height: 250)

        // 닫기 버튼만 표시
        self.standardWindowButton(.miniaturizeButton)?.isHidden = true
        self.standardWindowButton(.zoomButton)?.isHidden = true

        // 모서리 둥글게
        self.isMovable = true

        // SwiftUI 콘텐츠 호스팅
        let hostingView = NSHostingView(rootView: contentView)
        self.contentView = hostingView

        // 화면 중앙에 배치
        self.center()
    }
}
