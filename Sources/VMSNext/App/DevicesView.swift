import SwiftUI

/// "Dispositivos": equipamentos cadastrados e busca na rede local ("IPV4 pesquisar" do VMS antigo).
struct DevicesView: View {
    let onEdit: (Camera) -> Void
    let onSettings: (Camera) -> Void

    @EnvironmentObject private var store: CameraStore
    @StateObject private var model = DevicesModel()

    var body: some View {
        Form {
            Section {
                HStack {
                    Button {
                        Task { await model.search() }
                    } label: {
                        Label(model.searching ? "Procurando…" : "Procurar na rede", systemImage: "magnifyingglass")
                    }
                    .disabled(model.searching)
                    if model.searching { ProgressView().controlSize(.small) }
                    Spacer()
                    Button {
                        onEdit(Camera(name: "Nova câmera", host: "192.168.0."))
                    } label: {
                        Label("Adicionar manualmente", systemImage: "plus")
                    }
                }
                if let message = model.message {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(model.found) { device in
                    let added = store.cameras.contains { $0.host == device.ip }
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name.isEmpty ? device.ip : device.name)
                            Text("\(device.ip):\(device.port) · MAC \(device.mac)\(device.serial.isEmpty ? "" : " · CloudID \(device.serial)")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                        Spacer()
                        if added {
                            Label("Já adicionado", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .font(.callout)
                        } else {
                            Button("Adicionar…") { onEdit(model.camera(for: device)) }
                        }
                    }
                }
            } header: {
                Text("Encontrar na rede (IPV4 pesquisar)")
            } footer: {
                Text("Procura câmeras e NVRs Xiongmai ligados na mesma rede do Mac. Ao adicionar, digite o usuário e a senha do equipamento.")
                    .foregroundStyle(.secondary)
            }

            Section("Meus equipamentos") {
                ForEach(rows, id: \.id) { row in
                    HStack {
                        Image(systemName: row.isRecorder ? "server.rack" : "video")
                            .foregroundStyle(.secondary)
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title)
                            Text(row.subtitle).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                        Spacer()
                        Button("Editar…") { onEdit(row.camera) }
                        Button("Configurações…") { onSettings(row.camera) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Dispositivos")
    }

    private struct Row {
        let id: String
        let title: String
        let subtitle: String
        let camera: Camera
        let isRecorder: Bool
    }

    /// Câmeras avulsas e um item por NVR (os canais aparecem na lista de câmeras ao lado).
    private var rows: [Row] {
        var result = store.standaloneCameras.map { camera in
            Row(id: camera.id.uuidString, title: camera.name,
                subtitle: "\(camera.host):\(camera.dvripPort) · usuário \(camera.username)"
                    + (camera.cloudID.map { " · CloudID \($0)" } ?? ""),
                camera: camera, isRecorder: false)
        }
        for group in store.groups {
            guard let first = store.channels(in: group).first else { continue }
            result.append(Row(id: "group-\(group)", title: group,
                              subtitle: "\(first.host):\(first.dvripPort) · \(store.channels(in: group).count) canais · usuário \(first.username)",
                              camera: first, isRecorder: true))
        }
        return result
    }
}

@MainActor
final class DevicesModel: ObservableObject {
    @Published private(set) var found: [DeviceDiscovery.Found] = []
    @Published private(set) var searching = false
    @Published private(set) var message: String?

    func search() async {
        searching = true
        message = nil
        found = await DeviceDiscovery.search()
        searching = false
        if found.isEmpty {
            message = "Nenhum equipamento respondeu. Confira se o Mac está na mesma rede e se o VMS Next tem permissão de Rede Local (Ajustes do Sistema → Privacidade e Segurança → Rede Local)."
        }
    }

    func camera(for device: DeviceDiscovery.Found) -> Camera {
        var camera = Camera(name: device.name.isEmpty || device.name == "LocalHost" ? "Câmera \(device.ip)" : device.name,
                            host: device.ip)
        camera.dvripPort = device.port
        camera.cloudID = device.serial.isEmpty ? nil : device.serial
        return camera
    }
}
