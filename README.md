# Kant Looper

**여러 AI 코딩 에이전트를 지휘해, 계획·구현·검증·수정을 반복 수행하는 Bash 기반 멀티모델 코딩 오케스트레이터.**

Codex, Claude, Grok, OpenCode, Antigravity 같은 도구를 직접 대체하는 AI 모델이 아니라, **메타 에이전트(Claude)가 사용자 작업을 분석하고 적합한 모델을 추천**하며, 추천된 도구가 작업한 결과를 검증해 작업 브랜치에 커밋하는 상위 제어 스크립트입니다.

> AI에게 코드를 맡기되, AI의 판단을 그대로 믿지는 않고 규칙과 검증 절차를 통과한 변경만 받아들이는 자동화 시스템.

메인 백엔드는 `kant-loop.sh`이며, 작업 실행뿐 아니라 사전 검사, 상태 확인, 결과 보고, 작업 브랜치 승격, 정리 명령을 제공합니다. 자동 push, main 직접 커밋, 강제 reset/rebase, 위험 명령은 금지되어 있습니다.

---

## 요구사항

- macOS (bash 3.2 호환, `git worktree` 사용)
- `git`
- 최소 1개 이상의 외부 코딩 에이전트 CLI: `codex`(OpenAI), `claude`(Anthropic), `grok`(xAI), `opencode`(GLM 등), `agy`(Antigravity/Gemini)
  - 설치되지 않은 도구는 health-check가 자동으로 우회하고, 전부 실패하면 `claude`가 최종 폴백입니다.

## 빠른 시작

```bash
# 환경 검사만 (side-effect 없음)
scripts/kant-loop.sh preflight TASK.md

# 드라이런 — 라우팅/브랜치명만 확인, 실제 실행 X
scripts/kant-loop.sh run TASK.md --dry-run

# 메타 에이전트(Claude)가 작업 분석 → 모델 후보 제안 → 사용자 승인 → 실행
scripts/kant-loop.sh run TASK.md
# (Claude 세션에서 작업 요청 → §16 워크플로우에 따라 모델 추천 → 승인 후 호출)

# 명시적 도구/모델 직접 지정 (메타 에이전트 우회)
scripts/kant-loop.sh run TASK.md --quick --agent codex --model gpt-5.6-terra

# 실행 상태 확인
scripts/kant-loop.sh status --latest

# main 병합은 사용자가 직접 실행
scripts/kant-loop.sh promote agent/kant/<run-id> --target main
```

TASK.md는 `## 목표` 또는 `## Goal` 섹션이 있으면 그대로, 없으면 메타 에이전트가 자동 보정합니다. 모드와 전체 옵션은 [SKILL.md](SKILL.md)를 참고하세요.

---

## 메타 에이전트 워크플로우 (핵심)

**Kant Looper는 자동 라우팅 엔진이 아닙니다.** 메타 에이전트(Claude)가 사용자 작업을 분석하고 적합한 모델을 추천하는 구조입니다.

```
[1] 사용자가 작업을 자연어로 제시
       ↓
[2] 메타 에이전트가 가이드 md + SKILL.md 빠르게 흡수
       ↓
[3] 작업 분석 (본질·난이도·도메인·제약)
       ↓
[4] 모델 후보 2~3개 제안 (A안 균형 / B안 빠름 / C안 고품질)
       ↓
[5] 사용자 승인
       ↓
[6] TASK 메타 프롬프트 작성 + 외부 도구 호출
       ↓
[7] 보고 회수 → 검증 → 작업 브랜치 커밋
       ↓
[8] main 병합은 사용자가 promote로 명시 실행
```

가이드: [references/multimodel-coding-agent-routing-guide.md](references/multimodel-coding-agent-routing-guide.md) §16/§17.

---

## 어떤 일을 하는 스크립트인가

사용자가 TASK.md에 목표를 작성하면 Kant Looper는 대체로 다음 과정을 거칩니다.

```text
작업 이해 (메타 에이전트가 분석)
→ 모델 후보 제시 + 사용자 승인
→ 격리된 작업 공간(worktree) 생성
→ 선택된 도구/모델 호출 (plan → implement → gate → review)
→ 테스트와 안전 검사
→ 문제가 있으면 repair → verify
→ 검토된 변경만 작업 브랜치에 커밋
→ 사용자에게 결과 보고
```

핵심은 단순히 AI를 반복 호출하는 것이 아니라, 각 호출을 **역할이 있는 단계**로 분리하고, **메타 에이전트가 그 단계를 결정**한다는 점입니다.

### Plan
무엇을 바꿀지, 어떤 파일이 작업 범위인지, 무엇을 통과해야 완료인지 결정. 읽기 전용.

### Implement
계획에 따라 실제 코드 작성. 작업 디렉터리 쓰기 권한과 편집·터미널 권한 부여.

### Gate
"완료했습니다"라는 자기평가보다 실제 테스트와 검사 결과를 확인합니다.

```text
문법 검사 · 테스트 · 정적 검사 · 변경 범위 검사 · 비밀정보 검사 · 보호 경로 검사
```

### Review
구현을 담당한 에이전트와 별개의 리뷰어가 변경 내용을 검토. 판정은 다음 중 하나:

```text
PASS · CHANGES_REQUESTED · BLOCKED · INVALID_OUTPUT
```

### Repair와 Verify
문제 발견 시 수정 계획 + 필요한 부분만 수정. 테스트와 검토 재수행. 무한 재시도는 무진전 감지로 차단됩니다.

---

## 라우팅 가이드

`references/multimodel-coding-agent-routing-guide.md`는 메타 에이전트의 SSOT입니다. 다음을 포함합니다:

- **§3 GLM 계열** (glm-5.2/5.1/5/5-turbo/4.7/4.7-flashx 등)
- **§4 GPT-5.6 계열** (sol/terra/luna)
- **§5 Grok 계열** (grok-4.5, grok-build-0.1)
- **§6 Gemini/Antigravity** (3.5-flash, 3.1-pro-preview, 3.1-flash-lite)
- **§7 MiniMax M 계열** (M3, M2.7, M2.7-highspeed)
- **§8 난이도 매트릭스** (T0~T4 × 모델)
- **§13 실무 서브에이전트 프롬프트**
- **§16 메타 에이전트 워크플로우** (이 문서와 짝)
- **§17 모델 추론 능력 요약** (추론 깊이·속도·한국어·1M·멀티모달·가격대 한눈에)

`scripts/lib/routing-parser.sh`가 이 가이드를 파싱해 다음 변수를 캐시로 노출합니다:

```bash
# 16개 모델 + 5개 태그
KANT_PRIMARY_LUNA, TERRA, SOL           # GPT-5.6
KANT_PRIMARY_GLM52, GLM47, GLM5TURBO,
  GLM47FLASHX, GLM5VTURBO               # GLM
KANT_PRIMARY_GROK45, GROKBUILD           # Grok
KANT_PRIMARY_GEMINI35FLASH, GEMINI31PRO,
  GEMINI31LITE                          # Gemini
KANT_PRIMARY_CLAUDE_M3, CLAUDE_M27,
  CLAUDE_M27HS                          # MiniMax M

KANT_TAG_CODING_MODELS                 # 코딩 특화
KANT_TAG_FRONTEND_MODELS               # 프론트/디자인
KANT_TAG_KOREAN_MODELS                 # 한국어 강함
KANT_TAG_FAST_MODELS                   # 속도 우선
KANT_TAG_HUGE_CONTEXT_MODELS           # 1M 컨텍스트
```

---

## 안전 약속 (절대 위반 안 됨)

1. **자동 push 금지** — 어떤 원격에도 push 안 함 (사용자 명시 요청 시에만)
2. **merge commit 금지** — ff-only만, `promote` 명령으로만
3. **rebase / reset --hard / branch -D 금지**
4. **main 직접 커밋 금지** — 작업 브랜치(`agent/kant/<run-id>`)에만
5. **protected paths 변경 차단** — `.env`, `*.pem`, `*.key`, `*credential*`, `*secret*`, `node_modules`, `dist`, `build`, `__pycache__`

상세: [references/safety-promises.md](references/safety-promises.md)

---

## 왜 이름이 ‘Kant’인가

칸트는 단순히 "이성이 무엇을 할 수 있는가"만 묻지 않았습니다. 동시에 다음을 물었습니다.

> 이성은 어디까지 정당하게 판단할 수 있으며, 어떤 한계를 넘어서는 안 되는가?

Kant Looper도 AI가 무엇을 할 수 있는지만 보지 않습니다.

```text
이 변경은 허용된 범위 안에 있는가?
검증할 수 있는 근거가 있는가?
다른 리뷰어도 받아들일 수 있는가?
안전 규칙을 위반하지 않았는가?
실제로 커밋해도 되는가?
```

AI의 능력을 확대하는 시스템이면서, 동시에 AI 능력의 **사용 조건과 한계를 정하는 시스템**입니다.

### 1. 자율성과 법칙
코딩 에이전트에게 자율성을 주되, 항상 다음 법칙 안에서만:

```text
지정된 worktree 안에서만 수정
계획·검토 단계에서는 읽기 전용
보호된 파일 변경 금지
위험 명령 금지
검증되지 않은 변경 커밋 금지
```

### 2. 정언명령과 보편적 규칙
Codex가 구현하든, Grok이 구현하든, Claude가 수정하든 동일한 안전 규칙 적용. 모델의 명성이나 능력이 아니라 **행위 자체**에 규칙 적용.

### 3. 순수이성비판과 검증
에이전트의 자기평가("완료했습니다")가 아니라 **검증 가능한 증거**(diff, 테스트 종료 코드, 변경 파일 범위, 리뷰 결과, 커밋 tree)를 요구합니다.

### 4. 현상과 물자체의 비유
모델 내부의 추론은 모르지만 밖으로 나타난 결과로 판단. "AI가 충분히 고민했을 것"이라고 추측하지 않습니다.

### 5. 인간을 최종 목적으로 남겨두기
자동화를 추구하지만 인간의 최종 통제권은 유지. 자동 push 금지, main 병합은 사용자가 명시적으로 실행.

---

## 왜 ‘Looper’인가

```text
실행 → 비판 → 수정 → 재검증
```

같은 diff나 같은 테스트 실패가 반복되면 무진전 감지로 중단. 'Looper'는 무한 반복이 아니라 교정의 반복입니다.

> 판단하고, 행동하고, 결과를 비판하고, 필요한 경우 더 나은 행동으로 교정한다.

---

## 한 문장으로 정의하면

> **Kant Looper는 메타 에이전트(Claude)가 사용자 작업을 분석해 적합한 모델을 추천하고, 추천된 도구가 작업한 결과를 안전 약속과 검증 절차로 걸러 작업 브랜치에 받아들이는 멀티모델 코딩 오케스트레이터입니다.**

## 핵심 문구

> **능력에는 권한을 주고, 권한에는 한계를 두며, 결과에는 검증을 요구한다.**