# MirrorUE Pro waitlist

Collects signups from [GitHub Pages](https://kamilbourouiba.github.io/MirrorUE/) — **no API keys** on the default setup.

## Default: GitHub Issues (recommended)

FormSubmit often fails to deliver to iCloud and other strict inboxes. The default provider opens a **prefilled GitHub issue** instead.

**You receive signups via GitHub notification emails** (Settings → Notifications → Issues).

```js
window.MirrorUEWaitlist = {
  provider: "github-issue",
  githubIssue: { owner: "KamilBourouiba", repo: "MirrorUE" },
};
```

Flow:

1. User submits the form on the site.
2. A prefilled GitHub issue opens in a new tab.
3. They click **Submit new issue** (free GitHub account required).
4. Action [waitlist-from-issue.yml](../.github/workflows/waitlist-from-issue.yml) validates the issue, comments, and auto-closes it.

Direct link (no site form): **New issue → Pro waitlist signup** template.

## Alternative: Web3Forms (email inbox)

If you prefer email delivery without GitHub:

1. Create a free access key at [web3forms.com](https://web3forms.com) (uses your email).
2. Set in `docs/waitlist-config.js`:

```js
window.MirrorUEWaitlist = {
  provider: "web3forms",
  web3formsAccessKey: "YOUR_KEY_HERE",
};
```

If the key is missing or submission fails, the site falls back to the GitHub issue flow.

## Alternative: FormSubmit

```js
window.MirrorUEWaitlist = {
  provider: "formsubmit",
  notifyEmail: "kbourouiba@icloud.com",
};
```

Requires one-time “Activate Form” email from FormSubmit. Often blocked by iCloud — prefer GitHub Issues or Web3Forms.

## Manual / admin

```bash
./scripts/waitlist-add.sh user@example.com pro "Acme" "QA team"
```

Or **Actions → Waitlist ingest → Run workflow** (appends to `data/waitlist.json` for private admin use).

## Privacy

See [privacy.html](privacy.html) on the site.

- Honeypot field blocks basic bots.
- `localStorage` remembers if the browser already joined.
- GitHub issues on a public repo may expose signup details until closed — issues are auto-closed after processing.
