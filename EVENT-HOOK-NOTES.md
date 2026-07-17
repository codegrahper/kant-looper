# Event hook notes

## Verified insertion points

- `fail_run()` writes `result.txt=failed`; it is the terminal failure hook.
- `do_commit()` writes `result.txt=completed`; it is the committed-success hook.
- `run_quick_mode()`, `run_quick_chain()`, and `run_parallel_mode()` write
  `result.txt=pass_no_commit`; they are non-commit success hooks.
- `cmd_run()` creates the state directory, run ID, branch, and isolated
  worktree before either synchronous or detached execution.
- `--detach` calls `_run_mode` through `nohup`; its child inherits the
  workflow metadata stored in the state directory.

## POC boundary

- Event emission is opt-in: `--workflow <id> --step <id>`. Every quick agent
  uses this same terminal hook, so configured `agy`, `grok`, `opencode`,
  `claude`, and `codex` calls all notify the dispatcher through the spool.
- Events live at `$KANT_STATE_ROOT/events`, outside each run directory.
- The emitter writes a temporary JSON file and atomically links it into
  `events/pending`; an existing event ID is never overwritten.
- The Supervisor accepts only configured workflow IDs, steps, agents, and
  models. It uses argv-based `subprocess.run`, never shell commands.
- A successor reuses the source run's registered non-primary worktree and
  remains subject to kant-loop's existing safety and gate checks.
- `kant-loop.sh workflow start TASK.md --workflow ID` starts the resident
  supervisor and the configured first quick step together. The supervisor
  records each terminal event, performs deterministic dispatcher verification,
  and only then routes the next configured step.
