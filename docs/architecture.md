# Architecture

Cowsaver keeps its cowsay-compatible core independent of macOS so that rendering behavior and content handling remain testable outside the screensaver host.

```text
Sources/
  CowsayKit/       Foundation-only parsing, selection, configuration, and rendering
  CowsayCLI/       cowsaver-cli command-line front end
  CowsaverRender/  AppKit rendering shared by the app and screensaver
  CowsaverSaver/   ScreenSaverView shell and Options sheet
  CowsaverApp/     standalone AppKit front end
```

## Module boundaries

### `CowsayKit`

`CowsayKit` parses static cowfiles, wraps messages, builds balloons, selects fortunes and cowfiles, reads configuration, and produces the next text block. It imports Foundation only, so `swift test` can exercise these behaviors without a screensaver host.

The core keeps byte-level text handling because cowsay counts bytes rather than Unicode characters. It also contains SHA-256 because CryptoKit would make the core Apple-specific. `make check` rejects platform-framework imports in this target.

`AdaptiveWrap` belongs in the core even though it considers screen shape: its `Canvas` input contains only ratios. `CowsaverRender` supplies the font metrics and drawable area, while the core selects a wrap width without owning an AppKit view.

### `CowsaverRender`

`CowsaverRender` resolves themes, calculates layout and auto-fit, hosts the `CATextLayer`, coordinates content rotation, and locates resources. Both front ends use it, so layout and rendering behavior have one implementation. It is a SwiftPM target so the layout and rotation coordinator are covered by tests.

### `CowsaverSaver`

`CowsaverSaver` contains the `ScreenSaverView` subclass, Options sheet, and `ScreenSaverDefaults` integration. It is built by the Makefile because SwiftPM has no product type for a loadable screensaver bundle. The legacy ScreenSaver API is contained here; configuration is represented by the shared `Configuration` type.

### `CowsaverApp`

`CowsaverApp` is the convenient development front end, provides the `--render-to-png` path used by rendering tests, and supports manual fullscreen display when the installed saver is being diagnosed. It does not use ScreenSaver APIs and does not integrate with the lock screen.

## Build system

`Package.swift` defines the core, command-line tool, app, and tests. The Makefile compiles the modules and assembles the `.saver` bundle, then copies the runtime cowfiles and curated fortunes into each product. Xcode Command Line Tools are sufficient.

The screensaver and app link the shared modules statically. This avoids a runtime dynamic-library lookup from a bundle loaded by the sandboxed screensaver host.

## Compatibility evidence

`CowsayKit` is compared with cowsay 3.8.4 through 219 committed golden fixtures. The generator is pinned to that version, and tests compare `Data` rather than `String` so trailing whitespace and invalid UTF-8 are preserved. Details of the modeled Perl behavior live beside the implementation in `CowsayKit`.
