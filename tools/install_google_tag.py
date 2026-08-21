#!/usr/bin/env python3
import glob, re, os

official_google_tag = """  <!-- Google tag (gtag.js) -->
  <script async src="https://www.googletagmanager.com/gtag/js?id=AW-18393322142"></script>
  <script>
    window.dataLayer = window.dataLayer || [];
    function gtag(){dataLayer.push(arguments);}
    gtag('js', new Date());

    gtag('config', 'AW-18393322142');
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

    # Clean previous gtag blocks
    html = re.sub(r'<!--\s*Google tag\s*\(gtag\.js\)[\s\S]*?</script>\s*<!-- Event snippet for Download conversion -->\s*<script>[\s\S]*?</script>', '', html)
    html = re.sub(r'<script\s+async\s+src=[\"\']https://www\.googletagmanager\.com/gtag/js\?id=AW-18393322142[\"\']></script>\s*<script>[\s\S]*?gtag\(\'config\',\s*\'AW-18393322142\'\);\s*</script>', '', html)

    # Insert official tag right before </head>
    if '</head>' in html:
        html = html.replace('</head>', official_google_tag + '\n</head>')

    # Clean double blank lines
    html = re.sub(r'\n{3,}', '\n\n', html)

    with open(fpath, 'w', encoding='utf-8') as f:
        f.write(html)
    print(f'Installed official Google tag on: {fpath}')

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

# Also update FR and DE index files
for fpath in ['docs/fr/recopie-iphone-mac/index.html', 'docs/de/iphone-mirroring-eu/index.html']:
    if os.path.exists(fpath):
        with open(fpath, 'r', encoding='utf-8') as f:
            c = f.read()
        c = re.sub(r'<!--\s*Google tag\s*\(gtag\.js\)[\s\S]*?</script>\s*<!-- Event snippet for Download conversion -->\s*<script>[\s\S]*?</script>', '', c)
        c = re.sub(r'<script\s+async\s+src=[\"\']https://www\.googletagmanager\.com/gtag/js\?id=AW-18393322142[\"\']></script>\s*<script>[\s\S]*?gtag\(\'config\',\s*\'AW-18393322142\'\);\s*</script>', '', c)
        if '</head>' in c:
            c = c.replace('</head>', official_google_tag + '\n</head>')
        with open(fpath, 'w', encoding='utf-8') as f:
            f.write(c)
        print(f'Mirrored to localized: {fpath}')

print('Official Google tag installed across all 34 HTML files!')
