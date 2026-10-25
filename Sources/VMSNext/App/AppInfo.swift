import Foundation

/// Versão do app, lida de um lugar só: Resources/Info.plist (CFBundleShortVersionString e CFBundleVersion).
/// Para trocar a versão, use `./scripts/set-version.sh 1.1.0` (ou `1.1.0-beta.1`); todas as telas mostram o valor daqui.
enum AppInfo {
    private static let rawVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    /// Versão para mostrar: "1.1.0-beta.1" vira "1.1.0 Beta 1".
    static let version = rawVersion.replacingOccurrences(of: "-beta.", with: " Beta ").replacingOccurrences(of: "-beta", with: " Beta")
    /// Versão de testes: ainda tem erros conhecidos.
    static let isBeta = rawVersion.contains("-beta")
    static let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
    /// "1.1.0 Beta 1 (28)"
    static var fullVersion: String { "\(version) (\(build))" }
}
