---
name: kant-looper
description: 외부 CLI 도구(codex, grok, opencode, agy, claude)를 백그라운드로 호출해 작업을 시키고, Claude가 결과를 비판적으로 검증한 뒤 작업 브랜치에 커밋합니다. main 병합은 사용자의 명시적 승인을 기다립니다. "백그라운드로 돌려서 검증까지", "코덱스한테 시키고 결과만 확인하고 싶어", "루프로 처리하고 끝나면 알려줘", "HPRAR 가볍게 돌려줘", "main 병합은 내가 직접 할게", "도구 한 번만 호출해서 끝내줘", "여러 모델 동시에 돌려줘", "agy한테 UI 맡기고 glm한테 로직 맡겨" 라는 발화에서 즉시 트리거.
user-invocable: true
allowed-tools:
  - "Bash(scripts/kant-loop.sh:*)"
  - "Bash(scripts/lib/*:*)"
  - "Bash(scripts/adapters/*:*)"
  - "Bash(scripts/tests/*:*)"
  - "Bash(git status:*)"
  - "Bash(git diff:*)"
  - "Bash(git log:*)"
  - "Bash(git rev-parse:*)"
  - "Read"
  - "Write"
---

# kant-looper — 외부 도구 호출 + 검증 + 커밋 루프

> "칸트는 냉정합니다" — 이 skill은 작업을 외부 도구에 위임하고, **비판적으로 검증한 뒤** 작업 브랜치에 커밋합니다. **main 병합은 사용자가 직접 합니다.**

## 한 줄로 보기

```
TASK.md → 백그라운드로 외부 도구 호출 → 결과 검증 → 작업 브랜치 커밋 → 보고
   ↑                                                              ↓
   └──────── 검증 실패 시 자동 재시도 또는 다른 모델로 전환 ────────┘
```

이 작업이 끝났는데 verdict가 PASS면 자동으로 커밋됩니다. **main에 합치는 건 별개** — `kant-loop.sh promote` 명령을 사용자가 직접 실행.

## 3가지 모드

| 모드 | 인자 | 적합 | 백엔드 동작 |
|---|---|---|---|
| `--quick` | 단일 도구 한 번 호출 + gate + (선택) commit | T0~T1, 가벼운 수정 | 풀 라운드/카드 시스템 생략 |
| `--parallel` | 2~4개 도구 동시 호출 + 머지 + commit | T2, UI+로직+테스트 분리 | `nohup + wait` 병렬 |
| `--full` | plan → implement → review → commit (+ repair 라운드) | T3~T4, 복잡한 작업 | HPRAR 풀 루프 (MAX_ROUNDS=2) |

기본값은 `--full`. T0~T1 작업에 무거운 풀 루프는 과합니다. 가벼운 작업엔 `--quick`을 명시.

## 호출 예시

```bash
# 드라이런 (환경 검사만)
kant-loop.sh preflight TASK.md
kant-loop.sh run TASK.md --dry-run

# 가벼움: --quick (단일 호출)
kant-loop.sh run TASK.md --quick --agent codex --model gpt-5.6-terra

# 동시성: --parallel (UI + 로직 + 검증)
kant-loop.sh run TASK.md --parallel --auto-route

# 풀: --full (기본, HPRAR)
kant-loop.sh run TASK.md
kant-loop.sh run TASK.md --strict-verify    # Round 1 PASS여도 verify 강제
kant-loop.sh run TASK.md --no-auto-commit  # PASS까지만, commit은 사용자가

# 백그라운드 (장기 작업)
kant-loop.sh run TASK.md --detach
# → run_id + state-dir 즉시 반환
# → 완료 시 macOS notification

# 상태 확인
kant-loop.sh status --latest
kant-loop.sh status <run-id>

# 보고서
kant-loop.sh report <run-id>

# main 병합 (사용자 명시 실행)
kant-loop.sh promote agent/kant/<run-id> --target main

# 가이드 갱신 (외부 → 내부)
kant-loop.sh update-guide

# 14일 지난 state 정리
kant-loop.sh cleanup --apply
```

## 자동 라우팅 (T0~T4)

`routing-parser.sh`가 `references/multimodel-coding-agent-routing-guide.md`를 매번 파싱해서 동적으로 결정. 코드에 박힌 매핑 없음. 가이드 갱신 시 자동 반영.

| 키워드 | 라우트 |
|---|---|
| UI, component, screen, stitch, modal, css, frontend | agy (gemini-3.5-flash) |
| 단위 테스트, fixture, mock | codex (gpt-5.6-luna) |
| 리팩터, migrate, cleanup | opencode (glm-5.2) |
| 터미널, cli, rust, c++ | grok (grok-4.5) |
| 리뷰, verify, audit | codex (gpt-5.6-sol) |
| 1M, huge, large repo | opencode (glm-5.2) |
| 기본 | codex (gpt-5.6-terra) |

## 안전 약속 (절대 위반 안 됨)

1. **자동 push 금지** — 어떤 원격에도 push 안 함
2. **merge commit 금지** — ff-only만, `promote` 명령으로만
3. **rebase / reset --hard / branch -D 금지**
4. **main 직접 커밋 금지** — 작업 브랜치(`agent/kant/<run-id>`)에만
5. **protected paths 변경 차단** — `.env`, `*.pem`, `*.key`, `*credential*`, `*secret*`, `node_modules`, `dist`, `build`, `__pycache__`

상세: `references/safety-promises.md`

## 호출 실패 시 Fallback

인증 실패 / timeout / rate limit / 형식 오류 / 네트워크 에러 — 모든 실패 모드에 즉시 대응. **claude가 마지막 폴백**이라 작업이 중단되는 일은 거의 없음.

상세: `references/failure-modes.md`, `references/fallback-table.md`

## 무진전 감지 + 자동 중단

routing 가이드 10.2 정책 기반. 같은 diff 3회 / 같은 테스트 실패 2회 / 10회 도구 호출 동안 변화 없음 → 자동 중단.

상세: `references/failure-modes.md` §무진전 감지

## 작업 보고 형식

```
작업 끝났어요.

- run-id: <RUN_ID>
- 모드: --quick / --parallel / --full
- 결과: PASS / CHANGES_REQUESTED / BLOCKED / FALLBACK_TO_CLAUDE
- 사용된 도구: codex(gpt-5.6-terra) → glm-5.2 (fallback) → claude (final)
- 라운드: 1 (strict-verify=0) 또는 2
- 브랜치: agent/kant/<run-id>
- 커밋: <COMMIT_SHA> (tree <COMMITTED_TREE_SHA>)
- 변경 파일 수: <N>
- diff 해시: <FINAL_DIFF_HASH>
- fallback 발생: N회

main에 합치시려면:
  bash <SKILL_DIR>/scripts/kant-loop.sh promote agent/kant/<run-id> --target main
```

## 설계 원칙 (이 스킬의 약속)

> 1. **외부 가이드를 skill 폴더 내부 SSOT로**. 절대 외부 경로 참조 안 함. `/kant-looper update-guide`로만 갱신.
> 2. **호출 실패 시 즉시 fallback**. claude가 마지막 폴백. 작업 중단 거의 없음.
> 3. **MCP/CLI health check를 모든 호출 전 수행**. 죽은 도구는 즉시 우회.
> 4. **Claude 사용량 절감**. Claude는 메타 오케스트레이션만.
> 5. **merge는 사용자가 명시 실행**. 3중 강제 (allowed-tools + 스크립트 + promote 분기).
> 6. **이바가 개입하는 순간 그건 kant-looper가 아닙니다**. 완전 자동이 1차 목표.
> 7. **칸트는 냉정합니다**. verdict는 verdict대로. 감정/사정 개입 없이 원칙만으로 결정.

## 디렉토리

```
~/.claude/skills/kant-looper/
├── SKILL.md (지금 보고 있는 파일)
├── references/
│   ├── multimodel-coding-agent-routing-guide.md  # SSOT 라우팅 가이드
│   ├── loop-flow.md                              # 라운드/상태 머신
│   ├── verdict-schema.md                         # JSON verdict 스키마
│   ├── safety-promises.md                        # 안전 약속 전체
│   ├── failure-modes.md                          # 실패 모드 + 무진전 감지
│   ├── fallback-table.md                         # 도구별 fallback 체인
│   └── agy-cli-notes.md                          # agy(Antigravity) CLI 실전 노트 — sandbox/mode/모델ID 등
├── scripts/
│   ├── kant-loop.sh                              # 메인 백엔드
│   ├── adapters/                                 # 5개 어댑터 (codex/grok/opencode/agy/claude)
│   ├── lib/                                      # 8개 라이브러리 (routing/health/fallback/...)
│   └── tests/                                    # 시나리오 자동 검증
└── agents/openai.yaml                            # 인터페이스 메타
```

상세 backend 동작은 `references/loop-flow.md` 참조. 그 외 모든 것은 스크립트가 담당.
