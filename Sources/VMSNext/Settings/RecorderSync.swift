import SwiftUI

/// Câmera configurada num canal digital do NVR (NetWork.RemoteDeviceV3 / RemoteDevice).
struct NVRChannelInfo {
    /// Canal do NVR começando em 1 (D01 = 1), o mesmo número do RTSP/DVRIP do NVR.
    let channel: Int
    let enabled: Bool
    let name: String
    let ip: String
    /// Canal da câmera ligada (começando em 1).
    let remoteChannel: Int

    var configured: Bool { !ip.isEmpty && ip != "0.0.0.0" }
}

enum RecorderChannels {
    /// Lê do NVR a câmera de cada canal digital.
    static func read(_ camera: Camera) async throws -> [NVRChannelInfo] {
        let client = try await DeviceSessions.shared.client(for: camera)
        var raw = try? await client.getConfig("NetWork.RemoteDeviceV3")
        if raw == nil { raw = try? await client.getConfig("NetWork.RemoteDevice") }
        guard let items = raw as? [Any] else {
            throw NSError(domain: "VMSNext", code: 1, userInfo: [NSLocalizedDescriptionKey:
                String(localized: "O NVR não informou as câmeras dos canais.")])
        }
        return parse(items)
    }

    static func parse(_ items: [Any]) -> [NVRChannelInfo] {
        items.enumerated().compactMap { index, item in
            guard let dict = item as? [String: Any] else { return nil }
            let decoders = (dict["Decoder"] as? [[String: Any]]) ?? []
            let selected = (ConfigValue.int(dict["SingleConnId"]) ?? 1) - 1
            let decoder = decoders.indices.contains(selected) ? decoders[selected] : decoders.first
            let enabled = (dict["Enable"] as? Bool) ?? ((ConfigValue.int(dict["Enable"]) ?? 0) != 0)
            let ip = (decoder?["IPAddress"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                ?? NetworkModel.hexToIP(decoder?["Address"]) ?? ""
            return NVRChannelInfo(channel: index + 1, enabled: enabled,
                                  name: (decoder?["ConfName"] as? String) ?? (decoder?["Name"] as? String) ?? "",
                                  ip: ip, remoteChannel: (ConfigValue.int(decoder?["Channel"]) ?? 0) + 1)
        }
    }
}

/// "Atualizar canais pelo NVR": compara a lista do app com as câmeras que estão no NVR e propõe
/// adicionar, remover e renomear canais (e refazer a ligação "Mesma câmera" com as câmeras avulsas).
@MainActor
final class RecorderSyncModel: ObservableObject {
    enum Kind { case add, remove, update }

    struct Change: Identifiable {
        let id = UUID()
        let kind: Kind
        let channel: Int
        /// Canal do app (nil quando é canal novo).
        let existing: Camera?
        let newName: String
        let newSameAs: Camera.ID?
        let detail: String
        var include = true
    }

    let group: String
    @Published private(set) var loading = true
    @Published private(set) var error: String?
    @Published var changes: [Change] = []

    init(group: String) { self.group = group }

    func load(store: CameraStore) async {
        loading = true
        error = nil
        defer { loading = false }
        guard let first = store.channels(in: group).first else { return }
        do {
            let nvr = try await RecorderChannels.read(first)
            changes = Self.plan(nvr: nvr, channels: store.channels(in: group), standalone: store.standaloneCameras)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Câmera avulsa do app que é a câmera ligada no canal (mesmo IP; com várias no IP, o mesmo canal).
    static func match(_ info: NVRChannelInfo, in standalone: [Camera]) -> Camera? {
        let sameHost = standalone.filter { $0.host == info.ip }
        if sameHost.count <= 1 { return sameHost.first }
        return sameHost.first { $0.channel == info.remoteChannel }
    }

    static func plan(nvr: [NVRChannelInfo], channels: [Camera], standalone: [Camera]) -> [Change] {
        let active = nvr.filter { $0.enabled && $0.configured }
        var result: [Change] = []
        for info in active {
            let linked = match(info, in: standalone)
            let cameraName = linked?.name ?? (info.name.isEmpty ? info.ip : info.name)
            let proposed = "Canal \(info.channel) - \(cameraName)"
            let where_ = "\(info.ip) · \(info.name.isEmpty ? "—" : info.name)"
            if let existing = channels.first(where: { $0.channel == info.channel }) {
                // Só muda o nome quando a câmera do canal mudou; nome dado pelo usuário fica.
                guard existing.sameAs != linked?.id else { continue }
                let changedCamera = existing.sameAs != nil
                result.append(Change(kind: .update, channel: info.channel, existing: existing,
                                     newName: changedCamera ? proposed : existing.name, newSameAs: linked?.id,
                                     detail: where_))
            } else {
                result.append(Change(kind: .add, channel: info.channel, existing: nil, newName: proposed,
                                     newSameAs: linked?.id, detail: where_))
            }
        }
        let activeNumbers = Set(active.map(\.channel))
        for camera in channels where !activeNumbers.contains(camera.channel) {
            result.append(Change(kind: .remove, channel: camera.channel, existing: camera, newName: camera.name,
                                 newSameAs: nil, detail: String(localized: "Canal desativado ou vazio no NVR")))
        }
        return result.sorted { $0.channel < $1.channel }
    }

    func apply(store: CameraStore) {
        let chosen = changes.filter(\.include)
        guard !chosen.isEmpty, let template = store.channels(in: group).first else { return }
        var list = store.cameras
        let removed = Set(chosen.filter { $0.kind == .remove }.compactMap { $0.existing?.id })
        for change in chosen where change.kind == .update {
            guard let id = change.existing?.id, let index = list.firstIndex(where: { $0.id == id }) else { continue }
            list[index].name = change.newName
            list[index].sameAs = change.newSameAs
        }
        list.removeAll { removed.contains($0.id) }
        // Canais novos entram logo depois do último canal do NVR, na ordem dos números.
        let added: [Camera] = chosen.filter { $0.kind == .add }.map { change in
            var camera = template
            camera.id = UUID()
            camera.name = change.newName
            camera.channel = change.channel
            camera.sameAs = change.newSameAs
            camera.split = nil
            camera.ptz = .auto
            return camera
        }
        // Cada câmera avulsa fica ligada a um canal só.
        let linkedNow = Set(chosen.compactMap(\.newSameAs))
        for index in list.indices where list[index].group == group && list[index].sameAs.map(linkedNow.contains) == true {
            if !chosen.contains(where: { $0.existing?.id == list[index].id }) { list[index].sameAs = nil }
        }
        let insertAt = (list.lastIndex { $0.group == group }).map { $0 + 1 } ?? list.endIndex
        list.insert(contentsOf: added, at: insertAt)
        store.cameras = list
        AppLog.shared.add(.config, String(format: "Canais do NVR atualizados pelo NVR: %d mudança(s)", chosen.count), device: group)
        changes = []
    }
}

struct RecorderSyncSheet: View {
    @EnvironmentObject private var store: CameraStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var model: RecorderSyncModel

    init(group: String) {
        _model = StateObject(wrappedValue: RecorderSyncModel(group: group))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            Text(String(format: String(localized: "Sincronizar canais do %@"), model.group)).font(.headline)
            Text("Compara a lista do app com as câmeras que estão configuradas no NVR. Marque o que deve mudar.")
                .foregroundStyle(.secondary)
            Group {
                if model.loading {
                    ProgressView("Lendo do NVR…").frame(maxWidth: .infinity, minHeight: 160)
                } else if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else if model.changes.isEmpty {
                    Label("A lista do app já está igual à do NVR.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.success)
                        .frame(maxWidth: .infinity, minHeight: 120)
                } else {
                    List {
                        ForEach($model.changes) { $change in
                            Toggle(isOn: $change.include) { row(change) }
                                .toggleStyle(.checkbox)
                                .padding(.vertical, 2)
                        }
                    }
                    .frame(minHeight: 380)
                }
            }
            HStack {
                Spacer()
                Button(model.changes.isEmpty ? String(localized: "Fechar") : String(localized: "Cancelar")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                if !model.changes.isEmpty {
                    Button("Sincronizar") {
                        model.apply(store: store)
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.changes.contains(where: \.include))
                }
            }
        }
        .padding(Space.xl)
        .frame(width: 620)
        .task { await model.load(store: store) }
    }

    @ViewBuilder
    private func row(_ change: RecorderSyncModel.Change) -> some View {
        let linkedName = change.newSameAs.flatMap { id in store.cameras.first { $0.id == id }?.name }
        VStack(alignment: .leading, spacing: 2) {
            switch change.kind {
            case .add:
                Label(String(format: String(localized: "Adicionar %@"), change.newName), systemImage: "plus.circle.fill")
                    .foregroundStyle(Theme.success)
            case .remove:
                Label(String(format: String(localized: "Remover %@"), change.newName), systemImage: "minus.circle.fill")
                    .foregroundStyle(Theme.warning)
            case .update:
                if let old = change.existing?.name, old != change.newName {
                    Label("\(old) → \(change.newName)", systemImage: "arrow.triangle.2.circlepath")
                } else {
                    Label(change.newName, systemImage: "link")
                }
            }
            Group {
                Text(String(format: "D%02d · %@", change.channel, change.detail))
                if change.kind != .remove {
                    Text(linkedName.map { String(format: String(localized: "Mesma câmera que: %@"), $0) }
                        ?? String(localized: "Sem câmera avulsa ligada"))
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}
