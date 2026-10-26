import SwiftUI

/// Uma gravação com tags. Guarda o dia, o horário e o tipo, para achar o vídeo de novo depois,
/// mesmo de outro dia (a busca no equipamento é por dia).
struct TaggedRecording: Codable, Hashable, Identifiable {
    var id: String { RecordingTags.key(cameraID, fileName) }
    let cameraID: Camera.ID
    let fileName: String
    let begin: Date
    let end: Date
    var tags: [String]

    var kind: Recording.Kind {
        Recording(fileName: fileName, begin: begin, end: end, sizeKB: 0, channel: 0).kind
    }
}

/// Tags das gravações, salvas em ~/Library/Application Support/VMSNext/recording-tags.json (só neste Mac).
@MainActor
final class RecordingTags: ObservableObject {
    static let shared = RecordingTags()

    @Published private(set) var items: [String: TaggedRecording] = [:]

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VMSNext", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("recording-tags.json")
    }()

    private init() {
        if let data = try? Data(contentsOf: fileURL),
           let saved = try? JSONDecoder().decode([TaggedRecording].self, from: data)
        {
            items = Dictionary(saved.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        }
    }

    nonisolated static func key(_ cameraID: Camera.ID, _ fileName: String) -> String {
        "\(cameraID.uuidString)|\(fileName)"
    }

    /// Todas as tags já usadas, em ordem alfabética, com quantos vídeos cada uma tem.
    var allTags: [(name: String, count: Int)] {
        var counts: [String: Int] = [:]
        for item in items.values { for tag in item.tags { counts[tag, default: 0] += 1 } }
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func tags(of recording: Recording, camera: Camera) -> [String] {
        items[Self.key(camera.id, recording.fileName)]?.tags ?? []
    }

    /// Nomes dos arquivos com tag desta câmera (para marcar na linha do tempo).
    func taggedFiles(camera: Camera) -> Set<String> {
        Set(items.values.filter { $0.cameraID == camera.id && !$0.tags.isEmpty }.map(\.fileName))
    }

    func add(_ tag: String, to recording: Recording, camera: Camera) {
        let name = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // Reaproveita a grafia de uma tag que já existe ("Entrega" e "entrega" são a mesma).
        let existing = allTags.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        let finalName = existing?.name ?? name
        let key = Self.key(camera.id, recording.fileName)
        var item = items[key] ?? TaggedRecording(cameraID: camera.id, fileName: recording.fileName,
                                                 begin: recording.begin, end: recording.end, tags: [])
        guard !item.tags.contains(finalName) else { return }
        item.tags.append(finalName)
        items[key] = item
        save()
    }

    func remove(_ tag: String, from recording: Recording, camera: Camera) {
        let key = Self.key(camera.id, recording.fileName)
        guard var item = items[key] else { return }
        item.tags.removeAll { $0 == tag }
        items[key] = item.tags.isEmpty ? nil : item
        save()
    }

    /// Vídeos com a tag, da câmera escolhida, do mais recente para o mais antigo.
    func recordings(with tag: String, camera: Camera) -> [TaggedRecording] {
        items.values.filter { $0.cameraID == camera.id && $0.tags.contains(tag) }.sorted { $0.begin > $1.begin }
    }

    private func save() {
        let data = try? JSONEncoder().encode(Array(items.values).sorted { $0.begin < $1.begin })
        try? data?.write(to: fileURL, options: .atomic)
    }
}

/// Texto digitado e tag escolhida na janelinha de tags (ObservableObject no lugar de @State, que precisa do Xcode).
final class TagPopoverState: ObservableObject {
    @Published var query = ""
    /// Tag clicada: mostra os vídeos com ela.
    @Published var filter: String?
}

/// Botão "Tags" do cabeçalho das Gravações, no mesmo formato dos ‹ tipo ›.
struct RecordingTagButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.xs) {
                Image(systemName: count > 0 ? "tag.fill" : "tag")
                Text(count > 0 ? String(localized: "Tags (\(count))") : String(localized: "Tags"))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, Space.s)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: Radius.small + 2).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Colocar tags no vídeo e ver os vídeos de uma tag")
    }
}

/// Janelinha de tags: as tags do vídeo que está tocando, um campo para adicionar ou buscar, e as tags que já
/// existem. Clicar numa tag lista os vídeos com ela (de qualquer dia), para abrir de novo.
struct RecordingTagsPopover: View {
    let camera: Camera
    /// Vídeo que está tocando ou escolhido (nil = nenhum).
    let current: Recording?
    let onOpen: (TaggedRecording) -> Void

    @ObservedObject private var tags = RecordingTags.shared
    @StateObject private var state = TagPopoverState()

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let filter = state.filter {
                taggedList(filter)
            } else {
                editor
            }
        }
        .padding(Space.l)
        .frame(width: 340)
    }

    // MARK: - Tags do vídeo e busca

    private var editor: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            if let current {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text("Este vídeo").font(.headline)
                    HStack(spacing: Space.xs) {
                        Circle().fill(current.kind.color).frame(width: 8, height: 8)
                        Text("\(current.kind.label) · \(timeRange(current.begin, current.end))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                let mine = tags.tags(of: current, camera: camera)
                if mine.isEmpty {
                    Text("Sem tags ainda.").font(.caption).foregroundStyle(.secondary)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Space.xs) {
                            ForEach(mine, id: \.self) { tag in chip(tag, current: current) }
                        }
                    }
                }
            } else {
                Text("Toque um vídeo para colocar tags nele.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            TextField(current == nil ? String(localized: "Buscar tag") : String(localized: "Adicionar ou buscar tag"),
                      text: $state.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addTyped)

            if let current, canCreate {
                Button {
                    addTyped()
                } label: {
                    Label(String(localized: "Criar a tag \"\(trimmedQuery)\""), systemImage: "plus.circle.fill")
                }
                .buttonStyle(.link)
                .help("Criar a tag e colocar neste vídeo")
                .disabled(tags.tags(of: current, camera: camera).contains(trimmedQuery))
            }

            Divider()
            Text("Tags").font(.subheadline.weight(.semibold))
            if matches.isEmpty {
                Text(tags.allTags.isEmpty ? String(localized: "Nenhuma tag criada ainda.")
                                          : String(localized: "Nenhuma tag com esse nome."))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: Space.xxs) {
                        ForEach(matches, id: \.name) { tag in tagRow(tag.name, count: tag.count) }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private var trimmedQuery: String { state.query.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var matches: [(name: String, count: Int)] {
        let query = trimmedQuery
        guard !query.isEmpty else { return tags.allTags }
        return tags.allTags.filter { $0.name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
    }

    /// Mostra "Criar a tag" só quando o texto ainda não é uma tag existente.
    private var canCreate: Bool {
        !trimmedQuery.isEmpty && !tags.allTags.contains {
            $0.name.compare(trimmedQuery, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }

    private func addTyped() {
        guard let current, !trimmedQuery.isEmpty else { return }
        tags.add(trimmedQuery, to: current, camera: camera)
        state.query = ""
    }

    private func chip(_ tag: String, current: Recording) -> some View {
        HStack(spacing: Space.xxs) {
            Image(systemName: "tag.fill").font(.system(size: 9))
            Text(tag)
            Button {
                tags.remove(tag, from: current, camera: camera)
            } label: {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .help("Tirar a tag deste vídeo")
            .accessibilityLabel(String(localized: "Tirar a tag \(tag)"))
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.white)
        .padding(.horizontal, Space.s)
        .padding(.vertical, Space.xxs + 1)
        .background(Capsule().fill(Theme.accent))
    }

    private func tagRow(_ name: String, count: Int) -> some View {
        let onVideo = current.map { tags.tags(of: $0, camera: camera).contains(name) } ?? false
        return HStack(spacing: Space.s) {
            Button {
                state.filter = name
            } label: {
                HStack(spacing: Space.s) {
                    Image(systemName: "tag").foregroundStyle(Theme.accent)
                    Text(name).lineLimit(1)
                    Spacer(minLength: Space.s)
                    Text("\(count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Ver os vídeos com esta tag")
            if let current {
                Button {
                    if onVideo { tags.remove(name, from: current, camera: camera) } else { tags.add(name, to: current, camera: camera) }
                } label: {
                    Image(systemName: onVideo ? "checkmark.circle.fill" : "plus.circle")
                        .foregroundStyle(onVideo ? Theme.accent : .secondary)
                }
                .buttonStyle(.plain)
                .help(onVideo ? String(localized: "Tirar a tag deste vídeo") : String(localized: "Colocar a tag neste vídeo"))
                .accessibilityLabel(onVideo ? String(localized: "Tirar a tag \(name)") : String(localized: "Colocar a tag \(name)"))
            }
        }
        .padding(.vertical, Space.xs)
        .padding(.horizontal, Space.s)
        .background(RoundedRectangle(cornerRadius: Radius.small).fill(Color.primary.opacity(0.04)))
    }

    // MARK: - Vídeos de uma tag

    private func taggedList(_ tag: String) -> some View {
        let list = tags.recordings(with: tag, camera: camera)
        return VStack(alignment: .leading, spacing: Space.m) {
            HStack(spacing: Space.s) {
                Button {
                    state.filter = nil
                } label: {
                    Image(systemName: "chevron.left")
                }
                .help("Voltar")
                .accessibilityLabel("Voltar")
                Label(tag, systemImage: "tag.fill").font(.headline).foregroundStyle(Theme.accent)
                Spacer()
                Text("\(list.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if list.isEmpty {
                Text("Nenhum vídeo desta câmera com esta tag.").font(.caption).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: Space.xxs) {
                        ForEach(list) { item in
                            Button { onOpen(item) } label: {
                                HStack(spacing: Space.s) {
                                    Circle().fill(item.kind.color).frame(width: 8, height: 8)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(item.begin.formatted(date: .abbreviated, time: .omitted))
                                        Text("\(item.kind.label) · \(timeRange(item.begin, item.end))")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: "play.circle").foregroundStyle(Theme.accent)
                                }
                                .padding(.vertical, Space.xs)
                                .padding(.horizontal, Space.s)
                                .background(RoundedRectangle(cornerRadius: Radius.small).fill(Color.primary.opacity(0.04)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Abrir este vídeo")
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
        }
    }

    private func timeRange(_ begin: Date, _ end: Date) -> String {
        "\(begin.formatted(date: .omitted, time: .shortened))–\(end.formatted(date: .omitted, time: .shortened))"
    }
}
