# MirrorUE paths

Record → save → replay. No AI agent.

Paths are JSON files in `~/Documents/MirrorUE/Workflows/`.

## In the app

1. Bottom bar: enter a name → **Record** → use the phone → **Stop**
2. **Save** → **Play**

Or open the full panel: dock **Paths** / menu **Paths…** (⌘⇧P).

## CLI

```bash
./tools/mirrorue path record start
# … interact with the phone in MirrorUE …
./tools/mirrorue path record stop --name my-path
./tools/mirrorue path list
./tools/mirrorue path play my-path
```

## API

```
GET  /v1/workflows
POST /v1/workflows/record/start
POST /v1/workflows/record/stop  {"name":"optional"}
POST /v1/workflows/save         {"name":"..."}
POST /v1/workflows/play       {"name":"..."}
POST /v1/workflows/stop
```
