# SSOT 통합 로드맵 — Phase 3/4/5 플랜

> 2026-07-16 작성. Phase 1 (SSOT 코드 정합화)과 Phase 2 (검증기 강화)는
> 완료됨 (`routing-ssot-integration` 브랜치 커밋 `3842c68`, `85e7c98`).
> 이 문서는 이바가 요청한 "직접 플랜을 만들어 이어서 작업" 대상인
> Phase 3-5의 설계와 위험 평가를 담는다.

## 원칙

각 phase는 **독립적으로 커밋**되고 **다음 phase로 넘어가기 전 명시적
체크포인트**를 둔다. Phase N이 완료되어야 Phase N+1을 시작한다.

| Phase | 위험도 | 코드 수정 | 실행 전제 |
|---|---|---|---|
| 1 (완료) | 없음 | `routing-ssot/*` 신규 파일만 | 없음 |
| 2 (완료) | 없음 | `routing-ssot/*` 만 | 없음 |
| 3 | **낮음** (additive) | `kant-loop.sh` 1블록 + `scripts/lib/ssot-*` 신규 | 바로 실행 가능 |
| 4 | **높음** (production 전환) | `kant-loop.sh` routing flow 본체 | Phase 3 그림자 로그가 0 diff로 안정 |
| 5 | **중간** (제거) | hardcode 상수 제거 | Phase 4 전환이 최소 2주 안정 |

## Phase 3 — 그림자 모드 (Shadow Mode)

### 목표

`kant-loop.sh`가 실제 라우팅 결정을 내린 직후, 동일 입력에 대해 SSOT가
어떤 결정을 내놓을지 **병렬로 계산**하여 diff 로그를 남긴다. **실제 라우팅은
기존 하드코딩 로직으로 동작**하므로 사용자 경험이나 결과는 변하지 않는다.

### 위험 평가

- 기본 OFF (`KANT_SHADOW_SSOT=0`). 아무것도 안 켜면 Kant-Looper 동작은
  byte-for-byte 동일.
- 켜져 있을 때 모든 shadow 호출은 `|| true`로 감싸진다. Python 로더가 죽어도,
  YAML이 깨져도, 로그 파일이 안 써져도 주 흐름은 영향 없음.
- shadow 코드는 별도 파일(`scripts/lib/ssot-shadow.sh`,
  `scripts/lib/ssot_loader.py`)에 격리. `kant-loop.sh` 본체에는 최소한의
  진입점 1개만 추가.

### 파일

| 파일 | 상태 | 목적 |
|---|---|---|
| `scripts/lib/ssot_loader.py` | 신규 | routing-ssot.yaml을 읽고 shell-friendly 출력을 내놓는 Python 로더. subcommand: `route-for-task`, `chain-for-route`, `health`. |
| `scripts/lib/ssot-shadow.sh` | 신규 | bash 래퍼. `ssot_shadow_check_env`, `ssot_shadow_observe` 함수. check_env가 false면 observe는 즉시 return 0. |
| `scripts/kant-loop.sh` | 1블록 추가 | routing 결정 직후(`judged_route`/`effective_route` 확정 후, L1004 근처)에 `ssot_shadow_observe` 호출. env 안 켜져 있으면 no-op. |
| `scripts/tests/test-ssot-shadow.sh` | 신규 | bash 테스트. (a) env off → 로그 파일 생성 안 됨, (b) env on + 정상 입력 → 예상 diff 라인 생성, (c) ssot_loader.py 강제 crash → shadow silent, 주 흐름 정상. `test-all.sh`에 등록. |
| `references/ssot-shadow-mode.md` | 신규 | 사용자 가이드. 켜는 법, 로그 읽는 법, diff 임계치 가이드. |

### SSOT 로더 입출력

로더는 바닥 YAML 파싱에 PyYAML을 쓰지만, 호출 형태는 모두 **단발성 CLI**다
(kant-loop.sh이 subshell로 부른다). 런타임 메모리에 SSOT를 상주시키지 않는다.

```bash
# intent+complexity → SSOT가 제안하는 route와 primary
ssot_loader.py route-for-task --intent implement --complexity T2
# stdout: route=standard_repo
# stdout: primary=codex|openai/gpt-5.6-terra

# SSOT route → chain
ssot_loader.py chain-for-route --route standard_repo
# stdout: chain=codex|openai/gpt-5.6-terra,codex|openai/gpt-5.6-luna,...

# 헬스 체크
ssot_loader.py health
# stdout: ok
```

**코드 route 이름 ↔ SSOT route 이름 매핑**은 로더 내부에 하드코딩된 테이블:

```python
CODE_TO_SSOT = {
    "tiny": "tiny",
    "standard": "standard_repo",
    "hard": "hard_repo",
    "huge": "huge_context",
    "visual": "visual_browser",
    "review": "review",
}
```

`long_tool_chain`은 코드에 대응이 없으므로 shadow 비교에서 제외.

### 로그 형식

```
$KANT_SHADOW_LOG (기본: /tmp/kant-shadow-$USER.log, 회전 X)
---
ts=2026-07-16T15:23:01+09:00
task_md=/path/to/task.md
intent=implement complexity=T2
code_route=standard code_primary=codex|gpt-5.6-terra
ssot_route=standard_repo ssot_primary=codex|openai/gpt-5.6-terra
diff=none
---
ts=2026-07-16T15:24:00+09:00
task_md=...
diff=primary code=codex|gpt-5.6-terra ssot=opencode|glm-5.2
```

`diff=none`이 가장 흔해야 정상. `diff=primary` 또는 `diff=route`가 누적되면
Phase 4 전환 전에 원인 분석이 필요하다.

### Phase 3 완료 조건

- [ ] ssot_loader.py가 routing-ssot.yaml을 읽어 정확한 route/chain을 반환
- [ ] kant-loop.sh env off 시 로그 파일 생성 없음 (test로 검증)
- [ ] kant-loop.sh env on 시 예상 diff 라인 생성
- [ ] ssot_loader.py crash 시 shadow silent, 주 흐름 정상 (test로 검증)
- [ ] 기존 `test-all.sh` 모든 테스트 통과 (회귀 없음)
- [ ] `safety-check.sh self-test` 통과 (자동 push / rebase / reset grep 걸리지 않음)

### Phase 4 진입 조건 (Phase 3 종료 후 이바가 판단)

- Phase 3을 켜고 **최소 20건 이상**의 실제 작업을 돌린 로그 확보.
- diff=none 비율이 **90% 이상** (또는 발생한 diff가 모두 SSOT가 더 정확한
  사례로 확인됨).
- diff=primary 또는 diff=route가 반복적으로 발생하면 원인 분석 후 SSOT/코드
  어느 쪽을 고칠지 결정. 이 결정은 Phase 4 전에 이바 승인 필요.

## Phase 4 — 실제 라우팅 소스 전환

### 목표

SSOT를 라우팅의 **1차 소스**로 사용. hardcoded 상수(`KANT_ROUTE_*_PRIMARY`,
`KANT_PRIMARY_*`)는 SSOT 로더가 반환하는 값으로 교체. fallback chain은
`fallback-dispatcher.sh`가 읽던 hardcoded 테이블 대신 SSOT의 chain 문자열을
파싱해 사용.

### 위험 평가

- **이 phase는 production 동작을 바꾼다.** 잘못되면 라우팅이 깨져 모든
  작업이 실패할 수 있음.
- 안전망: 전환은 `KANT_ROUTING_SOURCE=ssot|hardcode` env로 토글. 기본
  `hardcode` → Phase 4 커밋 후에도 기본값은 hardcode로 유지하다가, 이바가
  직접 `=ssot`로 켜서 실사용 검증 후 PR 설명에 기록.
- 롤백: env 1개만 바꾸면 즉시 hardcode로 복귀.

### 파일

| 파일 | 상태 | 목적 |
|---|---|---|
| `scripts/lib/ssot-shadow.sh` | 확장 | `ssot_resolve_route(intent, complexity)` 함수 추가. `KANT_ROUTING_SOURCE=ssot`일 때만 활성. |
| `scripts/lib/routing-parser.sh` | 수정 | `_get_route_candidate`가 ssot 경로를 우선 호출하고 실패 시 hardcode fallback. |
| `scripts/lib/fallback-dispatcher.sh` | 수정 | chain 조회 시 ssot_loader의 `chain-for-route`를 우선, 실패 시 기존 hardcoded 테이블. |
| `scripts/kant-loop.sh` | 최소 수정 | routing source 토글을 lib에 위임, 본체는 거의 안 건드림. |
| `scripts/tests/test-routing-source-ssot.sh` | 신규 | ssot 모드에서의 end-to-end 라우팅 검증. 기존 test-meta-aware-routing과 동일 입력을 넣어 같은 결과가 나오는지 확인. |

### Phase 4 완료 조건

- [ ] `KANT_ROUTING_SOURCE=ssot`에서 모든 기존 라우팅 테스트 통과
- [ ] 동일 입력에 대해 hardcode 모드와 ssot 모드가 같은 route+primary 반환
- [ ] fallback chain 순회가 ssot chain으로 동작
- [ ] `KANT_ROUTING_SOURCE=hardcode`로 즉시 복귀 가능

### Phase 5 진입 조건

- 최소 2주간 `KANT_ROUTING_SOURCE=ssot` 기본 사용
- 회귀 없음
- 이바가 명시적으로 hardcode 제거 승인

## Phase 5 — Hardcode 제거 + 전체 회귀

### 목표

routing-parser.sh / fallback-dispatcher.sh / kant-loop.sh의 hardcode 상수를
제거하고 SSOT만 남김. fallback-dispatcher.sh는 단순 chain executor로 축소.

### 제거 대상

- `routing-parser.sh` L84-90의 `KANT_ROUTE_*_PRIMARY` 상수
- `fallback-dispatcher.sh` L26-35의 8개 hardcoded chain 문자열
- `kant-loop.sh`의 `KANT_PRIMARY_*` 변수 (L76-81)
- `validate_agent_model_compatibility` 자체는 SSOT의 agent_bindings로
  대체 가능 → 검토 후 제거 또는 보류

### 보존 대상

- `KANT_LIB_DIR`, `ROUTING_GUIDE` 등 경로 변수
- agent CLI 호출 자체 (codex/opencode/grok/agy/claude의 실행 인터페이스)
- fallback 순회 메커니즘 자체 (chain을 읽어 한 단계씩 시도하는 로직)

### Phase 5 완료 조건

- [ ] hardcode 상수 제거 후에도 모든 라우팅 테스트 통과
- [ ] SSOT의 chain 1줄만 바꾸면 라우팅이 즉시 반영됨 (실험으로 확인)
- [ ] `safety-check.sh self-test`, `test-all.sh` 전부 green
- [ ] 코드-SSOT 불일치를 detection하는 추가 회귀 테스트 포함

## 의사결정 포인트 (이바 승인 필요)

Phase 3 → 4로 넘어가는 시점과 Phase 4 → 5로 넘어가는 시점은 모두 이바의
명시적 판단이 필요하다. 각 phase는 코드 품질 문제가 아니라 **관측 데이터와
운영 판단**에 의해 좌우된다.

- Phase 3 종료 후: "shadow 로그를 충분히 모았고 diff가 임계치 이하다" →
  Phase 4 진행 여부 결정.
- Phase 4 종료 후: "ssot 모드가 2주간 안정적이다" → Phase 5 제거 진행 여부
  결정.

이 플랜대로라면 Sisyphus가 지금 당장 실행할 수 있는 건 **Phase 3까지**다.
Phase 4-5는 Phase 3의 관측 결과를 이바가 검토한 뒤 진행한다.
