# Changelog

## 1.3.0 — Phase 5 foundation

### Added
- Local loopback automation API on `127.0.0.1:8090` (`/v1/status`, `/v1/tap`, `/v1/swipe`, `/v1/type`, `/v1/key`, `/v1/button`, `/v1/workflows/run`)
- `tools/mirrorue-cli` helper for curl-based scripting
- In-app **Privacy & Security** panel + `SECURITY.md`
- Workflow record / play / save JSON (Phase 4)
- Screenshot, screen recording, show-touches, paste clipboard (Phase 3)
- Connection state machine, recovery, performance panel (Phase 2)
- `.app` / `.dmg` packaging via `tools/package_app.sh` (Phase 1)
- First-launch checklist + Settings UI

## 1.0.0 — Public MIT release

- CoreMediaIO + Metal mirroring (target 120 fps)
- CoreDevice UniversalHID (touch, buttons, keyboard)
- Auto keyboard layout mapping
