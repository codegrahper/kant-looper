#!/usr/bin/env python3
"""
SSOT Loader - routing-ssot.json을 로드하고 쿼리하는 런타임 모듈.

routing-ssot.json은 validate-routing-ssot.py가 검증 통과 시 자동 생성한다.
이 로더는 런타임에 pyyaml을 필요로 하지 않는다 (표준 라이브러리만 사용).

Subcommands:
  route-for-task: intent + complexity → SSOT route + primary
  chain-for-route: route_name → full fallback chain
  health: SSOT 파일 유효성 + sha256 체크
"""

import argparse
import json
import sys
import hashlib
from pathlib import Path
from typing import Dict, Any

CODE_TO_SSOT = {
    "tiny": "tiny",
    "standard": "standard_repo",
    "standard_repo": "standard_repo",
    "hard": "hard_repo",
    "hard_repo": "hard_repo",
    "huge": "huge_context",
    "huge_context": "huge_context",
    "visual": "visual_browser",
    "visual_browser": "visual_browser",
    "review": "review",
}

SSOT_DIR = Path(__file__).parent.parent.parent / "routing-ssot"
JSON_PATH = SSOT_DIR / "routing-ssot.json"
YAML_PATH = SSOT_DIR / "routing-ssot.yaml"
SCHEMA_PATH = SSOT_DIR / "routing-ssot.schema.json"


def compute_sha256(filepath: Path) -> str:
    sha256_hash = hashlib.sha256()
    with open(filepath, "rb") as f:
        for chunk in iter(lambda: f.read(4096), b""):
            sha256_hash.update(chunk)
    return sha256_hash.hexdigest()


def load_ssot() -> Dict[str, Any]:
    if not JSON_PATH.exists():
        return {"error": f"SSOT JSON not found: {JSON_PATH}. Run validate-routing-ssot.py first."}

    with open(JSON_PATH, "r", encoding="utf-8") as f:
        return json.load(f)


def route_for_task(args: argparse.Namespace) -> None:
    """Query SSOT: intent + complexity → route + primary model."""
    ssot = load_ssot()
    if "error" in ssot:
        print(json.dumps({"error": ssot["error"]}))
        sys.exit(1)

    intent = args.intent
    complexity = args.complexity

    # 코드 라우트 → SSOT 라우트 변환
    code_route = complexity
    ssot_route = CODE_TO_SSOT.get(code_route, code_route)

    routes = ssot.get("routes", {})
    if ssot_route not in routes:
        print(json.dumps({"error": f"Route not found: {ssot_route}"}))
        sys.exit(1)

    route = routes[ssot_route]
    primary = route.get("primary")
    fallbacks = route.get("fallbacks", [])

    if not primary:
        print(json.dumps({"error": f"Route has no primary: {ssot_route}"}))
        sys.exit(1)

    result = {
        "code_route": code_route,
        "ssot_route": ssot_route,
        "primary": primary,
        "fallbacks": fallbacks,
        "total_fallbacks": len(fallbacks),
    }

    print(json.dumps(result, ensure_ascii=False))


def chain_for_route(args: argparse.Namespace) -> None:
    """Query SSOT: route → full fallback chain."""
    ssot = load_ssot()
    if "error" in ssot:
        print(json.dumps({"error": ssot["error"]}))
        sys.exit(1)

    ssot_route = CODE_TO_SSOT.get(args.route, args.route)
    routes = ssot.get("routes", {})

    if ssot_route not in routes:
        print(json.dumps({"error": f"Route not found: {ssot_route}"}))
        sys.exit(1)

    route = routes[ssot_route]
    primary = route.get("primary")
    fallbacks = route.get("fallbacks", [])

    # Build full chain: primary → fallbacks
    chain = [primary] + fallbacks if primary else fallbacks

    result = {
        "route": ssot_route,
        "chain": chain,
        "chain_length": len(chain),
    }

    print(json.dumps(result, ensure_ascii=False))


def health(args: argparse.Namespace) -> None:
    result = {
        "json_path": str(JSON_PATH),
        "json_exists": JSON_PATH.exists(),
        "yaml_path": str(YAML_PATH),
        "yaml_exists": YAML_PATH.exists(),
        "schema_path": str(SCHEMA_PATH),
        "schema_exists": SCHEMA_PATH.exists(),
    }

    if not JSON_PATH.exists():
        result["status"] = "error"
        result["error"] = "SSOT JSON not found. Run validate-routing-ssot.py."
        print(json.dumps(result, ensure_ascii=False))
        sys.exit(1)

    ssot = load_ssot()
    if "error" in ssot:
        result["status"] = "error"
        result["error"] = ssot["error"]
        print(json.dumps(result, ensure_ascii=False))
        sys.exit(1)

    yaml_sha = compute_sha256(YAML_PATH) if YAML_PATH.exists() else ""
    result["status"] = "ok"
    result["yaml_sha256"] = yaml_sha
    result["routes_count"] = len(ssot.get("routes", {}))
    result["models_count"] = len(ssot.get("models", {}))

    print(json.dumps(result, ensure_ascii=False))


def main():
    parser = argparse.ArgumentParser(description="SSOT Loader - Query routing data")
    subparsers = parser.add_subparsers(dest="command", help="Subcommand")

    # route-for-task
    route_parser = subparsers.add_parser("route-for-task", help="Get route for task")
    route_parser.add_argument("--intent", required=True, help="Task intent")
    route_parser.add_argument("--complexity", required=True, help="Code complexity (route name)")

    # chain-for-route
    chain_parser = subparsers.add_parser("chain-for-route", help="Get fallback chain for route")
    chain_parser.add_argument("--route", required=True, help="Code route name")

    # health
    health_parser = subparsers.add_parser("health", help="Check SSOT health")

    args = parser.parse_args()

    if args.command == "route-for-task":
        route_for_task(args)
    elif args.command == "chain-for-route":
        chain_for_route(args)
    elif args.command == "health":
        health(args)
    else:
        parser.print_help()
        sys.exit(1)


if __name__ == "__main__":
    main()