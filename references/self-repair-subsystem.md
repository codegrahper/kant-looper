# Self-Repair Subsystem (수동 복구 전용)

> **상태: 유지 · 수동 전용(manual recovery).** 이 subsystem은 `kant-loop.sh`의
> 자동 실행 경로에서 **호출되지 않는다.** core runtime(quick / quick-chain /
> parallel)은 실패 시 `fallback-dispatcher.sh`로 다른 도구·모델을 시도할 뿐,
> 아래 스크립트를 부르지 않는다. 이 문서는 "실행에서는 안 쓰지만 테스트에는
> 남아 있는" 애매한 상태를 없애기 위해, 이 묶음을 **명시적으로 수동 복구
> subsystem으로 정의**한다 (2026-07-24 결정 — 삭제 대신 유지·명문화).

## 무엇인가

한 run이 실패했을 때, 그 실패를 사람이 아니라 메타 에이전트가 분석해서 패치를
만들고, 그 패치를 **격리된 `fix/` 브랜치에 안전하게** 적용하는 별도 복구 파이프라인.
과거 HPRAR self-healing 루프의 일부였으나, 현재 경량 구조에서는 자동 루프에서
분리되어 수동 도구로만 남았다.

## 구성 요소

| 스크립트 | 역할 | 진입점 |
|---|---|---|
| `scripts/lib/failure-context.sh` | 실패한 run의 state_dir에서 구조화된 실패 컨텍스트 캡처 | `failure-context.sh capture <state_dir>` |
| `scripts/lib/failure-analyzer.sh` | 그 컨텍스트를 메타 에이전트(claude)에 보내 root_cause·fix 제안 JSON 생성 | `failure-analyzer.sh analyze <state_dir>` |
| `scripts/lib/fix-apply.sh` | 제안 JSON의 패치를 `fix/` 브랜치에 안전 가드와 함께 적용 | `fix-apply.sh apply <json_file>` |
| `scripts/lib/apply-change.py` | 단일 변경을 argv로만 적용 (인라인 python 보간 차단용 분리) | `apply-change.py apply-one <json> <idx>` |

## 수동 사용 흐름

```bash
# 1) 실패한 run의 컨텍스트 캡처
scripts/lib/failure-context.sh capture <state_dir>

# 2) 메타 에이전트에게 분석 요청 → 제안 JSON 생성
scripts/lib/failure-analyzer.sh analyze <state_dir>

# 3) 제안 패치를 fix/ 브랜치에 적용 (현재 작업 트리는 깨끗해야 함)
scripts/lib/fix-apply.sh apply <제안_json_path>
```

각 단계는 독립적으로 실행 가능하고, 사람이 중간 산출물을 검토한 뒤 다음 단계로
넘어가는 것을 전제로 한다. `kant-loop.sh`가 이 흐름을 자동으로 잇지 않는다.

## 안전 가드 (`fix-apply.sh`)

1. `fix/*` 브랜치만 허용 — main/master/기타 명시 거부
2. 작업 디렉터리가 깨끗해야 함 (unstaged/staged 변경 있으면 거부)
3. 변경 파일만 `git add` (광역 `git add .` 금지)
4. rollback은 영향받은 파일만 (`git checkout -- .` 같은 광역 reset 금지)
5. symlink 우회 차단 — realpath resolve 후 allowlist 검사
6. `commands_to_run` 인터페이스 자체를 받지 않음 (모델이 임의 명령 실행 불가)
7. 인라인 python 보간 없음 — `apply-change.py`가 argv/JSON으로만 수신
8. idempotency marker — 동일 proposal 재실행 차단

## 관련 테스트

`scripts/tests/test-all.sh`에 포함되어 회귀로 계속 검증된다:

```
test-fix-apply-redesign.sh    # P0/P1 안전 가드
test-fix-apply-guards.sh      # 가드 개별 검증
test-fix-apply-e2e.sh         # git 통합 e2e
test-meta-agent-loop.sh       # 메타 에이전트 분석 모듈
test-redactor.sh              # secret 마스킹
```

이 테스트들이 통과한다고 해서 subsystem이 자동 실행 경로에 편입된 것은 아니다 —
어디까지나 수동 복구 도구의 회귀 방지용이다.

## 향후

core runtime을 다시 자동 self-healing으로 확장하기로 결정하면, 이 subsystem을
`kant-loop.sh`의 실패 처리 경로에 연결하는 것이 출발점이 된다. 그 전까지는
수동 전용으로 유지한다.
