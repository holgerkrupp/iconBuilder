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
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open .icon…") { openIcon() }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandGroup(after: .saveItem) {
                Button("Export PDF…") { model.presentExport = .pdf }
                    .keyboardShortcut("e", modifiers: .command)
                    .disabled(model.document == nil)
                Button("Export PNG…") { model.presentExport = .png }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
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
/// `swift run` from the command line.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

/// Which export sheet to present, if any.
enum ExportKind: Identifiable { case pdf, png; var id: Int { self == .pdf ? 0 : 1 } }
