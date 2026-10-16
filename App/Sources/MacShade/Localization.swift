import Foundation

/// Localized string (key = English text, translations in Resources/<lang>.lproj/Localizable.strings), with printf-style arguments.
func L(_ key: String, _ args: CVarArg...) -> String {
    let format = NSLocalizedString(key, comment: "")
    return args.isEmpty ? format : String(format: format, arguments: args)
}

/// Languages the launcher is translated into (code, name in its own language).
let appLanguages: [(code: String, name: String)] = [
    ("en", "English"), ("de", "Deutsch"), ("fr", "Français"), ("es", "Español"), ("it", "Italiano"),
    ("pt", "Português"), ("ja", "日本語"), ("zh-Hans", "简体中文"),
]
