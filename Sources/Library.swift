import Foundation
import SceneKit
import AppKit

@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published var items: [LibraryItem] = []
    @Published var thumbnails: [UUID: NSImage] = [:]
    @Published var processing: Set<UUID> = []
    @Published var selection: UUID?
    @Published var multi: Set<UUID> = []
    @Published var searchFocusTick = 0
    @Published var banner: String?
    @Published var catalogs: [Catalog] = []
    @Published var nameRequest: NameRequest?

    let dataDir: URL
    private let thumbsDir: URL
    private let indexURL: URL
    private let catalogsURL: URL
    private var queue: [UUID] = []
    private var pumping = false
    private var bannerTask: Task<Void, Never>?

    init() {
        let fm = FileManager.default
        if let override = ProcessInfo.processInfo.environment["VIEW3D_DATA_DIR"], !override.isEmpty {
            dataDir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            dataDir = base.appendingPathComponent("View 3D", isDirectory: true)
        }
        thumbsDir = dataDir.appendingPathComponent("Vignettes", isDirectory: true)
        indexURL = dataDir.appendingPathComponent("bibliotheque.json")
        catalogsURL = dataDir.appendingPathComponent("catalogues.json")
        try? fm.createDirectory(at: thumbsDir, withIntermediateDirectories: true)
        // Les vignettes changent d'aspect (thème sombre) : on les refait une fois.
        let marker = thumbsDir.appendingPathComponent(".theme-sombre")
        if !fm.fileExists(atPath: marker.path) {
            for f in (try? fm.contentsOfDirectory(at: thumbsDir, includingPropertiesForKeys: nil)) ?? [] where f.pathExtension == "png" {
                try? fm.removeItem(at: f)
            }
            fm.createFile(atPath: marker.path, contents: Data())
        }
        load()
        refreshAll()
        if let name = ProcessInfo.processInfo.environment["VIEW3D_SELECT"] {   // réglage de test
            selection = items.first { $0.fileName == name }?.id
            if let s = selection { multi = [s] }
        }
    }

    // MARK: Persistance

    private func load() {
        if let d = try? Data(contentsOf: catalogsURL), let c = try? JSONDecoder().decode([Catalog].self, from: d) { catalogs = c }
        guard let data = try? Data(contentsOf: indexURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let decoded = try? dec.decode([LibraryItem].self, from: data) { items = decoded }
        for it in items {
            if let img = NSImage(contentsOf: thumbURL(it.id)) { thumbnails[it.id] = img }
        }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(items) { try? data.write(to: indexURL, options: .atomic) }
    }

    private func saveCatalogs() {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(catalogs) { try? data.write(to: catalogsURL, options: .atomic) }
    }

    // MARK: Catalogues

    @discardableResult
    func createCatalog(name: String, adding ids: [UUID] = []) -> UUID? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        let c = Catalog(name: n, itemIDs: ids)
        catalogs.append(c); saveCatalogs()
        return c.id
    }

    func renameCatalog(_ id: UUID, to name: String) {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, let i = catalogs.firstIndex(where: { $0.id == id }) else { return }
        catalogs[i].name = n; saveCatalogs()
    }

    func deleteCatalog(_ id: UUID) {
        catalogs.removeAll { $0.id == id }; saveCatalogs()
    }

    func addToCatalog(_ ids: [UUID], _ catalog: UUID) {
        guard let i = catalogs.firstIndex(where: { $0.id == catalog }) else { return }
        for id in ids where !catalogs[i].itemIDs.contains(id) { catalogs[i].itemIDs.append(id) }
        saveCatalogs()
    }

    func removeFromCatalog(_ id: UUID, _ catalog: UUID) {
        guard let i = catalogs.firstIndex(where: { $0.id == catalog }) else { return }
        catalogs[i].itemIDs.removeAll { $0 == id }; saveCatalogs()
    }

    private func thumbURL(_ id: UUID) -> URL { thumbsDir.appendingPathComponent("\(id.uuidString).png") }

    // MARK: Ajout

    /// Ajoute des fichiers ou des dossiers (parcourus récursivement).
    func importURLs(_ urls: [URL], into catalog: UUID? = nil) {
        var added = 0, duplicates = 0, ignored = 0
        let fm = FileManager.default
        var files: [URL] = []
        for u in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                if let en = fm.enumerator(at: u, includingPropertiesForKeys: [.isRegularFileKey],
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    for case let f as URL in en where ModelFormat.from(url: f) != nil { files.append(f) }
                }
            } else if ModelFormat.from(url: u) != nil { files.append(u) } else { ignored += 1 }
        }
        let known = Set(items.map { $0.path })
        var seen = known
        var firstNew: UUID?
        var touched: [UUID] = []
        for f in files.sorted(by: { $0.path.localizedStandardCompare($1.path) == .orderedAscending }) {
            let path = f.standardizedFileURL.path
            if seen.contains(path) {
                duplicates += 1
                if let ex = items.first(where: { $0.path == path }) { touched.append(ex.id) }
                continue
            }
            seen.insert(path)
            guard let fmt = ModelFormat.from(url: f) else { continue }
            let rv = try? f.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            var item = LibraryItem(path: path, format: fmt, zUp: fmt.defaultZUp)
            item.fileSize = Int64(rv?.fileSize ?? 0)
            item.modified = rv?.contentModificationDate
            items.append(item)
            if firstNew == nil { firstNew = item.id }
            touched.append(item.id)
            enqueue(item.id)
            added += 1
        }
        save()
        if let c = catalog { addToCatalog(touched, c) }
        if let f = firstNew { selection = f; multi = [f] }
        var parts: [String] = []
        if added > 0 { parts.append(added == 1 ? "1 création ajoutée" : "\(added) créations ajoutées") }
        if duplicates > 0 { parts.append(duplicates == 1 ? "1 déjà présente" : "\(duplicates) déjà présentes") }
        if ignored > 0 { parts.append(ignored == 1 ? "1 fichier ignoré (format non pris en charge)" : "\(ignored) fichiers ignorés (format non pris en charge)") }
        if let c = catalog, let cat = catalogs.first(where: { $0.id == c }), !touched.isEmpty { parts.append("dans « \(cat.name) »") }
        if parts.isEmpty { parts.append("Aucun fichier 3D reconnu") }
        showBanner(parts.joined(separator: " · "))
    }

    func showBanner(_ text: String) {
        banner = text
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_500_000_000)
            if !Task.isCancelled { self?.banner = nil }
        }
    }

    // MARK: Modifications

    func remove(_ ids: Set<UUID>) {
        for id in ids { try? FileManager.default.removeItem(at: thumbURL(id)); thumbnails[id] = nil }
        items.removeAll { ids.contains($0.id) }
        for i in catalogs.indices { catalogs[i].itemIDs.removeAll { ids.contains($0) } }
        saveCatalogs()
        multi.subtract(ids)
        if let s = selection, ids.contains(s) { selection = multi.first }
        save()
    }

    func setTags(_ id: UUID, _ text: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        let tags = text.split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let new: [String]? = tags.isEmpty ? nil : tags
        if items[i].tags != new { items[i].tags = new; save() }
    }

    // MARK: Recherche

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// Texte dans lequel on cherche : nom, dossier, format, mots-clés, catalogues, « favori ».
    func searchHaystack(_ it: LibraryItem) -> String {
        var parts = [it.fileName, it.folderPath, it.format.label, it.format.badge] + (it.tags ?? [])
        parts += catalogs.filter { $0.itemIDs.contains(it.id) }.map { $0.name }
        if it.favorite { parts.append("favori") }
        return Library.fold(parts.joined(separator: " | "))
    }

    func toggleFavorite(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].favorite.toggle(); save()
    }

    func setZUp(_ id: UUID, _ value: Bool) {
        guard let i = items.firstIndex(where: { $0.id == id }), items[i].zUp != value else { return }
        items[i].zUp = value; save()
        enqueue(id)
    }

    func item(_ id: UUID?) -> LibraryItem? {
        guard let id = id else { return nil }
        return items.first { $0.id == id }
    }

    func revealInFinder(_ item: LibraryItem) {
        if item.exists {
            NSWorkspace.shared.activateFileViewerSelecting([item.url])
        } else {
            let folder = item.url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: folder.path) { NSWorkspace.shared.open(folder) }
        }
    }

    func openFile(_ item: LibraryItem) {
        if item.exists { NSWorkspace.shared.open(item.url) }
    }

    // MARK: Vignettes

    /// Au lancement : détecte les fichiers modifiés et complète les vignettes manquantes.
    func refreshAll() {
        for i in items.indices {
            let it = items[i]
            guard it.exists else { continue }
            let rv = try? it.url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let changed = rv?.contentModificationDate != it.modified
            if changed {
                items[i].modified = rv?.contentModificationDate
                items[i].fileSize = Int64(rv?.fileSize ?? 0)
                items[i].error = nil
            }
            if changed || (thumbnails[it.id] == nil && it.error == nil) { enqueue(it.id) }
        }
        save()
    }

    private func enqueue(_ id: UUID) {
        if !queue.contains(id) { queue.append(id) }
        processing.insert(id)
        guard !pumping else { return }
        pumping = true
        Task { await self.pump() }
    }

    private func pump() async {
        while !queue.isEmpty {
            let id = queue.removeFirst()
            await process(id)
            processing.remove(id)
        }
        pumping = false
    }

    private func process(_ id: UUID) async {
        guard let item = item(id) else { return }
        guard item.exists else { return }
        let url = item.url, format = item.format
        let result: Result<LoadedModel, Error> = await Task.detached(priority: .userInitiated) {
            Result { try ModelLoader.load(url: url, format: format) }
        }.value
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        switch result {
        case .success(let model):
            items[idx].triangles = model.triangles
            items[idx].dims = model.size
            items[idx].error = nil
            if let img = ThumbnailRenderer.shared.render(model: model, zUp: items[idx].zUp) {
                thumbnails[id] = img
                try? img.pngData()?.write(to: thumbURL(id), options: .atomic)
            }
        case .failure(let err):
            items[idx].error = err.localizedDescription
            thumbnails[id] = nil
        }
        save()
    }
}
