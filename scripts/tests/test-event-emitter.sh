#!/usr/bin/env bash
# test-event-emitter.sh — completion event contract

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
EMITTER="$ROOT/scripts/event/emit-event.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

pass=0
fail=0

check() {
  local name="$1"
  shift
  if "$@"; then
    printf 'PASS %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL %s\n' "$name" >&2
    fail=$((fail + 1))
  fi
}

STATE="$TMP_ROOT/state/run-a"
EVENTS="$TMP_ROOT/events"
mkdir -p "$STATE"
printf 'run-a\n' > "$STATE/run-id.txt"
printf 'pass_no_commit\n' > "$STATE/result.txt"
printf 'agent/test\n' > "$STATE/branch.txt"
printf '/tmp/worktree-a\n' > "$STATE/worktree.txt"
printf '# report\n' > "$STATE/report.md"

"$EMITTER" emit \
  --state-dir "$STATE" \
  --event-root "$EVENTS" \
  --workflow-id static-grok-opencode-codex \
  --step-id implement \
  --agent grok \
  --model grok-4.5 \
  --phase implement

EVENT="$EVENTS/pending/evt-run-a.json"
check 'writes one pending event' test -f "$EVENT"
check 'event JSON contains terminal source state' python3 - "$EVENT" <<'PY'
import json
import sys

event = json.load(open(sys.argv[1]))
assert event['event_type'] == 'agent.completed'
assert event['status'] == 'success'
assert event['workflow_id'] == 'static-grok-opencode-codex'
assert event['source'] == {'agent': 'grok', 'model': 'grok-4.5', 'phase': 'implement'}
assert event['artifacts']['worktree'] == '/tmp/worktree-a'
PY

"$EMITTER" emit \
  --state-dir "$STATE" \
  --event-root "$EVENTS" \
  --workflow-id static-grok-opencode-codex \
  --step-id implement \
  --agent grok \
  --model grok-4.5 \
  --phase implement
check 'does not overwrite duplicate event ID' test "$(find "$EVENTS/pending" -name '*.json' | wc -l | tr -d ' ')" = '1'

printf 'failed\n' > "$STATE/result.txt"
printf 'run-b\n' > "$STATE/run-id.txt"
"$EMITTER" emit \
  --state-dir "$STATE" \
  --event-root "$EVENTS" \
  --workflow-id static-grok-opencode-codex \
  --step-id implement \
  --agent grok \
  --model grok-4.5 \
  --phase implement
check 'represents a failed terminal run' python3 - "$EVENTS/pending/evt-run-b.json" <<'PY'
import json
import sys

assert json.load(open(sys.argv[1]))['status'] == 'failed'
PY

printf '\n%d passed, %d failed\n' "$pass" "$fail"
test "$fail" -eq 0
