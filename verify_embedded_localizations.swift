import Foundation

@main
struct VerifyEmbeddedLocalizations {
    static func main() {
        let expected: [(String, String)] = [
            ("en", "PROFILE"),
            ("es", "PERFIL"),
            ("pt-BR", "PERFIL"),
            ("vi", "HỒ SƠ"),
            ("zh-Hans", "个人资料"),
        ]

        for (locale, expectedValue) in expected {
            guard let actual = EmbeddedLocalizationCatalog.text(
                for: "vesper.tab.profile",
                languageCode: locale
            ) else {
                fatalError("Missing embedded profile-tab translation for \(locale)")
            }
            guard actual == expectedValue else {
                fatalError("Wrong profile-tab translation for \(locale): \(actual)")
            }
        }
        print("Embedded localization runtime smoke test passed for all 5 languages.")
    }
}
