# loop-flow.md

> ⚠️ **낡은 문서**: 이 문서는 폐기된 HPRAR 라운드 상태 모델을 설명합니다. 현재 `kant-loop.sh`는 `implement`/`review`/`repair` 3역할만 사용합니다. 역사적 기록으로 보존합니다.

> kant-looper의 라운드별 상태 머신과 state 디렉터리 구조. 백엔드(`scripts/kant-loop.sh`) 구현의 입출력 계약.

## 호출 모드와 라운드

### `--quick` 모드 (가장 가벼움)

```
[1] 도구/모델 선택 (클로드 판단 또는 --agent/--model 명시)
    → 1개 도구/모델 선택

[2] health_check <tool>
    → 실패 시 즉시 fallback → claude로 전환

[3] adapter_<tool>.sh call PROMPT WORKTREE
    → response.json + log

[4] verdict-extractor.sh extract response.json
    → 4-value enum {PASS, CHANGES_REQUESTED, BLOCKED, INVALID_OUTPUT}

[5] gate-runner.sh run
    → exit 0 이어야 진행

[6] safety-check.sh paths
    → protected/forbidden 위반 시 BLOCKED

[7] AUTO_COMMIT=1 ? commit_reviewed_diff : pass_no_commit

[8] report → 사용자에게 결과 통보
```

`--quick --chain tool:model,tool:model,tool:model`은 같은 격리 worktree에서 `implement → review → repair`를 순차 실행한다. 세 단계 중 하나라도 PASS가 아니면 즉시 중단하고 커밋하지 않는다.

### `--parallel` 모드 (동시성)

```
[1] --chain 명시 (필수, 최대 4명)
    → N개 도구/모델 reviewer

[2] 각 도구를 병렬 읽기 전용 호출 (nohup + wait)
    agent-agy-ui.log
    agent-glm5.2-logic.log
    agent-codex-review.log

[3] 각 verdict 수집
    → 모든 reviewer가 PASS이고 worktree 변경이 없을 때만 성공

[4] report
```

`--parallel`은 동시 파일 수정을 하지 않는다. 변경이 필요한 작업은 quick 체인을 사용한다.

## 상태 머신

```
QUEUED ─→ RUNNING ─→ WAITING_FOR_TOOL ─→ WAITING_FOR_VERDICT
                                              │
              ┌───────────────────────────────┼───────────────────────────┐
              ▼                               ▼                           ▼
          SUCCEEDED                       PARTIAL/FAILED              TIMED_OUT/CANCELLED
              │                               │                           │
              ▼                               ▼                           ▼
         commit 단계                      다음 라운드                  fail_run
                                                                              │
                                                                              ▼
                                                                       fallback_dispatch
```

상세 상태 (routing 가이드 10.1 기반):

| 상태 | 의미 |
|---|---|
| `QUEUED` | 작업 등록됨, 대기열 |
| `RUNNING` | 외부 에이전트 호출 중 |
| `WAITING_FOR_TOOL` | 에이전트가 도구 호출 결과 대기 |
| `WAITING_FOR_VERDICT` | 응답 수신, verdict 검증 대기 |
| `SUCCEEDED` | 모든 phase PASS, commit |
| `PARTIAL` | Round 1 PASS, Round 2에서 일부 진행 |
| `FAILED` | verdict != PASS, 자동 fallback 또는 사용자 보고 |
| `CANCELLED` | 사용자가 명시 취소 |
| `TIMED_OUT` | timeout 초과 |

## state 디렉터리 구조

`~/.claude/state/kant-looper/<repo-hash>/<run-id>/`

```
run-id.txt
task.md                                # 원본 사본
branch.txt                             # agent/<slug>/<run-id>
worktree.txt
base-{branch,sha}.txt
{plan,repair-plan,review,verify}.json
implement.r{1,2}.{prompt.md,log}
gates-round-{1,2}/gate-*.log
staged-diff-round-{1,2}.{patch,stat}
staged-diff-hash-round-{1,2}.txt
parallel/                              # --parallel 모드
  agent-agy-ui.log
  agent-glm5.2-logic.log
  agent-codex-review.log
fallback-log.txt                       # 어떤 fallback 발생
commit-{sha,tree}.txt
phase-events.log                       # 시간순 이벤트
final-report.md
state-summary.json                     # 매 phase 끝에 덮어씀 (Claude가 읽음)
```

### state-summary.json 스키마

```json
{
  "run_id": "uuid",
  "mode": "quick|parallel",
  "phase": "implement.r1",
  "status": "RUNNING|SUCCEEDED|FAILED|TIMED_OUT",
  "verdict": "PASS|CHANGES_REQUESTED|BLOCKED|INVALID_OUTPUT",
  "agent_chain": ["codex:gpt-5.6-terra", "glm-5.2", "claude"],
  "current_tool": "codex",
  "current_model": "gpt-5.6-terra",
  "fallback_count": 1,
  "no_progress_count": 0,
  "elapsed_seconds": 142,
  "tokens_used": 12450,
  "cost_usd": 0.21,
  "diff_hash": "sha256:...",
  "commit_sha": null,
  "summary": "reverse() 함수 추가, 3개 테스트 PASS",
  "findings": [],
  "next_action": "commit|repair_round_2|fail"
}
```

## 무진전 감지 + 상향 순서

### 무진전 중단 조건 (routing 가이드 10.2)

`scripts/lib/no-progress-detector.sh`가 매 phase 끝마다 검사:

```text
- 같은 diff 3회 → 중단
- 같은 테스트 실패 2회 → 중단
- 10회 이상 도구 호출 동안 진척 없음 → 중단
- 허용 범위 밖 파일 접근 → 중단
- 요구 범위를 임의로 확대 → 중단
- 컨텍스트 압축 후 핵심 제약 누락 → 중단
- 시간·토큰·비용 한도 80% 도달 → 중단
```

중단 시 상태 `FAILED`로 전환 + 사용자에게 보고.

### 상향 순서 (routing 가이드 10.3)

라운드 1 실패 시 자동 escalation:

```
Luna → Terra → Sol High
glm-4.7 → glm-5.2
gemini-3.5-flash → gemini-3.1-pro-preview
MiniMax-M2.7 → MiniMax-M3
```

각 단계 실패 시 상위 모델로. 상위 모델까지 실패 시 다른 공급자 → claude (최종 폴백).

## 호출 시퀀스 예시 (`--quick --chain`)

```
T+0s    run TASK.md --quick --chain opencode:glm-5.2,codex:gpt-5.6-sol,codex:gpt-5.6-terra
        → RUN_ID, state-dir 즉시 반환

T+3s    health_check: codex, grok, opencode, agy, claude
        → 모두 OK (또는 UNAVAILABLE 표시)

T+5s    implement (opencode, glm-5.2)
        → implement.r1.log exit 0, changed_files=[5]

T+45s   gate (npm test)
        → exit 0

T+60s   review (codex, gpt-5.6-sol, read-only)
        → review verdict=PASS

T+70s   repair (codex, gpt-5.6-terra) → gate → commit
        → COMMIT_SHA 기록

T+80s   notify_final "completed"
        → macOS notification + Claude 세션 보고
```

## 실패 처리

```
quick 체인 단계가 PASS가 아니면 즉시 실패한다. `--parallel` reviewer가 실패하거나 worktree 변경을 만들면 실패하며, 구현이 필요하면 사용자가 `--quick --chain`을 명시적으로 실행한다.

T+260s  commit

fallback-log.txt:
  T+30 codex(gpt-5.6-sol) rate_limit → glm-5.2
  T+100 codex(gpt-5.6-terra) auth_fail → agy(gemini-3.5-flash)
```
