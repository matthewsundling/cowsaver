import AppKit
import CoreGraphics
import CowsayKit
import CowsaverAppSupport
import CowsaverRender
import Foundation

// Cowsaver.app — the standalone front end.
//
// `--window` supports interactive development, `--render-to-png` drives offscreen rendering
// tests, `--configure` edits the shared settings, and `--fullscreen` provides manual display.
// This target imports no ScreenSaver APIs and does not participate in screen lock.

enum Mode {
    case window
    case fullscreen
    case idle(TimeInterval)
    case configure
    case renderPNG(path: String, size: CGSize)
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("cowsaver: \(message)\n".utf8))
    exit(1)
}

// MARK: - Arguments

var mode = Mode.window
var arguments = Array(CommandLine.arguments.dropFirst())
var index = 0

func nextValue(_ flag: String) -> String {
    index += 1
    guard index < arguments.count else { fail("\(flag) requires a value") }
    return arguments[index]
}

while index < arguments.count {
    switch arguments[index] {
    case "--window":
        mode = .window
    case "--fullscreen":
        mode = .fullscreen
    case "--idle":
        guard let seconds = TimeInterval(nextValue("--idle")), seconds > 0 else {
            fail("--idle expects a positive number of seconds")
        }
        mode = .idle(seconds)
    case "--configure":
        mode = .configure
    case "--render-to-png":
        let path = nextValue("--render-to-png")
        mode = .renderPNG(path: path, size: CGSize(width: 1280, height: 800))
    case "--help", "-h":
        print("""
        Cowsaver — a fortune | cowsay screensaver

        Usage: Cowsaver [--window | --fullscreen | --idle SECONDS | --configure]

          --window            windowed, for development (default)
          --fullscreen        cover every screen now
          --idle SECONDS      wait for the user to go idle, then cover every screen.
                              Skips activation while anything holds a display-sleep
                              assertion, so it will not cover a video.
          --configure         open the settings window and write config.json

        Configuration lives in a JSON file, not in this binary.
        See docs/configuration.md.

        This app does not integrate with screen lock and will not display on the lock
        screen. For that, install the screensaver: make install
        """)
        exit(0)
    default:
        fail("unknown option \(arguments[index])")
    }
    index += 1
}

// MARK: - Shared setup

func loadConfiguration() -> Configuration {
    guard let url = ResourceLocations.configurationURL() else { return Configuration() }
    let result = Configuration.load(contentsOf: url)
    for warning in result.warnings { FileHandle.standardError.write(Data("cowsaver: \(warning)\n".utf8)) }
    return result.configuration
}

func makeEngine(_ configuration: Configuration, seed: UInt64) -> CowsaverEngine {
    let bundle = Bundle.main
    let engine = CowsaverEngine(
        configuration: configuration,
        cowDirectories: ResourceLocations.cowDirectories(bundle: bundle),
        fortuneDirectories: ResourceLocations.fortuneDirectories(bundle: bundle),
        seed: seed
    )
    for message in engine.diagnostics.messages {
        FileHandle.standardError.write(Data("cowsaver: \(message)\n".utf8))
    }
    return engine
}

// MARK: - Offscreen render, for tests

// This runs before the app event loop and creates no visible window, but AppKit rendering still requires a GUI-capable user session.
if case .renderPNG(let path, let size) = mode {
    let configuration = loadConfiguration()
    let engine = makeEngine(configuration, seed: 1)

    // Top-level code runs on the main thread, satisfying ImageRenderer's main-actor requirement.
    let rendered = MainActor.assumeIsolated {
        let canvas = Layout.canvas(theme: Theme(configuration: configuration), in: size)
        return ImageRenderer.png(block: engine.nextBlock(fitting: canvas),
                                 configuration: configuration, size: size)
    }
    guard let png = rendered else { fail("could not render an image") }
    do {
        try png.write(to: URL(fileURLWithPath: path))
    } catch {
        fail("could not write \(path): \(error.localizedDescription)")
    }
    exit(0)
}

// MARK: - Fullscreen presentation

/// A borderless standalone fullscreen/idle window that can still become key.
///
/// An ordinary borderless `NSWindow`'s `canBecomeKey` is `false`. Without this override, no
/// window built for `--fullscreen`/`--idle` could ever receive keyboard events or become the
/// app's key window, regardless of how it is ordered — `orderFrontRegardless()` changes
/// ordering only. It has no need to become the main window. Mouse-movement delivery is a
/// separate concern, established per window by `acceptsMouseMovedEvents`.
final class FullscreenWindow: NSWindow {
    override var canBecomeKey: Bool { true }
}

/// Stable per-screen identity for reconciling owned fullscreen presentations against
/// `NSScreen.screens` across a display-configuration change.
///
/// `CGDirectDisplayID` is what stays stable when a screen's resolution, arrangement, or
/// frame changes; array position and frame geometry are exactly what churns during that
/// change and would misidentify a retained display as removed-and-added.
enum ScreenIdentity: Hashable {
    case display(CGDirectDisplayID)
    /// Only for the rare snapshot whose device dictionary lacks a screen number. Tied to
    /// this particular `NSScreen` instance, so a later snapshot's object for the same
    /// physical display compares unequal — that display is treated as removed and
    /// re-added rather than silently misidentified as retained.
    case fallback(ObjectIdentifier)

    init(screen: NSScreen) {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber {
            self = .display(CGDirectDisplayID(number.uint32Value))
        } else {
            self = .fallback(ObjectIdentifier(screen))
        }
    }
}

/// One owned fullscreen presentation: a window, its content view, and the stable identity
/// of the display it covers, kept together so reconciliation cannot let those three drift
/// out of sync.
struct Presentation {
    let identity: ScreenIdentity
    let window: NSWindow
    let view: CowsaverContentView
}

// MARK: - Application

final class AppController: NSObject, NSApplicationDelegate, RotationClient {
    private let mode: Mode
    private var configuration: Configuration
    private var engine: CowsaverEngine
    private var presentations: [Presentation] = []
    /// The single window in `--window` mode, held strongly. `NSView.window` is
    /// `unsafe_unretained`, so `windowedView` alone would not keep this window alive.
    private var windowedWindow: NSWindow?
    /// The single window's view in `--window` mode. Reconciliation and display identity are
    /// fullscreen-only concerns; windowed mode never has more than this one view.
    private var windowedView: CowsaverContentView?
    private var eventMonitor: Any?
    /// Installed only while fullscreen/idle content is visible; see `installDisplayObserver()`.
    private var displayObserver: NSObjectProtocol?
    private var idleTimer: DispatchSourceTimer?
    private var isShowing = false
    private var settings: ConfigurationSheet?

    init(mode: Mode) {
        self.mode = mode
        let configuration = loadConfiguration()
        self.configuration = configuration
        self.engine = makeEngine(configuration, seed: UInt64.random(in: 0 ..< .max))
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        switch mode {
        case .window:
            NSApp.setActivationPolicy(.regular)
            installMenu()
            showWindowed()
        case .fullscreen:
            NSApp.setActivationPolicy(.accessory)
            show()
        case .idle(let threshold):
            // Remain an accessory app until the idle threshold is reached.
            NSApp.setActivationPolicy(.accessory)
            startIdleWatch(threshold: threshold)
        case .configure:
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            // Leave the launch callback before running a modal loop in it.
            DispatchQueue.main.async { [weak self] in
                self?.presentSettings()
                NSApp.terminate(nil)
            }
        case .renderPNG:
            break   // handled above
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        if case .window = mode { return true }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Fullscreen/idle dismissal already tears its own presentation down; this also
        // covers the windowed lifecycle and any termination that arrives while still
        // visible, so no observer, monitor, or window outlives the process on any path.
        if isShowing {
            isShowing = false
            teardownVisiblePresentation()
        }
        RotationCoordinator.shared.unregister(self)
    }

    // MARK: Presentation

    private func showWindowed() {
        let frame = NSRect(x: 0, y: 0, width: 1024, height: 640)
        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Cowsaver"
        window.center()
        windowedWindow = window
        let view = makeView(frame: frame)
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        windowedView = view
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        rotate()
        RotationCoordinator.shared.register(self, interval: configuration.rotationInterval)
    }

    private func show() {
        guard !isShowing else { return }
        isShowing = true

        for (identity, screen) in currentScreensByIdentity() {
            let presentation = makePresentation(for: screen, identity: identity)
            presentations.append(presentation)
            presentation.window.orderFrontRegardless()
        }

        // Ordering alone does not request key status; explicitly key one owned window
        // before any input can be dismissed, so the local monitor below always has a real
        // key-and-mouse-moved-capable window behind it.
        NSApp.activate(ignoringOtherApps: true)
        makeCurrentPresentationKey(preferring: NSEvent.mouseLocation)

        installEventMonitor()
        installDisplayObserver()

        rotate()
        RotationCoordinator.shared.register(self, interval: configuration.rotationInterval)
    }

    private func dismiss() {
        guard isShowing else { return }
        isShowing = false
        teardownVisiblePresentation()
        RotationCoordinator.shared.unregister(self)

        if case .idle = mode { return }   // keep waiting
        NSApp.terminate(nil)
    }

    /// Removes the event monitor and display observer, then releases every owned window.
    /// Safe to call once per visible lifetime; both `dismiss()` and termination-while-visible
    /// route through this so neither can double-remove or leak either registration.
    private func teardownVisiblePresentation() {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        displayObserver = nil
        for presentation in presentations { presentation.window.orderOut(nil) }
        presentations.removeAll()
    }

    /// Installs exactly one local monitor for the visible presentation's lifetime. A global
    /// monitor would need Accessibility permission; a local one is enough because it sees
    /// every matching event AppKit delivers to this active application. Keying a presentation
    /// window is what makes it eligible to receive keyboard events at all; each fullscreen
    /// window's `acceptsMouseMovedEvents` is what makes `.mouseMoved` deliverable.
    private func installEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown,
                       .otherMouseDown, .mouseMoved, .scrollWheel]
        ) { [weak self] event in
            self?.dismiss()
            return nil
        }
    }

    /// Installs the attached-display observer for the visible presentation's lifetime only:
    /// never while waiting for `--idle`, and never in `--window`/`--configure`, where no
    /// presentation exists to reconcile. AppKit posts this notification on the main actor
    /// with no useful `userInfo`, so reconciliation rereads `NSScreen.screens` itself.
    private func installDisplayObserver() {
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: nil
        ) { [weak self] _ in
            self?.reconcileDisplays()
        }
    }

    /// The current screens keyed by stable identity, keeping only the first screen seen for
    /// a duplicate identity so a defective snapshot never produces two owned windows for the
    /// same display.
    private func currentScreensByIdentity() -> [(identity: ScreenIdentity, screen: NSScreen)] {
        var seen = Set<ScreenIdentity>()
        var ordered: [(identity: ScreenIdentity, screen: NSScreen)] = []
        for screen in NSScreen.screens {
            let identity = ScreenIdentity(screen: screen)
            guard seen.insert(identity).inserted else { continue }
            ordered.append((identity, screen))
        }
        return ordered
    }

    /// Reconciles owned fullscreen presentations against the current display set. Runs on
    /// every `didChangeScreenParametersNotification` while visible, synchronously on the
    /// main thread the notification already arrives on.
    ///
    /// A retained display keeps its window and view and only has its frame updated;
    /// `CowsaverContentView` refits its current block on that frame change on its own, so
    /// this never chooses a new fortune merely because resolution or arrangement changed. An
    /// added display gets a new presentation, populated immediately so it is never blank
    /// until the next rotation. A removed display's presentation is ordered out and dropped.
    private func reconcileDisplays() {
        let current = currentScreensByIdentity()

        var retained: [Presentation] = []
        for presentation in presentations {
            if let match = current.first(where: { $0.identity == presentation.identity }) {
                presentation.window.setFrame(match.screen.frame, display: true)
                retained.append(presentation)
            } else {
                presentation.window.orderOut(nil)
            }
        }
        presentations = retained

        let retainedIdentities = Set(presentations.map(\.identity))
        for (identity, screen) in current where !retainedIdentities.contains(identity) {
            let presentation = makePresentation(for: screen, identity: identity)
            presentation.window.orderFrontRegardless()
            presentations.append(presentation)
            presentation.view.present(engine.nextBlock(fitting: presentation.view.canvas),
                                      animated: configuration.wantsTransition)
        }

        // A transient empty snapshot leaves no current screen to reconcile against, so
        // every presentation above was just dropped as "removed." There is nothing left to
        // key; a later notification with real screens repopulates and rekeys normally.
        guard !presentations.isEmpty else { return }

        // If the previous key window survived, ordering and frame updates above never
        // touched its key status, so there is nothing further to do. Otherwise it was
        // removed (or never existed), so explicitly key a current one the same way initial
        // presentation does.
        guard !presentations.contains(where: { $0.window.isKeyWindow }) else { return }
        makeCurrentPresentationKey(preferring: NSEvent.mouseLocation)
    }

    /// Builds one fullscreen window/view pair for `screen`, but does not order or key it —
    /// callers decide that, since initial presentation and reconciliation order differently.
    private func makePresentation(for screen: NSScreen, identity: ScreenIdentity) -> Presentation {
        let window = FullscreenWindow(contentRect: screen.frame, styleMask: [.borderless],
                                      backing: .buffered, defer: false, screen: screen)
        window.level = .screenSaver
        window.isOpaque = true
        window.ignoresMouseEvents = false
        window.acceptsMouseMovedEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.setFrame(screen.frame, display: true)

        let view = makeView(frame: NSRect(origin: .zero, size: screen.frame.size))
        view.autoresizingMask = [.width, .height]
        window.contentView = view

        return Presentation(identity: identity, window: window, view: view)
    }

    /// Explicitly requests key status for one owned fullscreen window, since ordering
    /// (`orderFrontRegardless()`) never does that by itself. The screen under the pointer is
    /// a reasonable, deterministic choice; which covered screen is key is not itself
    /// user-visible, so the fallback to the first current presentation is just as valid.
    private func makeCurrentPresentationKey(preferring point: NSPoint) {
        // Each fullscreen window's frame is already set to the exact frame of the display it
        // owns, so testing the window's own frame picks the same presentation `window.screen`
        // would, without depending on AppKit having resolved `screen` this soon after
        // construction/frame assignment.
        let chosen = presentations.first { $0.window.frame.contains(point) }
            ?? presentations.first
        chosen?.window.makeKeyAndOrderFront(nil)
    }

    private func makeView(frame: NSRect) -> CowsaverContentView {
        CowsaverContentView(frame: frame, configuration: configuration,
                            seed: UInt64.random(in: 0 ..< .max))
    }

    // MARK: Settings

    /// A menu bar, so the settings window has a keyboard route in windowed mode.
    private func installMenu() {
        let appMenu = NSMenu()
        let settingsItem = appMenu.addItem(withTitle: "Settings…",
                                           action: #selector(showSettings),
                                           keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Cowsaver",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let menu = NSMenu()
        menu.addItem(appItem)
        NSApp.mainMenu = menu
    }

    @objc private func showSettings() { presentSettings() }

    /// The shared sheet, shown as an ordinary window. Running it modally matches how its
    /// Cancel and OK buttons close it when it has no sheet parent.
    private func presentSettings() {
        let sheet = ConfigurationSheet(configuration: configuration) { [weak self] updated in
            self?.applySaved(updated)
        }
        // This is only the initial hint: no sheet parent ever attaches in this standalone
        // path, so once shown, the window's own screen takes over as the authoritative
        // source. `NSScreen.main` is the last resort, for when neither a key nor a main
        // window exists yet (the `--configure` launch path) — this app owns the unparented
        // window's location outright, so that fallback is appropriate here.
        let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main
        sheet.prepareForPresentation(on: screen)
        settings = sheet   // nothing else retains it while it is on screen
        sheet.window.center()
        sheet.window.makeKeyAndOrderFront(nil)
        NSApp.runModal(for: sheet.window)
        settings = nil
    }

    /// The sheet has already validated and written `config.json` by the time this runs.
    /// Bring this process into line with what it wrote.
    private func applySaved(_ updated: Configuration) {
        print(ResourceLocations.canonicalConfigurationURL().path)

        configuration = updated
        windowedView?.apply(configuration: updated)
        for presentation in presentations { presentation.view.apply(configuration: updated) }
        // Settings that change which content is loaded need a new engine, not just a redraw.
        engine = makeEngine(updated, seed: UInt64.random(in: 0 ..< .max))
        // Re-registering an existing client updates the interval it rotates at.
        if isLive {
            RotationCoordinator.shared.register(self, interval: updated.rotationInterval)
        }
        rotate()
    }

    // MARK: Idle watching

    private func startIdleWatch(threshold: TimeInterval) {
        // Poll idle state every five seconds. This is separate from content rendering and
        // is only used by the standalone app's optional idle mode.
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isShowing else { return }
            if IdleMonitor.shouldActivate(afterIdleSeconds: threshold) { self.show() }
        }
        idleTimer = timer
        timer.resume()
    }

    // MARK: RotationClient

    var isLive: Bool { isShowing || !presentations.isEmpty || windowedView != nil }

    func rotate() {
        // Produce content per view. The app owns all fullscreen windows under one engine,
        // while the saver gets a separately seeded engine for each host-created view.
        if let windowedView {
            windowedView.present(engine.nextBlock(fitting: windowedView.canvas),
                                 animated: configuration.wantsTransition)
        }
        for presentation in presentations {
            presentation.view.present(engine.nextBlock(fitting: presentation.view.canvas),
                                      animated: configuration.wantsTransition)
        }
    }
}

let controller = AppController(mode: mode)
let application = NSApplication.shared
application.delegate = controller
application.run()
