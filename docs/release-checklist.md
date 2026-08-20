# Release checklist

One pass per macOS under test, run at beta 1 of each new release and again at its public
release. Third-party screensavers use a deprecated surface, so what a new macOS breaks is
found by running the thing, not by reading a diff — this is the runbook for doing that the
same way every time.

Run it against a build made on the machine under test:

```sh
make clean && make install
killall legacyScreenSaver
```

Set `"debugFrame": true` in `config.json` for the visual checks. A red border marks the view
bounds and a blue border the text layer, which separates a host-geometry problem from a
layout problem in a screenshot; remove it when the pass is over.

| Check | How | Pass looks like |
|---|---|---|
| Build + provenance | `make clean && make install && make doctor` | Doctor shows the running OS, Command Line Tools, Swift, and the commit the saver was built from |
| Unit + golden suite | `make test` (Xcode toolchain) or `make smoke` (Command Line Tools) | Green; 219 fixtures pass |
| Settings preview | Wallpaper → Screen Saver, watch 3 rotations | Intact cow, no clipping |
| Options sheet | Click Options; change a value; OK | The sheet opens inside the screen, and `config.json` holds the new value |
| App settings | `Cowsaver.app --configure`, change a value | The saver shows it at the next activation, without reinstalling |
| Hot corner | Trigger; watch 3 rotations | No clipping, the fade runs |
| Idle timer | Set 1 min; wait | Activates; no clipping, with the clock on **and** off on macOS 26 and later |
| Lock screen return | Wake from the saver with a password required | The unlock prompt is normal |
| Multi-display | If available: both screens | Each screen fits independently, with different fortunes |
| Config resilience | Point at a deliberately broken `config.json` | The saver runs on defaults; `cowsaver-cli --validate-config` names every problem, including any misspelled key |

## Recording a run

Add a row to the table in [compatibility.md](compatibility.md) for every completed pass,
whatever the outcome. Include the macOS version and build, the architecture, and what
failed if anything did — a pass that found nothing is as much of a result as one that did,
and an unrecorded pass is indistinguishable from one that never happened.
