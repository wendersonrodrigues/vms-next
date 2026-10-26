import AppKit
import CoreImage
import Foundation
import Vision

/// Gravidade de um alerta, para ordenar e filtrar em Eventos.
enum AlarmSeverity: String, Codable, CaseIterable, Identifiable, Comparable {
    case low, medium, high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return String(localized: "Baixa")
        case .medium: return String(localized: "Média")
        case .high: return String(localized: "Alta")
        }
    }

    var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    static func < (a: Self, b: Self) -> Bool { a.rank < b.rank }
}

/// O que a IA do Mac (Vision) achou na foto do alerta.
struct AlarmAnalysis: Codable, Hashable {
    var people = 0
    var faces = 0
    var cats = 0
    var dogs = 0
    /// Veículos que a classificação da cena viu (carro, moto, caminhão…), já traduzidos.
    var vehicles: [String] = []
    /// Textos lidos na imagem quando há veículo (ajuda com placas).
    var texts: [String] = []
    /// A análise não conseguiu rodar (sem foto ou erro): o alerta fica como o equipamento mandou.
    var failed = false

    var foundSomething: Bool { people > 0 || cats + dogs > 0 || !vehicles.isEmpty }

    /// Título do alerta depois da análise ("Pessoa · 2 pessoas", "Veículo · carro").
    var title: String? {
        if people > 0 { return people == 1 ? String(localized: "Pessoa") : String(localized: "\(people) pessoas") }
        if let first = vehicles.first { return String(localized: "Veículo · \(first)") }
        if dogs > 0 { return dogs == 1 ? String(localized: "Cachorro") : String(localized: "\(dogs) cachorros") }
        if cats > 0 { return cats == 1 ? String(localized: "Gato") : String(localized: "\(cats) gatos") }
        return nil
    }

    /// Etiquetas curtas do que foi achado, para a linha do evento.
    var chips: [String] {
        var result: [String] = []
        if people > 0 { result.append(people == 1 ? String(localized: "1 pessoa") : String(localized: "\(people) pessoas")) }
        if faces > 0 { result.append(faces == 1 ? String(localized: "1 rosto") : String(localized: "\(faces) rostos")) }
        result += vehicles
        if dogs > 0 { result.append(dogs == 1 ? String(localized: "1 cachorro") : String(localized: "\(dogs) cachorros")) }
        if cats > 0 { result.append(cats == 1 ? String(localized: "1 gato") : String(localized: "\(cats) gatos")) }
        result += texts.prefix(2).map { "“\($0)”" }
        return result
    }
}

/// Analisa a foto do alerta com o Vision do macOS, no próprio Mac (Neural Engine), sem internet e sem baixar
/// modelo: pessoas, rostos, cães e gatos, veículos pela classificação da cena e texto quando há veículo.
enum AlarmVision {
    /// Identificadores da classificação da cena do Vision que contam como veículo, com o nome mostrado.
    private static let vehicleLabels: [String: String] = [
        "car": String(localized: "carro"), "automobile": String(localized: "carro"), "sportscar": String(localized: "carro"),
        "suv": String(localized: "carro"), "jeep": String(localized: "carro"), "police_car": String(localized: "carro"),
        "truck": String(localized: "caminhão"), "semi_truck": String(localized: "caminhão"), "firetruck": String(localized: "caminhão"),
        "van": String(localized: "van"), "motorhome": String(localized: "van"), "bus": String(localized: "ônibus"),
        "motorcycle": String(localized: "moto"), "scooter": String(localized: "moto"), "bicycle": String(localized: "bicicleta"),
        "vehicle": String(localized: "veículo"),
    ]

    static func analyze(_ image: CGImage) async -> AlarmAnalysis {
        await Task.detached(priority: .utility) { run(image) }.value
    }

    private static func run(_ image: CGImage) -> AlarmAnalysis {
        var result = AlarmAnalysis()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let faces = VNDetectFaceRectanglesRequest()
        let animals = VNRecognizeAnimalsRequest()
        let scene = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([humans, faces, animals, scene])
        } catch {
            result.failed = true
            return result
        }
        result.people = (humans.results ?? []).filter { $0.confidence > 0.5 }.count
        result.faces = (faces.results ?? []).filter { $0.confidence > 0.5 }.count
        for animal in animals.results ?? [] {
            guard let label = animal.labels.first, label.confidence > 0.5 else { continue }
            if label.identifier == VNAnimalIdentifier.cat.rawValue { result.cats += 1 }
            if label.identifier == VNAnimalIdentifier.dog.rawValue { result.dogs += 1 }
        }
        var seen = Set<String>()
        for observation in scene.results ?? [] where observation.confidence > 0.3 {
            let id = observation.identifier.lowercased()
            // Nomes exatos da lista do Vision (VNClassifyImageRequest.supportedIdentifiers).
            if let name = vehicleLabels[id], seen.insert(name).inserted { result.vehicles.append(name) }
        }
        // Texto só quando há veículo: é o caso das placas, e evita ler a data e o nome que a câmera escreve na imagem.
        if !result.vehicles.isEmpty {
            let text = VNRecognizeTextRequest()
            text.recognitionLevel = .accurate
            text.usesLanguageCorrection = false
            if (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([text])) != nil {
                result.texts = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter(looksLikePlate)
            }
        }
        return result
    }

    /// Placa (antiga ou Mercosul): 7 caracteres com letras e números, sem os textos de data/hora da câmera.
    private static func looksLikePlate(_ text: String) -> Bool {
        let clean = text.uppercased().filter { $0.isLetter || $0.isNumber }
        guard clean.count == 7 else { return false }
        return clean.contains(where: \.isLetter) && clean.contains(where: \.isNumber)
    }
}

/// Foto do alerta: o quadro que já está na tela (sem gastar rede) ou, se a câmera não está aberta, uma foto
/// pedida ao equipamento (OPSNAP). Guarda uma cópia pequena para a linha do evento.
@MainActor
enum AlarmPhotos {
    static let folder: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("VMSNext/alert-photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    static func url(for id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).jpg") }

    static func capture(camera: Camera) async -> CGImage? {
        for quality in [StreamQuality.main, .sub] {
            guard let stream = LiveStreamHub.shared.existing(LiveStreamHub.key(camera, quality)) else { continue }
            if #available(macOS 14.4, *), let buffer = stream.displayLayer.sampleBufferRenderer.displayedPixelBuffer() {
                let image = CIImage(cvPixelBuffer: buffer)
                if let cgImage = CIContext().createCGImage(image, from: image.extent) { return cgImage }
            }
        }
        guard let client = try? await DeviceSessions.shared.client(for: camera),
              let data = try? await client.snapshot(channel: camera.channel - 1),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Cópia de até 640 px de largura em JPEG, para a lista de Eventos e a notificação.
    static func save(_ image: CGImage, id: UUID) -> URL? {
        let scale = min(1, 640 / CGFloat(image.width))
        let size = NSSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
        let resized = NSImage(size: size)
        resized.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: .zero).draw(in: NSRect(origin: .zero, size: size))
        resized.unlockFocus()
        guard let tiff = resized.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.8]) else { return nil }
        let url = url(for: id)
        return (try? data.write(to: url)) != nil ? url : nil
    }

    static func remove(_ ids: [UUID]) {
        for id in ids { try? FileManager.default.removeItem(at: url(for: id)) }
    }
}
