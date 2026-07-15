# Kant Looper Routing SSOT 패키지

이 패키지는 Kant-Looper의 라우팅 규칙(모델, route, fallback, agent-model 바인딩)을
YAML 단일 진실의 원천(SSOT)으로 관리한다. Phase 1 (2026-07-16) 기준, 실행 코드
(`scripts/kant-loop.sh`, `scripts/lib/*.sh`)은 아직 이 SSOT를 읽지 않으며, 하드코딩
라우팅 상수를 그대로 사용한다. SSOT는 코드와 100% 정합하도록 큐레이션된
"코드 진실의 거울"이다. Phase 3 이후 그림자 모드를 통해 코드와 비교 검증된 뒤,
Phase 4에서 실제 라우팅 소스로 전환된다.

## 파일

- `routing-ssot.yaml`: 실행용 SSOT. 스키마 버전 1.1.0.
- `routing-ssot.schema.json`: JSON Schema Draft 2020-12 구조 검증 규칙.
- `validate-routing-ssot.py`: schema + 의미 검증기.
- `SSOT-UPDATE-PLAN.md`: 주기적 업데이트 및 기존 문서 전환 계획.

## 검증

```bash
uv run --with pyyaml --with jsonschema python3 \
  routing-ssot/validate-routing-ssot.py \
  routing-ssot/routing-ssot.yaml \
  routing-ssot/routing-ssot.schema.json
```

기대 출력: `VALID`, 모델/루트 수, SHA-256 해시. Phase 2 통과 시:

```
VALID
models=16 routes=7
sha256=56087f63672f9847ded095145b7aeef77c8d61f62bc9d4fe197629fb40e3d94b
```

### Phase 2 검증 항목

검증기는 다음 5개 invariant를 자동 검사한다 (agy 리포트 §5 누락 항목 전량 보완).

| # | 검증 항목 | 코드 대응 | 위반 시 에러 힌트 |
|---|---|---|---|
| 1 | agent-model 호환성 | kant-loop.sh::validate_agent_model_compatibility L327-368 | `does not match any allowed pattern` / `denied pattern` |
| 2 | fallback 최종 안전망 | fallback-dispatcher.sh의 8 chain 모두 claude\|default 종결 | `must terminate with 'claude\|anthropic/claude-default'` |
| 3 | scoring 가중치 합 = 100 | SSOT 내부 정책 | `must sum to 100` |
| 4 | route eligible_tiers ↔ primary recommended_tiers 교집합 | SSOT tier 모델 | `has no overlap with primary` |
| 5 | provider별 최소 1개 모델 | orphan provider 방지 | `has no models registered` |

### Phase 2 음성 케이스 테스트

`routing-ssot/tests/test_validator.py`는 canonical SSOT를 in-memory로 변형해
각 invariant를 위반시킨 뒤 검증기가 non-zero 종료 + 해당 힌트를 출력하는지
확인한다. pytest가 없어도 standalone으로 실행된다.

```bash
uv run --with pyyaml --with jsonschema python3 \
  routing-ssot/tests/test_validator.py
```

기대 결과: 8/8 PASS (1개 canonical positive + 7개 negative).

| 테스트 | 위반 invariant |
|---|---|
| `test_canonical_passes` | (positive baseline) |
| `test_agent_binding_violation_wrong_tool_for_pattern` | #1 allowed mismatch |
| `test_agent_binding_unknown_tool` | #1 undeclared agent_tool |
| `test_agent_binding_claude_denies_minimax` | #1 denied match |
| `test_fallback_chain_missing_safety_net` | #2 chain not claude-terminated |
| `test_scoring_weights_sum_not_100` | #3 sum != 100 |
| `test_route_tier_no_overlap_with_primary` | #4 tier disjoint |
| `test_provider_without_models` | #5 orphan provider |

## 배치

Phase 1에서는 패키지 5개 파일을 저장소 최상위 `routing-ssot/` 디렉토리에 평면으로
둔다. `SSOT-UPDATE-PLAN.md`가 제안하는 `config/`, `schemas/`, `scripts/`, `docs/`
분산 배치는 Phase 5에서 저장소 전체 정리 시점에 적용한다. 평면 배치가 Phase 1의
"실행 코드 건드리지 않기" 제약과 가장 잘 맞고 git 추적/이력 추적도 단순하다.

## Route 이름 매핑 (코드 ↔ SSOT)

`scripts/lib/routing-parser.sh::judge_task_routing()` (L495-512)이 판별하는 route
이름과 SSOT의 route 키는 의도적으로 다르다. SSOT는 의미론적 이름을, 코드는 짧은
내부 식별자를 쓴다. 둘은 1:1로 대응한다. Phase 4에서 SSOT 로더가 코드 경로에
연결될 때 이 매핑 표가 로더에 하드코딩된다.

| 코드 route (`judge_task_routing`) | SSOT route | 비고 |
|---|---|---|
| `tiny` | `tiny` | 이름 동일 |
| `standard` | `standard_repo` | T1/T2 일반 구현 |
| `hard` | `hard_repo` | T3/T4 어려운 구현 |
| `huge` | `huge_context` | huge context 필요 |
| `visual` | `visual_browser` | 멀티모달/브라우저 |
| `review` | `review` | 독립 리뷰 (Phase 1 신규 등록) |
| (코드 없음) | `long_tool_chain` | `status: proposed` — 코드에 대응 없음 |

`review` route의 primary는 `codex|openai/gpt-5.6-sol`로 `hard_repo`와 동일한
fallback chain을 공유한다. 이는 코드에서 `KANT_ROUTE_REVIEW_PRIMARY="codex:$primary_sol"`
(routing-parser.sh L90)과 동일한 바인딩이다.

## Agent-Model 바인딩 설계

Kant-Looper의 핵심 제약: 각 모델은 정확히 하나의 agent CLI로만 실행된다.
`scripts/kant-loop.sh::validate_agent_model_compatibility()` (L327-368)가 런타임에
이 규칙을 강제한다.

SSOT는 이 제약을 두 레이어로 표현한다.

### 1. `agent_bindings` 최상위 섹션

5개 agent tool의 호환성 규칙을 정규식 패턴으로 명시. 이 패턴은
`validate_agent_model_compatibility`의 `grep -qE` 호출과 1:1 대응한다.

| agent_tool | SSOT 필드 | 패턴 | 코드 대응 (kant-loop.sh L327-368) |
|---|---|---|---|
| `codex` | `allowed_model_patterns` | `^gpt-` | L335 |
| `opencode` | `allowed_model_patterns` | `^glm-`, `^MiniMax-` | L341-342 |
| `grok` | `allowed_model_patterns` | `^grok-` | L349 |
| `agy` | `allowed_model_patterns` | `^gemini-` | L355 |
| `claude` | `denied_model_patterns` | `^MiniMax-` | L361 |

### 2. 모델별 `agent_tool` 필드

각 모델은 실제로 어느 CLI로 실행되는지 `agent_tool` 필드로 명시한다. Phase 2
검증기가 이 필드와 `agent_bindings` 패턴을 교차 검증한다.

### 3. Route primary/fallbacks 형식

route의 `primary`와 `fallbacks` 원소는 `agent_tool|provider/model_id` 형식의
문자열이다. 이는 `scripts/lib/fallback-dispatcher.sh`의 chain 문자열
(`agent|model`)에 provider namespace를 붙인 형태로, SSOT가 self-contained이면서
코드 chain 구조와 동형이게 한다.

예: `codex|openai/gpt-5.6-sol` = 코드의 `codex|gpt-5.6-sol`과 동일한 의미.

### 최종 안전망 불변량

모든 route의 fallback chain 마지막 원소는 `claude|anthropic/claude-default`여야
한다. 이는 `fallback-dispatcher.sh`의 8개 chain이 전부 `claude|default`로
끝나는 런타임 불변량과 일치한다. Phase 2 검증기가 이 불변량을 자동 검사한다.

## Phase 1 결정 사항

### o3 미등록 (agy 리포트 3-3 반박)

agy 검증 리포트는 `kant-loop.sh` L716 모델 레지스트리와 L355 hard_repo fallback에
`o3`가 존재한다고 기술했다. 2026-07-16 기준 코드 재확인 결과, `o3`는 저장소 전체에서
**단 한 건도 검색되지 않는다** (코드, 문서, 설정 모두 포함). 리포트의 클레임은
stale data에 기반한 것이다. 따라서 SSOT에 `o3`를 등록하지 않는다.

### `glm-5-turbo`, `glm-5v-turbo`, `glm-4.7-flash` → `status: proposed`

세 모델 모두 SSOT에는 등록돼 있으나 런타임 코드(`routing-parser.sh`,
`fallback-dispatcher.sh`, `model-selector.sh`)의 활성 경로에 존재하지 않는다.

- `glm-5-turbo`: `references/multimodel-coding-agent-routing-guide.md`에만 언급.
  `long_tool_chain` route primary로 등록되나, 이 route 자체가 `status: proposed`.
- `glm-5v-turbo`: `references/fallback-table.md`와 routing-guide에만 언급.
  `fallback-dispatcher.sh`의 `agy|gemini-3.5-flash` chain에는 없음.
- `glm-4.7-flash`: `openai.yaml`에 등록되나 `routing-parser.sh::is_model_valid()`가
  거부.

임의 삭제 대신 `status: proposed`로 표기하여 "코드에 아직 반영되지 않은 제안"
상태를 명시한다. Phase 4/5에서 코드에 실제로 wire되면 `status: stable`로 승격.

### `visual_browser` chain: 코드 기준 정합

`references/fallback-table.md`는 `visual_browser`의 fallback으로 `glm-5v-turbo`,
`MiniMax-M3`를 기술하나, `fallback-dispatcher.sh`의 실제 chain은 다르다:

```
agy|gemini-3.5-flash → agy|gemini-3.1-pro-preview → opencode|glm-5.2 → claude|default
```

SSOT는 **코드 기준**으로 정합화했다 (`fallback-table.md` 불일치는 별도 이슈).
`fallback-table.md` 자체는 이 Phase에서 수정하지 않는다.

## Phase 1 → Phase 2 인계

Phase 2 (2026-07-16 완료)가 추가로 담당한 검증 (agy 리포트 §5 누락 항목 전량):

1. **Agent-model 호환성 자동 검증**: 각 모델의 `agent_tool` ↔ `agent_bindings`
   패턴 교차 검사 — `validate_agent_model_compatibility`의 5개 규칙 재현.
2. **Fallback 최종 안전망 존재 검증**: 모든 route chain이
   `claude|anthropic/claude-default`로 종결되는지 검사.
3. **Scoring 가중치 합 = 100 검증**: `selection_policy.scoring` 합계.
4. **Route eligible_tiers ↔ 모델 recommended_tiers 교차 검증**: primary 기준.
5. **Provider별 최소 1개 모델 검증**: orphan provider 차단.

음성 케이스(in-memory 변형 fixture) 7건 + canonical positive 1건이
`routing-ssot/tests/test_validator.py`에 추가됐고 모두 통과한다.

`selection_policy` 스키마가 세밀화됐다 (hard_exclusions/scoring/tie_breakers
필수화, scoring 값은 0-100 정수). 나머지 정책 섹션(`governance`,
`review_policy`, `execution_policy`, `evaluation_policy`, `update_policy`)은
여전히 `type: object`만 있고 Phase 5 후속 후보로 남는다.

## Phase 2 → Phase 3 인계

Phase 2 검증기가 보장하는 것:
- SSOT가 스키마를 만족한다.
- SSOT의 모든 agent_tool 할당이 코드의 호환성 규칙과 정합하다.
- 모든 route chain이 claude 안전망으로 종결된다.
- scoring 가중치가 합 100이다.
- route의 eligible tier가 primary에게 의미 있는 tier다.
- 모든 provider에 최소 1개 모델이 있다.

Phase 2 검증기가 **보장하지 못하는** 것 (Phase 3 그림자 모드가 검증):
- SSOT가 "실제로 코드와 동일한 라우팅 결정을 내리는가" — 정합성은
  구조/패턴 수준이지 런타임 동작 수준이 아니다.
- 동일 task description에 대해 `routing-parser.sh::judge_task_routing()`이
  내놓는 route 이름과 SSOT가 의도한 route가 일치하는가.
- `fallback-dispatcher.sh::do_fallback()`이 런타임에 순회하는 chain 순서와
  SSOT의 fallbacks 리스트 순서가 byte-for-byte 일치하는가.

이 간극은 Phase 3 그림자 모드가 다룬다. `kant-loop.sh`은 기존 하드코딩
라우팅으로 실제 결정을 내리되, 병렬로 SSOT 로더가 같은 입력에 대해
어떤 결정을 내놓을지 계산해 diff를 로그로 남긴다. diff가 임계치 이하로
안정되면 Phase 4 전환을 승인한다.
