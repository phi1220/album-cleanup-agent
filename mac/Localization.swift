import Foundation

enum L10n {
    static let languageKey = "appLanguage"
    static let supportedLanguages = ["en", "zh-Hans"]

    static func language(for selection: String? = nil, preferred: [String] = Locale.preferredLanguages) -> String {
        let selected = selection ?? UserDefaults.standard.string(forKey: languageKey) ?? "system"
        if supportedLanguages.contains(selected) { return selected }
        return Bundle.preferredLocalizations(from: supportedLanguages, forPreferences: preferred).first ?? "en"
    }

    static func locale(for selection: String? = nil) -> Locale {
        Locale(identifier: language(for: selection))
    }

    static func bundle(for language: String) -> Bundle {
        guard let url = Bundle.main.url(forResource: language, withExtension: "lproj"),
              let bundle = Bundle(url: url) else { return .main }
        return bundle
    }

    static var modelInstruction: String {
        language() == "en"
            ? "\nWrite all human-readable reasons, conditions, exceptions and guidance in English. Preserve JSON keys, IDs and quoted user feedback."
            : "\n所有面向用户的理由、条件、例外和审核补充均使用简体中文。保留 JSON 键、编号及引用的用户反馈原文。"
    }

    // Older state files saved rendered system reports. Translate those for display only;
    // this is never applied to user feedback, model observations or preference content.
    static func storedStatus(_ text: String) -> String {
        let placeholder = try! NSRegularExpression(pattern: #"%(?:(\d+)\$)?@"#)
        for language in supportedLanguages {
            let bundle = bundle(for: language)
            guard let url = bundle.url(forResource: "Localizable", withExtension: "strings"),
                  let data = try? Data(contentsOf: url),
                  let catalog = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String] else { continue }
            for key in catalog.keys.sorted(by: { $0.count > $1.count }) {
                let template = catalog[key]!
                let tokens = placeholder.matches(in: template, range: NSRange(template.startIndex..., in: template))
                var pattern = "^", offset = template.startIndex
                for token in tokens {
                    let range = Range(token.range, in: template)!
                    pattern += NSRegularExpression.escapedPattern(for: String(template[offset..<range.lowerBound]).replacingOccurrences(of: "%%", with: "%")) + "(.*?)"
                    offset = range.upperBound
                }
                pattern += NSRegularExpression.escapedPattern(for: String(template[offset...]).replacingOccurrences(of: "%%", with: "%")) + "$"
                guard let regex = try? NSRegularExpression(pattern: pattern, options: .dotMatchesLineSeparators),
                      let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { continue }
                var arguments = Array(repeating: "", count: tokens.count)
                for (index, token) in tokens.enumerated() {
                    let position = Range(token.range(at: 1), in: template).flatMap { Int(template[$0]) }.map { $0 - 1 } ?? index
                    guard arguments.indices.contains(position) else { return text }
                    let value = String(text[Range(match.range(at: index + 1), in: text)!])
                    arguments[position] = Self.bundle(for: self.language()).localizedString(forKey: value, value: value, table: nil)
                }
                let format = Self.bundle(for: self.language()).localizedString(forKey: key, value: key, table: nil)
                return String(format: format, locale: locale(), arguments: arguments)
            }
        }
        return text
    }
}

func tr(_ key: String, _ arguments: CVarArg...) -> String {
    let format = L10n.bundle(for: L10n.language()).localizedString(forKey: key, value: key, table: nil)
    return String(format: format, locale: L10n.locale(), arguments: arguments)
}
