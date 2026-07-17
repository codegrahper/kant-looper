#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

REPO="$TMP_ROOT/repo"
STATE="$TMP_ROOT/state"
mkdir -p "$REPO" "$STATE"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name test
git -C "$REPO" commit --allow-empty -qm initial
printf '# task\n\n## Goal\nTest terminal state\n' > "$TMP_ROOT/task.md"

if "$ROOT/scripts/kant-loop.sh" _run_mode unsupported "$TMP_ROOT/task.md" "$STATE" "$REPO" '' '' '' implement; then
  exit 1
fi
test "$(cat "$STATE/result.txt")" = failed
test "$(cat "$STATE/failure-code.txt")" = UNSUPPORTED_MODE
echo 'PASS detached worker records terminal failure for unsupported mode'
