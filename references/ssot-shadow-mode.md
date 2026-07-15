# SSOT Shadow Mode (Phase 3)

그림자 모드는 Kant-Looper의 라우팅 결정을 비침해 방식으로 관찰한다.
기존 하드코딩 라우팅 로직은 그대로 실행되며, 병렬로 SSOT 로더가 동일
입력에 대해 어떤 결정을 내놓을지 계산해 diff를 TSV 로그로 남긴다.

## 활성화

```bash
KANT_SHADOW_MODE=on scripts/kant-loop.sh run TASK.md --dry-run
```

옵션 환경변수:

- `KANT_SHADOW_MODE=on` — 그림자 모드 활성 (기본: off)
- `KANT_SHADOW_LOG=/path/to/log.tsv` — 로그 파일 경로 (기본: `/tmp/kant-shadow.log`)
- `KANT_SHADOW_DEBUG=1` — stderr에 각 관찰 결과 출력

활성화 조건 (모두 만족해야 동작):

1. `KANT_SHADOW_MODE=on`
2. `python3` 사용 가능
3. `routing-ssot/routing-ssot.json` 존재 (검증기가 생성)

조건 불충족 시 모든 훅은 조용히 무시된다 (fail-safe).

## 로그 형식

TSV (탭 구분), 한 줄당 하나의 라우팅 결정:

```
timestamp	intent	code_route	code_model	ssot_route	ssot_primary	pipeline_result
```

예:

```
2026-07-15T22:06:11Z	implement	standard	codex:gpt-5.6-terra	standard_repo	codex|openai/gpt-5.6-terra	dry-run
```

필드:

| 필드 | 의미 |
|---|---|
| `timestamp` | UTC ISO 8601 |
| `intent` | `routing-parser.sh judge`의 intent (implement/fix/test 등) |
| `code_route` | 코드가 판별한 라우트 이름 (tiny/standard/hard/huge/visual/review) |
| `code_model` | 코드가 실제로 사용할 tool:model 쌍 또는 체인 문자열 |
| `ssot_route` | SSOT가 매핑한 라우트 (standard_repo/hard_repo 등) |
| `ssot_primary` | SSOT가 제안할 primary (`agent\|provider/model_id` 형식) |
| `pipeline_result` | 관찰 지점 (`dry-run` / `quick-routed` / `parallel-routed` / `full-routed`) |

## 관찰 지점

`scripts/kant-loop.sh`에 4개 훅이 삽입됐다. 모두 `|| true`로 보호되므로
섀도우 로직이 실패해도 프로덕션 동작에 영향을 주지 않는다.

1. **dry-run** — `cmd_run`의 dry-run 경로. judge 결과 전체가 이미 파싱된
   시점이므로 추가 비용 없이 관찰 가능.
2. **quick-routed** — `run_quick_mode`의 라우팅 결정 직후. routing-parser
   judge를 한 번 더 호출해 라우트 이름을 얻는다 (shadow ON일 때만).
3. **parallel-routed** — `run_parallel_mode`의 route_list 결정 직후. 동일.
4. **full-routed** — `run_full_mode`의 plan/impl/review 체인 결정 직후.
   하드코딩된 기본 체인(`opencode:glm-5.2,agy:gemini-3.5-flash,codex:gpt-5.6-sol`)
   과 SSOT 권장값을 비교한다.

라우트 이름 추출은 `reason` 필드의 `route:NAME` 세그먼트에서 이뤄진다.
`judged_route`는 tool:model 쌍이지 라우트 이름이 아니다.

## JSON 파일 생성

`routing-ssot/routing-ssot.json`은 런타임 로더가 읽는 파일이다.
`routing-ssot/routing-ssot.yaml`이 유효하면 검증기가 자동으로 생성한다.

```bash
uv run --with pyyaml --with jsonschema python3 \
  routing-ssot/validate-routing-ssot.py \
  routing-ssot/routing-ssot.yaml \
  routing-ssot/routing-ssot.schema.json
```

출력에 `json_dump=routing-ssot/routing-ssot.json`이 포함되면 성공.
YAML이 수정될 때마다 재생성해야 한다. YAML → JSON 변환이므로 JSON은
수동 편집하지 않는다.

## 런타임 의존성

`scripts/lib/ssot_loader.py`는 표준 라이브러리만 사용한다 (`json`, `argparse`,
`pathlib`, `hashlib`). pyyaml은 검증기에만 필요하고 런타임 로더에는 필요
없다. PEP 668로 인해 시스템 python3에 pyyaml을 설치할 수 없는 환경에서도
로더는 동작한다.

## Phase 4 진입 기준

Phase 4(토글 메커니즘)는 다음 조건이 모두 충족되면 진입한다:

1. dry-run 그림자 로그가 다양한 task에서 안정적으로 생성된다.
2. code_route ↔ ssot_route 매핑이 의도대로 동작한다 (`standard` →
   `standard_repo`, `hard` → `hard_repo` 등).
3. SSOT primary가 코드의 primary와 일치하거나, 불일치 시 그 원인이
   SSOT curation 의도(예: proposed 모델 비활성)로 설명 가능하다.
4. 그림자 로그가 프로덕션 실행 경로에 영향을 주지 않음이 확인됐다.

이 기준이 충족되면 `KANT_ROUTING_SOURCE=ssot` 토글로 코드 라우팅을
SSOT 기반으로 전환한다 (Phase 4). Phase 5는 하드코딩 상수 제거 여부를
결정한다.

## 제한사항

- 로그는 한 줄당 하나의 결정만 기록한다. full 모드의 3 에이전트 체인은
  단일 줄에 통합(`plan:impl:review` 형식)으로 기록된다.
- SSOT가 라우트를 해결할 수 없는 입력(예: 알 수 없는 라우트 이름)은
  기록되지 않는다. `ssot_route`가 빈 문자열이면 훅이 조기 종료한다.
- `KANT_SHADOW_LOG`에 쓰기 권한이 없으면 로그는 조용히 무시된다.
- 그림자 모드는 라우팅 결정을 관찰만 한다. 실행 시간, 비용, verdict
  등은 기록하지 않는다. 그것들은 Phase 4/5의 영역이다.