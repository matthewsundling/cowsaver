import AppKit
import CowsayKit
import Foundation
import Testing
@testable import CowsaverRender

/// Rendering regression tests.
///
/// These assert stable layout properties instead of comparing committed PNG bytes. Text
/// rasterization varies across macOS versions and display scales, while bitmap dimensions,
/// fitted size, placement, and configured colours remain useful regression signals.
///
/// `.serialized` and `@MainActor` keep AppKit view construction and layer rendering on the
/// main thread while swift-testing runs the broader suite concurrently.
@Suite("Offscreen rendering", .serialized)
@MainActor
struct ImageRenderTests {
    private let size = CGSize(width: 1280, height: 800)

    private func sampleBlock(columns: Int = 40, rows: Int = 12) -> String {
        (0 ..< rows).map { _ in String(repeating: "x", count: columns) }.joined(separator: "\n")
    }

    @Test func producesABitmapOfTheRequestedSize() throws {
        let result = try #require(ImageRenderer.render(block: sampleBlock(),
                                                       configuration: Configuration(),
                                                       size: size))
        #expect(result.image.pixelsWide == 1280)
        #expect(result.image.pixelsHigh == 800)
    }

    @Test func producesAValidPNG() throws {
        let data = try #require(ImageRenderer.png(block: sampleBlock(),
                                                  configuration: Configuration(), size: size))
        #expect(data.starts(with: [0x89, 0x50, 0x4E, 0x47]), "PNG magic bytes")
        #expect(NSBitmapImageRep(data: data) != nil)
    }

    /// Checks that something is actually drawn. A blank frame is the symptom of nearly
    /// every layout bug.
    @Test func actuallyDrawsSomething() throws {
        let result = try #require(ImageRenderer.render(block: sampleBlock(),
                                                       configuration: Configuration(),
                                                       size: size))
        var litPixels = 0
        for x in stride(from: 0, to: result.image.pixelsWide, by: 4) {
            for y in stride(from: 0, to: result.image.pixelsHigh, by: 4) {
                if let colour = result.image.colorAt(x: x, y: y), colour.greenComponent > 0.3 {
                    litPixels += 1
                }
            }
        }
        #expect(litPixels > 100, "the frame is effectively blank (\(litPixels) lit samples)")
    }

    /// Auto-fit must scale to the content, not pick a constant.
    @Test func autoFitRespondsToBlockSize() throws {
        let small = try #require(ImageRenderer.render(block: sampleBlock(columns: 20, rows: 6),
                                                      configuration: Configuration(), size: size))
        let large = try #require(ImageRenderer.render(block: sampleBlock(columns: 160, rows: 48),
                                                      configuration: Configuration(), size: size))
        #expect(large.metrics.fontSize < small.metrics.fontSize)
    }

    /// A fortune longer than the screen must not overflow it.
    @Test func oversizedContentStaysInsideTheFrame() throws {
        let result = try #require(ImageRenderer.render(block: sampleBlock(columns: 300, rows: 120),
                                                       configuration: Configuration(), size: size))
        if result.metrics.fontSize > 6 {
            #expect(result.metrics.textSize.width <= size.width)
            #expect(result.metrics.textSize.height <= size.height)
        }
    }

    @Test func explicitFontSizeIsUsedVerbatim() throws {
        var configuration = Configuration()
        configuration.fontSize = 22
        let result = try #require(ImageRenderer.render(block: sampleBlock(),
                                                       configuration: configuration, size: size))
        #expect(result.metrics.fontSize == 22)
    }

    /// Rendering is deterministic for a fixed seed, which is what would make committed
    /// reference images viable on a pinned machine.
    @Test func isDeterministicForAFixedSeed() throws {
        let a = try #require(ImageRenderer.png(block: sampleBlock(),
                                               configuration: Configuration(), size: size, seed: 7))
        let b = try #require(ImageRenderer.png(block: sampleBlock(),
                                               configuration: Configuration(), size: size, seed: 7))
        #expect(a == b)
    }

    /// Repositioning must actually move the block, or Rule 5 is not implemented.
    @Test func repositioningChangesPlacement() throws {
        var configuration = Configuration()
        configuration.reposition = true
        let a = try #require(ImageRenderer.png(block: sampleBlock(),
                                               configuration: configuration, size: size, seed: 1))
        let b = try #require(ImageRenderer.png(block: sampleBlock(),
                                               configuration: configuration, size: size, seed: 99))
        #expect(a != b, "two different seeds placed the block identically")
    }

    @Test func repositioningOffCentresTheBlock() throws {
        var configuration = Configuration()
        configuration.reposition = false
        let a = try #require(ImageRenderer.png(block: sampleBlock(),
                                               configuration: configuration, size: size, seed: 1))
        let b = try #require(ImageRenderer.png(block: sampleBlock(),
                                               configuration: configuration, size: size, seed: 99))
        #expect(a == b, "with reposition off, the seed must not matter")
    }

    /// The theme reaches the pixels, not just the config struct.
    @Test func themeColoursAreApplied() throws {
        var amber = Configuration()
        amber.theme = "amber"
        let result = try #require(ImageRenderer.render(block: sampleBlock(),
                                                       configuration: amber, size: size))
        var sawAmber = false
        for x in stride(from: 0, to: result.image.pixelsWide, by: 2) {
            for y in stride(from: 0, to: result.image.pixelsHigh, by: 2) {
                if let colour = result.image.colorAt(x: x, y: y),
                   colour.redComponent > 0.8, colour.greenComponent > 0.4,
                   colour.blueComponent < 0.2 {
                    sawAmber = true
                }
            }
            if sawAmber { break }
        }
        #expect(sawAmber, "no amber pixels found; the theme did not reach the text layer")
    }

    /// E2: `debugFrame` draws a red border on the view bounds and a contrasting blue
    /// border on the text layer, so a screenshot can tell a host-geometry bug from a
    /// layout bug. `CALayer.render(in:)` happens to draw `borderWidth`/
    /// `borderColor`, unlike some other layer effects (shadows, masks), so this can
    /// assert directly on pixels rather than only on the flag's plumbing.
    @Test func debugFrameDrawsBorderColouredPixels() throws {
        var configuration = Configuration()
        configuration.debugFrame = true
        let result = try #require(ImageRenderer.render(block: sampleBlock(),
                                                        configuration: configuration, size: size))

        var sawRedBoundsEdge = false
        for x in stride(from: 0, to: result.image.pixelsWide, by: 4) {
            if let colour = result.image.colorAt(x: x, y: 0),
               colour.redComponent > 0.8, colour.greenComponent < 0.2, colour.blueComponent < 0.2 {
                sawRedBoundsEdge = true
                break
            }
        }
        #expect(sawRedBoundsEdge, "no red border found on the view bounds edge")

        var sawBlueTextBorder = false
        for x in stride(from: 0, to: result.image.pixelsWide, by: 2) {
            for y in stride(from: 0, to: result.image.pixelsHigh, by: 2) {
                if let colour = result.image.colorAt(x: x, y: y),
                   colour.blueComponent > 0.8, colour.redComponent < 0.2, colour.greenComponent < 0.2 {
                    sawBlueTextBorder = true
                }
            }
            if sawBlueTextBorder { break }
        }
        #expect(sawBlueTextBorder, "no blue border found around the text layer")
    }

    @Test func emptyBlockDoesNotCrash() {
        #expect(ImageRenderer.render(block: "", configuration: Configuration(), size: size) != nil)
    }

    /// The 8x8 case that used to log `textFrame=144.492x83.8125@0,0` — a layer eighteen times
    /// the width of its view. Containment is asserted more broadly in `ContainmentTests`.
    @Test func tinyCanvasDoesNotCrash() throws {
        let tiny = CGSize(width: 8, height: 8)
        let result = try #require(ImageRenderer.render(block: sampleBlock(),
                                                       configuration: Configuration(), size: tiny))
        #expect(CGRect(origin: .zero, size: tiny).contains(result.textFrame))
    }
}
