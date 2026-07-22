import AppIntents
import Foundation

/// A project in the IconBuilder library, as seen by Shortcuts, Spotlight and Siri.
struct IconProjectEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: "Icon Project",
        numericFormat: "\(placeholder: .int) icon projects")

    static let defaultQuery = IconProjectEntityQuery()

    var id: UUID
    @Property(title: "Name") var name: String
    @Property(title: "Imported") var importedAt: Date
    @Property(title: "Last Modified") var modifiedAt: Date
    @Property(title: "Original Location") var originPath: String?

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "Edited \(modifiedAt.formatted(date: .abbreviated, time: .shortened))",
            image: .init(systemName: "app.dashed"))
    }

    init(project: LibraryProject) {
        self.id = project.id
        self.name = project.name
        self.importedAt = project.importedAt
        self.modifiedAt = project.modifiedAt
        self.originPath = project.originPath
    }

    /// Resolve back to the stored project. Intents hold the entity rather than a
    /// `LibraryProject`, which would go stale across the entity round trip.
    @MainActor
    func resolveProject() throws -> LibraryProject {
        ProjectLibrary.shared.reload()
        guard let project = ProjectLibrary.shared.projects.first(where: { $0.id == id }) else {
            throw IconIntentError.projectNotFound(name)
        }
        return project
    }
}

struct IconProjectEntityQuery: EntityQuery, EntityStringQuery, EnumerableEntityQuery {

    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [IconProjectEntity] {
        let wanted = Set(identifiers)
        ProjectLibrary.shared.reload()
        return ProjectLibrary.shared.projects
            .filter { wanted.contains($0.id) }
            .map(IconProjectEntity.init(project:))
    }

    /// Powers "the Up Next icon" in Siri and the Shortcuts picker's search field.
    @MainActor
    func entities(matching string: String) async throws -> [IconProjectEntity] {
        ProjectLibrary.shared.reload()
        return ProjectLibrary.shared.projects
            .filter { $0.name.localizedCaseInsensitiveContains(string) }
            .map(IconProjectEntity.init(project:))
    }

    @MainActor
    func allEntities() async throws -> [IconProjectEntity] {
        ProjectLibrary.shared.reload()
        return ProjectLibrary.shared.projects.map(IconProjectEntity.init(project:))
    }

    @MainActor
    func suggestedEntities() async throws -> [IconProjectEntity] {
        // ProjectLibrary already sorts most-recently-edited first.
        ProjectLibrary.shared.reload()
        return Array(ProjectLibrary.shared.projects.prefix(10))
            .map(IconProjectEntity.init(project:))
    }
}

// MARK: - Parameter enums

extension Appearance: AppEnum {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Appearance")

    static let caseDisplayRepresentations: [Appearance: DisplayRepresentation] = [
        .light: "Light",
        .dark: "Dark",
        .tinted: "Tinted",
        .clear: "Clear",
    ]
}

/// The rendering recipes exposed to Shortcuts. `Recipe` itself is a struct of
/// tunable values, so automations pick a preset by name rather than a value.
enum IconRecipeChoice: String, AppEnum {
    case iOS26
    case iOS27
    case watchOS

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Recipe")

    static let caseDisplayRepresentations: [IconRecipeChoice: DisplayRepresentation] = [
        .iOS26: "iOS 26",
        .iOS27: "iOS 27",
        .watchOS: "watchOS",
    ]

    var recipe: Recipe {
        switch self {
        case .iOS26: .iOS26
        case .iOS27: .iOS27
        case .watchOS: .watchOS
        }
    }
}
