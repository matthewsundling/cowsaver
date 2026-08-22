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
    /// The config file content `configuration` was decoded from, or nil when there was no
    /// readable file. A reused view compares against this to tell an edited file from the
    /// one already in effect.
    private var configurationData: Data?
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
        configurationData = file?.data
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
        // A host that finalises geometry just after startAnimation returns would otherwise
        // have its content fitted to a placeholder size — the leading hypothesis for the
        // clipping on timer activation in issue #2. The content view re-fits on later
        // geometry signals as well; this catches the case where none arrives.
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
        // Logged because a host that never asks is indistinguishable, from the outside,
        // from a sheet that fails to open (issue #1). One capture settles which it is.
        log("hasConfigureSheet queried")
        return true
    }

    public override var configureSheet: NSWindow? {
        log("configureSheet requested")
        // The sheet has already validated and written config.json by the time this runs.
        let sheet = ConfigurationSheet(configuration: configuration) { [weak self] updated in
            guard let self else { return }
            self.configuration = updated
            // Take the file content the sheet just wrote, so the next activation does not
            // re-apply a configuration that has already arrived through this path.
            self.configurationData = Self.configurationFile()?.data
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

    /// Re-read `config.json` when its content differs from what this view last loaded.
    ///
    /// The legacy host can reuse a view across activations, and a view that resolves its
    /// configuration only in `init` keeps its birth configuration forever, so an edited file
    /// reaches nothing but a freshly created view (issue #10). Content rather than mtime:
    /// the file is a few hundred bytes, and byte equality has no clock-granularity edge
    /// cases.
    ///
    /// Applies the result the way the sheet's save path does. `startAnimation` renders after
    /// this returns, immediately for a preview and a runloop turn later otherwise, so there
    /// is no rotation to ask for here.
    private func reloadConfigurationIfChanged() {
        let file = Self.configurationFile()
        guard file?.data != configurationData else { return }
        configurationData = file?.data

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

    /// The config file in the search order and its content. Nil when there is no file at
    /// all; nil content when the file exists but could not be read.
    private static func configurationFile() -> (url: URL, data: Data?)? {
        guard let url = ResourceLocations.configurationURL() else { return nil }
        return (url, FileManager.default.contents(atPath: url.path))
    }

    /// `config.json` is the whole configuration; there is no second store layered under it.
    ///
    /// `Configuration.load` already warns about a malformed file. No file at all is the
    /// ordinary case and says nothing; a file that exists but cannot be read warns here.
    private static func resolveConfiguration(
        _ file: (url: URL, data: Data?)?
    ) -> Configuration.LoadResult {
        guard let file else {
            return Configuration.LoadResult(configuration: Configuration(), warnings: [])
        }
        guard let data = file.data else {
            return Configuration.LoadResult(
                configuration: Configuration(),
                warnings: ["config.json at \(file.url.path) is unreadable; using defaults"]
            )
        }
        return Configuration.load(data: data)
    }

    private static let logger = Logger(subsystem: "com.matthewsundling.cowsaver", category: "saver")

    private func log(_ message: String) {
        // os_log with an explicit subsystem and public privacy: on macOS 26 the host drops
        // NSLog output from the appex entirely, and the default privacy would redact the
        // message in `log show`. Default level persists to disk for after-the-fact capture.
        Self.logger.log("[Cowsaver] \(message, privacy: .public)")
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
