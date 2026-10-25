import SwiftUI

/// Tela Início: apresenta o app e mostra, antes do mosaico, se as câmeras estão conectadas,
/// os alertas do dia, o espaço em disco e o clima.
struct HomeView: View {
    let onMode: (ViewMode) -> Void
    /// Abre o equipamento ao vivo (câmera ou NVR inteiro).
    let onOpenLive: (SidebarItem) -> Void
    /// Abre as configurações do equipamento (true = NVR inteiro).
    let onSettings: (Camera, Bool) -> Void

    @EnvironmentObject private var store: CameraStore
    @ObservedObject private var alarms = AlarmCenter.shared
    @StateObject private var model = HomeModel()
    @StateObject private var cityField = CityField()

    private var alertsToday: Int {
        alarms.events.filter { $0.isStart && Calendar.current.isDateInToday($0.date) }.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                banner
                // Cards da mesma linha ficam com a altura do mais alto.
                HStack(alignment: .top, spacing: 18) {
                    weatherCard
                    alertsCard
                    connectedCard
                }
                .fixedSize(horizontal: false, vertical: true)
                shortcutsSection
                HStack(alignment: .top, spacing: 18) {
                    camerasCard
                        .frame(width: 280)
                    storageCard
                }
                .fixedSize(horizontal: false, vertical: true)
                devicesSection
            }
            .padding(Space.xxl)
            .frame(maxWidth: 1300)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle("Início")
        .task {
            cityField.text = model.city
            async let weather: Void = model.loadWeather()
            await model.refresh(store: store)
            await weather
        }
    }

    // MARK: - Banner

    private var banner: some View {
        ZStack(alignment: .leading) {
            // Fundo: casa inteligente futurista à noite (gerado no Magnific), escurecido à esquerda para o texto.
            if let background = Self.bannerImage {
                Image(nsImage: background)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .clipped()
                LinearGradient(colors: [Color.black.opacity(0.75), Color.black.opacity(0.35), .clear],
                               startPoint: .leading, endPoint: .trailing)
            } else {
                LinearGradient(colors: [Theme.accent, Color.indigo.opacity(0.85)], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
            HStack(spacing: 20) {
                AppLogo(size: 136)
                    .shadow(radius: 8, y: 4)
                VStack(alignment: .leading, spacing: 8) {
                    Text("VMS Next")
                        .font(.system(size: 34, weight: .bold))
                    Text("Um app dedicado às suas câmeras e NVRs Xiongmai, nativo no Mac com Apple Silicon: ao vivo, gravações, alertas e todas as configurações num só lugar. Código aberto e feito por quem usa.")
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(maxWidth: 560, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        pill(String(localized: "Código aberto"), "chevron.left.forwardslash.chevron.right")
                        pill(String(localized: "Apple Silicon"), "cpu")
                        pill(String(localized: "Tudo na sua rede, sem nuvem"), "lock.shield")
                    }
                }
                .foregroundStyle(.white)
            }
            .padding(Space.xxl)
            VStack(alignment: .trailing, spacing: 4) {
                Text("Criado por Wenderson Rodrigues").font(.caption.weight(.semibold))
                Link(destination: NavigationRail.githubURL) {
                    Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right").font(.caption)
                }
                Text("versão \(AppInfo.version)")
                    .font(.caption2)
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        }
        .frame(height: 210)
        .clipShape(RoundedRectangle(cornerRadius: Radius.large))
    }

    private static let bannerImage: NSImage? = Bundle.main.resourceURL
        .flatMap { NSImage(contentsOf: $0.appendingPathComponent("Previews/banner.jpg")) }

    private func pill(_ text: String, _ icon: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.medium))
            .padding(.horizontal, Space.m)
            .padding(.vertical, Space.xs)
            .background(Capsule().fill(.white.opacity(0.18)))
    }

    // MARK: - Clima e alertas

    private var weatherCard: some View {
        card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    cardHeader("Temperatura", icon: "thermometer.medium")
                    Spacer()
                    Button {
                        cityField.text = model.city
                        cityField.editing.toggle()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.borderless)
                    .help("Escolher a cidade")
                    .accessibilityLabel("Escolher a cidade")
                }
                if let weather = model.weather {
                    let info = HomeModel.describe(weather)
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(Int(weather.temperature.rounded()))°C").font(.system(size: 40, weight: .semibold))
                            Text(info.text).foregroundStyle(.secondary)
                            Text(weather.city).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: info.icon)
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 44))
                    }
                } else if let error = model.weatherError {
                    Text(error).font(.callout).foregroundStyle(.secondary)
                }
                if cityField.editing || model.city.isEmpty {
                    HStack {
                        TextField("Sua cidade", text: $cityField.text)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(saveCity)
                        Button("OK", action: saveCity)
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    private func saveCity() {
        model.city = cityField.text
        cityField.editing = false
        Task { await model.loadWeather() }
    }

    private var alertsCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                cardHeader(String(localized: "Alertas de hoje"), icon: "bell.badge.fill")
                Text("\(alertsToday)").font(.system(size: 40, weight: .semibold))
                if let last = alarms.events.first {
                    Text("Último: \(last.kind == .other ? last.event : last.kind.label) · \(last.cameraName) · \(last.date.formatted(date: .omitted, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text("Nenhum alerta desde que o app abriu.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Ver eventos") { onMode(.events) }
                    .controlSize(.small)
            }
        }
    }

    // MARK: - Status

    private var connectedCard: some View {
        statCard(String(localized: "Equipamentos conectados"), icon: "wifi",
                 value: model.devices.isEmpty ? "—" : "\(model.onlineCount) de \(model.devices.count)",
                 detail: model.checking ? "Verificando…" : (model.onlineCount == model.devices.count ? String(localized: "Todos respondendo") : String(localized: "Alguns sem conexão")),
                 tint: model.onlineCount == model.devices.count ? Theme.success : Theme.warning)
    }

    /// Acompanha a altura do armazenamento: o número cresce para ocupar o card.
    private var camerasCard: some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                cardHeader(String(localized: "Câmeras"), icon: "video.fill", tint: .blue)
                Spacer(minLength: 0)
                Text("\(store.cameras.count)").font(.system(size: 72, weight: .semibold)).monospacedDigit()
                Text("\(store.standaloneCameras.count) avulsa(s) · \(store.groups.count) NVR(s)")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
    }

    /// Um item por disco: de onde é (HD do NVR ou cartão da câmera) e o que acontece quando enche,
    /// para um disco cheio não assustar quando a gravação é cíclica.
    private var storageCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                cardHeader(String(localized: "Armazenamento"), icon: "internaldrive.fill")
                let disks = model.devices.filter { $0.totalMB > 0 }
                if disks.isEmpty {
                    Text(model.checking ? "Verificando…" : String(localized: "Nenhum disco ou cartão encontrado."))
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(disks) { device in
                    let used = Double(device.totalMB - device.freeMB) / Double(device.totalMB)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Label(device.isRecorder ? String(localized: "\(device.name) · HD do NVR") : String(localized: "\(device.name) · cartão da câmera"),
                                  systemImage: device.isRecorder ? "server.rack" : "sdcard")
                                .font(.callout.weight(.medium))
                            Spacer()
                            Text("\(Self.size(device.totalMB - device.freeMB)) de \(Self.size(device.totalMB))")
                                .font(.callout).monospacedDigit()
                        }
                        ProgressView(value: used)
                            .tint(used > 0.97 && device.overwrite != true ? .red : Theme.accent)
                        Text(recordingMode(device, used: used))
                            .font(.caption)
                            .foregroundStyle(device.overwrite == false && used > 0.97 ? Color.red : .secondary)
                    }
                }
            }
        }
    }

    private func recordingMode(_ device: Device, used: Double) -> String {
        switch device.overwrite {
        case .some(true):
            return used > 0.97 ? String(localized: "Cheio, mas normal: gravação cíclica apaga as gravações mais antigas e continua gravando.")
                : String(localized: "Gravação cíclica: quando encher, apaga as gravações mais antigas.")
        case .some(false):
            return used > 0.97 ? String(localized: "Cheio e a gravação PAROU: o equipamento está configurado para parar quando enche.")
                : String(localized: "Para de gravar quando encher (não apaga as antigas).")
        case .none:
            return "\(Self.size(device.freeMB)) livres"
        }
    }

    private static func size(_ megabytes: Int) -> String {
        megabytes >= 1024 * 1024 ? String(format: "%.1f TB", Double(megabytes) / 1_048_576)
            : megabytes >= 1024 ? String(format: "%.0f GB", Double(megabytes) / 1024) : "\(megabytes) MB"
    }

    private func statCard(_ title: String, icon: String, value: String, detail: String, tint: Color) -> some View {
        card {
            VStack(alignment: .leading, spacing: 8) {
                cardHeader(title, icon: icon, tint: tint)
                Text(value).font(.system(size: 26, weight: .semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Equipamentos

    private var devicesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Conexão dos equipamentos").font(.title3.weight(.semibold))
                Spacer()
                Button {
                    Task { await model.refresh(store: store) }
                } label: {
                    Label("Verificar de novo", systemImage: "arrow.clockwise")
                }
                .disabled(model.checking)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 240), spacing: 14)], spacing: 14) {
                ForEach(model.devices) { device in
                    card {
                        HStack(spacing: 12) {
                            Image(systemName: device.isRecorder ? "server.rack" : "video.fill")
                                .font(.title3)
                                .frame(width: 40, height: 40)
                                .background(RoundedRectangle(cornerRadius: Radius.control).fill(Color.primary.opacity(0.07)))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(device.name).font(.headline).lineLimit(1)
                                Text(device.isRecorder ? "\(device.address) · \(device.channels) canais" : device.address)
                                    .font(.caption).foregroundStyle(.secondary)
                                HStack(spacing: 5) {
                                    Circle().fill(statusColor(device)).frame(width: 8, height: 8)
                                    Text(statusText(device)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                            VStack(spacing: 6) {
                                Button {
                                    onOpenLive(device.isRecorder ? .group(device.name) : .camera(device.camera.id))
                                } label: {
                                    Image(systemName: "video.fill").frame(width: 18)
                                }
                                .help("Ver ao vivo")
                                .accessibilityLabel("Ver ao vivo")
                                Button {
                                    onSettings(device.camera, device.isRecorder)
                                } label: {
                                    Image(systemName: "slider.horizontal.3").frame(width: 18)
                                }
                                .help("Configurações")
                                .accessibilityLabel("Configurações")
                            }
                            .controlSize(.small)
                        }
                    }
                    .help(device.error ?? "")
                }
            }
        }
    }

    private func statusColor(_ device: Device) -> Color {
        switch device.online {
        case .some(true): return .green
        case .some(false): return .red
        case .none: return .gray
        }
    }

    private func statusText(_ device: Device) -> String {
        switch device.online {
        case .some(true): return device.totalMB > 0 ? "Conectado · \(Self.size(device.freeMB)) livres" : "Conectado"
        case .some(false): return device.error ?? "Sem conexão"
        case .none: return "Verificando…"
        }
    }

    private typealias Device = HomeModel.Device

    // MARK: - Atalhos

    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                ForEach([ViewMode.live, .recordings, .events, .devices, .settings, .preferences], id: \.self) { mode in
                    shortcut(mode)
                }
            }
        }
    }

    private func shortcut(_ mode: ViewMode) -> some View {
        Button {
            onMode(mode)
        } label: {
            card {
                VStack(spacing: 10) {
                    ModeIcon(mode: mode, size: 72)
                    Text(mode.title).font(.callout.weight(.medium))
                }
                .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.hover)
    }

    // MARK: - Peças

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(Space.l)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .themedCard()
    }

    private func cardHeader(_ title: String, icon: String, tint: Color = Theme.accent) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(RoundedRectangle(cornerRadius: Radius.small).fill(tint.opacity(0.15)))
            Text(title).font(.headline)
        }
    }
}

final class CityField: ObservableObject {
    @Published var text = ""
    @Published var editing = false
}
