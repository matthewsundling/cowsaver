# Compatibility

Third-party macOS screensavers use a deprecated surface. This document records what has actually been checked. Cowsaver has a macOS 13.0 deployment target; that is a build setting, not a compatibility claim for every release from macOS 13 onward.

**Please add a row if you build or run Cowsaver anywhere not listed.** `make doctor` records the OS, architecture, Command Line Tools, Swift compiler, and installed saver metadata needed for a useful report.

## Known results

| macOS version | Status | Notes |
|---|---|---|
| Sonoma 14.5 | Tested | 23F79, arm64. See the Sonoma 14.5 field pass below. |
| Sequoia 15.7.5 | Tested | Screensaver and preview work. |
| Sequoia 15.7.7 | Tested | Screensaver and preview work. |
| Sequoia 15.7.8 | Tested | Screensaver and preview work. Development machine: 24G824, x86_64, Swift 6.1.2 Command Line Tools. |
| Sequoia 15.7.9 | Tested | Screensaver and preview work. |
| macOS 26 Tahoe 26.4.1 | Tested; failures and evidence gaps remain | 25E253 on an Apple M2 Pro (arm64), Command Line Tools 26.6, Swift 6.3.3, commit `b2738b4`. Build, install, repository checks, and 219/219 smoke fixtures passed. Preview, Hot Corner, and one-minute idle activation kept content normally sized and contained when Tahoe supplied 3456x2234-pixel view bounds inside a 1728x1117-point window, directly verifying the defense for closed [#2](https://github.com/matthewsundling/cowsaver/issues/2). With Clock Appearance enabled, however, the date/clock group overlapped Cowsaver content in all three activation paths ([#66](https://github.com/matthewsundling/cowsaver/issues/66)). The settings Preview drew amber text on a light background ([#65](https://github.com/matthewsundling/cowsaver/issues/65)); standalone settings saved but scrolled slowly without retained timing measurements ([#67](https://github.com/matthewsundling/cowsaver/issues/67)); and Options opened on 7 of 13 timed attempts but failed five controlled `Cancel → Done → Screen Saver → Options` repetitions ([#1](https://github.com/matthewsundling/cowsaver/issues/1)). Relaunching System Settings restored Options, but the host/package/race cause remains unclassified. Configuration recovery and six fullscreen dismissal paths passed. The GPU check was invalid because it classified Apple unified graphics as discrete ([#68](https://github.com/matthewsundling/cowsaver/issues/68)). The exact host's Command Line Tools lacked Swift Testing; the same commit later passed the full suite in [Tahoe CI](https://github.com/matthewsundling/cowsaver/actions/runs/33895796276). No external display or standalone `--idle 10` result was recorded. |
| macOS 26 Tahoe 26.6.1 | Tested; historical host diagnosis | 25G76, Apple silicon, with lifecycle logging streamed live. The clipping in [#2](https://github.com/matthewsundling/cowsaver/issues/2) was diagnosed as pixel-sized view bounds inside a point-sized hosting window. The subsequent 26.4.1 pass above directly verifies Cowsaver's window-fitting defense. Options opened, saved, and closed whenever System Settings reached the extension; the later 26.4.1 pass showed missing attempts with no Cowsaver request, but an independent comparison saver is still required to classify the cause. The settings sheet had also exceeded the available height of this 1280x828-point display; its screen-height cap and scrolling controls are tracked by closed [#16](https://github.com/matthewsundling/cowsaver/issues/16). |

The project began on an Intel MacBook Pro with dual graphics, but Cowsaver makes no hardware-specific compatibility claim.

## Sonoma 14.5 field pass

The Sonoma pass used macOS Sonoma 14.5 (23F79) on arm64, Xcode Command Line Tools
16.2.0.0.1.1733547573, and Apple Swift 6.0.3 (swiftlang-6.0.3.1.10). It tested commit
`8b1cc95`. `make install` and `make app` succeeded; `make test` passed 311 tests; and
`make smoke` matched 219/219 goldens.

System Settings selection, preview, Options editing and saving, saver activation, small preview
layout, and settings behavior were observed working without clipping. The standalone app remained
correctly fitted while an external display was connected and disconnected during fullscreen use.
No screenshots were retained.

The first-use Reveal button showed that a missing `config.json` had no visible explanation. The
inline explanation was added in commit `5850335` after this pass, so it was not part of the
Sonoma evidence.

## Compatibility posture

macOS 26 Tahoe has been tested on Apple silicon. The 26.4.1 pass directly exercised the window-fitting defense, and the original timer-clipping failure is resolved. Tahoe is still not supported: the settings Preview background is wrong; standalone settings scrolling is slow but uncharacterized; System Settings reproducibly loses Options after `Cancel → Done → Screen Saver → Options` for a cause not yet isolated; and Tahoe's clock/date group overlaps Cowsaver content in every recorded clock-on activation path. The retained GPU result is invalid because the diagnostic called Apple unified graphics discrete. The completed field evidence covers one built-in display, not external-display behavior or app display reconciliation.

The configuration file remains the supported configuration path on tested systems. A fresh Tahoe Command Line Tools installation could build and install Cowsaver but could not run `make test` because it lacked Swift Testing; `make test` reports that limitation clearly, and `make smoke` passed all 219 framework-free golden fixtures. The same commit later passed the full Swift suite in [Tahoe CI](https://github.com/matthewsundling/cowsaver/actions/runs/33895796276), which is source-level evidence rather than exact-host or System Settings verification. See closed [#4](https://github.com/matthewsundling/cowsaver/issues/4) and the [Tahoe reconciliation tracker](https://github.com/matthewsundling/cowsaver/issues/69). Each verification pass follows the [macOS compatibility checklist](release-checklist.md), and every completed run belongs in the table above. That checklist records field evidence; the [maintainer release procedure](releasing.md) covers release state transitions separately.

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
