#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import os
import sqlite3
import subprocess
import sys
import tempfile
from dataclasses import asdict, dataclass
from pathlib import Path


@dataclass(frozen=True, slots=True)
class Completion:
    task_id: str
    agent: str
    attempt: int
    exit_code: int
    stop_reason: str
    result_file: str
    stdout_file: str
    stderr_file: str
    task_file: str
    model: str
    workspace: str
    timestamp: str


class CompletionError(Exception):
    pass


def text(raw: object, name: str) -> str:
    if not isinstance(raw, str) or not raw or len(raw) > 4096:
        raise CompletionError(f"invalid {name}")
    return raw


def integer(raw: object, name: str) -> int:
    if not isinstance(raw, int) or isinstance(raw, bool) or raw < 0:
        raise CompletionError(f"invalid {name}")
    return raw


def parse_completion(path: Path) -> Completion:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise CompletionError("invalid completion envelope") from error
    if not isinstance(raw, dict) or raw.get("event") != "task.completed":
        raise CompletionError("unsupported event")
    return Completion(
        task_id=text(raw.get("task_id"), "task_id"),
        agent=text(raw.get("agent"), "agent"),
        attempt=integer(raw.get("attempt"), "attempt"),
        exit_code=integer(raw.get("exit_code"), "exit_code"),
        stop_reason=text(raw.get("stop_reason"), "stop_reason"),
        result_file=text(raw.get("result_file"), "result_file"),
        stdout_file=text(raw.get("stdout_file"), "stdout_file"),
        stderr_file=text(raw.get("stderr_file"), "stderr_file"),
        task_file=text(raw.get("task_file"), "task_file"),
        model=text(raw.get("model"), "model"),
        workspace=text(raw.get("workspace"), "workspace"),
        timestamp=text(raw.get("timestamp"), "timestamp"),
    )


def initialize(connection: sqlite3.Connection) -> None:
    connection.executescript("""
    CREATE TABLE IF NOT EXISTS tasks (
      task_id TEXT PRIMARY KEY,
      parent_task_id TEXT,
      assigned_agent TEXT NOT NULL,
      status TEXT NOT NULL,
      instruction TEXT NOT NULL DEFAULT '',
      workspace TEXT NOT NULL,
      created_at TEXT NOT NULL,
      started_at TEXT,
      completed_at TEXT,
      exit_code INTEGER,
      result_path TEXT,
      callback_status TEXT,
      retry_count INTEGER NOT NULL DEFAULT 0
    );
    CREATE TABLE IF NOT EXISTS task_events (
      event_key TEXT PRIMARY KEY,
      task_id TEXT NOT NULL,
      event_type TEXT NOT NULL,
      payload TEXT NOT NULL,
      created_at TEXT NOT NULL
    );
    CREATE TABLE IF NOT EXISTS task_artifacts (
      task_id TEXT NOT NULL,
      attempt INTEGER NOT NULL,
      artifact_type TEXT NOT NULL,
      path TEXT NOT NULL,
      PRIMARY KEY(task_id, attempt, artifact_type)
    );
    CREATE TABLE IF NOT EXISTS task_attempts (
      task_id TEXT NOT NULL,
      attempt INTEGER NOT NULL,
      agent TEXT NOT NULL,
      status TEXT NOT NULL,
      exit_code INTEGER,
      stop_reason TEXT,
      started_at TEXT,
      completed_at TEXT,
      PRIMARY KEY(task_id, attempt)
    );
    """)


def receive(connection: sqlite3.Connection, completion: Completion) -> bool:
    key = f"{completion.task_id}:{completion.attempt}:task.completed"
    payload = json.dumps(asdict(completion), sort_keys=True)
    try:
        connection.execute(
            "INSERT INTO task_events(event_key, task_id, event_type, payload, created_at) VALUES (?, ?, ?, ?, ?)",
            (key, completion.task_id, "COMPLETION_RECEIVED", payload, completion.timestamp),
        )
    except sqlite3.IntegrityError:
        connection.execute(
            "INSERT OR IGNORE INTO task_events(event_key, task_id, event_type, payload, created_at) VALUES (?, ?, ?, ?, ?)",
            (f"{key}:duplicate", completion.task_id, "DUPLICATE_IGNORED", payload, completion.timestamp),
        )
        return False
    connection.execute(
        """INSERT INTO tasks(task_id, assigned_agent, status, workspace, created_at, started_at, completed_at, exit_code, result_path, callback_status)
           VALUES (?, ?, 'COMPLETED', ?, ?, ?, ?, ?, ?, 'received')
           ON CONFLICT(task_id) DO UPDATE SET status='COMPLETED', completed_at=excluded.completed_at,
             exit_code=excluded.exit_code, result_path=excluded.result_path, callback_status='received'""",
        (completion.task_id, completion.agent, completion.workspace, completion.timestamp, completion.timestamp,
         completion.timestamp, completion.exit_code, completion.result_file),
    )
    connection.execute(
        """INSERT INTO task_attempts(task_id, attempt, agent, status, exit_code, stop_reason, started_at, completed_at)
           VALUES (?, ?, ?, 'COMPLETED', ?, ?, ?, ?)
           ON CONFLICT(task_id, attempt) DO UPDATE SET status='COMPLETED', exit_code=excluded.exit_code,
             stop_reason=excluded.stop_reason, completed_at=excluded.completed_at""",
        (completion.task_id, completion.attempt, completion.agent, completion.exit_code, completion.stop_reason,
         completion.timestamp, completion.timestamp),
    )
    for artifact_type, artifact_path in (("result", completion.result_file), ("stdout", completion.stdout_file), ("stderr", completion.stderr_file), ("task", completion.task_file), ("model", completion.model)):
        connection.execute(
            "INSERT OR REPLACE INTO task_artifacts(task_id, attempt, artifact_type, path) VALUES (?, ?, ?, ?)",
            (completion.task_id, completion.attempt, artifact_type, artifact_path),
        )
    return True


def run_command(argv: list[str], workspace: Path) -> bool:
    completed = subprocess.run(argv, cwd=workspace, check=False, capture_output=True, text=True, timeout=120)
    return completed.returncode == 0


def verify(connection: sqlite3.Connection, task_id: str) -> str:
    row = connection.execute("SELECT workspace FROM tasks WHERE task_id = ?", (task_id,)).fetchone()
    if row is None:
        raise CompletionError("unknown task")
    workspace = Path(row[0])
    changed = subprocess.run(
        ["git", "status", "--porcelain"], cwd=workspace, check=False, capture_output=True, text=True, timeout=30,
    )
    scripts = Path(__file__).parents[1]
    safety = scripts / "lib" / "safety-check.sh"
    gates = scripts / "lib" / "gate-runner.sh"
    with tempfile.TemporaryDirectory(prefix="kant-dispatch-gates-") as output_dir:
        passed = (
            changed.returncode == 0
            and bool(changed.stdout.strip())
            and run_command(["git", "diff", "--check"], workspace)
            and run_command([str(safety), "all", str(workspace)], workspace)
            and run_command([str(gates), "run", str(workspace), output_dir], workspace)
        )
    status = "PASSED" if passed else "RETRY_REQUIRED"
    event = "VERIFICATION_PASSED" if passed else "VERIFICATION_FAILED"
    connection.execute("UPDATE tasks SET status = ?, callback_status = ? WHERE task_id = ?", (status, event, task_id))
    connection.execute(
        "INSERT OR IGNORE INTO task_events(event_key, task_id, event_type, payload, created_at) VALUES (?, ?, ?, ?, datetime('now'))",
        (f"{task_id}:verify:1", task_id, event, json.dumps({"workspace": str(workspace), "status": status})),
    )
    return status


def artifact(connection: sqlite3.Connection, task_id: str, artifact_type: str) -> str:
    row = connection.execute(
        "SELECT path FROM task_artifacts WHERE task_id = ? AND artifact_type = ? ORDER BY attempt DESC LIMIT 1",
        (task_id, artifact_type),
    ).fetchone()
    if row is None:
        raise CompletionError(f"missing {artifact_type} artifact")
    return str(row[0])


def retry(connection: sqlite3.Connection, task_id: str, kant_loop: Path, database: Path) -> None:
    row = connection.execute(
        "SELECT assigned_agent, workspace, status, retry_count FROM tasks WHERE task_id = ?", (task_id,)
    ).fetchone()
    if row is None or row[2] != "RETRY_REQUIRED" or int(row[3]) >= 2:
        raise CompletionError("task is not retryable")
    task_file = artifact(connection, task_id, "task")
    model = artifact(connection, task_id, "model")
    environment = dict(os.environ)
    environment["KANT_DISPATCH_DB"] = str(database)
    environment["KANT_DISPATCH_TASK_ID"] = task_id
    environment["KANT_DISPATCH_ATTEMPT"] = str(int(row[3]) + 2)
    completed = subprocess.run(
        [str(kant_loop), "run", task_file, "--quick", "--agent", str(row[0]), "--model", model,
         "--existing-worktree", str(row[1]), "--no-auto-commit", "--detach"],
        cwd=Path(str(row[1])), env=environment, check=False, capture_output=True, text=True, timeout=60,
    )
    if completed.returncode != 0:
        raise CompletionError("retry dispatch failed")
    connection.execute(
        "UPDATE tasks SET status='RUNNING', retry_count=retry_count+1, callback_status='RETRY_REQUESTED' WHERE task_id = ?",
        (task_id,),
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    subcommands = parser.add_subparsers(dest="command", required=True)
    receive_parser = subcommands.add_parser("receive")
    receive_parser.add_argument("--db", type=Path, required=True)
    receive_parser.add_argument("--event-file", type=Path, required=True)
    verify_parser = subcommands.add_parser("verify")
    verify_parser.add_argument("--db", type=Path, required=True)
    verify_parser.add_argument("--task-id", required=True)
    retry_parser = subcommands.add_parser("retry")
    retry_parser.add_argument("--db", type=Path, required=True)
    retry_parser.add_argument("--task-id", required=True)
    retry_parser.add_argument("--kant-loop", type=Path, required=True)
    args = parser.parse_args()
    args.db.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(args.db) as connection:
        initialize(connection)
        if args.command == "receive":
            completion = parse_completion(args.event_file)
            accepted = receive(connection, completion)
            print("accepted" if accepted else "duplicate_ignored")
        elif args.command == "verify":
            print(verify(connection, args.task_id))
        else:
            retry(connection, args.task_id, args.kant_loop, args.db)
            print("RETRY_DISPATCHED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
