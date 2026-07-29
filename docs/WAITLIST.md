# MirrorUE Pro waitlist

Collects signups from [GitHub Pages](https://kamilbourouiba.github.io/MirrorUE/).

## Default: Web3Forms + hCaptcha

```js
window.MirrorUEWaitlist = {
  provider: "web3forms",
  web3formsAccessKey: "YOUR_KEY",
  requireCaptcha: true,
};
```

### One-time dashboard setup (required)

1. [Web3Forms dashboard](https://app.web3forms.com) → your form → **Settings**
2. **Allowed domains:** add `kamilbourouiba.github.io`
3. **Captcha:** enable **hCaptcha** as the spam provider
4. (Recommended) If the access key was ever public in git, **rotate the key** in the dashboard and update `waitlist-config.js`

Submissions arrive by email at the address linked to your Web3Forms account.

### Security on the site

- hCaptcha widget on every waitlist form (Web3Forms client script)
- Honeypot field + 60s client rate limit per browser
- Field length limits (email 254, company 120, note 500)
- GitHub Issues fallback only if Web3Forms fails
- Admin exports via **Actions artifact** — emails are **not** committed to the public repo

## Alternative: GitHub Issues only

No third-party form email; users confirm via a GitHub issue (good for dev audiences).

```js
window.MirrorUEWaitlist = {
  provider: "github-issue",
  requireCaptcha: false,
};
```

Flow: form → prefilled issue tab → user clicks **Submit new issue** → Action auto-closes.

## Manual / admin export

```bash
./scripts/waitlist-add.sh user@example.com pro "Acme" "QA team"
```

Then download the **waitlist-export** artifact from the workflow run (Actions → Waitlist ingest).

Or **Actions → Waitlist ingest → Run workflow** manually.

Copy `data/waitlist.json.example` to `data/waitlist.json` locally if testing the ingest script — never commit real signups.

## Key rotation

If your Web3Forms access key appeared in public git history:

1. Generate a new key at [web3forms.com](https://web3forms.com)
2. Update `docs/waitlist-config.js`
3. Revoke the old key in the Web3Forms dashboard

## Privacy

See [privacy.html](privacy.html) on the site.
