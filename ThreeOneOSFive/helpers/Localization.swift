import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    static let storageKey = "appLanguage"

    case english = "en"
    case spanish = "es"
    case vietnamese = "vi"
    case portuguese = "pt-BR"
    case simplifiedChinese = "zh-Hans"

    var id: String { rawValue }
    var locale: Locale { Locale(identifier: rawValue) }

    var displayName: String {
        switch self {
        case .english: return "English"
        case .spanish: return "Español"
        case .vietnamese: return "Tiếng Việt"
        case .portuguese: return "Português"
        case .simplifiedChinese: return "简体中文"
        }
    }

    func text(_ key: String) -> String {
        EmbeddedLocalizationCatalog.text(for: key, languageCode: rawValue)
            ?? EmbeddedLocalizationCatalog.text(for: key, languageCode: AppLanguage.english.rawValue)
            ?? key
    }

    func text(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }

    static func currentText(_ key: String) -> String {
        let code = UserDefaults.standard.string(forKey: storageKey) ?? AppLanguage.english.rawValue
        return (AppLanguage(rawValue: code) ?? .english).text(key)
    }
}

private struct AppLanguageEnvironmentKey: EnvironmentKey {
    static let defaultValue = AppLanguage.english
}

extension EnvironmentValues {
    var appLanguage: AppLanguage {
        get { self[AppLanguageEnvironmentKey.self] }
        set { self[AppLanguageEnvironmentKey.self] = newValue }
    }
}

extension ExploitStatus {
    func displayText(language: AppLanguage) -> String {
        switch self {
        case .notStarted:
            return language.text("status.not_attempted")
        case .success(let method):
            let localizedMethod = method == "Simulator preview"
                ? language.text("method.simulator_preview")
                : method
            return language.text("status.ok_via", localizedMethod)
        case .failed(let method, let code):
            return language.text("status.failed_via", method, code)
        case .unsupported(let message):
            return language.text("status.unsupported_reason", message)
        }
    }
}
