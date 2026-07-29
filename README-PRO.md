# MirrorUE Pro

[![License: Commercial](https://img.shields.io/badge/License-Commercial-blue.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-macOS%2014%2B-black.svg)](#requirements)

**Commercial automation layer** for [MirrorUE](https://github.com/KamilBourouiba/MirrorUE) — record, replay, and export touch paths on a real development iPhone.

> MirrorUE (free, MIT) covers mirroring and control. **MirrorUE Pro** adds path automation, latency-aware playback, and a full workflow HTTP + CLI surface for QA and repeatable device smoke.

**Site:** [kamilbourouiba.github.io/MirrorUE](https://kamilbourouiba.github.io/MirrorUE/) (pricing & overview)

---

## Pro features

| Area | What you get |
|------|----------------|
| **Path bar** | Name, saved paths menu, Record · Play · Export |
| **Live timeline** | SF Symbol step strip while recording or playing |
| **Latency tuning** | p95 round-trip compensation in JSON + playback |
| **Storage** | Paths in app bundle `Resources/Workflows` or repo `Workflows/` |
| **Export** | JSON export only — import from arbitrary disk paths is blocked |
| **API** | `GET/POST /v1/workflows/*` record, save, play, stop, export |
| **CLI** | `./tools/mirrorue path record|list|play|stop` |

Everything in the free MirrorUE tier (CoreMediaIO mirror, HID control, dock, screenshot, recording, basic control API) is included.

---

## Requirements

Same as MirrorUE: macOS 14+, iOS 27+, Developer Mode, trusted USB + Network usbmux pairing.

---

## Quick start

```bash
./tools/package_app.sh
open dist/MirrorUE.app
```

1. Connect your iPhone (picker or `--udid`).
2. Use the **path bar** under the mirror: name your path, **Record**, interact on the phone, **Stop** (auto-saves when named).
3. **Play** to replay; **Export** (↗) to copy JSON elsewhere.

Keyboard: **⌘R** toggles record. **⌘⇧P** toggles the live timeline.

---

## Path JSON

```json
{
  "name": "Login smoke",
  "version": 1,
  "latencyP95Ms": 42,
  "steps": [
    { "kind": "tap", "x": 0.5, "y": 0.72 },
    { "kind": "wait", "ms": 400 },
    { "kind": "type", "text": "hello@example.com" },
    { "kind": "key", "usage": 40, "mods": 0 }
  ]
}
```

Coordinates are normalized 0…1 in the mirrored content rect (y downward).

---

## Workflow API & CLI

Loopback HTTP on `http://127.0.0.1:8090` (`MIRRORUE_API_PORT` to override).

```bash
./tools/mirrorue path record start
# … interact on phone …
./tools/mirrorue path record stop --name my-path
./tools/mirrorue path list
./tools/mirrorue path play my-path
./tools/mirrorue help-api
```

| Endpoint | Action |
|----------|--------|
| `GET /v1/workflows` | List saved paths + recording state |
| `POST /v1/workflows/record/start` | Start recording |
| `POST /v1/workflows/record/stop` | Stop (+ optional `name` to save) |
| `POST /v1/workflows/play` | Replay `{ "name": "…" }` |
| `POST /v1/workflows/export` | Export to `{ "name", "path" }` |

Full reference: [docs/API.md](docs/API.md)

See [SECURITY.md](SECURITY.md) — never expose this port publicly.

---

## Licensing

MirrorUE Pro is **commercial software**. Purchase / seat licensing: contact [hello@mirrorue.dev](mailto:hello@mirrorue.dev).

The underlying MirrorUE core remains [MIT](https://github.com/KamilBourouiba/MirrorUE/blob/main/LICENSE) where applicable.

---

## Build

```bash
./tools/build_engine.sh
swift build -c release --product MirrorUE
./mirroring
```
