# failure-modes.md

> 호출 실패 / verdict 실패 / 무진전 / 안전 위반 등 모든 실패 모드의 대응 정책. routing 가이드 10.2 + 11절 기반.

## 실패 모드 분류

| 모드 | 감지 신호 | 1차 대응 | 2차 대응 |
|---|---|---|---|
| **timeout** | exit 124 | 더 가벼운 모델로 같은 도구 재시도 | 다른 공급자 |
| **인증 실패** | HTTP 401/403 또는 stderr 패턴 | 다른 공급자로 즉시 전환 | claude |
| **rate limit** | HTTP 429 | backoff 30s + 다른 공급자 | claude |
| **형식 오류** | verdict-extractor 실패 | 같은 모델 재시도 1회 | 다른 모델 → claude |
| **연결 실패** | connection refused, DNS fail | retry 1회 | 다른 공급자 → claude |
| **gate 실패** | exit != 0 | repair 라운드 | BLOCKED |
| **무진전** | 같은 diff 3회 / 같은 테스트 실패 2회 | 자동 중단 | 사용자에게 보고 |
| **안전 위반** | protected paths / forbidden patterns | 즉시 중단 | BLOCKED |
| **크기 초과** | > 10MB 단일 파일 | 즉시 중단 | BLOCKED |
| **메타 무결성** | diff hash 불일치, review 시점과 commit 시점 다름 | 즉시 중단 | GATE_FAILED |

## exit code 매핑

```text
0    = 정상
65   = INVALID_OUTPUT (JSON 파싱 실패 또는 required 필드 누락)
66   = BLOCKED
73   = WORKTREE_TAMPERED (plan 단계에서 worktree 변경 감지)
80   = GATE_FAILED (gate exit != 0 또는 diff hash 불일치)
124  = TIMEOUT
200  = INFRA_ERROR (도구 자체 에러, 분류 불가)
201  = AUTH_FAILED (401/403)
202  = RATE_LIMITED (429)
203  = NETWORK_ERROR (connection refused / DNS)
```

## fallback 체인 (호출 실패 시)

각 도구별로 정의된 fallback chain. 가이드 + 운영 데이터에 따라 진화.

### codex

```
primary:    gpt-5.6-sol
fallback_1: gpt-5.6-terra        (같은 공급자, 더 가벼움)
fallback_2: glm-5.2               (다른 공급자)
fallback_3: grok-4.5              (다른 공급자)
final:      claude                (자체 호출, subagent)
```

### grok

```
primary:    grok-4.5
fallback_1: gpt-5.6-terra         (다른 공급자)
fallback_2: glm-5.2
final:      claude
```

### opencode

```
primary:    glm-5.2
fallback_1: glm-4.7               (같은 공급자, 더 가벼움)
fallback_2: gpt-5.6-terra
final:      claude
```

### agy (Antigravity)

```
primary:    gemini-3.5-flash
fallback_1: gemini-3.1-pro-preview (같은 공급자, 더 강함)
fallback_2: glm-5.2
final:      claude
```

agy는 `--sandbox`/`--add-dir`/`--dangerously-skip-permissions`의 실제 동작이 이름만
보고 짐작하기 쉽지 않다 (예: `--sandbox`는 파일 쓰기를 안 막음). adapter-agy.sh를
건드리거나 agy 라우팅을 조정하기 전에 `references/agy-cli-notes.md`를 먼저 볼 것.

### claude (subagent)

```
primary:    MiniMax-M3 (subagent)
fallback_1: 없음 (claude가 마지막 폴백)
```

상세는 `references/fallback-table.md` 참조.

## 무진전 감지 알고리즘

`scripts/lib/no-progress-detector.sh`:

```bash
detect_no_progress() {
  local run_id="$1"
  local state_dir="$HOME/.claude/state/kant-looper/$(repo_hash)/$run_id"

  # 1. 같은 diff 3회
  local same_diff_count=$(grep -c "$(jq -r .diff_hash "$state_dir/state-summary.json")" \
    "$state_dir/phase-events.log" || true)
  if [ "$same_diff_count" -ge 3 ]; then
    return 1  # NO_PROGRESS
  fi

  # 2. 같은 테스트 실패 2회
  local same_test_fail=$(count_same_test_failures "$state_dir")
  if [ "$same_test_fail" -ge 2 ]; then
    return 1
  fi

  # 3. 10회 이상 도구 호출 동안 진척 없음
  # 4. 허용 범위 밖 파일 접근
  # 5. 요구 범위를 임의로 확대
  # 6. 컨텍스트 압축 후 핵심 제약 누락
  # 7. 시간·토큰·비용 한도 80% 도달

  return 0
}
```

무진전 감지 시:
1. 작업 즉시 중단
2. 상태 `FAILED_NO_PROGRESS`로 전환
3. fallback_dispatch 시도 (다른 모델로 같은 작업)
4. 그래도 무진전이거나 사용자 작업 범위 확대 요청 시 BLOCKED + 보고

## 상태 전환 정책

각 phase 끝마다 state-machine 갱신:

```
QUEUED → RUNNING → WAITING_FOR_TOOL → WAITING_FOR_VERDICT
  → SUCCEEDED | PARTIAL | FAILED | TIMED_OUT | CANCELLED
```

### SUCCEEDED로 가는 경로

```
모든 phase verdict=PASS, gate exit 0, safety check PASS
→ commit
→ SUCCEEDED
```

### PARTIAL로 가는 경로

```
Round 1 PASS, Round 2에서 일부 phase 진행하다 중단
→ PARTIAL
→ commit (불완전 diff)
```

### FAILED로 가는 경로

```
verdict=CHANGES_REQUESTED + MAX_ROUNDS 도달
verdict=BLOCKED
gate fail + repair 중단
→ FAILED
→ fallback_dispatch 시도
```

### TIMED_OUT으로 가는 경로

```
exit 124 + IMPLEMENT_TIMEOUT_SECONDS 초과
→ TIMED_OUT
→ fallback_dispatch 또는 사용자 보고
```

## failure_log 형식

`fallback-log.txt`:

```
2026-07-12T10:23:45Z codex(gpt-5.6-sol) RATE_LIMIT → fallback to glm-5.2
2026-07-12T10:24:12Z opencode(glm-5.2) NO_PROGRESS same_diff_count=3 → halt
2026-07-12T10:24:13Z halted: FAILED_NO_PROGRESS
```

## 자동 재시도 vs 사용자 보고 기준

```text
자동 재시도 (fallback_dispatch):
- timeout
- rate limit
- 형식 오류
- 단일 도구 일시 장애
- 같은 작업 다른 모델로 가능

즉시 중단 (사용자 보고):
- 안전 약속 위반 (protected paths, forbidden patterns, 메타 무결성)
- main 브랜치 직접 커밋 시도
- 모든 도구 + claude 모두 실패
- 모순된 verdict (예: plan=PASS, implement=BLOCKED)
- 사용자 정의 작업 범위와 자동 작업 범위 불일치
- 작업 범위를 자동 확대 시도

사용자 보고 후 대기:
- 모순된 요구사항 (예: "테스트 없이 strict TypeScript + any 허용")
- 외부 도구 영구 장애
```

## 안전 실패 시나리오

### 시나리오 1: 도구가 protected paths를 변경

```
agy가 .env 파일을 수정함
→ safety-check.sh가 staged diff에서 .env 감지
→ BLOCKED, 실패 코드 SAFETY_VIOLATION
→ 어떤 도구/모델이어도 작업 중단
→ fallback 안 함 (자동 재시도 위험)
```

### 시나리오 2: PLAN이 다른 의도

```
PLAN_AGENT가 "main.py와 tests/test_main.py 수정"이라 했는데
IMPL_AGENT가 utils/, scripts/ 등 다른 디렉터리까지 수정
→ diff 의도성 mismatch 감지
→ 경고 + 사용자 보고 (자동 fallback 안 함)
```

### 시나리오 3: 무한 fallback 루프

```
codex fail → glm-5.2 fail → grok fail → claude fail → fallback 없음
→ 모든 도구 실패
→ BLOCKED_ALL_PROVIDERS + 사용자 보고
```
