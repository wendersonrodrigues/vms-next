import SwiftUI

struct CameraTile: View {
    let camera: Camera
    let quality: StreamQuality
    let onEdit: () -> Void
    var onSettings: (() -> Void)? = nil

    @EnvironmentObject private var store: CameraStore
    @StateObject private var stream = LiveStream()

    var body: some View {
        ZStack {
            VideoLayerView(layer: stream.displayLayer)
            overlay
            VStack {
                Spacer()
                HStack {
                    Text(camera.displayName)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                        .foregroundStyle(.white)
                    Spacer()
                }
                .padding(6)
            }
        }
        .background(Color.black)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Editar câmera…", action: onEdit)
            if let onSettings { Button("Configurações…", action: onSettings) }
            Button("Reconectar", action: start)
        }
        .onAppear(perform: start)
        .onDisappear { stream.stop() }
        .onChange(of: store.passwordRevision) { start() }
    }

    @ViewBuilder
    private var overlay: some View {
        switch stream.status {
        case .idle, .playing:
            EmptyView()
        case .connecting:
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Conectando…")
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))
        case .needsPassword:
            VStack(spacing: 8) {
                Image(systemName: "key.fill").font(.title2)
                Text("Senha não definida")
                Button("Definir senha", action: onEdit)
            }
            .font(.caption)
            .foregroundStyle(.white)
        case let .failed(message, retrying):
            VStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title2)
                    .foregroundStyle(.yellow)
                Text(message).multilineTextAlignment(.center)
                if retrying {
                    Text("Tentando novamente…").foregroundStyle(.white.opacity(0.6))
                } else {
                    Button("Corrigir senha", action: onEdit)
                }
            }
            .font(.caption)
            .foregroundStyle(.white)
            .padding()
        }
    }

    private func start() {
        stream.start(camera: camera, quality: quality, password: store.password(for: camera),
                     source: store.resolvedLiveSource(for: camera))
    }
}
