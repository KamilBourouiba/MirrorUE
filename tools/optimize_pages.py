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

font_block = """  <meta name="theme-color" content="#0a0c12" />
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link rel="preload" as="style" href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Space+Grotesk:wght@500;600;700&display=swap" />
  <link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Space+Grotesk:wght@500;600;700&display=swap" media="print" onload="this.media='all'" />
  <noscript><link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@400;500;600&family=Space+Grotesk:wght@500;600;700&display=swap" /></noscript>
  <link rel="stylesheet" href="/styles.min.css?v=perf3" />"""

for fpath in glob.glob('docs/*.html'):
    with open(fpath, 'r', encoding='utf-8') as f:
        content = f.read()

    # 1. Clean existing synchronous gtag.js
    content = re.sub(r'<script\s+async\s+src=[\"\']https://www\.googletagmanager\.com/gtag/js\?id=AW-18393322142[\"\']></script>\s*<script>[\s\S]*?gtag\(\'config\',\s*\'AW-18393322142\'\);\s*</script>', '', content)
    content = re.sub(r'<!-- Google tag \(gtag\.js\)[\s\S]*?</script>\s*<!-- Event snippet for Download conversion -->\s*<script>[\s\S]*?</script>', '', content)
    content = re.sub(r'<!-- Event snippet for Download conversion -->\s*<script>[\s\S]*?gtag_report_conversion[\s\S]*?</script>', '', content)

    # 2. Clean existing font links and styles.css
    content = re.sub(r'<meta\s+name=[\"\']theme-color[\"\']\s+content=[\"\']#0a0c12[\"\']\s*/>', '', content)
    content = re.sub(r'<link\s+rel=[\"\']preconnect[\"\']\s+href=[\"\']https://fonts\.googleapis\.com[\"\']\s*/>', '', content)
    content = re.sub(r'<link\s+rel=[\"\']preconnect[\"\']\s+href=[\"\']https://fonts\.gstatic\.com[\"\']\s+crossorigin\s*/>', '', content)
    content = re.sub(r'<link\s+rel=[\"\']preload[\"\']\s+as=[\"\']style[\"\']\s+href=[\"\']https://fonts\.googleapis\.com[\s\S]*?/>', '', content)
    content = re.sub(r'<link\s+rel=[\"\']stylesheet[\"\']\s+href=[\"\']https://fonts\.googleapis\.com[\s\S]*?/>', '', content)
    content = re.sub(r'<link\s+href=[\"\']https://fonts\.googleapis\.com[\s\S]*?rel=[\"\']stylesheet[\"\']\s*/>', '', content)
    content = re.sub(r'<noscript><link\s+rel=[\"\']stylesheet[\"\']\s+href=[\"\']https://fonts\.googleapis\.com[\s\S]*?/></noscript>', '', content)
    content = re.sub(r'<link\s+rel=[\"\']stylesheet[\"\']\s+href=[\"\']/styles[\s\S]*?/>', '', content)

    # 3. Add optimized gtag block right after <head>
    content = content.replace('<head>', '<head>\n' + gtag_block)

    # 4. Add font block before Structured Data or before </head>
    if '<!-- Structured Data' in content:
        content = content.replace('<!-- Structured Data', font_block + '\n\n  <!-- Structured Data')
    else:
        content = content.replace('</head>', font_block + '\n</head>')

    # 5. Clean excessive newlines
    content = re.sub(r'\n{3,}', '\n\n', content)

    with open(fpath, 'w', encoding='utf-8') as f:
        f.write(content)
    print(f'Optimized: {fpath}')

# Now mirror to subdirectories
for fpath in glob.glob('docs/*.html'):
    base = os.path.splitext(os.path.basename(fpath))[0]
    if base not in ('index', '404'):
        subdir = os.path.join('docs', base)
        os.makedirs(subdir, exist_ok=True)
        with open(fpath, 'r', encoding='utf-8') as f:
            content = f.read()
        with open(os.path.join(subdir, 'index.html'), 'w', encoding='utf-8') as f:
            f.write(content)

print('All pages optimized and mirrored!')
