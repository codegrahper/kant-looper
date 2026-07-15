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

기대 출력: `VALID`, 모델/루트 수, SHA-256 해시. Phase 1 통과 시:

```
VALID
models=16 routes=7
sha256=56087f63672f9847ded095145b7aeef77c8d61f62bc9d4fe197629fb40e3d94b
```

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

Phase 1의 검증기는 "새 형식 파싱 + 기존 검증 유지"까지만 담당한다. Phase 2가
추가로 담당할 검증 항목 (agy 리포트 §5):

1. **Agent-model 호환성 자동 검증**: 각 모델의 `agent_tool` ↔ `agent_bindings`
   패턴 교차 검사.
2. **Fallback 최종 안전망 존재 검증**: 모든 route chain이
   `claude|anthropic/claude-default`로 종결되는지 검사.
3. **Scoring 가중치 합 = 100 검증**: `selection_policy.scoring` 합계.
4. **Route eligible_tiers ↔ 모델 recommended_tiers 교차 검증**.
5. **Provider별 최소 1개 모델 검증**.

음성 케이스(일부러 규칙을 어긴 fixture)를 만들어 각 검사가 실패를 잡아내는지
검증하는 테스트도 Phase 2에서 추가한다.

Phase 1에서 스키마가 허용하지만 Phase 2가 추가 검증해야 하는 공백:
- 모델의 `agent_tool`이 `agent_bindings` 키에 존재하는지 (현재 스키마는 문자열
  필드일 뿐).
- route primary의 agent가 같은 route의 fallback의 agent와 호환되는지.
- 동일 모델이 같은 chain에 agent 없이 중복 등장하는지.
