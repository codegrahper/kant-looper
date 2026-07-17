#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
STARTER="$ROOT/scripts/event/start-workflow.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

REPO="$TMP_ROOT/repo"
STATE_ROOT="$TMP_ROOT/state"
CONFIG="$TMP_ROOT/workflows.json"
ARGS="$TMP_ROOT/root-args.txt"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name test
git -C "$REPO" commit --allow-empty -qm initial
printf '# UI task\n\n## Goal\nCreate a UI\n' > "$TMP_ROOT/task.md"
python3 - "$CONFIG" <<'PY'
import json
import sys

json.dump({"schema_version": 1, "workflows": {"ui-flow": {"max_attempts": 2, "steps": [
    {"id": "design", "agent": "agy", "model": "gemini-3.5-flash", "phase": "implement"},
]}}}, open(sys.argv[1], "w"))
PY

STUB="$TMP_ROOT/kant-loop-stub.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$KANT_TEST_ARGS"
EOF
chmod +x "$STUB"

start_output="$(KANT_STATE_ROOT="$STATE_ROOT" KANT_LOOP_BIN="$STUB" KANT_TEST_ARGS="$ARGS" \
  "$STARTER" "$TMP_ROOT/task.md" --workflow ui-flow --workflow-file "$CONFIG" --repo "$REPO")"
supervisor_pid="$(printf '%s\n' "$start_output" | awk -F': ' '/^supervisor_pid:/{print $2}')"

grep -Fx -- 'run' "$ARGS" >/dev/null
grep -Fx -- '--agent' "$ARGS" >/dev/null
grep -Fx -- 'agy' "$ARGS" >/dev/null
grep -Fx -- '--workflow' "$ARGS" >/dev/null
test -n "$supervisor_pid"
kill -0 "$supervisor_pid"
kill "$supervisor_pid" 2>/dev/null || true
echo 'PASS workflow start launches supervisor and root quick call'
