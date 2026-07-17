import SwiftUI
import AppKit
import IconBuilderCore

@main
struct IconBuilderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { AppDelegate.sharedModel = model }
                .onOpenURL { url in model.open(url: url) }
        }
        .commands {
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { model.undo() }
                    .keyboardShortcut("z", modifiers: .command)
                    .disabled(!model.canUndo)
                Button("Redo") { model.redo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
                    .disabled(!model.canRedo)
            }
            CommandGroup(replacing: .newItem) {
                Button("Open .icon…") { openIcon() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.save() }
                    .keyboardShortcut("s", modifiers: .command)
                    .disabled(model.document == nil || !model.isDirty)
            }
            CommandGroup(after: .saveItem) {
                Button("Export PDF…") { model.presentExport = .pdf }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.document == nil)
                Button("Export PNG…") { model.presentExport = .png }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                    .disabled(model.document == nil)
                Button("Export Print-Ready PDF…") { model.presentExport = .print }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(model.document == nil)
            }
        }
    }

    private func openIcon() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose an Apple .icon bundle"
        panel.prompt = "Open"
        if panel.runModal() == .OK, let url = panel.url {
            model.open(url: url)
        }
    }
}

/// Ensures the app becomes a regular, focused GUI app even when launched via
/// `swift run` from the command line, and routes open-file launch events
/// (Finder double-click / a path passed as an argument once Launch Services
/// knows we claim `.icon` — without this handler AppKit turns the launch into
/// an unfulfilled open-document request and SwiftUI never creates a window).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Set by the App on creation so open-file events can reach the model.
    static weak var sharedModel: AppModel?
    /// URL delivered before the model/window existed; consumed by onAppear.
    static var pendingOpenURL: URL?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        if let model = AppDelegate.sharedModel {
            model.open(url: url)
        } else {
            AppDelegate.pendingOpenURL = url
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

/// Which export sheet to present, if any.
enum ExportKind: Int, Identifiable { case pdf, png, print; var id: Int { rawValue } }
