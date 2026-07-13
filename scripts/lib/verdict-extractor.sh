#!/usr/bin/env bash
# verdict-extractor.sh — 외부 에이전트 응답에서 JSON verdict 추출
#
# codex-agent-loop-v4.sh:extract_json_object 패턴 기반.
# 모델이 JSON을 ```json 코드블록에 넣든, 사족 텍스트와 섞어 출력하든,
# 첫 번째 valid JSON object를 brace-counting으로 추출.
#
# bash 3.2 호환 (macOS 기본 bash).

set -Eeuo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# extract_json_object
# ---------------------------------------------------------------------------
# 인자: input_file (또는 stdin)
# 출력 (stdout): 첫 번째 valid JSON object
# 종료 코드: 0 = 추출 성공, 1 = 추출 실패

extract_json_object() {
  local input="${1:-/dev/stdin}"

  if [ ! -f "$input" ] && [ "$input" != "/dev/stdin" ]; then
    echo "ERROR: input not found: $input" >&2
    return 1
  fi

  # 0단계: claude(.result) / grok(.text) envelope 언랩 후
  # 1단계: ```json ... ``` 코드블록 우선 추출
  # 2단계: brace-counting
  # (envelope 언랩은 최상위에 verdict가 없을 때만 — codex 등 무회귀)
  local codeblock_json
  if command -v python3 >/dev/null 2>&1; then
    codeblock_json=$(
      python3 - "$input" 2>/dev/null <<'PYEOF' || true
import json, re, sys

def try_extract(text):
    # 1단계: 코드펜스
    m = re.search(r'```(?:json)?\s*\n([\s\S]*?)\n```', text)
    if m:
        try:
            json.loads(m.group(1))
            return m.group(1).strip()
        except Exception:
            pass
    # 2단계: brace-counting
    depth = 0
    in_str = False
    escape = False
    start = -1
    for i, ch in enumerate(text):
        if in_str:
            if escape:
                escape = False
            elif ch == '\\':
                escape = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == '{':
            if depth == 0:
                start = i
            depth += 1
        elif ch == '}':
            depth -= 1
            if depth == 0 and start >= 0:
                candidate = text[start:i+1]
                try:
                    json.loads(candidate)
                    return candidate.strip()
                except Exception:
                    start = -1
    return None

path = sys.argv[1]
text = open(path, 'r', errors='ignore').read()

# 0단계 (신규): envelope 언랩 — claude(.result)/grok(.text)
# 최상위가 이미 verdict를 담고 있으면 손대지 않는다.
try:
    envelope = json.loads(text)
    if isinstance(envelope, dict) and 'verdict' not in envelope:
        for field in ('result', 'text'):
            inner = envelope.get(field)
            if isinstance(inner, str) and inner.strip():
                found = try_extract(inner)
                if found:
                    print(found)
                    sys.exit(0)
except Exception:
    pass

# 기존 1~2단계 (raw 텍스트 그대로)
found = try_extract(text)
if found:
    print(found)
    sys.exit(0)
sys.exit(1)
PYEOF
    )
  fi

  if [ -n "${codeblock_json:-}" ]; then
    echo "$codeblock_json"
    return 0
  fi

  # 2단계: fallback - 첫 줄부터 raw로 jq 시도 (이미 JSON-only 응답인 경우)
  if command -v jq >/dev/null 2>&1; then
    local first_object
    first_object=$(jq -Rn --rawfile f "$input" '
      . as $empty |
      (try ($f | fromjson) catch null) as $direct |
      if $direct != null then $direct
      else
        ($f | scan("(?<json>\\{[^{}]*\\})")) as $scanned |
        $scanned
      end
    ' 2>/dev/null | head -1 || true)
    if [ -n "$first_object" ]; then
      echo "$first_object"
      return 0
    fi
  fi

  return 1
}

# ---------------------------------------------------------------------------
# validate_verdict_json
# ---------------------------------------------------------------------------
# 인자: json_string 또는 json_file_path
# 출력 (stdout): role (PASS|CHANGES_REQUESTED|BLOCKED|INVALID_OUTPUT)
# 종료 코드: 0 = verdict 유효, 1 = INVALID_OUTPUT

validate_verdict_json() {
  local input="${1:-/dev/stdin}"

  local json_text
  if [ -f "$input" ]; then
    json_text="$(cat "$input")"
  else
    json_text="$input"
  fi

  if [ -z "$json_text" ]; then
    echo "INVALID_OUTPUT"
    return 1
  fi

  # jq로 verdict 추출
  if command -v jq >/dev/null 2>&1; then
    local verdict
    verdict=$(printf '%s' "$json_text" | jq -r '.verdict // "INVALID_OUTPUT"' 2>/dev/null || echo "INVALID_OUTPUT")
    case "$verdict" in
      PASS|CHANGES_REQUESTED|BLOCKED|INVALID_OUTPUT)
        echo "$verdict"
        return 0
        ;;
      *)
        echo "INVALID_OUTPUT"
        return 1
        ;;
    esac
  fi

  # jq 없으면 단순 grep
  if printf '%s' "$json_text" | grep -qE '"verdict"[[:space:]]*:[[:space:]]*"PASS"'; then
    echo "PASS"
    return 0
  fi
  if printf '%s' "$json_text" | grep -qE '"verdict"[[:space:]]*:[[:space:]]*"CHANGES_REQUESTED"'; then
    echo "CHANGES_REQUESTED"
    return 0
  fi
  if printf '%s' "$json_text" | grep -qE '"verdict"[[:space:]]*:[[:space:]]*"BLOCKED"'; then
    echo "BLOCKED"
    return 0
  fi

  echo "INVALID_OUTPUT"
  return 1
}

# ---------------------------------------------------------------------------
# extract role별 required 필드 검사
# ---------------------------------------------------------------------------
# 인자: json_text, role
# 종료 코드: 0 = 모든 required 필드 존재, 1 = 누락

check_required_fields() {
  local json_text="$1" role="$2"

  if ! command -v jq >/dev/null 2>&1; then
    return 0   # jq 없으면 검사 skip
  fi

  local required_fields='verdict summary findings'
  case "$role" in
    plan)
      required_fields="$required_fields scope implementation_steps acceptance_criteria verification_commands"
      ;;
    repair-plan)
      required_fields="$required_fields root_cause repair_steps do_not_touch verification_commands acceptance_criteria"
      ;;
    implement|repair)
      required_fields="$required_fields changed_files tests_added_or_updated risks notes_for_reviewer"
      ;;
    review)
      required_fields="$required_fields required_fixes evidence requires_repair_round gate_interpretation commit_ready"
      ;;
    verify)
      required_fields="$required_fields review_findings_resolved gate_interpretation commit_ready requires_repair_round"
      ;;
  esac

  local field
  for field in $required_fields; do
    if ! printf '%s' "$json_text" | jq -e ".$field" >/dev/null 2>&1; then
      return 1
    fi
  done

  return 0
}

# ---------------------------------------------------------------------------
# <verdict> 태그 파싱 (이중 출력 fallback)
# ---------------------------------------------------------------------------

extract_verdict_tag() {
  local input="${1:-/dev/stdin}"
  local text

  if [ -f "$input" ]; then
    text="$(cat "$input")"
  else
    text="$input"
  fi

  local tag
  tag=$(printf '%s' "$text" | grep -oE '<verdict>[^<]+</verdict>' | head -1 | sed 's/<[^>]*>//g' || true)
  if [ -n "$tag" ]; then
    echo "$tag"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# 메인 처리 함수
# ---------------------------------------------------------------------------

# 인자: response_file, role
# 출력 (stdout): "verdict|extracted_json_path"
# 종료 코드: 0 = 성공

process_response() {
  local response_file="$1" role="${2:-implement}"
  local work_dir
  work_dir="$(dirname "$response_file")"

  # 1단계: JSON 추출
  local json_text
  json_text="$(extract_json_object "$response_file" 2>/dev/null || true)"

  if [ -z "$json_text" ]; then
    # <verdict> 태그 폴백
    local tag_verdict
    tag_verdict="$(extract_verdict_tag "$response_file" 2>/dev/null || true)"
    if [ -z "$tag_verdict" ]; then
      echo "INVALID_OUTPUT|"
      return 1
    fi
    json_text="{\"verdict\": \"$tag_verdict\", \"summary\": \"\", \"findings\": []}"
  fi

  # 2단계: 검증
  local verdict
  verdict="$(validate_verdict_json "$json_text")"

  if [ "$verdict" = "INVALID_OUTPUT" ]; then
    echo "INVALID_OUTPUT|$json_text"
    return 0
  fi

  # 3단계: required 필드 검사
  if ! check_required_fields "$json_text" "$role"; then
    echo "INVALID_OUTPUT|$json_text"
    return 0
  fi

  # 4단계: 추출 결과를 파일로 저장
  local json_path="$work_dir/$(basename "$response_file" .raw).json"
  printf '%s' "$json_text" > "$json_path"
  echo "$verdict|$json_path"
  return 0
}

# ---------------------------------------------------------------------------
# CLI 진입점
# ---------------------------------------------------------------------------

if [ "${1:-}" = "extract" ]; then
  shift
  extract_json_object "$@"
  exit $?
fi

if [ "${1:-}" = "validate" ]; then
  shift
  validate_verdict_json "$@"
  exit $?
fi

if [ "${1:-}" = "process" ]; then
  shift
  process_response "$@"
  exit $?
fi

cat <<EOF
verdict-extractor.sh — 외부 에이전트 응답에서 JSON verdict 추출

사용법:
  verdict-extractor.sh extract <file>           # 첫 번째 valid JSON object 추출
  verdict-extractor.sh validate <file_or_text>  # verdict enum 검증
  verdict-extractor.sh process <file> <role>    # 추출 + 검증 + .json 저장
EOF
exit 0
