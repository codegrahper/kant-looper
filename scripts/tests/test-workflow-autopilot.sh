#!/usr/bin/env bash

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUPERVISOR="$ROOT/scripts/event/supervisor.py"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

EVENTS="$TMP_ROOT/events"
DB="$TMP_ROOT/tasks.sqlite3"
REPO="$TMP_ROOT/repo"
WORKTREE="$TMP_ROOT/worktree"
CONFIG="$TMP_ROOT/workflows.json"
ARGS="$TMP_ROOT/dispatches.txt"
mkdir -p "$EVENTS/pending" "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.invalid
git -C "$REPO" config user.name test
git -C "$REPO" commit --allow-empty -qm initial
git -C "$REPO" worktree add -q -b autopilot "$WORKTREE"
printf 'workflow change\n' > "$WORKTREE/changed.txt"

python3 - "$CONFIG" <<'PY'
import json
import sys

json.dump({"schema_version": 1, "workflows": {"ui-flow": {"max_attempts": 2, "steps": [
    {"id": "design", "agent": "agy", "model": "gemini-3.5-flash", "phase": "implement"},
    {"id": "tests", "agent": "agy", "model": "gemini-3.5-flash", "phase": "implement"},
    {"id": "final", "agent": "codex", "model": "gpt-5.6-sol", "phase": "review"},
]}}}, open(sys.argv[1], "w"))
PY

make_state() {
  local run_id="$1"
  local state="$TMP_ROOT/state/$run_id"
  mkdir -p "$state"
  printf '%s\n' "$run_id" > "$state/run-id.txt"
  printf 'pass_no_commit\n' > "$state/result.txt"
  printf '%s\n' "$WORKTREE" > "$state/worktree.txt"
  printf '# %s\n\n## Goal\nContinue workflow\n' "$run_id" > "$state/task.md"
  : > "$state/detached.log"
  : > "$state/phase-events.log"
  printf '%s\n' "$state"
}

ROOT_STATE="$(make_state root)"
python3 - "$EVENTS/pending/root.json" "$ROOT_STATE" "$WORKTREE" <<'PY'
import json
import sys

path, state_dir, workspace = sys.argv[1:]
json.dump({
    "schema_version": 1,
    "event_id": "evt-root",
    "event_type": "agent.completed",
    "workflow_id": "ui-flow",
    "run_id": "root",
    "step_id": "design",
    "source": {"agent": "agy", "model": "gemini-3.5-flash", "phase": "implement"},
    "status": "success",
    "artifacts": {"state_dir": state_dir, "result_file": state_dir + "/result.txt", "report_file": state_dir + "/report.md", "worktree": workspace, "branch": "autopilot"},
    "attempt": 0,
    "max_attempts": 2,
}, open(path, "w"))
PY

STUB="$TMP_ROOT/kant-loop-stub.sh"
cat > "$STUB" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$@" >> "$KANT_TEST_ARGS"
step=""
worktree=""
while [ $# -gt 0 ]; do
  case "$1" in
    --step) step="$2"; shift ;;
    --existing-worktree) worktree="$2"; shift ;;
  esac
  shift
done
case "$step" in
  tests) next="final"; run_id="tests-run"; agent="agy"; model="gemini-3.5-flash"; phase="implement" ;;
  final) next=""; run_id="final-run"; agent="codex"; model="gpt-5.6-sol"; phase="review" ;;
  *) exit 2 ;;
esac
state="$KANT_TEST_ROOT/state/$run_id"
mkdir -p "$state"
printf '%s\n' "$run_id" > "$state/run-id.txt"
printf 'pass_no_commit\n' > "$state/result.txt"
printf '%s\n' "$worktree" > "$state/worktree.txt"
printf '# %s\n\n## Goal\nContinue workflow\n' "$run_id" > "$state/task.md"
: > "$state/detached.log"
: > "$state/phase-events.log"
python3 - "$KANT_TEST_EVENTS/pending/$run_id.json" "$state" "$worktree" "$run_id" "$step" "$agent" "$model" "$phase" <<'PY'
import json
import sys

path, state_dir, workspace, run_id, step, agent, model, phase = sys.argv[1:]
json.dump({
    "schema_version": 1,
    "event_id": "evt-" + run_id,
    "event_type": "agent.completed",
    "workflow_id": "ui-flow",
    "run_id": run_id,
    "step_id": step,
    "source": {"agent": agent, "model": model, "phase": phase},
    "status": "success",
    "artifacts": {"state_dir": state_dir, "result_file": state_dir + "/result.txt", "report_file": state_dir + "/report.md", "worktree": workspace, "branch": "autopilot"},
    "attempt": 0,
    "max_attempts": 2,
}, open(path, "w"))
PY
EOF
chmod +x "$STUB"

KANT_TEST_ARGS="$ARGS" KANT_TEST_ROOT="$TMP_ROOT" KANT_TEST_EVENTS="$EVENTS" \
  python3 "$SUPERVISOR" --event-root "$EVENTS" --workflow-file "$CONFIG" --repo "$REPO" --db "$DB" --kant-loop "$STUB" --max-events 3

grep -Fx -- 'agy' "$ARGS" >/dev/null
grep -Fx -- 'codex' "$ARGS" >/dev/null
test "$(grep -Fc -- '--step' "$ARGS")" = '2'
python3 - "$DB" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    rows = connection.execute("SELECT status FROM tasks ORDER BY task_id").fetchall()
assert rows == [("PASSED",), ("PASSED",), ("PASSED",)]
PY
echo 'PASS supervisor automatically verifies and routes a configured quick workflow'
