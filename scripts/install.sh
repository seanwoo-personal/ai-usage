#!/bin/bash
# AI Usage installer / updater
#   curl -fsSL https://raw.githubusercontent.com/seanwoo-personal/ai-usage/main/scripts/install.sh | bash
#
# What it does, in order (nothing is replaced until the new app has passed every check):
#   1. picks one exact release (latest, or AIUSAGE_VERSION=v1.2.3) and downloads that release's
#      AI-Usage.zip and AI-Usage.zip.sha256 over HTTPS only
#   2. checks the SHA-256, the archive's paths (no "..", absolute paths or symlinks)
#   3. checks the app: name, bundle ID, executable, CPU architecture, minimum macOS, signature integrity
#   4. copies it next to the destination, then quits the running app and swaps; restores on failure
#
# Limits: the hash comes from the same GitHub release as the app, so it detects corrupted or
# swapped-in-transit downloads, not a compromised release. The app is ad-hoc signed: the signature
# proves the files weren't changed after signing, not who made them (no Apple Developer ID yet).
#
# Test-only settings (ignored unless AIUSAGE_TEST_MODE=1):
#   AIUSAGE_ZIP_URL (file:// allowed), AIUSAGE_SHA256, AIUSAGE_INSTALL_DIR, AIUSAGE_NO_OPEN=1, AIUSAGE_NO_QUIT=1
set -euo pipefail

REPO="seanwoo-personal/ai-usage"
APP="AI Usage.app"
BUNDLE_ID="com.sean.aiusage"
EXE="AIUsage"

say()  { printf '%s\n' "$*"; }
fail() { printf '\n✗ %s\n' "$*" >&2; exit 1; }

TEST_MODE="${AIUSAGE_TEST_MODE:-0}"
if [[ "$TEST_MODE" != "1" ]]; then
  for v in AIUSAGE_ZIP_URL AIUSAGE_SHA256 AIUSAGE_INSTALL_DIR AIUSAGE_NO_OPEN AIUSAGE_NO_QUIT; do
    [[ -n "${!v:-}" ]] && fail "$v 는 테스트 모드(AIUSAGE_TEST_MODE=1)에서만 쓸 수 있어요."
  done
fi

say ""
say "AI Usage 설치를 시작할게요."
[[ "$(uname -s)" == "Darwin" ]] || fail "macOS에서만 설치할 수 있어요."
OS_VERSION="$(sw_vers -productVersion)"
OS_MAJOR="${OS_VERSION%%.*}"
(( OS_MAJOR >= 13 )) || fail "macOS 13(Ventura) 이상이 필요해요. 지금 버전: $OS_VERSION"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-install.XXXXXX")"
LOCK="${TMPDIR:-/tmp}/aiusage-install.lock"
cleanup() { rm -rf "$WORK"; [[ "${HAVE_LOCK:-0}" == "1" ]] && rm -rf "$LOCK"; return 0; }
trap cleanup EXIT

# ── one installer at a time ─────────────────────────────────────────────────────────────
if mkdir "$LOCK" 2>/dev/null; then
  HAVE_LOCK=1; echo $$ > "$LOCK/pid"
else
  other="$(cat "$LOCK/pid" 2>/dev/null || true)"
  if [[ -n "$other" ]] && kill -0 "$other" 2>/dev/null; then
    fail "다른 AI Usage 설치가 이미 진행 중이에요. 끝난 뒤 다시 실행해 주세요."
  fi
  rm -rf "$LOCK"; mkdir "$LOCK" || fail "설치 잠금을 만들 수 없어요. 잠시 후 다시 실행해 주세요."
  HAVE_LOCK=1; echo $$ > "$LOCK/pid"
fi

CURL=(curl --fail --location --silent --show-error --proto '=https' --tlsv1.2
      --connect-timeout 15 --max-time 300 --retry 2 --retry-delay 2)

# ── 1. which release, and download ──────────────────────────────────────────────────────
if [[ "$TEST_MODE" == "1" && -n "${AIUSAGE_ZIP_URL:-}" ]]; then
  TAG="${AIUSAGE_VERSION:-test}"
  ZIP_URL="$AIUSAGE_ZIP_URL"
  [[ "$ZIP_URL" == file://* || "$ZIP_URL" == https://* ]] || fail "테스트 주소는 file:// 또는 https:// 만 쓸 수 있어요."
  EXPECTED_SHA="${AIUSAGE_SHA256:-}"
  [[ -n "$EXPECTED_SHA" ]] || fail "테스트 모드에서는 AIUSAGE_SHA256 이 필요해요."
  say "• (테스트) $ZIP_URL"
  curl --fail --silent --show-error --proto '=file,https' "$ZIP_URL" -o "$WORK/app.zip" || fail "내려받지 못했어요."
else
  if [[ -n "${AIUSAGE_VERSION:-}" ]]; then
    TAG="$AIUSAGE_VERSION"
  else
    say "• 최신 버전을 확인하는 중…"
    "${CURL[@]}" -H "Accept: application/vnd.github+json" "https://api.github.com/repos/$REPO/releases/latest" -o "$WORK/release.json" \
      || fail "최신 버전 정보를 받지 못했어요. 인터넷 연결을 확인하고 다시 실행해 주세요."
    TAG="$(/usr/bin/plutil -extract tag_name raw -o - "$WORK/release.json" 2>/dev/null || true)"
  fi
  [[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "버전 이름이 올바르지 않아요: '$TAG'"
  BASE="https://github.com/$REPO/releases/download/$TAG"
  say "• $TAG 를 내려받는 중…"
  "${CURL[@]}" "$BASE/AI-Usage.zip" -o "$WORK/app.zip" || fail "앱을 내려받지 못했어요. 인터넷 연결을 확인하고 다시 실행해 주세요."
  "${CURL[@]}" "$BASE/AI-Usage.zip.sha256" -o "$WORK/app.zip.sha256" || fail "검증용 해시를 내려받지 못했어요. 다시 실행해 주세요."
  EXPECTED_SHA="$(awk '{print $1; exit}' "$WORK/app.zip.sha256")"
fi

# ── 2. archive checks ───────────────────────────────────────────────────────────────────
[[ -s "$WORK/app.zip" ]] || fail "내려받은 파일이 비어 있어요. 다시 실행해 주세요."
[[ "$EXPECTED_SHA" =~ ^[0-9a-f]{64}$ ]] || fail "검증용 해시 형식이 올바르지 않아요."
ACTUAL_SHA="$(shasum -a 256 "$WORK/app.zip" | awk '{print $1}')"
[[ "$ACTUAL_SHA" == "$EXPECTED_SHA" ]] || fail "내려받은 파일의 해시가 릴리스와 달라요. 손상되었거나 바뀐 파일일 수 있어 설치하지 않았어요."

ENTRIES="$(zipinfo -1 "$WORK/app.zip" 2>/dev/null)" || fail "압축 파일이 손상됐어요. 다시 실행해 주세요."
while IFS= read -r entry; do
  [[ "$entry" == "$APP/"* || "$entry" == "$APP" ]] || fail "압축 안에 예상하지 못한 파일이 있어요: $entry"
  [[ "$entry" == /* || "$entry" == *"/../"* || "$entry" == *"/.." || "$entry" == "../"* ]] && fail "압축 안에 허용되지 않는 경로가 있어요: $entry"
done <<< "$ENTRIES"
if zipinfo "$WORK/app.zip" 2>/dev/null | awk 'NR>2 && /^l/ {found=1} END {exit !found}'; then
  fail "압축 안에 심볼릭 링크가 있어 설치하지 않았어요."
fi
mkdir "$WORK/unzipped"
ditto -x -k "$WORK/app.zip" "$WORK/unzipped" || fail "압축을 풀지 못했어요. 다시 실행해 주세요."
NEW="$WORK/unzipped/$APP"

# ── 3. app checks ───────────────────────────────────────────────────────────────────────
check_app() {   # $1 = app path
  local a="$1" plist="$1/Contents/Info.plist" v
  [[ -d "$a" && -f "$plist" ]] || fail "내려받은 앱의 구조가 올바르지 않아요."
  [[ -z "$(find "$a" -type l -print -quit)" ]] || fail "앱 안에 심볼릭 링크가 있어 설치하지 않았어요."
  v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$plist" 2>/dev/null || true)"
  [[ "$v" == "$BUNDLE_ID" ]] || fail "앱 식별자가 달라요($v). 설치하지 않았어요."
  v="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "$plist" 2>/dev/null || true)"
  [[ "$v" == "$EXE" && -x "$a/Contents/MacOS/$EXE" ]] || fail "앱 실행 파일이 없어요. 설치하지 않았어요."
  local arch_ok='^x86_64h?$'; [[ "$(uname -m)" == "arm64" ]] && arch_ok='^arm64e?$'
  lipo -archs "$a/Contents/MacOS/$EXE" 2>/dev/null | tr ' ' '\n' | grep -qE "$arch_ok" \
    || fail "이 Mac($(uname -m))에서 실행할 수 없는 앱이에요."
  v="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$plist" 2>/dev/null || echo 13.0)"
  (( OS_MAJOR >= ${v%%.*} )) || fail "이 앱은 macOS $v 이상이 필요해요. 지금 버전: $OS_VERSION"
  codesign --verify --strict "$a" 2>/dev/null || fail "앱 서명이 손상됐거나 파일이 바뀌었어요. 설치하지 않았어요."
}
check_app "$NEW"
NEW_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$NEW/Contents/Info.plist")"
if [[ "$TEST_MODE" != "1" && "v$NEW_VERSION" != "$TAG" ]]; then
  fail "앱 버전($NEW_VERSION)이 릴리스($TAG)와 달라요. 설치하지 않았어요."
fi
say "• 확인 완료: 버전 $NEW_VERSION, 파일 해시 일치, 서명 무결성 정상"
say "  (Apple 개발자 인증이 아닌 임시 서명이라, 만든 사람을 증명하지는 않아요.)"

# ── 4. where to install ─────────────────────────────────────────────────────────────────
if [[ "$TEST_MODE" == "1" && -n "${AIUSAGE_INSTALL_DIR:-}" ]]; then
  DEST="$AIUSAGE_INSTALL_DIR"
elif [[ -d "/Applications/$APP" ]]; then
  DEST="/Applications"
elif [[ -d "$HOME/Applications/$APP" ]]; then
  DEST="$HOME/Applications"
elif [[ -w "/Applications" ]]; then
  DEST="/Applications"
else
  DEST="$HOME/Applications"
fi
mkdir -p "$DEST" 2>/dev/null || fail "$DEST 폴더를 만들 수 없어요."
[[ -w "$DEST" ]] || fail "$DEST 에 쓸 권한이 없어요. 기존 앱은 그대로 두었어요."
if [[ "$DEST" == "/Applications" && -d "$HOME/Applications/$APP" ]]; then
  say "  참고: ~/Applications 에도 AI Usage가 있어요. 하나만 남기는 게 좋아요."
fi

NEED_KB="$(du -sk "$NEW" | awk '{print $1}')"
FREE_KB="$(df -Pk "$DEST" | awk 'NR==2 {print $4}')"
(( FREE_KB > NEED_KB * 2 )) || fail "디스크 공간이 부족해요. 기존 앱은 그대로 두었어요."

STAGE="$DEST/.AI Usage.app.new-$$"
BACKUP="$DEST/.AI Usage.app.old-$$"
say "• $DEST 에 준비하는 중…"
ditto "$NEW" "$STAGE" || { rm -rf "$STAGE"; fail "새 앱을 복사하지 못했어요. 기존 앱은 그대로 두었어요."; }
check_app "$STAGE"

# ── 5. swap (only now is the running app touched) ───────────────────────────────────────
WAS_RUNNING=0
if [[ "${AIUSAGE_NO_QUIT:-0}" != "1" ]] && pgrep -x "$EXE" >/dev/null 2>&1; then
  WAS_RUNNING=1
  say "• 실행 중인 AI Usage를 종료하는 중…"
  osascript -e 'quit app "AI Usage"' >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x "$EXE" >/dev/null 2>&1 || break; sleep 0.5; done
  pkill -x "$EXE" >/dev/null 2>&1 || true
fi

restore_and_fail() {
  rm -rf "$DEST/$APP.tmp-fail" 2>/dev/null || true
  if [[ -d "$BACKUP" ]]; then
    [[ -d "$DEST/$APP" ]] && mv "$DEST/$APP" "$DEST/$APP.tmp-fail" 2>/dev/null
    mv "$BACKUP" "$DEST/$APP" 2>/dev/null
    rm -rf "$DEST/$APP.tmp-fail" 2>/dev/null || true
  fi
  rm -rf "$STAGE"
  [[ "$WAS_RUNNING" == "1" && "${AIUSAGE_NO_OPEN:-0}" != "1" ]] && open "$DEST/$APP" 2>/dev/null
  fail "$1 기존 앱으로 되돌렸어요."
}
if [[ -d "$DEST/$APP" ]]; then
  mv "$DEST/$APP" "$BACKUP" || { rm -rf "$STAGE"; fail "기존 앱을 옮기지 못했어요. 기존 앱은 그대로 두었어요."; }
fi
mv "$STAGE" "$DEST/$APP" || restore_and_fail "새 앱으로 바꾸지 못했어요."
rm -rf "$BACKUP"

say ""
say "✓ 설치가 끝났어요: $DEST/$APP (버전 $NEW_VERSION)"
if [[ "${AIUSAGE_NO_OPEN:-0}" != "1" ]]; then
  if open "$DEST/$APP"; then
    say "  앱을 열었어요. 화면 오른쪽 위 메뉴 막대에 아이콘이 보이는지 확인해 주세요."
    say "  처음이라면 열린 안내 창에서 Claude / ChatGPT 계정을 연결해야 사용량이 표시돼요."
  else
    say "  앱을 자동으로 열지 못했어요. 응용 프로그램 폴더에서 AI Usage를 직접 열어 주세요."
  fi
fi
say ""
