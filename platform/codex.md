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
