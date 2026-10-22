import Foundation
import SQLite3

/// Lê nome, IP, usuário e canais do devices.db do VMS da Xiongmai.
/// As senhas não são importadas: o usuário as digita no app e elas vão para o Keychain.
enum LegacyVMSImporter {
    static let defaultPath = "/Applications/VMS.app/Contents/MacOS/data/users/admin/devices.db"

    struct ImportError: LocalizedError {
        let errorDescription: String?
    }

    static func load(path: String = defaultPath) throws -> [Camera] {
        guard FileManager.default.fileExists(atPath: path) else {
            throw ImportError(errorDescription: "Banco do VMS não encontrado em \(path)")
        }
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw ImportError(errorDescription: "Não foi possível abrir o banco do VMS")
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        let sql = "SELECT Name, Address, UserName, AnalogChan, DigitalChan FROM Devices ORDER BY ID"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ImportError(errorDescription: "Formato do banco do VMS não reconhecido")
        }
        defer { sqlite3_finalize(statement) }

        var cameras: [Camera] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let host = text(statement, 1)
            guard !host.isEmpty else { continue }
            let user = text(statement, 2)
            let name = cleanName(text(statement, 0), host: host)
            let channels = max(1, Int(sqlite3_column_int(statement, 3)) + Int(sqlite3_column_int(statement, 4)))
            for channel in 1 ... channels {
                cameras.append(Camera(
                    name: channels > 1 ? "\(name) · Canal \(channel)" : name,
                    host: host,
                    channel: channel,
                    username: user.isEmpty ? "admin" : user
                ))
            }
        }
        return cameras
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: pointer)
    }

    /// "Frente - 192.168.0.19" → "Frente"
    private static func cleanName(_ name: String, host: String) -> String {
        let cleaned = name.replacingOccurrences(of: host, with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " -–").union(.whitespaces))
        return cleaned.isEmpty ? host : cleaned
    }
}
