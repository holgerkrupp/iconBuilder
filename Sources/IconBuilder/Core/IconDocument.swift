import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A loaded `.icon` bundle: the parsed manifest plus its vector assets.
struct IconDocument: @unchecked Sendable {
    var url: URL
    var manifest: IconManifest
    /// image-name → parsed vector shape.
    var shapes: [String: SVGShape]
    /// image-name → raster asset (PNG/JPEG layers). CGImage is immutable.
    var images: [String: CGImage] = [:]
    /// Non-fatal asset problems found while loading the bundle.
    var warnings: [String] = []

    enum LoadError: Error, CustomStringConvertible {
        case notADirectory
        case missingManifest
        case badManifest(String)

        var description: String {
            switch self {
            case .notADirectory: return "The .icon is not a readable bundle directory."
            case .missingManifest: return "icon.json was not found inside the bundle."
            case .badManifest(let m): return "Could not parse icon.json: \(m)"
            }
        }
    }

    enum SaveError: Error, CustomStringConvertible {
        case unsafeAssetName(String)

        var description: String {
            switch self {
            case .unsafeAssetName(let name): return "The asset name is not safe to write: \(name)"
            }
        }
    }

    static func load(bundleURL: URL) throws -> IconDocument {
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

        // Load every referenced asset once: SVGs as vector shapes, everything
        // else (PNG/JPEG…) as raster images.
        let assetsDir = bundleURL.appendingPathComponent("Assets")
        var shapes: [String: SVGShape] = [:]
        var images: [String: CGImage] = [:]
        var warnings: [String] = []
        var attemptedAssets: Set<String> = []
        for group in manifest.groups {
            for layer in group.layers where !layer.imageName.isEmpty {
                let name = layer.imageName
                guard attemptedAssets.insert(name).inserted else { continue }
                guard URL(fileURLWithPath: name).lastPathComponent == name else {
                    warnings.append("Asset “\(name)” has an unsafe path and was not loaded.")
                    continue
                }
                let assetURL = assetsDir.appendingPathComponent(name)
                guard fm.fileExists(atPath: assetURL.path) else {
                    warnings.append("Asset “\(name)” is referenced by icon.json but is missing from Assets.")
                    continue
                }
                if name.lowercased().hasSuffix(".svg") {
                    if let shape = SVGShape.load(url: assetURL) {
                        shapes[name] = shape
                    } else {
                        warnings.append("Asset “\(name)” does not contain readable SVG geometry.")
                    }
                } else if let src = CGImageSourceCreateWithURL(assetURL as CFURL, nil),
                          let image = CGImageSourceCreateImageAtIndex(src, 0, nil) {
                    images[name] = image
                } else {
                    warnings.append("Asset “\(name)” is not a readable SVG, PNG, or JPEG image.")
                }
            }
        }
        return IconDocument(url: bundleURL, manifest: manifest, shapes: shapes,
                            images: images, warnings: warnings)
    }

    var displayName: String {
        url.deletingPathExtension().lastPathComponent
    }

    /// Persist the manifest and any SVG geometry changed by the editor.
    /// Unchanged source SVGs are deliberately left byte-for-byte intact.
    func save(modifiedShapes: [String: EditableShape] = [:],
              modifiedImages: [String: CGImage] = [:]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let manifestData = try encoder.encode(manifest)

        let assetsURL = url.appendingPathComponent("Assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        for (name, shape) in modifiedShapes {
            guard URL(fileURLWithPath: name).lastPathComponent == name,
                  name.lowercased().hasSuffix(".svg") else {
                throw SaveError.unsafeAssetName(name)
            }
            try shape.svgData.write(to: assetsURL.appendingPathComponent(name), options: .atomic)
        }
        for (name, image) in modifiedImages {
            guard URL(fileURLWithPath: name).lastPathComponent == name else {
                throw SaveError.unsafeAssetName(name)
            }
            let destinationURL = assetsURL.appendingPathComponent(name)
            guard let destination = CGImageDestinationCreateWithURL(
                destinationURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
                throw SaveError.unsafeAssetName(name)
            }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }
        try manifestData.write(to: url.appendingPathComponent("icon.json"), options: .atomic)
    }
}
