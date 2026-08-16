# MirrorUE Local API v3

Loopback-only HTTP API for controlling a connected development iPhone and
running the bounded phone agent from the Mac.

**Base URL:** `http://127.0.0.1:8090` (override with `MIRRORUE_API_PORT`)  
**CLI:** `./tools/mirrorue`  
**Security:** the listener binds explicitly to IPv4 loopback. Never proxy or
forward it to another interface; see [SECURITY.md](../SECURITY.md).

## Architecture

```text
LM Studio / OpenAI-compatible API
                 ▲
                 │ compact OCR + optional 720 px JPEG
                 │ async Chat Completions with one strict tool
                 ▼
MirrorUE agent ── observe → decide → validate → act → settle ──┐
     ▲                                                         │
     └──────────── CoreMediaIO frame + CoreDevice HID ◀────────┘

CLI / local SDK → 127.0.0.1:8090
                    ├── workflows/ record, validate, save and replay
                    ├── control/  direct HID actions and macros
                    ├── vision/   latest frame
                    ├── llm/      selected provider test/chat
                    └── agent/    bounded goal run/status/logs/stop
```

Provider URL, model, screenshot permission, and token are configured in the
app's **AI Provider…** panel. Non-secret profile fields use UserDefaults; the
token is stored separately in macOS Keychain and is never returned by this API.

The built-in adapter accepts OpenAI-compatible APIs. Its default LM Studio base
is `http://127.0.0.1:1234/v1`; the adapter calls `GET /models` and
`POST /chat/completions` below that base. More provider protocols can be added
behind the same stored-profile and agent interfaces.
Plain HTTP provider URLs are accepted only for loopback; remote providers must
use HTTPS so tokens and optional screenshots are encrypted in transit.

Chat reasoning is profile-scoped and cannot be overridden through the local
HTTP API. Generic OpenAI-compatible profiles use **Provider default**, which
omits `reasoning_effort`. For reliable bounded tool calls, phone-agent requests
using the LM Studio preset always send `"reasoning_effort":"none"` even if
general chat is saved as Low, Medium, or High. `GET /v1/llm/status` reports
both `chatReasoning` and effective `agentReasoning`.

Chat Completions reasoning controls require LM Studio 0.4.8 or newer. A local
smoke test on LM Studio 0.4.20 with `qwen/qwen3.5-9b` reduced an otherwise
comparable request from 55.9 s to 8.3 s and reported reasoning tokens from 138
to 0. This is a model-, prompt-, and machine-dependent compatibility result,
not a performance guarantee. Other OpenAI-compatible servers may reject
`reasoning_effort`; use **Provider default** for those endpoints.

## Quick start with LM Studio

1. Start LM Studio's local server and load a tool-capable Qwen model.
2. In MirrorUE, open **AI Provider…**, choose **LM Studio**, test the
   connection, select the model, and save.
3. Connect and unlock the iPhone.
4. Open the right sidebar's **AI Runs** tab, enter a small reversible goal such
   as `Open Settings`, and press **Run**.

The screenshot toggle controls whether a JPEG can be sent to the selected
provider. When it is off, MirrorUE sends only local macOS Vision OCR with
normalized coordinates. A text-only Qwen model can therefore operate many
screens; a vision-capable model generally handles icons and unlabeled controls
better.

LM Studio setup and compatible endpoint details:
[local server](https://lmstudio.ai/docs/developer/core/server),
[OpenAI-compatible endpoints](https://lmstudio.ai/docs/developer/openai-compat),
and [tool use](https://lmstudio.ai/docs/developer/openai-compat/tools).

## Quick reference

| Method | Path | Description |
|---|---|---|
| GET | `/v1` | Endpoint map |
| GET | `/v1/docs` | This file as JSON-wrapped Markdown |
| GET | `/v1/status` | iPhone connection and capture status |
| GET | `/v1/workflows` | Workflow library and live state |
| POST | `/v1/workflows/*` | Record, save, play, stop, or export |
| GET | `/v1/vision/frame` | Latest phone frame |
| POST | `/v1/control/*` | Direct HID primitives and macros |
| GET | `/v1/llm/status` | Test the selected provider and list models |
| POST | `/v1/llm/chat` | Text-only request through the selected provider |
| POST | `/v1/agent/run` | Start one asynchronous goal run |
| GET | `/v1/agent/status` | Current run and aggregate metrics |
| GET | `/v1/agent/logs` | Bounded current-run trace |
| POST | `/v1/agent/stop` | Cooperatively cancel the current run |

Legacy aliases remain available (`/v1/frame`, `/v1/tap`, `/v1/home`, and
similar paths).

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
  "state": "Connected",
  "displayFps": 120,
  "captureFps": 118,
  "apiPort": 8090
}
```

## Vision

```http
GET /v1/vision/frame?maxW=720&format=jpg&encoding=path
```

| Query | Default | Values |
|---|---:|---|
| `maxW` | `720` | Maximum width (`0...4096`); `0` keeps full width |
| `format` | `jpg` | `jpg` or `png` |
| `encoding` | `path` | `path` or `b64` |

```json
{
  "ok": true,
  "frameId": "f42",
  "path": "/var/folders/.../mirrorue-live-frame.jpg",
  "bytes": 148234,
  "maxW": 720,
  "format": "jpg",
  "encoding": "path"
}
```

`encoding=b64` also includes `"b64": "..."`. The public frame endpoint retains
its compatibility file path; the in-app agent instead encodes directly from the
live pixel buffer and does not write an intermediate frame.

```bash
./tools/mirrorue frame /tmp/phone.jpg
./tools/mirrorue frame --b64 /tmp/phone.jpg
```

## Control

Coordinates are normalized from `0` to `1` with the origin at the top left of
the mirrored phone content.

```http
POST /v1/control/tap
Content-Type: application/json

{"x": 0.5, "y": 0.8}
```

Available primitives and macros:

```text
POST /v1/control/tap        {"x":0.5,"y":0.8}
POST /v1/control/swipe      {"x":0.5,"y":0.8,"x1":0.5,"y1":0.2,"ms":300}
POST /v1/control/type       {"text":"hello"}
POST /v1/control/key        {"usage":40,"mods":0}
POST /v1/control/button     {"name":"home"}
POST /v1/control/home       {}
POST /v1/control/wait       {"ms":800}
POST /v1/control/spotlight  {"home":true}
POST /v1/control/clear      {"backspaces":12}
POST /v1/control/open       {"app":"Settings"}
```

Batch several deterministic actions to avoid HTTP round trips:

```http
POST /v1/control/do
Content-Type: application/json

{
  "steps": [
    {"op": "home"},
    {"op": "wait", "ms": 500},
    {"op": "open", "app": "Settings"}
  ]
}
```

## Workflows

The **Workflow** sidebar tab records manual taps, swipes, typing, clipboard
text, and supported dock buttons. Saved files live in the current source
checkout's `Workflows/` directory for development builds and in
`~/Documents/MirrorUE/Workflows/` for packaged builds.

```text
GET  /v1/workflows
GET  /v1/workflows/status
POST /v1/workflows/record/start  {}
POST /v1/workflows/record/stop   {"name":"open-settings"}
POST /v1/workflows/save          {"name":"open-settings"}
POST /v1/workflows/play          {"name":"open-settings"}
POST /v1/workflows/stop          {}
POST /v1/workflows/export        {"name":"open-settings","path":"/tmp/open-settings.json"}
```

Playback holds device arbitration for the complete run and is rejected while
an AI run is starting or active. Workflow files are capped at 2 MB and 2,048
steps; coordinates, durations, keys, buttons, and typed payloads are validated
before playback.

```bash
./tools/mirrorue workflow list
./tools/mirrorue workflow record start
./tools/mirrorue workflow record stop --name open-settings
./tools/mirrorue workflow play open-settings
./tools/mirrorue workflow stop
./tools/mirrorue workflow export open-settings /tmp/open-settings.json
```

## Selected model provider

Provider configuration and secrets are deliberately UI-only. The local API can
test or use the selected profile but cannot read or replace its token.

### Status

```http
GET /v1/llm/status
```

```json
{
  "ok": true,
  "provider": "lm-studio",
  "name": "LM Studio",
  "host": "http://127.0.0.1:1234/v1",
  "model": "qwen-model-id",
  "models": ["qwen-model-id"],
  "latency_ms": 8,
  "screenshots": true,
  "chatReasoning": "high",
  "agentReasoning": "none",
  "detail": "connected; 1 model available in 8 ms"
}
```

### Text chat

```http
POST /v1/llm/chat
Content-Type: application/json

{
  "messages": [
    {"role": "system", "content": "Be concise."},
    {"role": "user", "content": "Reply with one word."}
  ],
  "temperature": 0,
  "max_tokens": 64
}
```

The shorthand `{"prompt":"Hello","max_tokens":64}` is also accepted. A request
may override `model`; it cannot override the provider URL or authentication.

```json
{
  "ok": true,
  "text": "Hello",
  "provider": "LM Studio",
  "model": "qwen-model-id",
  "usage": {
    "prompt": 24,
    "completion": 2,
    "total": 26,
    "latency_ms": 184
  }
}
```

```bash
./tools/mirrorue llm-status
./tools/mirrorue llm-chat "Reply with one word"
```

## Phone agent

Only one run can execute at a time. Each iteration captures one observation,
sends one request, validates exactly one tool call, and checks goal success
before acting. If more work is needed, it executes a micro-plan of at most three
safe consecutive actions ending at an explicit visual checkpoint, waits for
the screen to settle, and observes again. It never batches across an action
whose result must be seen before choosing the next target. A completed run has
zero final actions and records the visible evidence used to verify success.
Default limits are 12 steps, 24 total actions, four short history entries, and
200 log entries.

The accepted model actions are:

- `tap` and `swipe` with finite normalized coordinates;
- `type` with bounded text;
- `open_app` with a bounded app name;
- an allow-list of hardware/system buttons;
- a bounded `wait`.

Unknown operations and fields fail closed. Typed text is omitted from logs.
Pressing Stop cancels provider I/O, typing loops, gestures, waits, and app-open
macros; any active key or touch is released.

`open_app` first asks the connected CoreDevice AppService to resolve the
installed app and launch its exact bundle identifier. The compact name catalog
is cached for five minutes. If that service is unavailable, MirrorUE falls back
to the cancellable HID Search macro. A persistent application-state
notification monitor contributes trusted foreground bundle identity to agent
observations; model completion that contradicts this signal is rejected and
re-observed.

### Start

```http
POST /v1/agent/run
Content-Type: application/json

{
  "goal": "Open Settings",
  "maxSteps": 12
}
```

```json
{
  "ok": true,
  "runId": "e03f36cf-7fc2-4930-9e80-03f52cbdd135",
  "state": "queued",
  "running": true,
  "maxSteps": 12
}
```

`maxSteps` is clamped to `1...32`. A second concurrent run returns `409`.

### Inspect and stop

```http
GET  /v1/agent/status
GET  /v1/agent/logs
POST /v1/agent/stop
Content-Type: application/json

{}
```

Status includes the state, step, selected provider, completion/error summary,
and aggregate prompt tokens, completion tokens, LLM latency, and executed
action count.

```bash
./tools/mirrorue agent "Open Settings"
./tools/mirrorue agent --max-steps 6 --no-wait "Open Settings"
./tools/mirrorue agent-status
./tools/mirrorue agent-logs
./tools/mirrorue agent-stop
```

## Performance choices

- The display capture ring retains six zero-copy frames by default instead of
  32. Override with `MIRRORUE_CAPTURE_SLOTS` only when diagnosing stalls.
- One shared Core Image context performs in-memory JPEG encoding and tiny
  perceptual fingerprints.
- OCR uses fast local Vision recognition; screenshots are capped at
  720×1280 and JPEG quality 0.68.
- The provider session reuses connections and has no URL cache.
- Generic providers omit reasoning effort by default; LM Studio defaults to
  `none` to avoid hidden reasoning work when the model honors the setting.
- Multi-action turns and screen-change polling reduce model calls and fixed
  sleeps.
- Context, actions, logs, steps, output tokens, and response sizes are bounded.

For lowest latency, keep LM Studio on `127.0.0.1`, use a quantized model that
fits fully in available unified memory/VRAM, enable screenshots only for a
vision-capable model, and start with `maxSteps` between 4 and 8.

## Errors

| HTTP | Meaning |
|---:|---|
| 400 | Missing or invalid request field |
| 403 | Request did not originate from loopback |
| 404 | Unknown path |
| 409 | An agent run is already active |
| 503 | Phone, provider, frame, or agent unavailable |

Errors use `{"ok":false,"error":"..."}`.
