# MirrorUE Pro waitlist

Collects signups from [GitHub Pages](https://kamilbourouiba.github.io/MirrorUE/) — **no API keys** on the default setup.

## Default: FormSubmit (recommended)

Uses [FormSubmit.co](https://formsubmit.co) — free, only your email address.

1. Set your inbox in `docs/waitlist-config.js` (`kbourouiba@icloud.com`).
2. Push to `main`.
3. **Activate once:** submit a test signup on the site (or use FormSubmit’s test). FormSubmit emails **`notifyEmail`** with an **“Activate Form”** link — click it. Until then, the site falls back to opening a GitHub issue for the visitor.
4. After activation, signups arrive as email (table layout).

```js
window.MirrorUEWaitlist = {
  provider: "formsubmit",
  notifyEmail: "kbourouiba@icloud.com",
};
```

No API key. After changing `notifyEmail`, push and complete FormSubmit activation from the new inbox.

## Alternative: GitHub Issues (100% GitHub-native)

Good if you want signups in `data/waitlist.json` without any third party.

```js
window.MirrorUEWaitlist = {
  provider: "github-issue",
  githubIssue: { owner: "KamilBourouiba", repo: "MirrorUE" },
};
```

Flow:

1. User submits the form → prefilled GitHub issue opens in a new tab.
2. They click **Submit new issue** (needs a GitHub account).
3. Action [waitlist-from-issue.yml](../.github/workflows/waitlist-from-issue.yml) parses the issue, appends to [`data/waitlist.json`](../data/waitlist.json), comments, and closes it.

Direct link (no site form): **New issue → Pro waitlist signup** template.

## Manual / admin

```bash
./scripts/waitlist-add.sh user@example.com pro "Acme" "QA team"
```

Or **Actions → Waitlist ingest → Run workflow**.

## Privacy

- Honeypot field blocks basic bots.
- `localStorage` remembers if the browser already joined.
- Issues are public until closed; FormSubmit keeps signups in your inbox only.
