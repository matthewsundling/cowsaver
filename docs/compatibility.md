# Compatibility

Third-party macOS screensavers use a deprecated surface. This document records what has actually been checked. Cowsaver has a macOS 13.0 deployment target; that is a build setting, not a compatibility claim for every release from macOS 13 onward.

**Please add a row if you build or run Cowsaver anywhere not listed.** `make doctor` records the OS, architecture, Command Line Tools, Swift compiler, and installed saver metadata needed for a useful report.

## Known results

| macOS version | Status | Notes |
|---|---|---|
| Sequoia 15.7.5 | Tested | Screensaver and preview work. |
| Sequoia 15.7.7 | Tested | Screensaver and preview work. |
| Sequoia 15.7.8 | Tested | Screensaver and preview work. Development machine: 24G824, x86_64, Swift 6.1.2 Command Line Tools. |
| Sequoia 15.7.9 | Tested | Screensaver and preview work. |
| macOS 26 Tahoe 26.4.1 | Tested; not supported | On Apple silicon, Cowsaver builds, installs, and can be selected, but the Options sheet does not open and timer-based activation can clip content. See [#1](https://github.com/matthewsundling/cowsaver/issues/1) and [#2](https://github.com/matthewsundling/cowsaver/issues/2). |

The project began on an Intel MacBook Pro with dual graphics, but Cowsaver makes no hardware-specific compatibility claim.

## Compatibility posture

macOS 26 Tahoe 26.4.1 has been tested on Apple silicon, but Cowsaver is not currently supported there because of the failures recorded above. The configuration file is the supported configuration path on tested systems; the Options sheet is a convenience. A fresh Tahoe Command Line Tools installation could build and install Cowsaver but could not run `make test` because it lacked Swift Testing; see [#4](https://github.com/matthewsundling/cowsaver/issues/4).

## System Settings

On the tested Sequoia releases, Screen Saver is reached from System Settings → Wallpaper. It is no longer a separate settings pane.

## If the screensaver breaks after a macOS update

1. Run `make doctor` and include its output in a report; it identifies the environment that built the installed saver.
2. Rebuild from source on the affected Mac if practical: `make clean && make install`.
3. Use the standalone app as a temporary fallback: `./build/Cowsaver.app/Contents/MacOS/Cowsaver --idle 300`. It shares the renderer but does not integrate with screen lock.
4. Open an issue with the `make doctor` output and add a row above.
