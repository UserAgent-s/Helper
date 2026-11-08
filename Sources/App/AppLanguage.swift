import Foundation
import Observation

enum AppLanguage: String, CaseIterable, Sendable {
    case ru
    case en
    case uk

    var displayName: String {
        switch self {
        case .ru: "Русский"
        case .en: "English"
        case .uk: "Українська"
        }
    }
}

@MainActor
@Observable
final class LocalizationCenter {
    static let shared = LocalizationCenter()

    private(set) var language: AppLanguage = .ru
    private var settingsStore: AppSettingsStore?

    private init() {}

    func configure(with settingsStore: AppSettingsStore) {
        self.settingsStore = settingsStore
        language = settingsStore.appLanguage
    }

    func setLanguage(_ newLanguage: AppLanguage) {
        language = newLanguage
        settingsStore?.appLanguage = newLanguage
    }
}

@MainActor
func loc(_ key: String) -> String {
    let language = LocalizationCenter.shared.language
    guard
        let path = Bundle.main.path(forResource: language.rawValue, ofType: "lproj"),
        let languageBundle = Bundle(path: path)
    else {
        return key
    }
    return languageBundle.localizedString(forKey: key, value: key, table: "Localizable")
}
