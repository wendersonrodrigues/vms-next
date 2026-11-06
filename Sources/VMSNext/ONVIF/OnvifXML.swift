import Foundation

/// Árvore simples de um XML de resposta ONVIF. Os nomes ficam sem o prefixo (tt:, trt:, tds:…), porque cada
/// fabricante usa os seus.
final class OnvifXML {
    let name: String
    let attributes: [String: String]
    fileprivate(set) var text = ""
    fileprivate(set) var children: [OnvifXML] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    static func parse(_ data: Data) -> OnvifXML? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        guard parser.parse() else { return nil }
        return builder.root
    }

    /// Primeiro elemento com esse nome, em qualquer nível abaixo (incluindo este).
    func first(_ name: String) -> OnvifXML? {
        if self.name == name { return self }
        for child in children {
            if let found = child.first(name) { return found }
        }
        return nil
    }

    /// Todos os elementos com esse nome, em qualquer nível abaixo.
    func all(_ name: String) -> [OnvifXML] {
        var result = self.name == name ? [self] : []
        for child in children { result += child.all(name) }
        return result
    }

    /// Texto do primeiro elemento com esse nome, sem espaços nas pontas.
    func value(_ name: String) -> String? {
        first(name).map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Atributo pelo nome sem prefixo.
    func attribute(_ name: String) -> String? {
        attributes.first { Self.local($0.key) == name }?.value
    }

    fileprivate static func local(_ name: String) -> String {
        name.split(separator: ":").last.map(String.init) ?? name
    }

    private final class Builder: NSObject, XMLParserDelegate {
        var root: OnvifXML?
        private var stack: [OnvifXML] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes: [String: String] = [:]) {
            let node = OnvifXML(name: OnvifXML.local(elementName), attributes: attributes)
            stack.last?.children.append(node)
            if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            stack.last?.text += string
        }
    }
}

extension String {
    /// Texto seguro dentro de um XML.
    var xmlEscaped: String {
        replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}
