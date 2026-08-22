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
| macOS 26 Tahoe 26.6.1 | Tested; fixes pending verification | 25G76, Apple silicon, with the lifecycle logging streamed live. The clipping in [#2](https://github.com/matthewsundling/cowsaver/issues/2) is host geometry: the host resizes the view to the display's pixel dimensions while the hosting window stays at point dimensions, so content fitted to those bounds is drawn at twice the intended size. Cowsaver now fits content to the window instead, which no Tahoe machine has confirmed yet. The Options sheet of [#1](https://github.com/matthewsundling/cowsaver/issues/1) opens, saves, and closes when System Settings reaches the extension; what remains is that some Options clicks produce no activity anywhere, which relaunching System Settings clears. The sheet itself opened taller than this 1280x828-point display leaves room for, putting its buttons at the bottom edge; it now caps its height and scrolls its controls ([#16](https://github.com/matthewsundling/cowsaver/issues/16)). |

The project began on an Intel MacBook Pro with dual graphics, but Cowsaver makes no hardware-specific compatibility claim.

## Compatibility posture

macOS 26 Tahoe has been tested on Apple silicon, and the failures recorded above are now diagnosed rather than only observed. Cowsaver defends against the clipping and fits its settings sheet to the screen, but neither fix has been exercised on a Tahoe machine, so Tahoe is not yet supported: it is diagnosed, defended, and waiting on a verification pass. One failure is outside Cowsaver's reach — the Options click System Settings sometimes swallows before the extension is contacted — and `Cowsaver.app --configure` opens the same settings window when that happens. The configuration file is the supported configuration path on tested systems; the Options sheet is a convenience. A fresh Tahoe Command Line Tools installation could build and install Cowsaver but could not run `make test` because it lacked Swift Testing; `make test` now reports that limitation clearly, and `make smoke` provides the framework-free golden verification path. See [#4](https://github.com/matthewsundling/cowsaver/issues/4). Each verification pass follows the [macOS compatibility checklist](release-checklist.md), and every completed run belongs in the table above. That checklist records field evidence; the [maintainer release procedure](releasing.md) covers release state transitions separately.

## System Settings

On the tested Sequoia releases, Screen Saver is reached from System Settings → Wallpaper. It is no longer a separate settings pane.

## Host-log diagnosis

Use `scripts/watch-host-logs.sh` while reproducing a problem to see filtered Cowsaver and settings-sheet activity live. Use `scripts/capture-host-logs.sh` after reproducing a problem when a timestamped diagnostic set is more useful. Review every file before sharing: the normal review and transfer set is `doctor.txt`, `sw_vers.txt`, `cowsaver.log`, and `sheet.log`. `host-full.log` contains broad screensaver-host and System Settings history; do not share it unless a maintainer specifically requests it, and only after reviewing and redacting it as needed. Filtered logs can still contain personal paths or context.

## If the screensaver breaks after a macOS update

1. Run `make doctor` and include its output in a report; it identifies the environment that built the installed saver.
2. Rebuild from source on the affected Mac if practical: `make clean && make install`.
3. To tell a host geometry bug from a layout bug, set `"debugFrame": true` in `config.json` and take a screenshot: it draws a red border on the view bounds and a blue border on the text layer.
4. Use the standalone app as a temporary fallback: `./build/Cowsaver.app/Contents/MacOS/Cowsaver --idle 300`. It shares the renderer but does not integrate with screen lock.
5. Open an issue with the `make doctor` output and add a row above.
