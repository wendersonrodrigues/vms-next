import Foundation

/// Versão do app, lida de um lugar só: Resources/Info.plist (CFBundleShortVersionString e CFBundleVersion).
/// Para trocar a versão, use `./scripts/set-version.sh 1.1.0`; todas as telas mostram o valor daqui.
enum AppInfo {
    static let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    /// "1.0.0 (27)"
    static var fullVersion: String { "\(version) (\(build))" }
}
