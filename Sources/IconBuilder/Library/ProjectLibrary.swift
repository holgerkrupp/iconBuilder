import Foundation
import Observation

/// One project in the internal IconBuilder library.
///
/// A project owns a private working copy of a `.icon` bundle. All editing and
/// autosaving happens on that copy, which is why editing never touches — and
/// never risks — the user's original document. `origin` remembers where the
/// bundle was imported from so Pro users can write the work back to it.
struct LibraryProject: Identifiable, Codable, Hashable {
    var id: UUID
    /// Bundle name without the `.icon` extension.
    var name: String
    /// Security-scoped bookmark of the imported original, if there was one.
    var originBookmark: Data?
    /// Last known path of the original — for display only, never for writing.
    var originPath: String?
    var importedAt: Date
    var modifiedAt: Date

    var bundleName: String { "\(name).icon" }
}

/// The on-disk library of working copies in Application Support.
///
/// Layout: `…/IconBuilder/Projects/<uuid>/project.json` alongside
/// `…/<uuid>/<Name>.icon/`. Keeping each project in its own directory means a
/// project can be deleted or recovered as a unit, and two imports of icons with
/// the same name don't collide.
@MainActor
@Observable
final class ProjectLibrary {
    static let shared = ProjectLibrary()

    private(set) var projects: [LibraryProject] = []

    /// Project to reopen on the next launch — the basis for crash recovery.
    private static let lastProjectDefaultsKey = "lastOpenProjectID"

    private let fm = FileManager.default

    private init() {
        reload()
    }

    // MARK: Locations

    var rootURL: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("IconBuilder/Projects", isDirectory: true)
    }

    func directoryURL(for project: LibraryProject) -> URL {
        rootURL.appendingPathComponent(project.id.uuidString, isDirectory: true)
    }

    /// The working copy the editor reads and autosaves.
    func bundleURL(for project: LibraryProject) -> URL {
        directoryURL(for: project).appendingPathComponent(project.bundleName, isDirectory: true)
    }

    private func metadataURL(for id: UUID) -> URL {
        rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
            .appendingPathComponent("project.json")
    }

    // MARK: Listing

    func reload() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entries = (try? fm.contentsOfDirectory(at: rootURL,
                                                   includingPropertiesForKeys: nil)) ?? []
        projects = entries.compactMap { dir -> LibraryProject? in
            guard let id = UUID(uuidString: dir.lastPathComponent),
                  let data = try? Data(contentsOf: metadataURL(for: id)),
                  let project = try? decoder.decode(LibraryProject.self, from: data)
            else { return nil }
            return project
        }
        .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    // MARK: Importing

    enum LibraryError: Error, CustomStringConvertible {
        case notAnIconBundle
        case originUnavailable

        var description: String {
            switch self {
            case .notAnIconBundle:
                return "That folder is not a readable .icon bundle."
            case .originUnavailable:
                return "The original document could not be found. Move it back, or use “Export Editable .icon…” to choose a new location."
            }
        }
    }

    /// Copy an external `.icon` bundle into the library and return the project.
    ///
    /// The caller is responsible for having started security-scoped access on
    /// `url`; the bookmark taken here is what lets a later save-back reach the
    /// original after a relaunch.
    func importIcon(from url: URL) throws -> LibraryProject {
        guard fm.fileExists(atPath: url.appendingPathComponent("icon.json").path) else {
            throw LibraryError.notAnIconBundle
        }
        let now = Date()
        var project = LibraryProject(
            id: UUID(),
            name: url.deletingPathExtension().lastPathComponent,
            originBookmark: try? url.bookmarkData(options: .withSecurityScope,
                                                  includingResourceValuesForKeys: nil,
                                                  relativeTo: nil),
            originPath: url.path,
            importedAt: now,
            modifiedAt: now
        )
        let directory = directoryURL(for: project)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.copyItem(at: url, to: bundleURL(for: project))
        try write(&project)
        reload()
        return project
    }

    /// Create an empty project — a bundle with one empty group and no assets.
    ///
    /// It has no origin: there is no external document to save back to until
    /// the user picks one with “Export Editable .icon…”.
    func createProject(named name: String) throws -> LibraryProject {
        let now = Date()
        var project = LibraryProject(
            id: UUID(),
            name: uniqueName(base: name),
            originBookmark: nil,
            originPath: nil,
            importedAt: now,
            modifiedAt: now
        )
        let bundle = bundleURL(for: project)
        try fm.createDirectory(at: bundle.appendingPathComponent("Assets", isDirectory: true),
                               withIntermediateDirectories: true)
        let document = IconDocument(url: bundle,
                                    manifest: IconManifest(groups: [IconGroup()]),
                                    shapes: [:])
        try document.save()
        try write(&project)
        reload()
        return project
    }

    /// “Untitled”, then “Untitled 2”… so the library list stays readable.
    private func uniqueName(base: String) -> String {
        let taken = Set(projects.map(\.name))
        guard taken.contains(base) else { return base }
        var suffix = 2
        while taken.contains("\(base) \(suffix)") { suffix += 1 }
        return "\(base) \(suffix)"
    }

    // MARK: Mutating

    /// Record that the working copy changed. Cheap enough to call on autosave.
    func touch(_ project: LibraryProject) {
        var updated = project
        updated.modifiedAt = Date()
        try? write(&updated)
        reload()
    }

    func delete(_ project: LibraryProject) {
        try? fm.removeItem(at: directoryURL(for: project))
        if lastOpenedProjectID == project.id { lastOpenedProjectID = nil }
        reload()
    }

    /// Point a project at a new original, so subsequent save-backs go there.
    func setOrigin(_ url: URL, for project: LibraryProject) {
        var updated = project
        updated.originBookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                       includingResourceValuesForKeys: nil,
                                                       relativeTo: nil)
        updated.originPath = url.path
        try? write(&updated)
        reload()
    }

    private func write(_ project: inout LibraryProject) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try fm.createDirectory(at: directoryURL(for: project), withIntermediateDirectories: true)
        try encoder.encode(project).write(to: metadataURL(for: project.id), options: .atomic)
    }

    // MARK: Origin resolution

    /// Resolve the imported original's current location.
    ///
    /// Returns the URL and whether security-scoped access was started — the
    /// caller must stop it when done.
    func resolveOrigin(for project: LibraryProject) -> (url: URL, secured: Bool)? {
        guard let bookmark = project.originBookmark else {
            guard let path = project.originPath else { return nil }
            let url = URL(fileURLWithPath: path)
            return fm.fileExists(atPath: url.path) ? (url, false) : nil
        }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bookmark,
                                 options: [.withSecurityScope, .withoutUI],
                                 relativeTo: nil,
                                 bookmarkDataIsStale: &stale),
              fm.fileExists(atPath: url.path)
        else { return nil }
        if stale { setOrigin(url, for: project) }
        return (url, url.startAccessingSecurityScopedResource())
    }

    // MARK: Recovery

    var lastOpenedProjectID: UUID? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: Self.lastProjectDefaultsKey)
            else { return nil }
            return UUID(uuidString: raw)
        }
        set {
            UserDefaults.standard.set(newValue?.uuidString, forKey: Self.lastProjectDefaultsKey)
        }
    }

    /// The project to restore on launch — after a normal quit or a crash alike.
    var projectToRecover: LibraryProject? {
        guard let id = lastOpenedProjectID else { return nil }
        return projects.first { $0.id == id }
    }

    /// Replace an external bundle's contents with the project's working copy.
    ///
    /// Written as a swap through a sibling temporary directory so an
    /// interrupted write can't leave the user's original half-updated.
    func copyWorkingCopy(of project: LibraryProject, to destination: URL) throws {
        let source = bundleURL(for: project)
        // Stage in the system replacement directory, not beside the
        // destination: the sandbox grants access to the file the user chose,
        // never to the folder around it, so a sibling temp is denied outright.
        // `appropriateFor:` keeps the staging copy on the destination's volume
        // so the swap below stays a rename.
        let stagingDirectory = try fm.url(for: .itemReplacementDirectory,
                                          in: .userDomainMask,
                                          appropriateFor: destination,
                                          create: true)
        defer { try? fm.removeItem(at: stagingDirectory) }
        let staging = stagingDirectory
            .appendingPathComponent(destination.lastPathComponent, isDirectory: true)
        try fm.copyItem(at: source, to: staging)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: destination)
        }
    }
}
