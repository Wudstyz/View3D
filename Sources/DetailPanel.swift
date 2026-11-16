import SwiftUI
import SceneKit
import AppKit

private let frNumber: NumberFormatter = {
    let f = NumberFormatter(); f.locale = Locale(identifier: "fr_FR"); f.numberStyle = .decimal
    f.maximumFractionDigits = 2; f.usesGroupingSeparator = true; return f
}()
private let frDate: DateFormatter = {
    let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateStyle = .long; f.timeStyle = .none; return f
}()

private func fmtSize(_ bytes: Int64) -> String {
    let f = ByteCountFormatter(); f.countStyle = .file; f.allowedUnits = [.useKB, .useMB, .useGB]
    return f.string(fromByteCount: bytes).replacingOccurrences(of: "ko", with: "Ko")
}

struct DetailPanel: View {
    @EnvironmentObject var lib: Library

    var body: some View {
        Group {
            if let item = lib.item(lib.selection) {
                ItemDetail(item: item).id(item.id)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "cursorarrow.click.2").font(.system(size: 38)).foregroundStyle(.tertiary)
                    Text("Sélectionnez une création").font(.title3.weight(.medium))
                    Text("Elle s'affichera ici en 3D, et vous pourrez\nla faire tourner avec la souris.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }
}

struct ItemDetail: View {
    @EnvironmentObject var lib: Library
    let item: LibraryItem
    @State private var tagsText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.displayName).font(.title2.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                    Spacer()
                    Menu { CatalogMenuItems(itemIDs: [item.id]) } label: {
                        Image(systemName: "books.vertical").font(.title3)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Ajouter à un catalogue")
                    Button { lib.toggleFavorite(item.id) } label: {
                        Image(systemName: item.favorite ? "star.fill" : "star")
                            .font(.title3).foregroundStyle(item.favorite ? Color.yellow : Color.secondary)
                    }
                    .buttonStyle(.plain)
                    .help(item.favorite ? "Retirer des favoris" : "Ajouter aux favoris")
                }

                if !item.exists {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Ce fichier est introuvable à son emplacement d'origine : il a peut-être été déplacé, renommé ou supprimé. Vous pouvez le retirer de la bibliothèque et le rajouter depuis son nouvel emplacement.")
                            .font(.callout)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
                } else if let err = item.error {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        Text(err).font(.callout)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.08)))
                } else {
                    ViewerContainer(item: item)
                        .frame(height: 360)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.white.opacity(0.12)))
                    HStack {
                        Text("Haut du modèle")
                            .font(.callout).foregroundStyle(.secondary)
                        Picker("", selection: Binding(get: { item.zUp }, set: { lib.setZUp(item.id, $0) })) {
                            Text("Axe Y").tag(false)
                            Text("Axe Z").tag(true)
                        }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 130)
                        Spacer()
                    }
                    .help("Si le modèle apparaît couché, essayez l'autre axe. Les fichiers d'impression 3D (STL, 3MF) utilisent souvent Z.")
                }

                Button { lib.revealInFinder(item) } label: {
                    Label("Afficher dans le Finder", systemImage: "folder").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                .help(item.exists ? "Ouvre le dossier et sélectionne le fichier" : "Ouvre le dossier d'origine s'il existe encore")

                HStack(spacing: 10) {
                    Button { lib.openFile(item) } label: {
                        Label("Ouvrir", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
                    }
                    .disabled(!item.exists)
                    .help("Ouvre le fichier avec l'application par défaut")
                    Button(role: .destructive) { lib.remove([item.id]) } label: {
                        Label("Retirer", systemImage: "minus.circle").frame(maxWidth: .infinity)
                    }
                    .help("Retire de la bibliothèque (le fichier n'est pas supprimé)")
                }
                .controlSize(.large)

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Mots-clés").font(.caption).foregroundStyle(.secondary)
                    TextField("ex. figurine, dragon, pour le salon", text: $tagsText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { lib.setTags(item.id, tagsText) }
                    Text("Séparés par des virgules. La recherche les utilise.")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .onAppear { tagsText = (item.tags ?? []).joined(separator: ", ") }
                .onDisappear { lib.setTags(item.id, tagsText) }

                VStack(alignment: .leading, spacing: 9) {
                    row("Format", item.format.label)
                    row("Poids", fmtSize(item.fileSize))
                    if let t = item.triangles, t > 0 { row("Triangles", frNumber.string(from: NSNumber(value: t)) ?? "\(t)") }
                    if let d = item.dims, d.count == 3 {
                        row("Dimensions", d.map { frNumber.string(from: NSNumber(value: $0)) ?? "\($0)" }.joined(separator: " × ") + "  (X × Y × Z)")
                    }
                    row("Ajouté le", frDate.string(from: item.addedAt))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Emplacement").font(.caption).foregroundStyle(.secondary)
                        Text(item.path).font(.callout).textSelection(.enabled)
                            .lineLimit(3).truncationMode(.middle)
                    }
                }
            }
            .padding(18)
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(k).font(.callout).foregroundStyle(.secondary).frame(width: 90, alignment: .leading)
            Text(v).font(.callout).textSelection(.enabled)
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Aperçu 3D interactif

private struct ViewerKey: Hashable {
    let id: UUID; let zUp: Bool; let modified: Date?
}

struct ViewerContainer: View {
    let item: LibraryItem
    @State private var prepared: PreparedScene?
    @State private var loading = true
    @State private var errorText: String?
    @State private var wireframe = false
    @State private var resetToken = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color(nsColor: viewerBackground)
            if let p = prepared {
                SceneContainer(prepared: p, wireframe: wireframe, resetToken: resetToken).id(p.id)
            }
            if loading {
                VStack(spacing: 8) { ProgressView(); Text("Chargement…").font(.caption).foregroundStyle(.secondary) }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let e = errorText {
                Text(e).foregroundStyle(.secondary).padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if prepared != nil {
                HStack(spacing: 6) {
                    Toggle(isOn: $wireframe) { Image(systemName: "square.grid.3x3") }
                        .toggleStyle(.button).help("Afficher le maillage (fil de fer)")
                    Button { resetToken += 1 } label: { Image(systemName: "arrow.counterclockwise") }
                        .help("Revenir à la vue de départ (ou double-clic sur le modèle)")
                }
                .controlSize(.small).padding(8)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if prepared != nil {
                Text("Glisser : tourner · Molette : zoom · Maj + glisser : déplacer")
                    .font(.caption2).foregroundStyle(.secondary).padding(8)
            }
        }
        .task(id: ViewerKey(id: item.id, zUp: item.zUp, modified: item.modified)) { await load() }
    }

    private func load() async {
        loading = true; errorText = nil; prepared = nil
        let url = item.url, format = item.format, zUp = item.zUp
        let result: Result<LoadedModel, Error> = await Task.detached(priority: .userInitiated) {
            Result { try ModelLoader.load(url: url, format: format) }
        }.value
        if Task.isCancelled { return }
        switch result {
        case .success(let m): prepared = PreparedScene(model: m, zUp: zUp)
        case .failure(let e): errorText = e.localizedDescription
        }
        loading = false
    }
}

struct SceneContainer: NSViewRepresentable {
    let prepared: PreparedScene
    let wireframe: Bool
    let resetToken: Int

    final class Coordinator: NSObject {
        weak var view: SCNView?
        var prepared: PreparedScene?
        var cam: SCNNode?
        var token = 0

        @objc func doubleClick() { resetCamera() }

        func resetCamera() {
            guard let v = view, let p = prepared else { return }
            cam?.removeFromParentNode()
            let c = p.makeCamera()
            p.scene.rootNode.addChildNode(c)
            cam = c
            v.pointOfView = c
            v.defaultCameraController.target = SCNVector3(0, 0, 0)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> SCNView {
        let v = SCNView(frame: .zero)
        v.scene = prepared.scene
        v.backgroundColor = viewerBackground
        v.allowsCameraControl = true
        v.antialiasingMode = .multisampling4X
        v.autoenablesDefaultLighting = false
        v.defaultCameraController.interactionMode = .orbitTurntable
        v.defaultCameraController.inertiaEnabled = true
        let c = context.coordinator
        c.view = v; c.prepared = prepared
        c.resetCamera()
        let g = NSClickGestureRecognizer(target: c, action: #selector(Coordinator.doubleClick))
        g.numberOfClicksRequired = 2
        v.addGestureRecognizer(g)
        return v
    }

    func updateNSView(_ v: SCNView, context: Context) {
        v.debugOptions = wireframe ? [.renderAsWireframe] : []
        if context.coordinator.token != resetToken {
            context.coordinator.token = resetToken
            context.coordinator.resetCamera()
        }
    }
}
