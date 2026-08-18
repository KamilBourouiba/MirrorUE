#!/usr/bin/env python3
import glob, re, os

gtag_idle_block = """  <!-- Google tag (gtag.js) — loaded on idle for optimal FCP/LCP -->
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

non_blocking_font_block = """  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link rel="preload" as="style" href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Space+Grotesk:wght@500;600;700&display=swap" />
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Space+Grotesk:wght@500;600;700&display=swap" media="print" onload="this.media='all'" />
  <noscript><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Space+Grotesk:wght@500;600;700&display=swap" /></noscript>
  <link rel="stylesheet" href="/styles.min.css?v=perf3" />"""

for fpath in glob.glob('docs/*.html'):
    with open(fpath, 'r', encoding='utf-8') as f:
        content = f.read()

    # 1. Replace old synchronous Google Tag with idle version
    old_gtag_regex = r'<!--\s*Google tag\s*\(gtag\.js\)[\s\S]*?gtag\(\'config\',\s*\'AW-18393322142\'\);\s*</script>'
    if re.search(old_gtag_regex, content):
        content = re.sub(old_gtag_regex, gtag_idle_block, content, count=1)
    elif '<head>' in content and 'AW-18393322142' not in content:
        content = content.replace('<head>', '<head>\n' + gtag_idle_block)

    # 2. Replace synchronous fonts & styles.css with non-blocking fonts and styles.min.css
    old_fonts_regex = r'<link\s+rel=[\"\']preconnect[\"\']\s+href=[\"\']https://fonts\.googleapis\.com[\"\']\s*/>[\s\S]*?<link\s+rel=[\"\']stylesheet[\"\']\s+href=[\"\']/styles[\s\S]*?/>'
    if re.search(old_fonts_regex, content):
        content = re.sub(old_fonts_regex, non_blocking_font_block, content, count=1)

    # 3. Add defer to conversion.js if present
    content = content.replace('<script src="/conversion.js"></script>', '<script defer src="/conversion.js"></script>')

    # 4. Fix heading order in footers (replace <h4>...</h4> with <p class="footer-heading">)
    footer_h4_pattern = r'<h4>(.*?)</h4>'
    def replace_h4(match):
        title = match.group(1)
        return f'<p class="footer-heading" style="color: #0f172a; font-family: var(--font); font-size: 0.85rem; font-weight: 700; text-transform: uppercase; letter-spacing: 0.05em; margin: 0 0 0.75rem 0;">{title}</p>'
    content = re.sub(footer_h4_pattern, replace_h4, content)

    with open(fpath, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f'Processed & Optimized: {fpath}')

# Now replicate to all subdirectories (including fr/ and de/)
for fpath in glob.glob('docs/*.html'):
    base = os.path.splitext(os.path.basename(fpath))[0]
    if base not in ('index', '404'):
        subdir = os.path.join('docs', base)
        os.makedirs(subdir, exist_ok=True)
        with open(fpath, 'r', encoding='utf-8') as f:
            c = f.read()
        with open(os.path.join(subdir, 'index.html'), 'w', encoding='utf-8') as f:
            f.write(c)

# Also optimize fr and de index files
for fpath in ['docs/fr/recopie-iphone-mac/index.html', 'docs/de/iphone-mirroring-eu/index.html']:
    if os.path.exists(fpath):
        with open(fpath, 'r', encoding='utf-8') as f:
            c = f.read()
        if 'Google tag (gtag.js) — loaded on idle' not in c and '<head>' in c:
            c = c.replace('<head>', '<head>\n' + gtag_idle_block)
        c = re.sub(r'<h4>(.*?)</h4>', replace_h4, c)
        with open(fpath, 'w', encoding='utf-8') as f:
            f.write(c)
        print(f'Optimized localized page: {fpath}')

print('All pages successfully optimized with full metadata, non-blocking assets, and clean heading hierarchy!')
