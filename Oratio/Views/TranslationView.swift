import SwiftUI

/// 메인 번역 표시 뷰
/// 플로팅 패널 내에 표시되는 스크롤 가능한 번역 리스트
struct TranslationView: View {
    @EnvironmentObject var appState: AppState
    private var textScale: CGFloat { appState.textScale }

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
            ZStack {
                VisualEffectView(material: .underWindowBackground, blendingMode: .behindWindow)
                Color(nsColor: .windowBackgroundColor).opacity(0.55)
            }
        )
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .foregroundColor(.accentColor)
            Text("Oratio")
                .font(.system(size: 17 * textScale, weight: .semibold))
            Spacer()
            Text(appState.orchestrator.isRunning ? "캡처 중" : "대기 중")
                .font(.system(size: 12 * textScale))
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
                .font(.system(size: 40 * textScale))
                .foregroundColor(.secondary)
            Text("번역 대기 중")
                .font(.system(size: 20 * textScale, weight: .medium))
                .foregroundColor(.secondary)
            Text("번역을 시작하려면 \u{25B6} 버튼을 누르세요")
                .font(.system(size: 12 * textScale))
                .foregroundColor(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @State private var isAtBottom: Bool = true

    // MARK: - Translation List

    private var translationListView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(appState.orchestrator.entries.enumerated()), id: \.element.id) { index, entry in
                        let showSpeakerLabel = shouldShowSpeakerLabel(at: index)
                        TranslationEntryRow(
                            entry: entry,
                            textScale: textScale,
                            showSpeakerLabel: showSpeakerLabel
                        )
                        .id(entry.id)
                    }

                    // 하단 앵커 — 가시 여부로 isAtBottom 추적
                    Color.clear
                        .frame(height: 1)
                        .id("bottom_anchor")
                        .onAppear { isAtBottom = true }
                        .onDisappear { isAtBottom = false }
                }
                .padding(12)
            }
            .onChange(of: appState.orchestrator.lastAddedEntryID) { _ in
                if isAtBottom, let lastEntry = appState.orchestrator.entries.last {
                    withAnimation { proxy.scrollTo(lastEntry.id, anchor: .bottom) }
                }
            }
            .onChange(of: appState.orchestrator.entries.last?.originalText) { _ in
                if isAtBottom, let lastEntry = appState.orchestrator.entries.last {
                    withAnimation { proxy.scrollTo(lastEntry.id, anchor: .bottom) }
                }
            }
        }
    }

    /// 같은 화자의 연속 엔트리에서는 라벨 생략 (첫 등장 시만 표시)
    private func shouldShowSpeakerLabel(at index: Int) -> Bool {
        let entries = appState.orchestrator.entries
        guard let speaker = entries[index].speaker else { return false }
        if index == 0 { return true }
        return entries[index - 1].speaker != speaker
    }
}

// MARK: - Translation Entry Row

struct TranslationEntryRow: View {
    let entry: TranslationEntry
    let textScale: CGFloat
    let showSpeakerLabel: Bool

    /// 깜빡이는 애니메이션을 위한 상태
    @State private var isPulsing: Bool = false

    /// 화자별 색상
    private static let speakerColors: [Color] = [
        .blue, .purple, .orange, .teal, .pink,
        .indigo, .mint, .brown, .cyan, .red
    ]

    /// 마이크 소스 색상
    private static let micColor: Color = .cyan

    private var isMic: Bool { entry.source == .microphone }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // 소스 라벨
            if isMic {
                HStack(spacing: 4) {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 9 * textScale))
                        .foregroundColor(Self.micColor)
                    Text("나 (한→영)")
                        .font(.system(size: 10 * textScale, weight: .semibold))
                        .foregroundColor(Self.micColor)
                }
                .padding(.bottom, 2)
            } else if showSpeakerLabel, let speaker = entry.speaker {
                HStack(spacing: 4) {
                    Circle()
                        .fill(speakerColor(for: speaker))
                        .frame(width: 8, height: 8)
                    Text("Speaker \(speaker)")
                        .font(.system(size: 10 * textScale, weight: .semibold))
                        .foregroundColor(speakerColor(for: speaker))
                }
                .padding(.bottom, 2)
            }

            // 원문 - 작은 폰트
            Text(entry.originalText)
                .font(.system(size: 12 * textScale))
                .foregroundColor(isMic ? Self.micColor.opacity(0.7) : .secondary)

            // 번역 텍스트
            if let translation = entry.translatedText, !translation.isEmpty {
                Text(translation)
                    .font(.system(size: 15 * textScale, weight: .medium))
                    .foregroundColor(isMic
                        ? (entry.isFinalized ? Self.micColor : Self.micColor.opacity(0.6))
                        : (entry.isFinalized ? .primary : .secondary))
            } else if !entry.originalText.isEmpty {
                Text("번역 중...")
                    .font(.system(size: 13 * textScale))
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
        .frame(maxWidth: .infinity, alignment: isMic ? .trailing : .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isMic
                    ? Self.micColor.opacity(entry.isFinalized ? 0.10 : 0.05)
                    : (entry.isFinalized ? Color.green.opacity(0.08) : Color.secondary.opacity(0.05)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.clear)
                .overlay(alignment: isMic ? .trailing : .leading) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(leftBarColor)
                        .frame(width: 3)
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
        )
    }

    // MARK: - 색상

    private var leftBarColor: Color {
        if isMic {
            return Self.micColor
        }
        if let speaker = entry.speaker {
            return speakerColor(for: speaker)
        }
        return .green
    }

    private func speakerColor(for speaker: String) -> Color {
        let index = (Int(speaker) ?? 1) - 1
        return Self.speakerColors[index % Self.speakerColors.count]
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
