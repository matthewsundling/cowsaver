import AppKit
import CowsayKit
import Foundation

/// Renders a block of ASCII art to a bitmap without a window.
///
/// This exists so the layout can be tested. `CowsayKit`'s goldens prove the *text* is
/// right; nothing there would notice if auto-fit picked a font size of 4, or if the block
/// were positioned off-screen. Rendering offscreen catches that, and needs no GUI session,
/// no System Settings, and no screensaver host.
///
/// The app's `--render-to-png` is a thin wrapper over this, so the tests and the shipped
/// binary exercise exactly the same path.
public enum ImageRenderer {
    public struct Result {
        public let image: NSBitmapImageRep
        /// What the view drew, taken from the view, not computed a second time here.
        ///
        /// A second computation can agree with itself while the view does something else, so
        /// a test could pass on layout the screen never saw.
        public let metrics: LayoutMetrics
        /// The frame the view gave its text layer, in view coordinates.
        public let textFrame: CGRect
    }

    /// Main-actor bound because this builds an `NSView` and renders its layer tree. The
    /// annotation makes that AppKit requirement visible at each call site.
    @MainActor
    public static func render(
        block: String,
        configuration: Configuration,
        size: CGSize,
        seed: UInt64 = 1
    ) -> Result? {
        let view = CowsaverContentView(frame: CGRect(origin: .zero, size: size),
                                       configuration: configuration, seed: seed)
        view.present(block, animated: false)
        view.layoutSubtreeIfNeeded()

        guard let representation = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ), let context = NSGraphicsContext(bitmapImageRep: representation) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        // Render the layer tree rather than calling draw(_:). The content is a CATextLayer,
        // and cacheDisplay would capture the view's own (empty) drawing instead.
        view.layer?.render(in: context.cgContext)
        NSGraphicsContext.restoreGraphicsState()

        return Result(image: representation, metrics: view.presentedMetrics,
                      textFrame: view.presentedTextFrame)
    }

    @MainActor
    public static func png(
        block: String,
        configuration: Configuration,
        size: CGSize,
        seed: UInt64 = 1
    ) -> Data? {
        guard let result = render(block: block, configuration: configuration,
                                  size: size, seed: seed) else { return nil }
        return result.image.representation(using: .png, properties: [:])
    }
}
