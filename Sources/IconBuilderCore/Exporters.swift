import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

public enum Exporters {

    /// Render the icon to a vector PDF. Fills are emitted in DeviceCMYK when
    /// `options.cmyk` is set, so the file is print-ready. Paths and gradients
    /// stay vector; disable `options.effects` for a fully clean separation.
    public static func exportPDF(_ doc: IconDocument, to url: URL,
                                 pointSize: CGFloat, options: RenderOptions) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: pointSize, height: pointSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.contextCreationFailed
        }
        ctx.beginPDFPage(nil)
        IconRenderer.render(doc, into: ctx, size: pointSize, options: options)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// Render to an in-memory PDF (e.g. for a SwiftUI preview via PDFKit).
    public static func pdfData(_ doc: IconDocument, pointSize: CGFloat,
                               options: RenderOptions) -> Data? {
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pointSize, height: pointSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)
        IconRenderer.render(doc, into: ctx, size: pointSize, options: options)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// Rasterize to a CGImage (sRGB) for on-screen preview.
    public static func rasterize(_ doc: IconDocument, pixelSize: Int,
                                 options: RenderOptions) -> CGImage? {
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        guard let ctx = CGContext(data: nil, width: pixelSize, height: pixelSize,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        ctx.interpolationQuality = .high
        IconRenderer.render(doc, into: ctx, size: CGFloat(pixelSize), options: options)
        return ctx.makeImage()
    }

    /// Write a PNG (used by the headless validation tool).
    public static func exportPNG(_ doc: IconDocument, to url: URL, pixelSize: Int,
                                 options: RenderOptions) throws {
        guard let image = rasterize(doc, pixelSize: pixelSize, options: options) else {
            throw ExportError.contextCreationFailed
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.contextCreationFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.writeFailed }
    }

    public enum ExportError: Error, CustomStringConvertible {
        case contextCreationFailed
        case writeFailed
        public var description: String {
            switch self {
            case .contextCreationFailed: return "Could not create the graphics context."
            case .writeFailed: return "Could not write the output file."
            }
        }
    }
}
