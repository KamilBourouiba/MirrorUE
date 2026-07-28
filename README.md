# MirrorUE

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black.svg)](#requirements)
[![iOS](https://img.shields.io/badge/iOS-27%2B-lightgrey.svg)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](Package.swift)

Native **macOS** mirror for a development iPhone you own, trust, and authorize.

Swift / AppKit / Metal UI. Video uses the system **CoreMediaIO** screen device —
the same USB path as QuickTime and Finder presentation. Touch, hardware
buttons, and keyboard go through an embedded **CoreDevice** tunnel on a usbmux
**Network** peer so the cable stays free for capture.

```text
USB cable  → CoreMediaIO (iPhone screen DAL) → Metal (IOSurface, zero-copy)
Wi‑Fi / Net → CoreDevice tunnel → UniversalHID (touch · buttons · keyboard)
              (+ engine HEVC fallback until capture is live)
```

> **Not a general consumer screen mirror.** MirrorUE is for phones you pair for
> development (Developer Mode, Trust This Computer). DRM apps may blank while
> mirrored.

---

## Features

| Area | What you get |
|------|----------------|
| **Video** | USB CoreMediaIO → Metal, IOSurface zero-copy, target **120 fps** (ProMotion) |
| **Touch** | Click / drag / scroll on the mirrored image; landscape digitizer remap |
| **Keyboard** | Auto layout mapping (`fr` / `us` / physical) from Mac language + input source |
| **Dock** | Home, Lock, App Switcher, Control Center, Siri, mute, volume, music-safe, instant |
| **Window** | Aspect-locked phone frame, portrait ↔ landscape follow, native fullscreen |
| **Engine** | Frozen `MirrorUEEngine` (PyInstaller) — no user Python at runtime after build |

---

## Requirements

| Need | Detail |
|------|--------|
| Mac | macOS 14+, Xcode Command Line Tools (`swift`) |
| Phone | **iOS 27+**, USB-paired, unlocked when prompted |
| Dev | Developer Mode on; Wi‑Fi / Network usbmux pairing for the HID tunnel |
| Rebuild | `python3 -m pip install -r tools/requirements.txt` |

MirrorUE targets the CoreDevice / UniversalHID stack used with **iOS 27**. Older
iOS versions are not supported.

---

## Quick start

```bash
git clone https://github.com/KamilBourouiba/MirrorUE.git
cd MirrorUE
./tools/build_engine.sh   # once (or after pulling)
./mirroring               # device picker, or pass --udid
```

Status should show `coremediaio` once the screen device is live. Keep the phone
unlocked and accept Trust / camera–screen prompts on the Mac.

```bash
./mirroring --udid YOUR_UDID
./mirroring --width 390 --height 844
```

Binaries land in `bin/MirrorUE` (UI) and `bin/MirrorUEEngine` (frozen CoreDevice
worker). The launcher prefers those builds — no user Python required at runtime
after a successful freeze.

---

## How to use

### 1. First-time setup

1. Plug the iPhone in with a trusted USB cable and unlock it (**iOS 27+**).
2. On the phone: **Settings → Privacy & Security → Developer Mode** → On.
3. Trust this computer if iOS prompts; on the Mac, allow camera / screen capture
   when macOS asks (CoreMediaIO needs it).
4. Keep the phone on the same Wi‑Fi as the Mac with Network pairing done once
   via Xcode — MirrorUE uses the **Network** usbmux peer for HID so USB stays
   free for the screen device.
5. Build once, then launch:

```bash
./tools/build_engine.sh
./mirroring
```

### 2. Connect

- Without `--udid`, a picker lists USB iPhones — select one and **Connect**.
- With a known device: `./mirroring --udid YOUR_UDID`.
- The overlay walks tunnel → HID → screen capture.
- When live, the status line should mention **`coremediaio`**. If you only see
  the engine HEVC path, replug USB and unlock the phone.

### 3. Touch and gestures

| Action | How |
|--------|-----|
| Tap | Click on the mirrored screen |
| Drag / scroll | Click-drag |
| Wheel scroll | Mouse wheel / trackpad over the mirror |
| Rotate | Rotate the physical iPhone — the window follows |

Clicks map through an aspect-fit content rect into the portrait HID digitizer.
Aim at the **image**, not letterbox bars.

If landscape taps feel mirrored:

```bash
MIRRORUE_LANDSCAPE=left ./mirroring
```

### 4. Keyboard

USB HID usages are **US key positions**. iOS remaps them through the iPhone
**hardware keyboard** layout. MirrorUE defaults to **`auto`**:

1. Preferred Mac language (e.g. `fr-US` → French AZERTY HID)
2. Else active Mac input source (Italian/Spanish QWERTY → US letters, …)

So a French Mac using an Italian-Pro layout still maps correctly to a French
iPhone hardware keyboard.

| `MIRRORUE_KB_PHONE` | Behaviour |
|---------------------|-----------|
| `auto` (default) | Preferred language → `fr` / `us` / …, else Mac layout |
| `fr` | Glyph → French AZERTY HID |
| `us` | Glyph → US HID |
| `physical` | Mac keyCode → HID position |

```bash
./tools/kb_translate.py --test
MIRRORUE_KB_PHONE=us ./mirroring   # force U.S. phone mapping
```

Click once inside the mirror so it is first responder. Unmapped symbols may
paste via Cmd+V on device (`MIRRORUE_KB_PASTE=0` to disable).

### 5. Control dock

| Control | Action |
|---------|--------|
| Home | Home button |
| Lock | Lock button |
| App Switcher | Multitasking |
| Control Center | Open Control Center |
| Siri | Siri |
| Mute | Ring / silent |
| Vol − / Vol + | Volume |
| Music safe | Pause video path; HID-only |
| Instant | Soft refresh; **Shift-click** = hard transcoder reset |

### 6. Window and orientation

- Edge / corner resize keeps phone aspect (skipped in native fullscreen).
- Portrait ↔ landscape follows the capture frame.
- Badges show device name, link state, and orientation.

### 7. Checklist

```text
□ USB plugged, phone unlocked
□ ./mirroring (or --udid …)
□ Status shows coremediaio (~120 fps inbound on ProMotion)
□ Click mirror → type / tap
□ Dock for Home / Lock / volume when needed
```

### 8. Troubleshooting

| Symptom | What to try |
|---------|-------------|
| Picker empty | Cable, Trust, unlock, Refresh |
| Black / stuck connecting | Unlock phone; quit other QuickTime mirrors; replug USB |
| Touch OK, video laggy | Confirm USB picture; status must be `coremediaio` |
| Stuck at ~60 fps | ProMotion Mac display; check `capture inbound` log; `MIRRORUE_CAPTURE_FPS=120` |
| Taps miss in landscape | `MIRRORUE_LANDSCAPE=left ./mirroring` |
| Wrong keys (`kamil`→`kq,il`) | iPhone **Settings → General → Keyboard → Hardware Keyboard**; or `MIRRORUE_KB_PHONE=fr` |
| `bin/MirrorUE*` missing | `./tools/build_engine.sh` |

Stop with **⌘Q** or close the window.

---

## Environment variables

| Variable | Default | Effect |
|----------|---------|--------|
| `MIRRORUE_CAPTURE_FPS` | `120` | CoreMediaIO + Metal target FPS |
| `MIRRORUE_CAPTURE_SLOTS` | `32` | CMIO IOSurface ring depth |
| `MIRRORUE_KB_PHONE` | `auto` | Phone HID layout strategy |
| `MIRRORUE_KB_PASTE` | on | Paste unmapped unicode via Cmd+V |
| `MIRRORUE_LANDSCAPE` | `right` | Home indicator side for landscape taps |
| `MIRRORUE_HID_ORIENT` | — | `buffer` skips landscape HID remap |
| `MIRRORUE_HID_SOCK` | `/tmp/mirrorue_hid.sock` | HID Unix socket path |
| `MIRRORUE_RCTL` | on | Engine HEVC rate-control companion |
| `MIRRORUE_MUVS_CREDITS` | `2` | HEVC frame backpressure |
| `MIRRORUE_MUVS_SLOTS` | `4` | HEVC shared-memory slots |

---

## Architecture

```text
Sources/
  MirrorUEApp/     AppKit window, Metal view, dock, orientation, keyboard inject
  MediaKit/        CoreMediaIO capture + MUVS / video socket readers
  DeviceKit/       usbmux discovery, CoreDevice bridge, tunnel session
  ControlKit/      HID Unix-socket client, keyboard translator, HTTP fallback

tools/
  mirrorue_engine.py   Engine entry (PyInstaller → bin/MirrorUEEngine)
  kb_translate.py      Local glyph → HID regression CLI
  engine/
    live_mirror.py     CoreDevice session, video + HID bind
    hid_socket.py      Write-only HID protocol
    keyboard_map.py    Glyph fold helpers (engine fallback)
    video_socket.py    Engine ↔ UI video transport
    …
```

**Why Network for control?** Opening the CoreMediaIO screen device reconfigures
USB and breaks a concurrent USB CoreDevice tunnel. MirrorUE opens HID on the
same UDID’s Network usbmux entry when present, and keeps USB for picture.

**HID protocol** is write-only over a loopback Unix socket (`0600`). The client
never waits for an ACK. Touch moves coalesce; the worker drains on disconnect.

**Keyboard** maps Mac glyphs / key positions to HID usages for the iPhone
hardware-keyboard layout. Sending US logical `a` (usage `0x04`) to an AZERTY
iPhone types `q` — that is why `auto` / `fr` exist.

---

## Limits

- Requires **iOS 27+** (CoreDevice / UniversalHID)
- For a phone you own and authorize for development
- Control HTTP (if used) is loopback-only; prefer the HID socket
- DRM apps may blank while mirrored
- Re-validate after major iOS / macOS updates
- Display FPS is capped by the Mac display refresh (need ProMotion for 120)

---

## Contributing

Issues and PRs welcome for bugs, docs, and layout maps (more phone keyboard
tables, QWERTZ, etc.). Keep changes focused; do not commit `bin/MirrorUE*`,
pairing records, or local secrets.

```bash
./tools/kb_translate.py --test
swift build -c release --product MirrorUE
./tools/build_engine.sh
```

---

## License

[MIT](LICENSE) © 2026 Kamil Bourouiba

Do not redistribute device pairing records or credentials. Binaries in `bin/`
are local build artifacts and are gitignored.
