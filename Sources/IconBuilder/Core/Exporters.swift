import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

enum Exporters {

    private static let maximumRasterDimension = 8_192

    /// Render the icon to a vector PDF. Fills are emitted in DeviceCMYK when
    /// `options.cmyk` is set, so the file is print-ready. Paths and gradients
    /// stay vector; disable `options.effects` for a fully clean separation.
    static func exportPDF(_ doc: IconDocument, to url: URL,
                                 pointSize: CGFloat, options: RenderOptions) throws {
        guard pointSize.isFinite, pointSize >= 1, pointSize <= 16_384 else {
            throw ExportError.invalidOptions("PDF size must be between 1 and 16,384 points.")
        }
        var pdfOptions = options
        pdfOptions.vectorPDF = true
        var mediaBox = CGRect(x: 0, y: 0, width: pointSize, height: pointSize)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.contextCreationFailed
        }
        ctx.beginPDFPage(nil)
        IconRenderer.render(doc, into: ctx, size: pointSize, options: pdfOptions)
        ctx.endPDFPage()
        ctx.closePDF()
    }

    /// Render to an in-memory PDF (e.g. for a SwiftUI preview via PDFKit).
    static func pdfData(_ doc: IconDocument, pointSize: CGFloat,
                               options: RenderOptions) -> Data? {
        guard pointSize.isFinite, pointSize >= 1, pointSize <= 16_384 else { return nil }
        var pdfOptions = options
        pdfOptions.vectorPDF = true
        let data = NSMutableData()
        var mediaBox = CGRect(x: 0, y: 0, width: pointSize, height: pointSize)
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        ctx.beginPDFPage(nil)
        IconRenderer.render(doc, into: ctx, size: pointSize, options: pdfOptions)
        ctx.endPDFPage()
        ctx.closePDF()
        return data as Data
    }

    /// Rasterize to a Display P3 CGImage, matching Icon Composer's PNG output.
    static func rasterize(_ doc: IconDocument, pixelSize: Int,
                                 options: RenderOptions) -> CGImage? {
        guard (1...maximumRasterDimension).contains(pixelSize) else { return nil }
        let space = CGColorSpace(name: CGColorSpace.displayP3)!
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
    static func exportPNG(_ doc: IconDocument, to url: URL, pixelSize: Int,
                                 options: RenderOptions) throws {
        guard (1...maximumRasterDimension).contains(pixelSize) else {
            throw ExportError.invalidOptions("PNG size must be between 1 and 8,192 pixels.")
        }
        guard let image = rasterize(doc, pixelSize: pixelSize, options: options) else {
            throw ExportError.contextCreationFailed
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ExportError.contextCreationFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { throw ExportError.writeFailed }
    }

    enum ExportError: Error, CustomStringConvertible {
        case contextCreationFailed
        case writeFailed
        case cutContourFailed
        case artworkPNGFailed
        case invalidOptions(String)
        var description: String {
            switch self {
            case .contextCreationFailed: return "Could not create the graphics context."
            case .writeFailed: return "Could not write the output file."
            case .cutContourFailed: return "Could not add the CutContour spot-color layer to the PDF."
            case .artworkPNGFailed: return "Could not read the artwork PNG."
            case .invalidOptions(let message): return message
            }
        }
    }

    // MARK: - Print-ready export

    /// Options for a print-ready PDF: physical size, bleed, die-cut line.
    struct PrintOptions: Sendable {
        /// Finished (cut) icon size in millimetres.
        var targetSizeMM: Double
        /// Bleed added on every side, in millimetres.
        var bleedMM: Double
        /// Raster resolution used when `flatten` is on. Vector output ignores it.
        var dpi: Double
        /// Rasterize the artwork to a CMYK bitmap at `dpi` (some print shops
        /// require flattened files). The cut line stays vector either way.
        var flatten: Bool
        /// Draw the die-cut contour (100% magenta hairline on top).
        var cutLine: Bool
        /// Export artwork in sRGB instead of CMYK (for print services that
        /// prefer RGB input and convert with their own profiles). The
        /// CutContour spot color keeps its CMYK alternate either way.
        var rgb: Bool
        /// Optional Icon Composer PNG export placed over the trim area, for a
        /// pixel-exact match with Apple's own render. The vector artwork still
        /// fills the bleed; the seam falls on the cut line. Raster in the trim
        /// area at the PNG's native resolution.
        var artworkPNGURL: URL?

        init(targetSizeMM: Double = 50, bleedMM: Double = 3, dpi: Double = 300,
                    flatten: Bool = false, cutLine: Bool = true, rgb: Bool = false,
                    artworkPNGURL: URL? = nil) {
            self.targetSizeMM = targetSizeMM
            self.bleedMM = bleedMM
            self.dpi = dpi
            self.flatten = flatten
            self.cutLine = cutLine
            self.rgb = rgb
            self.artworkPNGURL = artworkPNGURL
        }

        static let mmToPt = 72.0 / 25.4

        var pageSizeMM: Double { targetSizeMM + 2 * bleedMM }
        var targetSizePt: CGFloat { CGFloat(targetSizeMM * Self.mmToPt) }
        var bleedPt: CGFloat { CGFloat(bleedMM * Self.mmToPt) }
        var pageSizePt: CGFloat { CGFloat(pageSizeMM * Self.mmToPt) }
    }

    /// Write a print-ready PDF: page = target + bleed, artwork bleeding to
    /// the page edge, PDF TrimBox on the finished size, and a CutContour
    /// die-cut contour. Artwork color is CMYK unless `print.rgb` selects sRGB.
    static func exportPrintPDF(_ doc: IconDocument, to url: URL,
                                      print p: PrintOptions, options: RenderOptions) throws {
        guard p.targetSizeMM.isFinite, p.targetSizeMM > 0,
              p.bleedMM.isFinite, p.bleedMM >= 0,
              p.dpi.isFinite, p.dpi > 0,
              p.pageSizeMM.isFinite, p.pageSizeMM > 0 else {
            throw ExportError.invalidOptions(
                "Print size and resolution must be finite positive values; bleed cannot be negative."
            )
        }

        var opts = options
        opts.cmyk = !p.rgb
        opts.clipToMask = true
        opts.vectorPDF = !p.flatten

        let S = p.targetSizePt          // finished size
        let b = p.bleedPt               // bleed per side
        let P = p.pageSizePt            // page (media) size

        var mediaBox = CGRect(x: 0, y: 0, width: P, height: P)
        var trimBox = CGRect(x: b, y: b, width: S, height: S)
        var bleedBox = mediaBox

        func boxData(_ rect: inout CGRect) -> CFData {
            Data(bytes: &rect, count: MemoryLayout<CGRect>.size) as CFData
        }
        let pageInfo: [CFString: Any] = [
            kCGPDFContextMediaBox: boxData(&mediaBox),
            kCGPDFContextBleedBox: boxData(&bleedBox),
            kCGPDFContextTrimBox: boxData(&trimBox),
        ]

        let pdfData = NSMutableData()
        guard let consumer = CGDataConsumer(data: pdfData as CFMutableData),
              let ctx = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
            throw ExportError.contextCreationFailed
        }
        ctx.beginPDFPage(pageInfo as CFDictionary)

        // Optional pixel-exact Icon Composer artwork for the trim area.
        var overlay: CGImage?
        if let pngURL = p.artworkPNGURL {
            let secured = pngURL.startAccessingSecurityScopedResource()
            defer { if secured { pngURL.stopAccessingSecurityScopedResource() } }
            guard let image = loadImage(url: pngURL) else { throw ExportError.artworkPNGFailed }
            overlay = image
        }

        if p.flatten {
            // Flattened: a bitmap at the requested dpi covering the full page.
            let rawPixels = (p.pageSizeMM / 25.4 * p.dpi).rounded()
            guard rawPixels >= 1, rawPixels <= Double(maximumRasterDimension) else {
                throw ExportError.invalidOptions(
                    "Flattened artwork would be \(rawPixels.formatted()) pixels wide. Reduce the physical size or resolution to stay at or below \(maximumRasterDimension) pixels."
                )
            }
            let px = Int(rawPixels)
            if let image = rasterizePage(doc, pagePixels: px, bleedFraction: Double(b / P),
                                         options: opts, overlay: overlay) {
                ctx.draw(image, in: mediaBox)
            } else {
                throw ExportError.contextCreationFailed
            }
        } else {
            drawPrintArtwork(doc, into: ctx, trimSize: S, bleed: b, options: opts)
            if let overlay {
                drawArtworkOverlay(overlay, into: ctx,
                                   trimRect: CGRect(x: b, y: b, width: S, height: S),
                                   options: opts)
            }
        }

        ctx.endPDFPage()
        ctx.closePDF()

        var output = pdfData as Data
        if p.cutLine {
            // The die-cut contour as a `/Separation /CutContour` spot color on
            // its own PDF layer — the convention commercial print RIPs expect.
            // The mask path is symmetric, so PDF-native (bottom-up) coordinates
            // are equivalent to the renderer's.
            let contour = opts.recipe.maskPath(in: CGRect(x: b, y: b, width: S, height: S))
            guard let injected = PDFCutContour.inject(into: output, contour: contour,
                                                      lineWidth: 0.25) else {
                throw ExportError.cutContourFailed
            }
            output = injected
        }
        try output.write(to: url)
    }

    /// Draw the print artwork with seamless bleed.
    ///
    /// The icon's artwork exists beyond the cut line — the authoring canvas is
    /// square and the OS mask merely cuts it away — so the bleed shows the
    /// *actual* artwork continuation wherever possible:
    ///  1. clip to the mask contour expanded by the bleed,
    ///  2. draw the trim-size artwork unclipped (its square canvas covers the
    ///     corner bleed with true artwork, exactly aligned),
    ///  3. mirror the artwork across each canvas edge to fill the sliver of
    ///     bleed beyond the canvas (the mask flats touch the canvas edge) —
    ///     mirroring is color-continuous at the boundary, so no visible seam.
    private static func drawPrintArtwork(_ doc: IconDocument, into ctx: CGContext,
                                         trimSize S: CGFloat, bleed b: CGFloat,
                                         options: RenderOptions) {
        let P = S + 2 * b
        var art = options
        art.clipToMask = false   // clipping to the expanded contour happens here
        // Directional lighting/shadows must not render in the mirrored bleed
        // tiles — the mirror transform would flip them upside down.
        var mirrorArt = art
        mirrorArt.effects = false

        ctx.saveGState()
        // Expanded cut contour: the recipe mask over the full page rect. It
        // fully contains the trim mask and stays within the bleed everywhere.
        ctx.addPath(options.recipe.maskPath(in: CGRect(x: 0, y: 0, width: P, height: P)))
        ctx.clip()

        // Mirrored copies across the four canvas edges (and corners, for
        // completeness — squircle corners never reach them). Regions are
        // disjoint from the central square, so draw order is irrelevant.
        for dx in -1...1 {
            for dy in -1...1 where !(dx == 0 && dy == 0) {
                // Map local artwork u ∈ [0, S] per axis:
                //  d = 0  → b + u          (the canvas itself)
                //  d = -1 → b − u          (mirrored below/left of the edge)
                //  d = +1 → b + 2S − u     (mirrored above/right of the edge)
                func axis(_ d: Int) -> (scale: CGFloat, offset: CGFloat) {
                    switch d {
                    case -1: return (-1, b)
                    case 1: return (-1, b + 2 * S)
                    default: return (1, b)
                    }
                }
                let (ax, tx) = axis(dx)
                let (ay, ty) = axis(dy)
                ctx.saveGState()
                ctx.concatenate(CGAffineTransform(a: ax, b: 0, c: 0, d: ay, tx: tx, ty: ty))
                IconRenderer.render(doc, into: ctx, size: S, options: mirrorArt)
                ctx.restoreGState()
            }
        }

        // The exact artwork on the trim square, unclipped: inside the cut line
        // it is identical to the normal render; outside (canvas corners) it is
        // the true continuation of the design into the bleed.
        ctx.saveGState()
        ctx.translateBy(x: b, y: b)
        IconRenderer.render(doc, into: ctx, size: S, options: art)
        ctx.restoreGState()

        ctx.restoreGState()   // expanded contour clip
    }

    /// Load an image (PNG) via ImageIO.
    private static func loadImage(url: URL) -> CGImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Draw the Icon Composer PNG over the trim area.
    ///
    /// In CMYK mode the PNG is first flattened into the working CMYK space
    /// (through the ICC profile and intent when set) and clipped to the mask
    /// contour — the PNG's transparent corners must not cover the bleed, and
    /// any sub-pixel edge difference between Apple's mask and ours lands
    /// exactly on the cut line. In RGB mode the PNG draws directly with its
    /// own alpha.
    private static func drawArtworkOverlay(_ image: CGImage, into ctx: CGContext,
                                           trimRect: CGRect, options: RenderOptions) {
        ctx.saveGState()
        ctx.interpolationQuality = .high
        if options.cmyk {
            ctx.addPath(options.recipe.maskPath(in: trimRect))
            ctx.clip()
            if let converted = convertImageToCMYK(image, options: options) {
                ctx.draw(converted, in: trimRect)
            } else {
                ctx.draw(image, in: trimRect)   // CG converts at draw time
            }
        } else {
            ctx.draw(image, in: trimRect)
        }
        ctx.restoreGState()
    }

    /// Flatten an RGBA image into the working CMYK space (paper-white backed).
    private static func convertImageToCMYK(_ image: CGImage, options: RenderOptions) -> CGImage? {
        let space = ColorConvert.workingSpace(cmyk: true, profile: options.printProfile)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(CGColor(colorSpace: space, components: [0, 0, 0, 0, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.interpolationQuality = .high
        if let profile = options.printProfile {
            ctx.setRenderingIntent(profile.intent)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// Render the page (artwork + seamless bleed) into a bitmap of
    /// `pagePixels` × `pagePixels`, in CMYK or sRGB per `options.cmyk`.
    private static func rasterizePage(_ doc: IconDocument, pagePixels: Int,
                                      bleedFraction: Double, options: RenderOptions,
                                      overlay: CGImage? = nil) -> CGImage? {
        let space = ColorConvert.workingSpace(cmyk: options.cmyk, profile: options.printProfile)
        let bitmapInfo = options.cmyk
            ? CGImageAlphaInfo.none.rawValue                 // CMYK, no alpha
            : CGImageAlphaInfo.noneSkipLast.rawValue         // opaque RGB
        guard let ctx = CGContext(data: nil, width: pagePixels, height: pagePixels,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: space,
                                  bitmapInfo: bitmapInfo) else { return nil }
        ctx.interpolationQuality = .high
        // Paper white.
        let white = options.cmyk
            ? CGColor(colorSpace: space, components: [0, 0, 0, 0, 1])!
            : CGColor(colorSpace: space, components: [1, 1, 1, 1])!
        ctx.setFillColor(white)
        ctx.fill(CGRect(x: 0, y: 0, width: pagePixels, height: pagePixels))

        let P = CGFloat(pagePixels)
        let b = P * CGFloat(bleedFraction)
        drawPrintArtwork(doc, into: ctx, trimSize: P - 2 * b, bleed: b, options: options)
        if let overlay {
            drawArtworkOverlay(overlay, into: ctx,
                               trimRect: CGRect(x: b, y: b, width: P - 2 * b, height: P - 2 * b),
                               options: options)
        }
        return ctx.makeImage()
    }
}
