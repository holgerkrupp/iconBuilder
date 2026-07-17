import Foundation
import CoreGraphics

/// Destructive Boolean operations shared with SymbolBuilder's shape editor.
public enum ShapeBooleanOperation: String, CaseIterable, Identifiable, Sendable {
    case union
    case subtract
    case intersect
    case exclude

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .union: return "Union"
        case .subtract: return "Subtract"
        case .intersect: return "Intersect"
        case .exclude: return "Exclude Overlap"
        }
    }

    public var helpText: String {
        switch self {
        case .union: return "Merge all selected shapes into one outline."
        case .subtract: return "Cut the shapes in front out of the backmost selected shape."
        case .intersect: return "Keep only the area shared by every selected shape."
        case .exclude: return "Merge the shapes while removing overlapping areas."
        }
    }

    public func apply(_ left: CGPath, _ right: CGPath) -> CGPath {
        switch self {
        case .union: return left.union(right)
        case .subtract: return left.subtracting(right)
        case .intersect: return left.intersection(right)
        case .exclude: return left.symmetricDifference(right)
        }
    }
}
