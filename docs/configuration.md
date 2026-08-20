# Configuration

Cowsaver keeps its settings in one JSON file. This document describes every key that file
understands, what each one does, and what happens when a value is wrong.

[`config.example.json`](config.example.json) is a complete, loadable file containing every
key at its shipped value. Copy it to the path below and edit it.

## Where the file lives

The canonical location is inside the screensaver host's container:

```text
~/Library/Containers/com.apple.ScreenSaver.Engine.legacyScreenSaver/Data/Library/Application Support/Cowsaver/config.json
```

Cowsaver searches two directories, in order, and uses the first `config.json` it finds:

1. The container path above.
2. `~/Library/Application Support/Cowsaver/config.json`.

The files are not merged. A config file in the container directory means the one in
Application Support is never read.

The container path comes first because it is the one directory both front ends resolve to
the same file. The `.saver` runs inside `legacyScreenSaver.appex`, where the home directory
*is* the container; the standalone app sees your real home directory and appends the
container path itself. Settings are always written there, by both.

To see which file is in use:

```sh
.build/debug/cowsaver-cli --validate-config
```

It prints the search order with a `*` beside the file it found, then validates it.

## Three ways to change a setting

- **Edit `config.json`.** The supported path, and the only one that reaches every key.
- **The screensaver's Options sheet**, when macOS opens it.
- **The standalone app's settings window**: `./build/Cowsaver.app/Contents/MacOS/Cowsaver --configure`.

The sheet and the settings window are the same window, and both write the same
`config.json` — there is no second store. Six keys are file-only, because they have no
control in that window: `face`, `fontName`, `foreground`, `background`, `weightByFile`, and
`debugFrame`. The window preserves them; it writes back every key it read.

A key the file does not hold takes Cowsaver's built-in default; nothing else is layered
underneath.

Settings saved from either window take effect immediately: the running view reloads its
colours, rebuilds its content engine, and rotates. A hand edit to `config.json` is read the
next time the screensaver starts, so stop and start it afterwards.

## The keys

| Key | Type | Default | Range and clamping |
|---|---|---|---|
| `rotationSeconds` | number | `45` | Clamped to 1–86 400 in use. |
| `wrapWidth` | integer | `40` | Clamped to 2–500 in use. |
| `cowfiles` | array of strings | `["stegosaurus", "default", "tux", "dragon"]` | `[]` means every bundled cowfile. |
| `randomCow` | boolean | `true` | — |
| `face` | string | `"default"` | Face names, single letters, or a comma- or space-separated list. |
| `balloonStyle` | string | `"say"` | `say` or `think`; any other value is `say`. |
| `fontName` | string | `"Menlo"` | Any installed fixed-pitch face; otherwise a fallback chain. |
| `fontSize` | number | `0` | `0` auto-fits. A fitted size lands between 6 and 96 points. |
| `sizeVariation` | number | `0` | Clamped to 0–0.9 in use. Applies to auto-fit only. |
| `foreground` | string | `"#33FF66"` | `#RGB` or `#RRGGBB`, with or without the `#`. |
| `background` | string | `"#000000"` | Same as `foreground`. |
| `theme` | string | unset | `green-phosphor`, `amber`, `paperwhite`, `solarized-dark`. |
| `transition` | string | `"fade"` | `none` disables the fade; any other value keeps it. |
| `reposition` | boolean | `true` | — |
| `adaptiveWrap` | boolean | `true` | — |
| `maxFortuneLines` | integer | `60` | `0` or less means no limit. |
| `weightByFile` | boolean | `false` | — |
| `debugFrame` | boolean | `false` | File-only; no control in the settings window. |

Clamping is silent. `"rotationSeconds": 0` is not an error and produces no warning; it runs
at one second.

### Content

- **`cowfiles`** lists the cowfiles Cowsaver may draw. Names are matched against the bundled
  set below; a name that does not match is skipped. An empty list means every bundled
  cowfile, and so does a list in which nothing matched — in that case Cowsaver also logs a
  note saying so. Unlike cowsay's `COWPATH`, this set is fixed at what Cowsaver bundles.
- **`randomCow`** picks a new cowfile each rotation, avoiding the last few. Set it to
  `false` to keep one cow: the first name in `cowfiles` that actually loaded.
- **`maxFortuneLines`** is a corpus filter, not a truncation. A fortune taller than this
  when wrapped at `wrapWidth` is dropped when the collection is loaded, so it never appears.
  Raising it admits longer fortunes, which auto-fit then draws at a smaller size. `0` keeps
  everything.
- **`weightByFile`** changes how a fortune is chosen. By default every record is equally
  likely, whichever file it came from. Set it to `true` and each record's chance becomes
  proportional to the byte size of the file it came from, so records in large files come up
  more often — fortune's size-proportional weighting rather than a uniform draw. Either way
  a short history prevents immediate repeats.

### Layout

- **`wrapWidth`** is the narrowest balloon Cowsaver will use, in columns. It is also the
  width `maxFortuneLines` is measured at, so lowering it makes fortunes taller and drops
  more of them.
- **`adaptiveWrap`** lets a rotation try wider balloons — 1.5×, 2×, 2.5×, and 3× `wrapWidth`,
  never past 500 columns — and moves to a wider one only when it draws the text at least 10%
  bigger than the best width so far. A tie keeps the narrower balloon, so a short fortune
  that renders identically at every width stays at `wrapWidth`. With it off, every fortune is
  wrapped at `wrapWidth` exactly.
- **`fontSize`** of `0` fits each block to the screen: one measurement per rotation picks
  the largest size that fits inside a 10% margin, between 6 and 96 points. When even 6
  points cannot fit — a Settings preview pane rather than a screen — the block is scaled
  down past that floor rather than clipped. Any other value
  pins that point size and is taken as deliberate — a block too large for the screen is
  clipped rather than shrunk.
- **`sizeVariation`** draws each rotation below the fitted size, by up to that fraction of
  it: `0.3` picks a size somewhere between 70% and 100% of the fit, keeps it for that
  rotation, and picks again at the next one. `0`, the default, draws every rotation at the
  fitted size. It applies to auto-fit only — a `fontSize` other than `0` is an explicit
  choice and is used as written. Containment still runs afterwards, so a varied block is
  kept inside the screen like any other.
- **`reposition`** places each new block at a random position, kept off the very edge. Set
  it to `false` to centre every block.
- **`fontName`** must name an installed fixed-pitch face; the balloon borders only line up
  in one. If it is missing or proportional, Cowsaver falls back through Menlo, SF Mono,
  Monaco, and Courier New, and finally to the system monospaced font. There is no warning
  for this — the fallback always succeeds.

### Appearance

- **`theme`** names a preset and overrides `foreground` and `background` when it is set.
  Matching is case-insensitive.

  | Theme | Foreground | Background |
  |---|---|---|
  | `green-phosphor` | `#33FF66` | `#000000` |
  | `amber` | `#FFB000` | `#000000` |
  | `paperwhite` | `#2B2B2B` | `#F5F2E8` |
  | `solarized-dark` | `#93A1A1` | `#002B36` |

- **`foreground`** and **`background`** are used when no theme is set. To choose your own
  colours, remove the `theme` key entirely rather than setting it to an empty string, which
  is not a preset name and warns on every load. This is what the settings window's *custom
  colours* option does, and it is why a saved file has no `theme` key when that option is
  selected.
- **`transition`** controls the 0.6-second crossfade between fortunes. `none` turns it off.
- **`face`** applies cowsay's face modes. It accepts full names — `borg`, `dead`, `greedy`,
  `paranoid`, `stoned`, `tired`, `wired`, `young` — the single letters cowsay uses for them
  (`b`, `d`, `g`, `p`, `s`, `t`, `w`, `y`), or several separated by commas or spaces:
  `"dead"`, `"d"`, and `"dead, young"` are all valid. Unrecognized words are ignored, which
  is how the default value `"default"` means the ordinary face. With several modes, cowsay's
  own precedence decides the eyes.
- **`balloonStyle`** is `say` or `think`. `think` draws cowsay's thought balloon. Note that
  the `tired` face mode is not a thought balloon, despite cowsay's `-t` flag.

### Diagnostics

- **`debugFrame`** draws a red border on the view bounds and a blue border on the text
  layer. In a screenshot that separates a host-geometry problem from a layout problem. It
  has no control in the settings window; set it in the file, and remove it when you are
  done.

## The bundled cowfiles

Cowsaver includes 47 of the 51 cowfiles distributed with cowsay 3.8.4. The four omitted
cowfiles rely on executable Perl rather than static cow art, and Cowsaver does not execute
Perl. Any of these names may appear in `cowfiles`:

```text
actually            alpaca              beavis.zen          blowfish
bong                bud-frogs           bunny               cheese
cower               cupcake             daemon              default
dragon              dragon-and-cow      elephant            elephant-in-snake
eyes                flaming-sheep       fox                 ghostbusters
head-in             hellokitty          kiss                kitty
koala               kosh                llama               luke-koala
mech-and-cow        meow                milk                moofasa
moose               mutilated           ren                 sheep
skeleton            stegosaurus         stimpy              supermilker
surgery             turkey              turtle              tux
vader               vader-koala         www
```

## When a value is wrong

Loading a configuration never fails and never stops the screensaver. Every field is decoded
on its own, so one bad value costs you that value and nothing else:

- A value of the wrong type is ignored and the default is used: `"wrapWidth": "wide"` warns
  `wrapWidth: expected a number, ignoring`.
- `cowfiles` warns `expected a list of names` unless it is a list of strings.
- A `theme` that is not a preset warns and is dropped, leaving `foreground` and `background`
  in effect.
- A `foreground` or `background` that is not a hex colour warns and falls back to green on
  black.
- A file that is not valid JSON, or is JSON but not an object, warns and yields the shipped
  defaults entire.
- **A key Cowsaver does not know is named and ignored**, so a misspelled one no longer looks
  exactly like a setting that had no effect: `"wrapWdith": 60` warns `wrapWdith: not a
  setting Cowsaver knows; ignoring it`. Check the spelling against the table above, or
  against `config.example.json`.

The screensaver logs these warnings rather than showing them; there is nobody at the screen
to show an error to. Read them with:

```sh
.build/debug/cowsaver-cli --validate-config
```

That runs the loader the saver runs, so a warning here is a warning there. It prints `ok`
when there is nothing to report. `make doctor` ends with the same check, once `make cli` has
built the binary. Give it a path to check a file that is not installed yet:

```sh
.build/debug/cowsaver-cli --validate-config docs/config.example.json
```

To start from the shipped defaults instead of an existing file:

```sh
.build/debug/cowsaver-cli --print-default-config > config.json
```

That output has 17 keys rather than 18: `theme` is unset by default, and Cowsaver omits an
unset theme rather than writing it empty, which keeps the raw `foreground` and `background`
values active. `config.example.json` is the same file with `"theme": "green-phosphor"`
added.

## The example file, annotated

[`config.example.json`](config.example.json) is loadable as it stands. JSON has no comments,
so the annotations are here instead. **The block below is not loadable** — it is the example
with comments added:

```jsonc
{
  "adaptiveWrap" : true,               // may widen the balloon to fill the screen
  "background" : "#000000",            // unused while "theme" is set
  "balloonStyle" : "say",              // "think" for a thought balloon
  "cowfiles" : [                       // [] would mean every bundled cowfile
    "stegosaurus",
    "default",
    "tux",
    "dragon"
  ],
  "debugFrame" : false,                // true draws the layout borders
  "face" : "default",                  // or "dead", "d", "dead, young", ...
  "fontName" : "Menlo",                // must be fixed-pitch
  "fontSize" : 0,                      // 0 fits each fortune to the screen
  "foreground" : "#33FF66",            // unused while "theme" is set
  "maxFortuneLines" : 60,              // taller fortunes are never shown; 0 for no limit
  "randomCow" : true,                  // false pins the first loadable cowfile above
  "reposition" : true,                 // false centres every fortune
  "rotationSeconds" : 45,              // clamped to 1-86400
  "sizeVariation" : 0,                 // above 0, varies the fitted size per rotation
  "theme" : "green-phosphor",          // remove this key to use the two colours above
  "transition" : "fade",               // "none" disables the crossfade
  "weightByFile" : false,              // true favours records from larger fortune files
  "wrapWidth" : 40                     // narrowest balloon, in columns; clamped to 2-500
}
```

Keys may appear in any order; the settings window writes them sorted, and so does
`--print-default-config`.

## See also

- [Install guide](install.md) — installing Cowsaver, and what to do when it misbehaves.
- [Compatibility](compatibility.md) — tested macOS versions and known platform behavior.
- [README](../README.md#your-own-collection) — importing your own fortune files.
