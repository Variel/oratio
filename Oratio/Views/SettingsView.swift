import SwiftUI

/// API 키 설정 뷰
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Soniox (음성인식)") {
                SecureField("Soniox API Key", text: $settings.sonioxApiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Soniox 실시간 음성 인식에 필요 (soniox.com에서 발급)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    Image(systemName: "person.2.wave.2")
                        .foregroundColor(.blue)
                    Text("화자 분리 및 endpoint detection 자동 활성화")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("Gemini (번역)") {
                SecureField("Gemini API Key", text: $settings.geminiApiKey)
                    .textFieldStyle(.roundedBorder)
                Text("초벌/재벌 번역에 필요 (Google AI Studio에서 발급)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
