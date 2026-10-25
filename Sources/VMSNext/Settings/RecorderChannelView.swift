import SwiftUI

/// Configuração por canal (como o "ChannelNo" do VMS antigo): escolhe o canal e mostra a mesma tela que o canal
/// tem sozinho. Usada no NVR e nas câmeras avulsas com mais de um canal (lente dupla, como o Quintal/Corredor).
struct RecorderChannelView<Content: View>: View {
    let recorder: Camera
    let channelCount: Int
    /// Canal mostrado ao abrir (o da câmera escolhida na lista).
    var initialChannel = 1
    @ViewBuilder let content: (Camera) -> Content

    @EnvironmentObject private var store: CameraStore
    @StateObject private var selection = ChannelSelection()

    final class ChannelSelection: ObservableObject {
        @Published var channel = 1
        var started = false
        /// Total de canais informado pelo NVR (SystemInfo); nil até ler.
        @Published var deviceCount: Int?
    }

    private var count: Int { max(selection.deviceCount ?? channelCount, 1) }

    var body: some View {
        VStack(spacing: 0) {
            picker
            content(camera(for: selection.channel))
                .id(selection.channel)
        }
        .task {
            if !selection.started {
                selection.started = true
                selection.channel = initialChannel
            }
            guard selection.deviceCount == nil,
                  let client = try? await DeviceSessions.shared.client(for: recorder),
                  let info = try? await client.command(code: 1020, name: "SystemInfo", payload: nil),
                  let system = info["SystemInfo"] as? [String: Any] else { return }
            let total = (ConfigValue.int(system["DigChannel"]) ?? 0) + (ConfigValue.int(system["VideoInChannel"]) ?? 0)
            if total > 0 { selection.deviceCount = total }
        }
    }

    private var picker: some View {
        VStack(spacing: 0) {
            HStack {
                Picker(selection: $selection.channel) {
                    ForEach(Array(Set(1 ... count).union([selection.channel])).sorted(), id: \.self) { channel in
                        Text(name(channel)).tag(channel)
                    }
                } label: {
                    FieldLabel("Canal", original: "ChannelNo")
                }
                .frame(maxWidth: 420)
                .disabled(count == 1)
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            Divider()
        }
    }

    /// Usa a câmera cadastrada do canal, se houver; senão cria uma com o mesmo acesso do NVR.
    private func camera(for channel: Int) -> Camera {
        if let known = store.cameras.first(where: { $0.host == recorder.host && $0.group == recorder.group && $0.channel == channel }) {
            return known
        }
        var camera = recorder
        camera.id = UUID()
        camera.channel = channel
        camera.name = "Canal \(channel)"
        return camera
    }

    private func name(_ channel: Int) -> String {
        let known = store.cameras.first { $0.host == recorder.host && $0.group == recorder.group && $0.channel == channel }
        return known.map { "Canal \(channel) · \($0.name)" } ?? "Canal \(channel)"
    }
}
