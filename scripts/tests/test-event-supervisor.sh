#!/usr/bin/env bash
# test-event-supervisor.sh — event claim and recovery contract

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUPERVISOR="$ROOT/scripts/event/supervisor.py"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

EVENTS="$TMP_ROOT/events"
CONFIG="$ROOT/config/dispatch-routes.json"
REPO="$TMP_ROOT/repo"
mkdir -p "$EVENTS/pending" "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name test
git -C "$REPO" commit --allow-empty -qm initial
git -C "$REPO" worktree add -q -b event-review "$TMP_ROOT/review-worktree"
printf 'verified change\n' > "$TMP_ROOT/review-worktree/changed.txt"

write_event() {
  local name="$1" status="$2" step="$3" directory="$4"
  local state="$TMP_ROOT/state/$name"
  mkdir -p "$state"
  printf '%s\n' "$name" > "$state/run-id.txt"
  printf 'pass_no_commit\n' > "$state/result.txt"
  printf '%s\n' "$TMP_ROOT/review-worktree" > "$state/worktree.txt"
  printf '# %s\n\n## Goal\nReview workflow\n' "$name" > "$state/task.md"
  : > "$state/detached.log"
  : > "$state/phase-events.log"
  python3 - "$directory/$name.json" "$name" "$status" "$step" "$TMP_ROOT/review-worktree" "$state" <<'PY'
import json
import sys

path, event_id, status, step_id, worktree, state_dir = sys.argv[1:]
with open(path, 'w') as handle:
    json.dump({
        'schema_version': 1,
        'event_id': event_id,
        'event_type': 'agent.completed',
        'workflow_id': 'static-grok-opencode-codex',
        'run_id': event_id.removeprefix('evt-'),
        'step_id': step_id,
        'source': {'agent': 'grok', 'model': 'grok-4.5', 'phase': 'implement'},
        'status': status,
        'artifacts': {'state_dir': state_dir, 'result_file': state_dir + '/result.txt', 'report_file': state_dir + '/report.md', 'worktree': worktree, 'branch': 'event-review'},
        'attempt': 0,
        'max_attempts': 2,
    }, handle)
PY
}

write_event evt-success success implement "$EVENTS/pending"
python3 "$SUPERVISOR" --once --dry-run --event-root "$EVENTS" --workflow-file "$CONFIG" --repo "$REPO"
test -f "$EVENTS/completed/evt-success.json"
echo 'PASS dry-run claims and completes configured success event'

git -C "$TMP_ROOT/review-worktree" reset --hard -q
git -C "$TMP_ROOT/review-worktree" clean -fdq
write_event evt-failed failed implement "$EVENTS/pending"
python3 "$SUPERVISOR" --once --dry-run --event-root "$EVENTS" --workflow-file "$CONFIG" --repo "$REPO"
test -f "$EVENTS/failed/evt-failed.json"
echo 'PASS failed source does not dispatch successor'

printf 'verified change\n' > "$TMP_ROOT/review-worktree/changed.txt"
write_event evt-stale success implement "$EVENTS/processing"
touch -t 202001010000 "$EVENTS/processing/evt-stale.json"
python3 "$SUPERVISOR" --once --dry-run --recovery-seconds 1 --event-root "$EVENTS" --workflow-file "$CONFIG" --repo "$REPO"
test -f "$EVENTS/completed/evt-stale.json"
echo 'PASS stale processing event is recovered once'

STUB="$TMP_ROOT/kant-loop-stub.sh"
ARGS="$TMP_ROOT/dispatch-args.txt"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$KANT_TEST_ARGS"
EOF
chmod +x "$STUB"
write_event evt-dispatch success implement "$EVENTS/pending"
KANT_TEST_ARGS="$ARGS" python3 "$SUPERVISOR" --once --event-root "$EVENTS" --workflow-file "$CONFIG" --repo "$REPO" --kant-loop "$STUB"
test -f "$EVENTS/completed/evt-dispatch.json"
grep -Fx -- '--agent' "$ARGS" >/dev/null
grep -Fx -- 'opencode' "$ARGS" >/dev/null
grep -Fx -- '--model' "$ARGS" >/dev/null
grep -Fx -- 'glm-5.2' "$ARGS" >/dev/null
grep -Fx -- '--role' "$ARGS" >/dev/null
grep -Fx -- 'review' "$ARGS" >/dev/null
grep -Fx -- '--existing-worktree' "$ARGS" >/dev/null
grep -Fx -- "$TMP_ROOT/review-worktree" "$ARGS" >/dev/null
echo 'PASS dispatch uses configured argv and read-only review role'
