#!/usr/bin/env python3
"""apply-change.py — 메타 에이전트가 제안한 JSON에서 단일 변경을 적용 (argv)

인라인 python -c 보간 방지를 위해 별도 스크립트로 분리.
모든 데이터는 sys.argv와 JSON 파일을 통해 받으며, 어떤 보간도 하지 않음.

사용법:
    apply-change.py apply-one <json_file> <index>   # 변경 한 건 적용
    apply-change.py read <json_file> <key1> [<key2>...]  # 키 값 나열 (디버깅용)

규약:
- json_file: failure-analyzer가 작성한 JSON
- 변경 항목 구조: {"file": "<path>", "old_string": "...", "new_string": "..."}
- argv로 받은 모든 문자열은 Python literal 그대로 — 셸 보간이 일어나지 않음
"""
import json
import sys
import os


def apply_one(json_path: str, index: int) -> int:
    """JSON의 changes[index]를 파일에 적용"""
    if not os.path.isfile(json_path):
        print(f"ERROR: json_file not found: {json_path}", file=sys.stderr)
        return 1
    try:
        with open(json_path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (json.JSONDecodeError, OSError) as e:
        print(f"ERROR: JSON parse 실패 ({json_path}): {e}", file=sys.stderr)
        return 1

    changes = data.get("changes") or []
    if not isinstance(changes, list):
        print("ERROR: 'changes' 필드가 list가 아님", file=sys.stderr)
        return 1
    if index < 0 or index >= len(changes):
        print(f"ERROR: index 범위 초과 ({index} >= {len(changes)})", file=sys.stderr)
        return 1
    entry = changes[index]
    if not isinstance(entry, dict):
        print("ERROR: change 항목이 dict가 아님", file=sys.stderr)
        return 1

    file_path = entry.get("file", "")
    old_string = entry.get("old_string", "")
    new_string = entry.get("new_string", "")

    if not file_path or not isinstance(file_path, str):
        print("ERROR: 'file' 필드 누락 또는 문자열 아님", file=sys.stderr)
        return 1
    if not isinstance(old_string, str) or not isinstance(new_string, str):
        print("ERROR: old_string / new_string 은 문자열이어야 함", file=sys.stderr)
        return 1

    if not os.path.isfile(file_path):
        print(f"ERROR: 대상 파일 없음: {file_path}", file=sys.stderr)
        return 1

    try:
        with open(file_path, "r", encoding="utf-8") as fh:
            content = fh.read()
    except OSError as e:
        print(f"ERROR: 파일 읽기 실패 ({file_path}): {e}", file=sys.stderr)
        return 1

    if old_string not in content:
        print(f"ERROR: old_string이 파일에 없음: {file_path}", file=sys.stderr)
        return 1

    # 정확히 한 번 교체 (model이 의도치 않게 여러 번 매치하면 보류)
    occurrences = content.count(old_string)
    if occurrences > 1:
        print(
            f"ERROR: old_string이 {file_path}에 {occurrences}번 매치됨 — "
            "고유하지 않아 보류",
            file=sys.stderr,
        )
        return 1

    new_content = content.replace(old_string, new_string, 1)

    try:
        with open(file_path, "w", encoding="utf-8") as fh:
            fh.write(new_content)
    except OSError as e:
        print(f"ERROR: 파일 쓰기 실패 ({file_path}): {e}", file=sys.stderr)
        return 1

    print(f"patched {file_path}")
    return 0


def read_keys(json_path: str, keys: list) -> int:
    """JSON에서 주어진 키 값을 stdout으로 출력"""
    if not os.path.isfile(json_path):
        print(f"ERROR: json_file not found: {json_path}", file=sys.stderr)
        return 1
    try:
        with open(json_path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (json.JSONDecodeError, OSError) as e:
        print(f"ERROR: JSON parse 실패 ({json_path}): {e}", file=sys.stderr)
        return 1
    for k in keys:
        v = data.get(k, "")
        print(f"{k}={v}")
    return 0


def main() -> int:
    if len(sys.argv) < 2:
        print("사용법: apply-change.py apply-one <json> <idx> | read <json> <k1> ...", file=sys.stderr)
        return 1
    cmd = sys.argv[1]
    if cmd == "apply-one":
        if len(sys.argv) != 4:
            print("사용법: apply-change.py apply-one <json_file> <index>", file=sys.stderr)
            return 1
        return apply_one(sys.argv[2], int(sys.argv[3]))
    elif cmd == "read":
        if len(sys.argv) < 3:
            print("사용법: apply-change.py read <json_file> <key1> ...", file=sys.stderr)
            return 1
        return read_keys(sys.argv[2], sys.argv[3:])
    else:
        print(f"ERROR: 알 수 없는 명령: {cmd}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
