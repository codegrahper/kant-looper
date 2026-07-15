# Kant Looper SSOT 주기적 업데이트 플랜

## 1. 최종 문서 구조

`config/routing-ssot.yaml`만 실행 정책의 SSOT로 사용한다.

```text
config/routing-ssot.yaml                         # 사람이 승인하는 유일한 실행 SSOT
schemas/routing-ssot.schema.json                 # 구조 검증
scripts/validate-routing-ssot.py                 # 참조·정책 의미 검증
scripts/update-routing-ssot.py                   # 후보 patch 생성
scripts/render-routing-guide.py                  # Markdown 파생 문서 생성
references/multimodel-coding-agent-routing-guide.md
references/multimodel-coding-agent-routing-guide-simplified.md
evaluations/routing-regression.json              # 사내 회귀 평가 결과
audit/routing-updates/*.json                     # 업데이트 근거와 승인 기록
```

기존 상세 가이드와 간소화 가이드는 삭제할 필요는 없지만 직접 편집해서는 안 된다.
두 파일 상단에 `GENERATED FILE — DO NOT EDIT`를 넣고 SSOT에서 자동 생성한다.

## 2. 업데이트 주기

| 점검 대상 | 주기 | 자동화 결과 |
|---|---|---|
| 모델 존재 여부, Stable/Preview/Deprecated | 매주 | 후보 JSON 및 patch |
| 모델 ID·컨텍스트·도구 지원·가격·쿼터 | 매주 및 배포 전 | 후보 JSON 및 patch |
| 공급사 릴리스 노트 | 매주 | 변경 요약 |
| 외부 벤치마크 | 새 모델 출시 때 | 참고 데이터만 갱신 |
| 사내 저장소 회귀 평가 | 매월 | 승격·강등 후보 |
| MCP·권한·보안 정책 | 분기 | 정책 검토 PR |
| 긴급 Deprecated/장애 | 감지 즉시 | 사용 중지 후보; 자동 활성화 금지 |

## 3. 업데이트 파이프라인

1. 각 공급사 공식 모델 문서, 릴리스 노트, Deprecated 페이지를 수집한다.
2. LLM에게 전체 Markdown 재작성을 맡기지 않는다.
3. 수집 결과를 제한된 `candidate-update.json` 구조로 정규화한다.
4. 각 변경에는 `field`, `old`, `new`, `source_url`, `observed_at`, `evidence`를 기록한다.
5. 공식 출처 URL과 관찰 날짜가 없는 변경은 폐기한다.
6. 후보를 SSOT에 적용한 임시 YAML을 만든다.
7. JSON Schema 검증과 의미 검증을 실행한다.
8. 모든 route 모델이 registry에 존재하는지 확인한다.
9. Stable/Preview/Deprecated, capability, provider, context 필드를 교차검증한다.
10. 라우팅 변경이면 사내 회귀 평가를 실행한다.
11. 기존 primary 대비 성공률, 비용, 지연시간, 보안 위반을 비교한다.
12. 상세 가이드와 간소화 가이드를 임시 SSOT에서 재생성한다.
13. SSOT와 생성 문서의 diff를 함께 출력한다.
14. 구현 공급사와 다른 공급자의 모델이 변경안을 독립 리뷰한다.
15. 사람이 승인한 뒤에만 merge한다.
16. merge 후 SSOT SHA-256과 승인자를 감사 로그에 기록한다.

## 4. 자동화 허용 범위

자동화가 할 수 있는 일:

- 공식 출처 수집
- 변경 후보 구조화
- schema·semantic 검증
- 테스트 실행
- Markdown 생성
- PR 또는 patch 생성

자동화가 해서는 안 되는 일:

- SSOT 직접 덮어쓰기
- primary 모델 자동 변경
- Preview 모델 자동 승격
- 출처 없는 수치 삽입
- 벤치마크 하나만으로 라우팅 순위 변경
- 자동 merge
- Deprecated 모델을 fallback으로 유지

## 5. 승격·강등 기준

모델 승격은 다음을 모두 만족해야 한다.

- 공식 모델 ID와 상태 확인
- 최소 20개 이상의 대표 작업 회귀 평가
- 현재 primary보다 성공률이 2%p 이상 나쁘지 않음
- 보안·권한 위반 증가 없음
- 품질이 같으면 비용 또는 지연시간 개선
- T3/T4는 다른 공급자 리뷰 통과
- 사람 승인

즉시 강등 또는 비활성화 조건:

- Deprecated 또는 서비스 종료
- 반복적 API 실패
- 보안 정책 위반
- 특정 route에서 실패율 임계치 초과
- 모델 ID가 더 이상 공식 문서에 존재하지 않음

## 6. CI 필수 검사

```bash
python scripts/validate-routing-ssot.py   config/routing-ssot.yaml   schemas/routing-ssot.schema.json

python scripts/render-routing-guide.py --check
python scripts/run-routing-regression.py --minimum-samples 20
git diff --exit-code -- references/
```

필수 실패 조건:

- 알 수 없는 모델 또는 provider
- route와 registry 불일치
- primary와 fallback 중복
- required capability 누락
- Deprecated/disabled 모델 사용
- 출처 또는 확인일 누락
- 생성 문서가 SSOT와 불일치
- T3/T4 리뷰 공급사가 구현 공급사와 동일
- 자동 변경이 허용 범위를 초과

## 7. 기존 첨부 문서 처리

### 상세 가이드

`multimodel-coding-agent-routing-guide.md`는 유지하되 **SSOT에서 생성되는 운영 설명서**로 바꾼다.
현재의 모델 해설, MCP 계약, 보안, 성공 판정 등 유용한 설명은 렌더러 템플릿으로 이전한다.

### 간소화 가이드

`multimodel-coding-agent-routing-guide-simplified.md`도 유지 가능하지만 **요약 파생 문서**로만 사용한다.
모델 레지스트리와 route를 사람이 이 파일에 직접 추가하면 안 된다.

### 신규 문서

실제 새로 작성되는 핵심 문서는 `routing-ssot.yaml`이다.
따라서 답은 “기존 가이드를 단순 수정”이 아니라 **새 실행 SSOT를 만들고 기존 가이드를 파생 문서로 전환**하는 것이다.

## 8. 도입 순서

1. 새 YAML과 Schema를 `draft` 상태로 추가한다.
2. 현재 Kant Looper의 실제 모델 선택 코드와 필드 매핑을 작성한다.
3. validator를 CI에 연결한다.
4. 기존 라우팅 상수를 YAML 로더로 교체한다.
5. shadow mode로 기존 라우터와 새 라우터의 결정을 비교한다.
6. 차이를 검토하고 회귀 평가한다.
7. YAML 상태를 `active`로 변경한다.
8. 기존 Markdown의 직접 편집을 금지한다.
9. 렌더러 생성물을 CI에서 검증한다.
10. 한 번의 안정화 기간 후 중복된 기존 설정을 제거한다.
