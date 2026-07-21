# `platform/opencode.md` — OpenCode (Meta Agent Host)

이 파일은 **OpenCode 런타임에서 Meta Agent를 구동**할 때의 정보를 담는다.

## 설치 — 별도 설치 불필요

OpenCode는 `.claude/skills/`(및 `.agents/skills/`) 경로를 자체적으로 직접
읽도록 공식 지원한다. 따라서 nomad-kant-looper를 OpenCode에서 쓰기 위해
**별도로 복사하거나 clone하거나 심링크를 만들 필요가 없다.**

Claude Code 설치 경로(`$HOME/.claude/skills/nomad-kant-looper`)에 이미
스킬이 있다면, OpenCode는 그 경로를 그대로 읽는다.

## 미확정 항목

권한 모델, 백그라운드 실행 인터페이스 등 OpenCode와 다른 런타임 간의 세부
차이는 아직 미확정이다. 내용이 확인되면 이 파일에 추가한다. 확인 전에는
추측 내용을 적지 않는다.

## Capability (Host Contract v1 기준)

> 기준: `platform/HOST-CONTRACT.md`. 아래 등급은 이번 세션에서 **실제로 관측된
> 증거**만 반영한다(관측되지 않은 항목은 `검증필요`).

| capability | 등급 | 근거/비고 |
|---|---|---|
| Skill 발견 (Skill Discovery) | native | OpenCode가 `.claude/skills`를 자체적으로 직접 읽어 별도 설치 없이 로드함이 관측됨(OpenCode 공식 지원) |
| 구조화된 선택 UI (graceful degradation) | native | "실행 방식을 선택하세요", "직접 선택" 등의 구조화된 선택 UI를 띄워 흐름이 진행됨이 관측됨 |
| `$SKILL_DIR` 해석 | native | 스킬 경로의 `scripts/kant-loop.sh` 실행이 관측됨(실측 기반. `$SKILL_DIR` 규약 자체의 정밀 동등성은 별도 검증 대상) |
| foreground 백엔드 호출 | native | `kant-loop.sh run ...`이 실제 산출물(calculator.py 등)까지 완주함이 관측됨 |
| background 실행 (`--detach`) | 검증필요 | 이번 세션 미측정 |
| 완료 wake-up (background 완료 알림) | 검증필요 | 이번 세션 미측정 |
| permission 모델 | 검증필요 | 이번 세션 미측정 |
