#!/usr/bin/env bash
# generate-appcast.sh -- Build appcast.xml for Sparkle, upload to R2.
# Uses HTTPS-only URLs. EdDSA signature embedded. Release notes inlined or linked.
# Reads R2 creds from env (same as upload-r2.sh).
set -euo pipefail

SLUG=""
APP_NAME=""
VERSION=""
BUILD=""
DMG=""
ED_SIG=""
LENGTH=""
NOTES=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --slug) SLUG="$2"; shift 2 ;;
    --app-name) APP_NAME="$2"; shift 2 ;;
    --version) VERSION="$2"; shift 2 ;;
    --build) BUILD="$2"; shift 2 ;;
    --dmg) DMG="$2"; shift 2 ;;
    --ed-signature) ED_SIG="$2"; shift 2 ;;
    --length) LENGTH="$2"; shift 2 ;;
    --notes) NOTES="$2"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

[[ -n "$SLUG" && -n "$APP_NAME" && -n "$VERSION" && -n "$BUILD" && -n "$DMG" && -n "$ED_SIG" && -n "$LENGTH" ]] \
  || { echo "Missing required args" >&2; exit 2; }
: "${R2_ACCOUNT_ID:?}"
: "${R2_ACCESS_KEY_ID:?}"
: "${R2_SECRET_ACCESS_KEY:?}"
: "${R2_BUCKET_NAME:?}"

DMG_BASENAME="$(basename "$DMG")"
DMG_URL="https://dl.atelier.dev/$SLUG/$DMG_BASENAME"   # HTTPS only, dl.atelier.dev fronted by Cloudflare Worker
PUB_DATE="$(LC_TIME=C date -u +"%a, %d %b %Y %H:%M:%S +0000")"

# Inline release notes if small (<32KB); otherwise link.
NOTES_BLOCK=""
if [[ -n "$NOTES" && -f "$NOTES" ]]; then
  NOTES_SIZE=$(stat -f%z "$NOTES" 2>/dev/null || echo 0)
  if (( NOTES_SIZE > 0 && NOTES_SIZE < 32000 )); then
    # Inline (CDATA-escape: split any literal "]]>" sequences)
    NOTES_CONTENT="$(sed 's/]]>/]]]]><![CDATA[>/g' "$NOTES")"
    NOTES_BLOCK="<description><![CDATA[${NOTES_CONTENT}]]></description>"
  else
    NOTES_URL="https://dl.atelier.dev/$SLUG/release-notes-$VERSION.html"
    NOTES_BLOCK="<sparkle:releaseNotesLink>${NOTES_URL}</sparkle:releaseNotesLink>"
  fi
fi

APPCAST_OUT="$(mktemp)"
trap 'rm -f "$APPCAST_OUT"' EXIT

cat > "$APPCAST_OUT" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>${APP_NAME} (atelier)</title>
    <link>https://atelier.dev/${SLUG}</link>
    <description>${APP_NAME} updates feed</description>
    <language>en</language>
    <item>
      <title>${APP_NAME} ${VERSION}</title>
      <pubDate>${PUB_DATE}</pubDate>
      <sparkle:version>${BUILD}</sparkle:version>
      <sparkle:shortVersionString>${VERSION}</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>13.0</sparkle:minimumSystemVersion>
      ${NOTES_BLOCK}
      <enclosure
        url="${DMG_URL}"
        sparkle:edSignature="${ED_SIG}"
        length="${LENGTH}"
        type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF

echo "Generated appcast.xml:"
cat "$APPCAST_OUT"

rclone config delete r2 >/dev/null 2>&1 || true
rclone config create r2 s3 \
  provider=Cloudflare \
  access_key_id="$R2_ACCESS_KEY_ID" \
  secret_access_key="$R2_SECRET_ACCESS_KEY" \
  endpoint="https://$R2_ACCOUNT_ID.r2.cloudflarestorage.com" \
  acl=private >/dev/null

DEST="r2:$R2_BUCKET_NAME/$SLUG/appcast.xml"
echo "Uploading appcast -> $DEST"
rclone copyto "$APPCAST_OUT" "$DEST" \
  --s3-no-check-bucket \
  --header-upload "Content-Type: application/xml; charset=utf-8" \
  --header-upload "Cache-Control: public, max-age=300"

echo "Appcast upload complete."
