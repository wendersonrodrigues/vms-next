import SwiftUI
import UniformTypeIdentifiers

/// "Registro" do VMS antigo, com as duas abas: Cliente (o que aconteceu no VMS Next) e
/// Dispositivo (o registro guardado em cada câmera ou NVR, lido com OPLogQuery).
struct LogsView: View {
    @EnvironmentObject private var store: CameraStore
    @ObservedObject private var appLog = AppLog.shared
    @StateObject private var model = DeviceLogModel()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("Registro", selection: $model.tab) {
                    Text("Cliente (este app)").tag(DeviceLogModel.Tab.client)
                    Text("Dispositivo").tag(DeviceLogModel.Tab.device)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                DatePicker("De", selection: $model.from)
                DatePicker("até", selection: $model.to)
                Spacer()
            }
            .padding(Space.m)
            HStack(spacing: 12) {
                if model.tab == .device {
                    Picker("Equipamento", selection: $model.deviceID) {
                        ForEach(devices, id: \.id) { Text($0.displayName).tag(Optional($0.id)) }
                    }
                    .frame(maxWidth: 260)
                    Picker("Tipo", selection: $model.deviceType) {
                        ForEach(DeviceLogModel.types, id: \.value) { Text($0.label).tag($0.value) }
                    }
                    .frame(maxWidth: 220)
                    Button {
                        if let camera = devices.first(where: { $0.id == model.deviceID }) {
                            Task { await model.search(camera: camera) }
                        }
                    } label: {
                        Label("Procurar", systemImage: "magnifyingglass")
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.loading || model.deviceID == nil)
                    if model.loading { ProgressView().controlSize(.small) }
                } else {
                    Picker("Tipo", selection: $model.clientCategory) {
                        Text("Todos").tag(AppLog.Category?.none)
                        ForEach(AppLog.Category.allCases) { Text($0.label).tag(Optional($0)) }
                    }
                    .frame(maxWidth: 260)
                }
                Spacer()
                Button("Exportar…", action: export)
                    .disabled(rows.isEmpty)
                if model.tab == .client {
                    Button("Limpar") { appLog.clear() }
                        .disabled(appLog.entries.isEmpty)
                }
            }
            .padding(.horizontal, Space.m)
            .padding(.bottom, Space.m)
            Divider()
            if let message = model.message, model.tab == .device {
                Text(message).font(.callout).foregroundStyle(.secondary).padding(Space.s)
            }
            Table(rows) {
                TableColumn("Horário") { Text($0.time).monospacedDigit() }
                    .width(min: 140, ideal: 160)
                TableColumn("Usuário", value: \.user).width(min: 80, ideal: 110)
                TableColumn("Tipo", value: \.type).width(min: 110, ideal: 150)
                TableColumn("Equipamento", value: \.device).width(min: 100, ideal: 150)
                TableColumn("Nota") { Text($0.note).textSelection(.enabled) }
            }
            Divider()
            HStack {
                Text("\(rows.count) registro(s)").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .padding(Space.s)
        }
        .onAppear {
            if model.deviceID == nil { model.deviceID = devices.first?.id }
        }
    }

    /// Um item por equipamento físico (câmeras avulsas e NVRs).
    private var devices: [Camera] {
        var seen = Set<String>()
        return store.topLevel.compactMap { item -> Camera? in
            switch item {
            case let .camera(id): return store.cameras.first { $0.id == id }
            case let .group(name): return store.channels(in: name).first.map { var c = $0; c.name = name; c.group = nil; return c }
            }
        }
        .filter { seen.insert("\($0.host):\($0.dvripPort)").inserted }
    }

    private var rows: [LogRow] {
        switch model.tab {
        case .device:
            return model.rows
        case .client:
            return appLog.entries
                .filter { $0.date >= model.from && $0.date <= model.to }
                .filter { model.clientCategory == nil || $0.category == model.clientCategory }
                .map { LogRow(time: DeviceTime.string($0.date), user: Vault.shared.user, type: $0.category.label,
                              device: $0.device ?? "", note: $0.text) }
        }
    }

    private func export() {
        let prefs = AppPreferences.shared
        let name = "Registro \(model.tab == .client ? "cliente" : "dispositivo") \(AppPreferences.stamp(Date()))"
        guard let url = prefs.destination(named: name, in: prefs.downloadFolder, type: .commaSeparatedText) else { return }
        let escape: (String) -> String = { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let lines = ["Horário,Usuário,Tipo,Equipamento,Nota"]
            + rows.map { [$0.time, $0.user, $0.type, $0.device, $0.note].map(escape).joined(separator: ",") }
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

struct LogRow: Identifiable {
    let id = UUID()
    let time: String
    let user: String
    let type: String
    let device: String
    let note: String
}

@MainActor
final class DeviceLogModel: ObservableObject {
    enum Tab { case client, device }

    static let types: [(value: String, label: String)] = [
        ("LogAll", "Todos"), ("System", "Sistema"), ("Config", "Configuração"), ("Storage", "Armazenamento"),
        ("Alarm", "Alarmes"), ("Record", "Gravação"), ("Account", "Contas e acessos"), ("File", "Arquivos"),
    ]

    @Published var tab: Tab = .client
    @Published var from = Calendar.current.startOfDay(for: Date())
    @Published var to = Calendar.current.startOfDay(for: Date()).addingTimeInterval(86_399)
    @Published var deviceID: Camera.ID?
    @Published var deviceType = "LogAll"
    @Published var clientCategory: AppLog.Category?
    @Published private(set) var rows: [LogRow] = []
    @Published private(set) var loading = false
    @Published private(set) var message: String?

    /// OPLogQuery (código 1442) devolve até 128 registros por vez; continua de onde parou.
    func search(camera: Camera) async {
        loading = true
        message = nil
        rows = []
        defer { loading = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            var position = 0
            var result: [LogRow] = []
            for _ in 0 ..< 40 {
                let response = try await client.command(code: 1442, name: "OPLogQuery", payload: [
                    "BeginTime": DeviceTime.string(from), "EndTime": DeviceTime.string(to),
                    "LogPosition": position, "Type": deviceType,
                ] as [String: Any])
                let page = response["OPLogQuery"] as? [[String: Any]] ?? []
                result += page.map { entry in
                    LogRow(time: entry["Time"] as? String ?? "", user: entry["User"] as? String ?? "",
                           type: Self.label(entry["Type"] as? String ?? ""), device: camera.name,
                           note: entry["Data"] as? String ?? "")
                }
                guard page.count >= 128, let last = ConfigValue.int(page.last?["Position"]) else { break }
                position = last + 1
            }
            rows = result
            if result.isEmpty { message = "Nenhum registro neste período." }
        } catch {
            message = error.localizedDescription
        }
    }

    /// Tipos que o equipamento envia, em português; os desconhecidos aparecem como vieram.
    static func label(_ type: String) -> String {
        let names: [String: String] = [
            "LogIn": "Entrada", "LogOut": "Saída", "SaveConfig": "Configuração salva", "SetTime": "Hora alterada",
            "Reboot": "Reinício", "ShutDown": "Desligamento", "Upgrade": "Atualização",
            "EventStart": "Alarme (início)", "EventStop": "Alarme (fim)", "StorageDeviceError": "Erro no disco",
            "DiskChanged": "Disco trocado", "RecordStart": "Gravação iniciada", "RecordStop": "Gravação parada",
            "FileAccess": "Acesso a arquivo", "ClearLog": "Registro apagado", "AddUser": "Conta criada",
            "DeleteUser": "Conta apagada", "ModifyPassword": "Senha alterada",
        ]
        return names[type] ?? type
    }
}
