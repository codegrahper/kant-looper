# 칸트 루퍼 경량화 플랜 (0.6 방향 전환)

> 2026-07-17, 이바와의 대화로 결정. 이 문서는 앞으로 진행할 작업의 기준점이다.
> 새로운 기능을 더 붙이는 계획이 아니라, **지금 있는 것 중 무엇을 걷어내고
> 무엇을 남길지**를 정한 문서다.

## 왜 이 플랜인가

- 칸트 루퍼는 SSOT 자동 라우팅 + 자기개선(섀도우 관찰, self-scan/self-dispatch)을
  더하며 6,500줄 셸 시스템이 됐다. 오늘까지 발견된 파싱 버그(`SCRIPT_DIR` 충돌,
  `effective_route` 멀티라인 오염, `ssot_shadow_check_env` 불필요한 커플링)가
  전부 이 확장에서 나왔다.
- "어떤 작업에 어떤 도구/모델을 쓸지 판단"하는 역할은 원래 셸이 아니라
  **클로드가 할 일**이었다. SSOT 엔진은 그 판단을 셸에 아웃소싱했다가
  계속 부서진 것에 가깝다.
- 이바가 원하는 최종 형태: 클로드가 opencode/agy/grok/codex를
  **자기 서브에이전트처럼** 판단·위임해서 쓰고, 무거운 자동판정/자기개선
  엔진 없이 가볍게 도는 루퍼.

## 핵심 가치: 노마드(Nomad) 원칙

이 경량화가 성공하면 프로젝트명을 **`nomad-kant-looper`**로 바꿀 예정이다.
핵심 가치는 "에이전트 AI의 노마드" — 특정 벤더/모델에 정착하지 않고 필요에
따라 자유롭게 옮겨다니는 구조.

- **스위처빌리티(Switchability)**: 새 모델·공급사가 나오면 라우팅 규칙과
  모델 레지스트리만 고치면 전체 시스템이 따라가도록 설계한다. 코드 구조
  자체를 바꾸지 않아도 새 공급사를 추가/교체할 수 있어야 한다.
- **다극화(Multi-polar)**: 미국 빅테크 중심이 아니라 Z.AI, MiniMax, xAI,
  Google, OpenAI를 능력과 상황에 따라 동등하게 평가한다.
- **오픈웨이트 선호(미래 확장용)**: 오픈소스·오픈웨이트 모델이 성능상
  비슷하면 우선 고려한다. 지금은 CLI 중심 구조라 제한적이지만, 나중에
  막히지 않도록 구조적으로 열어둔다.
- 라우팅의 목적은 특정 공급사에 종속되지 않고 필요에 따라 모델·공급사를
  자유롭게 교체할 수 있는 유연한 구조를 유지하는 것이다.
- 효율과 비용을 중요하게 고려하되, **안전·검증·인간 통제라는 상위 원칙은
  절대 침해하지 않는다.**

### AI 위임과 사람의 최종 권한

- 칸트 루퍼는 AI(클로드)의 판단·위임 도움을 받을 수 있다. 하지만 **최종
  승인은 항상 사람(이바)의 몫**이다.
- **모델 레지스트리(어떤 모델을 후보로 둘지)는 이바가 정의·유지**한다.
  클로드는 그 레지스트리 안에서 작업마다 어떤 도구/모델이 적합한지
  판단해서 위임하고, 이바가 특정 도구를 명시하면 그걸 그대로 따른다
  (아래 "판단·위임 원칙" 절 참고).
- 라우팅 규칙 자체의 변경, 새 공급사 도입, merge 등 구조에 영향을 주는
  결정은 사람이 명시적으로 승인한다 — 자동화하지 않는다.

## 걷어낼 것 (스코프 축소)

| 대상 | 이유 |
|---|---|
| `scripts/lib/routing-parser.sh` (834줄) | 자동 판정 로직 — 클로드가 대신 판단 |
| `scripts/lib/ssot-shadow.sh`, `ssot_loader.py`, `routing-ssot/` 전체 | SSOT 라우팅 인프라 자체 |
| `cmd_self_scan`, `cmd_self_dispatch` (kant-loop.sh 내부) | 자기개선 자동 스캔/디스패치 |
| `test-ssot-stress-simulation.sh`, `test-self-improvement.sh` | 위 기능들의 테스트 |
| `ssot-2WEEK-trial.md` | 관찰 시험 자체를 조기 종료 |

## 남길 핵심 (이바가 말한 "가벼운 루퍼")

- `quick` / `full` / `parallel` 실행 모드
- `scripts/lib/safety-check.sh`, `scripts/lib/health-check.sh` — protected paths,
  자동 push 금지, main 직접 커밋 금지 등 5대 안전 원칙
- worktree 격리 (`git worktree` 기반 실행 분리)
- commit 게이트 (`do_commit`, `cmd_promote` — merge는 항상 이바가 명시 실행)
- `scripts/adapters/adapter-*.sh` (codex/opencode/agy/grok/claude) — 다만 아래
  MCP 검증 결과에 따라 일부는 MCP 호출로 교체될 수 있음

## 판단·위임 원칙 (이바 확정)

- **기본**: 클로드가 작업 내용을 보고 어떤 도구/모델을 쓸지 알아서 판단해서
  위임한다. (SSOT처럼 셸이 판정하는 게 아니라 클로드가 그 자리에서 판단)
- **오버라이드**: 이바가 "이건 grok한테 시켜" 같이 명시하면 그걸 그대로 따른다.
  명시가 없을 때만 클로드가 판단.
- 자동판정 코드(routing-parser.sh 류)는 다시 만들지 않는다 — 판단은 코드가
  아니라 대화 시점의 클로드가 한다.
- 단, 클로드가 고르는 후보군(어떤 모델을 쓸 수 있는지) 자체는 이바가
  정의하는 모델 레지스트리 범위 안에서만 판단한다 — "핵심 가치: 노마드
  원칙" 절 참고.

## MCP 전환 원칙 (이바 확정)

- **테스트 순서**: opencode부터. 이바가 실제로 가장 많이 쓰는 도구이고,
  기존 shell adapter(`adapter-opencode.sh`)가 이미 작동 중이므로 여기서부터
  MinMax M3 2.7, GLM 4.7, GLM 5.2 등 여러 모델로 안정성을 실전 테스트하며
  진행한다. grok/agy는 그 다음.
- **판단 기준**: 정해진 반복 횟수가 아니라, 이바의 실제 작업 몇 건을 MCP
  경로로 돌려보고 클로드가 자연스럽게 "안정적이다/아니다"를 판단한다.
- **실패 시 대응**: MCP로 전환한 도구가 런타임에서 실패/불안정하면, 기존
  shell adapter를 당분간 폴백으로 남겨둔다 (완전 삭제하지 않음 — 전환기에는
  두 경로가 공존).
- **전환 확정 조건**: MCP가 (1) 되고, (2) 버그 발생 확률이 낮고, (3) 우리가
  원하는 워크플로가 가능하고, (4) MCP를 필요한 방향으로 고쳐 쓰는 비용이
  효율적이라고 판단될 때만 완전히 갈아탄다. 네 가지 중 하나라도 아니면
  기존 shell adapter를 유지한다.

### 검증 결과: opencode-mcp-tool (2026-07-17)

`gilby125/opencode-mcp-tool`을 실제로 연결 시도 — **탈락**.

- README의 `npx -y @gilby125/opencode-mcp-tool` 설치 명령이 npm 레지스트리
  404로 실패 (`claude mcp add` 후 "Failed to connect" 확인, `npx` 직접 실행해서
  원인 재현).
- `package.json` 확인 결과 `@gilby125/opencode-mcp-tool`은 **npm에 배포된 적
  없음**. 마지막 커밋 2025-12-02, 테스트 코드 없음(`"No tests yet"`), 관리자 1명.
  소스 clone 후 직접 빌드하면 동작은 시키겠지만, 배포·테스트 안 된 1인
  프로젝트를 우리가 직접 빌드·유지하는 부담이 생겨 전환 취지(유지보수 부담
  경감)에 어긋남.
- **결정 (이바 승인)**: opencode는 MCP로 전환하지 않는다. 기존
  `adapter-opencode.sh`(shell)를 그대로 유지한다. MCP는 codex처럼 실제로
  정식 배포·연결이 검증되는 후보에 한해서만 채택한다.

### 검증 결과: agy-mcp (Boulea7/agy-mcp) (2026-07-17)

설치·연결은 성공(PyPI v0.1.8, `agy-doctor` healthy, `claude mcp list`에서
Connected). 도구 스키마도 README와 대체로 일치(`agy`, `agy_start/status/
read/result/cancel`, `agy_continue`, `agy_doctor`, `agy_install_skill`,
`agy_purge`, `agy_sessions`). 하지만 실사용 검증에서 **치명적 결함 발견**
— **탈락**.

- `agy` / `agy_start` 도구의 `cd` 파라미터가 실제로 적용되지 않음.
  `cd: /Users/drumqube/AGENTS/kant-looper-dev`를 넘겨도 응답 메타데이터의
  `cwd` 필드에는 그대로 echo되지만, agy 바이너리는 실제로
  `~/.gemini/antigravity-cli/scratch`(빈 스크래치 디렉토리)에서 실행됨.
  `pwd`를 직접 실행시켜 재현 확인(동기 호출 1회, 백그라운드 job 1회 모두
  동일 증상).
- 칸트 루퍼 어댑터는 항상 지정된 worktree 안에서 읽기/쓰기를 해야 하는데,
  agy-mcp는 엉뚱한 고정 디렉토리에서 동작하므로 `allow_write=true`
  테스트는 무의미하다고 판단해 진행하지 않음(잘못된 폴더에 쓰기만 하게 됨).
- **결정**: agy도 opencode와 같은 이유로 MCP 전환하지 않는다. 기존
  `adapter-agy.sh`(shell, `--add-dir <worktree>` 방식)를 그대로 유지한다.
  agy-mcp가 `cd`/워킹 디렉토리 버그를 고치고 재배포하면 그때 재검증한다.

### 검증 결과: grok-mcp (maikunari/grok-mcp) (2026-07-17)

npm 미배포(`package.json` `"private": true`)라 git clone 후 직접 빌드해서
검증. **기술적으로는 opencode/agy와 달리 통과** — 하지만 이바 판단으로
채택하지 않고 shell adapter 유지 결정.

- 빌드: `git clone` → `npm install` → `npm run build` (tsc) 정상 완료.
  소스(`src/index.ts`, 1118줄) 검토 결과 `spawn(grok 바이너리)` 외 외부
  네트워크 호출·`eval` 없음 — 깨끗함. 마지막 커밋 2026-07-09(검증 시점
  기준 8일 전), 관리자 1명(maikunari)이지만 짧은 기간에 버전을 여러 번
  올릴 만큼 활발.
- MCP stdio 프로토콜을 직접 스크립트로 구사(JSON-RPC `initialize` →
  `tools/list` → `tools/call`)해서 실제 동작 확인 — 세션 도중 등록이라
  `ToolSearch`에 도구가 안 잡혀서(agy와 동일한 제약) 새 서버 프로세스를
  수동으로 띄워 검증:
  - **read-only 호출**: `pwd`/`ls`를 지정한 `cwd`(kant-looper-dev)에서
    정확히 실행 — agy-mcp와 달리 `cwd` 파라미터가 실제로 적용됨.
  - **쓰기 호출**: 스크래치 디렉토리에 `hello.txt`를 정확한 내용으로 생성,
    `cat`으로 직접 재검증 완료.
  - **백그라운드 job**: `background: true`로 `job_id` 발급 → 완전히 새로운
    서버 프로세스에서 `grok_task_result`로 폴링해도 결과 조회됨
    (`~/.grok-mcp/jobs/` 영속화 — README 주장 실증).
  - **구조화 응답**: `files_changed`(git 저장소는 git-verified, 비git
    디렉토리는 transcript 폴백으로 정확히 라벨링), `session_id`,
    `stop_reason` 등 README 명세와 일치.
- **트레이드오프 지적**: 기존 `adapter-grok.sh`는 role별로 `plan/review/
  verify`에서 `--deny 'Bash(*)' --deny 'Edit(*)'`를 **셸이 명시적으로
  강제**하는데, grok-mcp는 `permission_mode`(예: `auto`) 하나로 승인
  범위가 결정되어 이 세밀한 강제가 없음 — MCP로 전환하면 read-only role의
  쓰기 차단을 셸이 아니라 **호출 시점의 클로드 판단**에 맡기게 됨.
- **결정 (이바 확정, 2026-07-17)**: grok도 MCP로 전환하지 않는다. 기존
  `adapter-grok.sh`(shell)를 유지한다. opencode/agy/grok 세 도구 모두
  이번 라운드에서는 shell adapter 유지로 귀결.

## 진행 방식 (이바 확정)

- **도그푸딩 중심**: 새 기능을 먼저 만들고 나중에 테스트하는 게 아니라,
  이바가 실제로 kant-looper를 opencode 위주로 계속 쓰면서(주력 사용) 그
  과정에서 모델 전환 안정성과 새로 붙인 연결 도구들이 실제로 작동하는지
  자연스럽게 검증한다.
- **단계별 승인**: 큰 변화를 한 번에 밀어붙이지 않고, 각 단계가 끝날 때마다
  이바에게 확인받은 뒤 다음 단계로 간다.

## omo(oh-my-openagent) 조사 (병행 트랙)

- omo 저장소를 직접 열어 실제 도구 호출/훅 메커니즘을 확인한다 (README만
  보고 판단하지 않는다 — 지난번 니체의 실수를 반복하지 않음).
- 참고할 만한 패턴이 있으면 칸트 루퍼의 경량 구조에 반영한다. 통째로
  가져오거나 갈아타는 게 목적이 아니라, "도구 호출을 더 단순하게 만드는
  아이디어"를 얻는 것이 목적.

### 조사 결과 (2026-07-17)

로컬에 이미 설치된 opencode 플러그인 `oh-my-openagent`(v4.17.0,
`code-yeongyu/oh-my-openagent`, npm 정식 배포)의 실제 소스(번들이지만
원본 경로 주석이 남아있어 추적 가능)를 열어서 확인.

- **훅 등록**: opencode 훅 객체(`tool.execute.before/after`,
  `chat.message`, `experimental.chat.messages.transform` 등)를 export.
  `createHooks()`가 `createCoreHooks + createContinuationHooks +
  createSkillHooks`를 스프레드로 합치는 단순 조합 패턴.
- **`.omo/run-continuation/*.json`의 정체**: job 상태 저장이 아니라, 세션이
  죽었다가 재개될 때 "이 세션이 continuation 대상인지"만 표시하는 얇은
  마커 파일(`features/run-continuation-state/storage.ts`). 진짜 job
  추적은 인메모리 Map + opencode 세션 자체를 폴링해서 얻음 — **세션 자체가
  진실의 소스, 파일은 캐시일 뿐**.
- **모델 라우팅**: 자동판정 스크립트 없음. 카테고리별 정적 테이블
  (`{name, model, variant, promptAppend}`)만 있고, **어떤 카테고리를 쓸지는
  호출하는 LLM 자신이 tool 인자로 고름** — routing-parser.sh를 걷어내고
  "클로드가 판단"하는 이번 방향과 정확히 일치하는 선례.
- **백그라운드 job**: 파일 기반 job store가 아니라 세션ID를 job_id로 재사용,
  인메모리 + 세션조회 방식(grok-mcp의 job_id/status/result와는 다른 접근).

**참고할 아이디어**: (1) 훅을 관심사별 함수로 쪼개 스프레드 머지하는 구조는
나중에 kant-loop.sh 정리 시 참고 가능. (2) "카테고리는 LLM이 고르고 정적
테이블에서 조회"는 우리가 이미 확정한 판단·위임 원칙과 같은 선례라 방향에
확신을 더함. (3) 파일 상태를 최소화하고 프로세스/세션 자체를 진실 소스로
삼는 편이 견고함 면에서 유리.

**정리**: 칸트 루퍼 저장소에 남아있던 `.omo/run-continuation/*.json` 9개
파일은 omo 플러그인이 만든 부산물(세션 재개 마커)로, 칸트 루퍼 자체 기능이
아니며 `.gitignore`로 이미 추적 제외돼 있었음. 삭제 완료(2026-07-17,
이바 승인).

## SSOT 2주 관찰 시험 처리

- `ssot-2WEEK-trial.md`에 조기 종료 사유(스코프 축소 결정, 2026-07-17)를
  기록한 뒤 문서 자체를 정리한다. 왜 SSOT를 버렸는지 근거를 남겨서 나중에
  "왜 SSOT를 버렸지?"라고 헷갈리지 않게 한다.

## 순서 요약

1. ✅ `ssot-2WEEK-trial.md` 조기 종료 기록 정리 (완료, `d9cdb33`)
2. ✅ opencode MCP 검증 → `opencode-mcp-tool` 탈락(미배포 패키지), 기존
   shell adapter 유지로 결론 (완료, 2026-07-17). MinMax M3 2.7 / GLM 4.7 /
   GLM 5.2 모델 안정성 테스트는 기존 `adapter-opencode.sh` 경로로 계속 진행.
3. grok, agy MCP 연결·검증 — 실패하면 기존 shell adapter 유지
   - ✅ agy MCP 검증 완료 → **탈락**(`cd` 파라미터 미적용, 고정 스크래치
     디렉토리에서 실행됨). `adapter-agy.sh` 유지 (완료, 2026-07-17).
   - ✅ grok-mcp 검증 완료 → 기술적으로는 통과(cwd/쓰기/백그라운드 job 모두
     실측 확인)했으나, role별 read-only 강제(Bash/Edit deny)를 셸이 아닌
     클로드 판단에 맡기게 되는 트레이드오프 때문에 이바가 **비채택** 결정.
     `adapter-grok.sh` 유지 (완료, 2026-07-17).
   - **3단계 최종 결론**: opencode/agy/grok 세 도구 모두 shell adapter
     유지. MCP 전환은 이번 라운드에서 0건.
4. ✅ omo 도구 호출 방식 조사 → 참고할 패턴 3가지 확인, `.omo/run-continuation`
   잔재 삭제 (완료, 2026-07-17)
5. ✅ SSOT/자기개선 코드 제거 (`routing-parser.sh`, `ssot-shadow.sh`,
   `routing-ssot/`, self-scan/self-dispatch, 관련 테스트) — 완료
   (2026-07-17, `bd3f9da`). kant-loop.sh 30개 파일 변경, 순증감
   +99/-5937줄. `--parallel`은 `--chain` 명시 필수로 변경(에러 처리).
   `test-all.sh`(14개) + `run-scenarios.sh`(A/B/C dry-run) 전부 재통과
   확인.
6. 남은 코드(quick/full/parallel + safety-check + worktree + commit 게이트)로
   전체 회귀 테스트 재구성, 문서(SKILL.md, CHANGELOG.md) 갱신

각 단계는 끝날 때마다 이바에게 결과를 보고하고 다음 단계 진행 여부를 확인한다.

## HPRAR(`--full` 자동 라운드 오케스트레이션) 포기 (2026-07-17, 이바 확정)

- **결정**: `--full`의 HPRAR(plan→implement→review→repair 자동 라운드 체이닝)
  방식을 포기한다. 복잡한 작업은 클로드가 `--quick` 호출을 여러 번(병렬 또는
  순차)으로 직접 조합해서 대화 중에 운영하는 방식으로 대체한다.
- **경위**: 2026-07-17 세션 중 실제 라이브 테스트에서 `--parallel`/`--full`이
  실패(원인은 omo가 진단·수정, 커밋 `59b187a`로 해결). 이 과정에서 "HPRAR
  자체가 구조적으로 반복 실패하는 패턴"이라는 근거로 별도 프로젝트
  `/Users/drumqube/AGENTS/Kanban Agentic Loop/hermes-kanban-opencode-claude-codex-loop.sh`
  (다른 에이전트가 만든 유사 HPRAR 구현)가 언급됐으나, 클로드가 그 프로젝트의
  실제 문서(`pilot-notes.md`, `HANDOFF.md`)를 직접 읽어본 결과 근거가
  충분히 뒷받침되지 않음을 확인했다(유일한 기록된 실패는 autonomous verifier
  delegate 1건의 인프라 설정 오류였고, 나머지 단계는 PASS로 기록돼 있었음).
  이 불일치를 이바에게 보고했고, 별도로 Hermes 에이전트에게 라이브 재검증
  작업지시(스크래치 파일로 전달)를 준비해뒀으나, **이바가 그 결과를 기다리지
  않고 이 시점에 HPRAR 포기를 최종 확정**했다. 즉 이 결정의 근거는
  hermes-kanban 프로젝트의 실증 데이터가 아니라, 이바의 독립적 판단이다.
- **대안**: `--quick` 모드를 강화하는 방향으로 간다. 라이브 테스트 3회 연속
  성공을 검증 기준으로 삼는다(진행 중).
- **남은 작업** (아직 코드 미반영): `run_full_mode` 함수, 관련 테스트,
  `SKILL.md`의 `--full` 절 제거. `--quick`/`--parallel`은 그대로 유지.
