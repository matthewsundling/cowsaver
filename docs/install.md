# Installing Cowsaver

Cowsaver is built from source and installed into your own home directory. It is not
Developer ID signed, so macOS asks you to approve it the first time it runs.

This guide covers a Mac with nothing installed yet. You need Xcode Command Line Tools and
about ten minutes; you do not need the full Xcode app.

## 1. Install the Command Line Tools

```sh
xcode-select --install
```

A dialog appears; accept it and wait for the download to finish. If the tools are already
present the command says so and exits.

Check that a Swift compiler is on the path:

```sh
swift --version
```

## 2. Get the source

```sh
git clone https://github.com/matthewsundling/cowsaver.git
cd cowsaver
```

## 3. Build and install

```sh
make install
```

This builds `Cowsaver.saver` and copies it to `~/Library/Screen Savers/`. The build runs
`make check` first, which enforces Cowsaver's architectural rules; a first build takes a
minute or two.

## 4. Select it in System Settings

Open **System Settings → Wallpaper → Screen Saver** and choose Cowsaver. Screen Saver is no
longer its own settings pane; it opens from Wallpaper.

The first time it runs, macOS may ask you to approve an unsigned screensaver. Approve it.

## 5. Change the settings

Click **Options** in System Settings to open Cowsaver's settings window, or edit the
configuration file directly. The file is the supported configuration path and reaches every
setting; the Options sheet is a convenience, and on some macOS versions it does not open at
all.

See the [configuration reference](configuration.md) for the file's location and every key it
understands, and [`config.example.json`](config.example.json) for a complete file to copy
and edit.

To use fortune files you already have on your Mac, see
[Your own collection](../README.md#your-own-collection) in the README.

## Reinstalling: restart the host

**After any `make install` over a previous build, the old code stays live until the
screensaver host restarts.** `legacyScreenSaver.appex` keeps the code it first loaded, so a
new build appears to have changed nothing at all — including a build that fixes the very bug
you are testing.

```sh
make install
killall legacyScreenSaver
```

macOS relaunches the host on demand, so nothing further is needed. Quit System Settings too
if it is open; it holds its own copy for the preview.

This is worth doing before you conclude that a change did not work.

## When something is wrong

Start here:

```sh
make doctor
```

It reports the running macOS version and architecture, the Command Line Tools and Swift
versions, whether a saver is installed, and the metadata recorded when that saver was
built — including the macOS it was built on, which is the usual explanation for a saver that
worked yesterday. It finishes with the configuration search order.

To check the configuration on its own:

```sh
make cli
.build/debug/cowsaver-cli --validate-config
```

That prints the search order with a `*` beside the file in use, and then either `ok` or the
same warnings the screensaver writes to the log. A misspelled key is not one of those
warnings — unknown keys are ignored silently. See
[when a value is wrong](configuration.md#when-a-value-is-wrong).

Other common cases:

- **Nothing appears in System Settings.** Confirm `~/Library/Screen Savers/Cowsaver.saver`
  exists, then quit and reopen System Settings.
- **Changes do not take effect.** Run `killall legacyScreenSaver`, as above.
- **The screensaver runs but the layout looks wrong.** Set `"debugFrame": true` in
  `config.json` and take a screenshot: a red border marks the view bounds and a blue border
  the text layer, which separates a host-geometry problem from a layout problem.
- **You are on macOS 26 Tahoe.** Cowsaver builds and installs there but is not currently
  supported: the Options sheet does not open and timer-based activation can clip content.
  See the [compatibility notes](compatibility.md).

If a problem survives all of that, open an issue and include the `make doctor` output.

## Running the tests

Installing Cowsaver needs only the Command Line Tools. Running the full developer test suite
is a separate matter, and the difference has caused confusion:

| Command | What it needs |
|---|---|
| `make install` | Command Line Tools. |
| `make check` | Command Line Tools. |
| `make smoke` | Command Line Tools. Runs the 219-fixture golden suite through `cowsaver-cli`. |
| `make test` | A toolchain that provides Swift Testing to `swift test` — Xcode or a swift.org toolchain. |

A Command Line Tools installation that does not bundle Swift Testing cannot run `make test`;
it fails with `no such module 'Testing'`. `make test` recognizes that failure and says so
rather than leaving you with the raw compiler error. `make smoke` is the framework-free
alternative: it verifies the same cowsay 3.8.4 compatibility fixtures without the test
framework, and it is enough to confirm a build renders correctly.

Regenerating those fixtures with `make golden` additionally requires cowsay 3.8.4
(`brew install cowsay`), and is only needed when cowsay compatibility behavior changes
deliberately.

## Uninstalling

```sh
make uninstall
```

That removes `~/Library/Screen Savers/Cowsaver.saver`. Your `config.json` and any imported
fortune files are left where they are; delete the `Cowsaver` directory named in the
[configuration reference](configuration.md#where-the-file-lives) to remove those too.
