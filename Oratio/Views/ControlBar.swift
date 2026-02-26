import SwiftUI

/// 시작/정지 컨트롤바
/// 번역 시작/정지 버튼, 오디오 레벨 미터, 상태 표시, 설정 버튼
struct ControlBar: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.openSettings) private var openSettingsAction
    private var textScale: CGFloat { appState.textScale }

    var body: some View {
        VStack(spacing: 6) {
            // 에러 메시지 표시
            if let errorMessage = appState.orchestrator.errorMessage {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.system(size: 11 * textScale))
                    Text(errorMessage)
                        .font(.system(size: 11 * textScale))
                        .foregroundColor(.red)
                        .lineLimit(2)
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)
            }

            HStack(spacing: 12) {
                // 시작/정지 버튼
                Button(action: toggleTranslation) {
                    HStack(spacing: 6) {
                        Image(systemName: appState.orchestrator.isRunning ? "stop.fill" : "play.fill")
                            .foregroundColor(appState.orchestrator.isRunning ? .red : .green)
                        Text(appState.orchestrator.isRunning ? "정지" : "시작")
                            .font(.system(size: 13 * textScale, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)

                // 상태 인디케이터 + 오디오 레벨 미터
                if appState.orchestrator.isRunning {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                        Text("캡처 중")
                            .font(.system(size: 10 * textScale))
                            .foregroundColor(.secondary)

                        // 오디오 레벨 미터
                        AudioLevelMeter(level: appState.audioCaptureService.audioLevel)
                            .frame(width: 40, height: 10)
                    }
                }

                Spacer()

                // 설정 버튼
                Button(action: openSettingsWindow) {
                    Image(systemName: "gear")
                }
                .buttonStyle(.borderless)
                .help("설정")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
    }

    private func toggleTranslation() {
        appState.toggleTranslation()
    }

    private func openSettingsWindow() {
        DispatchQueue.main.async {
            if let appDelegate = NSApp.delegate as? AppDelegate {
                appDelegate.activateForWindowPresentation()
            }
            openSettingsAction()
        }
    }
}

// MARK: - Audio Level Meter

/// 오디오 레벨을 시각적으로 표시하는 미터
struct AudioLevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // 배경
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.secondary.opacity(0.2))

                // 레벨 바
                RoundedRectangle(cornerRadius: 2)
                    .fill(levelColor)
                    .frame(width: max(0, geometry.size.width * CGFloat(level)))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
    }

    private var levelColor: Color {
        if level > 0.8 {
            return .red
        } else if level > 0.5 {
            return .yellow
        } else {
            return .green
        }
    }
}
