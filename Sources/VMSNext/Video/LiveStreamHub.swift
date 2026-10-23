import Combine
import Foundation

/// Vídeos ao vivo compartilhados entre quadros: as duas metades de uma câmera dividida usam a mesma
/// conexão. Cada quadro pega o vídeo ao aparecer e devolve ao sumir; sem nenhum quadro, ele para.
@MainActor
final class LiveStreamHub {
    static let shared = LiveStreamHub()

    private var streams: [String: LiveStream] = [:]
    private var users: [String: Int] = [:]
    /// Nome mostrado de cada vídeo (para a captura automática de fotos).
    private(set) var names: [String: String] = [:]

    static func key(_ camera: Camera, _ quality: StreamQuality) -> String {
        "\(camera.id)-\(quality.rawValue)"
    }

    func stream(for key: String) -> LiveStream {
        if let stream = streams[key] { return stream }
        let stream = LiveStream()
        streams[key] = stream
        return stream
    }

    /// Retorna true se este é o primeiro quadro usando o vídeo.
    func acquire(_ key: String, name: String) -> Bool {
        names[key] = names[key] ?? name
        users[key, default: 0] += 1
        return users[key] == 1
    }

    /// Vídeos em uso agora (algum quadro na tela), com o nome.
    var active: [(name: String, stream: LiveStream)] {
        users.filter { $0.value > 0 }.compactMap { key, _ in
            streams[key].map { (names[key] ?? key, $0) }
        }
    }

    func release(_ key: String) {
        let count = max((users[key] ?? 1) - 1, 0)
        users[key] = count
        guard count == 0, let stream = streams[key] else { return }
        AudioFocus.shared.release(stream.audioID)
        stream.stop()
    }
}

/// Liga um quadro a um vídeo do LiveStreamHub e repassa as mudanças do vídeo para o SwiftUI.
@MainActor
final class StreamLease: ObservableObject {
    let key: String
    let stream: LiveStream
    private var forward: AnyCancellable?

    init(key: String) {
        self.key = key
        stream = LiveStreamHub.shared.stream(for: key)
        forward = stream.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }
}
