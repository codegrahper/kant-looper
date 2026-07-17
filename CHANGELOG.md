# CHANGELOG — Kant-Looper

> 실행 경로: `~/.claude/skills/kant-looper` (main) · 개발 경로: `AGENTS/kant-looper-dev` (`Kant-looper-branch`)
> 프로젝트 시작: 2026-07-12

**버전 정책**: 0.x대 semver. `MINOR`(`0.X.0`)는 새 기능/아키텍처, `PATCH`(`0.X.Y`)는 인터페이스 변경 없는 버그 수정. `1.0.0`은 아직 사용하지 않음 — `--full`/`--parallel` 실제 호출 검증과 claude 폴백 안정성이 더 쌓여야 붙임. 각 버전은 main의 해당 커밋에 `git tag v0.X.Y`로 소급 태깅되어 있음 (`git tag -l "v0.*"`로 확인).

---

## [Unreleased]

### 경량화 5단계 — SSOT/자기개선 코드 제거 (2026-07-17, 이바 승인)

`PLAN-lightweight-kant-looper.md` 방향 전환에 따라, 아래 `routing-ssot-integration`
섹션이 설명하는 기능 전체(2주 관찰 시험 포함)를 **되돌리고 제거**했다. 판단은
셸 스크립트가 아니라 클로드가 그 자리에서 하는 쪽으로 확정.

- **삭제**: `scripts/lib/routing-parser.sh`(834줄), `ssot-shadow.sh`(170줄),
  `ssot_loader.py`, `routing-ssot/` 디렉토리 전체, 관련 테스트 6종
  (`test-ssot-stress-simulation.sh`, `test-self-improvement.sh`,
  `test-ssot-shadow.sh`, `test-routing-source-ssot.sh`,
  `test-routing-ssot-sync.sh`, `test-meta-aware-routing.sh`),
  `references/ssot-shadow-mode.md`, `ssot-2WEEK-trial.md`
- **`kant-loop.sh`**: `self-scan`/`self-dispatch` 서브커맨드와 관련 함수군
  전부 제거. quick/parallel/full 모드의 `AUTO_ROUTE`·`ssot_shadow_observe`
  분기 제거 — 기존에 이미 있던 하드코딩 기본값(`codex:gpt-5.6-terra` 등)만
  남김. `--parallel` 모드는 자동 슬라이싱이 없어졌으므로 `--chain` 명시가
  필수로 바뀜(생략 시 즉시 에러).
- **`model-selector.sh`**: `auto` 서브커맨드(routing-parser 의존) 제거,
  `list-agents`/`list-models`/`validate`/`select`는 유지.
- **`fallback-dispatcher.sh`**: `KANT_ROUTING_SOURCE=ssot` 분기 제거,
  하드코딩 fallback chain만 사용.
- **문서**: SKILL.md의 "자동 선택"/"자동 라우팅" 절을 코드 판정 서술에서
  "클로드가 판단, 표는 참고용 휴리스틱"으로 재작성. `references/loop-flow.md`,
  `references/fallback-table.md` 동기화. postmortem
  (`references/postmortems/2026-07-15-routing-keyword-collision.md`)은
  역사적 기록으로 보존하고 후기만 추가.
- **검증**: `test-all.sh`(14개 테스트), `run-scenarios.sh`(A/B/C 시나리오
  dry-run) 전부 재통과 확인.

### `routing-ssot-integration` → 병합 시 `v0.5.0` 예정 (main 병합 대기 — 2주 `KANT_ROUTING_SOURCE=ssot` 관찰 + 이바 승인 필요)

> **상태(2026-07-17)**: 위 "경량화 5단계"에서 이 섹션이 설명하는 코드 전체가
> 제거됐다. 아래는 왜/어떻게 만들어졌는지에 대한 역사적 기록으로 남긴다.

- **SSOT 라우팅 통합 — 5단계** (담당: OpenCode, 검증: 클로드)
  - **Phase 1** (`3842c68`) — `/Users/drumqube/Downloads/kant-looper-routing-ssot-package`를 `routing-ssot/`로 이식, agy 검증 리포트가 지적한 코드 불일치 해소: Anthropic/Claude provider 및 `claude:default` 모델 등록(치명 결함이던 "최종 안전망 누락" 해결), agent-model 바인딩 필드 추가, `review` route 추가, `o3` 등록. models 15→16, routes 6→7
  - **Phase 2** (`85e7c98`) — `validate-routing-ssot.py`에 코드-정합 invariant 5종 추가: agent-model 호환성, fallback 최종 안전망(Claude) 존재, scoring 가중치 합계=100, route tier ↔ 모델 tier 교차, provider별 최소 1개 모델. 음성 케이스 8개(`tests/test_validator.py`) 전부 실패로 잡히는지 확인
  - **Phase 3** (`d4b63d9`) — `scripts/lib/ssot-shadow.sh` 신설: `KANT_SHADOW_MODE=on`일 때만 활성화되는 비침해 관찰 모드. 하드코딩 라우팅 결과와 SSOT 라우팅 결과를 TSV로 기록만 하고 실제 판정에는 개입하지 않음 (기본 OFF, 로그 생성 안 됨 확인)
  - **Phase 4** (`a820684`) — `KANT_ROUTING_SOURCE=ssot` 토글 추가. 기본값(`hardcode`)은 기존 동작 100% 보존, 명시적으로 켜야 SSOT가 실제 라우팅 소스가 됨
  - **Phase 5** (`c703d91`) — hardcode↔SSOT drift 감지 회귀 테스트 4종 추가 (6개 라우트 primary 동기화, fallback chain 동기화, 전체 chain이 claude 안전망으로 끝남, 기본 상태 유지). **하드코딩 제거는 보류** — `PHASE-3-5-PLAN.md`에 "2주 이상 SSOT 모드 운영 + 이바의 명시적 승인" 조건 명시, 자의적 제거는 안전 약속 위반으로 판단해 보수적으로 유보
  - 검증: `test-all.sh` 16/16 PASS, 검증기 `VALID` (models=16, routes=7), 기본 상태·shadow ON·SSOT 토글 전부 클로드가 직접 재현 확인 (hardcode/SSOT 모드 route 완전 일치)

### `fix/claude-subscription-login` → 병합 시 `v0.5.1` 예정 (`Kant-looper-branch` 기준, 병합 대기)

- **Claude 어댑터를 구독 로그인 방식으로 고정 + MiniMax-M3 잔재 제거** (`cd56f6c`, 담당: OpenCode, 검증: 클로드)
  - 근본 원인: `health-check.sh`의 claude 분기가 `~/.claude/credentials.json` 또는 `ANTHROPIC_API_KEY` 존재를 요구 → OAuth 구독 로그인 상태에서는 둘 다 없어 claude가 항상 `UNAVAILABLE`로 오판, 8개 fallback chain의 최종 안전망이 무력화됨 (`QUICK_CALL_FAILED / INFRA_ERROR exit=201`)
  - 수정: 인증 확인을 claude CLI 자체에 위임 (파일/API키 강제 조건 제거), 인증 실패는 호출 시점에 `FAIL:FINAL_FALLBACK_FAILED`로 감지
  - `agents/openai.yaml`, `references/fallback-table.md`, `references/failure-modes.md`에 남아있던 "claude = MiniMax-M3" 표기 전부 `claude:default`로 정렬 (실행 코드 `fallback-dispatcher.sh`는 이미 정상이었음 — 문서만 어긋나 있었음)
  - 신규 회귀 테스트 `test-claude-health-subscription.sh` (mock claude + 격리 HOME, 5/5 PASS)
  - 검증: 실제 구독 로그인 상태에서 `health-check tool claude` rc=0, 실제 `--quick --agent claude --model default` 호출이 `pass_no_commit`으로 완주 (이전엔 실패하던 시나리오) — 클로드가 직접 재현·확인
  - **범위 밖으로 명시 보호**: `failure-context.sh`의 `ANTHROPIC_AUTH_TOKEN`/`ANTHROPIC_BASE_URL` 마스킹 정규식은 시크릿 삭제 대상이 아니라 보안 기능이라 변경하지 않음

---

## [0.4.0] — 2026-07-15 — `@도구[:모델]` 단축 입력

- **`/kant-looper @도구[:모델]` 단축 입력** (`54d5050`, 담당: 클로드)
  - Step 0 신설 — 메시지 맨 앞 `@codex`/`@opencode`/`@grok`/`@agy`/`@claude` 토큰 인식
  - `@도구:모델` + 작업 설명 → Step 1/2 스킵, 바로 Step 3 / `@도구`만 있으면 모델 선택 UI로 직행 (자동 기본값 임의 선택 금지) / 무효 토큰은 무시하지 않고 안내 후 정상 흐름 복귀
  - Claude는 별도 모델 목록이 없어 Step 0에서 바로 default로 처리하도록 예외 처리 확인 (실사용 중 발견)

---

## [0.3.0] — 2026-07-15 — 라우팅 판정 일원화

- **라우팅 판정 일원화 — 5단계** (`routing-unification`, 담당: Codex/GPT-5.6, 검증: 클로드)
  - **Phase 1** (`a259dc2`) — `judge_task_routing()` 단일 판정 함수 도입 + 증거 점수화(긍정/부정 신호 가중치). `접근`→`접근성|a11y|accessibility`, bare `전체`→저장소/코드베이스 문맥 한정으로 좁혀 오탐 제거
  - **Phase 2** (`79cdc19`, 정리 `e9daca0`) — `match`/`match-with-judgment`/dry-run 3개 진입점을 전부 `judge_task_routing()`로 통합, `judged_route`/`effective_route`/`fallback_reason` 구분 도입. (`e9daca0`: 초기 커밋에 실수로 섞여 들어간 세션 로그·잡파일 7개를 별도 정리 커밋으로 제거, `.gitignore`에 `.DS_Store`/`.omo/run-continuation/*.json` 추가)
  - **Phase 3** (`b9582db`, 배선 수정 `ede4aab`) — `--chain`을 `--full`/`--parallel` 실제 실행에 연결. 최초 구현에서 dry-run 출력 누락과 `--detach` 경로에서 체인이 조용히 사라지는 배선 버그 2건을 클로드가 발견해 같은 세션에서 수정
  - **Phase 4** (`8335145`) — SSOT 전략 B 확정: 코드가 판정 규칙의 SSOT, 가이드 문서는 모델명만 제공. SKILL.md의 "가이드를 매번 파싱해서 동적으로 결정"이라는 부정확한 서술 정정
  - **Phase 5** (`a81dbf8`) — 실제 문서형 fixture 18개 + 속성 기반 부정 테스트 추가, 60개 회귀 테스트 전체 PASS
  - 근본 원인이었던 오분류 사례: 순수 bash 어댑터 작업이 `ui`/`T3`로 오분류되어 `agy:gemini-3.5-flash`(브라우저 전용 도구)로 잘못 라우팅되던 문제 — `references/postmortems/2026-07-15-routing-keyword-collision.md`에 포스트모템 기록 (`77c4114`)
  - 병합 경로: `routing-unification` → main ff-only(`26bca47`), `Kant-looper-branch`를 main과 동기화(`8044cc4`)

---

## [0.2.1] — 2026-07-15 — MiniMax 경계·에이전트 기본모델 정리 (패치)

- **MiniMax 모델 경계 정리** (`4c00ff1`) — `is_official_minimax_model()` 3-모델 allowlist 도입, claude 어댑터가 provider prefix와 무관하게 모든 MiniMax 변형 거부, `fallback-dispatcher.sh`의 `claude|MiniMax-M3`를 `claude|default`로 전면 교체, 51개 MiniMax 라우팅 테스트 추가
- **에이전트 기본 모델 + 상대경로 프롬프트** (`4c0737c`) — `--agent`만 지정 시 도구별 기본 모델 사용(`get_default_model()`), 모델-도구 호환성 사전 검증(`validate_agent_model_compatibility()`), 모든 에이전트 프롬프트에 "워크트리 루트 기준 상대경로만 사용" 규칙 추가 (32+9 assertions)
- **커밋 전 Python 런타임 캐시 자동 정리** (`83d3e66`) — quick 모드에서 4개 에이전트 실행 중 생성되는 `__pycache__`가 protected-path 정책에 걸려 정상 산출물 커밋을 막던 문제 해결 (경로는 워크트리 내부로 제한, 소스에 커밋된 캐시 차단 정책은 유지)

---

## [0.2.0] — 2026-07-14 — meta-agent 자가치유 루프 + 멀티모델 확장

- **모델 지원 확장**: codex 5.6 sol/terra/luna, opencode glm-5.2/4.7 (`a440349`)
- **라우팅 SSOT 기반 + health-check 폴백** (`85d4463`)
- **meta-agent 자가치유 모듈 신설** (`05ba7ce`, `2bb5f29`, `d5c13e3`, `c005945`, `4043870`, `342eb88`, `c9ddfc8`)
  - `failure-context.sh`(실패 시 YAML 컨텍스트 캡처 + secret redaction) → `failure-analyzer.sh`(claude 메타 분석) → `fix-apply.sh`(제안된 패치를 `fix/` 브랜치에 안전 적용)의 자가치유 루프. 최초 모듈 테스트 7/7 PASS(`2bb5f29`)
  - 리뷰 피드백 반영 P0/P1 보안 가드 전면 재설계(`c005945`): 모델의 임의 shell 명령 실행(`commands_to_run`) 인터페이스 완전 제거, Python 인라인 보간 제거(별도 스크립트 분리), branch명 강제 검증(`fix/[a-zA-Z0-9._/-]+`, main/master 명시 거부), 작업트리 clean 검증 + 파일별 개별 staging(광역 `add -A` 금지), canonical path 검증(realpath 기반 저장소 외부 경로 거부), idempotency marker, 재진입 가드
  - 실제 git worktree에서 fix-apply를 호출하는 e2e 통합 테스트 추가(`342eb88`, 리뷰어 P1 "테스트가 실제 주요 경로를 검증하지 않음" 피드백 대응) — 핵심 보안 가드 6/6 PASS
  - BSD sed(`\{\}` 멀티라인) + 한글 멀티바이트 헤더 패턴 매칭 실패로 `guard_path_in_repo`가 source 후 미정의되던 테스트 인프라 버그 수정(`4043870`) — 회귀 총 38/38 PASS로 갱신
  - `jq` 의존성 추가, `mark_applied`가 커밋 성공 시에만 마커를 쓰도록 수정, `commands_to_run` 필드는 무시하되 경고 로그만 남기도록 처리(`c9ddfc8`) — e2e 11/11 PASS
  - 테스트: `test-fix-apply-redesign.sh` 12/12, `test-fix-apply-guards.sh` 8/8, `test-meta-agent-loop.sh` 7/7
- **secret redaction 영구 회귀 테스트** (`90bd27f`, `620e175`) — `failure-context.sh`의 `redactor()`가 보안 critical인데 이전 inline 검증(7/7 PASS)이 커밋 없이 사라졌던 걸 발견, `test-redactor.sh`로 영구화(OpenAI/MiniMax/Anthropic 키 prefix, Bearer 헤더, URL userinfo, 홈 디렉터리, 여러 줄 분산 secret 등 8종 시나리오), `test-all.sh` wrapper에 등록
- **테스트 통합** (`bdc217c`) — `scripts/tests/test-all.sh` 신설, 산재한 6~7개 회귀 테스트를 한 명령으로 통합 실행

---

## [0.1.1] — 2026-07-13 ~ 07-14 — 어댑터 verdict 파싱 안정성 (패치)

- **grok 샌드박스 감지 + opencode 모델 정규화** (`29f6f4c`) — `~/.grok/sandbox.toml` 부재/프로필 미정의 시 `--sandbox` 플래그 생략, bare 모델명(`glm-5.2` 등)을 `opencode-go/model` 포맷으로 정규화
- **JSON 추출 하드닝** (`ceef89d`, `da03576`) — brace-counting 파서가 중첩 JSON에서 실패하던 문제, `<verdict>` 태그 폴백 추가, 모델 자기보고 대신 실제 `git diff`로 `changed_files` 교차검증. 9회 반복 호출 실패율 1/9 → 0/9로 개선
- **`do_fallback()` verdict 누락 수정** (`d8c675e`, `e939521`, `ed531b8` PR A) — fallback 성공 시 `tool:model` 문자열을 그대로 echo해 quick 모드가 이를 verdict로 오인, 성공한 fallback도 항상 실패 처리되던 버그 수정

---

## [0.1.0] — 2026-07-13 — verdict 검증 정확도

- **`changed_files` 실제 diff 교차검증** (`5499dba`) — opencode/glm-4.7이 실제로 파일을 쓰지 않고도 자신 있게 `verdict=PASS` + 상세 `changed_files`를 보고하는 사례를 재현, `verify_changed_files()`를 3개 모드 전체에 배선해 모델 자기보고와 실제 git 상태 불일치 시 `CHANGED_FILES_MISMATCH`로 차단
- **claude/grok JSON envelope 언랩** (`c5b55de`) — `claude --output-format json`이 응답을 `"result"` 문자열로 한 겹 감싸 codefence/brace 파서가 못 찾던 문제, grok의 `"text"` 래핑도 동일 처리

---

## [0.0.1] — 2026-07-12 — 최초 스냅샷

- **kant-looper 스킬 초기 아키텍처 전체** (`e551c9d`, 23개 파일 · 6,135줄 · "버전 관리 시작 전 스냅샷"으로 한 커밋에 통째로 커밋됨 — 이전 개발 이력은 git에 없음)
  - **SKILL.md** — Meta Agent 3단계(Step1 작업 확인 → Step2 자동/직접 도구 선택 → Step3 작업지시 생성) + `--quick`/`--parallel`/`--full` 3모드 설계
  - **5개 어댑터** (`scripts/adapters/`) — codex, grok, opencode, agy, claude 각각 독립 호출 인터페이스
  - **8개 lib 스크립트** (`scripts/lib/`):
    - `routing-parser.sh` — 라우팅 가이드 파싱 + 키워드 매칭
    - `health-check.sh` — 호출 전 도구 가용성 점검
    - `safety-check.sh` — protected path·forbidden pattern(시크릿) 검사
    - `gate-runner.sh` — 테스트/빌드 게이트
    - `no-progress-detector.sh` — 동일 diff 반복·무진전 자동 중단
    - `timeout-runner.sh` — 프로세스 실행 + 타임아웃 관리
    - `fallback-dispatcher.sh` — 도구 실패 시 대체 체인
    - `verdict-extractor.sh` — 모델 응답에서 verdict JSON 추출
  - **references 6종** — `multimodel-coding-agent-routing-guide.md`(SSOT 라우팅 가이드, 637줄), `loop-flow.md`, `verdict-schema.md`, `safety-promises.md`, `failure-modes.md`, `fallback-table.md`
  - **`agents/openai.yaml`** — 인터페이스 메타 정의
  - **`scripts/tests/run-scenarios.sh`** — 초기 시나리오 테스트
  - **안전 원칙**: 자동 push 금지 · main 직접 커밋 금지 · rebase/`reset --hard` 금지 · protected paths 차단 · merge는 `promote` 명령으로만 사용자 승인 후 실행 — 이 5원칙은 이후 지금까지 한 번도 변경되지 않음
- **agy `--sandbox` read-only 우회 차단** (`93f8b34`) — `--sandbox`는 터미널 실행만 제한하고 파일 쓰기는 막지 않아, `--dangerously-skip-permissions`와 결합 시 plan/review/verify 같은 읽기 전용 역할도 파일을 쓸 수 있었던 취약점. `--mode plan`(읽기 전용) / `--mode accept-edits`(쓰기 허용)로 역할별 분리
- **모든 외부 CLI 어댑터의 격리 cwd 강제** (`7e07863`) — `kant-loop.sh`가 워크트리를 생성하고도 실제로 `cd`하지 않아, 5개 어댑터가 스폰하는 프로세스가 전부 사용자의 원본 체크아웃에서 실행되던 문제. `timeout-runner.sh`의 `run_with_timeout()`에 `cwd`를 fail-closed 필수 인자로 추가
- **README 요구사항 + 퀵스타트 추가** (`ee70fad`)
- **safety-check staging 버그 + 패턴 quoting 버그** (`88bf44c`) — 신규 파일만 생성하는 작업에서 `git add` 없이 `git diff --cached`를 검사해 secret 스캔이 아무 내용도 못 보던 문제, `FORBIDDEN_PATTERNS`의 unquoted 순회로 인한 glob 오전개(cwd의 dotfile을 패턴으로 오인) 수정
- **agy CLI 실전 노트** (`cfba3a9`) — `--sandbox`/`--add-dir`/`--dangerously-skip-permissions`의 실제 동작을 공식 문서와 재현으로 교차검증해 `references/agy-cli-notes.md`로 기록
