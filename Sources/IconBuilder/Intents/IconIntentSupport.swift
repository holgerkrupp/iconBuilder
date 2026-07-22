import AppIntents
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum IconIntentError: Error, CustomLocalizedStringResourceConvertible {
    case projectNotFound(String)
    case loadFailed(String, String)
    case renderFailed(String)
    case exportFailed(String, String)
    case noOrigin(String)
    case notUnlocked

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .projectNotFound(let name):
            "“\(name)” is no longer in the IconBuilder library."
        case .loadFailed(let name, let reason):
            "Could not open “\(name)”: \(reason)"
        case .renderFailed(let name):
            "“\(name)” could not be rendered."
        case .exportFailed(let name, let reason):
            "Could not export “\(name)”: \(reason)"
        case .noOrigin(let name):
            """
            “\(name)” has no original document to save back to. It was never \
            imported from a file, or the original has moved. Open it in \
            IconBuilder and use Export Editable .icon… to choose a location.
            """
        case .notUnlocked:
            """
            Saving `.icon` files requires IconBuilder Pro, a one-time purchase. \
            Your work is still autosaved and safe — open IconBuilder and choose \
            Save Back to Icon Composer to unlock it.
            """
        }
    }
}

/// Every paid `.icon`-writing intent funnels through here so the entitlement
/// check can never be skipped by adding another write-back path.
enum ProGate {
    @MainActor
    static func requireUnlocked() async throws {
        let store = StoreManager.shared
        if store.isUnlocked { return }
        // The intent may be running in a freshly launched process where the
        // entitlement has not been read back from StoreKit yet.
        await store.refresh()
        guard store.isUnlocked else { throw IconIntentError.notUnlocked }
    }
}

/// Requests parked by intents that need the UI, for the window to pick up.
///
/// An `openAppWhenRun` intent can fire before any window exists, so it cannot
/// simply reach for `AppDelegate.sharedModel` — the request is stored here and
/// drained once `ContentView` appears.
@MainActor
@Observable
final class IconNavigator {
    static let shared = IconNavigator()

    private(set) var projectToOpen: UUID?
    private(set) var shouldShowPaywall = false

    private init() {}

    func requestOpen(projectID: UUID) {
        projectToOpen = projectID
        deliver()
    }

    func requestPaywall() {
        shouldShowPaywall = true
        deliver()
    }

    /// Apply any parked request to a live model. Called by the intents (in case
    /// the app was already running) and again when the window appears.
    func deliver() {
        guard let model = AppDelegate.sharedModel else { return }
        if let id = projectToOpen,
           let project = ProjectLibrary.shared.projects.first(where: { $0.id == id }) {
            projectToOpen = nil
            model.openProject(project)
        }
        if shouldShowPaywall {
            shouldShowPaywall = false
            model.presentPaywall = .informational
        }
    }
}

// MARK: - Shared rendering helpers

enum IntentRenderSupport {
    /// Load a project's working copy, first flushing any edits the open editor
    /// still has in memory so an automated export never lags the screen.
    @MainActor
    static func loadDocument(for project: LibraryProject) throws -> IconDocument {
        if let model = AppDelegate.sharedModel, model.project?.id == project.id {
            model.flushAutosave()
        }
        do {
            return try IconDocument.load(bundleURL: ProjectLibrary.shared.bundleURL(for: project))
        } catch {
            throw IconIntentError.loadFailed(project.name, String(describing: error))
        }
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Stamp a diagonal "IconBuilder Pro" banner across a free preview, so the
    /// preview intent stays genuinely useful without substituting for the paid
    /// PNG export.
    static func watermarked(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let text = "IconBuilder Pro" as NSString
        let size = max(12.0, Double(w) * 0.075)
        let font = CTFontCreateWithName("HelveticaNeue-Bold" as CFString, size, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: CGColor(red: 1, green: 1, blue: 1, alpha: 0.55),
        ]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text as String, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, [])

        ctx.saveGState()
        ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        ctx.rotate(by: -.pi / 6)
        ctx.setShadow(offset: .zero, blur: size * 0.25,
                      color: CGColor(red: 0, green: 0, blue: 0, alpha: 0.45))
        ctx.textPosition = CGPoint(x: -bounds.width / 2, y: -bounds.height / 2)
        CTLineDraw(line, ctx)
        ctx.restoreGState()
        return ctx.makeImage()
    }
}
