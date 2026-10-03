#!/usr/bin/env bash
# Isolated installer tests: a temporary install folder, fake app bundles, no network,
# never /Applications or the user's real app or settings.
set -uo pipefail
cd "$(dirname "$0")/.."
INSTALL="$PWD/scripts/install.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/aiusage-installtest.XXXXXX")"
trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); echo "  ✓ $1"; }
bad() { fail=$((fail+1)); echo "  ✗ $1"; }

# A minimal, ad-hoc signed app. $1 = dir, $2 = bundle id, $3 = version
make_app() {
  local a="$1/AI Usage.app"
  mkdir -p "$a/Contents/MacOS"
  cp /usr/bin/true "$a/Contents/MacOS/AIUsage"
  cat > "$a/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$2</string>
<key>CFBundleExecutable</key><string>AIUsage</string>
<key>CFBundleShortVersionString</key><string>$3</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
</dict></plist>
PLIST
  codesign --force --sign - "$a" >/dev/null 2>&1
}
zip_app() { (cd "$1" && ditto -c -k --keepParent "AI Usage.app" "$2"); }
sha() { shasum -a 256 "$1" | awk '{print $1}'; }

# Fixtures
mkdir -p "$T/good" "$T/wrongid" "$T/noexe" "$T/tampered" "$T/wrongarch" "$T/fx"
make_app "$T/good" com.sean.aiusage 9.9.9;            zip_app "$T/good" "$T/fx/good.zip"
make_app "$T/wrongid" com.example.other 9.9.9;        zip_app "$T/wrongid" "$T/fx/wrongid.zip"
make_app "$T/noexe" com.sean.aiusage 9.9.9; rm "$T/noexe/AI Usage.app/Contents/MacOS/AIUsage"; zip_app "$T/noexe" "$T/fx/noexe.zip"
make_app "$T/tampered" com.sean.aiusage 9.9.9; printf 'x' >> "$T/tampered/AI Usage.app/Contents/MacOS/AIUsage"; zip_app "$T/tampered" "$T/fx/tampered.zip"
# Executable built only for the other CPU type (x86_64 on Apple Silicon, arm64 on Intel).
other_arch=arm64; [[ "$(uname -m)" == "arm64" ]] && other_arch=x86_64
make_app "$T/wrongarch" com.sean.aiusage 9.9.9
lipo /usr/bin/true -thin "$other_arch" -output "$T/wrongarch/AI Usage.app/Contents/MacOS/AIUsage"
codesign --force --sign - "$T/wrongarch/AI Usage.app" >/dev/null 2>&1; zip_app "$T/wrongarch" "$T/fx/wrongarch.zip"
: > "$T/fx/empty.zip"
head -c 4096 /dev/urandom > "$T/fx/corrupt.zip"
python3 - "$T/fx" <<'PY'
import sys, zipfile, os
d = sys.argv[1]
with zipfile.ZipFile(os.path.join(d, "traversal.zip"), "w") as z:
    z.writestr("AI Usage.app/Contents/Info.plist", "x")
    z.writestr("AI Usage.app/../../evil.txt", "x")
with zipfile.ZipFile(os.path.join(d, "extra.zip"), "w") as z:
    z.writestr("AI Usage.app/Contents/Info.plist", "x")
    z.writestr("Other.app/Contents/Info.plist", "x")
link = zipfile.ZipInfo("AI Usage.app/Contents/link")
link.external_attr = (0o120777 << 16)
with zipfile.ZipFile(os.path.join(d, "symlink.zip"), "w") as z:
    z.writestr("AI Usage.app/Contents/Info.plist", "x")
    z.writestr(link, "/etc/passwd")
PY

# An "existing install" with a marker, re-created before each case
DEST="$T/Install Dir With Spaces"
fresh_dest() {
  chmod -R u+w "$DEST" 2>/dev/null; rm -rf "$DEST"; mkdir -p "$DEST/AI Usage.app/Contents"
  echo old > "$DEST/AI Usage.app/Contents/marker"
}
old_kept()   { [[ -f "$DEST/AI Usage.app/Contents/marker" ]]; }
no_litter()  { [[ -z "$(ls -A "$DEST" | grep -v '^AI Usage.app$')" ]]; }
run() {   # $1 = zip, $2 = sha (optional)
  local z="$1" s="${2:-$(sha "$1")}"
  AIUSAGE_TEST_MODE=1 AIUSAGE_ZIP_URL="file://$z" AIUSAGE_SHA256="$s" AIUSAGE_INSTALL_DIR="$DEST" \
    AIUSAGE_NO_OPEN=1 AIUSAGE_NO_QUIT=1 bash "$INSTALL" >"$T/out.txt" 2>&1
}
expect_fail() {   # $1 = name, rest = run args
  local name="$1"; shift
  fresh_dest
  if run "$@"; then bad "$name: should have failed"
  elif ! old_kept; then bad "$name: existing app was not preserved"
  elif ! no_litter; then bad "$name: left temporary files in the install folder"
  else ok "$name → refused, existing app kept"; fi
}

echo "Installer (isolated, fake apps)"
expect_fail "download fails"            "$T/fx/does-not-exist.zip" "$(printf '%064d' 0)"
expect_fail "empty download"            "$T/fx/empty.zip"
expect_fail "corrupt ZIP"               "$T/fx/corrupt.zip"
expect_fail "hash mismatch"             "$T/fx/good.zip" "$(printf 'a%.0s' {1..64})"
expect_fail "wrong bundle ID"           "$T/fx/wrongid.zip"
expect_fail "missing executable"        "$T/fx/noexe.zip"
expect_fail "tampered after signing"    "$T/fx/tampered.zip"
expect_fail "path traversal entry"      "$T/fx/traversal.zip"
expect_fail "extra top-level app"       "$T/fx/extra.zip"
expect_fail "symlink in archive"        "$T/fx/symlink.zip"
expect_fail "app for the other CPU type" "$T/fx/wrongarch.zip"

# A Mac without developer tools: lipo, xcrun and friends fail there. The installer must not need them.
mkdir -p "$T/nodevtools"
for tool in lipo xcrun otool clang cc git; do
  printf '#!/bin/sh\necho "xcode-select: note: No developer tools were found" >&2\nexit 1\n' > "$T/nodevtools/$tool"
  chmod +x "$T/nodevtools/$tool"
done
fresh_dest
if PATH="$T/nodevtools:$PATH" run "$T/fx/good.zip" && ! old_kept && no_litter; then
  ok "Mac without developer tools → installs normally"
else bad "Mac without developer tools: install failed"; cat "$T/out.txt"; fi

fresh_dest; chmod 555 "$DEST"
if run "$T/fx/good.zip"; then bad "read-only install folder: should have failed"
elif ! old_kept; then bad "read-only install folder: existing app lost"
else ok "read-only install folder → refused, existing app kept"; fi
chmod 755 "$DEST"

fresh_dest
if run "$T/fx/good.zip" && [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/AI Usage.app/Contents/Info.plist")" == "9.9.9" ]] \
   && ! old_kept && no_litter && codesign --verify --strict "$DEST/AI Usage.app" 2>/dev/null; then
  ok "valid app in a folder with spaces → replaced, verified, no leftovers"
else bad "valid app install"; cat "$T/out.txt"; fi

# Two installers at once: exactly one may run; the result must be a valid app.
fresh_dest
( run "$T/fx/good.zip"; echo $? > "$T/r1" ) & ( run "$T/fx/good.zip"; echo $? > "$T/r2" ) & wait
codes="$(cat "$T/r1")$(cat "$T/r2")"
if [[ "$codes" == *0* ]] && codesign --verify --strict "$DEST/AI Usage.app" 2>/dev/null && no_litter; then
  ok "two installers at once → a valid app, no leftovers (exit codes $codes)"
else bad "two installers at once (exit codes $codes)"; fi

# The app's own updater runs this script as its child: the running app is then our *parent*.
# A fake app process (a renamed shell) starts the installer and must be quit by it; the installer
# carries on and finishes on its own (its output file is the result).
fresh_dest
printf '#include <stdlib.h>\n#include <unistd.h>\nint main(int c, char **v) { int r = system(v[1]); sleep(60); return r; }\n' > "$T/fake.c"
cc -o "$T/AIUsageFakeApp" "$T/fake.c" 2>/dev/null
"$T/AIUsageFakeApp" "AIUSAGE_TEST_MODE=1 AIUSAGE_ZIP_URL='file://$T/fx/good.zip' AIUSAGE_SHA256='$(sha "$T/fx/good.zip")' \
  AIUSAGE_INSTALL_DIR='$DEST' AIUSAGE_NO_OPEN=1 AIUSAGE_PROCESS_NAME=AIUsageFakeApp bash '$INSTALL' > '$T/out-parent.txt' 2>&1" 2>/dev/null &
FAKE=$!
disown "$FAKE" 2>/dev/null
for _ in $(seq 1 80); do grep -qE "설치가 끝났어요|✗" "$T/out-parent.txt" 2>/dev/null && break; sleep 0.5; done
sleep 0.5
if grep -q "설치가 끝났어요" "$T/out-parent.txt" && grep -q "종료하는 중" "$T/out-parent.txt" \
   && ! kill -0 "$FAKE" 2>/dev/null && ! old_kept && no_litter; then
  ok "updater case: the running app is the installer's parent → it is quit, then replaced"
else
  bad "updater case: parent app was not quit or install didn't finish"; kill -9 "$FAKE" 2>/dev/null; cat "$T/out-parent.txt"
fi

# Test-only settings are refused outside test mode.
if AIUSAGE_ZIP_URL="file://$T/fx/good.zip" bash "$INSTALL" >"$T/out.txt" 2>&1; then
  bad "local file URL accepted outside test mode"
else ok "local file URL outside test mode → refused before doing anything"; fi

echo ""
echo "installer: $pass passed, $fail failed"
[[ $fail == 0 ]]
