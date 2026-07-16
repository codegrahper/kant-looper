#!/usr/bin/env bash
# safety-check.sh — protected paths / forbidden patterns 검사
#
# kant-looper의 안전 약속을 강제. 자동 push/merge/rebase/reset 안 됨.
# staged diff와 unstaged 변경 모두 검사.
#
# bash 3.2 호환.

set -Eeuo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 기본 PROTECTED_PATHS
DEFAULT_PROTECTED_PATHS='.git .env .env.local .env.*.local *.pem *.key *credential* *secret* *password* node_modules dist build __pycache__ .venv scripts/lib/safety-check.sh scripts/lib/health-check.sh'

# 주의: 각 패턴이 공백을 포함할 수 있으므로(예: "-----BEGIN .* PRIVATE KEY-----")
# 반드시 줄바꿈으로만 구분한다. 공백으로 나누면 셸이 단어를 쪼개고,
# ".*" 같은 조각은 unquoted 루프에서 glob으로도 확장되어(예: "." ".." ".git")
# 원래 정규식과 무관한 값이 패턴인 것처럼 취급되는 사고가 난다.
DEFAULT_FORBIDDEN_PATTERNS='AKIA[0-9A-Z]{16}
sk-[a-zA-Z0-9]{20,}
-----BEGIN .* PRIVATE KEY-----
Bearer [A-Za-z0-9._-]{20,}
eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'

MAX_FILE_BYTES="${KANT_MAX_FILE_BYTES:-10485760}"  # 10MB

# ---------------------------------------------------------------------------
# protected paths 검사
# ---------------------------------------------------------------------------
# 인자: worktree_dir
# 출력 (stdout): 위반된 경로 (줄바꿈 구분). 없으면 빈 출력.
# 종료 코드: 0 = 통과, 1 = 위반 발견

check_protected_paths() {
  local worktree="$1"

  if [ ! -d "$worktree" ]; then
    return 0
  fi

  # git staged + unstaged 변경된 파일들 검사
  local files
  if (cd "$worktree" && git rev-parse --git-dir >/dev/null 2>&1); then
    files=$(
      cd "$worktree" && {
        git diff --name-only --cached 2>/dev/null
        git diff --name-only 2>/dev/null
        git ls-files --others --exclude-standard 2>/dev/null
      } | sort -u
    )
  else
    # worktree가 git이 아닌 경우 (드문 케이스)
    return 0
  fi

  local protected="${PROTECTED_PATHS:-$DEFAULT_PROTECTED_PATHS}"
  local violation=""

  local file
  for file in $files; do
    [ -z "$file" ] && continue

    local matched=""
    local pattern
    # PROTECTED_PATHS 항목 자체가 글롭(*.pem 등)이므로, 이 루프에서
    # 셸이 그 글롭을 실제 파일 목록으로 확장해버리면 안 된다 (set -f로 차단).
    set -f
    # shellcheck disable=SC2086
    for pattern in $protected; do
      # glob 매칭: 패턴을 */패턴* 형태로 검사
      local clean_pattern="${pattern%/}"
      # 정확한 매칭 검사 (case-insensitive)
      case "$file" in
        *"$clean_pattern"*)
          # 단, 단순 단어 매칭만 (예: 'src/secrets.ts'는 매칭 안 됨)
          if printf '%s' "$file" | grep -qE "(^|/)${clean_pattern//\*/[^/]*}($|/)"; then
            matched="$pattern"
            break
          fi
          ;;
      esac
    done
    set +f

    if [ -n "$matched" ]; then
      violation="${violation}${file} (matches: ${matched})\n"
    fi
  done

  if [ -n "$violation" ]; then
    printf '%b' "$violation"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# forbidden patterns 검사 (staged diff 내용)
# ---------------------------------------------------------------------------
# 인자: worktree_dir
# 출력 (stdout): 발견된 패턴 (줄바꿈 구분). 없으면 빈 출력.
# 종료 코드: 0 = 통과, 1 = 위반 발견

check_forbidden_patterns() {
  local worktree="$1"

  if [ ! -d "$worktree" ]; then
    return 0
  fi

  local diff_content
  if (cd "$worktree" && git rev-parse --git-dir >/dev/null 2>&1); then
    diff_content=$(
      cd "$worktree" && {
        git diff --cached --binary 2>/dev/null
        git diff --binary 2>/dev/null
      }
    )
  else
    return 0
  fi

  if [ -z "$diff_content" ]; then
    return 0
  fi

  local forbidden="${FORBIDDEN_PATTERNS:-$DEFAULT_FORBIDDEN_PATTERNS}"
  local violation=""

  # 패턴 자체에 공백이 들어있을 수 있어(예: "Bearer [A-Za-z0-9._-]{20,}")
  # 반드시 줄 단위로만 나눈다 — 단어 분리/glob 확장 둘 다 절대 일어나면 안 됨.
  local pattern
  while IFS= read -r pattern; do
    [ -z "$pattern" ] && continue
    if printf '%s' "$diff_content" | grep -qE "$pattern"; then
      violation="${violation}pattern: $pattern\n"
    fi
  done <<< "$forbidden"

  if [ -n "$violation" ]; then
    printf '%b' "$violation"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 파일 크기 검사
# ---------------------------------------------------------------------------
# 인자: worktree_dir
# 출력 (stdout): 크기 초과 파일 목록. 없으면 빈 출력.
# 종료 코드: 0 = 통과, 1 = 위반

check_file_sizes() {
  local worktree="$1"

  if [ ! -d "$worktree" ]; then
    return 0
  fi

  local files
  if (cd "$worktree" && git rev-parse --git-dir >/dev/null 2>&1); then
    files=$(
      cd "$worktree" && {
        git diff --name-only --cached 2>/dev/null
        git diff --name-only 2>/dev/null
        git ls-files --others --exclude-standard 2>/dev/null
      } | sort -u
    )
  else
    return 0
  fi

  local violation=""
  local file
  for file in $files; do
    [ -z "$file" ] && continue
    local full_path="$worktree/$file"
    if [ -f "$full_path" ]; then
      local size
      size=$(stat -f%z "$full_path" 2>/dev/null || stat -c%s "$full_path" 2>/dev/null || echo 0)
      if [ "$size" -gt "$MAX_FILE_BYTES" ] 2>/dev/null; then
        violation="${violation}${file} (${size} bytes > ${MAX_FILE_BYTES})\n"
      fi
    fi
  done

  if [ -n "$violation" ]; then
    printf '%b' "$violation"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 메인 검사
# ---------------------------------------------------------------------------

run_all_checks() {
  local worktree="$1"
  local total_violation=""

  local v
  v=$(check_protected_paths "$worktree" 2>/dev/null) || true
  if [ -n "$v" ]; then
    total_violation="${total_violation}PROTECTED_PATH_VIOLATION:\n${v}"
  fi

  v=$(check_forbidden_patterns "$worktree" 2>/dev/null) || true
  if [ -n "$v" ]; then
    total_violation="${total_violation}FORBIDDEN_PATTERN_VIOLATION:\n${v}"
  fi

  v=$(check_file_sizes "$worktree" 2>/dev/null) || true
  if [ -n "$v" ]; then
    total_violation="${total_violation}FILE_SIZE_VIOLATION:\n${v}"
  fi

  if [ -n "$total_violation" ]; then
    printf '%b' "$total_violation"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Self-test: 스크립트 내부 grep 검사
# ---------------------------------------------------------------------------

self_test() {
  # 매우 정확한 패턴 — 허용되는 변형은 제외
  # - git push (단순 push만; "git pushable" 등은 OK)
  # - git merge는 일반 OK; 단 `--no-ff` 플래그가 있으면 위반
  # - git rebase는 모두 위반
  # - git reset --hard는 위반
  # - git branch -D (대문자 D)는 위반
  # - rm -rf /, rm -rf /* 같은 파괴적 명령

  local file violation=""

  # 자기 자신(safety-check.sh) 제외 — 패턴 문자 자체가 들어있음
  for file in "$LIB_DIR"/../kant-loop.sh "$LIB_DIR"/*.sh; do
    [ -f "$file" ] || continue
    # safety-check.sh는 패턴 자체가 있으므로 검사에서 제외
    case "$(basename "$file")" in
      safety-check.sh) continue ;;
    esac

    local found=""
    # git push 검사 (정확)
    if grep -E '^[^#]*\bgit push\b' "$file" 2>/dev/null | grep -vE '^\s*#' | grep -v '\becho\b' | grep -q .; then
      found="${found}git push\n"
    fi
    # git merge --no-ff 검사
    if grep -E '^[^#]*\bgit merge\b' "$file" 2>/dev/null | grep -v -- '--ff-only' | grep -v 'echo' | grep -v '^\s*#' | grep -q .; then
      found="${found}git merge (without --ff-only)\n"
    fi
    # git rebase 검사
    if grep -E '^[^#]*\bgit rebase\b' "$file" 2>/dev/null | grep -v '^\s*#' | grep -q .; then
      found="${found}git rebase\n"
    fi
    # git reset --hard 검사
    if grep -E '^[^#]*\bgit reset .*--hard\b' "$file" 2>/dev/null | grep -v '^\s*#' | grep -q .; then
      found="${found}git reset --hard\n"
    fi
    # git branch -D 검사 (대문자 -D만)
    if grep -E '^[^#]*\bgit branch -D\b' "$file" 2>/dev/null | grep -v '^\s*#' | grep -q .; then
      found="${found}git branch -D\n"
    fi
    # rm -rf / 검사 (파괴적 명령만)
    if grep -E '^[^#]*\brm -rf /' "$file" 2>/dev/null | grep -v '^\s*#' | grep -q .; then
      found="${found}rm -rf /\n"
    fi

    if [ -n "$found" ]; then
      violation="${violation}$(basename "$file"):\n${found}"
    fi
  done

  if [ -n "$violation" ]; then
    printf 'self-test violations found:\n%b' "$violation"
    return 1
  fi
  echo "self-test: all scripts clean"
  return 0
}

# ---------------------------------------------------------------------------
# CLI 진입점
# ---------------------------------------------------------------------------

if [ "${1:-}" = "paths" ]; then
  shift
  check_protected_paths "$@"
  exit $?
fi

if [ "${1:-}" = "patterns" ]; then
  shift
  check_forbidden_patterns "$@"
  exit $?
fi

if [ "${1:-}" = "sizes" ]; then
  shift
  check_file_sizes "$@"
  exit $?
fi

if [ "${1:-}" = "all" ]; then
  shift
  run_all_checks "$@"
  exit $?
fi

if [ "${1:-}" = "self-test" ]; then
  self_test
  exit $?
fi

cat <<EOF
safety-check.sh — protected paths / forbidden patterns / file sizes 검사

사용법:
  safety-check.sh paths <worktree>      # protected paths 검사
  safety-check.sh patterns <worktree>   # forbidden patterns 검사
  safety-check.sh sizes <worktree>      # file size 검사 (>${MAX_FILE_BYTES} bytes)
  safety-check.sh all <worktree>        # 모든 검사
  safety-check.sh self-test             # 스크립트 내부 grep 검사

env:
  PROTECTED_PATHS (공백 구분, default: .git .env *.pem *.key *credential* *secret* ...)
  FORBIDDEN_PATTERNS (줄바꿈 구분 — 패턴 자체에 공백이 들어갈 수 있음, default: AWS / API key / PEM / Bearer / JWT)
  KANT_MAX_FILE_BYTES (default 10485760 = 10MB)
EOF
exit 0
