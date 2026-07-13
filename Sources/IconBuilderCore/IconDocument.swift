import Foundation
import CoreGraphics

/// A loaded `.icon` bundle: the parsed manifest plus its vector assets.
public struct IconDocument: Sendable {
    public var url: URL
    public var manifest: IconManifest
    /// image-name → parsed vector shape.
    public var shapes: [String: SVGShape]

    public enum LoadError: Error, CustomStringConvertible {
        case notADirectory
        case missingManifest
        case badManifest(String)

        public var description: String {
            switch self {
            case .notADirectory: return "The .icon is not a readable bundle directory."
            case .missingManifest: return "icon.json was not found inside the bundle."
            case .badManifest(let m): return "Could not parse icon.json: \(m)"
            }
        }
    }

    public static func load(bundleURL: URL) throws -> IconDocument {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: bundleURL.path, isDirectory: &isDir), isDir.boolValue else {
            throw LoadError.notADirectory
        }
        let manifestURL = bundleURL.appendingPathComponent("icon.json")
        guard let data = try? Data(contentsOf: manifestURL) else { throw LoadError.missingManifest }
        let manifest: IconManifest
        do {
            manifest = try JSONDecoder().decode(IconManifest.self, from: data)
        } catch {
            throw LoadError.badManifest(String(describing: error))
        }

        // Load every referenced asset once.
        let assetsDir = bundleURL.appendingPathComponent("Assets")
        var shapes: [String: SVGShape] = [:]
        for group in manifest.groups {
            for layer in group.layers where !layer.imageName.isEmpty {
                if shapes[layer.imageName] != nil { continue }
                let svgURL = assetsDir.appendingPathComponent(layer.imageName)
                if let shape = SVGShape.load(url: svgURL) {
                    shapes[layer.imageName] = shape
                }
            }
        }
        return IconDocument(url: bundleURL, manifest: manifest, shapes: shapes)
    }

    public var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }
}
