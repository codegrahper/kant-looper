# `platform/` — Meta Agent Host 축

이 디렉터리는 **Meta Agent Host 축**, 즉 "어느 런타임에서 Meta Agent(오케스트레이터)를
구동하느냐"에 따른 차이를 다룬다. 런타임마다 UI 형태, 설치 경로, 권한 부여 방식,
백그라운드 실행 인터페이스가 다르다.

## 두 축의 경계 (반드시 구분할 것)

Nomad Kant Looper에는 서로 직교하는 두 축이 있다. 이 둘을 섞으면 안 된다.

| 축 | 위치 | 의미 | 현재 상태 |
|---|---|---|---|
| **Meta Agent Host** | `platform/` (이 디렉터리) | 런타임이 Meta Agent를 *구동*하는 방식. 런타임별 UI/설치경로/권한 차이. | 이번 작업에서 새로 만듦 |
| **Worker Provider** | `scripts/adapters/*.sh` | Meta Agent가 외부 Worker CLI를 *호출*하는 방식 (codex/claude/grok/opencode/agy 각각의 호출 규약). | 기존. 이번 작업에서 손대지 않음 |

한 런타임(Claude Code, Codex, OpenCode 등)은 **두 역할을 동시에** 가질 수 있다.
예를 들어 Codex는 Meta Agent Host로서 Meta Agent를 구동할 수 있고, 동시에 다른
런타임이 구동하는 Meta Agent에게 Worker Provider로서 호출될 수도 있다. 그렇기
때문에 "호출을 받는 쪽(Worker Provider, `scripts/adapters/`)"과 "호출을 시작하는
쪽(Meta Agent Host, `platform/``)"은 별개의 문서 축으로 분리된다.

이름을 "adapters"로 재사용하지 않는 이유가 바로 이 두 축이 섞이는 것을 막기
위해서다.

## 각 파일의 역할

- `platform/claude-runtime.md` — Claude Code 런타임에서 Meta Agent를 구동할 때의 설치
  경로, 백그라운드 실행, 훅 관련 세부 내용을 담는다.
- `platform/codex.md` — Codex 런타임에서 Meta Agent를 구동할 때의 설치 경로와
  Codex 전용 인터페이스 메타데이터 위치, 그리고 미확정 TODO를 기록한다.
- `platform/opencode.md` — OpenCode 런타임에서 Meta Agent를 구동할 때의 설치
  방식(별도 설치 불필요)과 미확정 항목을 기록한다.

## Frontmatter 메타데이터 정책

`SKILL.md` 프론트매터의 **canonical 필드는 `name`과 `description` 두 개뿐**이다.
이 두 필드는 모든 런타임이 공통으로 읽을 수 있도록 `SKILL.md`에 그대로 유지한다.

반면 아래 두 필드는 런타임 호환성을 깨뜨릴 위험이 있어 **이번 단계에서는
`platform/` 으로 옮기지 않고 `SKILL.md`에 그대로 둔다**:

- `user-invocable` — 일부 런타임만 인식하는 메타데이터.
- `allowed-tools` — Claude Code 전용의 Bash 권한 glob 문법
  (`Bash(scripts/kant-loop.sh:*)` 형태). 다른 런타임의 권한 모델과 호환되지
  않으므로, canonical에서 분리하지 않고 Claude Code 동작을 보존하기 위해
  `SKILL.md`에 남겨둔다.

이 분리는 향후 단계에서 다시 검토된다.

### Codex 전용 메타데이터

Codex 전용 인터페이스 메타데이터는 **이미 `agents/openai.yaml`(저장소 루트)이
별도로 담당**하고 있다. 따라서 Codex 런타임을 위한 새 메타데이터 파일을
`platform/` 아래에 또 만들 필요는 없다 — `platform/codex.md`는 그 파일을
가리키는 포인터 역할만 한다.

> 참고: `scripts/lib/no-progress-detector.sh`는 현재 호출되지 않는 죽은 코드다. 삭제 여부는 v0.7 작업에서 결정한다.
