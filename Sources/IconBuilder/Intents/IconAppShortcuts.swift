import AppIntents

/// The phrases Spotlight and Siri offer without the user building a shortcut.
/// Every phrase must contain `${applicationName}`.
struct IconAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenIconProjectIntent(),
            phrases: [
                "Open an icon in \(.applicationName)",
                "Edit an \(.applicationName) project"
            ],
            shortTitle: "Open Project",
            systemImageName: "app.dashed")

        AppShortcut(
            intent: RenderIconPreviewIntent(),
            phrases: [
                "Preview an icon with \(.applicationName)",
                "Render an icon in \(.applicationName)"
            ],
            shortTitle: "Render Preview",
            systemImageName: "eye")

        AppShortcut(
            intent: ExportIconPDFIntent(),
            phrases: [
                "Export an icon as a PDF with \(.applicationName)",
                "Export a PDF from \(.applicationName)"
            ],
            shortTitle: "Export PDF",
            systemImageName: "doc.richtext")

        AppShortcut(
            intent: ExportIconPNGIntent(),
            phrases: [
                "Export an icon as a PNG with \(.applicationName)",
                "Export a PNG from \(.applicationName)"
            ],
            shortTitle: "Export PNG",
            systemImageName: "photo")

        AppShortcut(
            intent: ExportPrintReadyPDFIntent(),
            phrases: [
                "Export a print ready icon with \(.applicationName)",
                "Make a print PDF with \(.applicationName)"
            ],
            shortTitle: "Export Print PDF",
            systemImageName: "printer")

        AppShortcut(
            intent: SaveBackToIconComposerIntent(),
            phrases: [
                "Save an icon back to Icon Composer with \(.applicationName)",
                "Write back an \(.applicationName) project"
            ],
            shortTitle: "Save Back",
            systemImageName: "arrow.uturn.backward.square")
    }
}
