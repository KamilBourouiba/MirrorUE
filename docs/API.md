# MirrorUE Local API v3

Loopback-only HTTP API for scripting a connected development iPhone from your Mac.

**Base URL:** `http://127.0.0.1:8090` (override with `MIRRORUE_API_PORT`)  
**CLI:** `./tools/mirrorue`  
**Security:** bind to localhost only — do not expose publicly ([SECURITY.md](../SECURITY.md))

---

## Architecture

```text
Client (CLI / SDK / agent)
    │
    ▼
MirrorUE Local API  :8090
    ├── control/   HID taps, typing, home, open-app macros
    ├── vision/    phone frames (path or base64)
    ├── llm/       text reasoning (Ollama default; cloud providers later)
    ├── vlm/       vision Q&A (Apple FastVLM via MLX)
    └── agent/     goal loop (Ollama plan + FastVLM see + control act)
```

### Model roles

| Layer | Default | Role |
|-------|---------|------|
| **LLM** | [Ollama](https://ollama.com) (`llama3.2`) | Goal planning, JSON actions, verify "app open" |
| **VLM** | [Apple FastVLM](https://github.com/apple/ml-fast-vlm) (MLX) | Screen caption, one-shot vision Q&A |
| **Control** | CoreDevice HID | tap, swipe, type, home, Spotlight macros |

Future: `MIRRORUE_LLM_PROVIDER=openai` (user API keys) — not wired yet.

---

## Quick reference

| Method | Path | Description |
|--------|------|-------------|
| GET | `/v1` | Endpoint map |
| GET | `/v1/docs` | This documentation (markdown) |
| GET | `/v1/status` | Connection, FPS, agent, llm, vlm |
| GET | `/v1/vision/frame` | Latest phone frame |
| POST | `/v1/control/*` | HID primitives (aliases: `/v1/tap`, …) |
| POST | `/v1/llm/chat` | Ollama chat completion |
| GET | `/v1/llm/status` | Ollama health |
| POST | `/v1/vlm/ask` | FastVLM one-shot with optional frame |
| GET | `/v1/vlm/status` | FastVLM worker warm/loaded |
| POST | `/v1/agent/run` | Start goal agent (async 202) |
| GET | `/v1/agent/status` | Agent state |
| GET | `/v1/agent/logs` | Full trace |
| POST | `/v1/agent/stop` | Stop agent |

Legacy aliases without namespace prefix remain supported (`/v1/frame`, `/v1/home`, `/v1/tap`, …).

---

## Status

```http
GET /v1/status
```

```json
{
  "ok": true,
  "api": "mirrorue-local",
  "version": 3,
  "connected": true,
  "device": "iPhone",
  "displayFps": 120,
  "captureFps": 118,
  "llm": { "ok": true, "provider": "ollama", "model": "llama3.2" },
  "vlm": { "warm": true, "model": "FastVLM-1.5B" },
  "agent": { "running": false, "warm": true }
}
```

---

## Vision

Capture the live phone screen for agents or debugging.

```http
GET /v1/vision/frame?maxW=720&format=jpg&encoding=b64
```

| Query | Default | Values |
|-------|---------|--------|
| `maxW` | `720` | Max width in pixels (`0` = full) |
| `format` | `jpg` | `jpg`, `png` |
| `encoding` | `path` | `path` (file path), `b64` (base64 in JSON) |

**Response (encoding=path):**

```json
{
  "ok": true,
  "frameId": "f42",
  "path": "/var/folders/.../mirrorue-live-frame.jpg",
  "bytes": 312048,
  "maxW": 720,
  "format": "jpg",
  "encoding": "path"
}
```

**Response (encoding=b64):** same fields plus `"b64": "<base64…>"` — preferred for agents (no temp-file I/O).

Temp frame files use short ids (`mirrorue-f0042.jpg`), not epoch timestamps.

CLI:

```bash
./tools/mirrorue frame --b64 /tmp/phone.jpg
```

---

## Control

HID and high-level macros. Prefer **`POST /v1/control/do`** for batches.

### Primitives

```http
POST /v1/control/tap       {"x":0.5,"y":0.8}
POST /v1/control/swipe       {"x":0.5,"y":0.8,"x1":0.5,"y1":0.2,"ms":300}
POST /v1/control/type        {"text":"hello"}
POST /v1/control/key         {"usage":40,"mods":0}
POST /v1/control/button      {"name":"home"}
POST /v1/control/home        {}
POST /v1/control/wait        {"ms":800} | {"seconds":0.8}
POST /v1/control/spotlight   {"home":true}
POST /v1/control/clear       {"backspaces":12}
POST /v1/control/open        {"app":"Snapchat"}
```

Coordinates are normalized **0…1** in the mirrored content rect (origin top-left).

### Batch

```http
POST /v1/control/do
```

```json
{
  "steps": [
    {"op": "home"},
    {"op": "wait", "ms": 800},
    {"op": "open", "app": "Snapchat"},
    {"op": "tap", "x": 0.5, "y": 0.5}
  ]
}
```

Aliases: `/v1/do`, `/v1/tap`, `/v1/open`, …

---

## LLM (Ollama)

Text reasoning for planning and verification. Requires [Ollama](https://ollama.com) running locally:

```bash
ollama serve
ollama pull llama3.2
```

### Environment

| Variable | Default | Effect |
|----------|---------|--------|
| `OLLAMA_HOST` | `http://127.0.0.1:11434` | Ollama base URL |
| `MIRRORUE_LLM_MODEL` | `llama3.2` | Model name |
| `MIRRORUE_LLM_PROVIDER` | `ollama` | `ollama` \| `none` (future: `openai`) |

### Status

```http
GET /v1/llm/status
```

### Chat

```http
POST /v1/llm/chat
Content-Type: application/json

{
  "messages": [
    {"role": "system", "content": "You are concise."},
    {"role": "user", "content": "Summarize Spotlight search UX in one line."}
  ],
  "max_tokens": 128,
  "model": "llama3.2"
}
```

Shorthand:

```json
{"prompt": "Hello", "max_tokens": 64}
```

**Response:**

```json
{
  "ok": true,
  "text": "...",
  "provider": "ollama",
  "model": "llama3.2",
  "usage": {"prompt_est": 12, "completion": 45, "latency_ms": 890}
}
```

CLI:

```bash
./tools/mirrorue llm-status
./tools/mirrorue llm-chat "What is Spotlight on iOS?"
```

---

## VLM (FastVLM)

On-device vision via Apple FastVLM + [mlx-vlm](https://github.com/Blaizzy/mlx-vlm). Setup: [tools/fastvlm/README.md](../tools/fastvlm/README.md).

### Status

```http
GET /v1/vlm/status
```

### Ask (one-shot)

```http
POST /v1/vlm/ask
Content-Type: application/json

{
  "question": "What app is on screen?",
  "max_tokens": 48,
  "frame": true
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `question` | required | Vision + text prompt |
| `max_tokens` | `48` | Generation cap |
| `frame` | `true` | Attach live phone frame |

**Response:**

```json
{
  "ok": true,
  "text": "Snapchat camera view",
  "usage": {
    "prompt_est": 42,
    "completion": 8,
    "latency_ms": 1900,
    "vision_units": 576
  }
}
```

`usage` is local metering (not billing). One inference at a time → **429** if worker busy.

CLI:

```bash
./tools/mirrorue vlm-ask "describe the screen"
./tools/mirrorue vlm-status
```

---

## Agent

Autonomous goal loop: **FastVLM** captions the screen → **Ollama** plans JSON actions → **control** executes → verify → repeat.

```http
POST /v1/agent/run
Content-Type: application/json

{
  "goal": "open Snapchat",
  "maxSteps": 32,
  "llm": "ollama",
  "vision": "fastvlm"
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `goal` | required | Natural language task |
| `maxSteps` | `32` | Step budget |
| `llm` | `ollama` | Text provider (`none` = FastVLM-only fallback) |
| `vision` | `fastvlm` | Vision provider |

```http
GET  /v1/agent/status
GET  /v1/agent/logs
POST /v1/agent/stop
```

CLI (waits until done):

```bash
./tools/mirrorue agent "open Snapchat"
./tools/mirrorue agent-status
./tools/mirrorue agent-logs ~/Downloads/trace.log
./tools/mirrorue agent-stop
```

### Agent action JSON

Preferred VLM/LLM output:

```json
{
  "see": "Spotlight search with empty field",
  "plan": "type app name and open Top Hit",
  "acts": [
    {"op": "type", "text": "Snapchat"},
    {"op": "enter"}
  ]
}
```

Supported ops: `tap`, `swipe`, `type`, `enter`, `home`, `wait`, `done`.

### Verify before DONE

Open-app goals require LLM/VLM verify (`OPEN: yes`) before marking complete — checklist alone is not enough.

---

## Errors

| HTTP | Meaning |
|------|---------|
| 400 | Bad request / missing field |
| 403 | Not loopback |
| 404 | Unknown path |
| 409 | Agent already running |
| 429 | VLM worker busy |
| 503 | Not connected / model unavailable |
| 504 | Ask timeout |

All errors: `{"ok": false, "error": "…"}`

---

## Credits

- Vision: [Apple FastVLM](https://github.com/apple/ml-fast-vlm) · [mlx-vlm](https://github.com/Blaizzy/mlx-vlm)
- LLM default: [Ollama](https://ollama.com)
- MirrorUE: MIT — [Kamil Bourouiba](https://github.com/KamilBourouiba/MirrorUE)
