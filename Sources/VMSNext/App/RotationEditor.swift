import SwiftUI

/// Editor do rodízio de telas: a lista de telas (modelo + mosaico) e o tempo em cada uma.
struct RotationEditor: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: CameraStore
    @ObservedObject private var rotation = RotationStore.shared
    @ObservedObject private var layouts = ViewLayoutStore.shared
    @StateObject private var draft = RotationDraft()

    private var contexts: [(id: String, name: String)] {
        [("all", "Câmeras")] + store.groups.map { ("group:\($0)", $0) }
    }

    private var templates: [(id: String, name: String)] {
        [(ViewTemplate.autoID, "Auto")] + layouts.all.map { ($0.id, ContentView.templateTitle($0)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rodízio de telas").font(.title2.weight(.semibold))
            Text("O mosaico passa sozinho por estas telas, uma de cada vez, como o \"Tour\" do VMS antigo. Em cada tela vale a posição das câmeras que você arrumou naquele modelo.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Stepper("Tempo em cada tela: \(rotation.dwell) segundos", value: $rotation.dwell, in: 5 ... 600, step: 5)
            List {
                ForEach(Array(rotation.steps.enumerated()), id: \.element.id) { index, step in
                    HStack {
                        Text("\(index + 1).").monospacedDigit().foregroundStyle(.secondary)
                        Text(name(of: step.templateID, in: templates))
                        Text("·").foregroundStyle(.secondary)
                        Text(name(of: step.context, in: contexts)).foregroundStyle(.secondary)
                        Spacer()
                        Button { rotation.steps.remove(at: index) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless)
                    }
                }
                .onMove { rotation.steps.move(fromOffsets: $0, toOffset: $1) }
            }
            .frame(minHeight: 180)
            HStack {
                Picker("Modelo", selection: $draft.templateID) {
                    ForEach(templates, id: \.id) { Text($0.name).tag($0.id) }
                }
                Picker("Mosaico", selection: $draft.context) {
                    ForEach(contexts, id: \.id) { Text($0.name).tag($0.id) }
                }
                Button("Adicionar tela") {
                    rotation.steps.append(RotationStep(templateID: draft.templateID, context: draft.context))
                }
            }
            HStack {
                Spacer()
                Button("Fechar") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(Space.xl)
        .frame(width: 620, height: 520)
    }

    private func name(of id: String, in list: [(id: String, name: String)]) -> String {
        list.first { $0.id == id }?.name ?? id
    }
}

final class RotationDraft: ObservableObject {
    @Published var templateID = ViewTemplate.autoID
    @Published var context = "all"
}
