import AppKit
import Observation
import UniformTypeIdentifiers

/// Tracks and, on request, claims the default-application role for `.icon`
/// bundles.
///
/// **Not currently wired to any UI.** This is parked for the planned Settings
/// window, where "make IconBuilder the default for .icon files" belongs next to
/// the app's other preferences. Until then IconBuilder only *offers* itself:
/// declaring the document type in Info.plist puts it in Finder's "Open With"
/// list, and Icon Composer — the type's owner — stays the default.
///
/// It is verified working: `makeDefault()` triggers Apple's own
/// "Do you want all documents with the extension .icon to open with…?"
/// confirmation, and succeeds from inside the app sandbox. That system prompt
/// is why nothing here may run on its own — a call made without the user asking
/// puts a dialog on screen that they did not initiate.
@MainActor
@Observable
final class IconTypeAssociation {
    static let shared = IconTypeAssociation()

    /// Apple's own identifier for the bundle. Note the absence of a hyphen —
    /// `com.apple.icon-composer.icon` is not a type the system knows.
    static let iconType = UTType("com.apple.iconcomposer.icon")

    private(set) var isDefault = false
    private(set) var currentHandlerName: String?
    private(set) var lastError: String?

    private init() {
        refresh()
    }

    func clearError() {
        lastError = nil
    }

    /// Re-read who currently owns the type. Cheap; call it when showing UI.
    func refresh() {
        guard let type = Self.iconType,
              let handler = NSWorkspace.shared.urlForApplication(toOpen: type) else {
            isDefault = false
            currentHandlerName = nil
            return
        }
        currentHandlerName = FileManager.default.displayName(atPath: handler.path)
        // Compare resolved paths: the running app may be reached through a
        // symlink or a relocated copy.
        isDefault = handler.resolvingSymlinksInPath() == Bundle.main.bundleURL.resolvingSymlinksInPath()
    }

    /// Ask LaunchServices to make this copy of IconBuilder the default handler.
    /// Only ever called from an explicit user action.
    func makeDefault() async {
        lastError = nil
        guard let type = Self.iconType else {
            lastError = "macOS does not recognise the Icon Composer document type on this Mac."
            return
        }
        do {
            try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL,
                                                               toOpen: type)
        } catch {
            lastError = error.localizedDescription
        }
        refresh()
        // macOS puts up its own confirmation prompt for this change. Declining
        // it is reported exactly like success — no error, binding unmoved — so
        // this cannot be treated as a failure. Staying silent is right: the
        // user just said no, and telling them so would be noise.
    }
}
