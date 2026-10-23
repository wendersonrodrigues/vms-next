import CommonCrypto
import CryptoKit
import Foundation

/// Cofre das senhas das câmeras, como o login do VMS antigo: um arquivo criptografado (AES-GCM) com chave
/// derivada da senha do VMS Next (PBKDF2-SHA256). Substitui o Keychain, que pedia a senha do Mac a cada
/// nova compilação (o app é assinado ad-hoc, então o macOS o trata como outro app a cada versão).
///
/// "Lembrar senha" guarda a chave derivada num arquivo legível só pelo seu usuário do Mac.
final class Vault: ObservableObject {
    static let shared = Vault()

    @Published private(set) var isUnlocked = false
    @Published private(set) var user = "admin"

    private struct Stored: Codable {
        var user: String
        var salt: Data
        var iterations: Int
        /// [usuário@host: senha] criptografado.
        var box: Data
    }

    private let iterations = 200_000
    private var key: SymmetricKey?
    private var stored: Stored?
    private var passwords: [String: String] = [:]

    private let directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("VMSNext", isDirectory: true)
    private var vaultURL: URL { directory.appendingPathComponent("vault.json") }
    private var rememberURL: URL { directory.appendingPathComponent("login.key") }

    var isSetUp: Bool { stored != nil }
    var hasRememberedLogin: Bool { FileManager.default.fileExists(atPath: rememberURL.path) }

    private init() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: vaultURL), let saved = try? JSONDecoder().decode(Stored.self, from: data) {
            stored = saved
            user = saved.user
        }
    }

    // MARK: - Login

    /// Cria o cofre na primeira vez. `imported` traz senhas já existentes (do Keychain).
    func setUp(user: String, password: String, remember: Bool, imported: [String: String]) throws {
        var salt = Data(count: 16)
        _ = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let key = try Self.derive(password: password, salt: salt, iterations: iterations)
        self.key = key
        passwords = imported
        stored = Stored(user: user, salt: salt, iterations: iterations, box: Data())
        self.user = user
        try save()
        try setRemember(remember)
        isUnlocked = true
    }

    /// Abre o cofre. Retorna false se usuário ou senha estiverem errados.
    func unlock(user: String, password: String, remember: Bool) -> Bool {
        guard let stored, user == stored.user,
              let key = try? Self.derive(password: password, salt: stored.salt, iterations: stored.iterations),
              open(with: key) else { return false }
        try? setRemember(remember)
        AppLog.record(.login, "Entrada no VMS Next (\(user))")
        return true
    }

    /// Entra direto com a chave lembrada, se houver.
    func unlockWithRememberedLogin() -> Bool {
        guard let data = try? Data(contentsOf: rememberURL), data.count == 32 else { return false }
        return open(with: SymmetricKey(data: data))
    }

    /// Sai da sessão; com `forget`, apaga a senha lembrada.
    func lock(forget: Bool) {
        AppLog.record(.login, "Saída da sessão")
        if forget { try? FileManager.default.removeItem(at: rememberURL) }
        key = nil
        passwords = [:]
        isUnlocked = false
    }

    // MARK: - Senhas das câmeras

    func password(for account: String) -> String? {
        passwords[account]
    }

    func setPassword(_ password: String, for account: String) {
        passwords[account] = password
        try? save()
    }

    // MARK: - Arquivo

    private func open(with key: SymmetricKey) -> Bool {
        guard let stored else { return false }
        if stored.box.isEmpty {
            passwords = [:]
        } else {
            guard let box = try? AES.GCM.SealedBox(combined: stored.box),
                  let plain = try? AES.GCM.open(box, using: key),
                  let decoded = try? JSONDecoder().decode([String: String].self, from: plain) else { return false }
            passwords = decoded
        }
        self.key = key
        isUnlocked = true
        return true
    }

    private func save() throws {
        guard let key, var stored else { return }
        let plain = try JSONEncoder().encode(passwords)
        stored.box = try AES.GCM.seal(plain, using: key).combined ?? Data()
        self.stored = stored
        try JSONEncoder().encode(stored).write(to: vaultURL, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: vaultURL.path)
    }

    func setRemember(_ remember: Bool) throws {
        guard remember, let key else {
            try? FileManager.default.removeItem(at: rememberURL)
            return
        }
        let data = key.withUnsafeBytes { Data($0) }
        try data.write(to: rememberURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: rememberURL.path)
    }

    private static func derive(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        var derived = Data(count: 32)
        let passwordData = Data(password.utf8)
        let status = derived.withUnsafeMutableBytes { out in
            salt.withUnsafeBytes { saltBytes in
                passwordData.withUnsafeBytes { pass in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pass.baseAddress?.assumingMemoryBound(to: CChar.self), passwordData.count,
                        saltBytes.baseAddress?.assumingMemoryBound(to: UInt8.self), salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                        out.baseAddress?.assumingMemoryBound(to: UInt8.self), 32
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw CocoaError(.coderInvalidValue) }
        return SymmetricKey(data: derived)
    }
}
