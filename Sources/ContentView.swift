import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum SidebarFilter: Hashable {
    case all, favorites, missing
    case format(ModelFormat)
    case catalog(UUID)
}

enum SortMode: String, CaseIterable, Identifiable {
    case added = "Date d'ajout"
    case name = "Nom"
    case size = "Taille du fichier"
    case format = "Format"
    var id: String { rawValue }
}

enum SearchScope: Hashable { case library, here }

struct ContentView: View {
    @EnvironmentObject var lib: Library
    @State private var filter: SidebarFilter? = .all
    @State private var search = ""
    @State private var scope: SearchScope = .library
    @State private var sort: SortMode = .added
    @State private var cardSize: Double = 210
    @State private var dropTargeted = false
    @State private var nameText = ""
    @State private var showPicker = false
    @FocusState private var searchFocused: Bool

    private var currentFilter: SidebarFilter { filter ?? .all }
    private var currentCatalogID: UUID? { if case .catalog(let id) = currentFilter { return id } else { return nil } }
    private var currentCatalog: Catalog? { lib.catalogs.first { $0.id == currentCatalogID } }
    private var alertTitle: String {
        if case .rename = lib.nameRequest { return "Renommer le catalogue" }
        return "Nouveau catalogue"
    }
    private var tokens: [String] {
        Library.fold(search).split(whereSeparator: { $0 == " " }).map(String.init)
    }
    private var searching: Bool { !tokens.isEmpty }

    private var viewTitle: String {
        switch currentFilter {
        case .all: return "Toutes les créations"
        case .favorites: return "Favoris"
        case .missing: return "Fichiers introuvables"
        case .format(let f): return "Format \(f.label)"
        case .catalog: return "Catalogue « \(currentCatalog?.name ?? "") »"
        }
    }

    private func passesFilter(_ it: LibraryItem) -> Bool {
        switch currentFilter {
        case .all: return true
        case .favorites: return it.favorite
        case .missing: return !it.exists
        case .format(let f): return it.format == f
        case .catalog: return currentCatalog?.itemIDs.contains(it.id) ?? false
        }
    }

    private var filtered: [LibraryItem] {
        let global = searching && scope == .library
        var list = lib.items.filter { global || passesFilter($0) }
        if searching {
            list = list.filter { it in
                let h = lib.searchHaystack(it)
                return tokens.allSatisfy { h.contains($0) }
            }
        }
        switch sort {
        case .added: list.sort { $0.addedAt > $1.addedAt }
        case .name: list.sort { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
        case .size: list.sort { $0.fileSize > $1.fileSize }
        case .format: list.sort { ($0.format.badge, $0.fileName) < ($1.format.badge, $1.fileName) }
        }
        if searching {      // les correspondances sur le nom d'abord
            let named = { (it: LibraryItem) -> Bool in
                let n = Library.fold(it.fileName); return tokens.allSatisfy { n.contains($0) }
            }
            list = list.filter(named) + list.filter { !named($0) }
        }
        return list
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            ZStack {
                if lib.items.isEmpty {
                    EmptyLibraryView()
                } else {
                    HStack(spacing: 0) {
                        gridArea.frame(minWidth: 380, maxWidth: .infinity)
                        Divider()
                        DetailPanel().frame(width: 430)
                    }
                }
                if dropTargeted { DropOverlay() }
            }
            .overlay(alignment: .bottom) {
                if let b = lib.banner {
                    Text(b)
                        .font(.callout.weight(.medium))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.12)))
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
                        .padding(.bottom, 18)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: lib.banner)
        }
        .navigationTitle("View 3D")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { presentAddPanel() } label: { Label("Ajouter", systemImage: "plus") }
                    .help("Ajouter des fichiers 3D ou des dossiers (⌘O)")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Picker("Trier par", selection: $sort) {
                        ForEach(SortMode.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.inline)
                } label: { Label("Trier", systemImage: "arrow.up.arrow.down") }
                    .help("Trier les créations")
            }
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 4) {
                    Image(systemName: "square.grid.3x3").font(.caption).foregroundStyle(.secondary)
                    Slider(value: $cardSize, in: 150...340).frame(width: 90)
                    Image(systemName: "square.grid.2x2").font(.caption).foregroundStyle(.secondary)
                }
                .help("Taille des vignettes")
            }
        }
        .alert(alertTitle, isPresented: Binding(get: { lib.nameRequest != nil }, set: { if !$0 { lib.nameRequest = nil } })) {
            TextField("Nom du catalogue", text: $nameText)
            Button("Annuler", role: .cancel) {}
            Button("Valider") { commitName() }
        } message: {
            Text("Par exemple : Figurines, Pour le salon, Clients…")
        }
        .onChange(of: lib.nameRequest) { req in
            if case .rename(let id) = req { nameText = lib.catalogs.first { $0.id == id }?.name ?? "" } else { nameText = "" }
        }
        .onChange(of: lib.searchFocusTick) { _ in searchFocused = true }
        .onChange(of: filter) { _ in scope = .library }
        .sheet(isPresented: $showPicker) {
            if let id = currentCatalogID { AddToCatalogSheet(catalogID: id) }
        }
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            handleDrop(providers, into: currentCatalogID)
            return true
        }
    }

    // MARK: Sidebar

    private func commitName() {
        guard let req = lib.nameRequest else { return }
        switch req {
        case .create(let ids):
            if let id = lib.createCatalog(name: nameText, adding: ids) { filter = .catalog(id) }
        case .rename(let id):
            lib.renameCatalog(id, to: nameText)
        }
        lib.nameRequest = nil
    }

    private var sidebar: some View {
        let missing = lib.items.filter { !$0.exists }.count
        let formats = ModelFormat.allCases.filter { f in lib.items.contains { $0.format == f } }
        return List(selection: $filter) {
            Section("Bibliothèque") {
                Label("Toutes les créations", systemImage: "square.grid.2x2")
                    .badge(lib.items.count).tag(SidebarFilter.all)
                Label("Favoris", systemImage: "star")
                    .badge(lib.items.filter { $0.favorite }.count).tag(SidebarFilter.favorites)
                if missing > 0 {
                    Label("Introuvables", systemImage: "exclamationmark.triangle")
                        .badge(missing).tag(SidebarFilter.missing)
                }
            }
            Section {
                ForEach(lib.catalogs) { c in
                    Label(c.name, systemImage: "books.vertical")
                        .badge(c.itemIDs.count)
                        .tag(SidebarFilter.catalog(c.id))
                        .contextMenu {
                            Button("Renommer…") { lib.nameRequest = .rename(c.id) }
                            Button("Supprimer le catalogue", role: .destructive) {
                                if filter == .catalog(c.id) { filter = .all }
                                lib.deleteCatalog(c.id)
                            }
                        }
                        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                            handleDrop(providers, into: c.id); return true
                        }
                }
            } header: {
                HStack {
                    Text("Catalogues")
                    Spacer()
                    Button { lib.nameRequest = .create([]) } label: { Image(systemName: "plus") }
                        .buttonStyle(.plain).help("Nouveau catalogue")
                }
            }
            if !formats.isEmpty {
                Section("Formats") {
                    ForEach(formats) { f in
                        Label(f.label, systemImage: "cube")
                            .badge(lib.items.filter { $0.format == f }.count)
                            .tag(SidebarFilter.format(f))
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }

    // MARK: Grille

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Rechercher : nom, dossier, format, catalogue, mot-clé…", text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onExitCommand { search = ""; searchFocused = false }
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).help("Effacer la recherche (Échap)")
            } else {
                Text("⌘F").font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .stroke(searchFocused ? Color.accentColor : Color.white.opacity(0.12), lineWidth: searchFocused ? 2 : 1))
    }

    private func header(count: Int) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            searchBar
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(searching && scope == .library ? "Résultats dans toute la bibliothèque" : viewTitle)
                        .font(.headline)
                    Text(count == 0 ? "Aucune création" : count == 1 ? "1 création" : "\(count) créations")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if searching && currentFilter != .all {
                    Picker("", selection: $scope) {
                        Text("Toute la bibliothèque").tag(SearchScope.library)
                        Text("Ici seulement").tag(SearchScope.here)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 250)
                }
                if currentCatalogID != nil && !searching {
                    Button { showPicker = true } label: { Label("Ajouter des créations…", systemImage: "plus.circle") }
                        .help("Choisir dans toute la bibliothèque ce qui doit entrer dans ce catalogue")
                }
            }
        }
        .padding(.horizontal, 20).padding(.top, 14).padding(.bottom, 4)
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text("\(lib.multi.count) sélectionnées").font(.callout.weight(.medium))
            Menu("Ajouter à un catalogue") { CatalogMenuItems(itemIDs: Array(lib.multi)) }
                .fixedSize()
            if let c = currentCatalog {
                Button("Retirer de « \(c.name) »") { for id in lib.multi { lib.removeFromCatalog(id, c.id) } }
            }
            Button("Retirer de la bibliothèque", role: .destructive) { lib.remove(lib.multi) }
            Spacer()
            Button("Tout désélectionner") { lib.multi = lib.selection.map { [$0] } ?? [] }
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial)
        .overlay(Divider(), alignment: .top)
    }

    private var gridArea: some View {
        let list = filtered
        return VStack(spacing: 0) {
            header(count: list.count)
            ScrollView {
                if list.isEmpty {
                    emptyMessage
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize, maximum: cardSize * 1.6), spacing: 18)], spacing: 20) {
                        ForEach(list) { item in
                            CardView(item: item,
                                     image: lib.thumbnails[item.id],
                                     isSelected: lib.multi.contains(item.id) || lib.selection == item.id,
                                     isProcessing: lib.processing.contains(item.id))
                                .onTapGesture(count: 2) { lib.selection = item.id; lib.multi = [item.id]; lib.openFile(item) }
                                .onTapGesture { tap(item, in: list) }
                                .onDrag { NSItemProvider(contentsOf: item.url) ?? NSItemProvider() }
                                .contextMenu { contextMenu(for: item) }
                        }
                    }
                    .padding(20)
                }
            }
            if lib.multi.count > 1 { selectionBar }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var emptyMessage: some View {
        VStack(spacing: 12) {
            Image(systemName: searching ? "magnifyingglass" : "tray").font(.system(size: 34)).foregroundStyle(.tertiary)
            if searching {
                Text("Aucun résultat pour « \(search) »").foregroundStyle(.secondary)
                if currentFilter != .all && scope == .here {
                    Button("Chercher dans toute la bibliothèque") { scope = .library }
                }
            } else if currentCatalogID != nil {
                Text("Ce catalogue est vide").foregroundStyle(.secondary)
                Button { showPicker = true } label: { Label("Ajouter des créations…", systemImage: "plus.circle") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                Text("Vous pouvez aussi cliquer sur « Toutes les créations », sélectionner plusieurs vignettes (⌘ ou ⇧ + clic) puis les ajouter.")
                    .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center).frame(maxWidth: 360)
            } else {
                Text("Aucune création dans cette sélection").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 100)
    }

    @ViewBuilder private func contextMenu(for item: LibraryItem) -> some View {
        let targets: [UUID] = (lib.multi.contains(item.id) && lib.multi.count > 1) ? Array(lib.multi) : [item.id]
        Button("Afficher dans le Finder") { lib.revealInFinder(item) }
        Button("Ouvrir avec l'application par défaut") { lib.openFile(item) }.disabled(!item.exists)
        Divider()
        Menu(targets.count > 1 ? "Catalogues (\(targets.count) créations)" : "Catalogues") { CatalogMenuItems(itemIDs: targets) }
        if let c = currentCatalog {
            Button("Retirer de « \(c.name) »") { for id in targets { lib.removeFromCatalog(id, c.id) } }
        }
        Button(item.favorite ? "Retirer des favoris" : "Ajouter aux favoris") { lib.toggleFavorite(item.id) }
        Divider()
        Button("Retirer de la bibliothèque") { lib.remove(Set(targets)) }
    }

    private func tap(_ item: LibraryItem, in list: [LibraryItem]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.command) {
            if lib.multi.contains(item.id) {
                lib.multi.remove(item.id)
                if lib.selection == item.id { lib.selection = lib.multi.first }
            } else { lib.multi.insert(item.id); lib.selection = item.id }
        } else if flags.contains(.shift), let anchor = lib.selection,
                  let a = list.firstIndex(where: { $0.id == anchor }), let b = list.firstIndex(where: { $0.id == item.id }) {
            for it in list[min(a, b)...max(a, b)] { lib.multi.insert(it.id) }
            lib.selection = item.id
        } else {
            lib.multi = [item.id]; lib.selection = item.id
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], into catalog: UUID? = nil) {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()
        for p in providers {
            group.enter()
            p.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let data = item as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock(); urls.append(url); lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            Task { @MainActor in Library.shared.importURLs(urls, into: catalog) }
        }
    }
}

// MARK: - Carte

struct CardView: View {
    let item: LibraryItem
    let image: NSImage?
    let isSelected: Bool
    let isProcessing: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: viewerBackground))
                if let image = image {
                    Image(nsImage: image).resizable().scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .opacity(item.exists ? 1 : 0.35)
                } else if isProcessing {
                    VStack(spacing: 8) { ProgressView().controlSize(.small); Text("Préparation…").font(.caption).foregroundStyle(.secondary) }
                } else if let err = item.error {
                    VStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                        Text(err).font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center).lineLimit(3)
                    }.padding(10)
                } else {
                    Image(systemName: "cube").font(.system(size: 34)).foregroundStyle(.tertiary)
                }
                if !item.exists {
                    VStack(spacing: 4) {
                        Image(systemName: "questionmark.folder").font(.title)
                        Text("Introuvable").font(.caption.weight(.semibold))
                    }.foregroundStyle(.orange)
                }
            }
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.12), lineWidth: isSelected ? 3 : 1)
            )
            .shadow(color: .black.opacity(isSelected ? 0.18 : 0.06), radius: isSelected ? 8 : 3, y: 2)

            HStack(spacing: 6) {
                Text(item.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if item.favorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow) }
                Text(item.format.badge)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                    .foregroundStyle(Color.accentColor)
            }
            .padding(.horizontal, 2)
        }
        .contentShape(Rectangle())
    }
}

// MARK: - États vides

struct EmptyLibraryView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 128, height: 128)
            Text("Bienvenue dans View 3D").font(.largeTitle.weight(.semibold))
            Text("Ajoutez vos créations 3D pour les voir en un coup d'œil,\nles faire tourner et retrouver leur dossier en un clic.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button { presentAddPanel() } label: {
                Label("Ajouter des créations…", systemImage: "plus").padding(.horizontal, 10)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            Text("ou glissez-déposez ici des fichiers ou des dossiers")
                .font(.callout).foregroundStyle(.secondary)
            Text("Formats : STL · OBJ · PLY · 3MF · USD/USDZ · Alembic · Collada · SceneKit")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct DropOverlay: View {
    var body: some View {
        ZStack {
            Color.accentColor.opacity(0.08)
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 8]))
                .padding(14)
            VStack(spacing: 8) {
                Image(systemName: "square.and.arrow.down").font(.system(size: 44))
                Text("Déposez vos fichiers 3D ici").font(.title2.weight(.semibold))
            }.foregroundStyle(Color.accentColor)
        }
        .allowsHitTesting(false)
    }
}

/// Cases à cocher « dans quels catalogues sont ces créations ».
struct CatalogMenuItems: View {
    @EnvironmentObject var lib: Library
    let itemIDs: [UUID]
    var body: some View {
        ForEach(lib.catalogs) { c in
            let inside = !itemIDs.isEmpty && itemIDs.allSatisfy { c.itemIDs.contains($0) }
            Button {
                if inside { for id in itemIDs { lib.removeFromCatalog(id, c.id) } } else { lib.addToCatalog(itemIDs, c.id) }
            } label: {
                if inside { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
            }
        }
        if !lib.catalogs.isEmpty { Divider() }
        Button("Nouveau catalogue…") { lib.nameRequest = .create(itemIDs) }
    }
}

/// Fenêtre pour choisir, dans toute la bibliothèque, ce qui entre dans un catalogue.
struct AddToCatalogSheet: View {
    @EnvironmentObject var lib: Library
    @Environment(\.dismiss) private var dismiss
    let catalogID: UUID
    @State private var picked: Set<UUID> = []
    @State private var query = ""

    private var catalog: Catalog? { lib.catalogs.first { $0.id == catalogID } }
    private var candidates: [LibraryItem] {
        let inside = Set(catalog?.itemIDs ?? [])
        let toks = Library.fold(query).split(separator: " ").map(String.init)
        return lib.items
            .filter { !inside.contains($0.id) }
            .filter { it in let h = lib.searchHaystack(it); return toks.allSatisfy { h.contains($0) } }
            .sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
    }

    var body: some View {
        let list = candidates
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Ajouter à « \(catalog?.name ?? "") »").font(.title3.weight(.semibold))
                Text("Cliquez sur les créations à ajouter. Elles restent dans votre bibliothèque.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Rechercher dans la bibliothèque…", text: $query).textFieldStyle(.plain)
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.07)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Color.white.opacity(0.12)))
            }
            .padding(20)
            Divider()
            ScrollView {
                if list.isEmpty {
                    Text(query.isEmpty ? "Toutes vos créations sont déjà dans ce catalogue." : "Aucun résultat")
                        .foregroundStyle(.secondary).padding(.top, 80)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 14)], spacing: 14) {
                        ForEach(list) { it in
                            let on = picked.contains(it.id)
                            VStack(spacing: 5) {
                                ZStack(alignment: .topTrailing) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: viewerBackground))
                                        if let img = lib.thumbnails[it.id] {
                                            Image(nsImage: img).resizable().scaledToFit()
                                                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                        } else { Image(systemName: "cube").foregroundStyle(.tertiary) }
                                    }
                                    .aspectRatio(4.0 / 3.0, contentMode: .fit)
                                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(on ? Color.accentColor : Color.white.opacity(0.12), lineWidth: on ? 3 : 1))
                                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                                        .font(.title3)
                                        .foregroundStyle(on ? Color.accentColor : Color.white.opacity(0.5))
                                        .padding(6)
                                }
                                Text(it.displayName).font(.caption).lineLimit(1).truncationMode(.middle)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { if on { picked.remove(it.id) } else { picked.insert(it.id) } }
                        }
                    }
                    .padding(20)
                }
            }
            Divider()
            HStack {
                Button("Tout sélectionner (\(list.count))") { picked.formUnion(list.map { $0.id }) }
                    .disabled(list.isEmpty)
                Spacer()
                Button("Annuler") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(picked.isEmpty ? "Ajouter" : "Ajouter \(picked.count) création\(picked.count > 1 ? "s" : "")") {
                    lib.addToCatalog(Array(picked), catalogID)
                    lib.showBanner("\(picked.count) ajoutée\(picked.count > 1 ? "s" : "") à « \(catalog?.name ?? "") »")
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).disabled(picked.isEmpty)
            }
            .padding(16)
        }
        .frame(width: 780, height: 600)
    }
}
