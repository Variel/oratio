import SwiftUI

/// API 키 설정 뷰
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section("Soniox (음성인식 + 번역)") {
                SecureField("Soniox API Key", text: $settings.sonioxApiKey)
                    .textFieldStyle(.roundedBorder)
                Text("Soniox 실시간 음성 인식 및 번역에 필요 (soniox.com에서 발급)")
                    .font(.caption)
                    .foregroundColor(.secondary)

                HStack(spacing: 6) {
                    Image(systemName: "person.2.wave.2")
                        .foregroundColor(.blue)
                    Text("화자 분리, endpoint detection, 실시간 번역 자동 활성화")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Section("입력 실험") {
                Toggle("시스템 오디오 + 마이크 합성 실험", isOn: $settings.isMicrophoneMixExperimentEnabled)

                Text("실험 모드에서는 시스템 오디오와 마이크를 echo suppression 없이 합쳐서 Soniox에 보냅니다. 설정 변경은 다음 시작부터 적용돼요.")
                    .font(.caption)
                    .foregroundColor(.secondary)

                if settings.isMicrophoneMixExperimentEnabled {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("마이크 게인")
                            Spacer()
                            Text(String(format: "%.0f dB", settings.mixMicrophoneGainDb))
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.mixMicrophoneGainDb, in: -24...0, step: 1)
                        Text("시스템 오디오 대비 마이크 레벨을 낮춰서 raw mix 반응을 보기 위한 값이에요.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("마이크 딜레이")
                            Spacer()
                            Text("\(Int(settings.mixMicrophoneDelayMs.rounded())) ms")
                                .foregroundColor(.secondary)
                        }
                        Slider(value: $settings.mixMicrophoneDelayMs, in: 0...120, step: 5)
                        Text("마이크 입력을 시스템 오디오보다 늦게 합성합니다.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
