import AppKit
import SwiftUI

/// Idioma do app: igual ao Mac, português (o original) ou inglês. Usa o "AppleLanguages" do próprio app, o
/// mesmo que o macOS usa em Ajustes do Sistema › Geral › Idioma e Região › Apps; vale depois de reiniciar,
/// e assim também traduz os menus do sistema.
@MainActor
final class LanguageSettings: ObservableObject {
    enum Language: String, CaseIterable, Identifiable {
        case system, portuguese = "pt-BR", english = "en"
        var id: String { rawValue }

        /// Cada idioma no próprio idioma, como no macOS.
        var label: String {
            switch self {
            case .system: return String(localized: "Igual ao Mac")
            case .portuguese: return "Português (Brasil)"
            case .english: return "English"
            }
        }
    }

    static let shared = LanguageSettings()
    private static let key = "AppleLanguages"

    /// O que está valendo agora (lido ao abrir o app).
    let current: Language
    @Published var selected: Language {
        didSet { save() }
    }
    var needsRestart: Bool { selected != current }

    private init() {
        let saved = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "")?[Self.key] as? [String]
        let language = saved?.first.flatMap { code in Language.allCases.first { $0 != .system && code.hasPrefix($0.rawValue.prefix(2)) } } ?? .system
        current = language
        selected = language
    }

    private func save() {
        if selected == .system {
            UserDefaults.standard.removeObject(forKey: Self.key)
        } else {
            UserDefaults.standard.set([selected.rawValue], forKey: Self.key)
        }
    }

    /// Abre uma nova cópia do app e fecha esta (as gravações no Mac são fechadas antes, ao sair).
    func restart() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}
