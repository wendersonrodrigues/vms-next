import Foundation

/// Utilidades para o JSON de configuração da Xiongmai, que mistura inteiros e
/// strings hexadecimais ("0x00000001") para o mesmo tipo de campo.
enum ConfigValue {
    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        guard let text = value as? String else { return nil }
        if text.lowercased().hasPrefix("0x") { return Int(text.dropFirst(2), radix: 16) }
        return Int(text)
    }

    /// Grava preservando o tipo original do campo (hex string ou número). Campos ausentes não são criados.
    static func set(_ dict: inout [String: Any], _ key: String, _ value: Int) {
        guard let old = dict[key] else { return }
        dict[key] = old is String ? String(format: "0x%08X", value) : value
    }

    /// Configurações de canal às vezes vêm como objeto e às vezes como lista de um elemento.
    static func object(in raw: Any?) -> [String: Any]? {
        if let dict = raw as? [String: Any] { return dict }
        return (raw as? [Any])?.first as? [String: Any]
    }

    static func replacingObject(in raw: Any, with dict: [String: Any]) -> Any {
        if var list = raw as? [Any], !list.isEmpty {
            list[0] = dict
            return list
        }
        return dict
    }
}
