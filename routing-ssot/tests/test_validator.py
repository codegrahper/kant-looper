#!/usr/bin/env python3
"""Negative-case tests for routing-ssot validate-routing-ssot.py.

Each test mutates the canonical routing-ssot.yaml in memory to violate exactly
one Phase 2 invariant, runs the validator as a subprocess on the mutated copy,
and asserts:
  1. The validator exits non-zero.
  2. The error output mentions a phrase that identifies the violated rule.

This catches regressions where a validator change silently disables a check.

Run via:
    uv run --with pyyaml --with jsonschema python3 routing-ssot/tests/test_validator.py
or with pytest if available.
"""
from __future__ import annotations
import copy, subprocess, sys, tempfile, uuid
from pathlib import Path
import yaml

PKG = Path(__file__).resolve().parent.parent
CANONICAL_YAML = PKG / "routing-ssot.yaml"
CANONICAL_SCHEMA = PKG / "routing-ssot.schema.json"
VALIDATOR = PKG / "validate-routing-ssot.py"


def _load_canonical() -> dict:
    return yaml.safe_load(CANONICAL_YAML.read_text(encoding="utf-8"))


def _run_validator(data: dict) -> tuple[int, str, str]:
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = Path(tmpdir) / f"{uuid.uuid4().hex}.yaml"
        tmp.write_text(yaml.safe_dump(data, sort_keys=False, allow_unicode=True), encoding="utf-8")
        result = subprocess.run(
            [sys.executable, str(VALIDATOR), str(tmp), str(CANONICAL_SCHEMA)],
            capture_output=True,
            text=True,
        )
        return result.returncode, result.stdout, result.stderr


def _assert_rejects(data: dict, *, hint: str) -> None:
    rc, out, err = _run_validator(data)
    assert rc != 0, (
        f"validator accepted data that should be rejected (hint: {hint!r})\n"
        f"stdout: {out}\nstderr: {err}"
    )
    combined = f"{out}\n{err}"
    assert hint in combined, (
        f"expected hint {hint!r} in validator output but got:\n{combined}"
    )


def test_canonical_passes() -> None:
    rc, out, err = _run_validator(_load_canonical())
    assert rc == 0, f"canonical SSOT must pass validator; stderr:\n{err}"
    assert "VALID" in out, f"expected VALID in stdout, got: {out!r}"


def test_agent_binding_violation_wrong_tool_for_pattern() -> None:
    # gpt-5.6-sol is normally codex. Reassigning to opencode (allowed: ^glm-, ^MiniMax-)
    # should fail the allowed-pattern check.
    d = _load_canonical()
    d["models"]["openai/gpt-5.6-sol"]["agent_tool"] = "opencode"
    _assert_rejects(d, hint="does not match any allowed pattern")


def test_agent_binding_unknown_tool() -> None:
    d = _load_canonical()
    d["models"]["openai/gpt-5.6-sol"]["agent_tool"] = "nonexistent-tool"
    _assert_rejects(d, hint="not declared in agent_bindings")


def test_agent_binding_claude_denies_minimax() -> None:
    # claude's binding denies ^MiniMax-. Forcing a MiniMax model through claude
    # must trip the denied-pattern check.
    d = _load_canonical()
    d["models"]["minimax/MiniMax-M3"]["agent_tool"] = "claude"
    _assert_rejects(d, hint="denied pattern")


def test_fallback_chain_missing_safety_net() -> None:
    # tiny's chain must end with claude|anthropic/claude-default. Replacing the
    # terminator with a non-claude entry must fail.
    d = _load_canonical()
    d["routes"]["tiny"]["fallbacks"] = ["codex|openai/gpt-5.6-terra"]
    _assert_rejects(d, hint="claude|anthropic/claude-default")


def test_scoring_weights_sum_not_100() -> None:
    d = _load_canonical()
    d["selection_policy"]["scoring"]["task_fit"] = 30  # bumps sum from 100 to 110
    _assert_rejects(d, hint="sum to 100")


def test_route_tier_no_overlap_with_primary() -> None:
    # tiny primary is gpt-5.6-luna with recommended_tiers [T0, T1].
    # Forcing eligible_tiers to [T4] removes the overlap.
    d = _load_canonical()
    d["routes"]["tiny"]["eligible_tiers"] = ["T4"]
    _assert_rejects(d, hint="no overlap")


def test_provider_without_models() -> None:
    d = _load_canonical()
    d["providers"]["ghost"] = {
        "display_name": "Ghost Co",
        "official_sources": ["https://example.com"],
    }
    _assert_rejects(d, hint="no models")


def _run_all() -> int:
    tests = [(name, fn) for name, fn in sorted(globals().items()) if name.startswith("test_") and callable(fn)]
    passed = 0
    failed = []
    for name, fn in tests:
        try:
            fn()
            print(f"PASS  {name}")
            passed += 1
        except AssertionError as e:
            print(f"FAIL  {name}: {e}")
            failed.append(name)
    print(f"\n{passed}/{len(tests)} tests passed")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(_run_all())
