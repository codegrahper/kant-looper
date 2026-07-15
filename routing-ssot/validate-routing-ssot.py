#!/usr/bin/env python3
"""Validate routing-ssot.yaml against routing-ssot.schema.json plus semantic rules.

Phase 1 scope: parse the `<agent_tool>|<provider>/<model_id>` route format and
preserve every existing semantic check. Phase 2 adds agent-model compatibility,
fallback safety-net, scoring weight sum, and tier cross-validation.
"""
from __future__ import annotations
import argparse, hashlib, json, sys
from pathlib import Path
import yaml
from jsonschema import Draft202012Validator, FormatChecker


def fail(msg: str) -> None:
    print(f"ERROR: {msg}", file=sys.stderr)
    raise SystemExit(1)


def parse_route_ref(ref: str) -> tuple[str, str]:
    """Split `<agent_tool>|<provider>/<model_id>` into (agent_tool, model_key).

    model_key is `provider/model_id` — the key used in the `models` dict.
    """
    if "|" not in ref or "/" not in ref:
        fail(f"route reference must be '<agent>|<provider>/<model_id>', got: {ref!r}")
    agent_part, model_part = ref.split("|", 1)
    return agent_part, model_part


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("ssot", type=Path)
    p.add_argument("schema", type=Path)
    args = p.parse_args()

    data = yaml.safe_load(args.ssot.read_text(encoding="utf-8"))
    schema = json.loads(args.schema.read_text(encoding="utf-8"))

    errors = sorted(
        Draft202012Validator(schema, format_checker=FormatChecker()).iter_errors(data),
        key=lambda e: list(e.path),
    )
    if errors:
        for e in errors:
            print(f"SCHEMA: {'/'.join(map(str,e.path))}: {e.message}", file=sys.stderr)
        raise SystemExit(1)

    providers = data["providers"]
    models = data["models"]
    tiers = set(data["task_tiers"])

    for key, model in models.items():
        if key != f'{model["provider"]}/{model["model_id"]}':
            fail(f"model key mismatch: {key}")
        if model["provider"] not in providers:
            fail(f"unknown provider for {key}")
        if not set(model["recommended_tiers"]) <= tiers:
            fail(f"unknown tier in {key}")
        if model["status"] == "deprecated":
            fail(f"deprecated model must not remain active: {key}")

    for route_name, route in data["routes"].items():
        ids = [route["primary"], *route["fallbacks"]]
        if len(ids) != len(set(ids)):
            fail(f"duplicate model in route {route_name}")
        for ref in ids:
            _agent, model_key = parse_route_ref(ref)
            if model_key not in models:
                fail(f"route {route_name} references unknown model {ref}")
            if models[model_key]["status"] in {"deprecated", "disabled"}:
                fail(f"route {route_name} uses unavailable model {ref}")
        # required_capabilities applies to the PRIMARY only. Fallbacks are
        # best-available substitutes picked from a cross-provider chain and are
        # not filtered by the primary's capability requirements (matches runtime
        # fallback-dispatcher.sh behavior, which traverses the chain without
        # capability gating).
        _p_agent, p_model_key = parse_route_ref(route["primary"])
        missing = set(route["required_capabilities"]) - set(models[p_model_key]["capabilities"])
        if missing:
            fail(f"route {route_name}: primary {route['primary']} lacks {sorted(missing)}")

    digest = hashlib.sha256(args.ssot.read_bytes()).hexdigest()
    print("VALID")
    print(f"models={len(models)} routes={len(data['routes'])}")
    print(f"sha256={digest}")


if __name__ == "__main__":
    main()
