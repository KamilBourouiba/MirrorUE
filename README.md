# MirrorUE

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black.svg)](#requirements)
[![iOS](https://img.shields.io/badge/iOS-27%2B-lightgrey.svg)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](Package.swift)

**Site:** [kamilbourouiba.github.io/MirrorUE](https://kamilbourouiba.github.io/MirrorUE/)

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

**Need path automation?** See [MirrorUE Pro](https://github.com/KamilBourouiba/MirrorUE-Pro) (record / replay / export flows).

---

## Features

| Area | What you get |
|------|----------------|
| **Video** | USB CoreMediaIO → Metal, IOSurface zero-copy, target **120 fps** (ProMotion) |
| **Touch** | Click / drag / scroll on the mirrored image; landscape digitizer remap |
| **Keyboard** | Auto layout mapping (`fr` / `us` / physical) from Mac language + input source |
| **Dock** | Home, Lock, App Switcher, Control Center, Siri, mute, volume, music-safe, instant |
| **Capture** | Screenshot & HEVC screen recording with show-touches |
| **API** | Loopback HTTP + CLI for tap, type, home, open app, frame grab |
| **Window** | Aspect-locked phone frame, portrait ↔ landscape follow, native fullscreen |

---

## Requirements

| Need | Detail |
|------|--------|
| Mac | macOS 14+, Xcode Command Line Tools (`swift`) |
| Phone | **iOS 27+**, USB-paired, unlocked when prompted |
| Dev | Developer Mode on; Wi‑Fi / Network usbmux pairing for the HID tunnel |
| Rebuild | `python3 -m pip install -r tools/requirements.txt` |

---

## Quick start

### App (recommended)

```bash
./tools/package_app.sh          # builds binaries + dist/MirrorUE.app + .dmg
open dist/MirrorUE.app
```

First launch shows a short setup checklist (USB, Trust, Developer Mode, Network
pairing, camera permission). Then pick your iPhone. Settings live in the dock
gear or **⌘,**.

> Unsigned local builds: right-click the app → **Open** the first time.

### Developers

```bash
./tools/build_engine.sh   # once (or after pulling)
./mirroring               # device picker, or pass --udid
```

```bash
./mirroring --udid YOUR_UDID
./mirroring --width 390 --height 844
```

Binaries land in `bin/MirrorUE` (UI) and `bin/MirrorUEEngine` (frozen CoreDevice
worker). The packaged `.app` embeds both under `Contents/MacOS/`.

---

## How to use

### Touch and gestures

| Action | How |
|--------|-----|
| Tap | Click on the mirrored screen |
| Drag / scroll | Click-drag or mouse wheel over the mirror |
| Rotate | Rotate the physical iPhone — the window follows |

If landscape taps feel mirrored:

```bash
MIRRORUE_LANDSCAPE=left ./mirroring
```

### Keyboard

USB HID usages are **US key positions**. MirrorUE defaults to **`auto`** layout
detection (Mac language → phone HID map).

```bash
./tools/kb_translate.py --test
MIRRORUE_KB_PHONE=us ./mirroring
```

Click once inside the mirror so it is first responder.

### Control dock

| Control | Action |
|---------|--------|
| Home / Lock / App Switcher | Hardware buttons |
| Control Center / Siri | System shortcuts |
| Mute / Vol ± | Volume |
| Music safe | Pause video path; HID-only |
| Instant | Soft refresh; **Shift-click** = hard reset |
| Screenshot | PNG to Desktop (`⌘⇧S`) |
| Record | .mov to Desktop (`⌘⇧R`) |
| Paste clipboard | Cmd+V on device (`⌘⇧V`) |
| Performance | Live fps / latency (`⌘P`) |
| Settings | FPS, keyboard, landscape (`⌘,`) |

### Local control API

While connected, a **loopback-only** HTTP API listens on
`http://127.0.0.1:8090` (`MIRRORUE_API_PORT`).

```bash
./tools/mirrorue status
./tools/mirrorue home
./tools/mirrorue open Snapchat
./tools/mirrorue type 'hello'
./tools/mirrorue tap 0.5 0.8
./tools/mirrorue do home wait:0.8 open:Snapchat
./tools/mirrorue frame /tmp/phone.jpg
./tools/mirrorue help-api
```

| Namespace | Endpoints |
|-----------|-----------|
| **control** | `POST /v1/control/{tap,swipe,type,home,open,do,…}` |
| **vision** | `GET /v1/vision/frame?maxW=720&format=jpg&encoding=b64` |

Full reference: [docs/API.md](docs/API.md)

See [SECURITY.md](SECURITY.md) — do not expose this port publicly.

---

## Environment variables

| Variable | Default | Effect |
|----------|---------|--------|
| `MIRRORUE_CAPTURE_FPS` | `120` | CoreMediaIO target FPS |
| `MIRRORUE_KB_PHONE` | `auto` | Phone HID layout strategy |
| `MIRRORUE_LANDSCAPE` | `right` | Home indicator side for landscape taps |
| `MIRRORUE_API_PORT` | `8090` | Local HTTP API port |

Prefer **Settings** (dock gear / ⌘,) for FPS, keyboard, and landscape in the app.

---

## Architecture

```text
Sources/
  MirrorUEApp/     AppKit window, Metal view, dock, keyboard inject
  MediaKit/        CoreMediaIO capture + MUVS readers
  DeviceKit/       usbmux discovery, CoreDevice bridge
  ControlKit/      HID client, keyboard translator

tools/
  mirrorue_engine.py   PyInstaller → bin/MirrorUEEngine
  mirrorue             CLI for local API
```

**Why Network for control?** CoreMediaIO screen capture reconfigures USB; HID uses
the Network usbmux peer when available.

---

## Troubleshooting

| Symptom | What to try |
|---------|-------------|
| Picker empty | Cable, Trust, unlock, Refresh |
| Black / stuck connecting | Unlock phone; quit other mirrors; replug USB |
| Touch OK, video laggy | Status must show `coremediaio` |
| Taps miss in landscape | `MIRRORUE_LANDSCAPE=left ./mirroring` |
| `bin/MirrorUE*` missing | `./tools/build_engine.sh` then `./mirroring` |

---

## Contributing

Issues and PRs welcome for bugs, docs, and keyboard layout maps. Do not commit
`bin/MirrorUE*`, pairing records, or secrets.

```bash
./tools/kb_translate.py --test
swift build -c release --product MirrorUE
./tools/build_engine.sh
```

---

## License

[MIT](LICENSE) © 2026 Kamil Bourouiba
