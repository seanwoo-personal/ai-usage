#!/bin/bash
# AI Usage installer
#   curl -fsSL https://raw.githubusercontent.com/seanwoo-personal/ai-usage/main/scripts/install.sh | bash
#
# Downloads the latest release, installs it to /Applications (or ~/Applications) and opens it.
# AIUSAGE_ZIP_URL overrides the download location (used for local testing).
set -euo pipefail

REPO="seanwoo-personal/ai-usage"
URL="${AIUSAGE_ZIP_URL:-https://github.com/$REPO/releases/latest/download/AI-Usage.zip}"
APP="AI Usage.app"

say()  { printf '%s\n' "$*"; }
fail() { printf '\n✗ %s\n' "$*" >&2; exit 1; }

say ""
say "AI Usage 설치를 시작할게요."
[[ "$(uname -s)" == "Darwin" ]] || fail "macOS에서만 설치할 수 있어요."
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 13 )) || fail "macOS 13(Ventura) 이상이 필요해요. 지금 버전: $(sw_vers -productVersion)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

say "• 최신 버전을 내려받는 중…"
curl -fL --progress-bar "$URL" -o "$TMP/app.zip" \
  || fail "내려받지 못했어요. 인터넷 연결을 확인하고 같은 명령을 다시 실행해 주세요."
ditto -x -k "$TMP/app.zip" "$TMP/unzipped" || fail "내려받은 파일이 손상됐어요. 다시 실행해 주세요."
[[ -d "$TMP/unzipped/$APP" ]] || fail "내려받은 파일에 앱이 없어요. 다시 실행해 주세요."

DEST="/Applications"
[[ -w "$DEST" ]] || DEST="$HOME/Applications"
mkdir -p "$DEST"

if pgrep -x AIUsage >/dev/null 2>&1; then
  say "• 실행 중인 AI Usage를 종료하는 중…"
  osascript -e 'quit app "AI Usage"' >/dev/null 2>&1 || true
  sleep 1
  pkill -x AIUsage >/dev/null 2>&1 || true
fi

say "• $DEST 에 설치하는 중…"
rm -rf "$DEST/$APP"
ditto "$TMP/unzipped/$APP" "$DEST/$APP"
xattr -dr com.apple.quarantine "$DEST/$APP" >/dev/null 2>&1 || true

open "$DEST/$APP"
say ""
say "✓ 설치가 끝났어요!"
say "  방금 열린 안내 창을 따라 Claude / Codex 계정을 연결하면 돼요."
say "  화면 오른쪽 위 메뉴 막대에 사용량이 표시돼요."
say ""
