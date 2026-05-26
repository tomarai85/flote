#!/usr/bin/env bash
# upload-r2.sh -- Upload DMG + release notes to Cloudflare R2 under <slug>/.
# Uses rclone with an ephemeral S3-compatible remote.
# Reads R2_ACCOUNT_ID, R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET_NAME from env.
set -euo pipefail

SLUG=""
VERSION=""
DMG=""
NOTES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug) SLUG="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --dmg) DMG="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$SLUG" && -n "$VERSION" && -f "$DMG" ]] || { echo "Missing required args" >&2; exit 2; }
: "${R2_ACCOUNT_ID:?}"
: "${R2_ACCESS_KEY_ID:?}"
: "${R2_SECRET_ACCESS_KEY:?}"
: "${R2_BUCKET_NAME:?}"

# rclone remote name is local-only (config lives in $HOME/.config/rclone).
rclone config delete r2 >/dev/null 2>&1 || true
rclone config create r2 s3 \
  provider=Cloudflare \
  access_key_id="$R2_ACCESS_KEY_ID" \
  secret_access_key="$R2_SECRET_ACCESS_KEY" \
  endpoint="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com" \
  acl=private >/dev/null

DMG_BASENAME="$(basename "$DMG")"
DEST_DMG="r2:$R2_BUCKET_NAME/$SLUG/$DMG_BASENAME"

echo "Uploading $DMG -> $DEST_DMG"
rclone copyto "$DMG" "$DEST_DMG" \
  --s3-no-check-bucket \
  --header-upload "Content-Type: application/x-apple-diskimage" \
  --header-upload "Cache-Control: public, max-age=3600, immutable"

if [[ -n "$NOTES" && -f "$NOTES" ]]; then
  DEST_NOTES="r2:$R2_BUCKET_NAME/$SLUG/release-notes-$VERSION.html"
  echo "Uploading notes -> $DEST_NOTES"
  rclone copyto "$NOTES" "$DEST_NOTES" \
    --s3-no-check-bucket \
    --header-upload "Content-Type: text/html; charset=utf-8" \
    --header-upload "Cache-Control: public, max-age=300"
fi

echo "R2 upload complete."
