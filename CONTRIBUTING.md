# Contributing

Patches are welcome. This guide explains the project constraints contributors should preserve and the checks that support them. Participation in the project is governed by `CODE_OF_CONDUCT.md`.

## Build and test

Xcode Command Line Tools are sufficient to build both products; the project does not require the
full Xcode app or an Xcode project file. The full test suite is separate: `swift test` requires a
toolchain that supplies Swift Testing.

```sh
make check             # source-boundary checks
make test              # full Swift Testing suite, including the golden fixtures
make smoke             # framework-free byte comparison of the 219 golden fixtures
make test-diagnostics  # tests the host-log diagnostic tools
make                   # builds Cowsaver.saver and Cowsaver.app
make doctor            # build environment and installed-saver metadata
```

`make check` proves the maintained source boundaries. `make test` exercises the Swift test suite;
if its toolchain lacks Swift Testing, it explains that limitation. `make smoke` runs only the 219
cowsay-byte fixtures through `cowsaver-cli`; it does not exercise AppKit layout, bundle loading,
configuration, or screen presentation. `make test-diagnostics` checks the diagnostic scripts.

## Project constraints

### Keep the rendering surface small

Do not import Metal, MetalKit, SceneKit, SpriteKit, WebKit, GLKit, or OpenGL in `Sources/`. Cowsaver presents static text that changes on a long rotation interval, so these frameworks are unnecessary. `make check` and CI enforce this source boundary.

If a proposed feature genuinely requires one of these frameworks, discuss its effect on the project before implementing it.

### Do not add an application-owned render loop

Cowsaver does not override `animateOneFrame()`. `RotationCoordinator` schedules content changes, while `ScreenSaverView` retains its required infrequent default callback. See `docs/power.md` for the runtime model and measurement limits.

### Keep `CowsayKit` Foundation-only

`CowsayKit` must not import AppKit, Cocoa, ScreenSaver, CoreGraphics, QuartzCore, SwiftUI, or CryptoKit. Configuration, parsing, selection, and rendering behavior remain testable in the portable core; shared rendering platform code belongs in `CowsaverRender`, while standalone app-only platform code belongs in `CowsaverAppSupport` or the app front end. `make check` enforces the framework boundary.

SHA-256 is implemented in the core rather than imported from CryptoKit so the core remains Foundation-only.

### Keep the text build system

The repository uses `Package.swift` and `Makefile`; do not add an `.xcodeproj`. The Makefile assembles the loadable `.saver` bundle, which SwiftPM cannot produce directly, and the text build files are easy to inspect in review.

### Preserve tested cowsay behavior

`CowsayKit` matches cowsay 3.8.4 for the 219 committed golden cases, including trailing whitespace. If a rendering change intentionally affects a golden, regenerate it with `make golden` using cowsay 3.8.4 and describe the changed behavior in the pull request. The generator refuses other cowsay versions.

### Treat resource failures as recoverable

A screensaver should remain usable when a bundled or imported resource is malformed or missing. Do not force-unwrap values derived from file content or use `try!` on a resource path. When a new load failure is possible, provide a proportionate fallback and test it.

## Content

Cow art and fortune quotations are third-party material. See `credits.md`, `Resources/cows/provenance.md`, and `Resources/fortune-curated/provenance.md`.

- Preserve `##` comment headers in `.cow` files verbatim; they carry artist attribution.
- Do not add records to `Resources/fortune-upstream/`; it mirrors fortune-mod 9708 and its checksums must continue to verify.

### Removing a quote

Follow `Resources/fortune-curated/provenance.md`: remove the record from the curated corpus, record the dated decision in `curation.tsv`, and leave the preserved import unchanged.

## Style

Match the surrounding code. Comments should explain non-obvious behavior and constraints: cowsay's byte-based wrapping, `Text::Wrap`'s reserved final column, `-t` selecting tired eyes, and the static cowfile subset are good examples.

Typically, comments lead with one short sentence that stands alone, then a blank /// line, then the reasoning-- the constraint, the rejected alternative, the bug it prevents. Explain intent, not mechanics.

## Reporting compatibility

If you build or run Cowsaver on a macOS version not listed in `docs/compatibility.md`, please add a row. `make doctor` prints the information needed for a useful report.

## Security reports

Do not open a public issue for a suspected security vulnerability. Follow the reporting instructions in [SECURITY.md](SECURITY.md).
