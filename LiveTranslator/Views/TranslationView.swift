import SwiftUI

/// 메인 번역 표시 뷰
/// 플로팅 패널 내에 표시되는 스크롤 가능한 번역 리스트
struct TranslationView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            // 헤더
            headerView

            Divider()

            // 번역 리스트
            if appState.orchestrator.entries.isEmpty {
                emptyStateView
            } else {
                translationListView
            }

            Divider()

            // 컨트롤바
            ControlBar()
                .environmentObject(appState)
        }
        .frame(minWidth: 350, minHeight: 250)
        .background(
            VisualEffectView(material: .hudWindow, blendingMode: .behindWindow)
        )
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundColor(.accentColor)
            Text("LiveTranslator")
                .font(.headline)
            Spacer()
            Text(appState.statusMessage)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Empty State

    private var emptyStateView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("번역 대기 중")
                .font(.title3)
                .foregroundColor(.secondary)
            Text("번역을 시작하려면 \u{25B6} 버튼을 누르세요")
                .font(.caption)
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Translation List

    private var translationListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(appState.orchestrator.entries) { entry in
                        TranslationEntryRow(entry: entry)
                            .id(entry.id)
                    }
                }
                .padding(12)
            }
            .onChange(of: appState.orchestrator.entries.count) { _ in
                // 자동 스크롤
                if let lastEntry = appState.orchestrator.entries.last {
                    withAnimation {
                        proxy.scrollTo(lastEntry.id, anchor: .bottom)
                    }
                }
            }
        }
    }
}

// MARK: - Translation Entry Row

struct TranslationEntryRow: View {
    let entry: TranslationEntry

    /// 깜빡이는 애니메이션을 위한 상태
    @State private var isPulsing: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 원문 (영어) - 작은 폰트, 회색
            Text(entry.originalText)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .lineLimit(2)

            // 번역 텍스트
            if let translation = entry.displayTranslation {
                Text(translation)
                    .font(.system(size: 15, weight: translationFontWeight))
                    .foregroundColor(translationColor)
                    .opacity(translationOpacity)
            } else if !entry.originalText.isEmpty {
                // 번역 대기 중 - 깜빡이는 상태
                Text("번역 중...")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .opacity(isPulsing ? 0.3 : 0.8)
                    .animation(
                        Animation.easeInOut(duration: 0.8).repeatForever(autoreverses: true),
                        value: isPulsing
                    )
                    .onAppear { isPulsing = true }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(backgroundColor)
        )
    }

    // MARK: - 번역 상태별 스타일

    private var translationColor: Color {
        switch entry.translationState {
        case .pending:
            return .secondary
        case .quickCompleted:
            return .orange
        case .contextCompleted:
            return .primary
        }
    }

    private var translationFontWeight: Font.Weight {
        switch entry.translationState {
        case .pending:
            return .regular
        case .quickCompleted:
            return .medium
        case .contextCompleted:
            return .medium
        }
    }

    private var translationOpacity: Double {
        switch entry.translationState {
        case .pending:
            return 0.6
        case .quickCompleted:
            return 1.0
        case .contextCompleted:
            return 1.0
        }
    }

    private var backgroundColor: Color {
        switch entry.translationState {
        case .pending:
            return Color.secondary.opacity(0.05)
        case .quickCompleted:
            return Color.orange.opacity(0.08)
        case .contextCompleted:
            return Color.green.opacity(0.08)
        }
    }
}

// MARK: - Visual Effect View (NSVisualEffectView wrapper)

struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    let blendingMode: NSVisualEffectView.BlendingMode

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
