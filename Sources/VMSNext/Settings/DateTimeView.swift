import SwiftUI

/// "Sistema e horário" (Config. do sistema no VMS antigo): relógio do equipamento (OPTimeQuery 1452 /
/// OPTimeSetting 1450), sincronização automática (NetWork.NetNTP), formato da data, idioma e padrão de vídeo
/// (General.Location), saída automática (General.General) e nome do equipamento (NetWork.NetCommon.HostName,
/// o "Device Name" do VMS antigo; o MachineName de General.General fica "LocalHost" e não é usado).
@MainActor
final class DateTimeModel: ObservableObject {
    static let dateFormats: [(value: String, label: String)] = [
        ("DDMMYY", "Dia/Mês/Ano"), ("MMDDYY", "Mês/Dia/Ano"), ("YYMMDD", "Ano/Mês/Dia"),
    ]
    static let separators: [(value: String, label: String)] = [("/", "/  (barra)"), ("-", "-  (traço)"), (".", ".  (ponto)")]
    static let timeFormats: [(value: String, label: String)] = [("24", "24 horas"), ("12", "12 horas (AM/PM)")]
    static let languages: [(value: String, label: String)] = [
        ("Brazilian", "Português (Brasil)"), ("Portugal", "Português (Portugal)"), ("English", "Inglês"),
        ("Spanish", "Espanhol"), ("SimpChinese", "Chinês simplificado"),
    ]
    /// Nomes dos idiomas que a câmera informa em MultiLanguage.
    static let languageNames = [
        "Brazilian": "Português (Brasil)", "Portugal": "Português (Portugal)", "English": "Inglês",
        "Spanish": "Espanhol", "SimpChinese": "Chinês simplificado", "TradChinese": "Chinês tradicional",
        "Russian": "Russo", "Japanese": "Japonês", "Turkey": "Turco", "Turkish": "Turco", "French": "Francês",
        "German": "Alemão", "Italian": "Italiano", "Korean": "Coreano", "Arabic": "Árabe", "Polish": "Polonês",
        "Vietnamese": "Vietnamita", "Thai": "Tailandês", "Hebrew": "Hebraico", "Czech": "Tcheco",
    ]
    static let videoFormats: [(value: String, label: String)] = [("NTSC", "NTSC (Brasil, Américas)"), ("PAL", "PAL (Europa, Ásia)")]
    /// Códigos de fuso do equipamento confirmados (o VMS antigo mostra 14 como UTC−03:00).
    static let knownTimeZones = [14: "UTC−03:00 · Brasília"]

    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var error: String?
    @Published private(set) var notice: String?
    @Published var diagnosticText: String?

    /// Diferença (equipamento − Mac) em segundos, medida ao ler; o relógio na tela anda junto com o do Mac.
    @Published private(set) var offset: TimeInterval?

    @Published private(set) var hasNTP = false
    @Published var ntpEnabled = false
    @Published var ntpServer = ""
    @Published var ntpPeriod = 60

    @Published private(set) var hasLocation = false
    @Published var dateFormat = "DDMMYY"
    @Published var separator = "/"
    @Published var timeFormat = "24"
    @Published private(set) var hasDST = false
    @Published var dstOn = false
    @Published private(set) var timeZoneCode: Int?
    @Published var language: String?
    @Published var videoFormat: String?
    /// Idiomas que a câmera aceita (capacidade MultiLanguage), como na lista do VMS antigo.
    @Published private(set) var supportedLanguages: [String]?
    /// "Hd cheio" do VMS antigo (General.General.OverWrite): true = sobrescrever, false = parar.
    @Published var overwrite: Bool?

    @Published private(set) var hasGeneral = false
    @Published var hostName: String?
    @Published var autoLogout: Int?

    let camera: Camera
    private var ntpRaw: Any?
    private var locationRaw: Any?
    private var generalRaw: Any?
    private var commonRaw: Any?

    init(camera: Camera) {
        self.camera = camera
    }

    func deviceTime(at now: Date) -> Date? {
        offset.map { now.addingTimeInterval($0) }
    }

    func load() async {
        loading = true
        error = nil
        notice = nil
        defer { loading = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            await readClock(client)
            ntpRaw = try? await client.getConfig("NetWork.NetNTP")
            if let ntp = ConfigValue.object(in: ntpRaw) {
                hasNTP = true
                ntpEnabled = (ntp["Enable"] as? Bool) ?? (ConfigValue.int(ntp["Enable"]) == 1)
                ntpServer = (ntp["Server"] as? [String: Any])?["Name"] as? String ?? ""
                ntpPeriod = ConfigValue.int(ntp["UpdatePeriod"]) ?? 60
                timeZoneCode = ConfigValue.int(ntp["TimeZone"])
            }
            locationRaw = try? await client.getConfig("General.Location")
            if let location = ConfigValue.object(in: locationRaw) {
                hasLocation = true
                dateFormat = location["DateFormat"] as? String ?? dateFormat
                separator = location["DateSeparator"] as? String ?? separator
                timeFormat = location["TimeFormat"] as? String ?? timeFormat
                if let rule = location["DSTRule"] as? String {
                    hasDST = true
                    dstOn = rule.lowercased() != "off"
                }
                language = location["Language"] as? String
                videoFormat = location["VideoFormat"] as? String
            }
            supportedLanguages = (try? await client.command(code: 1360, name: "MultiLanguage", payload: nil))?["MultiLanguage"] as? [String]
            generalRaw = try? await client.getConfig("General.General")
            if let general = ConfigValue.object(in: generalRaw) {
                hasGeneral = true
                autoLogout = ConfigValue.int(general["AutoLogout"])
                overwrite = (general["OverWrite"] as? String).map { $0 == "OverWrite" }
            }
            commonRaw = try? await client.getConfig("NetWork.NetCommon")
            if let common = ConfigValue.object(in: commonRaw), let name = common["HostName"] as? String {
                hasGeneral = true
                hostName = name
            }
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Acerta o relógio do equipamento com o horário local do Mac.
    func syncWithMac() async {
        saving = true
        error = nil
        notice = nil
        defer { saving = false }
        do {
            let client = try await DeviceSessions.shared.client(for: camera)
            try await client.command(code: 1450, name: "OPTimeSetting", payload: DeviceTime.string(Date()))
            await readClock(client)
            notice = "Relógio acertado com o horário do Mac."
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
            if let raw = ntpRaw, var ntp = ConfigValue.object(in: raw) {
                ntp["Enable"] = ntpEnabled
                if var server = ntp["Server"] as? [String: Any] {
                    server["Name"] = ntpServer.trimmingCharacters(in: .whitespaces)
                    ntp["Server"] = server
                }
                ConfigValue.set(&ntp, "UpdatePeriod", ntpPeriod)
                let updated = ConfigValue.replacingObject(in: raw, with: ntp)
                try await client.setConfig("NetWork.NetNTP", updated)
                ntpRaw = updated
            }
            if let raw = locationRaw, var location = ConfigValue.object(in: raw) {
                location["DateFormat"] = dateFormat
                location["DateSeparator"] = separator
                location["TimeFormat"] = timeFormat
                if hasDST, let current = location["DSTRule"] as? String, (current.lowercased() != "off") != dstOn {
                    location["DSTRule"] = dstOn ? "On" : "Off"
                }
                if let language { location["Language"] = language }
                if let videoFormat { location["VideoFormat"] = videoFormat }
                let updated = ConfigValue.replacingObject(in: raw, with: location)
                try await client.setConfig("General.Location", updated)
                locationRaw = updated
            }
            if let raw = commonRaw, var common = ConfigValue.object(in: raw), let hostName,
               (common["HostName"] as? String) != hostName.trimmingCharacters(in: .whitespaces) {
                common["HostName"] = hostName.trimmingCharacters(in: .whitespaces)
                let updated = ConfigValue.replacingObject(in: raw, with: common)
                try await client.setConfig("NetWork.NetCommon", updated)
                commonRaw = updated
            }
            if let raw = generalRaw, var general = ConfigValue.object(in: raw) {
                if let autoLogout { ConfigValue.set(&general, "AutoLogout", autoLogout) }
                if let overwrite, general["OverWrite"] is String { general["OverWrite"] = overwrite ? "OverWrite" : "StopRecord" }
                let updated = ConfigValue.replacingObject(in: raw, with: general)
                try await client.setConfig("General.General", updated)
                generalRaw = updated
            }
            notice = "Configuração aplicada."
        } catch {
            self.error = error.localizedDescription
        }
    }

    func diagnostic() async -> String {
        await ConfigDiagnostics.dump(camera: camera, requests: [
            (1452, "OPTimeQuery"), (1042, "NetWork.NetNTP"), (1042, "General.Location"), (1042, "General.General"),
            (1042, "NetWork.NetCommon"), (1360, "MultiLanguage"),
        ])
    }

    private func readClock(_ client: DVRIPClient) async {
        let asked = Date()
        guard let response = try? await client.command(code: 1452, name: "OPTimeQuery", payload: nil),
              let text = response["OPTimeQuery"] as? String,
              let device = DeviceTime.date(text) else {
            offset = nil
            return
        }
        // Compensa metade do tempo de ida e volta da consulta.
        let roundTrip = Date().timeIntervalSince(asked)
        offset = device.timeIntervalSince(asked.addingTimeInterval(roundTrip / 2))
    }
}

struct DateTimeView: View {
    @StateObject private var model: DateTimeModel
    @StateObject private var ticker = Ticker()

    final class Ticker: ObservableObject {
        @Published var now = Date()
        private var timer: Timer?

        init() {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.now = Date() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        deinit { timer?.invalidate() }
    }

    init(camera: Camera) {
        _model = StateObject(wrappedValue: DateTimeModel(camera: camera))
    }

    var body: some View {
        VStack(spacing: 0) {
            if model.loading {
                ProgressView("Lendo do equipamento…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Form {
                    if model.hasGeneral { deviceSection }
                    clockSection
                    if model.hasNTP { ntpSection }
                    if model.hasLocation { formatSection }
                    if let error = model.error {
                        Section {
                            Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                }
                .formStyle(.grouped)
            }

            Divider()
            HStack {
                if let notice = model.notice {
                    Label(notice, systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Spacer()
                Button("Diagnóstico…") { Task { model.diagnosticText = await model.diagnostic() } }
                    .disabled(model.loading || model.saving)
                Button("Recarregar") { Task { await model.load() } }
                    .disabled(model.loading || model.saving)
                Button("Aplicar") { Task { await model.apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.loading || model.saving || (!model.hasNTP && !model.hasLocation && !model.hasGeneral))
            }
            .padding(12)
        }
        .task { await model.load() }
        .sheet(isPresented: Binding(get: { model.diagnosticText != nil }, set: { if !$0 { model.diagnosticText = nil } })) {
            DiagnosticSheet(text: model.diagnosticText ?? "")
        }
    }

    private var clockSection: some View {
        Section("Relógio") {
            LabeledContent {
                Text(model.deviceTime(at: ticker.now)?.formatted(date: .abbreviated, time: .standard) ?? "—")
                    .monospacedDigit()
            } label: {
                FieldLabel("Horário do equipamento", detail: "É o horário gravado nas gravações e nos alertas.")
            }
            LabeledContent("Horário do Mac") {
                Text(ticker.now.formatted(date: .abbreviated, time: .standard)).monospacedDigit()
            }
            if let offset = model.offset {
                LabeledContent("Diferença") {
                    Text(Self.describe(offset))
                        .foregroundStyle(abs(offset) > 60 ? .orange : .green)
                }
            }
            Button {
                Task { await model.syncWithMac() }
            } label: {
                Label("Acertar com o horário do Mac", systemImage: "clock.arrow.2.circlepath")
            }
            .disabled(model.saving)
        }
    }

    @ViewBuilder
    private var deviceSection: some View {
        Section("Equipamento") {
            if model.hostName != nil {
                TextField(text: Binding(get: { model.hostName ?? "" }, set: { model.hostName = $0 })) {
                    FieldLabel("Nome do equipamento", original: "Device Name",
                               detail: "Nome que o equipamento mostra no monitor, no iCSee e nas buscas da rede.")
                }
            }
            if let logout = model.autoLogout {
                Stepper(value: Binding(get: { logout }, set: { model.autoLogout = $0 }), in: 0 ... 60) {
                    FieldLabel(logout == 0 ? "Saída automática: nunca" : "Saída automática: \(logout) min", original: "Auto logoff",
                               detail: "Tempo sem uso até o menu do monitor ligado ao equipamento pedir a senha de novo. 0 = nunca.")
                }
            }
        }
    }

    private var ntpSection: some View {
        Section {
            Toggle(isOn: $model.ntpEnabled) {
                FieldLabel("Acertar automaticamente pela internet", original: "NTP",
                           detail: "O equipamento consulta um servidor de horário e corrige o relógio sozinho.")
            }
            TextField(text: $model.ntpServer) {
                FieldLabel("Servidor de horário", detail: "Para o Brasil, a.ntp.br ou pool.ntp.org funcionam bem.")
            }
            .disabled(!model.ntpEnabled)
            Stepper(value: $model.ntpPeriod, in: 1 ... 1440) {
                FieldLabel("Conferir a cada \(model.ntpPeriod) min", original: "UpdatePeriod")
            }
            .disabled(!model.ntpEnabled)
            if let code = model.timeZoneCode {
                LabeledContent {
                    Text(DateTimeModel.knownTimeZones[code] ?? "Código \(code) do equipamento")
                } label: {
                    FieldLabel("Fuso horário", original: "Fuso horário",
                               detail: "Usado pela sincronização automática. Para trocar, use o VMS antigo ou o menu do equipamento.")
                }
            }
        } header: {
            Text("Sincronização automática")
        }
    }

    private var formatSection: some View {
        Section("Formato e idioma") {
            Picker(selection: $model.dateFormat) {
                ForEach(DateTimeModel.dateFormats, id: \.value) { Text($0.label).tag($0.value) }
                if !DateTimeModel.dateFormats.contains(where: { $0.value == model.dateFormat }) {
                    Text(model.dateFormat).tag(model.dateFormat)
                }
            } label: {
                FieldLabel("Ordem da data", original: "Formato de data", detail: "Como a data aparece sobre o vídeo e nas telas do equipamento.")
            }
            Picker(selection: $model.separator) {
                ForEach(DateTimeModel.separators, id: \.value) { Text($0.label).tag($0.value) }
                if !DateTimeModel.separators.contains(where: { $0.value == model.separator }) {
                    Text(model.separator).tag(model.separator)
                }
            } label: {
                FieldLabel("Separador da data", original: "Separador")
            }
            Picker(selection: $model.timeFormat) {
                ForEach(DateTimeModel.timeFormats, id: \.value) { Text($0.label).tag($0.value) }
                if !DateTimeModel.timeFormats.contains(where: { $0.value == model.timeFormat }) {
                    Text(model.timeFormat).tag(model.timeFormat)
                }
            } label: {
                FieldLabel("Formato da hora", original: "Formato de hora")
            }
            if model.hasDST {
                Toggle(isOn: $model.dstOn) {
                    FieldLabel("Horário de verão", original: "DST",
                               detail: "O Brasil não usa horário de verão desde 2019; deixe desligado.")
                }
            }
            if let language = model.language {
                // Só os idiomas que a câmera tem (MultiLanguage), como no VMS antigo; o atual sempre aparece.
                let codes = model.supportedLanguages.map { $0.contains(language) ? $0 : $0 + [language] }
                    ?? DateTimeModel.languages.map(\.value) + (DateTimeModel.languages.contains { $0.value == language } ? [] : [language])
                Picker(selection: Binding(get: { language }, set: { model.language = $0 })) {
                    ForEach(codes, id: \.self) { Text(DateTimeModel.languageNames[$0] ?? $0).tag($0) }
                } label: {
                    FieldLabel("Idioma do equipamento", original: "Idioma",
                               detail: "Idioma do menu no monitor ligado ao equipamento. Não muda o VMS Next.")
                }
            }
            if let overwrite = model.overwrite {
                Picker(selection: Binding(get: { overwrite }, set: { model.overwrite = $0 })) {
                    Text("Sobrescrever (apaga as gravações mais antigas)").tag(true)
                    Text("Parar de gravar").tag(false)
                } label: {
                    FieldLabel("Disco cheio", original: "Hd cheio",
                               detail: "O que fazer quando o cartão ou o HD enche. Também aparece em Disco.")
                }
            }
            if let video = model.videoFormat {
                Picker(selection: Binding(get: { video }, set: { model.videoFormat = $0 })) {
                    ForEach(DateTimeModel.videoFormats, id: \.value) { Text($0.label).tag($0.value) }
                    if !DateTimeModel.videoFormats.contains(where: { $0.value == video }) {
                        Text(video).tag(video)
                    }
                } label: {
                    FieldLabel("Padrão de vídeo", original: "Padrão de vídeo",
                               detail: "Define a taxa de quadros base (NTSC 30 qps, PAL 25 qps). No Brasil use NTSC.")
                }
            }
        }
    }

    private static func describe(_ offset: TimeInterval) -> String {
        let seconds = Int(offset.rounded())
        if abs(seconds) <= 2 { return "Em dia" }
        let ahead = seconds > 0 ? "adiantado" : "atrasado"
        let value = abs(seconds)
        if value < 120 { return "\(value) s \(ahead)" }
        if value < 7200 { return "\(value / 60) min \(ahead)" }
        return "\(value / 3600) h \((value % 3600) / 60) min \(ahead)"
    }
}
