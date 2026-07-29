#!/usr/bin/env bash
# Append a signup to data/waitlist.json via GitHub repository_dispatch.
# Requires: gh auth login
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

EMAIL="${1:-}"
PLAN="${2:-pro}"
COMPANY="${3:-}"
NOTE="${4:-}"
SOURCE="${5:-admin}"

if [[ -z "$EMAIL" ]]; then
  echo "Usage: $0 email [plan=pro|fleet] [company] [note] [source]" >&2
  exit 1
fi

REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner)"

gh api "repos/${REPO}/dispatches" \
  -f event_type=waitlist-signup \
  -f "client_payload[email]=${EMAIL}" \
  -f "client_payload[plan]=${PLAN}" \
  -f "client_payload[company]=${COMPANY}" \
  -f "client_payload[note]=${NOTE}" \
  -f "client_payload[source]=${SOURCE}"

echo "Dispatched waitlist-signup for ${EMAIL} (${PLAN})"
