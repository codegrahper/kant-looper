#!/usr/bin/env bash
# adapter-opencode.sh — OpenCode CLI 어댑터 (GLM 모델 백엔드)
#
# 호출: opencode run -m <model> --format json --auto --print-logs \
#        --log-level INFO --dir <worktree> --variant <variant> "<prompt>"
# 완료 감지: exit code + --format json 이벤트 스트림

set -Eeuo pipefail

ADAPTER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_LIB="$ADAPTER_DIR/../lib"

# PATH에 ~/.opencode/bin 추가 (없는 경우)
if [ -d "${HOME}/.opencode/bin" ] && [[ ":${PATH}:" != *":${HOME}/.opencode/bin:"* ]]; then
  export PATH="${HOME}/.opencode/bin:${PATH}"
fi

get_io_dir() {
  local worktree="$1"
  local io_dir="$worktree/.kant-looper"
  mkdir -p "$io_dir"
  echo "$io_dir"
}

health() {
  "$SKILL_LIB/health-check.sh" tool opencode
}

version() {
  if command -v opencode >/dev/null 2>&1; then
    opencode --version 2>&1 | head -1
  elif [ -x "${HOME}/.opencode/bin/opencode" ]; then
    "${HOME}/.opencode/bin/opencode" --version 2>&1 | head -1
  else
    echo "opencode not installed"
  fi
}

# ---------------------------------------------------------------------------
# call
# ---------------------------------------------------------------------------

call() {
  local role="$1" prompt_file="$2" worktree="$3" model="$4"

  if [ ! -f "$prompt_file" ]; then
    echo "ERROR: prompt file not found: $prompt_file" >&2
    return 1
  fi

  if ! "$SKILL_LIB/health-check.sh" tool opencode >/dev/null 2>&1; then
    echo "ERROR: opencode unavailable" >&2
    return 201
  fi

  local io_dir
  io_dir="$(get_io_dir "$worktree")"
  local response_file="$io_dir/response-opencode-${role}.json"
  local log_file="$io_dir/log-opencode-${role}.log"

  local timeout
  timeout=$("$SKILL_LIB/timeout-runner.sh" timeout-for "$role")

  # opencode는 "provider/model" 형태를 요구한다 (예: opencode-go/glm-5.2).
  # bare 이름("glm-5.2", "glm-4.7" 등)이 들어오면 ProviderModelNotFoundError 발생.
  # 이미 "/"를含む 이름은 정규화 없이 그대로 사용.
  local variant="${KANT_OPENCODE_VARIANT:-high}"

  local glm_provider="${KANT_OPENCODE_GLM_PROVIDER:-opencode-go}"
  local normalized_model="$model"
  if ! printf '%s' "$model" | grep -q '/'; then
    case "$model" in
      glm-4.*|glm-5.*)
        normalized_model="${glm_provider}/${model}"
        ;;
      *)
        # 알 수 없는 bare 이름은 로그만 남기고 그대로 시도 (다른 프로바이더일 수 있음)
        echo "[adapter-opencode] WARN: bare model name '$model' — passing as-is (opencode may fail with ProviderModelNotFoundError)" >&2
        ;;
    esac
  fi

  # role에 따른 권한 모드 결정
  # - plan / review / verify: --auto 없이 (read-only 동작)
  # - implement / repair: --auto (파일 변경 필요, but 경고 출력)
  local use_auto=""
  case "$role" in
    implement|repair)
      use_auto="--auto"
      echo "[adapter-opencode] WARNING: --auto enabled for role=$role (파일 변경 허용). 작업은 $worktree 안으로 제한됨." >&2
      ;;
  esac

  local cmd=(
    opencode run
    -m "$normalized_model"
    --format json
    --print-logs
    --log-level INFO
    --dir "$worktree"
    --variant "$variant"
  )

  # implement/repair 단계에서만 --auto 추가
  if [ -n "$use_auto" ]; then
    cmd+=( "$use_auto" )
  fi

  # prompt 마지막에 추가 (파라미터 끝에)
  cmd+=( "$(cat "$prompt_file")" )

  # 실행 — set -e 안전 패턴 (command substitution 실패 시에도 rc 검출)
  local rc=0
  local runner_output
  if runner_output="$("$SKILL_LIB/timeout-runner.sh" run "$timeout" "$log_file" "$response_file" "$worktree" "${cmd[@]}")"; then
    rc=0
  else
    rc=$?
  fi

  local json_text
  # opencode는 JSON 이벤트 스트림을 출력 (각 라인이 별도 JSON 객체).
  # 첫 valid JSON을 추출하면 step-start 같은 이벤트가 잡혀 verdict가 빠짐.
  # 모든 이벤트를 파싱해서 마지막 type:text 객체의 verdict를 추출.
  json_text="$(python3 - <<'PYEOF' "$response_file" 2>/dev/null || true
import json, re, sys

path = sys.argv[1]
last_text = None
for line in open(path, errors='ignore'):
    line = line.strip()
    if not line:
        continue
    try:
        e = json.loads(line)
        if isinstance(e, dict) and e.get('type') == 'text':
            t = e.get('part', {}).get('text')
            if t:
                last_text = t
    except (json.JSONDecodeError, KeyError, TypeError):
        continue

if not last_text:
    sys.exit(1)

# 1. 코드블록 안의 JSON
m = re.search(r'```json\s*(\{.*?\})\s*```', last_text, re.DOTALL)
if m:
    try:
        json.loads(m.group(1))
        print(m.group(1))
        sys.exit(0)
    except json.JSONDecodeError:
        pass

# 2. <verdict> 태그
m2 = re.search(r'<verdict>(\w+)</verdict>', last_text)
if m2:
    print(json.dumps({
        "verdict": m2.group(1),
        "summary": "",
        "findings": [],
        "changed_files": [],
        "tests_added_or_updated": [],
        "risks": [],
        "notes_for_reviewer": ""
    }))
    sys.exit(0)

sys.exit(1)
PYEOF
)"

  # 폴백: 기존 verdict-extractor
  if [ -z "$json_text" ]; then
    json_text="$("$SKILL_LIB/verdict-extractor.sh" extract "$response_file" 2>/dev/null || true)"
  fi

  if [ -z "$json_text" ]; then
    local failure_mode
    failure_mode=$("$SKILL_LIB/fallback-dispatcher.sh" classify "opencode" "$rc" "$(cat "$log_file" 2>/dev/null)")
    echo "FAIL:${failure_mode:-EXTRACT_FAILED}"
    return 1
  fi

  local verdict
  verdict=$("$SKILL_LIB/verdict-extractor.sh" validate "$json_text")

  local json_path="$io_dir/opencode-${role}.json"
  printf '%s' "$json_text" > "$json_path"

  echo "$verdict|$json_path"
  return 0
}

# ---------------------------------------------------------------------------
# CLI 진입점
# ---------------------------------------------------------------------------

case "${1:-}" in
  call)
    shift
    call "$@"
    exit $?
    ;;
  health)
    health
    exit $?
    ;;
  version)
    version
    exit 0
    ;;
  *)
    echo "adapter-opencode.sh — OpenCode CLI 어댑터 (GLM 백엔드)"
    echo ""
    echo "사용법:"
    echo "  adapter-opencode.sh call <role> <prompt_file> <worktree> <model>"
    echo "  adapter-opencode.sh health"
    echo "  adapter-opencode.sh version"
    exit 1
    ;;
esac