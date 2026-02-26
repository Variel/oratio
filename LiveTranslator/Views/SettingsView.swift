import SwiftUI

/// API 키 설정 및 STT 제공자 선택 뷰
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            apiKeySettingsView
                .tabItem {
                    Label("API 키", systemImage: "key")
                }

            sttSettingsView
                .tabItem {
                    Label("음성인식", systemImage: "waveform")
                }
        }
        .frame(width: 450, height: 300)
        .padding()
    }

    // MARK: - API Key Settings

    private var apiKeySettingsView: some View {
        Form {
            Section("Gemini API") {
                SecureField("Gemini API Key", text: $settings.geminiApiKey)
                    .textFieldStyle(.roundedBorder)
                Text("gemini-2.5-flash-lite (초벌) 및 gemini-3-pro-preview (재벌) 번역에 사용")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("OpenAI API") {
                SecureField("OpenAI API Key", text: $settings.openaiApiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Whisper STT 사용 시 필요")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - STT Settings

    private var sttSettingsView: some View {
        Form {
            Section("음성인식(STT) 제공자") {
                Picker("STT 제공자", selection: $settings.selectedSTTProvider) {
                    ForEach(STTProviderType.allCases) { provider in
                        Text(provider.rawValue).tag(provider)
                    }
                }
                .pickerStyle(.radioGroup)

                // 제공자별 안내
                switch settings.selectedSTTProvider {
                case .apple:
                    providerDescription(
                        icon: "apple.logo",
                        title: "Apple Speech Framework",
                        description: "무료, 실시간 스트리밍 부분 결과 지원. macOS 내장.",
                        note: "인터넷 연결 필요 (온디바이스 모델 없는 경우)"
                    )
                case .whisper:
                    providerDescription(
                        icon: "cloud",
                        title: "OpenAI Whisper API",
                        description: "최고 정확도, 청크 기반 처리.",
                        note: "OpenAI API 키 필요, 사용량에 따라 과금"
                    )
                case .geminiLive:
                    providerDescription(
                        icon: "bolt",
                        title: "Gemini Live API",
                        description: "스트리밍 지원, 빠른 응답.",
                        note: "Gemini API 키 필요"
                    )
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    private func providerDescription(icon: String, title: String, description: String, note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: icon)
                Text(title).font(.subheadline.weight(.medium))
            }
            Text(description)
                .font(.caption)
                .foregroundColor(.secondary)
            Text(note)
                .font(.caption2)
                .foregroundColor(.orange)
        }
        .padding(.top, 4)
    }
}
