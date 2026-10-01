#!/usr/bin/env bash
# Builds the test runner from the app sources (without main.swift) plus Tests/*.swift and runs it.
# A compile failure stops here with the full compiler output; warnings are shown and kept in the log.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK="$(mktemp -d)"
OUT="$WORK/selftest"
LOG="${SELFTEST_LOG:-$WORK/compile.log}"
SRCS=()
while IFS= read -r f; do SRCS+=("$f"); done < <(ls Sources/AIUsage/*.swift | grep -v '/main.swift$')
while IFS= read -r f; do SRCS+=("$f"); done < <(ls Tests/*.swift)

if ! swiftc -parse-as-library -O "${SRCS[@]}" -o "$OUT" > "$LOG" 2>&1; then
  cat "$LOG"
  echo "✗ 테스트 빌드 실패 (컴파일 로그: $LOG)" >&2
  exit 2
fi
WARNINGS=$(grep -c "warning:" "$LOG" || true)
if [[ "$WARNINGS" != "0" ]]; then
  echo "컴파일 경고 ${WARNINGS}개 (전체 로그: $LOG)"
  grep "warning:" "$LOG" | sed 's#^.*/\(Sources\|Tests\)/#  \1/#' | sort -u | head -20
fi
"$OUT"
status=$?
[[ -x scripts/test-install.sh ]] && { bash scripts/test-install.sh || status=1; }
exit $status
