#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
OUT="$(mktemp -d)/selftest"
SRCS=$(ls Sources/AIUsage/*.swift | grep -v '/main.swift$')
swiftc -parse-as-library -O $SRCS Tests/selftest.swift -o "$OUT" 2>&1 | grep -E "error" || true
"$OUT"
