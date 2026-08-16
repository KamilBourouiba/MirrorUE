#!/usr/bin/env python3
"""Schedule meme posts to Buffer (GraphQL API)."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from content import build_catalog
from generate import (
    Provider,
    ThrottleClient,
    create_meme_url,
    load_config,
    memegen_url,
    output_exists,
    post_text,
    resolve_provider,
)

ROOT = Path(__file__).resolve().parent
DEFAULT_OUT = ROOT / "output"
BUFFER_API = "https://api.buffer.com"
UPLOAD_CACHE_FILE = "buffer-uploads.json"
VIDEO_CACHE_FILE = "buffer-videos.json"
IMGUR_API = "https://api.imgur.com/3/upload"
IMGUR_CLIENT_ID = "546c25a59c58ad7"  # anonymous uploads


def buffer_key(cfg: dict) -> str:
    key = os.environ.get("BUFFER_API_KEY") or cfg.get("buffer", {}).get("api_key") or ""
    if not key:
        raise SystemExit(
            "Set BUFFER_API_KEY or buffer.api_key in tools/reels/config.json (gitignored)."
        )
    return key


def gql(api_key: str, query: str, variables: dict | None = None) -> dict:
    payload: dict = {"query": query}
    if variables:
        payload["variables"] = variables
    body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(
        BUFFER_API,
        data=body,
        headers={
            "Content-Type": "application/json",
            "Authorization": f"Bearer {api_key}",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=60) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as err:
        detail = err.read().decode("utf-8", errors="replace")
        raise SystemExit(f"Buffer HTTP {err.code}: {detail}") from err

    if data.get("errors"):
        raise SystemExit(f"Buffer GraphQL error: {data['errors']}")
    return data


def list_channels(api_key: str, org_id: str | None) -> list[dict]:
    if not org_id:
        org_query = """
        query {
          account {
            organizations { id name }
          }
        }
        """
        org_data = gql(api_key, org_query)
        orgs = org_data["data"]["account"]["organizations"]
        if not orgs:
            raise SystemExit("No Buffer organizations on this account.")
        if len(orgs) == 1:
            org_id = orgs[0]["id"]
        else:
            print("Buffer organizations:")
            for org in orgs:
                print(f"  {org['id']}  {org['name']}")
            raise SystemExit("Set buffer.organization_id in config.json.")

    query = """
    query Channels($orgId: OrganizationId!) {
      channels(input: { organizationId: $orgId }) {
        id
        name
        service
      }
    }
    """
    data = gql(api_key, query, {"orgId": org_id})
    return [{**ch, "organizationId": org_id} for ch in data["data"]["channels"]]


def pick_channel(channels: list[dict], cfg: dict) -> dict:
    buf = cfg.get("buffer", {})
    channel_id = buf.get("channel_id")
    if channel_id:
        for ch in channels:
            if ch["id"] == channel_id:
                return ch
        raise SystemExit(f"channel_id {channel_id!r} not found on your Buffer account.")

    service = (buf.get("service") or "").lower()
    if service:
        matches = [c for c in channels if (c.get("service") or "").lower() == service]
        if len(matches) == 1:
            return matches[0]
        if matches:
            print("Multiple channels for service", service)
            for c in matches:
                print(f"  {c['id']}  {c['name']}  ({c['service']})")
            raise SystemExit("Set buffer.channel_id in config.json to disambiguate.")

    if len(channels) == 1:
        return channels[0]

    print("Connected Buffer channels:")
    for ch in channels:
        org = ch.get("organizationName", "")
        prefix = f"{org} · " if org else ""
        print(f"  {ch['id']}  {prefix}{ch['name']}  ({ch['service']})")
    raise SystemExit("Set buffer.channel_id in tools/reels/config.json and re-run.")


def schedule_times(
    count: int,
    tz_name: str,
    start_hour: int,
    end_hour: int,
    *,
    day_offset: int = 0,
) -> list[datetime]:
    tz = ZoneInfo(tz_name)
    now = datetime.now(tz)
    base = now + timedelta(days=day_offset)
    day_start = base.replace(hour=start_hour, minute=0, second=0, microsecond=0)
    day_end = base.replace(hour=end_hour, minute=0, second=0, microsecond=0)

    if day_offset == 0 and now >= day_end:
        raise SystemExit("No remaining slots today — use --day-offset 1 for tomorrow.")

    if day_offset == 0:
        first = max(now + timedelta(minutes=15), day_start)
    else:
        first = day_start

    if first >= day_end:
        first = day_start if day_offset else now + timedelta(minutes=15)

    span = (day_end - first).total_seconds()
    if count <= 1:
        return [first.astimezone(timezone.utc)]

    step = span / (count - 1) if count > 1 else 0
    slots: list[datetime] = []
    for i in range(count):
        local = first + timedelta(seconds=step * i)
        slots.append(local.astimezone(timezone.utc))
    return slots


def local_image_path(out_dir: Path, meme_id: str) -> Path | None:
    for ext in (".jpg", ".png", ".webp"):
        path = out_dir / f"{meme_id}{ext}"
        if path.exists():
            return path
    return None


def load_upload_cache(out_dir: Path) -> dict[str, str]:
    path = out_dir / UPLOAD_CACHE_FILE
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def save_upload_cache(out_dir: Path, cache: dict[str, str]) -> None:
    (out_dir / UPLOAD_CACHE_FILE).write_text(json.dumps(cache, indent=2), encoding="utf-8")


def load_video_cache(out_dir: Path) -> dict[str, str]:
    path = out_dir / VIDEO_CACHE_FILE
    if not path.exists():
        return {}
    return json.loads(path.read_text(encoding="utf-8"))


def save_video_cache(out_dir: Path, cache: dict[str, str]) -> None:
    (out_dir / VIDEO_CACHE_FILE).write_text(json.dumps(cache, indent=2), encoding="utf-8")


def imgur_client_id(cfg: dict) -> str:
    return os.environ.get("IMGUR_CLIENT_ID") or cfg.get("buffer", {}).get("imgur_client_id") or IMGUR_CLIENT_ID


def upload_public(path: Path, client_id: str) -> str:
    import base64

    field = "video" if path.suffix.lower() in {".mp4", ".mov", ".webm"} else "image"
    body = urllib.parse.urlencode({
        field: base64.b64encode(path.read_bytes()).decode("ascii"),
        "type": "base64",
        "name": path.name,
    }).encode("ascii")
    req = urllib.request.Request(
        IMGUR_API,
        data=body,
        headers={
            "Authorization": f"Client-ID {client_id}",
            "Content-Type": "application/x-www-form-urlencoded",
        },
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=180) as resp:
        data = json.loads(resp.read().decode("utf-8"))
    if not data.get("success"):
        raise RuntimeError(f"Imgur upload failed: {data}")
    link = data["data"].get("link") or data["data"].get("mp4")
    if not link:
        raise RuntimeError(f"Imgur returned no link: {data}")
    # Imgur CDN needs a moment before Buffer can fetch the file.
    time.sleep(3)
    return link


def _image_is_webp(path: Path) -> bool:
    try:
        head = path.read_bytes()[:12]
    except OSError:
        return False
    return head[:4] == b"RIFF" and head[8:12] == b"WEBP"


def normalize_reel_source(jpg: Path, work_dir: Path) -> Path:
    """ffmpeg -loop 1 misbehaves on WebP files saved as .jpg — normalize first."""
    if not _image_is_webp(jpg):
        return jpg
    work_dir.mkdir(parents=True, exist_ok=True)
    dest = work_dir / f"{jpg.stem}-norm.jpg"
    if dest.exists() and dest.stat().st_mtime >= jpg.stat().st_mtime:
        return dest
    try:
        from PIL import Image
    except ImportError as err:
        raise RuntimeError("Pillow required to convert WebP memes for Reels") from err
    with Image.open(jpg) as im:
        im.convert("RGB").save(dest, "JPEG", quality=92)
    return dest


def reel_layout(cfg: dict) -> tuple[int, int, int, float]:
    reel = cfg.get("reel", {})
    border = int(reel.get("border_px", 48))
    border = max(0, min(border, 120))
    duration = float(reel.get("duration_sec", 6.0))
    return 1080, 1920, border, duration


def jpg_to_reel_mp4(jpg: Path, out_dir: Path, cfg: dict, *, force: bool = False) -> Path:
    """Build 9:16 Reel MP4 — cover-scale meme with a thin border (no side gaps)."""
    out_dir.mkdir(parents=True, exist_ok=True)
    dest = out_dir / f"{jpg.stem}-reel.mp4"
    if (
        not force
        and dest.exists()
        and dest.stat().st_size > 0
        and dest.stat().st_mtime >= jpg.stat().st_mtime
    ):
        return dest

    frame_w, frame_h, border, seconds = reel_layout(cfg)
    inner_w = frame_w - 2 * border
    inner_h = frame_h - 2 * border
    source = normalize_reel_source(jpg, out_dir / "norm")
    # Cover inner frame (crop excess), then pad to full 9:16 with black border.
    vf = (
        f"scale={inner_w}:{inner_h}:force_original_aspect_ratio=increase,"
        f"crop={inner_w}:{inner_h},"
        f"pad={frame_w}:{frame_h}:(ow-iw)/2:(oh-ih)/2:color=black"
    )
    cmd = [
        "ffmpeg", "-y", "-loop", "1", "-i", str(source),
        "-c:v", "libx264", "-t", str(seconds), "-pix_fmt", "yuv420p",
        "-vf", vf,
        str(dest),
    ]
    subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return dest


def list_scheduled_posts(api_key: str, org_id: str, channel_id: str) -> list[dict]:
    query = """
    query Scheduled($orgId: OrganizationId!, $channelId: ChannelId!) {
      posts(first: 50, input: {
        organizationId: $orgId
        filter: { status: [scheduled], channelIds: [$channelId] }
      }) {
        edges { node { id text dueAt status } }
      }
    }
    """
    data = gql(api_key, query, {"orgId": org_id, "channelId": channel_id})
    return [edge["node"] for edge in data["data"]["posts"]["edges"]]


def delete_post(api_key: str, post_id: str) -> None:
    mutation = """
    mutation DeletePost($input: DeletePostInput!) {
      deletePost(input: $input) {
        ... on DeletePostSuccess { id }
        ... on MutationError { message }
      }
    }
    """
    data = gql(api_key, mutation, {"input": {"id": post_id}})
    result = data["data"]["deletePost"]
    if result.get("message"):
        raise RuntimeError(result["message"])


def edit_post_text(
    api_key: str,
    post_id: str,
    text: str,
    cfg: dict,
    *,
    video_url: str | None = None,
) -> None:
    mutation = """
    mutation EditPost($input: EditPostInput!) {
      editPost(input: $input) {
        ... on PostActionSuccess { post { id text } }
        ... on MutationError { message }
      }
    }
    """
    buf = {**cfg.get("buffer", {}), "instagram_type": "reel"}
    payload: dict = {
        "id": post_id,
        "text": text,
        "schedulingType": "automatic",
        "metadata": post_metadata("instagram", {"buffer": buf}),
    }
    if video_url:
        payload["assets"] = [{"video": {"url": video_url}}]
    data = gql(api_key, mutation, {"input": payload})
    result = data["data"]["editPost"]
    if result.get("message"):
        raise RuntimeError(result["message"])


def refresh_scheduled_captions(api_key: str, out_dir: Path, data: dict, cfg: dict) -> int:
    manifest = out_dir / "buffer-scheduled.json"
    if not manifest.exists():
        raise SystemExit(f"No {manifest} — nothing to update.")
    rows = json.loads(manifest.read_text(encoding="utf-8"))
    catalog = {m["id"]: m for m in data["memes"]}
    videos = load_video_cache(out_dir)
    updated = 0
    for row in rows:
        meme_id = row.get("id")
        post_id = (row.get("post") or {}).get("id")
        if not meme_id or not post_id or meme_id not in catalog:
            continue
        text = post_text(catalog[meme_id], data)
        video_url = videos.get(meme_id)
        edit_post_text(api_key, post_id, text, cfg, video_url=video_url)
        row["post"]["text"] = text
        print(f"  updated {meme_id} → {text}")
        updated += 1
    manifest.write_text(json.dumps(rows, indent=2), encoding="utf-8")
    return updated


def delete_all_scheduled(api_key: str, cfg: dict, channel_id: str) -> int:
    org_id = cfg.get("buffer", {}).get("organization_id")
    posts = list_scheduled_posts(api_key, org_id, channel_id)
    for post in posts:
        delete_post(api_key, post["id"])
        preview = (post.get("text") or "")[:40].replace("\n", " ")
        print(f"  deleted {post['id']}  {preview}")
    return len(posts)


def video_url_for(
    meme: dict,
    out_dir: Path,
    cfg: dict,
    cache: dict[str, str],
    *,
    force: bool = False,
) -> str:
    meme_id = meme["id"]
    if not force and meme_id in cache:
        return cache[meme_id]
    local = local_image_path(out_dir, meme_id)
    if not local:
        raise RuntimeError(f"No local image for {meme_id}")
    mp4 = jpg_to_reel_mp4(local, out_dir / "reels", cfg, force=force)
    url = upload_public(mp4, imgur_client_id(cfg))
    cache[meme_id] = url
    return url


def image_url_for(
    meme: dict,
    out_dir: Path,
    cfg: dict,
    client: ThrottleClient | None,
    cache: dict[str, str],
    provider: Provider,
) -> str:
    meme_id = meme["id"]
    if meme_id in cache:
        return cache[meme_id]

    local = local_image_path(out_dir, meme_id)
    if local:
        url = upload_public(local, imgur_client_id(cfg))
        cache[meme_id] = url
        return url

    if client is not None:
        url, _ = create_meme_url(client, cfg, meme["template"], meme["text"], provider)
    else:
        url = memegen_url(meme, cfg)
    cache[meme_id] = url
    return url


def resolve_image_url(
    meme: dict, cfg: dict, client: ThrottleClient | None, provider: Provider
) -> str:
    if client is not None:
        url, _ = create_meme_url(client, cfg, meme["template"], meme["text"], provider)
        return url
    return memegen_url(meme, cfg)


def pick_memes(
    catalog: list[dict],
    out_dir: Path,
    count: int,
    ids: list[str] | None,
    require_local: bool,
) -> list[dict]:
    if ids:
        by_id = {m["id"]: m for m in catalog}
        picked: list[dict] = []
        for meme_id in ids:
            if meme_id not in by_id:
                raise SystemExit(f"Unknown meme id: {meme_id!r}")
            picked.append(by_id[meme_id])
        return picked[:count]

    available = [m for m in catalog if not require_local or output_exists(out_dir, m["id"])]
    if len(available) < count:
        raise SystemExit(
            f"Only {len(available)} memes available"
            + (" with local files" if require_local else "")
            + f"; need {count}. Run ./tools/reels/run --all --resume first."
        )

    # Round-robin personas (lucas → sarah → thomas → nadia), lowest index first.
    by_persona: dict[str, list[dict]] = {}
    for m in available:
        by_persona.setdefault(m["persona"], []).append(m)
    for pool in by_persona.values():
        pool.sort(key=lambda m: m["id"])

    order = ["lucas", "sarah", "thomas", "nadia"]
    picked: list[dict] = []
    idx = 0
    while len(picked) < count:
        persona = order[idx % len(order)]
        pool = by_persona.get(persona, [])
        if pool:
            picked.append(pool.pop(0))
        idx += 1
        if idx > count * 4 and len(picked) < count:
            picked.extend(m for m in available if m not in picked)
            break
    return picked[:count]


def post_metadata(service: str, cfg: dict) -> dict | None:
    service = (service or "").lower()
    buf = cfg.get("buffer", {})
    if service == "instagram":
        return {
            "instagram": {
                "type": buf.get("instagram_type", "post"),
                "shouldShareToFeed": buf.get("instagram_share_to_feed", True),
            }
        }
    return None


def create_post(
    api_key: str,
    channel_id: str,
    service: str,
    text: str,
    media_url: str,
    due_at: datetime,
    cfg: dict,
    dry_run: bool,
    *,
    reel: bool = False,
) -> dict | None:
    due_iso = due_at.strftime("%Y-%m-%dT%H:%M:%S.000Z")
    mutation = """
    mutation SchedulePost($input: CreatePostInput!) {
      createPost(input: $input) {
        ... on PostActionSuccess {
          post { id text dueAt status }
        }
        ... on MutationError {
          message
        }
      }
    }
    """
    if reel:
        assets = [{"video": {"url": media_url}}]
        meta_cfg = {**cfg.get("buffer", {}), "instagram_type": "reel"}
        meta = post_metadata(service, {"buffer": meta_cfg})
    else:
        assets = [{"image": {"url": media_url}}]
        meta = post_metadata(service, cfg)

    payload: dict = {
        "text": text,
        "channelId": channel_id,
        "schedulingType": "automatic",
        "mode": "customScheduled",
        "dueAt": due_iso,
        "assets": assets,
    }
    if meta:
        payload["metadata"] = meta

    variables = {"input": payload}

    if dry_run:
        return {"dryRun": True, "dueAt": due_iso, "text": text, "media": media_url, "metadata": meta, "reel": reel}

    data = gql(api_key, mutation, variables)
    result = data["data"]["createPost"]
    if result.get("message"):
        raise RuntimeError(result["message"])
    return result["post"]


def main() -> None:
    parser = argparse.ArgumentParser(description="Schedule memes to Buffer")
    parser.add_argument("--count", type=int, default=10)
    parser.add_argument("--id", action="append", dest="ids", help="Specific meme id(s)")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT)
    parser.add_argument("--tz", default="Europe/Paris")
    parser.add_argument("--start-hour", type=int, default=8, help="First slot hour (local)")
    parser.add_argument("--end-hour", type=int, default=21, help="Last slot hour (local)")
    parser.add_argument(
        "--day-offset",
        type=int,
        default=0,
        help="Schedule N days from today (1 = tomorrow)",
    )
    parser.add_argument(
        "--require-local",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Only schedule memes with files in output/ (default: on)",
    )
    parser.add_argument("--list-channels", action="store_true")
    parser.add_argument(
        "--resolve-urls",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Create memegen URLs via API so Buffer can fetch them (default: on)",
    )
    parser.add_argument(
        "--provider",
        choices=["auto", "imgflip", "memegen"],
        help="Meme API when resolving remote URLs (default from config)",
    )
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument(
        "--delete-scheduled",
        action="store_true",
        help="Delete all scheduled posts on the target channel, then exit",
    )
    parser.add_argument(
        "--reel",
        action="store_true",
        help="Schedule as Instagram Reels (converts JPG → MP4)",
    )
    parser.add_argument(
        "--regen-reels",
        action="store_true",
        help="Rebuild MP4s and re-upload (ignore video cache)",
    )
    parser.add_argument(
        "--refresh-captions",
        action="store_true",
        help="Update text on posts listed in output/buffer-scheduled.json",
    )
    args = parser.parse_args()

    cfg = load_config()
    provider = resolve_provider(cfg, args.provider)
    api_key = buffer_key(cfg)
    data = build_catalog()
    channels = list_channels(api_key, cfg.get("buffer", {}).get("organization_id"))

    if args.list_channels:
        for ch in channels:
            org = ch.get("organizationName", "")
            prefix = f"{org} · " if org else ""
            print(f"{ch['id']}  {prefix}{ch['name']}  ({ch['service']})")
        return

    channel = pick_channel(channels, cfg)

    if args.refresh_captions:
        n = refresh_scheduled_captions(api_key, args.out, data, cfg)
        print(f"Updated {n} scheduled post(s)")
        return

    if args.delete_scheduled:
        n = delete_all_scheduled(api_key, cfg, channel["id"])
        print(f"Deleted {n} scheduled post(s) on {channel['name']}\n")
        if not args.reel and not args.ids:
            return

    memes = pick_memes(data["memes"], args.out, args.count, args.ids, args.require_local)
    slots = schedule_times(
        len(memes), args.tz, args.start_hour, args.end_hour, day_offset=args.day_offset
    )
    client = ThrottleClient(cfg) if args.resolve_urls and not args.dry_run and not args.reel else None
    upload_cache = load_upload_cache(args.out)
    video_cache = {} if args.regen_reels else load_video_cache(args.out)

    kind = "Reels" if args.reel else "posts"
    print(f"Channel: {channel['name']} ({channel['service']})")
    print(f"Scheduling {len(memes)} {kind} ({args.tz}, {args.start_hour}:00–{args.end_hour}:00)")

    scheduled: list[dict] = []
    for meme, due in zip(memes, slots):
        text = post_text(meme, data)
        if args.reel:
            print(f"  reel {meme['id']}…", end=" ", flush=True)
            media_url = video_url_for(
                meme, args.out, cfg, video_cache, force=args.regen_reels
            )
            save_video_cache(args.out, video_cache)
            print("uploaded")
        else:
            local = local_image_path(args.out, meme["id"])
            if local:
                print(f"  upload {local.name}…", end=" ", flush=True)
            media_url = image_url_for(meme, args.out, cfg, client, upload_cache, provider)
            if local:
                print("done")
            save_upload_cache(args.out, upload_cache)
        local_time = due.astimezone(ZoneInfo(args.tz)).strftime("%H:%M")
        print(f"\n{meme['id']} @ {local_time} ({args.tz})")
        try:
            post = create_post(
                api_key,
                channel["id"],
                channel.get("service", ""),
                text,
                media_url,
                due,
                cfg,
                args.dry_run,
                reel=args.reel,
            )
        except RuntimeError as err:
            if args.reel and "Video could not be read" in str(err):
                time.sleep(5)
                try:
                    post = create_post(
                        api_key, channel["id"], channel.get("service", ""),
                        text, media_url, due, cfg, args.dry_run, reel=True,
                    )
                except RuntimeError as err2:
                    print(f"  FAIL: {err2}")
                    continue
            else:
                print(f"  FAIL: {err}")
                continue
        scheduled.append({"id": meme["id"], "post": post, "reel": args.reel})
        if post and not args.dry_run:
            print(f"  OK Buffer {post['id']} → {post.get('dueAt', due.isoformat())}")

    manifest = args.out / "buffer-scheduled.json"
    if not args.dry_run and scheduled:
        manifest.write_text(json.dumps(scheduled, indent=2), encoding="utf-8")
        print(f"\nWrote {manifest}")

    if len(scheduled) < len(memes):
        raise SystemExit(1)


if __name__ == "__main__":
    main()
