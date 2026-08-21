import AppKit
import CowsayKit
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
    for note in engine.diagnostics.notes {
        FileHandle.standardError.write(Data("cowsaver: \(note)\n".utf8))
    }
    return engine
}

// MARK: - Offscreen render, for tests

// Handle this before starting NSApplication so the render path needs no window-server session.
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

// MARK: - Application

final class AppController: NSObject, NSApplicationDelegate, RotationClient {
    private let mode: Mode
    private var configuration: Configuration
    private var engine: CowsaverEngine
    private var windows: [NSWindow] = []
    private var views: [CowsaverContentView] = []
    private var eventMonitor: Any?
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

    // MARK: Presentation

    private func showWindowed() {
        let frame = NSRect(x: 0, y: 0, width: 1024, height: 640)
        let window = NSWindow(contentRect: frame,
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Cowsaver"
        window.center()
        install(view: makeView(frame: frame), in: window)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        rotate()
        RotationCoordinator.shared.register(self, interval: configuration.rotationInterval)
    }

    private func show() {
        guard !isShowing else { return }
        isShowing = true

        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless],
                                  backing: .buffered, defer: false, screen: screen)
            window.level = .screenSaver
            window.isOpaque = true
            window.ignoresMouseEvents = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            window.setFrame(screen.frame, display: true)
            install(view: makeView(frame: NSRect(origin: .zero, size: screen.frame.size)),
                    in: window)
            window.orderFrontRegardless()
        }

        // Any input dismisses. A global monitor would need accessibility permission; a
        // local one is enough because our windows are key while covering the screen.
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown,
                       .mouseMoved, .scrollWheel]
        ) { [weak self] event in
            self?.dismiss()
            return nil
        }
        NSApp.activate(ignoringOtherApps: true)

        rotate()
        RotationCoordinator.shared.register(self, interval: configuration.rotationInterval)
    }

    private func dismiss() {
        guard isShowing else { return }
        isShowing = false
        RotationCoordinator.shared.unregister(self)
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
        eventMonitor = nil
        for window in windows { window.orderOut(nil) }
        windows.removeAll()
        views.removeAll()

        if case .idle = mode { return }   // keep waiting
        NSApp.terminate(nil)
    }

    private func makeView(frame: NSRect) -> CowsaverContentView {
        CowsaverContentView(frame: frame, configuration: configuration,
                            seed: UInt64.random(in: 0 ..< .max))
    }

    private func install(view: CowsaverContentView, in window: NSWindow) {
        view.autoresizingMask = [.width, .height]
        window.contentView = view
        windows.append(window)
        views.append(view)
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
        for view in views { view.apply(configuration: updated) }
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

    var isLive: Bool { isShowing || !windows.isEmpty }

    func rotate() {
        // Produce content per view. The app owns all fullscreen windows under one engine,
        // while the saver gets a separately seeded engine for each host-created view.
        for view in views {
            view.present(engine.nextBlock(fitting: view.canvas),
                         animated: configuration.wantsTransition)
        }
    }
}

let controller = AppController(mode: mode)
let application = NSApplication.shared
application.delegate = controller
application.run()
