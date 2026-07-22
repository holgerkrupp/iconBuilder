import XCTest
import CoreGraphics
@testable import IconBuilder

final class ParserTests: XCTestCase {
    func testColorSpecParsing() {
        let c = ColorSpec(string: "srgb:0.0,0.5,1.0,1.0")
        XCTAssertNotNil(c)
        XCTAssertEqual(c?.space, .srgb)
        XCTAssertEqual(c?.b, 1.0)
        let p3 = ColorSpec(string: "display-p3:0.27,0.60,0.84,1.0")
        XCTAssertEqual(p3?.space, .displayP3)
    }

    func testCMYKConversionBlack() {
        let cmyk = ColorConvert.cmyk(ColorSpec(space: .srgb, r: 0, g: 0, b: 0, a: 1))
        XCTAssertEqual(cmyk.k, 1, accuracy: 0.0001)
    }

    func testCMYKConversionPureRed() {
        let cmyk = ColorConvert.cmyk(ColorSpec(space: .srgb, r: 1, g: 0, b: 0, a: 1))
        XCTAssertEqual(cmyk.k, 0, accuracy: 0.0001)
        XCTAssertEqual(cmyk.m, 1, accuracy: 0.0001)
        XCTAssertEqual(cmyk.y, 1, accuracy: 0.0001)
    }

    func testSVGPathParsesTriangle() {
        let d = "M0,0 L100,0 L50,100 Z"
        let path = SVGPathParser.path(fromData: d)
        XCTAssertFalse(path.boundingBoxOfPath.isNull)
        XCTAssertEqual(path.boundingBoxOfPath.width, 100, accuracy: 0.5)
    }

    func testSVGShapeParsesRect() {
        let svg = """
        <svg viewBox="0 0 1024 1024"><rect x="10" y="20" width="100" height="50"/></svg>
        """
        let shape = SVGShape.parse(data: Data(svg.utf8))
        XCTAssertNotNil(shape)
        XCTAssertEqual(shape?.viewBox.width, 1024)
    }

    func testMixedFillAndStrokeSVGRenderAsOneLayer() throws {
        let svg = """
        <svg viewBox="0 0 100 100">
          <path d="M50 15 L35 45 L15 50 L35 65 L30 90 L50 75 Z" fill="#fff"/>
          <path d="M50 15 L65 45 L85 50 L65 65 L70 90 L50 75"
                fill="none" stroke="#fff" stroke-width="8"
                stroke-linecap="round" stroke-linejoin="round"/>
        </svg>
        """
        let image = try renderSVG(svg, pixelSize: 100)

        XCTAssertGreaterThan(alpha(image, x: 50, y: 15), 150)
        XCTAssertGreaterThan(alpha(image, x: 82, y: 50), 150,
                             "the stroke-only half must remain visible")
    }

    func testSVGElementOpacitySurvivesLayerMaterialOverride() throws {
        let svg = """
        <svg viewBox="0 0 100 100">
          <rect width="100" height="100" style="fill-opacity:0.18"/>
        </svg>
        """
        let image = try renderSVG(svg, pixelSize: 100)
        let value = alpha(image, x: 50, y: 50)

        XCTAssertGreaterThan(value, 40)
        XCTAssertLessThan(value, 55)
    }

    func testSVGViewBoxMapsToAuthoringCanvas() throws {
        let svg = """
        <svg viewBox="0 0 24 24"><rect width="24" height="24"/></svg>
        """
        let image = try renderSVG(svg, pixelSize: 100)

        XCTAssertGreaterThan(alpha(image, x: 5, y: 5), 250)
        XCTAssertGreaterThan(alpha(image, x: 95, y: 95), 250)
    }

    private func renderSVG(_ svg: String, pixelSize: Int) throws -> CGImage {
        let shape = try XCTUnwrap(SVGShape.parse(data: Data(svg.utf8)))
        let white = ColorSpec(space: .srgb, r: 1, g: 1, b: 1, a: 1)
        let layer = Layer(name: "Shape", imageName: "shape.svg",
                          fill: Specialized(base: .solid(white)))
        let doc = IconDocument(url: URL(fileURLWithPath: "/tmp/svg-render.icon"),
                               manifest: IconManifest(groups: [IconGroup(layers: [layer])]),
                               shapes: ["shape.svg": shape])
        var options = RenderOptions(appearance: .light, recipe: .iOS26)
        options.effects = false
        options.background = false
        options.clipToMask = false
        return try XCTUnwrap(Exporters.rasterize(doc, pixelSize: pixelSize, options: options))
    }

    private func alpha(_ image: CGImage, x: Int, y: Int) -> UInt8 {
        let data = image.dataProvider!.data! as Data
        return data[y * image.bytesPerRow + x * 4 + 3]
    }

    func testManifestRoundTripKeepsEditableValues() throws {
        let json = """
        {
          "fill": { "linear-gradient": ["srgb:1,0,0,1", "display-p3:0,0,1,0.75"] },
          "groups": [{
            "blend-mode": "multiply",
            "blur-material-specializations": [{"appearance":"dark","value":null}],
            "refractivity": { "depth": 0.2, "strength": 0.7 },
            "layers": [{
              "name": "Shape", "image-name": "shape.svg",
              "fill-specializations": [{"appearance":"dark","value":{"solid":"srgb:0,1,0,1"}}],
              "opacity": 0.8
            }]
          }],
          "supported-platforms": {"circles":["watchOS"],"squares":"shared"}
        }
        """
        let decoded = try JSONDecoder().decode(IconManifest.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.groups[0].refractivity?.depth, 0.2)
        XCTAssertEqual(decoded.groups[0].refractivity?.enabled, false)
        XCTAssertEqual(decoded.groups[0].blurMaterial.value(for: .dark), BlurMaterial.none)
        XCTAssertEqual(decoded.groups[0].layers[0].opacity.base, 0.8)
        XCTAssertEqual(decoded.supportedPlatforms?.circles, ["watchOS"])

        let data = try JSONEncoder().encode(decoded)
        let roundTrip = try JSONDecoder().decode(IconManifest.self, from: data)
        XCTAssertEqual(roundTrip.fill, decoded.fill)
        XCTAssertEqual(roundTrip.groups[0].blendMode, "multiply")
        XCTAssertEqual(roundTrip.groups[0].blurMaterial.value(for: .dark), BlurMaterial.none)
        XCTAssertEqual(roundTrip.groups[0].layers[0].fill.value(for: .dark),
                       decoded.groups[0].layers[0].fill.value(for: .dark))
    }

    func testShapeSVGAndDocumentSave() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IconBuilder-save-\(UUID().uuidString).icon")
        let assets = root.appendingPathComponent("Assets")
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let untouched = assets.appendingPathComponent("untouched.svg")
        let original = Data("<svg viewBox=\"0 0 1 1\"><rect width=\"1\" height=\"1\"/></svg>".utf8)
        try original.write(to: untouched)

        let editable = EditableShape.starter(.star)
        let layer = Layer(name: "Star", imageName: "star.svg")
        let document = IconDocument(url: root,
                                    manifest: IconManifest(groups: [IconGroup(layers: [layer])]),
                                    shapes: ["star.svg": SVGShape(path: editable.path)])
        try document.save(modifiedShapes: ["star.svg": editable])

        XCTAssertEqual(try Data(contentsOf: untouched), original)
        let savedShape = try XCTUnwrap(SVGShape.load(url: assets.appendingPathComponent("star.svg")))
        XCTAssertEqual(savedShape.path.boundingBoxOfPath.width,
                       editable.path.boundingBoxOfPath.width, accuracy: 0.01)
        let savedManifest = try JSONDecoder().decode(
            IconManifest.self, from: Data(contentsOf: root.appendingPathComponent("icon.json")))
        XCTAssertEqual(savedManifest.groups[0].layers[0].imageName, "star.svg")
    }

    func testDocumentLoadReportsMissingAndUnsafeAssets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("IconBuilder-load-\(UUID().uuidString).icon")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: root) }

        let layers = [
            Layer(name: "Missing", imageName: "missing.svg"),
            Layer(name: "Unsafe", imageName: "../outside.svg"),
            // A duplicate reference should produce only one warning.
            Layer(name: "Missing again", imageName: "missing.svg"),
        ]
        let manifest = IconManifest(groups: [IconGroup(layers: layers)])
        try JSONEncoder().encode(manifest).write(
            to: root.appendingPathComponent("icon.json"), options: .atomic
        )

        let document = try IconDocument.load(bundleURL: root)

        XCTAssertEqual(document.warnings.count, 2)
        XCTAssertTrue(document.warnings.contains { $0.contains("missing from Assets") })
        XCTAssertTrue(document.warnings.contains { $0.contains("unsafe path") })
    }

    func testRasterExportRejectsUnsafeDimensions() throws {
        let document = IconDocument(
            url: URL(fileURLWithPath: "/tmp/empty.icon"),
            manifest: IconManifest(),
            shapes: [:]
        )

        XCTAssertNil(Exporters.rasterize(document, pixelSize: 0, options: RenderOptions()))
        XCTAssertNil(Exporters.rasterize(document, pixelSize: 8_193, options: RenderOptions()))

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("IconBuilder-invalid-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        XCTAssertThrowsError(try Exporters.exportPDF(
            document, to: output, pointSize: .infinity, options: RenderOptions()
        )) { error in
            guard case Exporters.ExportError.invalidOptions = error else {
                return XCTFail("Expected invalid options, got \(error)")
            }
        }
    }

    func testFlattenedPrintExportRejectsExcessivePixelDimensions() throws {
        let document = IconDocument(
            url: URL(fileURLWithPath: "/tmp/empty.icon"),
            manifest: IconManifest(),
            shapes: [:]
        )
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("IconBuilder-oversized-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: output) }
        let printOptions = Exporters.PrintOptions(
            targetSizeMM: 1_000, bleedMM: 0, dpi: 1_200, flatten: true
        )

        XCTAssertThrowsError(try Exporters.exportPrintPDF(
            document, to: output, print: printOptions, options: RenderOptions()
        )) { error in
            guard case Exporters.ExportError.invalidOptions = error else {
                return XCTFail("Expected invalid options, got \(error)")
            }
        }
    }

    func testShapeBooleanOperations() {
        let left = CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)
        let right = CGPath(rect: CGRect(x: 50, y: 0, width: 100, height: 100), transform: nil)

        let union = ShapeBooleanOperation.union.apply(left, right)
        XCTAssertTrue(union.contains(CGPoint(x: 25, y: 50)))
        XCTAssertTrue(union.contains(CGPoint(x: 125, y: 50)))

        let intersection = ShapeBooleanOperation.intersect.apply(left, right)
        XCTAssertFalse(intersection.contains(CGPoint(x: 25, y: 50)))
        XCTAssertTrue(intersection.contains(CGPoint(x: 75, y: 50)))

        let subtraction = ShapeBooleanOperation.subtract.apply(left, right)
        XCTAssertTrue(subtraction.contains(CGPoint(x: 25, y: 50)))
        XCTAssertFalse(subtraction.contains(CGPoint(x: 75, y: 50)))

        let exclusion = ShapeBooleanOperation.exclude.apply(left, right)
        XCTAssertTrue(exclusion.contains(CGPoint(x: 25, y: 50)))
        XCTAssertFalse(exclusion.contains(CGPoint(x: 75, y: 50)))
        XCTAssertTrue(exclusion.contains(CGPoint(x: 125, y: 50)))
    }

    func testQuickLineAndCurveShapesProduceFilledSVGGeometry() {
        for kind in [IconShapeKind.line, .curve] {
            let shape = EditableShape.starter(kind)
            XCTAssertFalse(shape.path.boundingBoxOfPath.isEmpty)
            XCTAssertNotNil(SVGShape.parse(data: shape.svgData))
        }
    }

    func testTextAndTransformMetadataRoundTripThroughSVG() throws {
        var original = EditableShape.starter(.text)
        original.text = "Icon Builder"
        original.fontName = "Helvetica-Bold"
        original.transformation = ShapeTransformation(rotationDegrees: 18,
                                                       skewXDegrees: 7,
                                                       perspectiveHorizontal: 0.3)

        let parsed = try XCTUnwrap(SVGShape.parse(data: original.svgData))
        let restored = EditableShape(shape: parsed)
        XCTAssertEqual(restored.kind, .text)
        XCTAssertEqual(restored.text, "Icon Builder")
        XCTAssertEqual(restored.fontName, "Helvetica-Bold")
        XCTAssertEqual(restored.transformation, original.transformation)
        XCTAssertEqual(restored.path.boundingBoxOfPath.width,
                       original.path.boundingBoxOfPath.width, accuracy: 0.01)
    }

    func testLayerReorderWithinAndAcrossGroups() {
        let a = Layer(name: "A", imageName: "a.svg")
        let b = Layer(name: "B", imageName: "b.svg")
        let c = Layer(name: "C", imageName: "c.svg")
        var manifest = IconManifest(groups: [IconGroup(layers: [a, b, c]), IconGroup()])

        let within = manifest.moveLayer(id: a.id, toGroup: 0, before: 2)
        XCTAssertEqual(within?.group, 0)
        XCTAssertEqual(within?.index, 1)
        XCTAssertEqual(manifest.groups[0].layers.map(\.name), ["B", "A", "C"])

        let across = manifest.moveLayer(id: a.id, toGroup: 1, before: 0)
        XCTAssertEqual(across?.group, 1)
        XCTAssertEqual(across?.index, 0)
        XCTAssertEqual(manifest.groups[0].layers.map(\.name), ["B", "C"])
        XCTAssertEqual(manifest.groups[1].layers.map(\.name), ["A"])
    }

    func testHiddenLayersAndGroupsAreExcludedFromRenderedExports() throws {
        let shape = SVGShape(path: CGPath(rect: CGRect(x: 0, y: 0, width: 1024, height: 1024),
                                          transform: nil))
        let visibleLayer = Layer(name: "Shape", imageName: "shape.svg",
                                 fill: Specialized(base: .solid(
                                    ColorSpec(space: .srgb, r: 1, g: 0, b: 0, a: 1))))
        var options = RenderOptions(appearance: .light, recipe: .iOS26)
        options.effects = false
        options.background = false
        options.clipToMask = false

        func centerAlpha(group: IconGroup) throws -> UInt8 {
            let doc = IconDocument(url: URL(fileURLWithPath: "/tmp/visibility.icon"),
                                   manifest: IconManifest(groups: [group]),
                                   shapes: ["shape.svg": shape])
            let image = try XCTUnwrap(Exporters.rasterize(doc, pixelSize: 32, options: options))
            let data = try XCTUnwrap(image.dataProvider?.data) as Data
            return data[16 * image.bytesPerRow + 16 * 4 + 3]
        }

        XCTAssertGreaterThan(try centerAlpha(group: IconGroup(layers: [visibleLayer])), 0)

        var hiddenLayer = visibleLayer
        hiddenLayer.hidden = true
        XCTAssertEqual(try centerAlpha(group: IconGroup(layers: [hiddenLayer])), 0)
        XCTAssertEqual(try centerAlpha(group: IconGroup(layers: [visibleLayer], hidden: true)), 0)
    }

    /// Regression test for the Icon Composer coordinate model, calibrated
    /// against Icon Composer 2.0 reference exports: center origin, Y-down,
    /// p' = (p − 512)·scale + translation, applied per layer then per group,
    /// with groups/layers listed topmost-first.
    func testCoordinateModelMatchesIconComposer() throws {
        let manifestJSON = """
        {
          "fill": "automatic",
          "groups": [
            {
              "layers": [
                {
                  "image-name": "bar.svg",
                  "name": "bar",
                  "fill": { "solid": "srgb:1.0,0.0,0.0,1.0" },
                  "position": { "scale": 1.05, "translation-in-points": [-387.4, 383.5] }
                }
              ],
              "position": { "scale": 1.02, "translation-in-points": [393.8, 514.0] }
            }
          ]
        }
        """
        let barSVG = """
        <svg viewBox="0 0 1024 1024"><rect x="2.3" y="0" width="1020.9" height="171.5"/></svg>
        """
        let manifest = try JSONDecoder().decode(IconManifest.self, from: Data(manifestJSON.utf8))
        let shape = try XCTUnwrap(SVGShape.parse(data: Data(barSVG.utf8)))
        let doc = IconDocument(url: URL(fileURLWithPath: "/tmp/x.icon"),
                               manifest: manifest, shapes: ["bar.svg": shape])
        var opts = RenderOptions(appearance: .light, recipe: .iOS26)
        opts.effects = false; opts.background = false; opts.clipToMask = false
        let img = try XCTUnwrap(Exporters.rasterize(doc, pixelSize: 1024, options: opts))

        // Expected bar top edge: ((0−512)·1.05 + 383.5)·1.02 + 514 + 512 ≈ 868.8
        // (matches the measured bottom-stripe seam at y≈865–869 in the
        // Icon Composer reference export).
        let data = try XCTUnwrap(img.dataProvider?.data) as Data
        let bpr = img.bytesPerRow
        func alpha(_ x: Int, _ y: Int) -> UInt8 { data[y * bpr + x * 4 + 3] }
        XCTAssertEqual(alpha(512, 850), 0, "above the bar top edge should be empty")
        XCTAssertGreaterThan(alpha(512, 890), 200, "below the bar top edge should be filled")
    }

    func testEditorLayerTransformMatchesFinalComposition() {
        let layer = Layer(name: "Shape", imageName: "shape.svg",
                          position: LayerPosition(scale: 0.7, translation: [-355, -516]))
        let group = IconGroup(layers: [layer],
                          position: LayerPosition(scale: 1.0, translation: [386, 506]))
        let transform = IconRenderer.layerCanvasTransform(layer: layer, group: group)

        // The SVG center becomes the accumulated layer + group translation,
        // then is recentered on the 1024-point output canvas.
        let center = CGPoint(x: 512, y: 512).applying(transform)
        XCTAssertEqual(center.x, 543, accuracy: 0.001)
        XCTAssertEqual(center.y, 502, accuracy: 0.001)

        // Editing uses the inverse transform to turn pointer positions back
        // into raw SVG coordinates.
        let roundTrip = center.applying(transform.inverted())
        XCTAssertEqual(roundTrip.x, 512, accuracy: 0.001)
        XCTAssertEqual(roundTrip.y, 512, accuracy: 0.001)
    }

    /// The print-ready export must produce a page of target+bleed size with a
    /// TrimBox on the finished size and a magenta die-cut stroke.
    func testPrintReadyPDFStructure() throws {
        let manifestJSON = """
        { "fill": "automatic", "groups": [ { "layers": [ {
            "image-name": "bar.svg", "name": "bar",
            "fill": { "solid": "srgb:1.0,0.0,0.0,1.0" },
            "position": { "scale": 1.0, "translation-in-points": [0, 0] }
        } ] } ] }
        """
        let barSVG = "<svg viewBox=\"0 0 1024 1024\"><rect x=\"0\" y=\"0\" width=\"1024\" height=\"1024\"/></svg>"
        let manifest = try JSONDecoder().decode(IconManifest.self, from: Data(manifestJSON.utf8))
        let shape = try XCTUnwrap(SVGShape.parse(data: Data(barSVG.utf8)))
        let doc = IconDocument(url: URL(fileURLWithPath: "/tmp/x.icon"),
                               manifest: manifest, shapes: ["bar.svg": shape])

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("printtest-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        var opts = RenderOptions(appearance: .light, recipe: .iOS26, cmyk: true)
        opts.effects = false
        let p = Exporters.PrintOptions(targetSizeMM: 50, bleedMM: 3)
        try Exporters.exportPrintPDF(doc, to: url, print: p, options: opts)

        // Die line structure: /Separation spot color named CutContour, carried
        // in an optional-content layer of the same name.
        let rawBytes = try Data(contentsOf: url)
        let raw = String(decoding: rawBytes, as: UTF8.self)
        XCTAssertTrue(raw.contains("/Separation /CutContour /DeviceCMYK"),
                      "CutContour spot colorspace missing")
        XCTAssertTrue(raw.contains("/Type /OCG /Name (CutContour)"),
                      "CutContour layer (OCG) missing")
        XCTAssertTrue(raw.contains("/OCProperties"), "layer registration missing")

        let pdf = try XCTUnwrap(CGPDFDocument(url as CFURL))
        XCTAssertEqual(pdf.numberOfPages, 1)
        let page = try XCTUnwrap(pdf.page(at: 1))

        // Page: (50 + 2·3) mm = 158.74 pt; TrimBox inset by the 8.5 pt bleed.
        let media = page.getBoxRect(.mediaBox)
        let trim = page.getBoxRect(.trimBox)
        XCTAssertEqual(media.width, 158.74, accuracy: 0.05)
        XCTAssertEqual(trim.minX, 8.504, accuracy: 0.05)
        XCTAssertEqual(trim.width, 141.73, accuracy: 0.05)

        // Rasterize at 4× and check actual ink:
        let scale: CGFloat = 4
        let px = Int(media.width * scale)
        let ctx = try XCTUnwrap(CGContext(data: nil, width: px, height: px,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                 components: [1, 1, 1, 1])!)
        ctx.fill(CGRect(x: 0, y: 0, width: px, height: px))
        ctx.scaleBy(x: scale, y: scale)
        ctx.drawPDFPage(page)
        let img = try XCTUnwrap(ctx.makeImage())
        let data = try XCTUnwrap(img.dataProvider?.data) as Data
        let bpr = img.bytesPerRow
        func rgb(_ x: Int, _ y: Int) -> (UInt8, UInt8, UInt8) {
            let o = (px - 1 - y) * bpr + x * 4   // flip to bottom-up PDF coords
            return (data[o], data[o + 1], data[o + 2])
        }

        // 1. Artwork center is the red icon fill.
        let center = rgb(px / 2, px / 2)
        XCTAssertGreaterThan(center.0, 150, "icon fill missing at center")
        XCTAssertLessThan(center.1, 120, "icon fill should be red")

        // 2. Bleed zone (left of the trim box, mid-height) carries artwork.
        let bleedPx = rgb(Int(4.0 * scale), px / 2)
        XCTAssertGreaterThan(bleedPx.0, 150, "bleed underlay missing")
        XCTAssertLessThan(bleedPx.1, 120, "bleed underlay should be red")

        // 3. Magenta die line crosses the trim edge at mid-height: scan a small
        //    window around x = trim.minX for a pixel with high R+B, low G.
        var foundMagenta = false
        let xc = Int(trim.minX * scale)
        for dx in -6...6 {
            let (r, g, b) = rgb(xc + dx, px / 2)
            // Magenta over the artwork: strong red, suppressed green, and a
            // clear blue lift relative to green.
            if r > 140 && g < 100 && b > g + 40 {
                foundMagenta = true; break
            }
        }
        XCTAssertTrue(foundMagenta, "magenta cut line not found at trim edge")
    }

    /// Quartz PDF gradients discard per-stop alpha. The PDF compatibility path
    /// must keep backdrop colors visible through a glass layer.
    func testPDFGlassRetainsBackdropTransparency() throws {
        let manifestJSON = """
        {
          "fill": { "solid": "srgb:1.0,0.0,0.0,1.0" },
          "groups": [
            {
              "translucency": { "enabled": true, "value": 0.5 },
              "specular": false,
              "layers": [ {
                "image-name": "glass.svg", "name": "glass", "glass": true,
                "opacity": 0.9,
                "fill": { "automatic-gradient": "srgb:0.0,1.0,1.0,1.0" }
              } ]
            },
            {
              "layers": [ {
                "image-name": "half.svg", "name": "half", "glass": false,
                "fill": { "solid": "srgb:0.0,0.0,1.0,1.0" }
              } ]
            }
          ]
        }
        """
        let fullSVG = "<svg viewBox=\"0 0 1024 1024\"><rect width=\"1024\" height=\"1024\"/></svg>"
        let halfSVG = "<svg viewBox=\"0 0 1024 1024\"><rect x=\"512\" width=\"512\" height=\"1024\"/></svg>"
        let manifest = try JSONDecoder().decode(IconManifest.self, from: Data(manifestJSON.utf8))
        let glass = try XCTUnwrap(SVGShape.parse(data: Data(fullSVG.utf8)))
        let half = try XCTUnwrap(SVGShape.parse(data: Data(halfSVG.utf8)))
        let doc = IconDocument(url: URL(fileURLWithPath: "/tmp/glass.icon"),
                               manifest: manifest,
                               shapes: ["glass.svg": glass, "half.svg": half])

        var options = RenderOptions(appearance: .light, recipe: .iOS27)
        options.effects = false
        options.clipToMask = false
        let pdfData = try XCTUnwrap(Exporters.pdfData(doc, pointSize: 100, options: options))
        let provider = try XCTUnwrap(CGDataProvider(data: pdfData as CFData))
        let pdf = try XCTUnwrap(CGPDFDocument(provider))
        let page = try XCTUnwrap(pdf.page(at: 1))

        let size = 400
        let ctx = try XCTUnwrap(CGContext(data: nil, width: size, height: size,
                                          bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.scaleBy(x: 4, y: 4)
        ctx.drawPDFPage(page)
        let image = try XCTUnwrap(ctx.makeImage())
        let bytes = try XCTUnwrap(image.dataProvider?.data) as Data
        let row = image.bytesPerRow
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let offset = y * row + x * 4
            return (Int(bytes[offset]), Int(bytes[offset + 1]), Int(bytes[offset + 2]))
        }

        let overRed = pixel(100, 200)
        let overBlue = pixel(300, 200)
        XCTAssertGreaterThan(overRed.0, overBlue.0 + 20,
                             "glass PDF fill became opaque and hid the backdrop")
        XCTAssertGreaterThan(overBlue.2, overRed.2 + 10,
                             "glass PDF fill did not transmit the blue backdrop")
    }

    /// ICC profile loading and profile-based CMYK conversion, using the
    /// system Generic CMYK profile (always present on macOS).
    func testPrintProfileConversion() throws {
        let url = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/Generic CMYK Profile.icc")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: url.path))

        let profile = try PrintProfile.load(url: url)
        XCTAssertEqual(profile.space.model, .cmyk)
        XCTAssertFalse(profile.name.isEmpty)

        // A saturated red must convert to a magenta+yellow-dominant separation.
        let red = ColorSpec(space: .srgb, r: 0.86, g: 0.27, b: 0.25, a: 1)
        let converted = ColorConvert.cgColor(red, cmyk: true, profile: profile)
        let comps = try XCTUnwrap(converted.components)
        XCTAssertEqual(converted.numberOfComponents, 5) // CMYK + alpha
        XCTAssertGreaterThan(comps[1], 0.5, "magenta should dominate")
        XCTAssertGreaterThan(comps[2], 0.5, "yellow should dominate")
        XCTAssertLessThan(comps[0], 0.4, "little cyan in a red")

        // A non-CMYK profile must be rejected.
        let rgbURL = URL(fileURLWithPath: "/System/Library/ColorSync/Profiles/sRGB Profile.icc")
        if FileManager.default.fileExists(atPath: rgbURL.path) {
            XCTAssertThrowsError(try PrintProfile.load(url: rgbURL))
        }
    }

    func testMatrixTransformApplied() {
        // translate(10,20) should move a unit rect's origin.
        let t = "translate(10,20)"
        let m = SVGShapeTestHook.parseTransform(t)
        let p = CGPoint(x: 0, y: 0).applying(m)
        XCTAssertEqual(p.x, 10, accuracy: 0.001)
        XCTAssertEqual(p.y, 20, accuracy: 0.001)
    }
}
