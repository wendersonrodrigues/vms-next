import SwiftUI

/// Formulário de configuração descrito por campos (nome da config + caminho dentro do JSON).
/// Campos que o equipamento não envia ficam escondidos, e cada valor é gravado no mesmo tipo
/// em que veio (número, booleano ou texto hexadecimal "0x...").
enum ConfigKey: Hashable, ExpressibleByStringLiteral, ExpressibleByIntegerLiteral {
    case key(String)
    case index(Int)

    init(stringLiteral value: String) { self = .key(value) }
    init(integerLiteral value: Int) { self = .index(value) }
}

/// Uma configuração lida da câmera. Quando ela vem como lista (um item por canal), `element` escolhe o item.
struct ConfigSource {
    let name: String
    var element: Int?
}

struct ConfigOption {
    let value: String
    let label: String

    init(_ value: String, _ label: String) {
        self.value = value
        self.label = label
    }
}

struct ConfigCondition {
    let source: Int
    let path: [ConfigKey]
    let values: Set<String>
}

struct ConfigField: Identifiable {
    enum Kind {
        case toggle
        case choice([ConfigOption])
        case number(ClosedRange<Int>, unit: String?)
        case slider(ClosedRange<Int>)
        case text
        /// Somente leitura.
        case info
        /// Somente leitura, IPv4 em hex little-endian (um endereço ou uma lista).
        case ipAddress
    }

    let id = UUID()
    let source: Int
    let path: [ConfigKey]
    let kind: Kind
    let title: String
    var original: String?
    var detail: String?
    /// Campo só editável quando outro campo tem um destes valores (ex.: taxa de bits só em CBR).
    var enabledWhen: ConfigCondition?
    /// Campo travado quando outro campo tem um destes valores (ex.: taxa de bits com Smart Encode ligado).
    var disabledWhen: ConfigCondition?
    /// Valores que este equipamento aceita (lidos das capacidades); nil = todas as opções.
    var allowed: (@MainActor (ConfigFormModel) -> [String]?)?
    /// Opções montadas a partir das capacidades (substituem as fixas quando não são nil).
    var dynamicOptions: (@MainActor (ConfigFormModel) -> [ConfigOption]?)?
    /// Função que o equipamento precisa ter em SystemFunction, ex.: "EncodeFunction.SmartH264V2",
    /// ou na capacidade "Camera", ex.: "Camera.SupportSetLDC" (a capacidade precisa estar em spec.abilities).
    var requires: String?
}

struct ConfigSection: Identifiable {
    let id = UUID()
    let title: String
    var footer: String?
    let fields: [ConfigField]
    /// Função que o equipamento precisa ter em SystemFunction, ex.: "NetServerFunction.NetNat".
    var requires: String?
}

struct ConfigFormSpec {
    var intro: String?
    let sources: [ConfigSource]
    let sections: [ConfigSection]
    /// Mensagem de confirmação antes de aplicar, para mudanças que podem cortar o acesso.
    var confirmApply: String?
    var emptyMessage = "Este equipamento não tem estas opções."
    /// Pergunta se quer reiniciar depois de aplicar, como o VMS antigo faz na codificação (algumas
    /// câmeras respondem "salvo" sem avisar que só aplicam depois de reiniciar).
    var offersRestart = false
    /// Capacidades (ABILITY_GET, 1360) incluídas no diagnóstico, ex.: "EncodeCapability".
    var abilities: [String] = []
    /// Ilustração do efeito dos ajustes (opcional), no topo do formulário.
    var preview: (@MainActor (ConfigFormModel) -> SettingPreview)?
}

@MainActor
final class ConfigFormModel: ObservableObject {
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published var diagnosticText: String?
    @Published var confirming = false
    /// O equipamento salvou, mas só aplica depois de reiniciar (resposta 603).
    @Published var askingRestart = false
    @Published private(set) var objects: [Int: Any] = [:]
    /// Capacidades lidas com ABILITY_GET (1360), por nome.
    private(set) var abilities: [String: Any] = [:]

    let camera: Camera
    let spec: ConfigFormSpec
    private var raws: [Int: Any] = [:]
    private var loaded: [Int: Any] = [:]

    init(camera: Camera, spec: ConfigFormSpec) {
        self.camera = camera
        self.spec = spec
    }

    var visibleSections: [ConfigSection] {
        spec.sections.compactMap { section in
            guard section.requires.map(supports) ?? true else { return nil }
            let fields = section.fields.filter { field in
                value(source: field.source, path: field.path) != nil && (field.requires.map(supports) ?? true)
            }
            return fields.isEmpty ? nil : ConfigSection(title: section.title, footer: section.footer, fields: fields)
        }
    }

    /// "Camera.X": campo X da capacidade Camera ligado (sem a capacidade, considera que não tem, como o VMS
    /// antigo); o resto vem de SystemFunction.
    func supports(_ path: String) -> Bool {
        if path.hasPrefix("Camera.") {
            let value = (abilities["Camera"] as? [String: Any])?[String(path.dropFirst(7))]
            return (value as? Bool) ?? (ConfigValue.int(value) == 1)
        }
        return DeviceCapabilities.supports(abilities["SystemFunction"] as? [String: Any], path)
    }

    var hasChanges: Bool {
        objects.contains { index, object in
            guard let old = loaded[index] else { return false }
            return !(object as AnyObject).isEqual(old)
        }
    }

    func load() async {
        loading = true
        error = nil
        notice = nil
        defer { loading = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            raws = [:]
            objects = [:]
            for (index, source) in spec.sources.enumerated() {
                guard let raw = try? await client.getConfig(source.name),
                      let object = Self.element(of: raw, at: source.element) else { continue }
                raws[index] = raw
                objects[index] = object
            }
            loaded = objects
            abilities = [:]
            if let functions = await DeviceCapabilities.systemFunction(for: camera) { abilities["SystemFunction"] = functions }
            for name in spec.abilities {
                if let response = try? await client.command(code: 1360, name: name, payload: nil), let value = response[name] {
                    abilities[name] = value
                }
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func apply() async {
        saving = true
        error = nil
        notice = nil
        defer { saving = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            var needsRestart = false
            var changed = false
            for (index, object) in objects.sorted(by: { $0.key < $1.key }) {
                guard let old = loaded[index], !(object as AnyObject).isEqual(old), let raw = raws[index] else { continue }
                let source = spec.sources[index]
                let updated = Self.replacing(element: source.element, in: raw, with: object)
                if try await client.setConfig(source.name, updated) == 603 { needsRestart = true }
                changed = true
                raws[index] = updated
                loaded[index] = object
            }
            if needsRestart || (changed && spec.offersRestart) {
                notice = "Salvo. Vale depois que a câmera reiniciar."
                askingRestart = true
            } else {
                notice = "Configuração aplicada."
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    func diagnostic() async -> String {
        await ConfigDiagnostics.dump(camera: camera, requests: spec.sources.map { (UInt16(1042), $0.name) }
            + spec.abilities.map { (UInt16(1360), $0) } + [(UInt16(1360), "SystemFunction")])
    }

    func restart() async {
        error = nil
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            try await client.command(code: 1450, name: "OPMachine", payload: ["Action": "Reboot"])
            notice = "Reiniciando a câmera. Ela volta em cerca de 1 minuto."
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Valores

    func value(source: Int, path: [ConfigKey]) -> Any? {
        guard var current = objects[source] else { return nil }
        for key in path {
            switch key {
            case let .key(name):
                guard let dict = current as? [String: Any], let next = dict[name], !(next is NSNull) else { return nil }
                current = next
            case let .index(position):
                guard let list = current as? [Any], list.indices.contains(position) else { return nil }
                current = list[position]
            }
        }
        return current
    }

    func setValue(_ newValue: Any, source: Int, path: [ConfigKey]) {
        guard let object = objects[source] else { return }
        objects[source] = Self.setting(newValue, at: path[...], in: object)
    }

    func isEnabled(_ field: ConfigField) -> Bool {
        if let blocker = field.disabledWhen,
           let key = Self.choiceKey(value(source: blocker.source, path: blocker.path)), blocker.values.contains(key) {
            return false
        }
        guard let condition = field.enabledWhen else { return true }
        guard let key = Self.choiceKey(value(source: condition.source, path: condition.path)) else { return true }
        return condition.values.contains(key)
    }

    func bool(_ field: ConfigField) -> Binding<Bool> {
        Binding(
            get: { Self.boolValue(self.value(source: field.source, path: field.path)) },
            set: { new in
                let old = self.value(source: field.source, path: field.path)
                self.setValue(Self.encodeBool(new, like: old), source: field.source, path: field.path)
            })
    }

    func int(_ field: ConfigField, range: ClosedRange<Int>) -> Binding<Int> {
        Binding(
            get: { ConfigValue.int(self.value(source: field.source, path: field.path)) ?? range.lowerBound },
            set: { new in
                let old = self.value(source: field.source, path: field.path)
                self.setValue(Self.encodeInt(min(max(new, range.lowerBound), range.upperBound), like: old),
                              source: field.source, path: field.path)
            })
    }

    /// Texto do campo numérico, gravado a cada tecla (sem depender de Enter). Só o máximo é limitado
    /// durante a digitação, para não atrapalhar quem digita "1" antes de "1024".
    func numberText(_ field: ConfigField, range: ClosedRange<Int>) -> Binding<String> {
        Binding(
            get: { ConfigValue.int(self.value(source: field.source, path: field.path)).map(String.init) ?? "" },
            set: { new in
                let digits = new.filter(\.isNumber)
                guard let number = Int(digits) else { return }
                let old = self.value(source: field.source, path: field.path)
                self.setValue(Self.encodeInt(min(number, range.upperBound), like: old), source: field.source, path: field.path)
            })
    }

    func double(_ field: ConfigField, range: ClosedRange<Int>) -> Binding<Double> {
        let binding = int(field, range: range)
        return Binding(get: { Double(binding.wrappedValue) }, set: { binding.wrappedValue = Int($0.rounded()) })
    }

    func choice(_ field: ConfigField) -> Binding<String> {
        Binding(
            get: { Self.choiceKey(self.value(source: field.source, path: field.path)) ?? "" },
            set: { new in
                let old = self.value(source: field.source, path: field.path)
                self.setValue(Self.encodeChoice(new, like: old), source: field.source, path: field.path)
            })
    }

    func text(_ field: ConfigField) -> Binding<String> {
        Binding(
            get: { self.value(source: field.source, path: field.path) as? String ?? "" },
            set: { self.setValue($0, source: field.source, path: field.path) })
    }

    /// Opções do campo mais o valor atual do equipamento, se ele não estiver na lista.
    func options(for field: ConfigField, _ options: [ConfigOption]) -> [ConfigOption] {
        var result = field.dynamicOptions?(self) ?? options
        let options = result
        if let allowed = field.allowed?(self), !allowed.isEmpty {
            result = options.filter { allowed.contains($0.value) }
                + allowed.filter { value in !options.contains { $0.value == value } }.map { ConfigOption($0, $0) }
        }
        guard let current = Self.choiceKey(value(source: field.source, path: field.path)),
              !result.contains(where: { $0.value == current }) else { return result }
        return result + [ConfigOption(current, "Valor do equipamento (\(current))")]
    }

    func infoText(_ field: ConfigField) -> String {
        let raw = value(source: field.source, path: field.path)
        if case .ipAddress = field.kind {
            let list = (raw as? [Any]) ?? [raw as Any]
            let ips = list.compactMap { NetworkModel.hexToIP($0) }.filter { $0 != "0.0.0.0" }
            return ips.isEmpty ? "—" : ips.joined(separator: ", ")
        }
        if let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue ? "Ligado" : "Desligado"
        }
        if let text = raw as? String { return text.isEmpty ? "—" : text }
        if let number = raw as? NSNumber { return number.stringValue }
        if let list = raw as? [Any] { return list.isEmpty ? "Nenhum" : list.map { "\($0)" }.joined(separator: ", ") }
        return "—"
    }

    // MARK: - Conversões

    private static func isBool(_ value: Any?) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    static func choiceKey(_ value: Any?) -> String? {
        if isBool(value) { return (value as! NSNumber).boolValue ? "1" : "0" }
        if let number = value as? NSNumber { return String(number.intValue) }
        if let text = value as? String {
            if text.lowercased().hasPrefix("0x"), let number = ConfigValue.int(text) { return String(number) }
            return text
        }
        return nil
    }

    static func boolValue(_ value: Any?) -> Bool {
        if let number = value as? NSNumber { return number.intValue != 0 }
        return (ConfigValue.int(value) ?? 0) != 0
    }

    static func encodeBool(_ value: Bool, like old: Any?) -> Any {
        if isBool(old) { return value }
        return encodeInt(value ? 1 : 0, like: old)
    }

    static func encodeInt(_ value: Int, like old: Any?) -> Any {
        if let text = old as? String, text.lowercased().hasPrefix("0x") { return String(format: "0x%08X", value) }
        if old is String { return String(value) }
        return value
    }

    static func encodeChoice(_ key: String, like old: Any?) -> Any {
        if isBool(old) { return key == "1" }
        if let number = Int(key) {
            if old is NSNumber { return number }
            if let text = old as? String, text.lowercased().hasPrefix("0x") { return String(format: "0x%08X", number) }
        }
        return key
    }

    private static func element(of raw: Any, at index: Int?) -> Any? {
        guard let list = raw as? [Any] else { return raw }
        let position = index ?? 0
        return list.indices.contains(position) ? list[position] : nil
    }

    private static func replacing(element index: Int?, in raw: Any, with object: Any) -> Any {
        guard var list = raw as? [Any] else { return object }
        let position = index ?? 0
        if list.indices.contains(position) { list[position] = object }
        return list
    }

    private static func setting(_ newValue: Any, at path: ArraySlice<ConfigKey>, in object: Any) -> Any {
        guard let key = path.first else { return newValue }
        let rest = path.dropFirst()
        switch key {
        case let .key(name):
            guard var dict = object as? [String: Any], let child = dict[name] else { return object }
            dict[name] = setting(newValue, at: rest, in: child)
            return dict
        case let .index(position):
            guard var list = object as? [Any], list.indices.contains(position) else { return object }
            list[position] = setting(newValue, at: rest, in: list[position])
            return list
        }
    }
}

struct ConfigFormView: View {
    @StateObject private var model: ConfigFormModel

    init(camera: Camera, spec: ConfigFormSpec) {
        _model = StateObject(wrappedValue: ConfigFormModel(camera: camera, spec: spec))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Lendo da câmera…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let sections = model.visibleSections
                Form {
                    if let intro = model.spec.intro, !sections.isEmpty {
                        Section {
                            if let preview = model.spec.preview {
                                HStack {
                                    Spacer()
                                    preview(model)
                                    Spacer()
                                }
                            }
                            Text(intro)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    ForEach(sections) { section in
                        Section {
                            ForEach(section.fields) { field in
                                row(field).disabled(!model.isEnabled(field) || model.saving)
                            }
                        } header: {
                            Text(section.title)
                        } footer: {
                            if let footer = section.footer {
                                Text(footer).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let message = model.error {
                        Section {
                            Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                        }
                    } else if sections.isEmpty {
                        Section {
                            Label(model.spec.emptyMessage, systemImage: "info.circle").foregroundStyle(.secondary)
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
                    .disabled(model.loading || model.saving)
                Button("Aplicar") {
                    if model.spec.confirmApply != nil {
                        model.confirming = true
                    } else {
                        Task { await model.apply() }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.loading || model.saving || !model.hasChanges)
            }
            .padding(Space.m)
        }
        .task { await model.load() }
        .confirmationDialog("Aplicar as mudanças?", isPresented: $model.confirming) {
            Button("Aplicar", role: .destructive) { Task { await model.apply() } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text(model.spec.confirmApply ?? "")
        }
        .alert("Reiniciar a câmera agora?", isPresented: $model.askingRestart) {
            Button("Reiniciar agora") { Task { await model.restart() } }
            Button("Depois, manualmente", role: .cancel) {}
        } message: {
            Text("A câmera salvou as mudanças, mas só passa a usá-las depois de reiniciar. Enquanto reinicia (cerca de 1 minuto) o vídeo e a gravação param.")
        }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }

    @ViewBuilder
    private func row(_ field: ConfigField) -> some View {
        let label = FieldLabel(field.title, original: field.original, detail: field.detail)
        switch field.kind {
        case .toggle:
            Toggle(isOn: model.bool(field)) { label }
        case let .choice(options):
            let available = model.options(for: field, options)
            Picker(selection: model.choice(field)) {
                ForEach(available, id: \.value) { Text($0.label).tag($0.value) }
            } label: {
                label
            }
            .disabled(available.count < 2)
        case let .number(range, unit):
            LabeledContent {
                HStack(spacing: 6) {
                    NumberField(value: model.numberText(field, range: range))
                    if let unit { Text(unit).foregroundStyle(.secondary) }
                }
            } label: {
                label
            }
        case let .slider(range):
            LabeledContent {
                HStack {
                    Slider(value: model.double(field, range: range),
                           in: Double(range.lowerBound) ... Double(range.upperBound), step: 1)
                        .frame(width: 200)
                    Text("\(model.int(field, range: range).wrappedValue)")
                        .monospacedDigit()
                        .frame(width: 32, alignment: .trailing)
                }
            } label: {
                label
            }
        case .text:
            TextField(text: model.text(field)) { label }
        case .info, .ipAddress:
            LabeledContent {
                Text(model.infoText(field)).textSelection(.enabled)
            } label: {
                label
            }
        }
    }
}

/// Campo numérico com texto próprio: dá para apagar tudo e digitar outro número; o valor só vai para a
/// configuração quando é um número, e ao sair do campo volta a mostrar o valor guardado.
private struct NumberField: View {
    let value: Binding<String>
    @StateObject private var box = TextBox()
    @FocusState private var focused: Bool

    var body: some View {
        TextField("", text: $box.text)
            .multilineTextAlignment(.trailing)
            .frame(width: 90)
            .focused($focused)
            .onAppear { if box.text != value.wrappedValue { box.text = value.wrappedValue } }
            .onChange(of: box.text) {
                // Só grava o que a pessoa digita; mudanças vindas da própria configuração não voltam para ela.
                guard focused, box.text != value.wrappedValue, Int(box.text.filter(\.isNumber)) != nil else { return }
                value.wrappedValue = box.text
            }
            .onChange(of: value.wrappedValue) { if !focused, box.text != value.wrappedValue { box.text = value.wrappedValue } }
            .onChange(of: focused) { if !focused { box.text = value.wrappedValue } }
            .onSubmit { box.text = value.wrappedValue }
    }
}

private final class TextBox: ObservableObject {
    @Published var text = ""
}
