import AppKit
import CowsayKit
import Foundation
import Testing
@testable import CowsaverRender

/// `sizeVariation` draws each rotation somewhere below the fitted size.
///
/// The properties that matter are a band (never larger than the fit, never smaller than the
/// configured fraction of it), a spread (something actually varies), containment (the clamp
/// still has the last word), and — where the feature is off — that nothing at all changed.
///
/// `.serialized` and `@MainActor` keep AppKit view construction on the main thread while
/// swift-testing runs the broader suite concurrently.
@Suite("Size variation", .serialized)
@MainActor
struct SizeVariationTests {
    private let canvas = CGSize(width: 1280, height: 800)

    private func block(rows: Int = 12, columns: Int = 40) -> String {
        (0 ..< rows).map { _ in String(repeating: "x", count: columns) }.joined(separator: "\n")
    }

    private func view(sizeVariation: Double, in size: CGSize? = nil,
                      seed: UInt64 = 1) -> CowsaverContentView {
        var configuration = Configuration()
        configuration.sizeVariation = sizeVariation
        return CowsaverContentView(frame: CGRect(origin: .zero, size: size ?? canvas),
                                   configuration: configuration, seed: seed)
    }

    /// Enough rotations to catch a factor that escapes the band on one draw in ten.
    @Test func everyRotationLandsInsideTheBandAndTheCanvas() {
        let variation = 0.5
        let unvaried = view(sizeVariation: 0)
        unvaried.present(block(), animated: false)
        let fitted = unvaried.presentedMetrics.fontSize

        let varying = view(sizeVariation: variation)
        var sizes: Set<CGFloat> = []
        for rotation in 0 ..< 50 {
            varying.present(block(), animated: false)
            let drawn = varying.presentedMetrics.fontSize
            #expect(drawn <= fitted, "rotation \(rotation) drew \(drawn), above the fit \(fitted)")
            #expect(drawn >= fitted * CGFloat(1 - variation),
                    "rotation \(rotation) drew \(drawn), below the band of \(fitted)")
            #expect(CGRect(origin: .zero, size: canvas).contains(varying.presentedTextFrame),
                    "rotation \(rotation): \(varying.presentedTextFrame) escapes \(canvas)")
            sizes.insert(drawn)
        }
        #expect(sizes.count > 1, "50 rotations drew one size; nothing varied")
    }

    /// Off means untouched, down to the random sequence: a view that does not ask for size
    /// variation must draw exactly what it drew before the feature existed, and a draw taken
    /// from the generator would move every position after it.
    @Test func variationOffMatchesADefaultViewExactly() {
        let plain = CowsaverContentView(frame: CGRect(origin: .zero, size: canvas),
                                        configuration: Configuration(), seed: 42)
        let explicitZero = view(sizeVariation: 0, seed: 42)

        for rotation in 0 ..< 10 {
            plain.present(block(), animated: false)
            explicitZero.present(block(), animated: false)
            #expect(plain.presentedMetrics == explicitZero.presentedMetrics,
                    "rotation \(rotation) fitted differently")
            #expect(plain.presentedTextFrame == explicitZero.presentedTextFrame,
                    "rotation \(rotation) placed the block differently")
        }
    }

    /// Auto-fit only. A pinned `fontSize` is an explicit choice, and varying it would make
    /// the number in the file a suggestion.
    @Test func aPinnedFontSizeIsNeverVaried() {
        var configuration = Configuration()
        configuration.fontSize = 22
        configuration.sizeVariation = 0.5
        let view = CowsaverContentView(frame: CGRect(origin: .zero, size: canvas),
                                       configuration: configuration, seed: 1)

        for _ in 0 ..< 10 {
            view.present(block(), animated: false)
            #expect(view.presentedMetrics.fontSize == 22)
        }
    }

    /// Containment runs after the variation, so a canvas with no room to spare is still the
    /// overriding invariant — the case issue #3 was about.
    @Test(arguments: [CGSize(width: 290, height: 165), CGSize(width: 8, height: 8)])
    func variationNeverEscapesASmallCanvas(size: CGSize) {
        let view = view(sizeVariation: 0.9, in: size)
        for rotation in 0 ..< 20 {
            view.present(block(rows: 65, columns: 70), animated: false)
            #expect(CGRect(origin: .zero, size: size).contains(view.presentedTextFrame),
                    "rotation \(rotation): \(view.presentedTextFrame) escapes \(size)")
        }
    }
}
