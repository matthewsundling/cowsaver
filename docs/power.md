# Power

Cowsaver favours long content-rotation intervals and simple AppKit layers over continuous application-managed rendering. It does not claim literal zero CPU use or a universal power-saving number: macOS and its screen-saver host retain their own timers, compositor work, and hardware decisions.

## Measurement

### Discrete GPU — measured

On a 2019 16-inch MacBook Pro (`MacBookPro16,1`, Core i9-9880H, Intel UHD 630 and AMD Radeon Pro 5500M), running macOS 15.7.8 (24G824), the median `Device Utilization %` from twelve one-second samples in each phase was:

| | integrated | discrete (driver-reported) |
|---|---:|---:|
| idle desktop | 3% | **15%**, 17 W |
| Cowsaver full-screen | 2% | **5%**, 16 W |

The discrete GPU load decreased in this comparison. On this computer the Radeon also drives the display, so it does not reach zero; the useful result is that this Cowsaver run did not increase its reported utilization. The watt values are the AMD driver's `Total Power(W)` readings for that GPU, not whole-machine package power.

### Whole-machine power — not measured

No whole-machine watt figure is published. The available measurements did not isolate Cowsaver from ordinary background activity well enough to support one.

To repeat the discrete-GPU comparison:

```sh
scripts/gpu-check.sh
```

Quit other applications first. The script samples the desktop and then Cowsaver, compares medians, and exits 0 for pass, 1 for fail, or 2 when the desktop control is already too busy to support a conclusion. Record the model, macOS version, display arrangement, and whether the machine has a discrete GPU with any result.

## Runtime behavior

### Installed screensaver

- `ScreenSaverView` requires `super.startAnimation()`, which activates the framework's periodic timer. Cowsaver leaves `animateOneFrame()` at its default no-op implementation and sets that framework interval to one hour.
- Cowsaver's own content changes are scheduled by one shared `RotationCoordinator` timer. It runs at the configured rotation interval (45 seconds by default), holds clients weakly, removes detached clients, and cancels itself when no clients remain.
- A rotation chooses a fortune, formats it, and updates a `CATextLayer`. The optional opacity fade lasts 0.6 seconds; content does not drift or animate continuously.
- The Settings preview renders one frame and does not register with `RotationCoordinator`. Its infrequent `ScreenSaverView` timer still exists.
- The renderer uses AppKit and Core Animation layers. WindowServer chooses the compositing hardware; Cowsaver does not make an integrated-GPU guarantee.
- `make check` rejects imports of Metal, MetalKit, SceneKit, SpriteKit, WebKit, GLKit, and OpenGL anywhere in `Sources/`.

### Standalone app

The standalone app shares the same renderer and rotation coordinator when it is showing a window or full-screen content. Its `--idle` mode is different: it intentionally checks system idle state every five seconds while waiting to activate. That makes it a practical fallback and development tool, not evidence of zero background activity.

## Verification without a power meter

- `make check` verifies that the excluded GPU-rendering frameworks are not imported.
- `swift test` covers the rotation coordinator's shared-timer, pruning, and cancellation behavior.
- In Activity Monitor, observe the installed saver between content rotations and record the OS, machine, and display configuration with the observation.
- On a dual-GPU Mac, run `scripts/gpu-check.sh`; it tests whether reported discrete-GPU utilization rises materially above an idle-desktop control.
