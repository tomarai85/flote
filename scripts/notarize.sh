#!/usr/bin/env bash
# notarize.sh -- Submit a DMG to Apple notarization service, --wait until verdict.
# Reads credentials from env (MACOS_APPLE_ID, MACOS_TEAM_ID, MACOS_APP_SPECIFIC_PASSWORD).
# On failure, fetches notarization log to stdout for CI to surface.
set -euo pipefail

DMG="${1:-}"
if [[ -z "$DMG" || ! -f "$DMG" ]]; then
  echo "Usage: $0 <path-to-dmg>" >&2
  exit 2
fi

: "${MACOS_APPLE_ID:?MACOS_APPLE_ID env required}"
: "${MACOS_TEAM_ID:?MACOS_TEAM_ID env required}"
: "${MACOS_APP_SPECIFIC_PASSWORD:?MACOS_APP_SPECIFIC_PASSWORD env required}"

echo "Submitting $DMG to Apple notarization service..."
SUBMIT_OUTPUT="$(mktemp)"
trap 'rm -f "$SUBMIT_OUTPUT"' EXIT

if ! xcrun notarytool submit "$DMG" \
  --apple-id "$MACOS_APPLE_ID" \
  --team-id "$MACOS_TEAM_ID" \
  --password "$MACOS_APP_SPECIFIC_PASSWORD" \
  --wait \
  --output-format json > "$SUBMIT_OUTPUT" 2>&1; then
  cat "$SUBMIT_OUTPUT" >&2
  echo "notarytool submit failed" >&2
  exit 1
fi

cat "$SUBMIT_OUTPUT"
STATUS="$(grep -o '"status":"[^"]*"' "$SUBMIT_OUTPUT" | head -1 | sed 's/.*"status":"\([^"]*\)".*/\1/')"
SUB_ID="$(grep -o '"id":"[^"]*"' "$SUBMIT_OUTPUT" | head -1 | sed 's/.*"id":"\([^"]*\)".*/\1/')"

if [[ "$STATUS" != "Accepted" ]]; then
  echo "Notarization NOT accepted (status: $STATUS, id: $SUB_ID)" >&2
  if [[ -n "$SUB_ID" ]]; then
    xcrun notarytool log "$SUB_ID" \
      --apple-id "$MACOS_APPLE_ID" \
      --team-id "$MACOS_TEAM_ID" \
      --password "$MACOS_APP_SPECIFIC_PASSWORD" >&2 || true
  fi
  exit 1
fi

echo "Notarization accepted (id: $SUB_ID)"
