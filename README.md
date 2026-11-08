# keepwarm

A tiny menu bar utility that works around choppy macOS animations (Quick Look, popovers, etc.) on an **external display that is set as the primary display**.

> **Status:** unofficial workaround, not affiliated with Apple. It treats the symptom, not the root cause, which I don't know. It worked on the author's setup (see below); your mileage may vary.

## The problem

Since macOS 26 (Tahoe) and still in macOS 27, system animations such as Quick Look (press <kbd>Space</kbd> on a file), calendar popovers and similar look choppy when an **external display is the primary display**. It has been there since the very first Tahoe release. It does **not** happen on macOS 15 (Sequoia): the author ran the same displays, cables and docks on Sequoia (M2 Pro, M3 Max, M4 Max) and everything was smooth. The M4 Max MacBook is still on Sequoia because of this bug, so it has not been tested on Tahoe.

Observations from the original bug report (Feedback Assistant). Reproduced by the author on an M3 Max MacBook, an M2 Pro Mac mini and an M5 Max MacBook running Tahoe/macOS 27. Colleagues report the same problem on an M3 Max and on an M4 Pro Mac mini:

- Only the **primary** display is affected. Apps on a secondary extended display run smoothly.
- Changing which external display is primary moves the problem with it, so cables and monitors are not the cause.
- With the MacBook lid open and the built-in display as primary, everything is smooth.
- The issue reproduces with one or two external displays, USB-C/DisplayPort/HDMI/Thunderbolt hub, 60 Hz, no HDR.
- It disappears while something demanding is running on the primary display (screen recording, a WebGL demo). A WebGL demo on the *secondary* display does **not** help.
- Not fixed by: Reduce Motion, Reduce Transparency, disabling "Displays have separate Spaces", hiding the Dock, fixed 60 Hz refresh, `defaults write` tweaks for Finder/QuickLook animations, High Power mode.
- `powermetrics` shows the GPU staying at its lowest frequency (338 MHz on M5 Max) both with and without the workaround, so this does not look like simple GPU downclocking.

The author's hypothesis (not verified beyond the machines listed above): since it reproduces across M2 Pro, M3 Max, M4 Pro and M5 Max, and the same hardware, displays and cables are smooth on Sequoia, it is a macOS regression that most likely affects any Mac using an external display as the primary one.

## The finding

Keeping **any window on the primary display refreshing at 45-60 fps** makes the animations smooth. The content and size don't matter: a 4×4 px, almost fully transparent window is enough. The same window at 30 fps does **not** help, even with a clearly visible color change.

My (unverified) interpretation: when few frames are being presented on the primary display, the system drops into a lazy presentation mode and can't ramp up fast enough for a short animation. I don't know the actual mechanism inside WindowServer / the display pipeline.

## What keepwarm does

- Creates a 4×4 px, click-through, nearly transparent window in the corner of the primary display.
- Updates it on every tick of a display link (default 45 fps) so the display keeps receiving frames.
- Follows the primary display when the display configuration changes.
- Does nothing when the primary display is the built-in one (not needed there).
- Lives in the menu bar with three modes:
  - **On**: always active.
  - **Off**: never active.
  - **Auto** (default): pauses itself when GPU utilization stays above a threshold (default 60%) for 3 seconds, resumes when it stays below for 2 seconds. Under heavy GPU load (rendering, local LLM inference, etc.) the workaround is assumed to be unnecessary.

The selected mode is remembered between launches. The workaround is not free, see [Overhead](#overhead).

## Overhead

Measured by the author on an M5 Max at 45 fps (Activity Monitor percentages are relative to one core, so 100% = one full core):

| Metric | Value |
|--------|-------|
| keepwarm process CPU | ~1.5-2.3% |
| keepwarm memory | ~20 MB |
| `WindowServer` CPU, keepwarm on | ~17-25% |
| `WindowServer` CPU, keepwarm off | ~5% |
| GPU (`powermetrics`) | ~5-8% active, ~18-44 mW, stays at the lowest frequency |

Most of the cost lands on `WindowServer`, not on the keepwarm process itself, and Activity Monitor shows 0% GPU for keepwarm because the compositing work is attributed to `WindowServer`. Auto mode removes the cost while the GPU is busy; a lower `--fps` reduces it (the lowest value that still helps hasn't been determined; 30 fps did not help, 45 did).

## Requirements

- macOS 14 or later (uses `NSView.displayLink`)
- Xcode Command Line Tools (`xcode-select --install`)

## Build and run

```bash
swiftc -O keepwarm.swift -o keepwarm
./keepwarm
```

A circle icon appears in the menu bar:

| Icon | Meaning |
|------|---------|
| Filled circle | active |
| Pause circle | Auto mode paused it because of high GPU load |
| Empty circle | off |

The first line of the menu shows the current state and GPU utilization.

### Options

| Option | Default | Description |
|--------|---------|-------------|
| `--fps N` | `45` | Refresh rate of the helper window. Try 60 if 45 isn't enough. |
| `--threshold N` | `60` | GPU utilization (%) above which Auto mode pauses. |
| `--alpha A` | `0.02` | Window opacity. Barely matters. |

Example: `./keepwarm --fps 60 --threshold 80`

## Start at login

```bash
mkdir -p ~/bin
cp keepwarm ~/bin/keepwarm
```

Create `~/Library/LaunchAgents/local.keepwarm.plist` (replace `USERNAME`):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>local.keepwarm</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Users/USERNAME/bin/keepwarm</string>
    <string>--fps</string><string>45</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ProcessType</key><string>Interactive</string>
</dict>
</plist>
```

Enable and disable:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/local.keepwarm.plist
launchctl bootout gui/$(id -u)/local.keepwarm
```

Run only one instance at a time (either manually or via launchd).

## Do you have this problem?

1. Connect an external display and make it primary (close the MacBook lid, or set it as the primary display in System Settings → Displays → Arrangement).
2. Select a file in Finder and press <kbd>Space</kbd> several times. Compare with the same action on a secondary display, or with the built-in display as primary.
3. Run `./keepwarm --fps 60` and repeat. If the animation is now smooth, you have the same issue and this workaround applies.

## Known limitations

- **GPU utilization key.** Auto mode reads GPU utilization from the I/O Registry (`IOAccelerator` → `PerformanceStatistics`). The key name may differ between macOS versions and chips. If the menu says "GPU: no data" (or similar), Auto mode behaves like On. In that case please open an issue and paste the output of:
  ```bash
  ioreg -r -c IOAccelerator -w0 | grep -i -E "utilization|activity"
  ```
- **The assumption behind Auto mode** (that the bug doesn't show up under high GPU load) was observed with screen recording and a WebGL demo, not with every kind of load. If animations lag during e.g. LLM inference, raise `--threshold` or use On.
- The 60% threshold and the 3 s / 2 s hysteresis were chosen by feel, not measured.
- This is a workaround. If Apple fixes the underlying issue, you won't need it.

## Reporting to Apple

If you are affected, please file your own report in Feedback Assistant and mention the key observation: *the choppiness on the primary external display disappears when any window on it refreshes at 45-60 fps, but not at 30 fps*. More independent reports on different hardware help.

## Contributing

Useful things to contribute: test results on other chips and macOS versions, the correct GPU utilization key for your machine, and any insight into why this happens.

## Credits

- **Aleksey Garbarev** found and documented the problem, tested it across several Macs, displays and macOS versions, and discovered the key finding that a 45-60 fps refresh on the primary display removes the stutter.
- **Claude** (Anthropic's AI assistant) helped analyze the `powermetrics` logs, narrow down hypotheses, and wrote the code and this README together with Aleksey.

## License

MIT. See [LICENSE](LICENSE).
