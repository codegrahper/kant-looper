# 포스트모템: 라우팅 키워드 오탐 (`ui`/`T3` 오분류)

> **후기(2026-07-17)**: 이 문서가 다루는 `routing-parser.sh`는 경량화
> 작업(5단계, [PLAN-lightweight-kant-looper.md](../../PLAN-lightweight-kant-looper.md))에서
> 완전히 제거됐다. 자동판정은 이제 코드가 아니라 클로드가 그 자리에서 판단한다.
> 이 문서는 왜 그 판단을 셸 코드에 맡기면 안 되는지 보여준 실제 사례로서
> 역사적 기록으로 남겨둔다.

- **날짜**: 2026-07-15
- **발견 경로**: OpenCode/GLM 어댑터 개선 작업(TASK-opencode-glm-debug-enhanced.md)을
  kant-looper로 디스패치하려다 자동 라우팅 결과가 명백히 이상해서 발견
- **수정 커밋**: `26bca47` (`agent/kant/task-20260715-101754-3e7f` → main으로 ff-only 병합)
- **영향 파일**: `scripts/lib/routing-parser.sh`

---

## 무슨 일이 있었나

순수 bash 어댑터 리팩터 작업지시(TASK.md)를 자동 라우팅에 넣었더니
`classify-intent` → `ui`, `estimate-complexity` → `T3`가 나왔다.
작업 내용은 UI/프론트엔드와 전혀 무관했고, 저장소 전체에 영향을 주는
대규모 작업도 아니었다. 결과적으로 자동 라우터는 이 작업을
`agy:gemini-3.5-flash`(브라우저/비주얼 자동화 전용 도구)로 보내려 했다 —
bash 스크립트 편집엔 완전히 부적합한 도구였다.

## 근본 원인

`classify_task_intent()`/`estimate_complexity()` (`routing-parser.sh:303-347`,
커밋 `85d4463`에서 신규 도입, 이후 한 번도 검증되지 않음)가 `elif` 체인에
**단어 경계 없는 정규식**을 쓰고 있었다.

- `ui` 분기의 `접근` 키워드 — "UI 접근성(accessibility)"을 잡으려던 의도였지만,
  bash 어댑터 작업지시 안의 "설정 파일 **접근** 가능", "작업 디렉터리 **접근** 권한"
  (파일시스템 권한 얘기, UI와 무관)에도 매칭됐다.
- `T3` 분기의 bare `전체` 키워드 — "저장소 **전체**" 의미로 넣은 것이지만,
  "실행 비용을 낮춘다"의 "**전체** 비용"(그냥 "overall") 같은 무관한 문맥에도 매칭됐다.
- `elif` 체인이라 첫 매치에서 확정되고 끝 — `ui`가 먼저 매치되면 `review`/`refactor`/
  `debug`/`cli` 같은 훨씬 적절한 분기는 아예 검사조차 안 됐다.

**더 근본적인 문제**: `references/multimodel-coding-agent-routing-guide.md`(SSOT로
설계된 문서)에는 intent 키워드 표가 애초에 없다. `85d4463` 커밋이 이 분류 체계
전체를 코드에만 하드코딩해서 새로 만들었고, "가이드를 매번 파싱해서 동적으로
결정한다"는 SKILL.md의 설명과 실제 구현이 어긋나 있었다. 문서화도, 이후 회귀
검증도 없이 방치된 코드였다.

## 왜 지금까지 안 걸렸나

이 분류 함수들은 `85d4463`(2026-07-14) 도입 이후 실제 다양한 작업지시로
테스트된 적이 없었다. 기존 회귀 테스트(`test-meta-aware-routing.sh`)는
`ui`/`refactor` 같은 "깨끗한" 단일 키워드 fixture만 커버했고, 실제 작업지시처럼
여러 섹션(권한, 검증, 비용 등)이 섞인 자연스러운 한국어 텍스트로는 검증된 적이
없었다. 짧고 흔한 단어(`접근`, `전체`)가 여러 문맥에서 재사용된다는 점이
fixture 설계에서 빠져 있었다.

## 수정

`scripts/lib/routing-parser.sh`:

- `접근` → `접근성|a11y|accessibility` (진짜 접근성 문맥만 매칭)
- bare `전체` → `전체[[:space:]]+(저장소|코드베이스)`, `저장소[[:space:]]+전체`,
  `(entire|whole)[[:space:]]+(repository|repo|codebase)` 등 문맥 한정 표현
- T2의 `across`도 같은 패턴 취약점이 있어 `across[[:space:]]+(multiple|several|...)`로
  좁힘
- `review` 분기의 `확인해`도 유사 오탐 소지가 있어 제거 (범위 밖이었지만 같은
  카테고리 버그라 함께 정리됨)
- 회귀 테스트 8개 추가: "접근 권한은 UI가 아니라 debug", "저장소 전체는 T3",
  "전체 비용은 T3가 아님" 등 — 앞으로 같은 클래스의 오탐이 재발하면 바로 잡힘

## 부수적으로 드러난, 별개의 버그 (이번엔 수정 안 함)

작업 도중 두 가지를 더 발견했지만 이번 수정 범위에는 포함하지 않았다.
별도 작업으로 남겨둔다.

1. **`--chain` 플래그가 죽은 코드다.** `kant-loop.sh:918`에서 `KANT_AGENT_CHAIN`을
   export만 하고, 이 변수를 읽는 코드가 저장소 어디에도 없다. `--full` 모드에서는
   도구/모델을 강제 지정할 방법이 현재 전혀 없다 (`--agent`/`--model`은 quick
   모드 전용). `--full` 작업의 도구를 사용자가 직접 고르고 싶다면 지금은 불가능하다.
2. **dry-run의 `route` 표시와 `match` 서브커맨드는 `match-with-judgment`와 다른,
   더 단순한 경로를 쓴다.** 이번에 고친 `classify_task_intent`/`estimate_complexity`는
   `match-with-judgment`에서는 올바르게 반영되지만(`codex:gpt-5.6-sol` 확인됨),
   `kant-loop.sh run --dry-run`이 보여주는 `route:` 필드와 `routing-parser.sh match`는
   여전히 예전 방식으로 `agy:gemini-3.5-flash`를 보여준다 — 실행에는 영향 없지만
   dry-run 결과를 신뢰하면 안 되는 상태다.

## 이번 건에서 얻은 교훈

1. **"파싱/판정 실패"와 "실제 작업 실패"는 다른 문제인데, 같은 세션에서 두 번
   똑같은 패턴으로 나타났다.** 애초에 고치려던 TASK.md(OpenCode/GLM 어댑터)의
   핵심 주제가 "모델이 정상 작업을 했는데 verdict 파싱이 잘못돼서 실패로
   오판정된다"였는데, 그 문제를 고치는 과정에서 실행한 codex 호출도 똑같은
   클래스의 문제를 일으켰다 — 코드 수정과 테스트(18/18 PASS)는 정상 완료됐지만,
   codex가 자기 자신의 `git commit` 시도가 샌드박스 권한 문제로 실패한 걸
   작업 자체의 실패로 오판해 `BLOCKED`를 self-report했다. 실제 git diff·테스트
   결과를 최종 사실값으로 삼아 검증하니 정상 완료였음이 바로 확인됐다.
   → **모델의 자기 보고보다 실제 저장소 상태(git diff, 테스트 실행 결과)를
   항상 우선해서 검증한다.** 이게 TASK.md가 요구하던 설계 원칙 1번과 정확히
   같은 원칙이고, 여기서도 그대로 유효했다.
2. **키워드 기반 분류/라우팅 로직은 word-boundary 없이 짧은 단어를 쓰면
   반드시 오탐을 만든다.** 특히 한국어처럼 조사가 바로 붙는 언어에서는
   `grep -E`로 문맥 없는 1~2음절 단어를 매칭 조건에 넣는 순간 오탐 위험이
   크다. 새 키워드를 추가할 땐 "이 단어가 완전히 다른 문맥에서도 흔히
   쓰이는가?"를 먼저 따져야 한다.
3. **"SSOT 문서에서 동적으로 파싱한다"는 설명과 실제 구현이 다를 수 있다.**
   문서(`multimodel-coding-agent-routing-guide.md`)를 믿고 넘어가지 말고,
   실제 코드(`routing-parser.sh`)가 그 문서를 정말로 읽는지 직접 확인해야
   한다. 이번 경우 지문서엔 키워드 표 자체가 없었다.
4. **새로 도입된 판정 로직은 실제 프로덕션형 입력(여러 섹션이 뒤섞인 자연스러운
   작업지시)으로 한 번은 검증해야 한다.** 단일 키워드짜리 인공적인 fixture만
   통과하는 테스트는 이런 클래스의 버그를 못 잡는다.

## 후속 조치 후보 (전부 완료)

- [x] `--chain`을 `--full`/`--parallel` 모드의 실제 에이전트 선택 로직에 연결
      근거: `scripts/kant-loop.sh:550-558, 690-713, 1235, 1395, 1460`에서 chain을
      각 모드의 실제 agent/model 선택에 전달·사용 (routing-unification Phase 3,
      `b9582db`/`ede4aab`).
- [x] `kant-loop.sh run --dry-run`과 `routing-parser.sh match`가
      `match-with-judgment`와 동일한 결과를 보여주도록 통일
      근거: 동일 TASK 파일을 세 명령에 넣어 `intent`/`complexity`/`judged_route`/
      `effective_route`가 일치함을 확인 (routing-unification Phase 2, `79cdc19`).
- [x] `references/multimodel-coding-agent-routing-guide.md`에 intent 키워드 표를
      실제로 추가하거나, SKILL.md의 "가이드를 매번 파싱해서 동적으로 결정" 설명을
      코드 현실에 맞게 정정 — **후자로 해결**
      근거: `SKILL.md`의 "자동 라우팅 (T0~T4)" 섹션이 "판정 규칙의 SSOT는 코드다"로
      정정됨 (routing-unification Phase 4, `8335145`). 가이드 문서 자체에 키워드
      표를 추가하는 전략 A는 채택하지 않기로 명시적으로 결정됨.
- [x] `test-meta-aware-routing.sh`에 실제 작업지시 스타일(여러 섹션 혼합) fixture
      추가로 회귀 커버리지 강화
      근거: `scripts/tests/test-meta-aware-routing.sh:175-438`에 F1-F12/N1-N4
      다문단 fixture가 존재하고 테스트 60/60 PASS (routing-unification Phase 5,
      `a81dbf8`).
