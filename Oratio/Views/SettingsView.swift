import SwiftUI

/// API 키 설정 및 STT 제공자 선택 뷰
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

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
        .padding()
    }

    // MARK: - API Key Settings

    private var apiKeySettingsView: some View {
        Form {
            Section("OpenAI API") {
                SecureField("OpenAI API Key", text: $settings.openaiApiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Whisper STT 사용 시 필요")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Section("Google Cloud") {
                HStack {
                    TextField("Service Account JSON 파일 경로", text: $settings.googleCloudServiceAccountPath)
                        .textFieldStyle(.roundedBorder)
                    Button("선택") {
                        selectServiceAccountFile()
                    }
                }
                if !settings.googleCloudServiceAccountPath.isEmpty {
                    let fileName = URL(fileURLWithPath: settings.googleCloudServiceAccountPath).lastPathComponent
                    Text("선택됨: \(fileName)")
                        .font(.caption)
                        .foregroundColor(.green)
                }
                Text("Google Cloud Speech-to-Text 사용 시 필요 (Service Account JSON)")
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
                case .googleCloud:
                    providerDescription(
                        icon: "globe",
                        title: "Google Cloud Speech-to-Text",
                        description: "gRPC 스트리밍, 자동 구두점, 높은 정확도.",
                        note: "Service Account JSON 파일 필요, Speech-to-Text API 활성화 필요"
                    )
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - 파일 선택

    private func selectServiceAccountFile() {
        let panel = NSOpenPanel()
        panel.title = "Service Account JSON 파일 선택"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        if panel.runModal() == .OK, let url = panel.url {
            settings.googleCloudServiceAccountPath = url.path
        }
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
