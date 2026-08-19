import AppKit
import CowsayKit
import CowsaverRender
import Foundation
import ScreenSaver

/// The `.saver` bridge between ScreenSaverKit and the shared Cowsaver content engine.
///
/// Cowsaver does not override `animateOneFrame()`. Calling `super.startAnimation()` is part
/// of the `ScreenSaverView` contract, so the host retains its own periodic callback; its
/// default implementation does nothing. `animationTimeInterval` makes that callback
/// infrequent, while `RotationCoordinator` owns Cowsaver's content-rotation schedule.
///
/// `NSPrincipalClass` in `Info.plist` is `CowsaverSaver.CowsaverView`, matching Swift's
/// module-qualified Objective-C runtime name.
public final class CowsaverView: ScreenSaverView, RotationClient {
    private var content: CowsaverContentView?
    private var engine: CowsaverEngine?
    private var configuration = Configuration()
    private var isRegistered = false

    // MARK: Lifecycle

    public override init?(frame: NSRect, isPreview: Bool) {
        super.init(frame: frame, isPreview: isPreview)
        logGeometry("init")

        // ScreenSaverView owns a required periodic callback after startAnimation(). Its
        // default animateOneFrame() implementation is a no-op, and an hourly interval keeps
        // that host callback out of the content-rotation path.
        animationTimeInterval = 3600

        wantsLayer = true
        autoresizingMask = [.width, .height]

        let resolved = Self.resolveConfiguration()
        configuration = resolved.configuration
        for warning in resolved.warnings { log(warning) }

        let bundle = Bundle(for: CowsaverView.self)
        let seed = UInt64(bitPattern: Int64(ObjectIdentifier(self).hashValue))
        let engine = CowsaverEngine(
            configuration: configuration,
            cowDirectories: ResourceLocations.cowDirectories(bundle: bundle),
            fortuneDirectories: ResourceLocations.fortuneDirectories(bundle: bundle),
            seed: seed
        )
        for note in engine.diagnostics.notes { log(note) }
        self.engine = engine

        let content = CowsaverContentView(frame: bounds, configuration: configuration, seed: seed)
        content.autoresizingMask = [.width, .height]
        addSubview(content)
        self.content = content
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        // One of three redundant teardown paths. See `unregisterFromRotation`.
        RotationCoordinator.shared.unregister(self)
    }

    // MARK: Preview detection

    /// Combine `isPreview` with geometry.
    ///
    /// This distinguishes small preview views from full-screen presentation.
    ///
    /// Evaluate lazily because `window` is nil during initialization and screen geometry is
    /// unavailable until the view is attached.
    ///
    /// Small views are treated as previews to avoid registering the rotation timer for a
    /// settings thumbnail.
    private var effectivelyPreview: Bool {
        if isPreview { return true }
        if bounds.width < 640 || bounds.height < 400 { return true }
        if let screen = window?.screen, bounds.width < screen.frame.width * 0.5 { return true }
        return false
    }

    // MARK: Animation

    public override func startAnimation() {
        super.startAnimation()
        logGeometry("startAnimation")
        rotate()   // always show something immediately, preview or not

        // A preview renders its first frame but does not join the shared rotation timer.
        guard !effectivelyPreview else { return }
        registerForRotation()
    }

    public override func stopAnimation() {
        super.stopAnimation()
        logGeometry("stopAnimation")
        unregisterFromRotation()
    }

    /// The legacy host can detach a view without a useful teardown sequence. Losing the
    /// window is therefore treated as teardown too.
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        logGeometry("viewDidMoveToWindow")
        if window == nil {
            unregisterFromRotation()
        } else if isAnimating, !effectivelyPreview, !isRegistered {
            registerForRotation()
        }
    }

    /// `RotationClient`. The coordinator prunes a detached view at its next rotation tick.
    public var isLive: Bool { window != nil }

    public func rotate() {
        guard let content, let engine else { return }
        // Rendering is fallible only through missing optional state; leave the existing frame
        // in place if the view has already been detached.
        content.present(engine.nextBlock(fitting: content.canvas),
                        animated: !effectivelyPreview)
    }

    private func registerForRotation() {
        guard !isRegistered else { return }
        isRegistered = true
        RotationCoordinator.shared.register(self, interval: configuration.rotationInterval)
    }

    /// Called from every lifecycle path that can detach the view. Repeated unregistration is
    /// harmless and covers both normal animation shutdown and window removal.
    private func unregisterFromRotation() {
        isRegistered = false
        RotationCoordinator.shared.unregister(self)
    }

    // MARK: Options sheet

    /// The sheet edits `config.json`, which is also the runtime configuration file.
    private var sheet: ConfigurationSheet?

    public override var hasConfigureSheet: Bool { true }

    public override var configureSheet: NSWindow? {
        let sheet = ConfigurationSheet(configuration: configuration) { [weak self] updated in
            guard let self else { return }
            if let error = ConfigurationSheet.persist(updated) {
                self.log("could not save settings: \(error)")
                return
            }
            self.configuration = updated
            self.content?.apply(configuration: updated)
            self.rebuildEngine()
            self.rotate()
        }
        self.sheet = sheet   // the host does not retain it for us
        return sheet.window
    }

    /// Settings that change which content is loaded need a new engine, not just a redraw.
    private func rebuildEngine() {
        let bundle = Bundle(for: CowsaverView.self)
        let seed = UInt64(bitPattern: Int64(ObjectIdentifier(self).hashValue))
        engine = CowsaverEngine(
            configuration: configuration,
            cowDirectories: ResourceLocations.cowDirectories(bundle: bundle),
            fortuneDirectories: ResourceLocations.fortuneDirectories(bundle: bundle),
            seed: seed
        )
    }

    // MARK: Configuration

    private static func resolveConfiguration() -> Configuration.LoadResult {
        // Layer built-in defaults, ScreenSaverDefaults, then config.json; the file has the
        // highest priority.
        var merged: [String: Any] = [:]

        if let defaults = ScreenSaverDefaults(forModuleWithName: "com.matthewsundling.cowsaver") {
            for key in Configuration.knownKeys {
                if let value = defaults.object(forKey: key) { merged[key] = value }
            }
        }

        var warnings: [String] = []
        if let url = ResourceLocations.configurationURL() {
            if let data = FileManager.default.contents(atPath: url.path),
               let parsed = try? JSONSerialization.jsonObject(with: data),
               let object = parsed as? [String: Any] {
                merged.merge(object) { _, fromFile in fromFile }
            } else {
                warnings.append("config.json at \(url.path) is unreadable or not a JSON object; ignoring it")
            }
        }

        let result = Configuration.load(object: merged)
        return Configuration.LoadResult(configuration: result.configuration,
                                        warnings: warnings + result.warnings)
    }

    private func log(_ message: String) {
        // NSLog sends diagnostics to Console without requiring a custom logging subsystem.
        NSLog("[Cowsaver] %@", message)
    }

    /// One grep-friendly line per lifecycle event.
    ///
    /// Enough to diagnose host geometry regressions from a single `log stream` capture.
    private func logGeometry(_ event: String) {
        let windowFrame = window?.frame
        let screenFrame = window?.screen?.frame
        log("\(event) bounds=\(Self.format(bounds)) frame=\(Self.format(frame)) " +
            "window=\(windowFrame.map(Self.format) ?? "nil") " +
            "screen=\(screenFrame.map(Self.format) ?? "nil") " +
            "isPreview=\(isPreview) effectivelyPreview=\(effectivelyPreview)")
    }

    private static func format(_ rect: NSRect) -> String {
        "\(format(rect.width))x\(format(rect.height))@\(format(rect.minX)),\(format(rect.minY))"
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%g", Double(value))
    }
}
