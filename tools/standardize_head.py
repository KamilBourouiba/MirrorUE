#!/usr/bin/env python3
import glob, re, os

gtag_block = """  <!-- Google tag (gtag.js) — loaded on idle for optimal FCP/LCP -->
  <script>
    window.dataLayer = window.dataLayer || [];
    function gtag(){dataLayer.push(arguments);}
    gtag('js', new Date());
    gtag('config', 'AW-18393322142');

    function loadGtagScript() {
      if (document.getElementById('gtag-script')) return;
      var s = document.createElement('script');
      s.id = 'gtag-script';
      s.async = true;
      s.src = 'https://www.googletagmanager.com/gtag/js?id=AW-18393322142';
      document.head.appendChild(s);
    }
    if ('requestIdleCallback' in window) {
      requestIdleCallback(loadGtagScript, { timeout: 2500 });
    } else {
      window.addEventListener('load', function() { setTimeout(loadGtagScript, 1000); });
    }
  </script>

  <!-- Event snippet for Download conversion -->
  <script>
  function gtag_report_conversion(url) {
    var callback = function () {
      if (typeof(url) != 'undefined') {
        window.location = url;
      }
    };
    if (typeof gtag === 'function') {
      gtag('event', 'conversion', {
          'send_to': 'AW-18393322142/Ac_OCIq45eMcEJ6lz8JE',
          'event_callback': callback
      });
    }
    return false;
  }
  </script>"""

for fpath in glob.glob('docs/*.html'):
    if 'google20d78eaedc6b1cda' in fpath:
        continue
    with open(fpath, 'r', encoding='utf-8') as f:
        html = f.read()

    # Extract head content
    head_match = re.search(r'<head>([\s\S]*?)</head>', html)
    if not head_match:
        continue
    head_inner = head_match.group(1)

    # Extract components
    # 1. Clean existing gtag scripts from head_inner
    head_clean = re.sub(r'<!--\s*Google tag\s*\(gtag\.js\)[\s\S]*?</script>\s*<!-- Event snippet for Download conversion -->\s*<script>[\s\S]*?</script>', '', head_inner)
    head_clean = re.sub(r'<script\s+async\s+src=[\"\']https://www\.googletagmanager\.com/gtag/js\?id=AW-18393322142[\"\']></script>\s*<script>[\s\S]*?gtag\(\'config\',\s*\'AW-18393322142\'\);\s*</script>', '', head_clean)

    # 2. Extract <meta charset="utf-8" />
    head_clean = re.sub(r'<meta\s+charset=[\"\']utf-8[\"\']\s*/>', '', head_clean)

    # 3. Extract <title>...</title>
    title_match = re.search(r'<title>(.*?)</title>', head_clean)
    title_str = title_match.group(0) if title_match else ''
    head_clean = re.sub(r'<title>.*?</title>', '', head_clean)

    # 4. Extract <meta name="viewport" ... />
    viewport_match = re.search(r'<meta\s+name=[\"\']viewport[\"\'][^>]*>', head_clean)
    viewport_str = viewport_match.group(0) if viewport_match else '<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover" />'
    head_clean = re.sub(r'<meta\s+name=[\"\']viewport[\"\'][^>]*>', '', head_clean)

    # 5. Extract <meta name="description" ... />
    desc_match = re.search(r'<meta\s+name=[\"\']description[\"\'][^>]*>', head_clean)
    desc_str = desc_match.group(0) if desc_match else ''
    head_clean = re.sub(r'<meta\s+name=[\"\']description[\"\'][^>]*>', '', head_clean)

    # 6. Extract <meta name="author" ... />
    author_match = re.search(r'<meta\s+name=[\"\']author[\"\'][^>]*>', head_clean)
    author_str = author_match.group(0) if author_match else '<meta name="author" content="Kamil Bourouiba" />'
    head_clean = re.sub(r'<meta\s+name=[\"\']author[\"\'][^>]*>', '', head_clean)

    # 7. Extract <meta name="robots" ... />
    robots_match = re.search(r'<meta\s+name=[\"\']robots[\"\'][^>]*>', head_clean)
    robots_str = robots_match.group(0) if robots_match else '<meta name="robots" content="index, follow, max-image-preview:large, max-snippet:-1, max-video-preview:-1" />'
    head_clean = re.sub(r'<meta\s+name=[\"\']robots[\"\'][^>]*>', '', head_clean)

    # Clean leftover whitespace
    head_clean = head_clean.strip()

    # Build standardized head
    new_head = f"""<head>
  <meta charset="utf-8" />
  {viewport_str}

  {title_str}
  {desc_str}
  {author_str}
  {robots_str}

  {head_clean}

{gtag_block}
</head>"""

    # Clean up double blank lines
    new_head = re.sub(r'\n{3,}', '\n\n', new_head)

    # Replace in html
    html = html[:head_match.start()] + new_head + html[head_match.end():]

    # Ensure footer has no <h4> elements
    html = re.sub(r'<h4>(.*?)</h4>', r'<p class="footer-heading" style="color: #0f172a; font-family: var(--font); font-size: 0.85rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em; margin: 0 0 0.75rem 0;">\1</p>', html)

    with open(fpath, 'w', encoding='utf-8') as f:
        f.write(html)
    print(f'Standardized Head for: {fpath}')

# Now mirror to subdirectories
for fpath in glob.glob('docs/*.html'):
    base = os.path.splitext(os.path.basename(fpath))[0]
    if base not in ('index', '404', 'google20d78eaedc6b1cda'):
        subdir = os.path.join('docs', base)
        os.makedirs(subdir, exist_ok=True)
        with open(fpath, 'r', encoding='utf-8') as f:
            c = f.read()
        with open(os.path.join(subdir, 'index.html'), 'w', encoding='utf-8') as f:
            f.write(c)

# Also update FR and DE index.html
for fpath in ['docs/fr/recopie-iphone-mac/index.html', 'docs/de/iphone-mirroring-eu/index.html']:
    if os.path.exists(fpath):
        with open(fpath, 'r', encoding='utf-8') as f:
            c = f.read()
        c = re.sub(r'<h4>(.*?)</h4>', r'<p class="footer-heading" style="color: #0f172a; font-family: var(--font); font-size: 0.85rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em; margin: 0 0 0.75rem 0;">\1</p>', c)
        with open(fpath, 'w', encoding='utf-8') as f:
            f.write(c)
        print(f'Mirrored: {fpath}')

print('All pages standardized with <meta charset>, <title>, <meta description> in first 500 bytes!')
