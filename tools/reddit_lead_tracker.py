#!/usr/bin/env python3
"""
MirrorUE — Reddit Lead Finder & Outreach Dashboard
Scrapes Reddit for users looking for iPhone mirroring solutions, alternatives in the EU,
low-latency screen mirroring, or keyboard control, and provides a sleek dashboard to track replies.
"""

import os
import sys
import json
import time
import urllib.request
import urllib.parse
from http.server import HTTPServer, BaseHTTPRequestHandler
import threading
from datetime import datetime

PORT = 5050
SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
WORKSPACE_ROOT = os.path.dirname(SCRIPT_DIR) if os.path.basename(SCRIPT_DIR) == "tools" else SCRIPT_DIR
DB_FILE = os.path.join(WORKSPACE_ROOT, "reddit_leads.json")

DEFAULT_QUERIES = [
    "iphone mirror mac",
    "mirror iphone to mac",
    "iphone mirroring europe",
    "iphone mirroring eu",
    "iphone mirroring alternative",
    "control iphone from mac",
    "type on iphone mac keyboard",
    "quicktime iphone mirror lag",
    "scrcpy ios",
    "stream iphone to mac 120hz"
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

TEMPLATES = [
    {
        "id": "eu_alt",
        "title": "🇪🇺 Alternative to Apple Mirroring in EU",
        "text": "If you're in the EU (where Apple blocked iPhone Mirroring due to the DMA), I built an open-source tool called MirrorUE (https://mirrorue.xyz) that mirrors and lets you control your iPhone from macOS via USB at up to 120 FPS with keyboard/mouse. 100% free under MIT license."
    },
    {
        "id": "keyboard_control",
        "title": "⌨️ Mouse & Keyboard Control",
        "text": "You can use MirrorUE (https://mirrorue.xyz) — it's a native macOS app that streams your iPhone at 120 fps and translates your Mac's physical keyboard (AZERTY, QWERTY, etc.) and mouse clicks directly to the phone via USB. Free & open-source."
    },
    {
        "id": "zero_lag_120fps",
        "title": "⚡ 120 FPS / Low-Latency Fix",
        "text": "If QuickTime or AirPlay is too laggy for you, check out MirrorUE (https://mirrorue.xyz). It uses zero-copy Metal texture rendering directly from the CoreMediaIO feed to get sub-20ms latency and 120 FPS on ProMotion iPhones."
    },
    {
        "id": "general_help",
        "title": "📱 General Developer & QA",
        "text": "Hey! I made a free macOS app called MirrorUE (https://mirrorue.xyz) specifically for this. It gives you full click, drag, physical keyboard typing, and instant 120 fps screen recording without needing any companion apps on your iPhone."
    }
]

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

import xml.etree.ElementTree as ET
import re
import html

def clean_html(raw_html):
    if not raw_html:
        return ""
    # Unescape HTML entities
    text = html.unescape(raw_html)
    # Remove HTML tags
    clean = re.sub(r'<[^>]+>', ' ', text)
    # Normalize whitespace
    clean = re.sub(r'\s+', ' ', clean).strip()
    return clean

def scrape_reddit():
    db = load_db()
    headers = {
        "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36"
    }
    
    found_count = 0
    ns = {"atom": "http://www.w3.org/2005/Atom"}
    
    # 1. Global keyword searches via search.rss
    for query in DEFAULT_QUERIES:
        url = f"https://www.reddit.com/search.rss?q={urllib.parse.quote(query)}&sort=new&t=month"
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=12) as response:
                if response.status == 200:
                    xml_data = response.read()
                    root = ET.fromstring(xml_data)
                    for entry in root.findall("atom:entry", ns):
                        post_id_el = entry.find("atom:id", ns)
                        post_id = post_id_el.text if post_id_el is not None else None
                        if not post_id:
                            continue
                        
                        title_el = entry.find("atom:title", ns)
                        title = title_el.text if title_el is not None else ""
                        
                        link_el = entry.find("atom:link", ns)
                        permalink = link_el.attrib.get("href", "") if link_el is not None else ""
                        
                        author_el = entry.find("atom:author/atom:name", ns)
                        author = author_el.text.replace("/u/", "") if author_el is not None and author_el.text else "anonymous"
                        
                        category_el = entry.find("atom:category", ns)
                        subreddit = category_el.attrib.get("label", "").replace("r/", "") if category_el is not None else "mac"
                        
                        content_el = entry.find("atom:content", ns)
                        raw_content = content_el.text if content_el is not None else ""
                        selftext = clean_html(raw_content)
                        
                        updated_el = entry.find("atom:published", ns) or entry.find("atom:updated", ns)
                        time_str = updated_el.text if updated_el is not None else ""
                        try:
                            # Parse ISO timestamp
                            dt = datetime.fromisoformat(time_str.replace("Z", "+00:00"))
                            created_utc = int(dt.timestamp())
                        except Exception:
                            created_utc = int(time.time())
                        
                        if post_id not in db["leads"]:
                            db["leads"][post_id] = {
                                "id": post_id,
                                "title": title,
                                "selftext": (selftext[:280] + "...") if len(selftext) > 280 else selftext,
                                "subreddit": subreddit,
                                "author": author,
                                "permalink": permalink,
                                "score": 1,
                                "num_comments": 0,
                                "created_utc": created_utc,
                                "matched_query": query,
                                "status": "new",  # new | replied | ignored
                                "replied_at": None,
                                "notes": "",
                                "found_at": datetime.utcnow().isoformat()
                            }
                            found_count += 1
            time.sleep(1.0)
        except Exception as e:
            print(f"[Scraper] Error querying '{query}': {e}", file=sys.stderr)
            time.sleep(1.5)

    # 2. Targeted Subreddit Searches
    for sub in TARGET_SUBREDDITS:
        url = f"https://www.reddit.com/r/{sub}/search.rss?q=iphone+mirror&restrict_sr=1&sort=new"
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=12) as response:
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
                        
                        content_el = entry.find("atom:content", ns)
                        raw_content = content_el.text if content_el is not None else ""
                        selftext = clean_html(raw_content)
                        
                        updated_el = entry.find("atom:published", ns) or entry.find("atom:updated", ns)
                        time_str = updated_el.text if updated_el is not None else ""
                        try:
                            dt = datetime.fromisoformat(time_str.replace("Z", "+00:00"))
                            created_utc = int(dt.timestamp())
                        except Exception:
                            created_utc = int(time.time())
                        
                        db["leads"][post_id] = {
                            "id": post_id,
                            "title": title,
                            "selftext": (selftext[:280] + "...") if len(selftext) > 280 else selftext,
                            "subreddit": sub,
                            "author": author,
                            "permalink": permalink,
                            "score": 1,
                            "num_comments": 0,
                            "created_utc": created_utc,
                            "matched_query": f"r/{sub} search",
                            "status": "new",
                            "replied_at": None,
                            "notes": "",
                            "found_at": datetime.utcnow().isoformat()
                        }
                        found_count += 1
            time.sleep(1.0)
        except Exception as e:
            print(f"[Scraper] Subreddit '{sub}' error: {e}", file=sys.stderr)
            time.sleep(1.5)
            
    db["last_scraped_at"] = datetime.utcnow().isoformat()
    save_db(db)
    return found_count

HTML_DASHBOARD = """<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>MirrorUE — Reddit Lead Tracker</title>
  <link rel="preconnect" href="https://fonts.googleapis.com">
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
  <link href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Space+Grotesk:wght@500;600;700&display=swap" rel="stylesheet">
  <style>
    :root {
      --bg: #090b10;
      --surface: #121620;
      --surface-border: rgba(255, 255, 255, 0.08);
      --primary: #5b6cff;
      --primary-glow: rgba(91, 108, 255, 0.25);
      --accent: #00d2ff;
      --success: #10b981;
      --warning: #f59e0b;
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
    }
    .brand { display: flex; align-items: center; gap: 0.75rem; }
    .brand-icon { font-size: 1.8rem; }
    .brand h1 { font-size: 1.5rem; font-weight: 700; }
    .brand p { font-size: 0.85rem; color: var(--muted); font-family: 'JetBrains Mono', monospace; }
    
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
    .filters { display: flex; gap: 0.5rem; }
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
    
    .lead-list { display: flex; flex-direction: column; gap: 1rem; }
    .lead-card {
      background: var(--surface);
      border: 1px solid var(--surface-border);
      border-radius: 12px;
      padding: 1.25rem;
      transition: border-color 0.2s ease;
    }
    .lead-card:hover { border-color: rgba(91, 108, 255, 0.4); }
    .lead-card.replied { border-left: 4px solid var(--success); opacity: 0.8; }
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
      gap: 0.75rem;
      font-size: 0.8rem;
      color: var(--muted);
      margin-bottom: 0.75rem;
      font-family: 'JetBrains Mono', monospace;
    }
    .badge {
      background: rgba(91, 108, 255, 0.15);
      color: var(--accent);
      padding: 0.2rem 0.5rem;
      border-radius: 4px;
      font-size: 0.75rem;
    }
    .badge-sub { background: rgba(255, 255, 255, 0.08); color: var(--text); }
    
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
    .lead-actions { display: flex; gap: 0.5rem; }
    .btn-sm { padding: 0.4rem 0.75rem; font-size: 0.8rem; border-radius: 6px; }
    .btn-success { background: var(--success); }
    .btn-danger { background: rgba(239, 68, 68, 0.2); color: var(--danger); border: 1px solid var(--danger); }
    
    /* Templates Modal */
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
    .template-item {
      background: rgba(0, 0, 0, 0.3);
      border: 1px solid var(--surface-border);
      border-radius: 8px;
      padding: 1rem;
      margin-top: 0.75rem;
    }
    .template-item h4 { font-size: 0.95rem; margin-bottom: 0.35rem; color: var(--accent); }
    .template-item p { font-size: 0.85rem; color: #cbd5e1; margin-bottom: 0.5rem; font-family: 'JetBrains Mono', monospace; }
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div class="brand">
        <span class="brand-icon">📱</span>
        <div>
          <h1>MirrorUE Lead Finder</h1>
          <p>Reddit Outreach Tracker · https://mirrorue.xyz</p>
        </div>
      </div>
      <div>
        <button id="btn-scrape" class="btn" onclick="triggerScrape()">⚡ Scan Reddit Now</button>
      </div>
    </header>

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

    <div id="lead-list" class="lead-list">
      <!-- Leads rendered here -->
    </div>
  </div>

  <!-- Response Templates Modal -->
  <div id="template-modal" class="modal" hidden>
    <div class="modal-box">
      <div style="display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem;">
        <h3>📋 Copy Reply Template</h3>
        <button class="btn btn-secondary btn-sm" onclick="closeTemplates()">✕ Close</button>
      </div>
      <p style="font-size: 0.85rem; color: var(--muted); margin-bottom: 1rem;">Choose a response to copy to your clipboard, then paste it on Reddit:</p>
      <div id="template-container"></div>
    </div>
  </div>

  <script>
    let leadsData = {};
    let currentFilter = 'new';

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
        container.innerHTML = `<div style="text-align:center; padding: 3rem; color: var(--muted); background: var(--surface); border-radius: 12px;">No leads found for this filter. Click <strong>Scan Reddit Now</strong> to search for new posts!</div>`;
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
            <span>• ⬆ ${l.score}</span>
            <span>• 💬 ${l.num_comments} comments</span>
            <span class="badge">🔍 ${escapeHtml(l.matched_query)}</span>
          </div>
          ${l.selftext ? `<div class="lead-body">${escapeHtml(l.selftext)}</div>` : ''}
          <div class="lead-footer">
            <div class="lead-actions">
              <a href="${l.permalink}" target="_blank" class="btn btn-secondary btn-sm">Open on Reddit ↗</a>
              <button class="btn btn-secondary btn-sm" onclick="openTemplates('${l.id}')">📋 Reply Template</button>
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
      btn.innerText = 'Scanning Reddit...';
      btn.disabled = true;
      try {
        const res = await fetch('/api/scrape', { method: 'POST' });
        const data = await res.json();
        alert(`Scan completed! Found ${data.found} new leads.`);
        await loadData();
      } catch (err) {
        alert('Error during scrape: ' + err);
      } finally {
        btn.innerText = '⚡ Scan Reddit Now';
        btn.disabled = false;
      }
    }

    async function updateStatus(id, status) {
      await fetch('/api/leads/update', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id, status })
      });
      loadData();
    }

    const templates = """ + json.dumps(TEMPLATES) + """;

    function openTemplates(leadId) {
      const container = document.getElementById('template-container');
      container.innerHTML = '';
      templates.forEach(t => {
        const item = document.createElement('div');
        item.className = 'template-item';
        item.innerHTML = `
          <h4>${t.title}</h4>
          <p>${escapeHtml(t.text)}</p>
          <button class="btn btn-sm" onclick="copyTemplate('${leadId}', ${JSON.stringify(t.text)})">📋 Copy &amp; Open Reddit</button>
        `;
        container.appendChild(item);
      });
      document.getElementById('template-modal').hidden = false;
    }

    function closeTemplates() {
      document.getElementById('template-modal').hidden = true;
    }

    function copyTemplate(leadId, text) {
      navigator.clipboard.writeText(text).then(() => {
        const lead = leadsData[leadId];
        if (lead && lead.permalink) {
          window.open(lead.permalink, '_blank');
        }
        updateStatus(leadId, 'replied');
        closeTemplates();
      });
    }

    function escapeHtml(text) {
      if (!text) return '';
      return text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;").replace(/"/g, "&quot;");
    }

    loadData();
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
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        if self.path == "/api/scrape":
            found = scrape_reddit()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"success": True, "found": found}).encode("utf-8"))
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
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        return  # Suppress noisy HTTP logs in console

def main():
    print("=" * 60)
    print("  📱 MirrorUE — Reddit Lead Finder & Outreach Dashboard")
    print(f"  🌐 Dashboard URL: http://localhost:{PORT}")
    print("=" * 60)
    
    # Run initial scrape in background thread on startup
    threading.Thread(target=scrape_reddit, daemon=True).start()
    
    server = HTTPServer(("127.0.0.1", PORT), DashboardHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping dashboard...")

if __name__ == "__main__":
    main()
