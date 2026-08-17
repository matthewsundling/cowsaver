# Platform risk

This document lists the Apple APIs Cowsaver depends on, the effect of a failure, and the mitigation that exists today.

| API or host | Used by | Status | If it fails | Current mitigation |
|---|---|---|---|---|
| `ScreenSaverView` | `CowsaverSaver` | Deprecated since Catalina; no public replacement is available. | The installed `.saver` may not load or render. | Use `Cowsaver.app --fullscreen` for manual display while diagnosing the saver. The cowsay core and renderer remain separate from the screensaver shell. |
| `ScreenSaverDefaults` | `CowsaverSaver` | Legacy ScreenSaver API. | Values saved by the Options sheet may no longer be read. | `config.json` is the supported configuration path and overrides those values. |
| `legacyScreenSaver.appex` host | macOS host process for the `.saver` | Apple-managed and sandboxed. | Lifecycle callbacks may be incomplete or views may remain attached longer than expected. | `RotationCoordinator` uses weak clients, removes detached views, and stops its timer when no clients remain. |
| `NSView` and `CATextLayer` | `CowsaverRender` | Current AppKit and Core Animation APIs. | Text rendering fails. | No separate fallback renderer is provided. |
| `CABasicAnimation` | `CowsaverRender` | Current Core Animation API. | The optional fade may not run. | Set `"transition": "none"`; content remains readable without the fade. |
| `NSFont` and `NSAttributedString` | `CowsaverRender` | Current AppKit APIs. | Font resolution fails. | The font resolver falls back through Menlo, SF Mono, Monaco, Courier New, and `monospacedSystemFont`. |
| `CGEventSource.secondsSinceLastEventType` | `CowsaverApp --idle` | Public API. | Idle-triggered activation stops working. | `--fullscreen` and the installed `.saver` remain available. |
| `IOPMCopyAssertionsStatus` | `CowsaverApp --idle` | Stable IOKit API. | The app cannot detect a display-sleep assertion. | The check fails open, so `--idle` may activate over video playback. |
| `NSApplication` and `NSWindow` | `CowsaverApp` | Current AppKit APIs. | The standalone app cannot run. | No separate app fallback is provided. |
| `FileManager` and `JSONSerialization` | `CowsayKit` | Foundation APIs. | Configuration or resource loading fails. | The engine uses compiled-in cow and fortune fallback content. |

## Deliberately excluded dependencies

- Metal, MetalKit, SceneKit, SpriteKit, GLKit, and OpenGL are unnecessary for static text presentation. `make check` rejects their imports.
- WKWebView is unnecessary for the bundled content and would add a browser rendering surface.
- Quartz Composer is deprecated and is not needed for rotation-based content updates.
- CryptoKit would make `CowsayKit` Apple-specific; the core includes its own SHA-256 implementation.
- Cowsaver's tests use Swift Testing rather than XCTest. The products build with Command Line Tools, but the test suite requires a Swift toolchain that includes Swift Testing; fresh macOS 26.4.1 Command Line Tools 26.6 did not provide it. See [issue #4](https://github.com/matthewsundling/cowsaver/issues/4).
- Apple has not published a public App Extension replacement for legacy screensavers.
- An `.xcodeproj` is not required by the Package.swift and Makefile build.

See [architecture.md](architecture.md) for the module boundaries.
