#!/usr/bin/env bash
# test-dispatcher-store.sh — completion event persistence contract

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
DISPATCHER="$ROOT/scripts/dispatcher/dispatcher.py"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

DB="$TMP_ROOT/tasks.sqlite3"
EVENT="$TMP_ROOT/completion.json"
cat > "$EVENT" <<'JSON'
{
  "event": "task.completed",
  "task_id": "task-001",
  "agent": "grok",
  "attempt": 1,
  "exit_code": 0,
  "stop_reason": "Cancelled",
  "result_file": "/tmp/result.json",
  "stdout_file": "/tmp/stdout.log",
  "stderr_file": "/tmp/stderr.log",
  "task_file": "/tmp/task.md",
  "model": "grok-4.5",
  "workspace": "/tmp/worktree",
  "timestamp": "2026-07-17T15:30:00+09:00"
}
JSON

python3 "$DISPATCHER" receive --db "$DB" --event-file "$EVENT"
python3 "$DISPATCHER" receive --db "$DB" --event-file "$EVENT"
python3 - "$DB" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    task = connection.execute(
        'SELECT status, assigned_agent, retry_count FROM tasks WHERE task_id = ?', ('task-001',)
    ).fetchone()
    events = connection.execute('SELECT COUNT(*) FROM task_events').fetchone()[0]
assert task == ('COMPLETED', 'grok', 0)
assert events == 2
PY
echo 'PASS completion is recorded once and duplicate is ignored'

WORKSPACE="$TMP_ROOT/workspace"
mkdir -p "$WORKSPACE"
git -C "$WORKSPACE" init -q
git -C "$WORKSPACE" config user.email test@example.invalid
git -C "$WORKSPACE" config user.name test
git -C "$WORKSPACE" commit --allow-empty -qm initial
printf 'verified change\n' > "$WORKSPACE/changed.txt"
python3 - "$EVENT" "$WORKSPACE" <<'PY'
import json
import sys

path, workspace = sys.argv[1:]
event = json.load(open(path))
event['task_id'] = 'task-002'
event['workspace'] = workspace
with open(path, 'w') as handle:
    json.dump(event, handle)
PY
python3 "$DISPATCHER" receive --db "$DB" --event-file "$EVENT"
python3 "$DISPATCHER" verify --db "$DB" --task-id task-002
python3 - "$DB" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    status = connection.execute('SELECT status FROM tasks WHERE task_id = ?', ('task-002',)).fetchone()[0]
assert status == 'PASSED'
PY
echo 'PASS cancelled worker with a valid diff is dispatcher-verified'

EMPTY_WORKSPACE="$TMP_ROOT/empty-workspace"
mkdir -p "$EMPTY_WORKSPACE"
git -C "$EMPTY_WORKSPACE" init -q
git -C "$EMPTY_WORKSPACE" config user.email test@example.invalid
git -C "$EMPTY_WORKSPACE" config user.name test
git -C "$EMPTY_WORKSPACE" commit --allow-empty -qm initial
python3 - "$EVENT" "$EMPTY_WORKSPACE" <<'PY'
import json
import sys

path, workspace = sys.argv[1:]
event = json.load(open(path))
event['task_id'] = 'task-002-empty'
event['workspace'] = workspace
with open(path, 'w') as handle:
    json.dump(event, handle)
PY
python3 "$DISPATCHER" receive --db "$DB" --event-file "$EVENT"
python3 "$DISPATCHER" verify --db "$DB" --task-id task-002-empty
python3 - "$DB" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    status = connection.execute('SELECT status FROM tasks WHERE task_id = ?', ('task-002-empty',)).fetchone()[0]
assert status == 'RETRY_REQUIRED'
PY
echo 'PASS cancelled worker without changes requires retry'

STATE_DIR="$TMP_ROOT/state/task-003"
mkdir -p "$STATE_DIR"
printf 'task-003\n' > "$STATE_DIR/run-id.txt"
printf 'grok\n' > "$STATE_DIR/event-agent.txt"
printf 'pass_no_commit\n' > "$STATE_DIR/result.txt"
printf '%s\n' "$WORKSPACE" > "$STATE_DIR/worktree.txt"
"$ROOT/scripts/dispatcher/record-completion.sh" "$STATE_DIR" "$DB"
python3 - "$DB" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    status = connection.execute('SELECT status FROM tasks WHERE task_id = ?', ('task-003',)).fetchone()[0]
assert status == 'COMPLETED'
PY
echo 'PASS terminal state bridge records a completion envelope'

RETRY_STUB="$TMP_ROOT/kant-loop-stub.sh"
RETRY_ARGS="$TMP_ROOT/retry-args.txt"
cat > "$RETRY_STUB" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$KANT_RETRY_ARGS"
EOF
chmod +x "$RETRY_STUB"
KANT_RETRY_ARGS="$RETRY_ARGS" python3 "$DISPATCHER" retry --db "$DB" --task-id task-002-empty --kant-loop "$RETRY_STUB"
grep -Fx -- '--agent' "$RETRY_ARGS" >/dev/null
grep -Fx -- 'grok' "$RETRY_ARGS" >/dev/null
grep -Fx -- '--model' "$RETRY_ARGS" >/dev/null
grep -Fx -- 'grok-4.5' "$RETRY_ARGS" >/dev/null
grep -Fx -- '--existing-worktree' "$RETRY_ARGS" >/dev/null
grep -Fx -- "$EMPTY_WORKSPACE" "$RETRY_ARGS" >/dev/null
python3 - "$DB" <<'PY'
import sqlite3
import sys

with sqlite3.connect(sys.argv[1]) as connection:
    row = connection.execute('SELECT status, retry_count FROM tasks WHERE task_id = ?', ('task-002-empty',)).fetchone()
assert row == ('RUNNING', 1)
PY
echo 'PASS retry dispatches the same worker with bounded attempt state'
