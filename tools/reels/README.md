# MirrorUE Reels — 100 product memes

**100 English memes** aimed at four buyer personas. Copy is about **what MirrorUE does for them** — not CoreMediaIO, APIs, or internal architecture.

Memes are generated via **[Imgflip](https://imgflip.com/api)** (primary) with **[memegen.link](https://memegen.link)** fallback — raw API output, no logo overlay.

## Provider (`auto` / `imgflip` / `memegen`)

Default: **`auto`** — Imgflip first when credentials are set, then memegen on failure.

1. Create a free [Imgflip](https://imgflip.com/signup) account (dedicated bot account recommended).
2. Add to `config.json`:

```json
{
  "provider": "auto",
  "imgflip": {
    "username": "your_imgflip_username",
    "password": "your_imgflip_password"
  }
}
```

Or export `IMGFLIP_USERNAME` / `IMGFLIP_PASSWORD`.

```bash
./tools/reels/run --persona sarah --limit 10 --all --resume
./tools/reels/run --provider imgflip --persona sarah --limit 10 --all
./tools/reels/run --provider memegen --retry-failed --resume
```

Imgflip adds a small watermark; memegen supports custom width/height (1080×1920) when used.

## Throttle (503 / rate limits)

memegen.link may return **503** when hit too fast. Defaults in `config.example.json`:

```json
"throttle": {
  "min_delay_sec": 2.0,
  "max_retries": 8,
  "backoff_base_sec": 2.5,
  "backoff_max_sec": 120,
  "circuit_threshold": 4,
  "circuit_pause_sec": 45
}
```

```bash
./tools/reels/run --all --resume          # skip files already in output/
./tools/reels/run --retry-failed --resume # only ids in output/failed.json
```

## Buffer scheduling

Buffer needs **public HTTPS image URLs**. The scheduler resolves each meme via the memegen API first, then posts to Instagram (or another channel).

1. Copy `config.example.json` → `config.json` (gitignored)
2. Add your Buffer personal API key and `channel_id`
3. Run:

```bash
export BUFFER_API_KEY=your_key   # or set buffer.api_key in config.json
python3 tools/reels/schedule_buffer.py --list-channels
python3 tools/reels/schedule_buffer.py --count 10   # spread across today (Europe/Paris)
python3 tools/reels/schedule_buffer.py --dry-run --count 3
```

Options: `--start-hour`, `--end-hour`, `--tz`, `--id lucas-01`, `--require-local`.

## Favicon (site)

Regenerate favicons after replacing `docs/logo.png`:

```bash
python3 tools/reels/prepare_brand.py
```

## Quick start

```bash
./tools/reels/run --all              # all 100 (~20–40 min with throttle)
./tools/reels/run --all --limit 5    # smoke test
./tools/reels/run --persona sarah    # 25 QA memes
open tools/reels/output
```

## Personas (25 memes each)

| Key | Who | Product angle |
|-----|-----|----------------|
| `lucas` | Indie iOS dev | Client demos on real iPhone, keyboard, 120fps |
| `sarah` | Mobile QA | Repeat flows, device repro, saved paths (Pro) |
| `thomas` | Creator / trainer | Record tutorials, one app, clean footage |
| `nadia` | QA lead | Team alignment, Fleet, no cloud farm yet |

Edit copy in [`content.py`](content.py).

Output: `tools/reels/output/` (gitignored)
