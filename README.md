# MirrorUE — 120 FPS iPhone Mirroring & Control for macOS

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014--26-black.svg)](#requirements)
[![iOS](https://img.shields.io/badge/iOS-16--26-lightgrey.svg)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](Package.swift)

**Official Website:** [mirrorue.xyz](https://mirrorue.xyz/) | **Download .dmg:** [mirrorue.xyz/MirrorUE.dmg](https://mirrorue.xyz/MirrorUE.dmg)

Native **macOS** desktop application to stream and control physical iPhones with **120 FPS ProMotion Metal rendering**, capacitive mouse/trackpad gestures, physical keyboard input translation (AZERTY / QWERTY), and local HTTP automation API.

- 📖 **Guides & Documentation:**
  - 🖥️ [How to Mirror an iPhone to Mac (2026 Guide)](https://mirrorue.xyz/mirror-iphone-to-mac/)
  - 🇪🇺 [European Union (EU) iPhone Mirroring Guide](https://mirrorue.xyz/iphone-mirroring-eu/)
  - ⚡ [120 FPS Metal Pipeline & Benchmarks (Raw Datasets)](https://mirrorue.xyz/benchmarks/)
  - 📱 [Device & OS Compatibility Matrix (macOS Tahoe 26 & iOS 26)](https://mirrorue.xyz/compatibility/)
  - 🤖 [Local REST API Reference (Port 8090)](https://mirrorue.xyz/api-docs/)
  - 🧪 [Real-Device QA & CI/CD Automation](https://mirrorue.xyz/iphone-qa-automation/)

```text
USB cable  → CoreMediaIO (iPhone screen DAL) → Metal (IOSurface, zero-copy)
Wi‑Fi / Net → CoreDevice tunnel → UniversalHID (touch · buttons · keyboard)
              (+ engine HEVC fallback until capture is live)
```

---

## Features

| Area | What you get |
|------|----------------|
| **Video** | USB CoreMediaIO → Metal, IOSurface zero-copy, target **120 fps** ([Benchmarks](https://mirrorue.xyz/benchmarks/)) |
| **Touch** | Click / drag / scroll on the mirrored image; landscape digitizer remap ([Control Guide](https://mirrorue.xyz/control-iphone-from-mac/)) |
| **Keyboard** | Auto layout mapping (`fr` / `us` / physical) from Mac language + input source |
| **Dock** | Home, Lock, App Switcher, Control Center, Siri, mute, volume, music-safe |
| **Capture** | Instant screenshot & HEVC screen recording |
| **API** | Local HTTP REST server on port **8090** ([API Docs](https://mirrorue.xyz/api-docs/)) |
| **QA Automation** | Record, save, replay and export validated manual phone workflows ([QA Guide](https://mirrorue.xyz/iphone-qa-automation/)) |
| **AI agent** | LM Studio / OpenAI-compatible provider profiles, local OCR, bounded validated actions |
| **Window** | Aspect-locked phone plus a collapsible Workflow / AI Runs sidebar |

---

## Requirements

| Need | Detail |
|------|--------|
| Mac | macOS 14+, Xcode Command Line Tools (`swift`) |
| Phone | **iOS 16+**, USB-paired, unlocked when prompted |
| Dev | Developer Mode on; Wi‑Fi / Network usbmux pairing for the HID tunnel |
| Rebuild | `python3 -m pip install -r tools/requirements.txt` |

---

## Quick start

### 1-Click Install (Recommended)

```bash
./install.sh
```

This compiles Apple Silicon / Metal optimizations, codesigns the app with camera/screen entitlements, and installs **`MirrorUE.app`** directly into your **`/Applications`** folder and sets up the `mirrorue` CLI shortcut!

### Launching MirrorUE

- **Spotlight:** Press **`⌘ + Space`**, type **`MirrorUE`**, press Enter.
- **Finder:** Open **`/Applications/MirrorUE.app`**.
- **Terminal:** Run **`mirrorue`** or **`./bin/MirrorUE`**.

First launch shows a short setup checklist (USB, Trust, Developer Mode, Network pairing, camera permission). Then pick your iPhone. Settings live in the dock gear or **⌘,**.

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
| Agent | Run or stop a bounded natural-language phone task |
| Settings | FPS, keyboard, landscape (`⌘,`) |

### Automation sidebar

The right sidebar is the current-source automation UI. It is collapsible and
has two tabs:

- **Workflow** records manual taps, swipes, typing, and dock buttons; names and
  saves the result in `Workflows/`; then replays or exports it as JSON.
- **AI Runs** shows the selected provider, effective agent mode, screenshot
  latency status, current goal, Stop control, and bounded live logs.

Workflow playback and AI action batches cannot overlap. Playback holds the
device-control lease for the complete run, and recording/playback is rejected
while an AI run is starting, observing, or thinking.

```bash
./tools/mirrorue workflow list
./tools/mirrorue workflow record start
./tools/mirrorue workflow record stop --name open-settings
./tools/mirrorue workflow play open-settings
./tools/mirrorue workflow export open-settings /tmp/open-settings.json
./tools/mirrorue workflow stop
```

### AI phone agent

Start an OpenAI-compatible server such as LM Studio, load a tool-capable Qwen
model, then open **AI Provider…** in MirrorUE. The default LM Studio URL is
`http://127.0.0.1:1234/v1`; **Test Connection** discovers available models.
Optional API tokens are stored in macOS Keychain.

Reasoning effort is configured per provider. Generic OpenAI-compatible
profiles default to **Provider default**, which omits `reasoning_effort` for
maximum API compatibility. The saved value controls general chat. Phone-agent
requests through the LM Studio preset always use **None** so hidden reasoning
cannot consume the strict tool-call token budget; the AI Runs tab shows this
effective override. Generic compatible providers use the saved value.

Compatibility note: Chat Completions reasoning controls require LM Studio
0.4.8 or newer. A local smoke test on LM Studio 0.4.20 with
`qwen/qwen3.5-9b` reduced an otherwise comparable request from 55.9 s to 8.3 s
and reported reasoning tokens from 138 to 0. This is model-, prompt-, and
machine-dependent, not a performance guarantee; unsupported OpenAI-compatible
servers may reject `reasoning_effort`, in which case use **Provider default**.

Open the sidebar's **AI Runs** tab, enter a small goal such as `Open Settings`,
and run it.
MirrorUE performs fast OCR locally, asks the model for a strictly validated
micro-plan ending at the next screen checkpoint, executes it through the
existing HID path, and observes again. Every model turn checks success first;
after an action batch, a new observation must verify the goal before the run
stops. Safe consecutive actions can share one model call, but planning stops
before an action depends on an unseen UI result. `open_app` uses CoreDevice's
direct app service when available, with the HID Search macro as a compatibility
fallback. A lightweight foreground-app notification supplies trusted bundle
identity, so an icon label on the Home Screen cannot count as an open app.
Enable screenshot sharing only for a provider/model you trust and that supports
vision; otherwise only OCR text and normalized coordinates are sent.

```bash
./tools/mirrorue llm-status
./tools/mirrorue llm-chat "Reply with one word"
./tools/mirrorue agent "Open Settings"
./tools/mirrorue agent-status
./tools/mirrorue agent-stop
```

One run is allowed at a time and all runs have step/action/context limits.
Stopping a run cooperatively cancels model I/O and in-progress HID macros.

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
| **workflows** | `GET /v1/workflows`, `POST /v1/workflows/{record/start,record/stop,save,play,stop,export}` |
| **vision** | `GET /v1/vision/frame?maxW=720&format=jpg&encoding=b64` |
| **llm** | `GET /v1/llm/status`, `POST /v1/llm/chat` |
| **agent** | `POST /v1/agent/run`, `GET /v1/agent/{status,logs}`, `POST /v1/agent/stop` |

Full reference: [docs/API.md](docs/API.md)

See [SECURITY.md](SECURITY.md) — do not expose this port publicly.

---

## Environment variables

| Variable | Default | Effect |
|----------|---------|--------|
| `MIRRORUE_CAPTURE_FPS` | `120` | CoreMediaIO target FPS |
| `MIRRORUE_CAPTURE_SLOTS` | `6` | Retained zero-copy frames (raise only if display stalls) |
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
