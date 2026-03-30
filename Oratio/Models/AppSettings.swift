import Foundation

/// 앱 설정 모델
/// UserDefaults를 통해 저장/로드한다.
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let sonioxApiKey = "sonioxApiKey"
        static let isMicrophoneMixExperimentEnabled = "isMicrophoneMixExperimentEnabled"
        static let mixMicrophoneGainDb = "mixMicrophoneGainDb"
        static let mixMicrophoneDelayMs = "mixMicrophoneDelayMs"
    }

    @Published var sonioxApiKey: String {
        didSet {
            UserDefaults.standard.set(sonioxApiKey, forKey: Keys.sonioxApiKey)
        }
    }

    /// 시스템 오디오 + 마이크를 suppression 없이 합쳐 Soniox에 보내는 실험 모드
    @Published var isMicrophoneMixExperimentEnabled: Bool {
        didSet {
            UserDefaults.standard.set(isMicrophoneMixExperimentEnabled, forKey: Keys.isMicrophoneMixExperimentEnabled)
        }
    }

    /// 마이크 입력 게인 (dB)
    @Published var mixMicrophoneGainDb: Double {
        didSet {
            UserDefaults.standard.set(mixMicrophoneGainDb, forKey: Keys.mixMicrophoneGainDb)
        }
    }

    /// 마이크 입력 지연 (ms)
    @Published var mixMicrophoneDelayMs: Double {
        didSet {
            UserDefaults.standard.set(mixMicrophoneDelayMs, forKey: Keys.mixMicrophoneDelayMs)
        }
    }

    private init() {
        let storedSonioxKey = UserDefaults.standard.string(forKey: Keys.sonioxApiKey) ?? ""
        self.sonioxApiKey = storedSonioxKey.isEmpty
            ? (ProcessInfo.processInfo.environment["SONIOX_API_KEY"] ?? "")
            : storedSonioxKey

        self.isMicrophoneMixExperimentEnabled = UserDefaults.standard.object(forKey: Keys.isMicrophoneMixExperimentEnabled) as? Bool ?? false

        let storedGain = UserDefaults.standard.object(forKey: Keys.mixMicrophoneGainDb) as? Double
        self.mixMicrophoneGainDb = storedGain ?? -6.0

        let storedDelay = UserDefaults.standard.object(forKey: Keys.mixMicrophoneDelayMs) as? Double
        self.mixMicrophoneDelayMs = storedDelay ?? 10.0
    }
}
