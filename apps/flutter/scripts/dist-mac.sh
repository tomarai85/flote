#!/bin/bash
# Flote Sprint 6 生成物
# 用途: macOS 向けリリースビルド、ad-hoc 署名、DMG 作成を自動化する

set -euo pipefail

# 使い方をまとめて表示する
usage() {
  cat <<'EOF'
Usage:
  ./scripts/dist-mac.sh [--version x.y.z]
  ./scripts/dist-mac.sh --help

Options:
  --version <x.y.z>  DMG ファイル名に埋め込むバージョンを指定する
  -h, --help         このヘルプを表示する
EOF
}

# エラーメッセージを統一して終了する
fail() {
  echo "エラー: $1" >&2
  exit 1
}

# 必須コマンドの存在を事前に確認する
require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "PATH に $1 が無い。インストール状況と PATH を確認してください。"
  fi
}

# 進捗表示付きでコマンドを実行する
run_step() {
  local message="$1"
  shift

  echo "==> $message"
  "$@" || fail "$message に失敗しました。"
}

VERSION=""

# 引数は最小限に保ち、未対応オプションは明示的に弾く
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --version)
      [ "$#" -ge 2 ] || fail "--version には値が必要です。"
      VERSION="$2"
      shift 2
      ;;
    *)
      fail "不明な引数です: $1"
      ;;
  esac
done

# スクリプトの親ディレクトリである apps/flutter を作業場所にする
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$APP_DIR"

require_command flutter
require_command codesign
require_command hdiutil
require_command shasum

# バージョン未指定時は pubspec.yaml の version 行から取り出す
if [ -z "$VERSION" ]; then
  VERSION="$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d'+' -f1)"
fi

[ -n "$VERSION" ] || fail "バージョンを解決できませんでした。pubspec.yaml の version: を確認してください。"

APP_PATH="build/macos/Build/Products/Release/Flote.app"
DIST_DIR="dist"
DMG_PATH="$DIST_DIR/flote-mac-v${VERSION}.dmg"

# Flutter の依存解決と macOS リリースビルドを順に実行する
echo "==> flutter clean && flutter pub get"
flutter clean || fail "flutter clean に失敗しました。"
flutter pub get || fail "flutter pub get に失敗しました。"

run_step "flutter build macos --release" flutter build macos --release

# 生成された .app に ad-hoc 署名を付ける
[ -d "$APP_PATH" ] || fail "ビルド成果物が見つかりません: $APP_PATH"
echo "==> ad-hoc codesign"
codesign --force --deep --sign - "$APP_PATH" || fail "codesign に失敗しました。"

# dist を整え、古い DMG を掃除してから新しい DMG を作成する
echo "==> dist ディレクトリの準備"
mkdir -p "$DIST_DIR" || fail "dist ディレクトリを作成できませんでした。"
rm -f "$DIST_DIR"/flote-mac-*.dmg || fail "既存 DMG の削除に失敗しました。"

echo "==> hdiutil create で DMG を作成"
hdiutil create \
  -volname "Flote" \
  -srcfolder "$APP_PATH" \
  -ov \
  -format UDZO \
  "$DMG_PATH" || fail "DMG の作成に失敗しました。"

[ -f "$DMG_PATH" ] || fail "DMG が生成されませんでした: $DMG_PATH"

# 配布確認に必要なパス、サイズ、ハッシュを最後にまとめて表示する
FILE_SIZE_BYTES="$(wc -c < "$DMG_PATH" | tr -d '[:space:]')"
FILE_SIZE_HUMAN="$(du -h "$DMG_PATH" | awk '{print $1}')"

echo "==> 出力結果"
echo "DMG: $(cd "$DIST_DIR" && pwd)/$(basename "$DMG_PATH")"
echo "サイズ: ${FILE_SIZE_BYTES} bytes (${FILE_SIZE_HUMAN})"
echo "SHA-256:"
shasum -a 256 "$DMG_PATH" || fail "SHA-256 の計算に失敗しました。"
