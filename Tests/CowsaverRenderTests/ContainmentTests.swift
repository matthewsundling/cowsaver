import AppKit
import CowsayKit
import Foundation
import Testing
@testable import CowsaverRender

/// The text layer never escapes the view.
///
/// This is the invariant issue #3 breaks: at the 6 pt floor a worst-case block does not fit a
/// Settings preview pane, and the oversized layer was pinned at the origin and clipped. Blocks
/// are built programmatically because the interesting shapes are extremes the corpus reaches
/// only occasionally, and the interesting canvases are host geometry no fixture can carry.
///
/// `.serialized` and `@MainActor` keep AppKit view construction on the main thread while
/// swift-testing runs the broader suite concurrently.
@Suite("Containment", .serialized)
@MainActor
struct ContainmentTests {
    /// About the worst the corpus can produce: a 60-line fortune in a widened balloon.
    private func block(rows: Int = 65, columns: Int = 70) -> String {
        (0 ..< rows).map { _ in String(repeating: "x", count: columns) }.joined(separator: "\n")
    }

    private func present(_ block: String, in size: CGSize,
                         configuration: Configuration = Configuration()) -> CowsaverContentView {
        let view = CowsaverContentView(frame: CGRect(origin: .zero, size: size),
                                       configuration: configuration, seed: 1)
        view.present(block, animated: false)
        return view
    }

    /// The preview pane is roughly 290x165; the rest are smaller still.
    @Test(arguments: [CGSize(width: 290, height: 165), CGSize(width: 200, height: 120),
                      CGSize(width: 8, height: 8)])
    func aWorstCaseBlockStaysInsideAPreviewPane(size: CGSize) {
        let view = present(block(), in: size)
        #expect(CGRect(origin: .zero, size: size).contains(view.presentedTextFrame),
                "\(view.presentedTextFrame) escapes \(size)")
        #expect(view.presentedMetrics.fontSize < 6,
                "must land below the floor for this to mean anything")
    }

    /// The pixels, not just the geometry.
    ///
    /// A frame inside the bounds proves nothing if the layer draws outside it, so this samples
    /// the outer two pixels the way the existing rendering tests sample color. The 8x8 canvas
    /// is left out: its image is all edge, and a two-pixel margin there has nothing to say.
    @Test(arguments: [CGSize(width: 290, height: 165), CGSize(width: 200, height: 120)])
    func aWorstCaseBlockLeavesTheOuterMarginBlank(size: CGSize) throws {
        let result = try #require(ImageRenderer.render(block: block(),
                                                       configuration: Configuration(), size: size))
        let image = result.image
        var lit: [String] = []
        func sample(_ x: Int, _ y: Int) {
            if let color = image.colorAt(x: x, y: y), color.greenComponent > 0.3 {
                lit.append("(\(x),\(y))")
            }
        }
        for x in 0 ..< image.pixelsWide {
            sample(x, 0)
            sample(x, 1)
            sample(x, image.pixelsHigh - 2)
            sample(x, image.pixelsHigh - 1)
        }
        for y in 0 ..< image.pixelsHigh {
            sample(0, y)
            sample(1, y)
            sample(image.pixelsWide - 2, y)
            sample(image.pixelsWide - 1, y)
        }
        #expect(lit.isEmpty, "foreground pixels in the outer margin at \(lit.prefix(5))")
    }

    /// A resize must re-fit, in both directions, and stay contained throughout.
    @Test func resizingRefitsTheCurrentBlock() {
        let small = CGSize(width: 400, height: 300)
        let large = CGSize(width: 3456, height: 2234)
        let tiny = CGSize(width: 290, height: 165)

        let view = present(block(), in: small)
        let fittedSmall = view.presentedMetrics.fontSize
        #expect(CGRect(origin: .zero, size: small).contains(view.presentedTextFrame))

        view.setFrameSize(large)
        #expect(view.presentedMetrics.fontSize > fittedSmall,
                "a much larger view did not re-fit larger")
        #expect(CGRect(origin: .zero, size: large).contains(view.presentedTextFrame))

        view.setFrameSize(tiny)
        #expect(view.presentedMetrics.fontSize < fittedSmall,
                "a much smaller view did not re-fit smaller")
        #expect(CGRect(origin: .zero, size: tiny).contains(view.presentedTextFrame))
    }

    /// Every block shape inside every canvas, including shapes no fortune produces.
    @Test(arguments: [(rows: 1, columns: 10), (rows: 10, columns: 80), (rows: 65, columns: 70)],
          [CGSize(width: 8, height: 8), CGSize(width: 290, height: 165),
           CGSize(width: 1024, height: 640), CGSize(width: 3456, height: 2234)])
    func everyShapeFitsEveryCanvas(shape: (rows: Int, columns: Int), canvas: CGSize) {
        let view = present(block(rows: shape.rows, columns: shape.columns), in: canvas)
        #expect(CGRect(origin: .zero, size: canvas).contains(view.presentedTextFrame),
                "\(shape.rows)x\(shape.columns) in \(canvas): \(view.presentedTextFrame)")
    }

    /// A pinned size is never rescaled, but its layer is still clamped into the view.
    ///
    /// An explicit `fontSize` is an explicit choice; the text then clips inside its own layer
    /// rather than overflowing the view and clipping against whatever the host draws next.
    @Test func aPinnedFontSizeIsKeptButItsLayerIsContained() {
        var configuration = Configuration()
        configuration.fontSize = 24
        let size = CGSize(width: 200, height: 120)

        let view = present(block(), in: size, configuration: configuration)
        #expect(view.presentedMetrics.fontSize == 24)
        #expect(CGRect(origin: .zero, size: size).contains(view.presentedTextFrame),
                "\(view.presentedTextFrame) escapes \(size)")
    }

    @Test func anExtremeDirectPinnedFontUsesTheSafeBound() {
        var configuration = Configuration()
        configuration.fontSize = Double.greatestFiniteMagnitude

        let view = present(block(), in: CGSize(width: 200, height: 120), configuration: configuration)
        #expect(view.presentedMetrics.fontSize == 144)
    }
}
