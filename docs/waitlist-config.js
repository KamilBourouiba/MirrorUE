/** MirrorUE Pro waitlist — no API keys required. */
window.MirrorUEWaitlist = {
  /**
   * Provider (pick one):
   * - "github-issue" — prefilled GitHub issue (default). You get GitHub notification emails.
   * - "web3forms" — Web3Forms.co → your inbox (set web3formsAccessKey).
   * - "formsubmit" — FormSubmit.co (often blocked by iCloud).
   * - "custom" — your own POST URL (Google Apps Script, etc.)
   */
  provider: "github-issue",

  /** Web3Forms.co — free at https://web3forms.com (access key is public in client). */
  web3formsAccessKey: "",

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
