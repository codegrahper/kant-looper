# Nomad Kant Looper란 무엇인가

![version](https://img.shields.io/badge/version-v0.6.0-blue)

**Nomad Kant Looper는 여러 AI 코딩 에이전트를 지휘해, 계획·구현·검증·수정을 반복 수행하는 Bash 기반 자동화 코딩 오케스트레이터입니다.**

Codex, Claude, Grok, OpenCode, Antigravity 같은 도구를 직접 대체하는 AI 모델이 아니라, 각 도구에 역할과 권한을 나누어 주고 작업 결과를 검사하는 **상위 제어 스크립트**입니다.

쉽게 표현하면 다음과 같습니다.

> AI에게 코드를 맡기되, AI의 판단을 그대로 믿지는 않고 규칙과 검증 절차를 통과한 변경만 받아들이는 자동화 시스템.

Nomad Kant Looper의 메인 백엔드는 `kant-loop.sh`이며, 작업 실행뿐 아니라 사전 검사, 상태 확인, 결과 보고, 작업 브랜치 승격, 정리 등의 명령을 제공합니다. 자동 push, main 브랜치 직접 커밋, 강제 reset이나 rebase 같은 위험 작업은 금지하도록 설계되어 있습니다.

## 요구사항

- macOS (bash 3.2 호환, `git worktree` 사용)
- `git`
- 최소 1개 이상의 외부 코딩 에이전트 CLI: `codex`(OpenAI), `claude`(Anthropic), `grok`(xAI), `opencode`(GLM 등), `agy`(Antigravity/Gemini)
  설치되지 않은 도구는 health-check가 자동으로 우회하고, 전부 실패하면 `claude`가 최종 폴백으로 동작합니다.

## 빠른 시작

```bash
# 환경 검사만 (side-effect 없음)
scripts/kant-loop.sh preflight TASK.md

# 드라이런 — 라우팅/브랜치명만 확인, 실제 실행 X
scripts/kant-loop.sh run TASK.md --dry-run

# 가벼운 작업: 단일 도구 한 번 호출
scripts/kant-loop.sh run TASK.md --quick --agent codex --model gpt-5.6-terra

# 기본값: 단일 quick 호출
scripts/kant-loop.sh run TASK.md

# 복잡한 변경: 구현 → 검토 → 수정 순차 체인
scripts/kant-loop.sh run TASK.md --quick --chain opencode:glm-5.2,codex:gpt-5.6-sol,codex:gpt-5.6-terra

# 실행 상태 확인
scripts/kant-loop.sh status --latest

# main 병합은 사용자가 직접 실행 (자동으로 일어나지 않음)
scripts/kant-loop.sh promote agent/kant/<run-id> --target main
```

`TASK.md`에는 `## 목표` 또는 `## Goal` 섹션이 반드시 있어야 합니다. `--quick`/`--parallel` 모드와 전체 옵션은 [SKILL.md](SKILL.md)를 참고하세요.

## 어떤 일을 하는 스크립트인가

사용자가 `TASK.md`에 목표와 작업 범위를 작성하면 Nomad Kant Looper는 대체로 다음 과정을 진행합니다.

```text
작업 이해
→ 적합한 AI 도구와 모델 선택
→ 구현 계획 수립
→ 격리된 작업 공간에서 코드 수정
→ 테스트와 안전 검사
→ 독립적인 코드 리뷰
→ 문제가 있으면 repair
→ 다시 검증
→ 검토된 변경만 작업 브랜치에 커밋
→ 사용자에게 결과 보고
```

핵심은 단순히 AI를 반복 호출하는 것이 아니라, 각 호출을 **역할이 있는 단계**로 구분한다는 점입니다.

### Plan

무엇을 바꿀지, 어떤 파일이 작업 범위인지, 무엇을 통과해야 완료인지 결정합니다.

이 단계는 원칙적으로 읽기 전용입니다. 계획을 세우는 에이전트가 계획과 동시에 코드를 몰래 수정하지 못하도록 분리합니다.

### Implement

계획에 따라 실제 코드를 작성합니다.

이 단계에서만 작업 디렉터리 쓰기 권한과 필요한 편집·터미널 권한이 주어집니다.

### Gate

에이전트가 “완료했습니다”라고 말했는지보다 실제 테스트와 검사 결과를 확인합니다.

```text
문법 검사
테스트
정적 검사
변경 범위 검사
비밀정보 검사
보호 경로 검사
```

Gate를 통과하지 못하면 완료로 인정하지 않습니다.

### Review

구현을 담당한 에이전트와 별개의 리뷰어가 변경 내용을 검토합니다.

리뷰 결과는 자유로운 감상문이 아니라 다음처럼 제한된 판정으로 처리됩니다.

```text
PASS
CHANGES_REQUESTED
BLOCKED
INVALID_OUTPUT
```

### Repair와 Verify

문제가 발견되면 수정 계획을 다시 만들고 필요한 부분만 고칩니다. 이후 테스트와 검토를 다시 수행하여 실제로 문제가 해결됐는지 확인합니다.

기본 quick 모드는 한 에이전트로 작업합니다. 복잡한 변경은 `--quick --chain`으로 구현 → 검토 → 수정을 한 격리 worktree에서 순차 실행합니다. `--parallel`은 파일을 바꾸지 않는 다중 검토 전용이며, 실제 수정은 quick 체인을 사용합니다.

## 철학

Nomad Kant Looper가 어떤 원칙 위에서 설계됐는지 — 왜 특정 모델에 정착하지
않는지("Nomad"), 왜 자율성에 항상 규칙과 검증을 함께 두는지("Kant"), 왜
한 번에 끝내지 않고 반복·검증하는지("Looper") — 는 [MANIFESTO.md](MANIFESTO.md)에
정리돼 있습니다.

> **모델은 이동하고, 원칙은 남는다.**
> **사람은 선택하고, AI는 돕는다.**
> **그리고 반복은 완성을 만든다.**
