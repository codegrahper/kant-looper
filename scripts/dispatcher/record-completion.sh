#!/usr/bin/env bash

set -Eeuo pipefail

STATE_DIR="$1"
DB_PATH="$2"
DISPATCHER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_EVENT="$(mktemp "${TMPDIR:-/tmp}/kant-completion.XXXXXX.json")"
trap 'rm -f "$TMP_EVENT"' EXIT

python3 - "$STATE_DIR" "$TMP_EVENT" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

state_dir = Path(sys.argv[1])
output = Path(sys.argv[2])

def read(name: str) -> str:
    path = state_dir / name
    return path.read_text(encoding="utf-8").strip() if path.exists() else ""

run_id = read("run-id.txt")
agent = read("event-agent.txt") or "unknown"
model = read("event-model.txt") or "default"
result = read("result.txt")
failure = read("failure-code.txt")
worktree = read("worktree.txt")
if not run_id or not result or not worktree:
    raise SystemExit("missing terminal state")
payload = {
    "event": "task.completed",
    "task_id": os.environ.get("KANT_DISPATCH_TASK_ID", run_id),
    "agent": agent,
    "attempt": int(os.environ.get("KANT_DISPATCH_ATTEMPT", "1")),
    "exit_code": 0 if result in {"completed", "pass", "pass_no_commit"} else 1,
    "stop_reason": failure or result,
    "result_file": str(state_dir / "result.txt"),
    "stdout_file": str(state_dir / "detached.log"),
    "stderr_file": str(state_dir / "phase-events.log"),
    "task_file": str(state_dir / "task.md"),
    "model": model,
    "workspace": worktree,
    "timestamp": datetime.now(timezone.utc).isoformat(),
}
output.write_text(json.dumps(payload), encoding="utf-8")
PY
python3 "$DISPATCHER_DIR/dispatcher.py" receive --db "$DB_PATH" --event-file "$TMP_EVENT"
