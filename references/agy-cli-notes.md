# agy (Antigravity CLI) 실전 노트

> 오늘 실제로 겪은 시행착오를 기록. 공식 문서(https://antigravity.google/docs/cli/using ,
> https://antigravity.google/docs/cli/reference)로 교차 확인된 내용만 "확인됨"으로 표시.
> agy를 라우팅하거나 adapter-agy.sh를 다시 건드리기 전에 먼저 이 문서를 읽을 것.

## 1. `--sandbox`는 터미널만 막는다 (파일 쓰기는 안 막힘)

**확인됨** — 공식 reference의 `settings.json` 표에 정확히 이렇게 나와 있다:

```
enableTerminalSandbox (boolean, default false)
  "Restricts all local execution commands launched by agents to OS containment rings."
```

`--sandbox`는 이 `enableTerminalSandbox`의 launch-time override다. **파일 읽기/쓰기와는 무관.**
read-only 롤(plan/review/verify)에서 `--sandbox read-only`만 주고 안심하면 안 된다 —
실제로 이 조합 + `--dangerously-skip-permissions`로 hello-world 테스트 중 agy가
스킬 스크립트 5개를 실제로 수정하는 사고가 있었다 (`fix/agy-read-only-sandbox-bypass` 커밋 참고).

파일 쓰기를 막는 실제 옵션은 `--mode plan`이다 (아래 3번 참고).

## 2. `--add-dir`은 cwd를 바꾸지 않는다 — 그냥 "추가 접근 허용"

**확인됨** — reference 문서의 슬래시 커맨드 표: `/add-dir <path>` = "Add a directory path
to the active workspace." (추가일 뿐, 전환이 아님)

실측으로도 확인: `--add-dir /some/other/dir`을 줘도 agy의 실제 `workspaceDirs`는
프로세스가 실행된 cwd를 그대로 가리켰다 (`cli.log`에서 직접 확인). 그래서 kant-looper는
agy를 포함한 5개 어댑터 전부, **프로세스 자체의 cwd를 격리된 worktree로 강제**하는 방식으로
고쳤다 (`scripts/lib/timeout-runner.sh`의 fail-closed cwd 인자, `fix/adapter-worktree-cwd-isolation` 커밋).
`--add-dir`에만 의존해서 worktree를 격리했다고 믿으면 안 된다.

## 3. `--mode plan` vs `--mode accept-edits`

**확인됨** (agy --help): `--mode` = "Set the agent execution mode for this session
(accept-edits, plan)".

- `plan`: 읽기 전용. 실제로 파일 수정 지시를 줘도 무시하고 분석/보고만 한다 (실측 확인 —
  `--mode plan`에서 "이 파일 한 줄 고쳐봐"라고 시켜도 파일이 전혀 안 바뀜).
- `accept-edits`: 편집 허용. 이 모드에서만 `--dangerously-skip-permissions`(아래 4번)와
  같이 써야 한다.

adapter-agy.sh는 role에 따라 이 둘을 나눠 쓰도록 고쳐져 있다 (plan/review/verify → plan,
implement/repair → accept-edits).

## 4. `--dangerously-skip-permissions`가 정확히 우회하는 것

**확인됨** — settings.json 표의 `toolPermission` 옵션:

```
toolPermission (string, default "request-review")
  "request-review"      : write/bash/web 도구 승인 요청
  "proceed-in-sandbox"  : 샌드박스 안에서는 자동 진행
  "always-proceed"      : 절대 승인 요청 안 함  ← --dangerously-skip-permissions가 이걸로 강제
  "strict"              : read 아닌 모든 도구에 승인 요청
```

즉 이 플래그는 **모든 도구 권한 요청(파일 편집 포함)을 자동 승인**한다. read-only 롤에서
이 플래그를 쓰면 `--mode plan`이 있어도 위험하니 절대 같이 쓰지 않는다 (adapter-agy.sh가
이미 이렇게 분기돼 있음 — `skip_permissions=0`은 plan/review/verify, `=1`은 implement/repair만).

별도로 `artifactReviewPolicy`(코드 작성 전 리뷰 여부)도 있는데 이건 아직 CLI 플래그로
직접 건드리지 않고 있음 — 필요해지면 추가 조사.

또한 GEMINI.md(`~/.gemini/GEMINI.md`)에는 agy가 `ask_permission` 도구로 이바에게 직접
권한을 요청하도록 지시돼 있다. kant-looper처럼 `--print`(비대화형) 모드로 부르면 물어볼
상대가 없어서, `--dangerously-skip-permissions`와 이 기대 동작이 충돌해 agy가 프롬프트를
무시하고 엉뚱한 응답(예: 자기소개, 무관한 상태 보고)을 내는 현상을 여러 번 관찰했다.
read-only 롤에서 스킵 플래그 자체를 없앤 이후로는 재현되지 않았다.

## 5. 모델 ID — agy 1.1.x부터 `--model` 플래그는 표시 이름만 받는다

agy 1.1.x(2026-07 확인, `agy --version` = 1.1.3)에서 `--model` 플래그에 raw ID를
주면 즉시 거부된다:

```
Error: invalid --model "gemini-3.5-flash": model gemini-3.5-flash is not
recognized as a known model or custom model in settings

Available models:
  Gemini 3.5 Flash (Medium)
  Gemini 3.5 Flash (High)
  Gemini 3.5 Flash (Low)
  Gemini 3.1 Pro (Low)
  Gemini 3.1 Pro (High)
  Claude Sonnet 4.6 (Thinking)
  Claude Opus 4.6 (Thinking)
  GPT-OSS 120B (Medium)
```

`agy models`가 보여주는 표시 이름(공백 포함)을 그대로 `--model`에 넘겨야 동작한다.
`gemini-3.1-flash-lite`는 목록에서 사라졌다 — 대체품이 필요하면
`Gemini 3.5 Flash (Low)`가 가장 가깝다. "Gemini 3.5 Pro"는 존재하지 않는다
(3.5는 Flash만, Pro는 3.1 계열).

kant-looper 내부 식별자(`model-selector.sh`, `fallback-dispatcher.sh`,
`kant-loop.sh`에 하드코딩된 `gemini-3.5-flash`, `gemini-3.1-pro-preview` 등)는
짧고 안정적인 형태 그대로 유지하고, 표시 이름 변환은
`scripts/adapters/adapter-agy.sh`의 normalization case가 책임진다
(opencode 어댑터의 provider 정규화 패턴과 동일). 매핑 테이블에 없는
이름은 WARN 로그 후 raw 값 그대로 시도(어댑터 방어적 폴백).

## 6. Stitch MCP는 시켜야 쓴다 — 알아서 안 씀

agy는 GEMINI.md 설정으로 Stitch MCP(Google의 UI 디자인 생성 도구, GCP 프로젝트 "Stitch")에
이미 연결돼 있지만, **TASK.md/프롬프트에 "Stitch를 먼저 호출해서 시안을 만들어라"라고
명시하지 않으면 그냥 코드를 직접 짜고 끝낸다.** "UI 만들어줘" 정도로는 Stitch를 안 쓴다.
필요하면 "필수 절차"로 명시하고, `notes_for_reviewer`에 실제 호출 여부를 남기라고 요구할 것
(이번에 이렇게 명시하니 실제로 호출하고 프로젝트 ID까지 verdict JSON에 남겼다).

같은 이유로, "사람 이미지 쓰지 마"처럼 지켜야 할 제약도 애매하게 말하면 (예: "저작권
문제 없게") 모델이 스스로 "AI로 새로 생성한 인물 사진이면 괜찮다"고 자체 해석해서 위반할
수 있다. 금지 항목은 실사/AI생성/일러스트/실루엣 등 구체적 형태까지 나열해야 한다.

## 7. IDE 쪽엔 네이티브 worktree 모드가 있다 (CLI --print엔 해당 없음)

공식 문서(Getting Started)에 Antigravity **IDE**의 에이전트 시작 모드로 "New Worktree Mode:
The agent operates in an isolated Git worktree"가 있다. 이건 IDE의 대화형 세션 개념이고,
kant-looper가 쓰는 `agy --print`(비대화형 단발 호출) 경로에는 노출되지 않는 것으로 보임 —
CLI reference에서 이에 대응하는 `--worktree` 류 플래그를 찾지 못했다. 그래서 kant-looper는
worktree 격리를 agy에 맡기지 않고 `timeout-runner.sh`의 cwd 강제로 직접 보장한다
(위 2번). 나중에 CLI에도 동등한 옵션이 생기면 이중 방어로 추가 검토.

## 참고 링크

- https://antigravity.google/docs/cli/using (Settings, quick tips, keybindings)
- https://antigravity.google/docs/cli/reference (슬래시 커맨드, 기본 키바인딩, settings.json 전체 표)
