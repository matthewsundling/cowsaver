# Configuration

Cowsaver keeps its settings in one JSON file. This document describes every key that file
understands, what each one does, and what happens when a value is wrong.

`docs/config.example.json` is a complete, loadable file containing every key at its shipped
value. Copy it to the path below and edit it.

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
| `rotationSeconds` | whole number | `45` | 1–600 seconds. |
| `wrapWidth` | whole number | `40` | 2–500 columns. |
| `cowfiles` | array | `["stegosaurus", "default", "tux", "dragon"]` | Ordered, unique, exact cowfile names; `[]` means every loadable cowfile. |
| `randomCow` | boolean | `true` | — |
| `face` | string | `"default"` | Face names, single letters, or a comma- or space-separated list. |
| `balloonStyle` | string | `"say"` | `say` or `think`, case-insensitively; invalid values warn and use `say`. |
| `fontName` | string | `"Menlo"` | A non-empty name; rendering requires fixed pitch and otherwise uses a fallback chain. |
| `fontSize` | number | `0` | `0` auto-fits; otherwise 6–144 points. Decimal pinned sizes are valid. |
| `sizeVariation` | number | `0` | 0–0.9. Applies to auto-fit only. |
| `foreground` | string | `"#33FF66"` | `#RGB` or `#RRGGBB`, with or without the `#`. |
| `background` | string | `"#000000"` | Same as `foreground`. |
| `theme` | string | `green-phosphor` | `green-phosphor`, `amber`, `paperwhite`, `solarized-dark`. |
| `transition` | string | `"fade"` | `fade` or `none`, case-insensitively; invalid values warn and use `fade`. |
| `reposition` | boolean | `true` | — |
| `adaptiveWrap` | boolean | `true` | — |
| `maxFortuneLines` | whole number | `60` | 0–100; `0` means no limit. |
| `weightByFile` | boolean | `false` | — |
| `debugFrame` | boolean | `false` | File-only; no control in the settings window. |

JSON booleans and numbers are different types: boolean settings accept only `true` or `false`,
so `0` and `1` are not booleans. Numeric settings reject booleans. `rotationSeconds`,
`wrapWidth`, and `maxFortuneLines` require whole numbers, although `40.0` is accepted. `fontSize`
and `sizeVariation` may be decimal values, but every numeric value must be finite.

Wrong types, fractions in whole-number settings, and non-finite values use that setting's default
and warn. A finite value outside its range clamps to the nearest supported value and warns. For
`fontSize`, a negative value becomes `0`, a positive value below `6` becomes `6`, and a value
above `144` becomes `144`. A problem with one field never prevents valid settings in the same
file from loading.

Categorical values are matched case-insensitively and stored in their documented lowercase
form. When Cowsaver writes the file again, mixed-case input such as `"ThInK"` therefore becomes
`"think"`.

### Content

- **`cowfiles`** lists the cowfiles Cowsaver may draw. Each string is preserved in order and
  matched exactly and case-sensitively against the names that actually loaded. Use the resource
  name without its `.cow` suffix; Cowsaver does not lowercase or trim a name into a different
  one. A non-string array entry is ignored with a warning that gives its exact index. A duplicate
  string is ignored after its first occurrence and warns with its index and name. An empty array
  intentionally means every loadable cowfile.

  At runtime, unavailable configured names are logged even when other configured names load. If
  none load, Cowsaver tries the default four in their documented order. If none of those loaded,
  it uses every cow that did load; if the library is empty, it uses the compiled-in cow. Each
  recovery logs which fallback was chosen. A value other than an array warns and uses the default
  four-name list.
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
  down past that floor rather than clipped. A finite pinned value from 6 through 144, including
  decimals such as `18.5`, is taken as deliberate — a block too large for the screen is clipped
  rather than shrunk.
- **`sizeVariation`** draws each rotation below the fitted size, by up to that fraction of
  it: `0.3` picks a size somewhere between 70% and 100% of the fit, keeps it for that
  rotation, and picks again at the next one. `0`, the default, draws every rotation at the
  fitted size. It applies to auto-fit only — a `fontSize` other than `0` is an explicit
  choice and is used as written. Containment still runs afterwards, so a varied block is
  kept inside the screen like any other.
- **`reposition`** places each new block at a random position, kept off the very edge. Set
  it to `false` to centre every block.
- **`fontName`** must be a non-empty name. Surrounding whitespace is removed; an empty or
  whitespace-only value warns and stores `Menlo`. File loading does not inspect installed fonts.
  At render time the name must resolve to a fixed-pitch face, because the balloon borders only
  line up in one. A missing or proportional face falls back through Menlo, SF Mono, Monaco, and
  Courier New, and finally to the system monospaced font. There is no render-time warning — the
  fallback always succeeds.

### Appearance

- **`theme`** names a preset, which supplies both colours. Cowsaver ships on
  `green-phosphor`. Matching is case-insensitive.

  | Theme | Foreground | Background |
  |---|---|---|
  | `green-phosphor` | `#33FF66` | `#000000` |
  | `amber` | `#FFB000` | `#000000` |
  | `paperwhite` | `#2B2B2B` | `#F5F2E8` |
  | `solarized-dark` | `#93A1A1` | `#002B36` |

- **`foreground`** and **`background`** are your own colours. Each accepts exactly three or six
  hexadecimal digits, with or without `#`; valid spelling and letter case are preserved. An
  invalid `foreground` warns and stores `#33FF66`, while an invalid `background` warns and stores
  `#000000`, independently of the other field. Setting either one without
  also naming a `theme` drops the shipped preset, so the colours you wrote are the ones you
  get. Naming a theme in the same file is how you ask for the preset instead; the preset
  then supplies both resolved colours. The raw fields still have to be valid because they remain
  persisted.

  Omitting all three appearance keys uses `green-phosphor` without warning. Omitting `theme`
  while supplying either raw colour is the one spelling for custom colours. A present but empty,
  null, wrongly typed, or unknown `theme` is invalid: it warns and uses `green-phosphor`, rather
  than activating the raw colours. This is why a saved custom-colour file has no `theme` key.
- **`transition`** controls the 0.6-second crossfade between fortunes. It accepts `fade` or
  `none`; `none` turns the crossfade off.
- **`face`** applies cowsay's face modes. It accepts full names — `borg`, `dead`, `greedy`,
  `paranoid`, `stoned`, `tired`, `wired`, `young` — the single letters cowsay uses for them
  (`b`, `d`, `g`, `p`, `s`, `t`, `w`, `y`), or several separated by commas or whitespace:
  `"dead"`, `"d"`, and `"dead, young"` are all valid. Matching is case-insensitive. Recognized
  tokens are kept in input order and stored in lowercase, separated by a comma and a space.
  Every unrecognized token is named in a warning while recognized neighbors survive. `default`
  means the ordinary face and adds no mode when another recognized mode is present. If no
  recognized token remains, Cowsaver stores `default` and says so. With several modes, cowsay's
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

- A value of the wrong type, a non-finite number, or a fraction where a whole number is required
  uses that setting's default and warns: `"wrapWidth": "wide"` warns that it expected a number.
- A finite number outside a setting's supported range is clamped to its nearest supported value
  and warns which value was used.
- A non-array `cowfiles` warns and uses the default four names. Inside an array, bad entries and
  later duplicates are ignored individually, with their exact indices, while valid siblings stay.
- A present `theme` that is not a preset warns and uses `green-phosphor`. Remove the key to use
  raw custom colours.
- A bad `foreground` or `background` warns and stores that field's default (`#33FF66` or
  `#000000`) without discarding a valid sibling.
- Invalid `balloonStyle`, `transition`, `face`, and `fontName` values name the field, warn, and
  state the value used for recovery.
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

That output has all 18 keys, `config.example.json` included. A file written by the settings
window under *custom colours* has 17: Cowsaver omits an unset theme rather than writing it
empty, which leaves the raw `foreground` and `background` values in effect.

## The example file, annotated

`docs/config.example.json` is loadable as it stands. JSON has no comments, so the
annotations are here instead. **The block below is not loadable** — it is the example
with comments added:

```jsonc
{
  "adaptiveWrap" : true,               // may widen the balloon to fill the screen
  "background" : "#000000",            // ignored while "theme" names a preset
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
  "foreground" : "#33FF66",            // ignored while "theme" names a preset
  "maxFortuneLines" : 60,              // taller fortunes are never shown; 0 for no limit
  "randomCow" : true,                  // false pins the first loadable cowfile above
  "reposition" : true,                 // false centres every fortune
  "rotationSeconds" : 45,              // whole seconds, 1-600
  "sizeVariation" : 0,                 // above 0, varies the fitted size per rotation
  "theme" : "green-phosphor",          // remove this key to use the two colours above
  "transition" : "fade",               // "none" disables the crossfade
  "weightByFile" : false,              // true favours records from larger fortune files
  "wrapWidth" : 40                     // narrowest balloon, in whole columns, 2-500
}
```

Keys may appear in any order; the settings window writes them sorted, and so does
`--print-default-config`.
