import XCTest
import CoreGraphics
@testable import IconBuilderCore

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

    func testMatrixTransformApplied() {
        // translate(10,20) should move a unit rect's origin.
        let t = "translate(10,20)"
        let m = SVGShapeTestHook.parseTransform(t)
        let p = CGPoint(x: 0, y: 0).applying(m)
        XCTAssertEqual(p.x, 10, accuracy: 0.001)
        XCTAssertEqual(p.y, 20, accuracy: 0.001)
    }
}
