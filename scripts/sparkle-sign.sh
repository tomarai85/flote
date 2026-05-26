#!/usr/bin/env bash
# sparkle-sign.sh -- Produce EdDSA signature for a DMG using Sparkle's sign_update tool.
# Outputs JSON: { "edSignature": "...", "length": N }
# Reads the private key from env SPARKLE_PRIVATE_KEY_FLOTE.
set -euo pipefail

DMG="${1:-}"
if [[ -z "$DMG" || ! -f "$DMG" ]]; then
  echo "Usage: $0 <path-to-dmg>" >&2
  exit 2
fi

PRIVATE_KEY="${SPARKLE_PRIVATE_KEY_FLOTE:-}"
if [[ -z "$PRIVATE_KEY" ]]; then
  echo "SPARKLE_PRIVATE_KEY_FLOTE env not set" >&2
  exit 1
fi

SIGN_UPDATE=""
for cand in \
  "$(command -v sign_update || true)" \
  "/opt/homebrew/Caskroom/sparkle/$(ls /opt/homebrew/Caskroom/sparkle 2>/dev/null | tail -1)/bin/sign_update" \
  "$HOME/Library/Application Support/Sparkle/sign_update"; do
  if [[ -n "$cand" && -x "$cand" ]]; then
    SIGN_UPDATE="$cand"; break
  fi
done

if [[ -z "$SIGN_UPDATE" ]]; then
  echo "sign_update tool not found. Install: brew install --cask sparkle" >&2
  exit 1
fi

KEY_FILE="$(mktemp)"
chmod 600 "$KEY_FILE"
printf "%s\n" "$PRIVATE_KEY" > "$KEY_FILE"
trap 'rm -f "$KEY_FILE"' EXIT

RAW="$("$SIGN_UPDATE" -f "$KEY_FILE" "$DMG")"
ED_SIG="$(echo "$RAW" | sed -n 's/.*sparkle:edSignature="\([^"]*\)".*/\1/p')"
LEN="$(echo "$RAW" | sed -n 's/.*length="\([^"]*\)".*/\1/p')"

if [[ -z "$ED_SIG" || -z "$LEN" ]]; then
  echo "Failed to parse sign_update output: $RAW" >&2
  exit 1
fi

printf '{"edSignature":"%s","length":"%s"}\n' "$ED_SIG" "$LEN"
