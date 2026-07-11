#!/usr/bin/env bash
# Create the GitHub repo webhook that feeds the oracle sidecar's
# POST /api/github-webhook (which HMAC-verifies and forwards repo+PR-number
# triggers to the native app's /api/pr-webhook).
#
# PREREQUISITE: a Cloudflare Access bypass policy for that exact path must be in
# place first (GitHub can't complete Access's OAuth) — see the "GitHub webhooks"
# section in apps/oracle-mcp/README.md. Until then, deliveries will bounce off
# the Access login page.
#
# Usage:
#   JUANCODE_GH_WEBHOOK_SECRET=... scripts/setup-github-webhook.sh [owner/repo] [domain]
#
#   owner/repo  defaults to the current repo (`gh repo view`)
#   domain      apex domain; the hook URL becomes https://oracle.<domain>/...
#               (or set ORACLE_DOMAIN; or set ORACLE_WEBHOOK_URL to override the
#               full URL)
#
# The secret is read from the JUANCODE_GH_WEBHOOK_SECRET env var only — it is
# never echoed, logged, or written anywhere by this script. Use the SAME value
# the sidecar and the native app see. Idempotent-ish: if a hook already points
# at the URL, the script skips creation.
set -euo pipefail

NWO="${1:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
DOMAIN="${2:-${ORACLE_DOMAIN:-}}"

if [ -n "${ORACLE_WEBHOOK_URL:-}" ]; then
  URL="$ORACLE_WEBHOOK_URL"
elif [ -n "$DOMAIN" ]; then
  URL="https://oracle.${DOMAIN}/api/github-webhook"
else
  echo "error: pass a domain (arg 2) or set ORACLE_DOMAIN / ORACLE_WEBHOOK_URL" >&2
  exit 1
fi

if [ -z "${JUANCODE_GH_WEBHOOK_SECRET:-}" ]; then
  echo "error: JUANCODE_GH_WEBHOOK_SECRET must be set (the sidecar's HMAC secret)" >&2
  exit 1
fi

# Skip if a hook already targets this URL (re-runs must not stack duplicates).
if gh api "repos/${NWO}/hooks" --paginate --jq '.[].config.url' | grep -Fxq "$URL"; then
  echo "hook already exists on ${NWO} -> ${URL}, nothing to do"
  exit 0
fi

# Payload goes over stdin (not argv) so the secret never shows up in `ps`.
# Output shows only the hook id + url, never the config blob.
jq -n --arg url "$URL" --arg secret "$JUANCODE_GH_WEBHOOK_SECRET" '{
  config: { url: $url, secret: $secret, content_type: "json" },
  events: ["pull_request", "pull_request_review", "issue_comment", "check_suite"],
  active: true
}' | gh api "repos/${NWO}/hooks" --input - \
  --jq '"created hook \(.id) -> \(.config.url)"'

echo "done. Verify with: gh api repos/${NWO}/hooks --jq '.[] | {id, url: .config.url, events}'"
