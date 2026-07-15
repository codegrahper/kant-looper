#!/usr/bin/env python3
"""Validate routing-ssot.yaml against routing-ssot.schema.json plus semantic rules.

Phase 1: parse the `<agent_tool>|<provider>/<model_id>` route format and preserve
every original semantic check.

Phase 2: add five invariants that catch SSOT-vs-code drift automatically:
  1. agent-model compatibility — every model's agent_tool satisfies the patterns
     declared in the top-level agent_bindings section (mirrors
     kant-loop.sh::validate_agent_model_compatibility L327-368).
  2. fallback safety net — every route chain terminates with
     `claude|anthropic/claude-default` (mirrors the runtime invariant that all
     8 chains in fallback-dispatcher.sh end with claude|default).
  3. scoring weight sum — selection_policy.scoring weights sum to exactly 100.
  4. route tier overlap — each route's eligible_tiers intersects with its
     primary model's recommended_tiers.
  5. provider liveness — every provider entry has at least one model.
"""
from __future__ import annotations
import argparse, hashlib, json, re, sys
from pathlib import Path
import yaml
from jsonschema import Draft202012Validator, FormatChecker

CLAUDE_SAFETY_NET = "claude|anthropic/claude-default"


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


def check_agent_model_compatibility(models: dict, agent_bindings: dict) -> None:
    for key, model in models.items():
        tool = model.get("agent_tool")
        if not tool:
            fail(f"model {key} missing agent_tool field")
        if tool not in agent_bindings:
            fail(f"model {key}: agent_tool {tool!r} not declared in agent_bindings")
        binding = agent_bindings[tool]
        allowed = binding.get("allowed_model_patterns", [])
        denied = binding.get("denied_model_patterns", [])
        mid = model["model_id"]
        if allowed and not any(re.search(p, mid) for p in allowed):
            fail(
                f"model {key}: model_id {mid!r} does not match any allowed "
                f"pattern of agent {tool}: {allowed}"
            )
        for p in denied:
            if re.search(p, mid):
                fail(
                    f"model {key}: model_id {mid!r} matches denied pattern "
                    f"{p!r} of agent {tool}"
                )


def check_fallback_safety_net(routes: dict) -> None:
    for name, route in routes.items():
        if route.get("status") == "retired":
            continue
        chain = route["fallbacks"]
        if not chain or chain[-1] != CLAUDE_SAFETY_NET:
            fail(
                f"route {name}: fallback chain must terminate with "
                f"{CLAUDE_SAFETY_NET!r} (runtime invariant: all 8 chains in "
                f"fallback-dispatcher.sh end with claude|default); got chain={chain}"
            )


def check_scoring_weights_sum(selection_policy: dict) -> None:
    scoring = selection_policy.get("scoring")
    if not isinstance(scoring, dict):
        fail("selection_policy.scoring must be a dict of weight name -> integer")
    total = sum(scoring.values())
    if total != 100:
        fail(
            f"selection_policy.scoring weights must sum to 100, got {total} "
            f"(weights: {scoring})"
        )


def check_route_tier_overlap(routes: dict, models: dict) -> None:
    for name, route in routes.items():
        if route.get("status") == "retired":
            continue
        _agent, prim_key = parse_route_ref(route["primary"])
        prim_recommended = set(models[prim_key]["recommended_tiers"])
        eligible = set(route["eligible_tiers"])
        if not (eligible & prim_recommended):
            fail(
                f"route {name}: eligible_tiers {sorted(eligible)} has no overlap "
                f"with primary {route['primary']!r} recommended_tiers "
                f"{sorted(prim_recommended)}"
            )


def check_provider_liveness(providers: dict, models: dict) -> None:
    providers_with_models = {m["provider"] for m in models.values()}
    for provider_name in providers:
        if provider_name not in providers_with_models:
            fail(
                f"provider {provider_name!r} is declared but has no models "
                f"registered (orphan provider)"
            )


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
    agent_bindings = data["agent_bindings"]
    tiers = set(data["task_tiers"])
    routes = data["routes"]
    selection_policy = data["selection_policy"]

    for key, model in models.items():
        if key != f'{model["provider"]}/{model["model_id"]}':
            fail(f"model key mismatch: {key}")
        if model["provider"] not in providers:
            fail(f"unknown provider for {key}")
        if not set(model["recommended_tiers"]) <= tiers:
            fail(f"unknown tier in {key}")
        if model["status"] == "deprecated":
            fail(f"deprecated model must not remain active: {key}")

    for route_name, route in routes.items():
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

    check_agent_model_compatibility(models, agent_bindings)
    check_fallback_safety_net(routes)
    check_scoring_weights_sum(selection_policy)
    check_route_tier_overlap(routes, models)
    check_provider_liveness(providers, models)

    digest = hashlib.sha256(args.ssot.read_bytes()).hexdigest()
    print("VALID")
    print(f"models={len(models)} routes={len(routes)}")
    print(f"sha256={digest}")


if __name__ == "__main__":
    main()
