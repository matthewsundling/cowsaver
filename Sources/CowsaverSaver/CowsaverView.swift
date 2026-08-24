import AppKit
import CowsayKit
import CowsaverRender
import Foundation
import ScreenSaver
import os.log

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
    /// The complete config-file state `configuration` was decoded from. A reused view must
    /// distinguish absence from an existing unreadable or oversized file as well as compare
    /// readable contents.
    private var configurationFileState: ConfigurationFileState = .missing
    private var configurationURL: URL?
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

        let file = Self.configurationFile()
        let resolved = Self.resolveConfiguration(file)
        configurationFileState = file.state
        configurationURL = file.url
        configuration = resolved.configuration
        for warning in resolved.warnings { log(warning) }

        self.engine = buildEngineAndLogDiagnostics()

        let seed = UInt64(bitPattern: Int64(ObjectIdentifier(self).hashValue))
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
        reloadConfigurationIfChanged()

        // A preview renders its first frame but does not join the shared rotation timer.
        guard !effectivelyPreview else {
            rotate()   // System Settings expects a thumbnail right away
            return
        }

        // Defer the first fit by one runloop turn.
        //
        // A host can finalise geometry just after startAnimation returns. Deferring prevents
        // the first content from being fitted to a placeholder size; the content view also
        // re-fits on any later geometry signal.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isAnimating, self.window != nil else { return }
            self.rotate()
        }
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

    /// `RotationClient`. An attached but stopped view is no longer eligible for rotation.
    public var isLive: Bool { isRegistered && isAnimating && window != nil }

    public func rotate() {
        guard let content, let engine else { return }
        // Rendering is fallible only through missing optional state; leave the existing frame
        // in place if the view has already been detached.
        let preview = effectivelyPreview
        content.present(engine.nextBlock(fitting: content.canvas, preview: preview),
                        animated: !preview)
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

    public override var hasConfigureSheet: Bool {
        // Log the capability query as well as the sheet request so a host that never asks can
        // be distinguished from a failure after it asks.
        log("hasConfigureSheet queried")
        return true
    }

    public override var configureSheet: NSWindow? {
        log("configureSheet requested")
        // The sheet has already validated and written config.json by the time this runs.
        let sheet = ConfigurationSheet(configuration: configuration) { [weak self] updated in
            guard let self else { return }
            self.configuration = updated
            // Take the complete state of the file the sheet just wrote, so the next
            // activation does not re-apply a configuration that has already arrived through
            // this path.
            let file = Self.configurationFile()
            self.configurationFileState = file.state
            self.configurationURL = file.url
            self.content?.apply(configuration: updated)
            self.rebuildEngine()
            // Re-register so a changed rotation interval takes effect in this host process,
            // which outlives the view that first registered one.
            if self.isRegistered {
                RotationCoordinator.shared.register(self, interval: updated.rotationInterval)
            }
            self.rotate()
        }
        // The host has not attached this window as a sheet yet, so its own screen would still
        // reflect wherever AppKit happened to construct it, not System Settings' display.
        sheet.prepareForPresentation(on: window?.screen)
        self.sheet = sheet   // the host does not retain it for us
        return sheet.window
    }

    /// Settings that change which content is loaded need a new engine, not just a redraw.
    private func rebuildEngine() {
        engine = buildEngineAndLogDiagnostics()
    }

    /// The one path every engine-creating call site uses, so initial construction, an
    /// Options-triggered rebuild, and an activation-time configuration reload all surface
    /// the same authoritative diagnostic sequence rather than each logging its own subset.
    private func buildEngineAndLogDiagnostics() -> CowsaverEngine {
        let bundle = Bundle(for: CowsaverView.self)
        let seed = UInt64(bitPattern: Int64(ObjectIdentifier(self).hashValue))
        let engine = CowsaverEngine(
            configuration: configuration,
            cowDirectories: ResourceLocations.cowDirectories(bundle: bundle),
            fortuneDirectories: ResourceLocations.fortuneDirectories(bundle: bundle),
            seed: seed
        )
        for message in engine.diagnostics.messages { log(message) }
        return engine
    }

    // MARK: Configuration

    /// Re-read `config.json` when its complete state differs from what this view last loaded.
    ///
    /// The legacy host can reuse a view across activations, so resolving configuration only
    /// in `init` would prevent an edited file from reaching that view. Compare complete state
    /// and content rather than mtime to catch missing, unreadable, and oversized transitions
    /// without clock-granularity edge cases.
    ///
    /// Applies the result the way the sheet's save path does. `startAnimation` renders after
    /// this returns, immediately for a preview and a runloop turn later otherwise, so there
    /// is no rotation to ask for here.
    private func reloadConfigurationIfChanged() {
        let file = Self.configurationFile()
        guard file.state != configurationFileState || file.url != configurationURL else { return }
        configurationFileState = file.state
        configurationURL = file.url

        let resolved = Self.resolveConfiguration(file)
        log("config.json changed since this view loaded it; reloading")
        for warning in resolved.warnings { log(warning) }
        configuration = resolved.configuration
        content?.apply(configuration: configuration)
        rebuildEngine()
        // Re-register so a changed rotation interval takes effect in this host process,
        // which outlives the view that first registered one.
        if isRegistered {
            RotationCoordinator.shared.register(self, interval: configuration.rotationInterval)
        }
    }

    /// The config file in the search order and its complete bounded read state.
    private static func configurationFile() -> (url: URL?, state: ConfigurationFileState) {
        guard let url = ResourceLocations.configurationURL() else { return (nil, .missing) }
        return (url, Configuration.fileState(at: url))
    }

    /// `config.json` is the whole configuration; there is no second store layered under it.
    ///
    /// `Configuration.load` already warns about malformed, unreadable, and oversized files.
    /// No file at all is the ordinary case for the saver and says nothing.
    private static func resolveConfiguration(
        _ file: (url: URL?, state: ConfigurationFileState)
    ) -> Configuration.LoadResult {
        guard let url = file.url else {
            return Configuration.LoadResult(configuration: Configuration(), warnings: [])
        }
        return Configuration.load(fileState: file.state, at: url)
    }

    private static let logger = Logger(subsystem: "com.matthewsundling.cowsaver", category: "saver")

    private func log(_ message: String) {
        // The screensaver host can discard NSLog output from the extension. An explicit
        // unified-log subsystem keeps these messages available, public privacy keeps them
        // readable in `log show`, and the default level preserves them after the process exits.
        Self.logger.log("[Cowsaver] \(message, privacy: .public)")
    }

    /// Records the view, window, and screen geometry in one stable line per lifecycle event.
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
