import SwiftUI
import AppKit
import ShapeEditingUI

@main
struct IconBuilderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()
    @State private var library = ProjectLibrary.shared

    var body: some Scene {
        WindowGroup {
            ContentView(model: model)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { AppDelegate.sharedModel = model }
                .onOpenURL { url in model.requestOpen(url: url) }
        }
        .commands {
            IconBuilderHelpCommands()
            ShapeEditorCommands()
            ShapeEditorWorkspaceCommands()
            RecentDocumentCommands()
            CommandGroup(replacing: .newItem) {
                Button("New Icon") { model.newDocument() }
                    .keyboardShortcut("n", modifiers: .command)

                Button("Import .icon…") { openIcon() }
                    .keyboardShortcut("o", modifiers: .command)

                Menu("IconBuilder Library") {
                    if library.projects.isEmpty {
                        Text("No projects yet")
                    } else {
                        ForEach(library.projects) { entry in
                            Button(entry.name) { model.openProject(entry) }
                        }
                    }
                }
            }
            CommandGroup(replacing: .saveItem) {
                // ⌘S keeps its muscle memory but is no longer the thing that
                // persists work — autosave already did. It writes back out.
                Button {
                    model.requirePro { model.saveBackToOrigin() }
                } label: {
                    HStack { Text("Save Back to Icon Composer"); ProBadge() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(model.document == nil || !model.hasOrigin)

                Button {
                    model.requirePro { exportEditableIcon() }
                } label: {
                    HStack { Text("Export Editable .icon…"); ProBadge() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(model.document == nil)
            }
            CommandGroup(after: .saveItem) {
                Button("Export PDF…") {
                    model.presentExport = .pdf
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(model.document == nil)

                Button("Export PNG…") {
                    model.presentExport = .png
                }
                .keyboardShortcut("e", modifiers: [.command, .option])
                .disabled(model.document == nil)

                Button("Export Print-Ready PDF…") {
                    model.presentExport = .print
                }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(model.document == nil)
            }
            CommandGroup(after: .appInfo) {
                Button("IconBuilder Pro…") { model.presentPaywall = .informational }
            }
            CommandGroup(replacing: .pasteboard) {
                Button("Cut") {}
                    .keyboardShortcut("x", modifiers: .command)
                    .disabled(true)

                Button("Copy") { model.copySelection() }
                    .keyboardShortcut("c", modifiers: .command)
                    .disabled(!model.canCopySelection)

                Button("Paste") { model.pasteLayers() }
                    .keyboardShortcut("v", modifiers: .command)
                    .disabled(!model.canPasteLayers)
            }
            CommandMenu("Icon") {
                Button("New Empty Layer") { model.addEmptyLayer() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                    .disabled(model.document == nil)

                Button("Add Group") { model.addGroup() }
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                    .disabled(model.document == nil)

                Button("Duplicate Layer") { model.duplicateSelection() }
                    .keyboardShortcut("d", modifiers: .command)
                    .disabled(!model.canDuplicateSelection)
            }
        }

        Window("Getting Started", id: "onboarding") {
            IconBuilderOnboardingView()
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)

        Window("IconBuilder Documentation", id: "documentation") {
            IconBuilderDocumentationView()
        }
        .defaultSize(width: 900, height: 650)
    }

    /// Save panel for a standalone `.icon` bundle copy. Only reached once the
    /// Pro gate has already been cleared.
    private func exportEditableIcon() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(model.displayName).icon"
        panel.message = "Save an editable .icon bundle"
        panel.prompt = "Export"
        if panel.runModal() == .OK, let url = panel.url {
            model.exportEditableIcon(to: url)
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
            model.requestOpen(url: url)
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
            model.requestOpen(url: url)
        } else {
            AppDelegate.pendingOpenURL = url
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = Self.sharedModel else { return .terminateNow }
        return model.confirmDiscardingChanges(action: "quitting IconBuilder",
                                              markDiscarded: true)
            ? .terminateNow : .terminateCancel
    }
}

/// Which export sheet to present, if any.
enum ExportKind: Int, Identifiable { case pdf, png, print; var id: Int { rawValue } }
