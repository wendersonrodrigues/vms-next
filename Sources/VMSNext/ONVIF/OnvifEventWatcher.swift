import Foundation

/// Alertas de uma câmera ONVIF: assina os eventos dela (CreatePullPointSubscription) e fica pedindo as
/// mensagens novas (PullMessages, até 10 s de espera cada). Movimento, pessoa e câmera tampada viram
/// início/fim de alerta, como o 1504 das câmeras Xiongmai. Se a assinatura cair, assina de novo.
@MainActor
final class OnvifEventWatcher {
    /// Nome do evento (no formato que AlarmKind entende) e se começou (true) ou terminou.
    var onEvent: ((_ event: String, _ isStart: Bool) -> Void)?
    /// Situação para a tela de Eventos ("Recebendo alertas" ou o erro).
    var onStatus: ((String) -> Void)?

    private let camera: Camera
    private var task: Task<Void, Never>?
    private var subscribedOnce = false

    init(camera: Camera) {
        self.camera = camera
    }

    var isRunning: Bool { task != nil }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                let services = try await OnvifServices.shared.entry(for: camera)
                let client = services.client
                // O endereço informado e, se ele não aceitar, os caminhos de costume (há câmeras que atendem tudo no principal).
                var candidates = [services.events].compactMap { $0 }
                if var parts = URLComponents(url: client.deviceURL, resolvingAgainstBaseURL: false) {
                    parts.path = "/onvif/event_service"
                    if let url = parts.url { candidates.append(url) }
                }
                candidates.append(client.deviceURL)
                var created: OnvifXML?
                var lastError: Error = OnvifClient.Failure.invalid
                for url in candidates where created == nil {
                    do {
                        created = try await client.call(url, body: """
                        <tev:CreatePullPointSubscription><tev:InitialTerminationTime>PT600S</tev:InitialTerminationTime></tev:CreatePullPointSubscription>
                        """)
                    } catch OnvifClient.Failure.auth {
                        throw OnvifClient.Failure.auth
                    } catch {
                        lastError = error
                    }
                }
                guard let created else { throw lastError }
                guard let address = created.first("SubscriptionReference")?.value("Address"),
                      let subscription = client.rehosted(address) else { throw OnvifClient.Failure.invalid }
                subscribedOnce = true
                onStatus?(String(localized: "Recebendo alertas (ONVIF)"))
                var renewed = Date()
                while !Task.isCancelled {
                    let reply = try await client.call(subscription, body: """
                    <tev:PullMessages><tev:Timeout>PT10S</tev:Timeout><tev:MessageLimit>20</tev:MessageLimit></tev:PullMessages>
                    """, timeout: 20, headers: Self.addressing(subscription, action: "PullPointSubscription/PullMessagesRequest"))
                    for message in reply.all("NotificationMessage") { handle(message) }
                    if Date().timeIntervalSince(renewed) > 240 {
                        _ = try? await client.call(subscription, body: "<wsnt:Renew><wsnt:TerminationTime>PT600S</wsnt:TerminationTime></wsnt:Renew>",
                                                   headers: Self.addressing(subscription, action: "SubscriptionManager/RenewRequest"))
                        renewed = Date()
                    }
                }
            } catch OnvifClient.Failure.auth {
                guard !Task.isCancelled else { return }
                onStatus?(OnvifClient.Failure.auth.localizedDescription)
                try? await Task.sleep(for: .seconds(300))
            } catch {
                guard !Task.isCancelled else { return }
                // A assinatura nunca deu certo: a câmera provavelmente não manda alertas pelo ONVIF (só o vídeo).
                // Tenta de novo de vez em quando, sem ficar insistindo.
                onStatus?(subscribedOnce ? error.localizedDescription
                                         : String(localized: "Esta câmera não manda alertas pelo ONVIF (só o vídeo)."))
                OnvifServices.shared.invalidate(camera)
                try? await Task.sleep(for: .seconds(subscribedOnce ? 30 : 600))
            }
        }
    }

    private static func addressing(_ url: URL, action: String) -> String {
        "<wsa:Action>http://www.onvif.org/ver10/events/wsdl/\(action)</wsa:Action><wsa:To>\(url.absoluteString.xmlEscaped)</wsa:To>"
    }

    /// Ex.: tópico "tns1:RuleEngine/CellMotionDetector/Motion" com IsMotion = true. O estado inicial
    /// ("Initialized", mandado ao assinar) é ignorado para não virar alerta de algo que já estava acontecendo.
    private func handle(_ message: OnvifXML) {
        guard let topic = message.value("Topic") else { return }
        let inner = message.first("Message")?.children.first { $0.name == "Message" } ?? message.first("Message")
        if inner?.attribute("PropertyOperation") == "Initialized" { return }
        let items = inner?.first("Data")?.all("SimpleItem") ?? []
        guard let state = items.first(where: { ["true", "false", "1", "0"].contains(($0.attribute("Value") ?? "").lowercased()) }) else { return }
        let active = ["true", "1"].contains((state.attribute("Value") ?? "").lowercased())
        guard let event = Self.eventName(topic: topic) else { return }
        onEvent?(event, active)
    }

    /// Tópico ONVIF → nome no formato dos eventos Xiongmai (AlarmKind entende "Human", "Motion", "Blind").
    static func eventName(topic: String) -> String? {
        let lower = topic.lowercased()
        if lower.contains("human") || lower.contains("people") || lower.contains("person") || lower.contains("face") { return "HumanDetect" }
        if lower.contains("tamper") || lower.contains("blind") { return "BlindDetect" }
        if lower.contains("motion") || lower.contains("field") || lower.contains("linedetector") || lower.contains("crossing") { return "MotionDetect" }
        return nil
    }
}
