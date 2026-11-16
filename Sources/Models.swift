import Foundation

/// Formats 3D pris en charge.
enum ModelFormat: String, Codable, CaseIterable, Identifiable {
    case stl, obj, ply, threeMF, usd, abc, dae, scn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .stl: return "STL"
        case .obj: return "OBJ"
        case .ply: return "PLY"
        case .threeMF: return "3MF"
        case .usd: return "USD / USDZ"
        case .abc: return "Alembic"
        case .dae: return "Collada"
        case .scn: return "SceneKit"
        }
    }

    var badge: String {
        switch self {
        case .threeMF: return "3MF"
        case .usd: return "USD"
        case .abc: return "ABC"
        case .dae: return "DAE"
        default: return rawValue.uppercased()
        }
    }

    /// Les fichiers d'impression 3D (STL, 3MF) ont presque toujours l'axe Z vers le haut.
    var defaultZUp: Bool { self == .stl || self == .threeMF }

    static let byExtension: [String: ModelFormat] = [
        "stl": .stl, "obj": .obj, "ply": .ply, "3mf": .threeMF,
        "usd": .usd, "usda": .usd, "usdc": .usd, "usdz": .usd,
        "abc": .abc, "dae": .dae, "scn": .scn,
    ]

    static func from(url: URL) -> ModelFormat? { byExtension[url.pathExtension.lowercased()] }
}

/// Une création dans la bibliothèque. Le fichier reste là où il est : on ne fait que le référencer.
struct LibraryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var path: String
    var format: ModelFormat
    var addedAt = Date()
    var fileSize: Int64 = 0
    var modified: Date?
    var triangles: Int?
    var dims: [Double]?          // taille X, Y, Z dans les unités du fichier
    var favorite = false
    var zUp: Bool
    var error: String?
    var tags: [String]?          // mots-clés saisis par l'utilisateur

    var url: URL { URL(fileURLWithPath: path) }
    var displayName: String { url.deletingPathExtension().lastPathComponent }
    var fileName: String { url.lastPathComponent }
    var folderPath: String { url.deletingLastPathComponent().path }
    var exists: Bool { FileManager.default.fileExists(atPath: path) }
}

/// Un catalogue : une sélection de créations (une création peut être dans plusieurs catalogues).
struct Catalog: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var itemIDs: [UUID] = []
    var createdAt = Date()
}

/// Demande de saisie d'un nom de catalogue (création ou renommage).
enum NameRequest: Hashable {
    case create([UUID])
    case rename(UUID)
}
