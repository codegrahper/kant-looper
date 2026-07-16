# SSOT 2주 관찰 시험 (Phase 5 진입 조건 추적)

> `routing-ssot/PHASE-3-5-PLAN.md`의 "Phase 5 진입 조건"을 실제로 추적하는 운영 문서.
> 이 문서가 관리하는 건 **hardcode 제거(candidate A) 착수 여부를 판단하는 관찰 기간**이다.

## 상태

| 항목 | 값 |
|---|---|
| 시작일 | 2026-07-16 |
| 최소 종료일 | 2026-07-30 (14일) |
| 현재 상태 | 🟡 진행 중 |
| 병합된 버전 | main `0da3f1c` (SSOT 라우팅 통합 + self-scan/self-dispatch + await, `Kant-looper-branch`/`routing-ssot-integration` 경유 ff-only 병합) |

## Phase 5 진입 조건 (PHASE-3-5-PLAN.md 원문)

- [ ] 최소 2주간 `KANT_ROUTING_SOURCE=ssot` 기본 사용
- [ ] 회귀 없음
- [ ] 이바가 명시적으로 hardcode 제거 승인

**세 조건 모두 충족돼야 candidate A(hardcode 상수 제거) 착수 가능.** 2주가
지났다는 사실만으로는 착수 조건이 안 된다 — 회귀 없음 확인과 이바의 명시
승인이 별도로 필요하다.

## 환경 설정

`~/.zshrc`에 추가됨 (2026-07-16):

```bash
export KANT_ROUTING_SOURCE=ssot
export KANT_SHADOW_LOG=~/.claude/state/kant-looper/ssot-shadow.log
```

- `KANT_ROUTING_SOURCE=ssot`: 실제 라우팅 판정에 SSOT(`routing-ssot/routing-ssot.yaml`)를
  우선 사용. 실패 시(파일 유실, 로더 크래시 등) 자동으로 hardcode로 폴백 —
  `test-ssot-stress-simulation.sh`로 이 폴백 자체는 이미 검증됨.
- `KANT_SHADOW_LOG`: `KANT_SHADOW_MODE=on`일 때 hardcode/SSOT 판정 결과를 비교
  기록하는 TSV 로그의 영구 경로 (기존 기본값 `/tmp/kant-shadow.log`는 재부팅
  시 유실되어 2주 관찰용으로 부적합했음 — 이 경로로 교체).

## 회귀 감시

이 기간 동안 kant-looper를 실사용할 때마다 다음을 관찰한다.

1. **`KANT_ROUTING_SOURCE=ssot` 상태에서 라우팅 결과가 이상하면 즉시 기록** —
   아래 "관찰 로그"에 날짜/증상/실제 vs 기대 라우트를 남긴다.
2. **`bash scripts/tests/test-routing-ssot-sync.sh`**를 주기적으로 돌려
   hardcode↔SSOT drift가 없는지 확인한다 (자동화된 4개 케이스).
3. 문제가 재현되면 즉시 `KANT_ROUTING_SOURCE=hardcode`로 되돌릴 수 있다
   (환경변수 하나 바꾸면 즉시 복귀 — Phase 4 완료조건에서 이미 검증됨).

## 관찰 로그

| 날짜 | 증상 | 실제 라우트 | 기대 라우트 | 조치 |
|---|---|---|---|---|
| (아직 없음) | | | | |

## 종료 절차 (2026-07-30 이후)

1. 관찰 로그에 회귀 기록이 없는지 확인
2. `bash scripts/tests/test-routing-ssot-sync.sh` 최종 실행
3. 이바에게 결과 보고 후 hardcode 제거(candidate A) 착수 여부 명시 승인 요청
4. 승인되면 `routing-ssot/PHASE-3-5-PLAN.md`의 "Phase 5 — Hardcode 제거" 섹션대로
   진행
