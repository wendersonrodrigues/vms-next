import SwiftUI

/// "Sistema e horário" (Config. do sistema no VMS antigo): relógio do equipamento (OPTimeQuery 1452 /
/// OPTimeSetting 1450), sincronização automática (NetWork.NetNTP), formato da data, idioma e padrão de vídeo
/// (General.Location), saída automática (General.General), fuso horário (System.TimeZone) e nome do equipamento
/// (NetWork.NetCommon.HostName, o "Device Name" do VMS antigo; o MachineName de General.General fica "LocalHost").
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
    /// Lista de fusos do VMS antigo (tela Config. do sistema), na mesma ordem, em minutos a leste de UTC.
    /// O equipamento guarda em System.TimeZone.timeMin os minutos a OESTE (UTC−03:00 = 180), visto no
    /// CSystemConfig do VMS antigo e no exchangeTable<TimeZone> do libnetsdk.
    static let timeZones: [Int] = [
        -720, -660, -600, -540, -480, -420, -360, -300, -240, -210, -180, -120, -60,
        0, 60, 120, 180, 210, 240, 270, 300, 330, 345, 360, 390, 420, 480, 540, 570, 600, 660, 720, 780,
    ]
    static func timeZoneLabel(_ minutes: Int) -> String {
        let sign = minutes < 0 ? "−" : "+"
        let text = String(format: "UTC%@%02d:%02d", sign, abs(minutes) / 60, abs(minutes) % 60)
        return minutes == -180 ? text + " · Brasília" : text
    }
    /// NetWork.NetNTP.TimeZone não é fuso: o VMS antigo usa 13 = servidor escolhido ("Custom") e
    /// 14 = "Auto Select Server" (CNetNTPConfig::onUpdateConfig / on_radioButton_clicked).
    static let ntpCustomServer = 13
    static let ntpAutoServer = 14

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
    /// Modo do servidor NTP (13 ou 14, ver ntpCustomServer); nil se a câmera usar outro valor.
    @Published var ntpServerMode: Int?
    /// Fuso em minutos a leste de UTC (System.TimeZone); nil se a câmera não tiver essa configuração.
    @Published var timeZoneMinutes: Int?
    @Published var confirmingTimeZone = false
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
    private var timeZoneRaw: Any?
    private var loadedTimeZone: Int?
    var timeZoneChanged: Bool { timeZoneMinutes != nil && timeZoneMinutes != loadedTimeZone }

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
                ntpServerMode = ConfigValue.int(ntp["TimeZone"]).flatMap {
                    [Self.ntpCustomServer, Self.ntpAutoServer].contains($0) ? $0 : nil
                }
            }
            timeZoneRaw = try? await client.getConfig("System.TimeZone")
            timeZoneMinutes = ConfigValue.object(in: timeZoneRaw).flatMap { ConfigValue.int($0["timeMin"]) }.map { -$0 }
            loadedTimeZone = timeZoneMinutes
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

    /// Trocar o fuso muda o horário local do equipamento (e o das gravações novas): pede confirmação antes.
    func apply(confirmed: Bool = false) async {
        if timeZoneChanged && !confirmed {
            confirmingTimeZone = true
            return
        }
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
                if let ntpServerMode { ConfigValue.set(&ntp, "TimeZone", ntpServerMode) }
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
            if timeZoneChanged, let raw = timeZoneRaw, var zone = ConfigValue.object(in: raw), let minutes = timeZoneMinutes {
                ConfigValue.set(&zone, "timeMin", -minutes)
                let updated = ConfigValue.replacingObject(in: raw, with: zone)
                try await client.setConfig("System.TimeZone", updated)
                timeZoneRaw = updated
                loadedTimeZone = minutes
                await readClock(client)
            }
            notice = "Configuração aplicada."
        } catch {
            self.error = error.localizedDescription
        }
    }

    func diagnostic() async -> String {
        await ConfigDiagnostics.dump(camera: camera, requests: [
            (1452, "OPTimeQuery"), (1042, "NetWork.NetNTP"), (1042, "General.Location"), (1042, "General.General"),
            (1042, "NetWork.NetCommon"), (1042, "System.TimeZone"), (1360, "MultiLanguage"),
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
                    .disabled(model.loading || model.saving || (!model.hasNTP && !model.hasLocation && !model.hasGeneral && model.timeZoneMinutes == nil))
            }
            .padding(12)
        }
        .task { await model.load() }
        .confirmationDialog("Trocar o fuso horário para \(DateTimeModel.timeZoneLabel(model.timeZoneMinutes ?? 0))?",
                            isPresented: $model.confirmingTimeZone) {
            Button("Trocar o fuso") { Task { await model.apply(confirmed: true) } }
            Button("Cancelar", role: .cancel) {}
        } message: {
            Text("A hora mostrada e gravada pelo equipamento muda junto. Gravações já feitas ficam com o horário antigo.")
        }
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
            if let minutes = model.timeZoneMinutes {
                // Lista do VMS antigo; o valor atual sempre aparece, mesmo fora dela.
                let options = DateTimeModel.timeZones.contains(minutes) ? DateTimeModel.timeZones : DateTimeModel.timeZones + [minutes]
                Picker(selection: Binding(get: { minutes }, set: { model.timeZoneMinutes = $0 })) {
                    ForEach(options, id: \.self) { Text(DateTimeModel.timeZoneLabel($0)).tag($0) }
                } label: {
                    FieldLabel("Fuso horário", original: "Fuso horário",
                               detail: "Define a hora local do equipamento. No Brasil (Brasília) é UTC−03:00.")
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
            if let mode = model.ntpServerMode {
                Picker(selection: Binding(get: { mode }, set: { model.ntpServerMode = $0 })) {
                    Text("Escolher automaticamente").tag(DateTimeModel.ntpAutoServer)
                    Text("Usar o servidor abaixo").tag(DateTimeModel.ntpCustomServer)
                } label: {
                    FieldLabel("Servidor", original: "Auto Select Server / Custom",
                               detail: "No automático o equipamento usa os servidores de horário que já conhece.")
                }
                .pickerStyle(.radioGroup)
                .disabled(!model.ntpEnabled)
            }
            TextField(text: $model.ntpServer) {
                FieldLabel("Servidor de horário", detail: "Para o Brasil, a.ntp.br ou pool.ntp.org funcionam bem.")
            }
            .disabled(!model.ntpEnabled || model.ntpServerMode == DateTimeModel.ntpAutoServer)
            Stepper(value: $model.ntpPeriod, in: 1 ... 1440) {
                FieldLabel("Conferir a cada \(model.ntpPeriod) min", original: "UpdatePeriod")
            }
            .disabled(!model.ntpEnabled)
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
