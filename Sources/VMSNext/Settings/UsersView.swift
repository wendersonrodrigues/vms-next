import SwiftUI

/// "Usuários": contas (Users, 1472), grupos (Groups, 1474; criar 1476, apagar 1480), adicionar (User, 1482), apagar (DelUser, 1486)
/// e troca de senha (ModifyPassword, 1488; senhas no hash de 8 caracteres do login DVRIP). Ao trocar a
/// senha da conta usada pelo app, o cofre é atualizado para o app continuar conectando.
@MainActor
final class UsersModel: ObservableObject {
    struct Account: Identifiable {
        let name: String
        let group: String
        let memo: String
        let reserved: Bool
        var id: String { name }
    }

    struct Group: Identifiable {
        let name: String
        let memo: String
        let authorities: [String]
        var id: String { name }
    }

    /// Permissões em português; "Monitor_03" vira "Ao vivo" do canal 3 e assim por diante.
    static let authorityNames: [String: String] = [
        "ShutDown": "Desligar e reiniciar", "ChannelTitle": "Nome dos canais", "RecordConfig": "Config. de gravação",
        "Backup": "Copiar gravações", "StorageManager": "Gerenciar disco", "Account": "Contas e senhas",
        "SysInfo": "Informações do sistema", "QueryLog": "Ver registro", "DelLog": "Apagar registro",
        "SysUpgrade": "Atualizar firmware", "AutoMaintain": "Manutenção automática", "TourConfig": "Ronda",
        "TVadjustConfig": "Ajuste da TV", "GeneralConfig": "Config. geral", "EncodeConfig": "Qualidade do vídeo",
        "NetConfig": "Rede", "AlarmConfig": "Alarmes", "VideoConfig": "Imagem", "PTZControl": "Controle PTZ",
        "DefaultConfig": "Restaurar padrão", "DigitalManager": "Câmeras do NVR", "ImExport": "Importar/exportar",
    ]

    /// Resume a lista de permissões: nomes claros e os canais de "Ao vivo"/"Gravações"/"Áudio" agrupados.
    static func describe(_ authorities: [String]) -> [String] {
        var plain: [String] = []
        var channels: [String: [Int]] = [:]
        for item in authorities {
            let parts = item.split(separator: "_")
            if parts.count == 2, let number = Int(parts[1]) {
                channels[String(parts[0]), default: []].append(number)
            } else {
                plain.append(authorityNames[item] ?? item)
            }
        }
        let labels = ["Monitor": "Ver ao vivo", "Replay": "Ver gravações", "Talk": "Áudio bidirecional"]
        let grouped = channels.keys.sorted().map { key -> String in
            let numbers = channels[key]!.sorted()
            let range = numbers.count > 1 && numbers.last! - numbers.first! == numbers.count - 1
                ? "canais \(numbers.first!)–\(numbers.last!)" : "canal " + numbers.map(String.init).joined(separator: ", ")
            return "\(labels[key] ?? key) · \(range)"
        }
        return grouped + plain
    }

    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published var diagnosticText: String?
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var groups: [Group] = []

    // Adicionar usuário
    @Published var adding = false
    @Published var newName = ""
    @Published var newGroup = "user"
    @Published var newMemo = ""
    @Published var newUserPassword = ""
    @Published var newUserConfirmation = ""

    @Published var deleting: Account?

    // Grupos ("Add grupo" e "Deletar grupo" do VMS antigo): o novo grupo copia as permissões de um existente.
    @Published var addingGroup = false
    @Published var newGroupName = ""
    @Published var newGroupMemo = ""
    @Published var groupTemplate = "user"
    @Published var deletingGroup: Group?

    /// Conta com a troca de senha aberta.
    @Published var editing: Account?
    @Published var oldPassword = ""
    @Published var newPassword = ""
    @Published var confirmation = ""
    @Published private(set) var formError: String?

    let camera: Camera

    init(camera: Camera) {
        self.camera = camera
    }

    var appAccount: String { camera.username }

    func load() async {
        loading = true
        error = nil
        defer { loading = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            let response = try await client.command(code: 1472, name: "Users", payload: nil)
            let list = response["Users"] as? [[String: Any]] ?? []
            accounts = list.map { user in
                Account(name: user["Name"] as? String ?? "?",
                        group: user["Group"] as? String ?? "",
                        memo: user["Memo"] as? String ?? "",
                        reserved: (user["Reserved"] as? Bool) ?? false)
            }
            if let groupList = try? await client.command(code: 1474, name: "Groups", payload: nil)["Groups"] as? [[String: Any]] {
                groups = groupList.map { group in
                    Group(name: group["Name"] as? String ?? "?", memo: group["Memo"] as? String ?? "",
                          authorities: group["AuthorityList"] as? [String] ?? [])
                }
            }
            if accounts.isEmpty { error = "O equipamento não informou as contas. Use \"Diagnóstico…\" e me envie o resultado." }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func beginPasswordChange(_ account: Account) {
        editing = account
        oldPassword = account.name == appAccount ? (Vault.shared.password(for: camera.keychainAccount) ?? "") : ""
        newPassword = ""
        confirmation = ""
        formError = nil
    }

    func changePassword() async -> Bool {
        guard let account = editing else { return false }
        guard newPassword == confirmation else {
            formError = "As senhas novas não conferem."
            return false
        }
        guard newPassword.count >= 6 else {
            formError = "Use pelo menos 6 caracteres."
            return false
        }
        saving = true
        formError = nil
        defer { saving = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            try await client.request(code: 1488, fields: [
                "EncryptType": "MD5",
                "UserName": account.name,
                "PassWord": DVRIPClient.sofiaHash(oldPassword),
                "NewPassWord": DVRIPClient.sofiaHash(newPassword),
            ])
            if account.name == appAccount {
                // A conta do app mudou de senha: atualiza o cofre e reconecta (vale para todos os canais do NVR).
                Vault.shared.setPassword(newPassword, for: camera.keychainAccount)
                DeviceSessions.shared.invalidate(account: camera.keychainAccount)
            }
            notice = "Senha de \(account.name) alterada."
            editing = nil
            return true
        } catch DVRIPError.device(let code) where code == 203 || code == 106 || code == 214 {
            formError = "A senha atual está errada."
            return false
        } catch {
            formError = error.localizedDescription
            return false
        }
    }

    // MARK: - Adicionar e apagar

    func beginAdding() {
        newName = ""
        newGroup = groups.contains { $0.name == "user" } ? "user" : (groups.first?.name ?? "user")
        newMemo = ""
        newUserPassword = ""
        newUserConfirmation = ""
        formError = nil
        adding = true
    }

    func addUser() async -> Bool {
        let name = newName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
            formError = "Use só letras sem acento, números, ponto, traço ou sublinhado no nome."
            return false
        }
        guard !accounts.contains(where: { $0.name.lowercased() == name.lowercased() }) else {
            formError = "Já existe uma conta com esse nome."
            return false
        }
        guard newUserPassword == newUserConfirmation else {
            formError = "As senhas não conferem."
            return false
        }
        guard newUserPassword.count >= 6 else {
            formError = "Use pelo menos 6 caracteres na senha."
            return false
        }
        saving = true
        formError = nil
        defer { saving = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            let authorities = groups.first { $0.name == newGroup }?.authorities ?? []
            try await client.command(code: 1482, name: "User", payload: [
                "AuthorityList": authorities, "Group": newGroup, "Memo": newMemo, "Name": name,
                "Password": DVRIPClient.sofiaHash(newUserPassword), "Reserved": false, "Sharable": true,
            ] as [String: Any])
            notice = "Conta \(name) criada."
            adding = false
            await load()
            return true
        } catch {
            formError = error.localizedDescription
            return false
        }
    }

    /// Motivo para não deixar apagar a conta (nil = pode apagar).
    func deleteBlocker(_ account: Account) -> String? {
        if account.reserved { return "Conta reservada do equipamento." }
        if account.name == appAccount { return "É a conta que o VMS Next usa." }
        let admins = accounts.filter { $0.group.lowercased() == "admin" }
        if account.group.lowercased() == "admin", admins.count <= 1 { return "É o único administrador." }
        return nil
    }

    func deleteUser(_ account: Account) async {
        guard deleteBlocker(account) == nil else { return }
        saving = true
        error = nil
        notice = nil
        defer { saving = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            try await client.request(code: 1486, fields: ["Name": account.name])
            notice = "Conta \(account.name) apagada."
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func beginAddingGroup() {
        newGroupName = ""
        newGroupMemo = ""
        groupTemplate = groups.contains { $0.name == "user" } ? "user" : (groups.first?.name ?? "user")
        formError = nil
        addingGroup = true
    }

    func addGroup() async {
        let name = newGroupName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else {
            formError = "Use só letras sem acento, números, ponto, traço ou sublinhado no nome."
            return
        }
        guard !groups.contains(where: { $0.name.lowercased() == name.lowercased() }) else {
            formError = "Já existe um grupo com esse nome."
            return
        }
        saving = true
        formError = nil
        defer { saving = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            let authorities = groups.first { $0.name == groupTemplate }?.authorities ?? []
            try await client.command(code: 1476, name: "Group", payload: [
                "AuthorityList": authorities, "Memo": newGroupMemo, "Name": name,
            ] as [String: Any])
            notice = "Grupo \(name) criado."
            addingGroup = false
            await load()
        } catch {
            formError = error.localizedDescription
        }
    }

    /// Motivo para não deixar apagar o grupo (nil = pode apagar).
    func deleteBlocker(_ group: Group) -> String? {
        if ["admin", "user"].contains(group.name.lowercased()) { return "Grupo padrão do equipamento." }
        if accounts.contains(where: { $0.group == group.name }) { return "Há contas neste grupo." }
        return nil
    }

    func deleteGroup(_ group: Group) async {
        guard deleteBlocker(group) == nil else { return }
        saving = true
        error = nil
        notice = nil
        defer { saving = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            try await client.request(code: 1480, fields: ["Name": group.name])
            notice = "Grupo \(group.name) apagado."
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func diagnostic() async -> String {
        await ConfigDiagnostics.dump(camera: camera, requests: [(1472, "Users"), (1474, "Groups")])
    }
}

struct UsersView: View {
    @StateObject private var model: UsersModel
    @EnvironmentObject private var store: CameraStore

    init(camera: Camera) {
        _model = StateObject(wrappedValue: UsersModel(camera: camera))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Lendo do equipamento…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    Section {
                        ForEach(model.accounts) { account in
                            HStack(spacing: 10) {
                                Image(systemName: account.group.lowercased() == "admin" ? "person.badge.key.fill" : "person.fill")
                                    .foregroundStyle(account.group.lowercased() == "admin" ? Theme.accent : .secondary)
                                    .frame(width: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(account.name).fontWeight(.medium)
                                        if account.name == model.appAccount {
                                            Text("usada pelo VMS Next").font(.caption2)
                                                .padding(.horizontal, Space.xs).padding(.vertical, Space.xxs)
                                                .background(Theme.accent.opacity(0.15), in: Capsule())
                                        }
                                        if account.reserved {
                                            Text("reservada").font(.caption2).foregroundStyle(.secondary)
                                        }
                                    }
                                    Text(groupLabel(account.group) + (account.memo.isEmpty ? "" : " · \(account.memo)"))
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Trocar senha…") { model.beginPasswordChange(account) }
                                Button(role: .destructive) {
                                    model.deleting = account
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                                .disabled(model.deleteBlocker(account) != nil)
                                .help(model.deleteBlocker(account).map { "Não pode apagar: \($0)" } ?? "Apagar conta")
                                .accessibilityLabel("Apagar a conta \(account.name)")
                            }
                            .padding(.vertical, Space.xxs)
                        }
                        Button {
                            model.beginAdding()
                        } label: {
                            Label("Adicionar usuário", systemImage: "person.badge.plus")
                        }
                        .disabled(model.groups.isEmpty)
                    } header: {
                        Text("Contas do equipamento (Usuários)")
                    } footer: {
                        Text("Administrador pode mudar tudo; usuário comum só vê e faz o que o grupo dele permite. Conta reservada não pode ser apagada.")
                            .foregroundStyle(.secondary)
                    }
                    if !model.groups.isEmpty {
                        Section {
                            ForEach(model.groups) { group in
                                DisclosureGroup {
                                    ForEach(UsersModel.describe(group.authorities), id: \.self) { item in
                                        Label(item, systemImage: "checkmark").font(.callout)
                                    }
                                } label: {
                                    HStack {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(groupLabel(group.name)).fontWeight(.medium)
                                            Text("\(group.authorities.count) permissões" + (group.memo.isEmpty ? "" : " · \(group.memo)"))
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                        Spacer()
                                        Button(role: .destructive) {
                                            model.deletingGroup = group
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                        .disabled(model.deleteBlocker(group) != nil)
                                        .help(model.deleteBlocker(group).map { "Não pode apagar: \($0)" } ?? "Apagar grupo")
                                        .accessibilityLabel("Apagar o grupo \(group.name)")
                                    }
                                }
                            }
                            Button {
                                model.beginAddingGroup()
                            } label: {
                                Label("Adicionar grupo", systemImage: "person.3")
                            }
                        } header: {
                            Text("Grupos e permissões")
                        } footer: {
                            Text("Cada conta recebe as permissões do seu grupo. O grupo novo começa com as permissões de um grupo existente; editar permissões ainda é feito no VMS antigo.")
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let error = model.error {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            Divider()
            HStack {
                if let notice = model.notice {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(Theme.success)
                }
                Spacer()
                Button("Diagnóstico…") { Task { model.diagnosticText = await model.diagnostic() } }
                    .disabled(model.loading || model.saving)
                Button("Recarregar") { Task { await model.load() } }
                    .keyboardShortcut("r")
                    .disabled(model.loading || model.saving)
            }
            .padding(Space.m)
        }
        .task { await model.load() }
        .sheet(item: $model.editing) { account in
            passwordSheet(account)
        }
        .sheet(isPresented: $model.adding) { addSheet }
        .sheet(isPresented: $model.addingGroup) { addGroupSheet }
        .confirmationDialog("Apagar o grupo \(model.deletingGroup?.name ?? "")?",
                            isPresented: Binding(get: { model.deletingGroup != nil }, set: { if !$0 { model.deletingGroup = nil } })) {
            Button("Apagar", role: .destructive) {
                if let group = model.deletingGroup { Task { await model.deleteGroup(group) } }
            }
            Button("Cancelar", role: .cancel) { model.deletingGroup = nil }
        }
        .confirmationDialog("Apagar a conta \(model.deleting?.name ?? "")?",
                            isPresented: Binding(get: { model.deleting != nil }, set: { if !$0 { model.deleting = nil } })) {
            Button("Apagar", role: .destructive) {
                if let account = model.deleting { Task { await model.deleteUser(account) } }
            }
            Button("Cancelar", role: .cancel) { model.deleting = nil }
        } message: {
            Text("Quem usa essa conta (iCSee, VMS antigo ou outro app) deixa de conseguir acessar o equipamento.")
        }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }

    private func groupLabel(_ group: String) -> String {
        switch group.lowercased() {
        case "admin": return "Administrador"
        case "user": return "Usuário comum"
        case "": return "Sem grupo"
        default: return group
        }
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Adicionar usuário").font(.headline)
            Form {
                TextField("Nome de usuário", text: $model.newName)
                SecureField("Senha", text: $model.newUserPassword)
                SecureField("Confirmar senha", text: $model.newUserConfirmation)
                Picker(selection: $model.newGroup) {
                    ForEach(model.groups) { Text(groupLabel($0.name)).tag($0.name) }
                } label: {
                    FieldLabel("Grupo", detail: "Usuário comum só vê ao vivo e gravações; administrador pode mudar tudo.")
                }
                TextField("Descrição (opcional)", text: $model.newMemo)
            }
            .formStyle(.grouped)
            if let error = model.formError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            }
            HStack {
                Spacer()
                Button("Cancelar") { model.adding = false }
                    .keyboardShortcut(.cancelAction)
                Button("Adicionar") { Task { _ = await model.addUser() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.saving || model.newName.isEmpty || model.newUserPassword.isEmpty)
            }
        }
        .padding(Space.xl)
        .frame(width: 460)
    }

    private var addGroupSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Adicionar grupo").font(.headline)
            Form {
                TextField("Nome do grupo", text: $model.newGroupName)
                Picker(selection: $model.groupTemplate) {
                    ForEach(model.groups) { Text(groupLabel($0.name)).tag($0.name) }
                } label: {
                    FieldLabel("Começar com as permissões de", detail: "O grupo novo recebe as mesmas permissões deste grupo.")
                }
                TextField("Descrição (opcional)", text: $model.newGroupMemo)
            }
            .formStyle(.grouped)
            if let error = model.formError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            }
            HStack {
                Spacer()
                Button("Cancelar") { model.addingGroup = false }
                    .keyboardShortcut(.cancelAction)
                Button("Adicionar") { Task { await model.addGroup() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.saving || model.newGroupName.isEmpty)
            }
        }
        .padding(Space.xl)
        .frame(width: 460)
    }

    private func passwordSheet(_ account: UsersModel.Account) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trocar a senha de \(account.name)").font(.headline)
            Form {
                SecureField("Senha atual", text: $model.oldPassword)
                SecureField("Senha nova", text: $model.newPassword)
                SecureField("Confirmar senha nova", text: $model.confirmation)
            }
            .formStyle(.grouped)
            if account.name == model.appAccount {
                Label("Esta é a conta que o VMS Next usa. Depois da troca, o app passa a usar a senha nova sozinho. Lembre de atualizar também o iCSee e o VMS antigo.",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = model.formError {
                Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
            }
            HStack {
                Spacer()
                Button("Cancelar") { model.editing = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Trocar senha") {
                    Task {
                        if await model.changePassword() { store.vaultDidUnlock() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.saving || model.newPassword.isEmpty)
            }
        }
        .padding(Space.xl)
        .frame(width: 440)
    }
}
