# Task

## 목표

`scripts/lib/routing-parser.sh`의 `classify_task_intent()`와 `estimate_complexity()`가
단어 경계 없는 정규식 때문에 의미 없는 부분 문자열 매칭으로 의도/복잡도를 오분류하는
버그를 고친다.

## 배경 (재현된 문제)

`classify_task_intent()` (약 scripts/lib/routing-parser.sh:303-328)의 `ui` 분기 정규식에
`접근` 키워드가 들어있는데, 이게 "UI 접근성(accessibility)"을 잡으려는 의도였지만
단어 경계가 없어서 "설정 파일 **접근** 가능", "작업 디렉터리 **접근** 권한" 같은
UI와 무관한 일반 텍스트(파일시스템 접근 권한 등)에도 매칭된다. `elif` 체인 첫 분기라
한 번 매칭되면 이후 `review`/`refactor`/`debug`/`cli` 분기는 아예 검사되지 않는다.

`estimate_complexity()` (약 scripts/lib/routing-parser.sh:330-347)의 T3 분기 정규식에
bare `전체` 키워드가 들어있는데, "저장소 **전체**" 의미로 넣은 것이지만
"실행 비용을 낮춘다"의 "**전체** 비용"처럼 "overall/total"이라는 무관한 뜻으로 쓰인 경우에도
매칭되어 T3로 과대 추정된다.

두 버그 모두 커밋 `85d4463`에서 신규 도입된 뒤 한 번도 수정된 적이 없다.
(재현: `bash scripts/lib/routing-parser.sh classify-intent <파일>`,
`bash scripts/lib/routing-parser.sh estimate-complexity <파일>` — bash 어댑터 관련
텍스트인데 파일/디렉터리 "접근" 권한을 언급하거나 "전체 비용"류 표현이 있으면
쉽게 재현 가능.)

## 작업 내용

1. `classify_task_intent()`의 키워드 정규식들(`ui`, `test`, `review`, `refactor`, `debug`,
   `docs`, `cli`, `research` 등 모든 분기)을 조사하여 단어 경계 없이 매칭될 수 있는
   짧고 모호한 한국어 토큰(`접근`처럼 다른 맥락에서 흔히 쓰이는 단어)을 식별한다.
2. `접근` 같은 모호한 단어는 실제 UI 접근성 문맥(예: `접근성`, `a11y`, `accessibility`)만
   매칭하도록 정규식을 좁히거나, 더 구체적인 복합 표현으로 교체한다.
   `grep -E`의 확장 정규식에서 사용 가능한 단어 경계 처리 방식을 사용한다
   (Bash 3.2 호환 — `grep -E`는 GNU/BSD 모두 `[[:<:]]`/`\b` 지원이 플랫폼마다 다르므로,
   가능하면 더 긴/구체적인 키워드 조합으로 모호성을 없애는 방식을 우선 고려한다).
3. `estimate_complexity()`의 T3 분기에서 bare `전체`도 동일한 문제가 있는지 확인하고,
   "저장소 전체"/"repository 전체" 같은 맥락이 명확한 복합 표현으로 좁히거나
   해당 브랜치의 다른 키워드로 대체한다. T2/T4 분기 등 다른 정규식도 같은 패턴의
   버그가 있는지 함께 점검한다.
4. 수정 후 `references/multimodel-coding-agent-routing-guide.md`(SSOT)에 이 의도
   분류 키워드 표가 없다는 점도 확인했다 — 이번 작업 범위에서 가이드 문서에
   intent 키워드 표를 새로 추가할 필요는 없다(문서화는 별도 작업). 코드 버그
   수정에만 집중한다.

## 수정 범위

- `scripts/lib/routing-parser.sh` (`classify_task_intent`, `estimate_complexity` 함수만)
- 필요 시 `scripts/tests/` 안의 관련 라우팅 테스트에 회귀 케이스 추가
  (기존 테스트 파일이 있으면 재사용, 없으면 최소한의 새 테스트 추가)

## 유지 조건

- **Kant-Looper 안전 5원칙 준수**: 자동 push 금지, main 직접 커밋 금지,
  rebase/reset --hard 금지, protected paths 변경 금지, 범위 밖 변경 금지
- Bash 3.2 호환성 유지 (associative array 금지, `[[ ]]` 내 `\s` 금지,
  `[[:space:]]` 사용)
- 기존에 올바르게 분류되던 다른 케이스(`review`, `refactor`, `debug`, `cli` 등)의
  동작을 깨뜨리지 않는다 — 정규식을 좁히되 원래 의도한 매칭(진짜 UI 접근성 언급,
  진짜 "저장소 전체" 언급)은 계속 잡혀야 한다.
- `_intent_to_route()`, `match_with_judgment()` 등 라우팅 파서의 다른 함수는
  이번 작업 범위가 아니면 변경하지 않는다.
- `--chain` 플래그가 `KANT_AGENT_CHAIN`을 export만 하고 아무 데도 소비되지 않는
  별도의 기존 버그가 있다는 걸 확인했다 — 이건 이번 작업 범위가 아니다. 건드리지 않는다.

## 검증

다음 명령으로 수정 전/후 결과를 비교한다.

```bash
bash -n scripts/lib/routing-parser.sh

# 이 저장소에 실제 있는 TASK-opencode-glm-debug-enhanced.md 계열 텍스트로 재현/검증
# (bash 어댑터 관련 텍스트, "접근 권한"/"전체 비용" 표현 포함된 파일)
bash scripts/lib/routing-parser.sh classify-intent TASK.md
bash scripts/lib/routing-parser.sh estimate-complexity TASK.md
# 수정 후: ui가 아니라 debug 또는 refactor 계열로, 그리고 실제 내용에 맞는 복잡도로 나와야 함

# 기존 회귀 테스트가 있으면 실행
bash scripts/tests/test-meta-aware-routing.sh 2>&1 | tail -30
```

## 완료 조건

- [ ] `TASK.md`(현재 저장소 루트에 있는 opencode/GLM 어댑터 개선 작업지시)를
      `classify-intent`에 넣었을 때 `ui`가 아니라 `debug` 또는 `refactor`로 분류됨
- [ ] 같은 파일의 `estimate-complexity`가 문맥상 타당한 등급으로 나옴 (bare `전체`
      한 단어만으로 T3로 튀지 않음)
- [ ] 기존에 정상 분류되던 케이스(진짜 UI 작업, 진짜 저장소 전체 영향 작업 등)는
      여전히 올바르게 분류됨 — 회귀 없음
- [ ] `bash -n scripts/lib/routing-parser.sh` 통과
- [ ] 기존 라우팅 관련 테스트 스위트 통과
- [ ] 변경 사항은 `agent/kant/<run-id>` 작업 브랜치에만 커밋, main 직접 커밋/자동 push 없음
