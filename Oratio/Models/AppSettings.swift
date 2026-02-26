import Foundation

/// STT 제공자 선택
enum STTProviderType: String, CaseIterable, Identifiable {
    case apple = "Apple Speech"
    case whisper = "OpenAI Whisper"
    case googleCloud = "Google Cloud Speech"

    var id: String { rawValue }
}

/// 앱 설정 모델
/// UserDefaults를 통해 저장/로드한다.
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let geminiApiKey = "geminiApiKey"
        static let openaiApiKey = "openaiApiKey"
        static let googleCloudServiceAccountPath = "googleCloudServiceAccountPath"
        static let selectedSTTProvider = "selectedSTTProvider"
    }

    @Published var geminiApiKey: String {
        didSet {
            UserDefaults.standard.set(geminiApiKey, forKey: Keys.geminiApiKey)
        }
    }

    @Published var openaiApiKey: String {
        didSet {
            UserDefaults.standard.set(openaiApiKey, forKey: Keys.openaiApiKey)
        }
    }

    /// Google Cloud Service Account JSON 파일 경로
    @Published var googleCloudServiceAccountPath: String {
        didSet {
            UserDefaults.standard.set(googleCloudServiceAccountPath, forKey: Keys.googleCloudServiceAccountPath)
        }
    }

    @Published var selectedSTTProvider: STTProviderType {
        didSet {
            UserDefaults.standard.set(selectedSTTProvider.rawValue, forKey: Keys.selectedSTTProvider)
        }
    }

    private init() {
        let storedGeminiKey = UserDefaults.standard.string(forKey: Keys.geminiApiKey) ?? ""
        self.geminiApiKey = storedGeminiKey.isEmpty
            ? (ProcessInfo.processInfo.environment["GOOGLE_GENERATIVE_AI_API_KEY"] ?? "")
            : storedGeminiKey

        let storedOpenAIKey = UserDefaults.standard.string(forKey: Keys.openaiApiKey) ?? ""
        self.openaiApiKey = storedOpenAIKey.isEmpty
            ? (ProcessInfo.processInfo.environment["OPENAI_API_KEY"] ?? "")
            : storedOpenAIKey

        self.googleCloudServiceAccountPath = UserDefaults.standard.string(forKey: Keys.googleCloudServiceAccountPath) ?? ""

        let providerRaw = UserDefaults.standard.string(forKey: Keys.selectedSTTProvider) ?? STTProviderType.apple.rawValue
        self.selectedSTTProvider = STTProviderType(rawValue: providerRaw) ?? .apple
    }
}
