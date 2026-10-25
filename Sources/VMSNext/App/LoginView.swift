import SwiftUI

final class LoginForm: ObservableObject {
    @Published var user = Vault.shared.user
    @Published var password = ""
    @Published var confirmation = ""
    @Published var remember = true
    @Published var importOld = true
    @Published var error: String?
}

/// Login ao abrir o app, como no VMS antigo. Na primeira vez, cria a senha do VMS Next.
struct LoginView: View {
    @EnvironmentObject private var store: CameraStore
    @ObservedObject var vault: Vault
    @StateObject private var form = LoginForm()

    private var settingUp: Bool { !vault.isSetUp }

    var body: some View {
        VStack(spacing: 0) {
            // Cabeçalho com o logo e as cores do tema (claro e escuro), como o resto do app.
            HStack(spacing: Space.m) {
                AppLogo(size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text("VMS Next").font(.title.weight(.bold))
                    Text(settingUp ? "Primeiro acesso" : "Entre para ver as suas câmeras")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, Space.xxl)
            .padding(.vertical, Space.l)
            .background(Theme.surface)
            .overlay(alignment: .bottom) { Divider() }

            Form {
                if settingUp {
                    Text("Crie a senha de acesso ao VMS Next. Ela protege as senhas das câmeras guardadas no app.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                TextField("Nome de usuário", text: $form.user)
                SecureField("Senha", text: $form.password)
                if settingUp {
                    SecureField("Confirmar senha", text: $form.confirmation)
                }
                Toggle("Lembrar senha", isOn: $form.remember)
                if settingUp {
                    Toggle("Trazer as senhas das câmeras já salvas", isOn: $form.importOld)
                        .help("Lê as senhas guardadas no Keychain pelas versões anteriores. O macOS pode pedir a senha do Mac uma última vez.")
                }
                if let error = form.error {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            HStack {
                Spacer()
                Button("Sair") { NSApp.terminate(nil) }
                Button(settingUp ? "Criar e entrar" : "Entrar", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(form.user.isEmpty || form.password.isEmpty)
            }
            .padding([.horizontal, .bottom], Space.xl)
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .background(Theme.background)
        .tint(Theme.accent)
    }

    private func submit() {
        form.error = nil
        let user = form.user.trimmingCharacters(in: .whitespaces)
        if settingUp {
            guard form.password.count >= 4 else { return form.error = "Use pelo menos 4 caracteres." }
            guard form.password == form.confirmation else { return form.error = "As senhas não conferem." }
            var imported: [String: String] = [:]
            if form.importOld {
                for account in Set(store.cameras.map(\.keychainAccount)) {
                    if let password = Keychain.password(for: account) { imported[account] = password }
                }
            }
            do {
                try vault.setUp(user: user, password: form.password, remember: form.remember, imported: imported)
                store.vaultDidUnlock()
            } catch {
                form.error = "Não foi possível criar o cofre: \(error.localizedDescription)"
            }
        } else if vault.unlock(user: user, password: form.password, remember: form.remember) {
            store.vaultDidUnlock()
        } else {
            form.error = "Usuário ou senha incorretos."
            form.password = ""
        }
    }
}
