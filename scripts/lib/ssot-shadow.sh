#!/usr/bin/env bash
# SSOT Shadow Mode Observer - 라우팅 결정을 비침해 기록하는 모듈
# 기본적으로 비활성 (KANT_SHADOW_MODE=on 활성화)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSOT_LOADER="${SCRIPT_DIR}/ssot_loader.py"

# 샌드박스 환경 체크
function ssot_shadow_check_env() {
    # KANT_SHADOW_MODE=on 이어야 섀도우 모드 활성화
    if [[ "${KANT_SHADOW_MODE:-}" != "on" ]]; then
        return 1  # 비활성
    fi

    # Python3 체크
    if ! command -v python3 &> /dev/null; then
        return 1  # Python3 없으면 비활성
    fi

    # SSOT 파일 체크
    if [[ ! -f "${SCRIPT_DIR}/../../routing-ssot/routing-ssot.yaml" ]]; then
        return 1  # SSOT 파일 없으면 비활성
    fi

    return 0  # 활성
}

# 섀도우 관찰: 코드 라우팅 vs SSOT 라우팅 비교
function ssot_shadow_observe() {
    ssot_shadow_check_env || return 0

    # 인자: 인텐트, 코드 라우트, 코드 모델, 파이프라인 결과
    local intent="${1:-}"
    local code_route="${2:-}"
    local code_model="${3:-}"
    local pipeline_result="${4:-success}"

    # Python 로더가 SSOT 라우트 + 프라이머리 반환
    local ssot_output
    ssot_output=$(
        python3 "${SSOT_LOADER}" route-for-task \
            --intent="${intent}" \
            --complexity="${code_route}" 2>/dev/null || true
    )

    # 로더 실패 시 조용히 종료
    if [[ -z "${ssot_output}" ]]; then
        return 0
    fi

    # JSON 파싱
    local ssot_route
    local ssot_primary
    ssot_route=$(echo "${ssot_output}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('ssot_route', ''))" 2>/dev/null || echo "")
    ssot_primary=$(echo "${ssot_output}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('primary', ''))" 2>/dev/null || echo "")

    if [[ -z "${ssot_route}" ]]; then
        return 0
    fi

    # 로그 레코드 생성 (TSV 형식)
    local timestamp
    timestamp=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
    local log_line="${timestamp}\t${intent}\t${code_route}\t${code_model}\t${ssot_route}\t${ssot_primary}\t${pipeline_result}"

    # 로그 파일에 기록
    echo -e "${log_line}" >> "${KANT_SHADOW_LOG:-/tmp/kant-shadow.log}" || true

    # 디버그용 stdout 출력 (선택사항)
    if [[ "${KANT_SHADOW_DEBUG:-}" == "1" ]]; then
        echo "[SHADOW] code_route=${code_route} code_model=${code_model} ssot_route=${ssot_route} ssot_primary=${ssot_primary}" >&2
    fi
}

# 섀도우 라우트 해결 (Phase 4용 예약)
function ssot_resolve_route() {
    ssot_shadow_check_env || return 1

    local intent="${1:-}"
    local complexity="${2:-}"

    # SSOT 라우트 + 프라이머리 반환
    local ssot_output
    ssot_output=$(
        python3 "${SSOT_LOADER}" route-for-task \
            --intent="${intent}" \
            --complexity="${complexity}" 2>/dev/null || true
    )

    if [[ -z "${ssot_output}" ]]; then
        return 1
    fi

    # 프라이머리 모델 반환
    local primary
    primary=$(echo "${ssot_output}" | python3 -c "import sys, json; print(json.load(sys.stdin).get('primary', ''))" 2>/dev/null || echo "")

    if [[ -n "${primary}" ]]; then
        echo "${primary}"
        return 0
    fi

    return 1
}