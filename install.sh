#!/usr/bin/env bash
# install.sh — nomad-kant-looper 런타임 설치 진입점
#
# Claude Code와 Codex에는 이 저장소의 git worktree를 연결한다.
# OpenCode는 Claude Code의 skills 경로를 직접 읽으므로 별도 설치하지 않는다.
#
# bash 3.2 호환 (macOS 기본 bash).

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$SCRIPT_DIR"

AGENT=""
REF="main"
DRY_RUN=0
FORCE=0

CLAUDE_TARGET="$HOME/.claude/skills/nomad-kant-looper"
CODEX_TARGET="$HOME/.codex/skills/nomad-kant-looper"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2
}

usage() {
  cat <<'EOF'
Usage:
  ./install.sh --agent claude|codex|opencode|all|auto [--ref main] [--dry-run] [--force]

Options:
  --agent NAME  설치 대상: claude, codex, opencode, all, auto
  --ref REF     worktree로 연결할 브랜치 (기본값: main)
  --dry-run     파일이나 git 상태를 변경하지 않고 예정 작업만 출력
  --force       이 저장소의 worktree가 아닌 기존 대상 디렉터리 교체 허용
  -h, --help    사용법 출력
EOF
}

die_usage() {
  log "ERROR: $*"
  usage >&2
  exit 2
}

is_repo_worktree() {
  local target_path="$1"

  git -C "$SKILL_ROOT" worktree list --porcelain | awk -v target="$target_path" '
    /^worktree / {
      path = substr($0, 10)
      if (path == target) {
        found = 1
      }
    }
    END { exit(found ? 0 : 1) }
  '
}

add_worktree() {
  local target_path="$1"
  local parent_dir
  parent_dir="$(dirname "$target_path")"

  if [ "$DRY_RUN" -eq 1 ]; then
    log "DRY-RUN: worktree 생성 예정: $target_path (ref: $REF)"
    return 0
  fi

  mkdir -p "$parent_dir"
  log "worktree 생성 중: $target_path (ref: $REF)"
  # Claude와 Codex가 같은 ref를 동시에 사용할 수 있도록 Git의 중복
  # branch checkout 제한만 해제한다. 기존 target 교체 여부는 위에서 별도로
  # 검사하므로, 사용자 --force 없이 foreign 경로를 건드리지는 않는다.
  git -C "$SKILL_ROOT" worktree add --force "$target_path" "$REF"
}

ensure_worktree() {
  local target_path="$1"

  if [ -e "$target_path" ] || [ -L "$target_path" ]; then
    if is_repo_worktree "$target_path"; then
      if [ "$DRY_RUN" -eq 1 ]; then
        log "DRY-RUN: 이미 worktree, pull 예정: $target_path (origin $REF)"
      else
        log "이미 worktree, pull 중: $target_path (origin $REF)"
        git -C "$target_path" pull --ff-only origin "$REF"
      fi
      return 0
    fi

    if [ "$FORCE" -ne 1 ]; then
      log "REFUSING: 이미 존재하고 이 저장소의 worktree가 아님: $target_path"
      log "REFUSING: 디렉터리를 변경하지 않았습니다. --force로 재실행하세요."
      return 1
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
      log "DRY-RUN: foreign 경로 제거 예정: $target_path"
      add_worktree "$target_path"
      return 0
    fi

    log "foreign 경로 제거 중 (--force): $target_path"
    rm -rf -- "$target_path"
    add_worktree "$target_path"
    return 0
  fi

  add_worktree "$target_path"
}

show_opencode_info() {
  log "OpenCode는 .claude/skills를 직접 읽으므로 별도 설치가 필요 없습니다."
  if [ ! -e "$CLAUDE_TARGET" ] && [ ! -L "$CLAUDE_TARGET" ]; then
    log "WARNING: Claude 설치 경로가 없습니다: $CLAUDE_TARGET"
  fi
}

run_all() {
  local result=0

  if ! ensure_worktree "$CLAUDE_TARGET"; then
    result=1
  fi
  if ! ensure_worktree "$CODEX_TARGET"; then
    result=1
  fi
  show_opencode_info

  return "$result"
}

run_auto() {
  local found=0
  local result=0

  if [ -d "$HOME/.claude" ]; then
    found=1
    if ! ensure_worktree "$CLAUDE_TARGET"; then
      result=1
    fi
  fi

  if [ -d "$HOME/.codex" ]; then
    found=1
    if ! ensure_worktree "$CODEX_TARGET"; then
      result=1
    fi
  fi

  if [ "$found" -eq 0 ]; then
    log "auto: $HOME/.claude와 $HOME/.codex가 없어 설치할 런타임이 없습니다."
  fi

  return "$result"
}

if [ "$#" -eq 0 ]; then
  usage
  exit 0
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --agent)
      [ "$#" -ge 2 ] || die_usage "--agent 값이 필요합니다."
      AGENT="$2"
      shift 2
      ;;
    --ref)
      [ "$#" -ge 2 ] || die_usage "--ref 값이 필요합니다."
      REF="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die_usage "알 수 없는 인자: $1"
      ;;
  esac
done

[ -n "$AGENT" ] || die_usage "--agent가 필요합니다."

case "$AGENT" in
  claude|codex|opencode|all|auto)
    ;;
  *)
    die_usage "지원하지 않는 --agent 값: $AGENT"
    ;;
esac

case "$REF" in
  ""|-*)
    die_usage "유효하지 않은 --ref 값: $REF"
    ;;
esac

case "$AGENT" in
  claude)
    ensure_worktree "$CLAUDE_TARGET"
    ;;
  codex)
    ensure_worktree "$CODEX_TARGET"
    ;;
  opencode)
    show_opencode_info
    ;;
  all)
    run_all
    ;;
  auto)
    run_auto
    ;;
esac
