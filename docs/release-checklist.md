# Release checklist

This is the maintainer's pass for checking Cowsaver against a version of macOS. Run it twice
for each new macOS: once on the earliest beta available to test on, and again once that
version has shipped publicly.

Third-party screensavers rely on an API Apple has deprecated, and a new macOS tends to break
them in ways no source diff will show. Finding out means installing the saver and watching it
run. This checklist is here so that every pass covers the same ground.

## For contributors

You do not need to run this. If you have built or run Cowsaver on a macOS version that is not
listed in `docs/compatibility.md`, that is worth reporting on its own: run `make doctor`,
then open an issue or a pull request adding a row to the table there. Say what worked, what
did not, and include the `make doctor` output.

## The pass

Build on the machine being tested, and install from that build:

```sh
make clean && make install
killall legacyScreenSaver
```

The `killall` is there because macOS keeps the previously loaded saver in memory. Without it,
the old build keeps running and the pass tests nothing.

Set `"debugFrame": true` in `config.json` before the visual checks. It draws a red border
on the view bounds and a blue border on the text layer, so a screenshot shows whether
content is wrong because macOS handed the saver the wrong size or because Cowsaver laid it
out badly. Set it back to `false` when the pass is over.

| Check | How | Pass looks like |
|---|---|---|
| Build + provenance | `make clean && make install && make doctor` | Doctor shows the running OS, Command Line Tools, Swift, and the commit the saver was built from |
| Unit + golden suite | `make test` (Xcode toolchain) or `make smoke` (Command Line Tools) | Green; 219 fixtures pass |
| Settings preview | Wallpaper → Screen Saver, watch 3 rotations | Intact cow, no clipping |
| Options sheet | Click Options; change a value; OK | The sheet opens inside the screen, and `config.json` holds the new value |
| App settings | `./build/Cowsaver.app/Contents/MacOS/Cowsaver --configure`, change a value | The saver shows it at the next activation, without reinstalling |
| Hot corner | Trigger; watch 3 rotations | No clipping, the fade runs |
| Idle timer | Set 1 min; wait | Activates; no clipping |
| Lock screen return | Wake from the saver with a password required | The unlock prompt is normal |
| Multi-display | If available: both screens | Each screen fits independently, with different fortunes |
| App fullscreen dismissal | Launch `Cowsaver.app --fullscreen` separately for each: press a key, click each mouse button, move the mouse, scroll | Every input dismisses it and the app quits |
| App display reconciliation | With `Cowsaver.app --fullscreen` or `--idle` visible, if the hardware permits: change the display arrangement or mode, or connect/disconnect a display | Every current screen is covered afterward and no stale window remains |
| Config resilience | Point at a deliberately broken `config.json` | The saver runs on defaults; `cowsaver-cli --validate-config` names every problem, including any misspelled key |

## Recording a run

Add a row to the table in `docs/compatibility.md` after every pass. Record the macOS
version and build, the architecture, and anything that failed.

Include the passes where nothing broke. Otherwise, a year from now, there is no way to tell a
macOS version that was checked and worked from one that was never checked at all.
