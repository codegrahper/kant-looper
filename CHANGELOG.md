# CHANGELOG — Nomad Kant Looper

> 실행 경로: `~/.claude/skills/nomad-kant-looper` (main) · 개발 경로: `AGENTS/kant-looper-dev` (`Kant-looper-branch`)
> 프로젝트 시작: 2026-07-12

**버전 정책**: 0.x대 semver. `MINOR`(`0.X.0`)는 새 기능/아키텍처, `PATCH`(`0.X.Y`)는 인터페이스 변경 없는 버그 수정. `1.0.0`은 아직 사용하지 않음 — `--parallel` 실제 호출 검증과 claude 폴백 안정성이 더 쌓여야 붙임. 각 버전은 main의 해당 커밋에 `git tag v0.X.Y`로 소급 태깅되어 있음 (`git tag -l "v0.*"`로 확인).

---

## [Unreleased]

## [0.6.0] — 2026-07-21 — Nomad Kant Looper 정체성 확립 + Agent-agnostic Stage 1

### MANIFESTO 문구 정정 — Human Sovereignty + "왜 몸통이 없는가" (2026-07-21)

- **`f987686`**: Human Sovereignty 섹션에 "인간은 판단을 외주하지 않습니다"
  문장 추가, "사람"을 "인간"으로 통일
- **"왜 몸통이 Claude인가" → "왜 몸통이 없는가"로 재작성**: 아래 Stage 1
  리팩터로 SKILL.md에서 "Claude=오케스트레이터" 하드코딩을 걷어냈는데,
  MANIFESTO에는 "이 원칙을 실제로 조율하는 몸통은 Claude"라는 모순된 문장이
  남아있던 것을 발견해 정정. 이름의 철학적 기원은 Claude와의 설계 대화에서
  나왔지만, 원칙 자체는 어떤 Runtime의 몸에도 정착하지 않는다는 내용으로 수정

### Stage 1 — Agent-agnostic 아키텍처 스켈레톤 (2026-07-20)

맥스(Codex)와 상의해 작성된 설계 문서를 바탕으로, Nomad Kant Looper를
Claude Code 전용 스킬에서 Claude Code·Codex·OpenCode 모두가 오케스트레이터
(Meta Agent Host)로 쓸 수 있는 구조로 1단계 리팩터. 이 세션에서 세 런타임
모두 실제로 Meta Agent 역할을 수행하는 것을 라이브로 확인한 뒤 진행함.

- **증분 1·2 — SKILL.md 어휘 일반화** (`8e02b18`): 프론트매터
  description·Step 2 자동 선택 서술·설계 원칙 등 약 10곳의 "클로드/Claude"를
  "Meta Agent"로, `AskUserQuestion` 명칭을 "구조화된 선택 UI"로 치환. 순수
  어휘 치환이라 동작 불변 — `grep "클로드\|AskUserQuestion" SKILL.md` 0건 확인
- **증분 3 — `platform/` 스켈레톤** (`b593b4a`): 기존 `scripts/adapters/`
  (Worker Provider 축, 워커 호출용, 미변경)와 이름이 겹치지 않도록 런타임별
  Meta Agent Host 차이를 `platform/README.md`·`claude-runtime.md`·`codex.md`·
  `opencode.md` 4개 문서로 분리. `agents/openai.yaml`이 이미 Codex 전용
  메타데이터 분리 역할을 하고 있음을 문서화(신규 파일 불필요)
- **증분 4 — `$SKILL_DIR` 도입** (`ad7ec49`): SKILL.md의 `$HOME/.claude/skills/nomad-kant-looper/...`
  하드코딩 경로 3곳을 `$SKILL_DIR`로 치환. 본문과 Technical Reference에
  중복 서술돼 있던 `--detach`+`run_in_background`+PostToolUse 훅 상세
  내용을 `platform/claude-runtime.md`로 이동
- **증분 5 — `install.sh`** (`478b98d`): `./install.sh --agent claude|codex|opencode|all|auto [--dry-run] [--force]`.
  symlink나 단순 clone이 아니라 `git worktree` 방식 채택(Claude 쪽은 이미
  이 방식으로 검증됨). 기존 foreign clone(`~/.codex/skills/nomad-kant-looper`)은
  자동으로 지우지 않고 감지 후 거부, `--force`로만 제거 후 worktree로 재연결.
  실제로 `--agent claude`/`--agent codex` 둘 다 라이브 실행해 worktree 생성 확인
- **`d05ad74`**: `test-meta-agent-loop.sh`의 스킬 리네임(kant-looper→
  nomad-kant-looper) 이전 하드코딩 경로 수정
- **보류(이번 범위 밖)**: 설계 결정 6(config priority의 ENV 위치), PLAN/VERIFY를
  bash phase로 재구현하는 것(2026-07-17 HPRAR 포기 결정과 충돌하므로 문서
  라벨링으로만 처리), `fallback-dispatcher.sh` 체인 내부 로직,
  `no-progress-detector.sh`(죽은 코드), `references/loop-flow.md` 등 이미
  낡은 참고문서 — 전부 그대로 둠
- **검증**: `scripts/tests/test-all.sh` 17개 스위트 전부 PASS, `bash -n`으로
  `install.sh`/`kant-loop.sh` 문법 확인

### Nomad Kant Looper 정체성 확립 — 매니페스토·리네임·저장소 이전 (2026-07-19)

- **MANIFESTO.md 신설** (`16c9856`): "Nomad Kant Looper" 정체성 선언 —
  6개 핵심 가치(Principle Sovereignty, Switchability, AI Pluralism, Bounded
  Delegation, Human Sovereignty, Verifiable Autonomy)
- **README 재작성 + MANIFESTO.md로 파일명 확정** (`f784230`): 제목·본문의
  "Kant Looper" 표기를 "Nomad Kant Looper"로 전환. 기존 철학 설명 섹션
  155줄을 MANIFESTO.md 링크 + 태그라인 3줄로 축약(270→123줄)
- **스킬 리네임** (`577d730`): SKILL.md 프론트매터 `name`을
  `nomad-kant-looper`로, 슬래시 커맨드 `/kant-looper`→`/nomad-kant-looper`
  전면 교체
- **인프라 이전** (커밋 아님, 수동 작업): GitHub 저장소를
  `codegrahper/Kant-Looper`→`codegrahper/nomad-kant-looper`로 `gh repo
  rename`, 배포 디렉터리를 `~/.claude/skills/kant-looper`→
  `~/.claude/skills/nomad-kant-looper`로 이전(메인 워크트리라
  `git worktree move` 불가 — `mv` 후 `git worktree repair`로 두 linked
  worktree 복구), 로컬 3곳(`kant-looper-dev`, 배포 워크트리,
  `fix/claude-subscription-login` 워크트리)의 origin remote URL을 새
  저장소로 갱신해 "저장소 이동" 경고 제거

### PostToolUse 훅 자동 완료 알림 — 도입 후 신뢰성 미달로 되돌림, 그 과정에서 발견한 체인 버그는 수정 (2026-07-19)

- **PostToolUse asyncRewake 훅 도입** (`7a1ff94`, 담당: 클로드)
  - `--detach`로 던진 외부 도구 실행이 끝나면 `.claude/settings.json`의
    `PostToolUse(Bash)` 훅(`scripts/hooks/kant-loop-auto-await.sh`,
    `asyncRewake: true`)이 자동으로 `await`를 백그라운드에 걸고 클로드를
    깨우도록 만듦. 클로드가 매번 수동으로 `await`를 background로 이어
    거는 단계를 없애려는 시도.
- **실전 3회 테스트 결과 신뢰할 수 없다고 판명, 도입 전 수동 패턴으로 복원**
  (`e1c8968` SKILL.md 되돌림, `9bff2cc` 훅 등록/스크립트 삭제)
  - 1회 정상 작동 / 1회 조기 오탐(아래 버그가 원인) / 1회는 실제로
    완료·커밋까지 됐는데도 원인 불명으로 완전히 침묵 — 아무 신호도 없이
    조용히 실패하는 쪽이 "깜빡함"보다 더 나쁜 실패 모드라고 판단
  - Step 3 실행 절/Rules 절/Technical Reference 모두 `--detach` 후
    `await`를 Bash 도구 `run_in_background: true`로 즉시 이어 거는 기존
    수동 패턴으로 되돌림. 훅 파일 자체는 침묵 원인 조사용 증거로 잠시
    남겨뒀다가, 신뢰하지 않기로 한 채 등록만 방치하면(매 Bash 호출마다
    불필요한 서브프로세스 스폰 + 나중에 경고를 놓치고 재의존할 위험)
    의미가 없다고 판단해 완전히 삭제함
- **원인 조사 중 발견한 진짜 버그: 체인 중간 단계 `result.txt` 조기 기록**
  (수정 `e65df54`, 회귀 테스트 `0a3740a`)
  - `run_quick_mode`가 `commit_at_end=0`이면 무조건 공유 `result.txt`에
    `pass_no_commit`을 썼는데, `run_quick_chain`은 implement/review/repair
    3단계 모두 `commit_at_end=0`으로 호출해서, 체인이 아직 안 끝났는데도
    중간 단계 하나가 PASS할 때마다 마치 최종 완료처럼 `result.txt`가
    덮어써졌다. `cmd_await`(및 위 훅)는 이 조기 기록을 완료로 오판했다.
  - `run_quick_mode`에 8번째 파라미터 `defer_terminal_result`(기본값 0,
    기존 standalone 호출 동작 불변) 추가. `run_quick_chain`만 각 단계
    호출에 `1`을 넘겨 중간 단계가 `result.txt`를 건드리지 않게 함.
    실제 위임(codex:gpt-5.6-sol)으로 구현했고, 클로드가 diff와
    `test-all.sh` 재실행으로 직접 검증함.
  - 회귀 테스트 `scripts/tests/test-chain-result-race.sh` 신설,
    `test-all.sh`에 등록. 즉시 응답하는 가짜 adapter로 4가지(중간 단계
    `result.txt` 무결성, 체인 성공 시 최종 기록, standalone review 기존
    동작 유지, 체인 중간 실패 시 즉시 실패) 검증
  - 실전 라이브 체인(opencode:glm-4.7 → codex:gpt-5.6-terra → codex:gpt-5.6-luna)
    으로 재검증: implement PASS(08:44:30) 후 review가 끝날 때까지
    (08:47:42) 조기 완료 신호 없음 확인. review는 별개로
    `CHANGES_REQUESTED`(내용 리뷰, 메커니즘과 무관)를 냈고 chain은
    설계대로 즉시 실패 처리, repair 미호출을 확인함

### 오픈소스 공개 대비 + 라우팅 가이드 간소화 (2026-07-18)

- **SKILL.md 오픈소스 대응** (`f55443e`, 담당: 클로드)
  - 특정 사용자 이름("이바") 참조 3곳을 일반 표현으로 교체
  - Step 1 오프닝 문구를 "Nomad Kant, 칸트와 유랑합니다. 🙏"로 교체 (이전: "어떤 작업을 할까요?")
  - agy가 선택되는 모든 경로(Step 0 단축입력/자동 선택/직접 선택)에 Google
    Stitch(UI 디자인 생성 MCP) 사용 여부를 묻는 대화창 추가 — agy가 Stitch
    MCP에 연결돼 있어도 프롬프트에 명시하지 않으면 안 쓰던 공백을 메움
- **라우팅 가이드 대폭 간소화** (`10bf729`) — `references/multimodel-coding-agent-routing-guide.md` 637줄 → 139줄
  - 시장 전체 모델 서베이에서 SKILL.md Step 2로 실제 선택 가능한 12개 모델만 남김
  - 실제와 다른 가상의 MCP 요청 스키마/툴 분리 절을 실제 어댑터 호출 계약
    (CLI 직접 호출 → stdout 파싱)으로 재작성
  - HPRAR와 같은 발상이던 자동 상향 상태 머신, `safety-promises.md`와 겹치던
    보안 체크리스트, 미사용 평가 가중치표, 지켜지지 않던 유지보수 주기표 삭제
  - 라이브 재현 결과도 함께 기록: opencode glm-4.7 verdict 누락 재현이
    엇갈려(다른 세션 2/2 실패, 이 세션 2/2 통과) 확실한 반복 재현 없이는
    모델을 제거하지 않기로 함
- **어댑터 주석 오류 수정** (`6473efc`) — `adapter-opencode.sh`의 예시 주석이
  실제 provider(`zai-coding-plan`)가 아니라 무관한 `opencode-go`를 가리키던
  오기 정정
- **GLOSSARY.md 신설 — 16→84개 용어** (`3eb9aa1`, `bb884f0`, `a738a8c`,
  `180d69a`, `1ad5a91`)
  - 비개발자가 클로드와 소통하는 데 필요한 개발 용어 사전. 서브에이전트
    실행 중에만 등장하고 대화에 직접 드러나지 않은 용어까지 포함
  - Git/프로세스·시스템/데이터 형식/테스트·품질/LLM·에이전트/CLI 관례/
    칸트루퍼 고유 용어 7개 카테고리로 구성

### 이벤트 기반 에이전트 간 자동 디스패처 POC — 추가 후 되돌림 (2026-07-17, 이바 확정)

- **agy 어댑터 프롬프트 인자 순서 버그 수정** (`214ca0b`)
  - agy가 `--print`류 플래그를 값 받는 플래그로 처리해 프롬프트를 마지막
    위치인자로 넘기면 무시함, 게다가 `--sandbox`가 `-p`보다 뒤에 오면
    `bubbletea: could not open TTY`로 죽는 인자 순서 의존성을 실측으로 확인
    — `-p`를 맨 앞으로 이동
  - verdict-extractor의 `validate` 호출이 `set -e` 아래에서 실패 시 어댑터를
    죽이던 문제에 가드 추가, 죽은 중복 폴백 코드를 `process` 서브커맨드
    호출로 교체해 `<verdict>` 태그 폴백이 실제로 동작하게 함
- **event/dispatcher POC 구현 후 라이브 검증, 구조적 결함 발견해 되돌림**
  (`87eb498` 추가 → `26618bc` 되돌림)
  - `scripts/event/`, `scripts/dispatcher/`, `config/dispatch-routes.json`으로
    에이전트 간 자동 콜백·라우팅 POC를 구현, `agy-ui-test-codex` 3단계를
    실제 라이브로 기계적으로 완주까지 확인
  - 그 과정에서 `--no-auto-commit`이 `--detach`에서 항상 무시되는 버그도
    발견해 수정 — `export AUTO_COMMIT=0`이 `--detach`의 nohup 재실행 자식
    에는 전파되지 않던 문제. `KANT_AUTO_COMMIT`도 함께 export하도록 고침
  - 하지만 `dispatcher.py`의 `verify()`가 에이전트의 실제 verdict(PASS/
    CHANGES_REQUESTED)를 전혀 보지 않고 diff+safety+gate 통과 여부만
    확인해, codex가 명확히 `CHANGES_REQUESTED`를 낸 리뷰도 워크플로우가
    `completed`로 마감하는 구조적 결함 발견 — 리뷰어가 거부한 코드가
    완료로 보고된 것
  - 이바는 이 판정 로직을 기계 검증에 반영하는 대신, 에이전트 간 자동
    디스패처·콜백 자체를 포기하고 클로드가 감독자로 남는 구조
    (`클로드 → 외부 에이전트 → 콜백 → 클로드 검증`)로 확정 —
    `scripts/event/`, `scripts/dispatcher/`, 관련 테스트 5종,
    `cmd_workflow`/`--workflow`/`--step` 전부 제거. `run --quick
    [--detach]`/`await`/`status`/`report`/`--existing-worktree` 등
    클로드가 직접 쓰는 기존 primitive는 유지
  - 자세한 경위는 `PLAN-lightweight-kant-looper.md` 참고

### quick 안정화 + HPRAR(`--full`) 포기 (2026-07-17, 이바 확정)

- **--parallel/--full 라이브 버그 3건 수정** (`59b187a`, 담당: OpenCode/GLM-5.2,
  검증: 클로드)
  - `run_parallel_mode`가 role을 파일명용 "implement-N"으로 만들어 어댑터
    `call`에도 그대로 넘겨, `adapter-codex.sh`/`adapter-opencode.sh`의
    정확 문자열 비교(`"implement"`/`"repair"`)에 안 걸려 codex는 읽기전용
    으로 폴백, opencode는 `--auto` 없이 실행되던 문제 — role과 파일명용
    slice_id를 분리
  - parallel 프롬프트가 "위 quick 모드와 동일"이라고 참조했지만 parallel은
    독립 파일이라 "위"가 없어 opencode가 파싱 가능한 verdict를 못 냄 —
    quick 모드와 같은 JSON 스키마+`<verdict>` 태그 안내를 parallel/full
    프롬프트에 그대로 인라인
  - agy CLI 1.1.3이 짧은 모델 ID(`gemini-3.5-flash`)를 거부하고 표시 이름
    (`Gemini 3.5 Flash (Medium)`)만 받게 바뀜 — 어댑터에 정규화 로직 추가,
    사라진 `gemini-3.1-flash-lite`는 모델 목록에서 제거
  - 검증: codex/opencode/agy 세 조합 모두 `--quick`/`--parallel --chain`으로
    실제 PASS 재현 확인
- **HPRAR(`--full`) 포기 결정 기록** (`a80dc7d`)
  - `--parallel`/`--full` 라이브 실패를 계기로 "자동 라운드 체이닝(HPRAR)
    자체가 구조적으로 반복 실패한다"는 근거가 논의됐으나, 클로드가 근거로
    제시된 별도 프로젝트의 실제 기록을 직접 확인한 결과 뒷받침이 불충분함을
    확인해 이바에게 보고. 이바는 그 검증 결과를 기다리지 않고 이 시점에
    독립적으로 HPRAR 포기를 확정
  - 대안: 복잡한 작업은 클로드가 `--quick` 호출을 여러 번 조합해 대화 중
    직접 운영
- **run_full_mode 및 HPRAR 코드 제거** (`7477faf`, 담당: 클로드)
  - `kant-loop.sh`에서 `run_full_mode`와 관련 full 시나리오 전부 삭제
    (kant-loop.sh 순감소 487줄), 기본 quick·3단계 quick 체인·읽기 전용
    parallel 계약으로 정리
  - `--full` 호출 시 "HPRAR 모드는 중단되었습니다. --quick 또는 --quick
    --chain을 사용하세요" 에러로 명시 안내
  - OpenCode 라이브 3회 연속 성공으로 quick 경로 재검증

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

### `fix/claude-subscription-login` — 병합 완료 (`d2c8dce`로 `Kant-looper-branch`에, 이후 main까지 반영됨. `v0.5.1` 별도 태깅은 안 함 — v0.5.0 범위에 이미 포함)

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
