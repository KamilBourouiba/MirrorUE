/** MirrorUE Pro waitlist — no API keys required. */
window.MirrorUEWaitlist = {
  /**
   * Provider (pick one):
   * - "formsubmit" — emails you directly (default). One-time inbox verify on first signup.
   * - "github-issue" — opens a GitHub issue; Actions ingests to data/waitlist.json (dev audience).
   * - "custom" — your own POST URL (Google Apps Script, etc.)
   */
  provider: "formsubmit",

  /**
   * FormSubmit.co — only your address, no API key.
   * First test signup emails you an "Activate Form" link at this address (click once).
   */
  notifyEmail: "kbourouiba@icloud.com",

  /** GitHub issue ingest (provider: github-issue) */
  githubIssue: {
    owner: "KamilBourouiba",
    repo: "MirrorUE",
    template: "waitlist",
  },

  /** Optional custom JSON endpoint */
  customEndpoint: "",

  /** Last-resort if provider misconfigured */
  fallbackMailto: "kbourouiba@icloud.com",
};
