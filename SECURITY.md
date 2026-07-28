# Security & privacy

MirrorUE is a **local** development tool. It does not include analytics, accounts, or cloud sync.

## Trust boundary

MirrorUE only communicates with an iPhone that the user has:

1. Physically connected (USB),
2. Unlocked,
3. Trusted (“Trust This Computer”),
4. Authorized for development (**Developer Mode**).

Screen content and injected input stay on the Mac ↔ phone path (CoreMediaIO + CoreDevice). There is no MirrorUE backend that receives frames or keystrokes.

## Permissions

| Permission | Why |
|------------|-----|
| Camera / screen capture | CoreMediaIO iPhone screen device |
| Local network | CoreDevice Network usbmux peer for HID |

## Local automation API

When MirrorUE is running, an HTTP API listens on **`127.0.0.1:8090`** only (loopback). Non-local clients are rejected. Do not expose this port via port-forwarding or a public VPN without additional auth.

## What we ask you not to redistribute

- Pairing records / lockdown certificates
- Device UDIDs in public bug reports without consent
- Screen recordings that contain personal data

## DRM

Some apps intentionally black out under screen capture. That is an OS / content-protection decision, not a MirrorUE bug.
