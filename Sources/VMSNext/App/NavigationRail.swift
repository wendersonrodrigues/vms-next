import AppKit
import SwiftUI

/// Aparência do app: seguir o macOS, sempre claro ou sempre escuro.
@MainActor
final class AppearanceSettings: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }
        var label: String {
            switch self {
            case .system: return "Igual ao Mac"
            case .light: return "Claro"
            case .dark: return "Escuro"
            }
        }
    }

    static let shared = AppearanceSettings()

    @Published var mode: Mode {
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: "appearance.mode")
            apply()
        }
    }

    private init() {
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: "appearance.mode") ?? "") ?? .system
    }

    func apply() {
        switch mode {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }
}

/// Coluna de ícones grandes à esquerda: Ao vivo, Gravações, Eventos, Dispositivos e Preferências.
struct NavigationRail: View {
    @Binding var mode: ViewMode
    let unread: Int

    var body: some View {
        VStack(spacing: 6) {
            // Logo do app (maior que os ícones do menu).
            AppLogo(size: 66)
                .padding(.top, Space.xxs)
                .padding(.bottom, Space.s)
                .help("VMS Next")
            item(.home)
            item(.live)
            item(.recordings)
            item(.events, badge: unread)
            item(.devices)
            item(.settings)
            Spacer()
            item(.preferences)
            credits
        }
        .padding(.vertical, Space.m)
        .frame(width: 92)
        .frame(maxHeight: .infinity)
        // Coluna flutuante com cantos arredondados, como nos painéis de referência.
        .background(RoundedRectangle(cornerRadius: Radius.large).fill(Theme.cardFill))
        .overlay(RoundedRectangle(cornerRadius: Radius.large).stroke(Theme.stroke))
        .shadow(color: .black.opacity(0.35), radius: 12, y: 4)
        .padding(Space.s)
        .background(Theme.background)
    }

    static let githubURL = URL(string: "https://github.com/wendersonrodrigues/vms-next")!

    private var version: String { AppInfo.version }

    /// Créditos: nome do app, versão, autor e link para o GitHub.
    private var credits: some View {
        VStack(spacing: 3) {
            Divider().padding(.horizontal, Space.m)
            Text("VMS Next").font(.system(size: 10, weight: .semibold))
            Text("versão \(version)").font(.system(size: 9)).monospacedDigit()
                // Beta em laranja: versão de testes, ainda com erros conhecidos.
                .foregroundStyle(AppInfo.isBeta ? Theme.warning : Color.primary)
            Text("criado por\nWenderson Rodrigues")
                .font(.system(size: 8))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Link(destination: Self.githubURL) {
                Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 9, weight: .medium))
            }
            .help("Abrir o projeto no GitHub")
        }
        .foregroundStyle(.secondary)
        .padding(.top, Space.xs)
        .frame(width: 80)
    }

    private func item(_ target: ViewMode, badge: Int = 0) -> some View {
        let selected = mode == target
        let title = target.title
        return Button {
            mode = target
        } label: {
            VStack(spacing: 4) {
                ModeIcon(mode: target, size: 40)
                    .opacity(selected ? 1 : 0.7)
                    .scaleEffect(selected ? 1.06 : 1)
                    .frame(height: 42)
                    .overlay(alignment: .topTrailing) {
                        if badge > 0 {
                            Text(badge > 99 ? "99+" : "\(badge)")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, Space.xs)
                                .padding(.vertical, Space.xxs)
                                .background(Capsule().fill(Color.red))
                                .offset(x: 12, y: -6)
                        }
                    }
                Text(title)
                    .font(.system(size: 10, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(width: 76, height: 66)
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .background(
                RoundedRectangle(cornerRadius: Radius.card)
                    .fill(selected ? Theme.accent.opacity(0.16) : .clear)
                    .overlay(RoundedRectangle(cornerRadius: Radius.card).stroke(selected ? Theme.accent.opacity(0.45) : .clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.hover)
        .help(title)
    }
}

/// Preferências do app: aparência e funcionamento em segundo plano.
struct PreferencesView: View {
    @ObservedObject private var appearance = AppearanceSettings.shared
    @ObservedObject private var background = BackgroundSettings.shared
    @ObservedObject private var alarms = AlarmCenter.shared
    @ObservedObject private var prefs = AppPreferences.shared
    @ObservedObject private var vault = Vault.shared
    @ObservedObject private var recorder = LocalRecorder.shared
    @EnvironmentObject private var store: CameraStore

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AppLogo(size: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Preferências do app").font(.title2.weight(.bold))
                        Text("Valem para o VMS Next neste Mac. As configurações de cada câmera ficam em Configurações.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, Space.xs)
            }
            Section("Aparência") {
                Picker(selection: $appearance.mode) {
                    ForEach(AppearanceSettings.Mode.allCases) { Text($0.label).tag($0) }
                } label: {
                    FieldLabel("Tema", detail: "Escuro deixa o mosaico mais confortável à noite. \"Igual ao Mac\" segue os Ajustes do Sistema.")
                }
                .pickerStyle(.segmented)
            }
            Section("Arquivos") {
                folderRow("Pasta das fotos", original: "Caminho de foto",
                          detail: "Fotos do quadro (ao vivo e gravações) e a captura automática.",
                          url: prefs.photoFolder) { prefs.photoFolder = $0 }
                folderRow("Pasta dos downloads", original: "Baixar caminho",
                          detail: "Gravações baixadas em MP4.", url: prefs.downloadFolder) { prefs.downloadFolder = $0 }
                Toggle(isOn: $prefs.askWhereToSave) {
                    FieldLabel("Perguntar onde salvar cada arquivo",
                               detail: "Desligado, as fotos e os downloads vão direto para as pastas acima.")
                }
            }
            Section {
                folderRow("Pasta das gravações no Mac", original: "Caminho de gravação",
                          detail: "Uma subpasta por câmera, com arquivos MP4.", url: prefs.recordingFolder) { prefs.recordingFolder = $0 }
                LabeledContent {
                    HStack {
                        TextField("", value: $prefs.recordReserveMB, format: .number.grouping(.never))
                            .frame(width: 90)
                            .multilineTextAlignment(.trailing)
                        Text("MB").foregroundStyle(.secondary)
                    }
                } label: {
                    FieldLabel("Espaço que fica sempre livre no Mac", original: "Reserva de espaço em disco",
                               detail: "Mínimo 5000 MB. Quando chegar nele, a gravação para ou apaga as mais antigas.")
                }
                Stepper(value: $prefs.recordFileMinutes, in: 5 ... 120, step: 5) {
                    FieldLabel("Tamanho de cada arquivo: \(prefs.recordFileMinutes) minutos", original: "Tamanho do arquivo")
                }
                Picker(selection: $prefs.recordOverwrite) {
                    Text("Parar a gravação").tag(false)
                    Text("Apagar as mais antigas (cíclica)").tag(true)
                } label: {
                    FieldLabel("Quando o espaço acabar", original: "Espaço de armazenamento está cheio")
                }
                Toggle(isOn: $prefs.autoRecord) {
                    FieldLabel("Gravar automaticamente", original: "Habilitar grav",
                               detail: "Com o VMS Next aberto, grava no Mac dentro do horário abaixo. O botão Gravar da câmera grava na hora, a qualquer momento.")
                }
                if prefs.autoRecord {
                    HStack {
                        DatePicker("Das", selection: minutes($prefs.autoRecordFrom), displayedComponents: .hourAndMinute)
                        DatePicker("às", selection: minutes($prefs.autoRecordTo), displayedComponents: .hourAndMinute)
                    }
                    Toggle("Todas as câmeras", isOn: $prefs.autoRecordAll)
                    if !prefs.autoRecordAll {
                        ForEach(store.cameras) { camera in
                            Toggle(camera.displayName, isOn: Binding(
                                get: { prefs.autoRecordCameras.contains(camera.id) },
                                set: { on in if on { prefs.autoRecordCameras.insert(camera.id) } else { prefs.autoRecordCameras.remove(camera.id) } }
                            ))
                        }
                    }
                }
                if let error = recorder.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                }
            } header: {
                Text("Gravação no Mac (Config. de gravação)")
            }
            Section("Ao abrir o app") {
                Toggle(isOn: $prefs.restoreState) {
                    FieldLabel("Voltar para onde parei", original: "Retomar ao estado anterior",
                               detail: "Guarda a câmera e o modelo de tela escolhidos. O app sempre abre no Início.")
                }
                Toggle(isOn: Binding(get: { vault.hasRememberedLogin }, set: { try? vault.setRemember($0); vault.objectWillChange.send() })) {
                    FieldLabel("Lembrar login e senha", original: "Lembrar login e senha",
                               detail: "Entra direto, sem pedir a senha do VMS Next. Desligado, pede a senha toda vez.")
                }
                Toggle(isOn: $prefs.syncDeviceClock) {
                    FieldLabel("Acertar o relógio das câmeras com o do Mac", original: "Sincronizar automaticamente com o horário do sistema",
                               detail: "Ao abrir o app, ajusta a data e a hora de cada câmera e NVR. Deixe desligado se elas já usam a internet (NTP).")
                }
                Picker(selection: $prefs.singleQualityHD) {
                    Text("HD (vídeo principal)").tag(true)
                    Text("SD (vídeo extra)").tag(false)
                } label: {
                    FieldLabel("Qualidade ao abrir uma câmera", original: "Auto comutação entre stream secundário e principal",
                               detail: "O mosaico usa sempre o vídeo extra, mais leve; a câmera em tela cheia começa nesta qualidade.")
                }
            }
            Section("Captura automática") {
                Toggle(isOn: $prefs.autoSnapshot) {
                    FieldLabel("Tirar fotos automaticamente", original: "Captura automática",
                               detail: "Salva uma foto de cada câmera que está na tela, na pasta das fotos → Captura automática.")
                }
                Picker(selection: $prefs.autoSnapshotSeconds) {
                    ForEach([30, 60, 300, 600, 1800, 3600], id: \.self) { seconds in
                        Text(seconds < 60 ? "\(seconds) segundos" : seconds < 3600 ? "\(seconds / 60) minuto(s)" : "1 hora").tag(seconds)
                    }
                } label: {
                    FieldLabel("A cada")
                }
                .disabled(!prefs.autoSnapshot)
            }
            Section("Alertas") {
                Picker(selection: $prefs.maxEvents) {
                    ForEach([100, 500, 1000, 5000, 30000], id: \.self) { Text("\($0)").tag($0) }
                } label: {
                    FieldLabel("Quantos alertas guardar na lista", original: "Informação de número de alarme",
                               detail: "Os mais antigos saem da lista de Eventos quando passar deste número. A lista fica guardada no Mac.")
                }
                Picker(selection: $prefs.logDays) {
                    ForEach([7, 30, 90, 365], id: \.self) { Text("\($0) dias").tag($0) }
                } label: {
                    FieldLabel("Guardar o registro do app por", original: "Tempo de log salvo",
                               detail: "Entradas, configurações alteradas, reinícios, fotos e downloads (Eventos → Registro).")
                }
            }
            Section("Segundo plano") {
                Toggle(isOn: $alarms.enabled) {
                    FieldLabel("Receber alertas das câmeras", detail: "Notificações do macOS quando uma câmera detecta algo.")
                }
                Toggle(isOn: Binding(get: { background.launchAtLogin }, set: { background.setLaunchAtLogin($0) })) {
                    FieldLabel("Abrir junto com o Mac", detail: "O app fica na barra de menus recebendo alertas.")
                }
                Toggle(isOn: $background.hideDockWhenClosed) {
                    FieldLabel("Esconder do Dock com a janela fechada", detail: "Continua acessível pelo ícone na barra de menus.")
                }
                if let error = background.loginError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Preferências")
    }

    /// Minutos desde a meia-noite como Date (para o seletor de hora).
    private func minutes(_ value: Binding<Int>) -> Binding<Date> {
        Binding(
            get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(TimeInterval(value.wrappedValue * 60)) },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                value.wrappedValue = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
            })
    }

    private func folderRow(_ title: String, original: String, detail: String, url: URL, set: @escaping (URL) -> Void) -> some View {
        LabeledContent {
            HStack {
                Text(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.secondary)
                Button("Escolher…") { if let new = prefs.chooseFolder(current: url) { set(new) } }
                Button {
                    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(url)
                } label: {
                    Image(systemName: "folder")
                }
                .help("Abrir a pasta no Finder")
            }
        } label: {
            FieldLabel(title, original: original, detail: detail)
        }
    }
}

/// Ícone de uma tela: o ícone gerado (Resources/Icons/<tela>.png) ou, sem ele, o símbolo do sistema.
/// "Config. câmeras" usa câmera com engrenagem, para não confundir com as Preferências do app.
struct ModeIcon: View {
    let mode: ViewMode
    var size: CGFloat = 24

    private static let images: [String: NSImage] = {
        var result: [String: NSImage] = [:]
        guard let folder = Bundle.main.resourceURL?.appendingPathComponent("Icons") else { return result }
        for name in ["home", "live", "recordings", "events", "devices", "settings", "preferences"] {
            if let image = NSImage(contentsOf: folder.appendingPathComponent("\(name).png")) { result[name] = image }
        }
        return result
    }()

    var body: some View {
        if let image = Self.images[mode.rawValue] {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else if mode == .settings {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: "video.fill").font(.system(size: size * 0.75))
                Image(systemName: "gearshape.fill")
                    .font(.system(size: size * 0.45))
                    .background(Circle().fill(Color(nsColor: .windowBackgroundColor)).padding(-1))
                    .offset(x: size * 0.12, y: size * 0.12)
            }
            .frame(width: size, height: size)
        } else {
            Image(systemName: mode.symbol).font(.system(size: size * 0.8)).frame(width: size, height: size)
        }
    }
}
