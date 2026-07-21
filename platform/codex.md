# `platform/codex.md` — Codex (Meta Agent Host)

이 파일은 **Codex 런타임에서 Meta Agent를 구동**할 때의 정보를 담는다.

## 설치 경로

설치 경로는 `$HOME/.codex/skills/nomad-kant-looper`이다.

> **설치 방식:** 이 경로(`$HOME/.codex/skills/nomad-kant-looper`)는 이 저장소의
> git worktree다. `install.sh --agent codex`로 생성/갱신한다(재실행 시
> `git pull --ff-only`가 사실상의 sync 경로). 예전에는 독립 clone이었으나
> v0.6.0에서 worktree로 전환됐다.

## Codex 전용 인터페이스 메타데이터

Codex 런타임을 위한 인터페이스 메타데이터(name, phases, modes, agents,
safety, …)는 **저장소 루트의 `agents/openai.yaml`**에 분리되어 있다.
`platform/codex.md` 아래에 중복 파일을 만들지 않는다. 자세한 내용은
`../agents/openai.yaml`을 참조.

## 미확정 TODO

다음 항목은 아직 검증되지 않았다. 단정하지 않는다.

1. **구조화된 선택 UI 가용 등급 미검증.** Codex가 사용자에게 선택지를
   제공할 때, 어느 형태까지 지원하는지(구조화된 UI / 번호가 매겨진 목록 /
   평문 출력)가 아직 검증되지 않았다. 어느 등급에 해당하는지 확인되면 이
   파일에 기록한다.

## Capability (Host Contract v1 기준)

> 기준: `platform/HOST-CONTRACT.md`. 아래 등급은 이번 세션에서 **실제로 관측된
> 증거**만 반영한다(관측되지 않은 항목은 `검증필요`).

| capability | 등급 | 근거/비고 |
|---|---|---|
| Skill 발견 (Skill Discovery) | native | `~/.codex/skills/nomad-kant-looper` worktree에서 로드됨이 관측됨 |
| 구조화된 선택 UI (graceful degradation) | native | "1개의 질문 중 1개" 형태의 구조화된 선택 카드(작업 입력/직접 답변 입력)를 띄워 흐름이 진행됨이 관측됨 |
| `$SKILL_DIR` 해석 | native | 스킬 경로의 `scripts/kant-loop.sh`를 실행함이 관측됨(실측 기반. `$SKILL_DIR` 규약 자체의 정밀 동등성은 별도 검증 대상) |
| foreground 백엔드 호출 | native | `kant-loop.sh run ...`이 completed까지 도달함이 관측됨(OpenCode/MiniMax 및 Claude 워커 호출 포함) |
| background 실행 (`--detach`) | 검증필요 | 이번 세션 미측정 |
| 완료 wake-up (background 완료 알림) | 검증필요 | 이번 세션 미측정 |
| permission 모델 | 검증필요 | Codex 고유 sandbox/승인 모델과의 대응 미측정 |
