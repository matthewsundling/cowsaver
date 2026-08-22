# Cowsaver

**A `fortune | cowsay` screensaver for macOS. Native Swift, zero dependencies, low idle activity.**

Created and maintained by [C. Matthew Sundling](https://github.com/matthewsundling).

*The cows and fortunes are other people’s work. This project is a renderer and screensaver shell.* See [credits.md](credits.md).

```text
 _______________________________________
/ Duct tape is like the force. It has a \
| light side, and a dark side, and it   |
| holds the universe together ...       |
|                                       |
\ -- Carl Zwanzig                       /
 ---------------------------------------
        \   ^__^
         \  (oo)\_______
            (__)\       )\/\
                ||----w |
                ||     ||
```

## Screenshots

![Cowsaver in green-phosphor, with the classic cowsay cow](docs/images/cowsaver-green-phosphor.png)

![Cowsaver in amber](docs/images/cowsaver-amber.png)

![Cowsaver in paperwhite](docs/images/cowsaver-paperwhite.png)

## What it includes

- **Cowsaver.saver** — a native macOS `fortune | cowsay` screensaver, built with Xcode Command Line Tools.
- **3,470 curated fortunes** and 47 static cowsay cowfiles, with upstream material and attribution preserved separately.
- **CowsayKit** — a pure-Swift cowsay-compatible rendering core, tested against committed output from cowsay 3.8.4; no Perl or subprocess is required.
- **Cowsaver.app** — a standalone development and fallback app. It is not a lock-screen screensaver.
- **Low idle activity** — Cowsaver renders when its content rotates rather than running a continuous animation loop.

Built with a macOS 13.0 deployment target. Verified on macOS Sequoia 15.7.5, 15.7.7, 15.7.8, and 15.7.9. macOS 26 Tahoe 26.4.1 was tested on Apple silicon but is not currently supported: the Options sheet does not open and timer-based activation can clip content. See [compatibility notes](docs/compatibility.md).

## Install

Cowsaver is built from source and installed locally; it is not Developer ID signed.

```sh
make install
```

Then open System Settings → Wallpaper → Screen Saver and select Cowsaver. macOS may ask you to approve the unsigned screensaver the first time it runs.

The [install guide](docs/install.md) walks through this step by step, from a Mac with nothing installed to a running screensaver, and covers what to do when something does not work.

To remove it:

```sh
make uninstall
```

If Cowsaver does not appear or run as expected, start with:

```sh
make doctor
```

It shows the macOS, Command Line Tools, Swift, and build information for the installed saver.

## Configuration

Cowsaver reads its settings from:

```text
~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/Cowsaver/config.json
```

Create or edit that file to change the rotation interval, cow selection, appearance, and layout. The Options sheet is a convenience when macOS makes it available; the config file is the supported configuration path.

The [configuration reference](docs/configuration.md) documents every key, its default, and what happens when a value is wrong. [`docs/config.example.json`](docs/config.example.json) is a complete file to copy and edit; `.build/debug/cowsaver-cli --print-default-config` prints the shipped defaults.

Cowsaver includes 47 of the 51 cowfiles distributed with cowsay 3.8.4; the four omitted cowfiles rely on executable Perl rather than static cow art. Unlike cowsay’s configurable `COWPATH`, Cowsaver uses this bundled set. The [configuration reference](docs/configuration.md) lists the 47 names.

The screensaver's Options sheet and the app's settings window are two views of the same window, and both write `config.json` — there is no second store. An invalid value in the file falls back to its default without preventing the screensaver from running; the settings window instead asks you to correct an invalid entry before it saves anything.

## The standalone app

Cowsaver also builds as a standalone app for development, testing, and manual fullscreen use.

```sh
make app
./build/Cowsaver.app/Contents/MacOS/Cowsaver --window
./build/Cowsaver.app/Contents/MacOS/Cowsaver --fullscreen
./build/Cowsaver.app/Contents/MacOS/Cowsaver --idle 300
./build/Cowsaver.app/Contents/MacOS/Cowsaver --configure
```

`--configure` opens Cowsaver's settings and writes `config.json`. It is the same window the screensaver shows behind its Options button, reached without going through the screensaver host, so settings stay editable when that host does not present one.

`--idle 300` waits for five minutes of idleness before showing Cowsaver. It checks idle state every five seconds and normally avoids activation while macOS reports a display-sleep assertion, such as while a film is playing.

While `--fullscreen` or `--idle` is showing, any keyboard or mouse activity — a key, a click, moving the mouse, or scrolling — dismisses it. It also follows the currently attached displays: connecting, disconnecting, or rearranging displays while it is visible keeps every current screen covered.

**The standalone app is not a screensaver.** It does not integrate with screen lock and does not appear on the lock screen. The `.saver` remains the installed screensaver; the app is a useful fallback for manual fullscreen display or development.

## Why

Cowsaver began on a 2019 16-inch MacBook Pro, where continuously rendered screensavers could wake the discrete Radeon GPU and make an otherwise idle machine noisy. A screensaver does not need sixty updates per second to show a fortune and an ASCII cow.

Cowsaver updates its content on rotation rather than running an application-owned continuous render loop. At the default setting, it chooses and draws a new fortune every 45 seconds.

- **No application render loop.** The saver does not override `animateOneFrame()`; its content changes use one shared rotation schedule. `ScreenSaverView` retains its own infrequent default callback.
- **No GPU frameworks.** It uses AppKit text layers and imports none of Metal, SceneKit, SpriteKit, WebKit, GLKit, or OpenGL. `make check` enforces that rule.
- **No external cowsay process.** The cowsay rendering logic is implemented in Swift and tested against cowsay 3.8.4 output.

This is a low-activity design, not a claim about a universal power-saving number. See [power notes](docs/power.md) for the measurement context and limitations.

## Cowsay compatibility

Cowsaver is tested for byte-for-byte compatibility with cowsay 3.8.4 across 219 committed cases.

The test suite compares committed output from real cowsay with Cowsaver output as raw data, including trailing whitespace. The cases cover every bundled cowfile in speech and thought modes, plus representative message shapes, wrap widths, face modes, option interactions, and the no-wrap path.

A few cowsay details are easy to miss:

- `-W 40` wraps at 39 columns because Perl’s `Text::Wrap` reserves the final column.
- `-t` selects tired eyes; it does not create a thought balloon. Thought balloons are the separate `cowthink` mode.
- cowsay measures bytes rather than characters. Cowsaver preserves that behavior, including its handling of non-ASCII input at a wrap boundary.
- Whitespace within a paragraph collapses to a single space unless the no-wrap path is used.

## Content and licensing

Cowsaver displays 3,470 curated fortunes from `fortune-mod` 9708 and 47 static cowfiles from cowsay 3.8.4. It does not execute Perl embedded in cowfiles, so the four cowsay templates that require it are not included.

| Content | What it means | Licence |
|---|---|---|
| Curated fortunes | 3,470 records used at runtime | BSD terms recorded with fortune-mod |
| Static cowfiles | 47 bundled cowsay templates | GPLv3 |
| Preserved source import | 35 files, 13,387 separator entries, 13,353 non-empty records; repository provenance only | BSD terms recorded with fortune-mod |

Cowsaver's own code is GPLv3. The bundled cow art and fortune material retain their upstream terms; Cowsaver does not relicense either. The built products carry their notices inside `Contents/Resources/`.

fortune-mod cautions that quote attributions and exact wording cannot be independently verified. A displayed attribution is therefore not evidence that the named person said the words. If a quotation is misattributed, misquoted, or you hold rights to it and want it removed, open an issue; Cowsaver will remove it from the curated runtime corpus.

See [credits.md](credits.md), [curated fortune provenance](Resources/fortune-curated/provenance.md), and [source-import provenance](Resources/fortune-upstream/provenance.md) for the exact scope, notices, and removal process.

### Your own collection

The bundled curated collection remains the default. You can also import fortune files already installed on your Mac.

```sh
./scripts/import-fortunes.sh --dry-run
./scripts/import-fortunes.sh
```

The script copies fortune files to `fortune-user/` inside Cowsaver’s application-support directory. Imported fortunes are added to the bundled curated collection; they do not replace it. Use `--dry-run` first to see what it would import. Stop and start the screensaver after an import so it creates a new content engine.

Personal fortune files are UTF-8 plain-text files with no filename extension. Separate records with a line containing only `%`; `.dat` and `.u8` index files are ignored. Files whose names end in `-o`, or which sit inside a directory whose name is exactly `off` (a directory merely containing those letters, such as `handoff`, does not count), are skipped under fortune-mod’s legacy convention for separately distributed content. Cowsaver does not curate or classify personal imports: apart from technical display filters, they are used as supplied.

Loading your own collection is bounded, so an oversized or unusually large import cannot stall the screensaver or grow its memory without limit:

| Limit | Value | Plain-language result |
|---|---|---|
| One fortune data file, or one `excluded.txt` list | 8 MiB | A larger file is skipped; the rest of your collection still loads. |
| Total fortune and exclusion data accepted per load | 32 MiB | Loading stops at this boundary; later files are not decoded. |
| Retained fortune records per load | 100,000 | Once this many records are kept, later records are not retained. |
| Filesystem entries examined per load | 1,000 | Every file, directory, and symbolic link looked at counts, not just usable fortunes; once this many have been examined, the rest of a large tree is left unscanned. |

These are fixed package limits, not settings — they do not appear in the Options window or `config.json`. A symbolic link, whether it stands in for a search root, a directory, or a file, is never followed. When a limit changes what actually loaded, the screensaver logs a short note explaining which one and what it means for your content; it never logs a fortune’s own text.

## Building

Cowsaver builds with Xcode Command Line Tools; it does not require the full Xcode app or an `.xcodeproj` to build and install the saver.

When `swift test` fails because the toolchain does not provide Swift Testing, `make test` explains the cause and the remedy instead of stopping at the raw compiler error. Command Line Tools-only users can run `make smoke` for the framework-free 219-fixture golden suite.

```sh
make check
make test
make
make cli
make smoke
```

To compare the command-line renderer with a local cowsay installation:

```sh
echo "hello" | .build/debug/cowsaver-cli -f stegosaurus
diff <(echo hi | .build/debug/cowsaver-cli -f dragon) <(echo hi | cowsay -f dragon)
```

Regenerating the committed golden output requires cowsay 3.8.4 (`brew install cowsay`). Run `make golden` only after intentionally changing cowsay compatibility behavior or updating the pinned cowsay version.

## Documentation

| Document                                                     | Description                                                  |
| ------------------------------------------------------------ | ------------------------------------------------------------ |
| [Architecture](docs/architecture.md)                         | Module layout and the boundary between the reusable core and macOS front ends. |
| [Install guide](docs/install.md)                             | Installing on a clean Mac, reinstalling, and troubleshooting. |
| [Configuration](docs/configuration.md)                       | Every configuration key, its default, and its error behavior. |
| [Power notes](docs/power.md)                                 | The low-activity design, measurement context, and limitations. |
| [Compatibility](docs/compatibility.md)                       | macOS versions tested so far and known platform behavior.    |
| [Platform risks](docs/platform-risk.md)                      | The Apple APIs Cowsaver relies on and its fallback paths.    |
| [Credits](credits.md)                                        | Attribution and licensing for the code, cowfiles, and fortune material. |
| [Contributing](CONTRIBUTING.md)                              | Development rules and contribution guidance.                 |
| [Code of Conduct](CODE_OF_CONDUCT.md)                        | Community standards and a private reporting route.           |
| [Security policy](SECURITY.md)                               | Supported versions and private vulnerability reporting.      |
| [Curated fortune provenance](Resources/fortune-curated/provenance.md) | Runtime corpus, curation record, licence, and removals. |
| [Source-import provenance](Resources/fortune-upstream/provenance.md) | Source, licence, and checksum information for the preserved fortune-mod import. |

## License

Cowsaver's code and project-authored documentation are licensed under [GPLv3](LICENSE). The bundled cowfiles and fortune material retain their own terms. See [license-notice.md](license-notice.md) and [credits.md](credits.md).
