import Foundation

/// Localized string lookup for code that is not a SwiftUI view.
///
/// Keys are the English source text, so if the `.lproj` resources are missing
/// (for example when running the binary straight out of `swift build`) the app
/// still shows readable English instead of a key.
func L(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: key, table: nil)
}

/// Localized string with `String(format:)` arguments.
func L(_ key: String, _ args: CVarArg...) -> String {
    String(format: L(key), arguments: args)
}
