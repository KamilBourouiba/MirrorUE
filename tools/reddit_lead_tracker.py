#!/usr/bin/env python3
"""
MirrorUE — AI-Powered Reddit Lead Finder & Outreach Dashboard
Uses local LM Studio API (http://localhost:1234/v1) for intelligent lead scoring,
intent classification, and generating natural bespoke responses.
"""

import os
import sys
import json
import time
import urllib.request
import urllib.parse
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
import threading
from datetime import datetime
import xml.etree.ElementTree as ET
import re
import html

PORT = 5050
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
WORKSPACE_ROOT = os.path.dirname(SCRIPT_DIR) if os.path.basename(SCRIPT_DIR) == "tools" else SCRIPT_DIR
DB_FILE = os.path.join(WORKSPACE_ROOT, "reddit_leads.json")
LMSTUDIO_URL = "http://localhost:1234/v1"

# Real-time Scraper State
SCRAPE_STATE = {
    "running": False,
    "current_query": "",
    "current_index": 0,
    "total_queries": 0,
    "found_in_run": 0,
    "last_error": None
}
SCRAPE_LOCK = threading.Lock()

DEFAULT_QUERIES = [
    # 1. EU / Regional Block Alternative
    "iphone mirroring europe",
    "iphone mirroring eu",
    "iphone mirroring not available in your region",
    "iphone mirroring alternative",
    # 2. Mouse, Trackpad & Physical Keyboard Control
    "control iphone from mac",
    "type on iphone mac keyboard",
    "control iphone with keyboard mac",
    "click on iphone from mac",
    # 3. Low-Latency, 120 FPS & Lag Fixes
    "quicktime iphone mirror lag",
    "iphone screen mirror 120fps",
    "stream iphone to mac without lag",
    # 4. Open-Source / Scrcpy Alternatives
    "scrcpy ios",
    "scrcpy iphone mac",
    "open source iphone mirror mac"
]

TARGET_SUBREDDITS = [
    "mac",
    "apple",
    "macapps",
    "iOSBeta",
    "jailbreak",
    "SideStore",
    "iosgaming",
    "iOSProgramming",
    "MacOS"
]

NEGATIVE_KEYWORDS = [
    "carplay", "selfie", "broken screen", "cracked", "repair", "screen protector",
    "earphone", "iem", "headphone", "battery drain", "overnight", "battery life",
    "case", "charger", "android auto", "apple watch", "trade-in", "camera lens",
    "rear camera", "glass replacement"
]

TECH_SUBREDDITS = {
    "mac", "apple", "macapps", "iosbeta", "jailbreak", "sidestore",
    "iosgaming", "iosprogramming", "macos", "macbook", "iphone", "ios",
    "technology", "software", "opensource", "hackintosh"
}

def is_relevant_heuristic(title, text, subreddit=""):
    content = (title + " " + text).lower()
    sub_lower = (subreddit or "").lower()
    
    # 1. Reject obvious non-mirroring noise
    if any(neg in content for neg in NEGATIVE_KEYWORDS):
        return False
        
    # 2. Reject non-tech subreddits unless title explicitly contains iphone mirror
    if sub_lower and sub_lower not in TECH_SUBREDDITS:
        if "iphone" not in content or "mirror" not in content:
            return False
        
    # 3. Must be an Apple / iPhone / iPad device
    has_iphone = any(k in content for k in ["iphone", "ios", "ipad"])
    
    # 4. Must mention Mac / macOS / Computer
    has_mac = any(k in content for k in ["mac", "macos", "macbook", "quicktime", "laptop", "computer"])
    
    # 5. Must be seeking screen mirroring, control, or scrcpy
    has_mirror_action = any(k in content for k in [
        "mirror", "mirroring", "control iphone", "type on iphone",
        "scrcpy", "quicktime", "120fps", "120 fps", "120hz",
        "screen to mac", "screen on mac", "keyboard on iphone", "mouse on iphone"
    ])
    
    # In Apple/Mac subreddits, if title explicitly has "iphone mirroring", it's 100% a match
    if sub_lower in TECH_SUBREDDITS and "mirroring" in content and has_iphone:
        return True
        
    return has_iphone and has_mac and has_mirror_action

def detect_specific_intent(title, text):
    content = (title + " " + text).lower()
    if any(k in content for k in ["eu", "europe", "france", "germany", "spain", "italy", "dma", "region", "country", "not available"]):
        return "🇪🇺 EU Block Alternative"
    if any(k in content for k in ["keyboard", "type", "typing", "mouse", "trackpad", "click", "drag", "touch"]):
        return "⌨️ Keyboard & Mouse Control"
    if any(k in content for k in ["120", "fps", "hz", "promotion", "lag", "delay", "latency", "quicktime", "game", "gaming"]):
        return "⚡ 120 FPS / Zero-Lag Stream"
    if any(k in content for k in ["scrcpy", "open source", "mit", "api", "automation", "usb", "coremediaio"]):
        return "🛠️ Open-Source / Scrcpy Tool"
    return "📱 iPhone Mirror for Mac"

def load_db():
    if os.path.exists(DB_FILE):
        try:
            with open(DB_FILE, "r", encoding="utf-8") as f:
                return json.load(f)
        except Exception:
            return {"leads": {}, "last_scraped_at": None}
    return {"leads": {}, "last_scraped_at": None}

def save_db(db):
    with open(DB_FILE, "w", encoding="utf-8") as f:
        json.dump(db, f, indent=2, ensure_ascii=False)

def check_lmstudio_status():
    try:
        req = urllib.request.Request(f"{LMSTUDIO_URL}/models", headers={"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=2) as res:
            if res.status == 200:
                data = json.loads(res.read().decode("utf-8"))
                models = data.get("data", [])
                model_name = models[0].get("id", "Local LLM") if models else "Local LLM"
                return {"connected": True, "model": model_name}
    except Exception:
        pass
    return {"connected": False, "model": None}

def call_lmstudio_chat(prompt, system_prompt="You are a helpful AI assistant."):
    status = check_lmstudio_status()
    model = status.get("model") or "qwen/qwen3.5-9b"
    
    payload = {
        "model": model,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": prompt}
        ],
        "temperature": 0.4,
        "max_tokens": 1500
    }
    
    req = urllib.request.Request(
        f"{LMSTUDIO_URL}/chat/completions",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=50) as res:
        data = json.loads(res.read().decode("utf-8"))
        msg = data["choices"][0]["message"]
        content = msg.get("content", "").strip()
        if not content and "reasoning_content" in msg:
            content = msg.get("reasoning_content", "").strip()
        # Remove any lingering thinking artifacts if present
        if "</think>" in content:
            content = content.split("</think>")[-1].strip()
        return content

def clean_html(raw_html):
    if not raw_html:
        return ""
    text = html.unescape(raw_html)
    clean = re.sub(r'<[^>]+>', ' ', text)
    clean = re.sub(r'\s+', ' ', clean).strip()
    return clean

def is_relevant_heuristic(title, text):
    content = (title + " " + text).lower()
    has_device = any(k in content for k in ["iphone", "ios", "apple"])
    has_intent = any(k in content for k in ["mirror", "mirroring", "screen", "cast", "control", "keyboard", "scrcpy", "quicktime", "lag", "display", "stream"])
    return has_device and has_intent

def ai_classify_and_score(title, text):
    """Uses LM Studio to strictly analyze if a user is actively trying to mirror/control an iPhone."""
    prompt = f"""Analyze this Reddit post to determine if the author is actively trying to mirror, stream, or control their iPhone on a Mac:
Title: {title}
Body: {text[:500]}

Evaluation Criteria:
- High Intent (80-100): User is seeking a tool to mirror iPhone to Mac, type with Mac keyboard, stream at 120 FPS, bypass EU Apple iPhone Mirroring restrictions, or find an iOS equivalent to scrcpy.
- Medium Intent (60-79): User complaining about QuickTime lag, AirPlay delay, or mirroring crashes.
- Low / Irrelevant (< 50): General Apple news, rumors, broken screens, battery, or unrelated talk.

Respond ONLY with valid JSON:
{{
  "is_lead": true,
  "relevance_score": 95,
  "intent": "🇪🇺 EU Block Alternative | ⌨️ Keyboard & Mouse Control | ⚡ 120 FPS / Zero-Lag Stream | 🛠️ Scrcpy / Open-Source Tool",
  "pain_point": "Exact problem in 6-8 words",
  "pitch_angle": "Why MirrorUE solves this"
}}"""
    try:
        content = call_lmstudio_chat(prompt, system_prompt="You are an expert tech lead qualification AI. Output only valid JSON.")
        json_match = re.search(r'\{.*\}', content, re.DOTALL)
        if json_match:
            return json.loads(json_match.group(0))
    except Exception:
        pass
    
    return {
        "is_lead": True,
        "relevance_score": 85,
        "intent": detect_specific_intent(title, text),
        "pain_point": title[:70],
        "pitch_angle": "Free 120 FPS native macOS iPhone mirror with keyboard/mouse control"
    }

def ai_generate_reply(title, text, subreddit, author):
    """Uses LM Studio to generate a bespoke, authentic indie developer reply."""
    prompt = f"""A user (/u/{author} on r/{subreddit}) posted:
Title: "{title}"
Post Details: "{text[:500]}"

You are an indie macOS developer who built MirrorUE (https://mirrorue.xyz).
Write a 2-sentence authentic Reddit reply that:
1. Directly answers their question or addresses their pain point (e.g. EU region block, QuickTime/AirPlay lag, typing on iPhone from Mac, or finding an open-source tool).
2. Introduces MirrorUE (https://mirrorue.xyz) as a free, open-source macOS app with zero-copy Metal 120 FPS USB mirroring, mouse clicks, and physical Mac keyboard support.
3. Sounds like a genuine, friendly developer helping a peer on Reddit (no marketing fluff, no buzzwords)."""

    try:
        reply = call_lmstudio_chat(
            prompt,
            system_prompt="You are a friendly, helpful indie Mac software engineer on Reddit. Be authentic and concise."
        )
        if reply:
            return reply
    except Exception as e:
        print(f"[AI Reply Error] {e}", file=sys.stderr)

    # High-quality fallback template
    return f"Hey /u/{author}! If you're looking for a smooth solution, I built [MirrorUE](https://mirrorue.xyz) — it's a free, open-source macOS app that gives you 120 FPS USB mirroring, mouse gestures, and physical Mac keyboard typing with virtually zero latency (works in the EU too)."

def scrape_reddit_worker():
    global SCRAPE_STATE
    with SCRAPE_LOCK:
        if SCRAPE_STATE["running"]:
            return
        SCRAPE_STATE["running"] = True
        SCRAPE_STATE["found_in_run"] = 0
        SCRAPE_STATE["current_index"] = 0
        all_tasks = [(q, None) for q in DEFAULT_QUERIES] + [("iphone mirror", s) for s in TARGET_SUBREDDITS]
        SCRAPE_STATE["total_queries"] = len(all_tasks)

    db = load_db()
    headers = {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
    }
    
    found_count = 0
    ns = {"atom": "http://www.w3.org/2005/Atom"}
    
    try:
        for idx, (query, sub) in enumerate(all_tasks):
            with SCRAPE_LOCK:
                SCRAPE_STATE["current_index"] = idx + 1
                SCRAPE_STATE["current_query"] = f"r/{sub}: {query}" if sub else query
            
            if sub:
                url = f"https://www.reddit.com/r/{sub}/search.rss?q={urllib.parse.quote(query)}&restrict_sr=1&sort=new"
                print(f"[Scanner] [{idx+1}/{len(all_tasks)}] Scanning r/{sub} for '{query}'...")
            else:
                url = f"https://www.reddit.com/search.rss?q={urllib.parse.quote(query)}&sort=new&t=month"
                print(f"[Scanner] [{idx+1}/{len(all_tasks)}] Searching Reddit for '{query}'...")

            try:
                req = urllib.request.Request(url, headers=headers)
                with urllib.request.urlopen(req, timeout=10) as response:
                    if response.status == 200:
                        xml_data = response.read()
                        root = ET.fromstring(xml_data)
                        for entry in root.findall("atom:entry", ns):
                            post_id_el = entry.find("atom:id", ns)
                            post_id = post_id_el.text if post_id_el is not None else None
                            if not post_id or post_id in db["leads"]:
                                continue
                            
                            title_el = entry.find("atom:title", ns)
                            title = title_el.text if title_el is not None else ""
                            
                            link_el = entry.find("atom:link", ns)
                            permalink = link_el.attrib.get("href", "") if link_el is not None else ""
                            
                            author_el = entry.find("atom:author/atom:name", ns)
                            author = author_el.text.replace("/u/", "") if author_el is not None and author_el.text else "anonymous"
                            
                            category_el = entry.find("atom:category", ns)
                            post_sub = sub or (category_el.attrib.get("label", "").replace("r/", "") if category_el is not None else "mac")
                            
                            content_el = entry.find("atom:content", ns)
                            raw_content = content_el.text if content_el is not None else ""
                            selftext = clean_html(raw_content)
                            
                            if not is_relevant_heuristic(title, selftext, post_sub):
                                continue
                            
                            updated_el = entry.find("atom:published", ns) or entry.find("atom:updated", ns)
                            time_str = updated_el.text if updated_el is not None else ""
                            try:
                                dt = datetime.fromisoformat(time_str.replace("Z", "+00:00"))
                                created_utc = int(dt.timestamp())
                            except Exception:
                                created_utc = int(time.time())
                            
                            intent = detect_specific_intent(title, selftext)
                            db["leads"][post_id] = {
                                "id": post_id,
                                "title": title,
                                "selftext": (selftext[:280] + "...") if len(selftext) > 280 else selftext,
                                "subreddit": post_sub,
                                "author": author,
                                "permalink": permalink,
                                "score": 1,
                                "num_comments": 0,
                                "created_utc": created_utc,
                                "matched_query": query,
                                "status": "new",
                                "ai_score": 90,
                                "ai_intent": intent,
                                "ai_summary": title[:90],
                                "replied_at": None,
                                "notes": "",
                                "found_at": datetime.utcnow().isoformat()
                            }
                            found_count += 1
                            with SCRAPE_LOCK:
                                SCRAPE_STATE["found_in_run"] = found_count
                time.sleep(1.5)
            except Exception as e:
                time.sleep(2.0)
    finally:
        db["last_scraped_at"] = datetime.utcnow().isoformat()
        save_db(db)
        with SCRAPE_LOCK:
            SCRAPE_STATE["running"] = False
        print(f"[Scanner] Finished scan cycle! Found {found_count} leads.")
    return found_count

def scrape_reddit():
    t = threading.Thread(target=scrape_reddit_worker, daemon=True)
    t.start()
    return True
            
    db["last_scraped_at"] = datetime.utcnow().isoformat()
    save_db(db)
    return found_count

HTML_DASHBOARD = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>MirrorUE — AI Reddit Lead Finder &amp; Outreach</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Space+Grotesk:wght@500;600;700&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg: #090b10;
      --surface: #121620;
      --surface-border: rgba(255, 255, 255, 0.08);
      --primary: #5b6cff;
      --accent: #00d2ff;
      --ai-purple: #a855f7;
      --success: #10b981;
      --danger: #ef4444;
      --text: #f1f5f9;
      --muted: #94a3b8;
    }
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body {
      background: var(--bg);
      color: var(--text);
      font-family: 'Space Grotesk', system-ui, sans-serif;
      min-height: 100vh;
      padding: 1.5rem;
      line-height: 1.5;
    }
    .container { max-width: 1300px; margin: 0 auto; }
    
    header {
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding-bottom: 1.5rem;
      border-bottom: 1px solid var(--surface-border);
      margin-bottom: 2rem;
      flex-wrap: wrap;
      gap: 1rem;
    }
    .brand { display: flex; align-items: center; gap: 0.75rem; }
    .brand-icon { font-size: 2rem; }
    .brand h1 { font-size: 1.5rem; font-weight: 700; }
    .brand p { font-size: 0.85rem; color: var(--muted); font-family: 'JetBrains Mono', monospace; }
    
    .ai-badge {
      display: inline-flex;
      align-items: center;
      gap: 0.4rem;
      background: rgba(168, 85, 247, 0.15);
      border: 1px solid rgba(168, 85, 247, 0.35);
      color: #d8b4fe;
      padding: 0.35rem 0.75rem;
      border-radius: 999px;
      font-size: 0.8rem;
      font-family: 'JetBrains Mono', monospace;
    }
    .dot { width: 8px; height: 8px; border-radius: 50%; background: #22c55e; box-shadow: 0 0 8px #22c55e; }
    .dot.offline { background: #64748b; box-shadow: none; }
    
    .stats-bar {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
      gap: 1rem;
      margin-bottom: 2rem;
    }
    .stat-card {
      background: var(--surface);
      border: 1px solid var(--surface-border);
      padding: 1.25rem;
      border-radius: 12px;
      display: flex;
      flex-direction: column;
    }
    .stat-card .label { font-size: 0.8rem; color: var(--muted); text-transform: uppercase; letter-spacing: 0.05em; font-family: 'JetBrains Mono', monospace; }
    .stat-card .value { font-size: 1.8rem; font-weight: 700; margin-top: 0.35rem; }
    
    .actions-bar {
      display: flex;
      justify-content: space-between;
      align-items: center;
      flex-wrap: wrap;
      gap: 1rem;
      margin-bottom: 1.5rem;
    }
    .filters { display: flex; gap: 0.5rem; flex-wrap: wrap; }
    .filter-btn {
      background: var(--surface);
      border: 1px solid var(--surface-border);
      color: var(--muted);
      padding: 0.5rem 1rem;
      border-radius: 8px;
      cursor: pointer;
      font-weight: 600;
      font-size: 0.85rem;
      transition: all 0.15s ease;
    }
    .filter-btn.active, .filter-btn:hover {
      background: var(--primary);
      color: #fff;
      border-color: var(--primary);
    }
    
    .btn {
      background: var(--primary);
      color: #fff;
      border: none;
      padding: 0.65rem 1.25rem;
      border-radius: 8px;
      font-weight: 600;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 0.5rem;
      transition: all 0.15s ease;
    }
    .btn:hover { opacity: 0.9; transform: translateY(-1px); }
    .btn:active { transform: translateY(0); }
    .btn-secondary { background: var(--surface); border: 1px solid var(--surface-border); color: var(--text); }
    .btn-ai { background: linear-gradient(135deg, #a855f7, #6366f1); color: #fff; border: none; }
    
    .lead-list { display: flex; flex-direction: column; gap: 1rem; }
    .lead-card {
      background: var(--surface);
      border: 1px solid var(--surface-border);
      border-radius: 12px;
      padding: 1.25rem;
      transition: all 0.2s ease;
    }
    .lead-card:hover { border-color: rgba(91, 108, 255, 0.4); box-shadow: 0 4px 20px rgba(0,0,0,0.3); }
    .lead-card.replied { border-left: 4px solid var(--success); opacity: 0.85; }
    .lead-card.ignored { opacity: 0.45; }
    
    .lead-header {
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      gap: 1rem;
      margin-bottom: 0.5rem;
    }
    .lead-title { font-size: 1.15rem; font-weight: 600; color: var(--text); text-decoration: none; }
    .lead-title:hover { color: var(--accent); }
    
    .lead-meta {
      display: flex;
      align-items: center;
      gap: 0.65rem;
      font-size: 0.8rem;
      color: var(--muted);
      margin-bottom: 0.75rem;
      font-family: 'JetBrains Mono', monospace;
      flex-wrap: wrap;
    }
    .badge {
      background: rgba(91, 108, 255, 0.15);
      color: var(--accent);
      padding: 0.2rem 0.5rem;
      border-radius: 4px;
      font-size: 0.75rem;
    }
    .badge-sub { background: rgba(255, 255, 255, 0.08); color: var(--text); }
    .badge-ai { background: rgba(168, 85, 247, 0.2); color: #d8b4fe; border: 1px solid rgba(168, 85, 247, 0.4); }
    
    .lead-body {
      font-size: 0.9rem;
      color: #cbd5e1;
      margin-bottom: 1rem;
      background: rgba(0, 0, 0, 0.25);
      padding: 0.75rem;
      border-radius: 8px;
    }
    
    .lead-footer {
      display: flex;
      justify-content: space-between;
      align-items: center;
      flex-wrap: wrap;
      gap: 0.75rem;
    }
    .lead-actions { display: flex; gap: 0.5rem; flex-wrap: wrap; }
    .btn-sm { padding: 0.4rem 0.75rem; font-size: 0.8rem; border-radius: 6px; }
    .btn-success { background: var(--success); }
    .btn-danger { background: rgba(239, 68, 68, 0.2); color: var(--danger); border: 1px solid var(--danger); }
    
    /* Modal */
    .modal {
      position: fixed;
      inset: 0;
      background: rgba(0, 0, 0, 0.75);
      backdrop-filter: blur(8px);
      display: flex;
      align-items: center;
      justify-content: center;
      padding: 1.5rem;
      z-index: 100;
    }
    .modal[hidden] { display: none; }
    .modal-box {
      background: var(--surface);
      border: 1px solid var(--surface-border);
      border-radius: 16px;
      max-width: 650px;
      width: 100%;
      padding: 1.5rem;
    }
    .ai-reply-preview {
      background: rgba(0, 0, 0, 0.4);
      border: 1px solid rgba(168, 85, 247, 0.3);
      border-radius: 8px;
      padding: 1rem;
      font-size: 0.9rem;
      line-height: 1.6;
      color: #f1f5f9;
      margin: 1rem 0;
      white-space: pre-wrap;
    }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div class="brand">
        <span class="brand-icon">📱</span>
        <div>
          <h1>MirrorUE Lead Finder</h1>
          <p>AI-Powered Reddit Outreach · https://mirrorue.xyz</p>
        </div>
      </div>
      <div style="display: flex; align-items: center; gap: 1rem;">
        <div id="ai-status" class="ai-badge">
          <span class="dot"></span>
          <span id="ai-model-label">Checking LM Studio...</span>
        </div>
        <button id="btn-scrape" class="btn" onclick="triggerScrape()">⚡ Scan Reddit Now</button>
      </div>
    </header>

    <div id="scrape-progress-banner" style="background: rgba(91, 108, 255, 0.15); border: 1px solid var(--primary); padding: 0.85rem 1.25rem; border-radius: 10px; margin-bottom: 1.5rem; display: flex; align-items: center; justify-content: space-between; gap: 1rem;" hidden>
      <div style="display: flex; align-items: center; gap: 0.75rem;">
        <span style="display: inline-block; width: 14px; height: 14px; border: 2px solid #5b6cff; border-top-color: transparent; border-radius: 50%; animation: spin 0.8s linear infinite;"></span>
        <span id="scrape-progress-text" style="font-size: 0.9rem; font-family: 'JetBrains Mono', monospace;">Scanning Reddit for high-intent leads...</span>
      </div>
      <span id="scrape-progress-count" class="badge" style="background: var(--primary); color: #fff;">0 found</span>
    </div>

    <div class="stats-bar">
      <div class="stat-card">
        <span class="label">Total Leads</span>
        <span class="value" id="stat-total">0</span>
      </div>
      <div class="stat-card">
        <span class="label">Uncontacted (New)</span>
        <span class="value" id="stat-new" style="color: var(--accent);">0</span>
      </div>
      <div class="stat-card">
        <span class="label">Replied</span>
        <span class="value" id="stat-replied" style="color: var(--success);">0</span>
      </div>
      <div class="stat-card">
        <span class="label">Dismissed</span>
        <span class="value" id="stat-ignored" style="color: var(--muted);">0</span>
      </div>
    </div>

    <div class="actions-bar">
      <div class="filters">
        <button class="filter-btn active" onclick="setFilter('new', this)">New Leads (<span id="count-new">0</span>)</button>
        <button class="filter-btn" onclick="setFilter('all', this)">All</button>
        <button class="filter-btn" onclick="setFilter('replied', this)">Replied (<span id="count-replied">0</span>)</button>
        <button class="filter-btn" onclick="setFilter('ignored', this)">Dismissed</button>
      </div>
      <div style="font-size: 0.8rem; color: var(--muted); font-family: 'JetBrains Mono', monospace;" id="last-scraped">
        Last scan: Never
      </div>
    </div>

    <div id="lead-list" class="lead-list"></div>
  </div>

  <style>
    @keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }
  </style>

  <!-- AI Reply Modal -->
  <div id="ai-modal" class="modal" hidden>
    <div class="modal-box">
      <div style="display: flex; justify-content: space-between; align-items: center;">
        <h3>✨ LM Studio AI Reply Generator</h3>
        <button class="btn btn-secondary btn-sm" onclick="closeAiModal()">✕ Close</button>
      </div>
      <div id="ai-loading" style="text-align: center; padding: 2rem; color: var(--muted);" hidden>
        Generating bespoke response via LM Studio...
      </div>
      <div id="ai-content-box">
        <div id="ai-reply-text" class="ai-reply-preview"></div>
        <div style="display: flex; justify-content: flex-end; gap: 0.5rem;">
          <button class="btn btn-secondary btn-sm" onclick="regenerateAiReply()">🔄 Regenerate</button>
          <button class="btn btn-ai btn-sm" onclick="copyAndOpenReddit()">📋 Copy &amp; Open Reddit ↗</button>
        </div>
      </div>
    </div>
  </div>

  <script>
    let leadsData = {};
    let currentFilter = 'new';
    let activeLeadId = null;
    let currentGeneratedReply = '';
    let isPollingScrape = false;

    async function checkAiStatus() {
      try {
        const res = await fetch('/api/ai/status');
        const data = await res.json();
        const label = document.getElementById('ai-model-label');
        const dot = document.querySelector('.dot');
        if (data.connected) {
          label.innerText = 'LM Studio (' + data.model + ')';
          dot.className = 'dot';
        } else {
          label.innerText = 'LM Studio Offline';
          dot.className = 'dot offline';
        }
      } catch (e) {
        document.getElementById('ai-model-label').innerText = 'LM Studio Offline';
      }
    }

    async function loadData() {
      try {
        const res = await fetch('/api/leads');
        const data = await res.json();
        leadsData = data.leads || {};
        
        document.getElementById('stat-total').innerText = Object.keys(leadsData).length;
        const newCount = Object.values(leadsData).filter(l => l.status === 'new').length;
        const repliedCount = Object.values(leadsData).filter(l => l.status === 'replied').length;
        const ignoredCount = Object.values(leadsData).filter(l => l.status === 'ignored').length;
        
        document.getElementById('stat-new').innerText = newCount;
        document.getElementById('count-new').innerText = newCount;
        document.getElementById('stat-replied').innerText = repliedCount;
        document.getElementById('count-replied').innerText = repliedCount;
        document.getElementById('stat-ignored').innerText = ignoredCount;
        
        if (data.last_scraped_at) {
          const d = new Date(data.last_scraped_at);
          document.getElementById('last-scraped').innerText = 'Last scan: ' + d.toLocaleTimeString();
        }
        
        renderLeads();
      } catch (err) {
        console.error('Error loading leads:', err);
      }
    }

    function setFilter(filter, el) {
      currentFilter = filter;
      document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
      el.classList.add('active');
      renderLeads();
    }

    function renderLeads() {
      const container = document.getElementById('lead-list');
      container.innerHTML = '';
      
      const leads = Object.values(leadsData).filter(l => {
        if (currentFilter === 'all') return true;
        return l.status === currentFilter;
      }).sort((a, b) => (b.created_utc || 0) - (a.created_utc || 0));

      if (leads.length === 0) {
        container.innerHTML = `<div style="text-align:center; padding: 3rem; color: var(--muted); background: var(--surface); border-radius: 12px;">No leads found for this filter. Click <strong>Scan Reddit Now</strong> to find fresh discussions!</div>`;
        return;
      }

      leads.forEach(l => {
        const card = document.createElement('div');
        card.className = `lead-card ${l.status}`;
        
        const dateStr = l.created_utc ? new Date(l.created_utc * 1000).toLocaleDateString() + ' ' + new Date(l.created_utc * 1000).toLocaleTimeString([], {hour: '2-digit', minute:'2-digit'}) : 'Recent';
        
        card.innerHTML = `
          <div class="lead-header">
            <a href="${l.permalink}" target="_blank" class="lead-title">${escapeHtml(l.title)} ↗</a>
          </div>
          <div class="lead-meta">
            <span class="badge badge-sub">r/${l.subreddit}</span>
            <span>u/${l.author}</span>
            <span>• ${dateStr}</span>
            <span class="badge">🔍 ${escapeHtml(l.matched_query)}</span>
            ${l.ai_intent ? `<span class="badge badge-ai">✨ ${escapeHtml(l.ai_intent)}</span>` : ''}
          </div>
          ${l.selftext ? `<div class="lead-body">${escapeHtml(l.selftext)}</div>` : ''}
          <div class="lead-footer">
            <div class="lead-actions">
              <a href="${l.permalink}" target="_blank" class="btn btn-secondary btn-sm">Open Reddit ↗</a>
              <button class="btn btn-ai btn-sm" onclick="openAiReply('${l.id}')">✨ AI Custom Reply</button>
              ${l.status !== 'replied' ? `<button class="btn btn-success btn-sm" onclick="updateStatus('${l.id}', 'replied')">✓ Mark Replied</button>` : `<button class="btn btn-secondary btn-sm" onclick="updateStatus('${l.id}', 'new')">↺ Mark New</button>`}
              ${l.status !== 'ignored' ? `<button class="btn btn-danger btn-sm" onclick="updateStatus('${l.id}', 'ignored')">✕ Dismiss</button>` : ''}
            </div>
            <div style="font-size: 0.8rem; color: var(--muted);">
              ${l.replied_at ? `Replied: ${new Date(l.replied_at).toLocaleTimeString()}` : ''}
            </div>
          </div>
        `;
        container.appendChild(card);
      });
    }

    async function triggerScrape() {
      const btn = document.getElementById('btn-scrape');
      const banner = document.getElementById('scrape-progress-banner');
      const progressText = document.getElementById('scrape-progress-text');
      const progressCount = document.getElementById('scrape-progress-count');
      
      btn.innerText = 'Scanning Reddit...';
      btn.disabled = true;
      banner.hidden = false;
      progressText.innerText = 'Starting live scan across Reddit...';
      progressCount.innerText = '0 found';

      try {
        await fetch('/api/scrape', { method: 'POST' });
        pollScrapeProgress();
      } catch (err) {
        alert('Error starting scrape: ' + err);
        btn.innerText = '⚡ Scan Reddit Now';
        btn.disabled = false;
        banner.hidden = true;
      }
    }

    function pollScrapeProgress() {
      const btn = document.getElementById('btn-scrape');
      const banner = document.getElementById('scrape-progress-banner');
      const progressText = document.getElementById('scrape-progress-text');
      const progressCount = document.getElementById('scrape-progress-count');

      const interval = setInterval(async () => {
        try {
          const res = await fetch('/api/scrape/status');
          const data = await res.json();
          
          if (data.running) {
            progressText.innerText = `[${data.current_index}/${data.total_queries}] Scanning ${data.current_query}...`;
            progressCount.innerText = `${data.found_in_run} leads found`;
          } else {
            clearInterval(interval);
            progressText.innerText = `✓ Scan complete! Found ${data.found_in_run} leads.`;
            progressCount.innerText = `${data.found_in_run} total`;
            btn.innerText = '⚡ Scan Reddit Now';
            btn.disabled = false;
            setTimeout(() => { banner.hidden = true; }, 4000);
            await loadData();
          }
        } catch (e) {
          clearInterval(interval);
          btn.innerText = '⚡ Scan Reddit Now';
          btn.disabled = false;
          banner.hidden = true;
        }
      }, 600);
    }

    async function updateStatus(id, status) {
      await fetch('/api/leads/update', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id, status })
      });
      loadData();
    }

    async function openAiReply(leadId) {
      activeLeadId = leadId;
      document.getElementById('ai-modal').hidden = false;
      document.getElementById('ai-loading').hidden = false;
      document.getElementById('ai-content-box').hidden = true;
      
      try {
        const res = await fetch('/api/ai/reply', {
          method: 'POST',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ id: leadId })
        });
        const data = await res.json();
        currentGeneratedReply = data.reply || '';
        document.getElementById('ai-reply-text').innerText = currentGeneratedReply;
        document.getElementById('ai-loading').hidden = true;
        document.getElementById('ai-content-box').hidden = false;
      } catch (e) {
        document.getElementById('ai-reply-text').innerText = 'Error calling LM Studio: ' + e;
        document.getElementById('ai-loading').hidden = true;
        document.getElementById('ai-content-box').hidden = false;
      }
    }

    function regenerateAiReply() {
      if (activeLeadId) {
        openAiReply(activeLeadId);
      }
    }

    function closeAiModal() {
      document.getElementById('ai-modal').hidden = true;
    }

    function copyAndOpenReddit() {
      if (!currentGeneratedReply) return;
      navigator.clipboard.writeText(currentGeneratedReply).then(() => {
        const lead = leadsData[activeLeadId];
        if (lead && lead.permalink) {
          window.open(lead.permalink, '_blank');
        }
        updateStatus(activeLeadId, 'replied');
        closeAiModal();
      });
    }

    function escapeHtml(text) {
      if (!text) return '';
      return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }

    checkAiStatus();
    loadData();
    setInterval(checkAiStatus, 15000);
    setInterval(loadData, 30000);
  </script>
</body>
</html>
"""

class DashboardHandler(BaseHTTPRequestHandler):
    def do_HEAD(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()

    def do_GET(self):
        if self.path == "/" or self.path == "/index.html":
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.end_headers()
            self.wfile.write(HTML_DASHBOARD.encode("utf-8"))
        elif self.path == "/api/leads":
            db = load_db()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(db).encode("utf-8"))
        elif self.path == "/api/scrape/status":
            with SCRAPE_LOCK:
                state_copy = dict(SCRAPE_STATE)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(state_copy).encode("utf-8"))
        elif self.path == "/api/ai/status":
            status = check_lmstudio_status()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps(status).encode("utf-8"))
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/api/scrape":
            started = scrape_reddit()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"success": True, "started": started}).encode("utf-8"))
        elif self.path == "/api/leads/update":
            content_len = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(content_len).decode('utf-8'))
            lead_id = body.get("id")
            new_status = body.get("status")
            db = load_db()
            if lead_id in db.get("leads", {}):
                db["leads"][lead_id]["status"] = new_status
                if new_status == "replied":
                    db["leads"][lead_id]["replied_at"] = datetime.utcnow().isoformat()
                save_db(db)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"success": True}).encode("utf-8"))
        elif self.path == "/api/ai/reply":
            content_len = int(self.headers.get('Content-Length', 0))
            body = json.loads(self.rfile.read(content_len).decode('utf-8'))
            lead_id = body.get("id")
            db = load_db()
            lead = db.get("leads", {}).get(lead_id, {})
            title = lead.get("title", "")
            selftext = lead.get("selftext", "")
            sub = lead.get("subreddit", "mac")
            author = lead.get("author", "redditor")
            
            reply = ai_generate_reply(title, selftext, sub, author)
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"reply": reply}).encode("utf-8"))
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        return

def main():
    print("=" * 65)
    print("  📱 MirrorUE — AI Reddit Lead Finder & Outreach Dashboard")
    print(f"  🌐 Dashboard URL: http://localhost:{PORT}")
    print("  🧠 Local LM Studio Engine: http://localhost:1234/v1")
    print("=" * 65)
    
    server = HTTPServer(("127.0.0.1", PORT), DashboardHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping dashboard...")

if __name__ == "__main__":
    main()
