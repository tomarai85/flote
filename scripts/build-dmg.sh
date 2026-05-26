#!/usr/bin/env bash
# build-dmg.sh -- Wrap create-dmg to produce a branded DMG.
# Idempotent: removes any prior DMG at the same path before producing the new one.
# Helper-app aware: --no-internet-enable so create-dmg does not re-sign nested apps.
set -euo pipefail

APP=""
NAME=""
VERSION=""
OUT_DIR=""

usage() {
  cat <<EOF
Usage: $0 --app <path.app> --name <DisplayName> --version <X.Y.Z> --out <output-dir>
EOF
  exit 2
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --name) NAME="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1" >&2; usage ;;
  esac
done

[[ -d "$APP" ]] || { echo "App not found: $APP" >&2; exit 1; }
[[ -n "$NAME" && -n "$VERSION" && -n "$OUT_DIR" ]] || usage

mkdir -p "$OUT_DIR"
DMG_NAME="${NAME}-${VERSION}.dmg"
DMG_PATH="$OUT_DIR/$DMG_NAME"

# Cleanup any prior run
rm -f "$DMG_PATH"

# Stage app in a scratch dir to control create-dmg layout exactly.
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"

# Try create-dmg first; fall back to hdiutil if create-dmg is unavailable.
if command -v create-dmg >/dev/null 2>&1; then
  create-dmg \
    --volname "${NAME} ${VERSION}" \
    --window-pos 200 120 \
    --window-size 640 360 \
    --icon-size 96 \
    --icon "$(basename "$APP")" 160 180 \
    --hide-extension "$(basename "$APP")" \
    --app-drop-link 480 180 \
    --no-internet-enable \
    "$DMG_PATH" \
    "$STAGE" || {
      # create-dmg returns non-zero on cosmetic AppleScript errors even when the DMG is fine.
      # Validate the file exists and is mountable; if not, hard-fail.
      if [[ ! -f "$DMG_PATH" ]]; then
        echo "create-dmg failed without producing a DMG" >&2
        exit 1
      fi
      echo "create-dmg returned non-zero but DMG exists; continuing"
    }
else
  echo "create-dmg not installed; falling back to hdiutil"
  hdiutil create -volname "${NAME} ${VERSION}" -srcfolder "$STAGE" -ov -format UDZO "$DMG_PATH"
fi

# Sanity: ensure helper signatures inside the bundle survived staging (cp -R preserves them,
# but verify here so we catch regressions early in CI rather than at notarization time).
hdiutil attach "$DMG_PATH" -nobrowse -readonly -mountpoint "$STAGE/mount" >/dev/null
codesign --verify --deep --strict --verbose=1 "$STAGE/mount/$(basename "$APP")" || {
  hdiutil detach "$STAGE/mount" -force >/dev/null
  echo "Codesign verification failed on DMG-mounted app" >&2
  exit 1
}
hdiutil detach "$STAGE/mount" -force >/dev/null

echo "DMG: $DMG_PATH"
