import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)  // thème sombre
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in Library.shared.importURLs(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@MainActor
func presentAddPanel() {
    let panel = NSOpenPanel()
    panel.title = "Ajouter des créations 3D"
    panel.message = "Choisissez des fichiers 3D ou des dossiers entiers."
    panel.prompt = "Ajouter"
    panel.canChooseFiles = true
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = true
    panel.allowedContentTypes = ModelFormat.byExtension.keys.sorted().compactMap { UTType(filenameExtension: $0) }
    if panel.runModal() == .OK { Library.shared.importURLs(panel.urls) }
}

@main
struct View3DApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var library = Library.shared

    var body: some Scene {
        Window("View 3D", id: "main") {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 1000, minHeight: 620)
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 1320, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Ajouter des créations…") { presentAddPanel() }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .textEditing) {
                Button("Rechercher") { library.searchFocusTick += 1 }
                    .keyboardShortcut("f")
            }
            CommandGroup(after: .newItem) {
                Divider()
                Button("Afficher dans le Finder") {
                    if let it = library.item(library.selection) { library.revealInFinder(it) }
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(library.selection == nil)
                Button("Ouvrir avec l'application par défaut") {
                    if let it = library.item(library.selection) { library.openFile(it) }
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(library.selection == nil)
                Button("Retirer de la bibliothèque") {
                    let ids = library.multi.isEmpty ? Set([library.selection].compactMap { $0 }) : library.multi
                    library.remove(ids)
                }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(library.selection == nil)
            }
        }
    }
}
