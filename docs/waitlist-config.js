/** MirrorUE Pro waitlist — no API keys required. */
window.MirrorUEWaitlist = {
  /**
   * Provider (pick one):
   * - "github-issue" — prefilled GitHub issue (default). You get GitHub notification emails.
   * - "web3forms" — Web3Forms.co → your inbox (set web3formsAccessKey).
   * - "formsubmit" — FormSubmit.co (often blocked by iCloud).
   * - "custom" — your own POST URL (Google Apps Script, etc.)
   */
  provider: "web3forms",

  /** Web3Forms.co — free at https://web3forms.com (access key is public in client). */
  web3formsAccessKey: "a5a3e211-4da8-4a32-9834-973ba577c77b",

  /** Require hCaptcha before Web3Forms submit (enable hCaptcha in Web3Forms dashboard). */
  requireCaptcha: true,

  /** FormSubmit.co — optional fallback */
  notifyEmail: "kbourouiba@icloud.com",

  /** GitHub issue signup (provider: github-issue) */
  githubIssue: {
    owner: "KamilBourouiba",
    repo: "MirrorUE",
    template: "waitlist.yml",
  },

  /** Optional custom JSON endpoint */
  customEndpoint: "",

  contactEmail: "kbourouiba@icloud.com",
  fallbackMailto: "kbourouiba@icloud.com",
};
