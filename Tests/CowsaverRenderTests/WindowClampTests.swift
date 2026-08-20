import AppKit
import CowsayKit
import Foundation
import Testing
@testable import CowsaverRender

/// Content stays inside the hosting window even when the host hands the view larger bounds.
///
/// This is the invariant issue #2 breaks. On macOS 26.6.1 `legacyScreenSaver` sometimes
/// resizes the saver view to the display's pixel dimensions while the hosting window stays
/// at point dimensions: bounds of 2560x1656 inside a 1280x828 window. Everything was then
/// drawn at twice the intended size, and with AppKit's bottom-left origin the window showed
/// only the window-sized region at the view's origin. These tests reproduce that geometry,
/// and the degenerate windows captured in the same session.
///
/// The windows are borderless so that their frame is exactly the size under test — a title
/// bar would add height the view was never told about — deferred, and never ordered front.
///
/// `.serialized` and `@MainActor` keep AppKit window and view construction on the main
/// thread while swift-testing runs the broader suite concurrently.
@Suite("Window clamp", .serialized)
@MainActor
struct WindowClampTests {
    /// The field machine's display, in points and in pixels.
    private let points = CGSize(width: 1280, height: 828)
    private let pixels = CGSize(width: 2560, height: 1656)

    /// A fortune-shaped block, fixed so two views can be compared exactly.
    private func block(rows: Int = 20, columns: Int = 44) -> String {
        (0 ..< rows).map { _ in String(repeating: "x", count: columns) }.joined(separator: "\n")
    }

    /// Repositioning off, so a placement is one value rather than a distribution.
    private var centred: Configuration {
        var configuration = Configuration()
        configuration.reposition = false
        return configuration
    }

    private func window(_ size: CGSize) -> NSWindow {
        NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless],
                 backing: .buffered, defer: true)
    }

    /// The host resizes the view itself, so the view carries its own frame into the window
    /// rather than tracking it.
    private func view(_ size: CGSize, in window: NSWindow?,
                      configuration: Configuration) -> CowsaverContentView {
        let view = CowsaverContentView(frame: CGRect(origin: .zero, size: size),
                                       configuration: configuration, seed: 1)
        view.autoresizingMask = []
        window?.contentView?.addSubview(view)
        return view
    }

    /// The captured failure, exactly: pixel-sized bounds inside a point-sized window.
    @Test func theFieldGeometryIsFittedToTheWindowNotTheBounds() {
        let clamped = view(pixels, in: window(points), configuration: centred)
        let reference = view(points, in: nil, configuration: centred)

        clamped.present(block(), animated: false)
        reference.present(block(), animated: false)

        let fitted = clamped.presentedMetrics.fontSize
        let expected = reference.presentedMetrics.fontSize
        #expect(CGRect(origin: .zero, size: points).contains(clamped.presentedTextFrame),
                "\(clamped.presentedTextFrame) escapes the visible \(points)")
        #expect(fitted == expected,
                "fitted to the bounds rather than the window: \(fitted) against \(expected)")
    }

    /// The healthy views in the same session must be untouched by the defense.
    @Test func aViewMatchingItsWindowIsFittedAsItIsWithNoWindowAtAll() {
        let hosted = view(points, in: window(points), configuration: centred)
        let reference = view(points, in: nil, configuration: centred)

        hosted.present(block(), animated: false)
        reference.present(block(), animated: false)

        #expect(hosted.presentedMetrics.fontSize == reference.presentedMetrics.fontSize)
        #expect(hosted.presentedTextFrame == reference.presentedTextFrame)
    }

    /// The host attaches a view to an empty window frame before the real one arrives, so an
    /// empty frame is a placeholder, not an instruction to draw nothing.
    @Test func aDegenerateWindowIsIgnored() {
        let host = window(.zero)
        #expect(host.frame.width < 64 && host.frame.height < 64,
                "the premise: \(host.frame.size) has to be degenerate for this to mean anything")
        let hosted = view(points, in: host, configuration: centred)
        let reference = view(points, in: nil, configuration: centred)

        hosted.present(block(), animated: false)
        reference.present(block(), animated: false)

        #expect(hosted.presentedMetrics.fontSize == reference.presentedMetrics.fontSize)
        #expect(hosted.presentedTextFrame == reference.presentedTextFrame)
    }

    /// The balloon is wrapped for the region that will be visible: `CowsaverView.rotate()`
    /// hands the engine `content.canvas` and nothing else, so this is the whole of what the
    /// saver needs from the clamp. The field geometry is an exact doubling, where the shape
    /// is the same either way; a window out of proportion with the bounds tells them apart.
    @Test func theWrapCanvasDescribesTheVisibleRegion() throws {
        let visible = CGSize(width: 1280, height: 400)
        let clamped = view(points, in: window(visible), configuration: centred)
        let reference = view(visible, in: nil, configuration: centred)

        let expected = try #require(reference.canvas)
        #expect(clamped.canvas == expected, "wrapped for the bounds rather than the window")
    }

    /// Every rotation lands inside the visible region, not just the first one.
    @Test func repositioningStaysInsideTheVisibleRegion() {
        var configuration = Configuration()
        configuration.reposition = true
        let clamped = view(pixels, in: window(points), configuration: configuration)
        let visible = CGRect(origin: .zero, size: points)

        for rotation in 0 ..< 20 {
            clamped.present(block(), animated: false)
            #expect(visible.contains(clamped.presentedTextFrame),
                    "rotation \(rotation): \(clamped.presentedTextFrame) escapes \(visible)")
        }
    }

    /// The window can change size while the bounds stay put: in the captured sequence the
    /// window frame went from 0x0 to 1280x828 with no `setFrameSize` on the view.
    @Test func aWindowGrowingRefitsTheBlock() {
        let host = window(CGSize(width: 640, height: 400))
        let hosted = view(points, in: host, configuration: centred)
        hosted.present(block(), animated: false)
        let underTheSmallWindow = hosted.presentedMetrics.fontSize

        host.setContentSize(points)
        hosted.needsLayout = true
        hosted.layoutSubtreeIfNeeded()

        #expect(hosted.presentedMetrics.fontSize > underTheSmallWindow,
                "a window grown to the bounds did not re-fit larger")
        #expect(CGRect(origin: .zero, size: points).contains(hosted.presentedTextFrame))
    }

    /// A rotation that lands after the host removes the window still fits the window.
    ///
    /// In the 26.6.1 capture every unclamped full-screen present shared a millisecond with a
    /// `viewDidMoveToWindow` reporting no window, so the clamp has to survive the detach.
    @Test func aDetachedViewKeepsFittingToTheWindowItLastHad() {
        let host = window(points)
        let hosted = view(pixels, in: host, configuration: centred)
        hosted.present(block(), animated: false)
        let attached = hosted.presentedMetrics.fontSize

        hosted.removeFromSuperview()
        #expect(hosted.window == nil, "the view must actually be detached")
        hosted.present(block(), animated: false)

        #expect(hosted.presentedMetrics.fontSize == attached,
                "a detached view re-fitted to its oversized bounds")
        #expect(CGRect(origin: .zero, size: points).contains(hosted.presentedTextFrame),
                "\(hosted.presentedTextFrame) escapes the visible \(points)")
    }
}
