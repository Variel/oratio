import Foundation

/// 앱 설정 모델
/// UserDefaults를 통해 저장/로드한다.
class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private enum Keys {
        static let sonioxApiKey = "sonioxApiKey"
    }

    @Published var sonioxApiKey: String {
        didSet {
            UserDefaults.standard.set(sonioxApiKey, forKey: Keys.sonioxApiKey)
        }
    }

    private init() {
        let storedSonioxKey = UserDefaults.standard.string(forKey: Keys.sonioxApiKey) ?? ""
        self.sonioxApiKey = storedSonioxKey.isEmpty
            ? (ProcessInfo.processInfo.environment["SONIOX_API_KEY"] ?? "")
            : storedSonioxKey
    }
}
