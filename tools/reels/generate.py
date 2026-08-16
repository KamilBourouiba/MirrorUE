#!/usr/bin/env python3
"""Generate product memes via Imgflip and/or memegen.link (raw API output)."""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Literal

from content import build_catalog
from imgflip_templates import TEMPLATE_IDS, caption_fields, template_id

ROOT = Path(__file__).resolve().parent
DEFAULT_OUT = ROOT / "output"
CONFIG_FILE = ROOT / "config.json"
CONFIG_EXAMPLE = ROOT / "config.example.json"
FAILED_FILE = "failed.json"

MEMEGEN_API = "https://api.memegen.link/images/"
IMGFLIP_CAPTION = "https://api.imgflip.com/caption_image"

Provider = Literal["auto", "imgflip", "memegen"]
RETRYABLE_HTTP = {429, 500, 502, 503, 504}


class ThrottleClient:
    """Pace memegen.link calls and retry on 429/503/etc."""

    def __init__(self, cfg: dict) -> None:
        t = cfg.get("throttle", {})
        self.min_delay = float(t.get("min_delay_sec", 2.0))
        self.max_retries = int(t.get("max_retries", 8))
        self.backoff_base = float(t.get("backoff_base_sec", 2.5))
        self.backoff_max = float(t.get("backoff_max_sec", 120.0))
        self.circuit_threshold = int(t.get("circuit_threshold", 4))
        self.circuit_pause_sec = float(t.get("circuit_pause_sec", 45.0))
        self._last_request = 0.0
        self._extra_delay = 0.0
        self.consecutive_failures = 0

    def pace(self) -> None:
        elapsed = time.monotonic() - self._last_request
        wait = max(self.min_delay, self._extra_delay) - elapsed
        if wait > 0:
            time.sleep(wait)

    def mark(self) -> None:
        self._last_request = time.monotonic()
        self.consecutive_failures = 0
        self._extra_delay = max(0.0, self._extra_delay * 0.5)

    def note_failure(self) -> None:
        self.consecutive_failures += 1
        self._extra_delay = min(self.backoff_max, self._extra_delay + self.backoff_base)
        if self.consecutive_failures >= self.circuit_threshold:
            print(
                f"  ⚠️  {self.consecutive_failures} memes failed in a row — "
                f"pausing {self.circuit_pause_sec:.0f}s (API throttle)"
            )
            time.sleep(self.circuit_pause_sec)
            self.consecutive_failures = 0
            self._extra_delay = min(self.backoff_max, self._extra_delay + self.backoff_base)

    def backoff(self, attempt: int, err: urllib.error.HTTPError | None = None) -> float:
        if err is not None:
            retry_after = err.headers.get("Retry-After") if err.headers else None
            if retry_after:
                try:
                    return min(self.backoff_max, float(retry_after))
                except ValueError:
                    pass
        delay = min(self.backoff_max, self.backoff_base * (2**attempt))
        return delay + random.uniform(0.0, 0.6)

    def urlopen(self, req: urllib.request.Request, timeout: int, label: str) -> Any:
        last_err: Exception | None = None
        for attempt in range(self.max_retries + 1):
            try:
                self.pace()
                resp = urllib.request.urlopen(req, timeout=timeout)
                self.mark()
                return resp
            except urllib.error.HTTPError as err:
                last_err = err
                if err.code not in RETRYABLE_HTTP or attempt >= self.max_retries:
                    raise
                wait = self.backoff(attempt, err)
                print(
                    f"  ⏳ {label}: HTTP {err.code} — wait {wait:.1f}s "
                    f"(retry {attempt + 1}/{self.max_retries})"
                )
                err.read()
                time.sleep(wait)
            except urllib.error.URLError as err:
                last_err = err
                if attempt >= self.max_retries:
                    raise
                wait = self.backoff(attempt)
                reason = getattr(err, "reason", err)
                print(
                    f"  ⏳ {label}: {reason} — wait {wait:.1f}s "
                    f"(retry {attempt + 1}/{self.max_retries})"
                )
                time.sleep(wait)
        raise last_err  # pragma: no cover


def imgflip_credentials(cfg: dict) -> tuple[str, str]:
    img = cfg.get("imgflip", {})
    user = (
        os.environ.get("IMGFLIP_USERNAME")
        or img.get("username")
        or cfg.get("imgflip_username")
        or ""
    ).strip()
    password = (
        os.environ.get("IMGFLIP_PASSWORD")
        or img.get("password")
        or cfg.get("imgflip_password")
        or ""
    ).strip()
    if not user or not password:
        raise RuntimeError(
            "Imgflip credentials missing — set imgflip.username/password in config.json "
            "or IMGFLIP_USERNAME / IMGFLIP_PASSWORD"
        )
    return user, password


def resolve_provider(cfg: dict, cli: str | None) -> Provider:
    raw = (cli or cfg.get("provider") or "auto").strip().lower()
    if raw not in ("auto", "imgflip", "memegen"):
        raise SystemExit(f"Unknown provider {raw!r} — use auto, imgflip, or memegen")
    return raw  # type: ignore[return-value]


def imgflip_available(cfg: dict) -> bool:
    try:
        imgflip_credentials(cfg)
        return True
    except RuntimeError:
        return False


def load_config() -> dict:
    with CONFIG_EXAMPLE.open(encoding="utf-8") as f:
        cfg = json.load(f)
    if CONFIG_FILE.exists():
        with CONFIG_FILE.open(encoding="utf-8") as f:
            user = json.load(f)
        for key, value in user.items():
            if isinstance(value, dict) and isinstance(cfg.get(key), dict):
                cfg[key] = {**cfg[key], **value}
            else:
                cfg[key] = value
    return cfg


def http_json(client: ThrottleClient, url: str, data: dict | None = None, timeout: int = 60) -> dict:
    headers = {"Accept": "application/json", "User-Agent": "MirrorUE-Reels/2.0"}
    body = None
    label = "memegen POST" if data is not None else "memegen GET"
    if data is not None:
        body = json.dumps(data, ensure_ascii=False).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=headers, method="POST" if body else "GET")
    with client.urlopen(req, timeout=timeout, label=label) as resp:
        return json.loads(resp.read().decode("utf-8"))


def encode_url(url: str) -> str:
    parts = urllib.parse.urlsplit(url)
    return urllib.parse.urlunsplit((
        parts.scheme,
        parts.netloc,
        urllib.parse.quote(parts.path, safe="/"),
        parts.query,
        parts.fragment,
    ))


def download(client: ThrottleClient, url: str, dest: Path, timeout: int = 120) -> None:
    req = urllib.request.Request(encode_url(url), headers={"User-Agent": "MirrorUE-Reels/2.0"})
    with client.urlopen(req, timeout=timeout, label="memegen image") as resp:
        dest.write_bytes(resp.read())


def memegen_create(client: ThrottleClient, template: str, text: list[str]) -> str:
    result = http_json(client, MEMEGEN_API, {"template_id": template, "text": text})
    url = result.get("url")
    if not url:
        raise RuntimeError(f"memegen.link returned no url: {result}")
    return url


def imgflip_create(client: ThrottleClient, cfg: dict, template: str, text: list[str]) -> str:
    if template not in TEMPLATE_IDS:
        raise KeyError(f"No Imgflip mapping for template {template!r}")
    user, password = imgflip_credentials(cfg)
    fields = {
        "template_id": str(template_id(template)),
        "username": user,
        "password": password,
        **caption_fields(text, template),
    }
    body = urllib.parse.urlencode(fields).encode("utf-8")
    req = urllib.request.Request(
        IMGFLIP_CAPTION,
        data=body,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "MirrorUE-Reels/2.0",
        },
        method="POST",
    )
    with client.urlopen(req, timeout=60, label="imgflip caption") as resp:
        result = json.loads(resp.read().decode("utf-8"))
    if not result.get("success"):
        raise RuntimeError(result.get("error_message") or result)
    url = result.get("data", {}).get("url")
    if not url:
        raise RuntimeError(f"Imgflip returned no url: {result}")
    return url


def create_meme_url(
    client: ThrottleClient,
    cfg: dict,
    template: str,
    text: list[str],
    provider: Provider,
) -> tuple[str, str]:
    """Return (image_url, provider_used)."""
    order: list[Provider]
    if provider == "auto":
        order = ["imgflip", "memegen"] if imgflip_available(cfg) else ["memegen"]
    elif provider == "imgflip":
        order = ["imgflip"]
    else:
        order = ["memegen"]

    errors: list[str] = []
    for name in order:
        try:
            if name == "imgflip":
                return imgflip_create(client, cfg, template, text), "imgflip"
            url = memegen_create(client, template, text)
            return memegen_finalize(url, cfg), "memegen"
        except (urllib.error.HTTPError, urllib.error.URLError, RuntimeError, KeyError, OSError) as err:
            errors.append(f"{name}: {err}")
            if provider != "auto":
                raise
            print(f"  ↪ {name} failed ({err}) — trying next provider")

    raise RuntimeError("All providers failed: " + "; ".join(errors))


def memegen_slug(text: str) -> str:
    text = text.replace("?", "~q").replace("'", "").replace('"', "")
    text = text.lower()
    text = re.sub(r"[^a-z0-9~_\s-]", "", text)
    text = re.sub(r"[\s-]+", "_", text).strip("_")
    return text


def memegen_finalize(url: str, cfg: dict) -> str:
    mg = cfg.get("memegen", {})
    params = {}
    if mg.get("width"):
        params["width"] = str(mg["width"])
    if mg.get("height"):
        params["height"] = str(mg["height"])
    fmt = mg.get("format")
    if fmt and fmt != "jpg" and url.endswith(".jpg"):
        url = url[:-4] + f".{fmt}"
    if not params:
        return url
    sep = "&" if "?" in url else "?"
    return url + sep + urllib.parse.urlencode(params)


def memegen_url(item: dict, cfg: dict) -> str:
    """Public memegen URL for a catalog item (no download)."""
    parts = "/".join(memegen_slug(t) for t in item["text"])
    base = f"https://api.memegen.link/images/{item['template']}/{parts}.jpg"
    return memegen_finalize(base, cfg)


def generate_one(
    item: dict,
    cfg: dict,
    out_dir: Path,
    client: ThrottleClient,
    provider: Provider,
) -> tuple[Path, str, str]:
    url, used = create_meme_url(client, cfg, item["template"], item["text"], provider)
    if ".webp" in url.split("?")[0].lower():
        ext = ".webp"
    elif url.endswith(".png"):
        ext = ".png"
    else:
        ext = ".jpg"
    dest = out_dir / f"{item['id']}{ext}"
    download(client, url, dest)
    return dest, url, used


def source_url_for_item(item: dict, cfg: dict, provider: Provider) -> str:
    """Best-effort public URL when skipping an existing local file."""
    if provider == "memegen" or (provider == "auto" and not imgflip_available(cfg)):
        return memegen_url(item, cfg)
    if item["template"] in TEMPLATE_IDS:
        return f"https://imgflip.com/i/template/{template_id(item['template'])}"
    return memegen_url(item, cfg)


def output_exists(out_dir: Path, meme_id: str) -> bool:
    for ext in (".jpg", ".png", ".webp"):
        if (out_dir / f"{meme_id}{ext}").exists():
            return True
    return False


def save_failed(out_dir: Path, failed: list[dict]) -> None:
    path = out_dir / FAILED_FILE
    path.write_text(json.dumps(failed, indent=2), encoding="utf-8")


def load_failed(out_dir: Path) -> list[str]:
    path = out_dir / FAILED_FILE
    if not path.exists():
        return []
    data = json.loads(path.read_text(encoding="utf-8"))
    return [row["id"] for row in data if row.get("id")]


def run_batch(
    memes: list[dict],
    cfg: dict,
    out_dir: Path,
    client: ThrottleClient,
    resume: bool,
    provider: Provider,
) -> tuple[list[dict], list[dict], dict[str, str]]:
    generated: list[dict] = []
    failed: list[dict] = []
    sources: dict[str, str] = {}
    total = len(memes)

    for n, item in enumerate(memes, start=1):
        if resume and output_exists(out_dir, item["id"]):
            print(f"[{n}/{total}] skip {item['id']} (exists)")
            generated.append(item)
            sources[item["id"]] = source_url_for_item(item, cfg, provider)
            continue
        try:
            path, url, used = generate_one(item, cfg, out_dir, client, provider)
            sources[item["id"]] = url
            generated.append(item)
            tag = f" ({used})" if used != "memegen" else ""
            print(f"[{n}/{total}] {path.name}{tag}")
        except (urllib.error.HTTPError, urllib.error.URLError, RuntimeError, ValueError, OSError) as err:
            client.note_failure()
            row = {"id": item["id"], "error": str(err)}
            failed.append(row)
            save_failed(out_dir, failed)
            print(f"FAIL [{n}/{total}] {item['id']}: {err}")

    return generated, failed, sources


def hashtags_for(item: dict, data: dict) -> list[str]:
    key = item.get("hashtags", "default")
    return list(data.get("hashtag_sets", {}).get(key, data.get("hashtag_sets", {}).get("default", [])))


def post_text(item: dict, data: dict) -> str:
    """Reel caption: hashtags only (no links — bad for reach)."""
    return " ".join(hashtags_for(item, data))


def write_captions(items: list[dict], data: dict, out_dir: Path, sources: dict[str, str]) -> Path:
    brand = data["brand"]
    personas = data.get("personas", {})
    lines = [
        f"# MirrorUE — product memes ({datetime.now(timezone.utc).strftime('%Y-%m-%d')})",
        "",
        f"Site: https://{brand['url']}",
        "",
        "---",
        "",
    ]
    for item in items:
        persona = item.get("persona", "")
        pinfo = personas.get(persona, {})
        lines += [
            f"## {item['id']} · {pinfo.get('name', persona)}",
            "",
            post_text(item, data),
            "",
            f"File: `{item['id']}.jpg`",
            f"Image URL: {sources.get(item['id'], memegen_url(item, load_config()))}",
            "",
            "---",
            "",
        ]
    path = out_dir / "captions.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    return path


def main() -> None:
    parser = argparse.ArgumentParser(description="Generate MirrorUE product memes")
    parser.add_argument("--list", action="store_true")
    parser.add_argument("--id", action="append", dest="ids")
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--persona", choices=["lucas", "sarah", "thomas", "nadia"])
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--limit", type=int, default=0, help="Max memes to generate (0 = all)")
    parser.add_argument("--resume", action="store_true", help="Skip memes already saved in output/")
    parser.add_argument(
        "--retry-failed",
        action="store_true",
        help="Only retry ids listed in output/failed.json",
    )
    parser.add_argument(
        "--retry-rounds",
        type=int,
        default=2,
        help="Extra passes over failures after the first batch (default: 2)",
    )
    parser.add_argument(
        "--provider",
        choices=["auto", "imgflip", "memegen"],
        help="Meme API: auto=Imgflip then memegen fallback (default from config)",
    )
    args = parser.parse_args()

    data = build_catalog()
    cfg = load_config()
    provider = resolve_provider(cfg, args.provider)
    client = ThrottleClient(cfg)

    memes = data["memes"]
    print(f"Catalog: {len(memes)} memes")

    if args.list:
        for m in memes:
            preview = " / ".join(m["text"][:2])[:50]
            print(f"{m['id']}  {m['template']:18}  {m['persona']:7}  {preview}")
        return

    if args.persona:
        memes = [m for m in memes if m["persona"] == args.persona]
    if args.retry_failed:
        failed_ids = set(load_failed(args.out))
        if not failed_ids:
            print(f"No {FAILED_FILE} in {args.out} — nothing to retry.")
            return
        memes = [m for m in memes if m["id"] in failed_ids]
    elif args.ids:
        memes = [m for m in memes if m["id"] in args.ids]
        missing = set(args.ids) - {m["id"] for m in memes}
        if missing:
            raise SystemExit(f"Unknown id(s): {', '.join(sorted(missing))}")
    elif not args.all:
        parser.print_help()
        print("\nTry: ./tools/reels/run --all")
        return

    if args.limit > 0:
        memes = memes[: args.limit]

    args.out.mkdir(parents=True, exist_ok=True)
    if provider == "imgflip" and not imgflip_available(cfg):
        raise SystemExit(
            "Provider imgflip requires credentials — add imgflip.username/password to config.json"
        )
    provider_note = provider
    if provider == "auto":
        provider_note = "auto (imgflip → memegen)" if imgflip_available(cfg) else "auto (memegen only, no Imgflip creds)"
    print(f"Provider: {provider_note}")
    print(
        f"Throttle: {client.min_delay}s between calls, "
        f"up to {client.max_retries} retries on 429/503, "
        f"circuit pause {client.circuit_pause_sec:.0f}s after {client.circuit_threshold} fails"
    )

    all_generated: list[dict] = []
    all_sources: dict[str, str] = {}
    pending = memes
    rounds = 1 + max(0, args.retry_rounds)

    for round_idx in range(rounds):
        if round_idx > 0:
            if not pending:
                break
            print(f"\n--- Retry pass {round_idx}/{args.retry_rounds} ({len(pending)} memes) ---")
        generated, failed, sources = run_batch(
            pending,
            cfg,
            args.out,
            client,
            resume=args.resume and round_idx == 0,
            provider=provider,
        )
        all_sources.update(sources)
        seen = {m["id"] for m in all_generated}
        for m in generated:
            if m["id"] not in seen:
                all_generated.append(m)
                seen.add(m["id"])
        if failed:
            save_failed(args.out, failed)
            pending = [m for m in memes if m["id"] in {f["id"] for f in failed}]
        else:
            save_failed(args.out, [])
            pending = []
            break

    if all_generated:
        print(f"Wrote {write_captions(all_generated, data, args.out, all_sources)}")
        manifest = args.out / "buffer-posts.json"
        rows = [
            {"id": m["id"], "text": post_text(m, data), "image_url": all_sources[m["id"]]}
            for m in all_generated
            if m["id"] in all_sources
        ]
        if rows:
            manifest.write_text(json.dumps(rows, indent=2), encoding="utf-8")
            print(f"Wrote {manifest}")

    remaining = load_failed(args.out)
    if remaining:
        print(f"\n{len(remaining)} still failed — saved to {args.out / FAILED_FILE}")
        print("Retry later: ./tools/reels/run --retry-failed --resume")
        raise SystemExit(1)


if __name__ == "__main__":
    main()
