# Kant-Looper OpenCode/GLM 어댑터 안정성·토큰 효율 개선

## 목표

`adapter-opencode.sh`에서 GLM 계열 모델(`glm-4.7`, `glm-5.2` 등) 호출 시 발생하는 다음 문제를 근본적으로 해결한다.

1. **verdict 추출 불안정성**
2. **`changed_files` 보고 누락 또는 환각**
3. **정상 작업을 실패로 오판해 발생하는 불필요한 repair/fallback 재호출**
4. **모델·variant·provider·쓰기 권한 조합의 불명확성**
5. **OpenCode 전용 파서와 다른 어댑터 간의 동작 불일치**

현재는 `git diff` 기반 사후 패치로 증상을 억제하고 있으나, 이는 근본 원인 해결이 아니다. 인라인 Python 파서가 `<verdict>WORD</verdict>` 태그 폴백에서 `changed_files: []`를 고정하고, 이 폴백이 항상 값을 반환하기 때문에 `verdict-extractor.sh`로의 최종 폴백이 사실상 dead code가 되는 구조가 핵심 원인이다.

최종 목표는 다음과 같다.

- OpenCode 어댑터도 다른 어댑터(codex/grok/agy/claude)와 동일하게 `verdict-extractor.sh`를 사용한다.
- OpenCode 특유의 NDJSON 이벤트 스트림 정규화는 공통 추출기 내부로 이동한다.
- 모델의 자기 보고는 참고값으로만 사용하고, 실제 변경 파일은 Git diff를 최종 사실값(source of truth)으로 검증한다.
- 정상 완료 작업의 불필요한 재시도와 모델 재호출을 줄여 토큰 사용량과 전체 실행 비용을 낮춘다.

---

## 기대 효과

### 안정성

- 정상 응답을 `EXTRACT_FAILED`로 잘못 판정하는 비율 감소
- 실제 변경 파일을 빈 배열로 보고하는 문제 제거
- 모델이 존재하지 않는 파일을 변경했다고 주장하는 경우 차단
- OpenCode와 다른 어댑터의 verdict 처리 방식 통일
- provider/model/variant/권한 오류를 실행 초기에 탐지

### 토큰 및 실행 비용

- verdict 파싱 실패로 인한 동일 프롬프트 재전송 감소
- 불필요한 repair 단계 진입 감소
- fallback 모델 호출 감소
- 정상 작업을 실패로 오판해 루프 전체를 다시 실행하는 경우 감소

> 이 작업은 모델 자체의 추론 속도를 높이는 최적화가 아니다.  
> 정상적으로 완료된 작업을 다시 수행하지 않도록 판정 경로를 정확하게 만드는 안정성·비용 최적화다.

---

## 핵심 설계 원칙

1. **실제 Git 상태가 최종 사실값이다.**
   - 모델 응답의 `changed_files`는 참고값이다.
   - 최종 검증은 `git diff --name-only`, `git status --porcelain` 등 실제 저장소 상태를 기준으로 한다.

2. **파싱 실패와 작업 실패를 구분한다.**
   - 모델이 작업에 실패한 경우와, 작업은 성공했지만 응답 파싱만 실패한 경우를 동일하게 취급하지 않는다.
   - 파싱 재시도 전에 실제 diff와 테스트 결과를 확인한다.

3. **한 번의 응답은 가능한 한 한 번만 모델 호출한다.**
   - 동일 응답 파일을 여러 파서가 중복 해석하는 것은 허용하되, 파싱 문제만으로 즉시 모델을 재호출하지 않는다.

4. **OpenCode 전용 처리는 최소화한다.**
   - NDJSON 정규화만 OpenCode 전용 함수에서 수행한다.
   - verdict JSON 생성과 검증은 공통 경로를 사용한다.

5. **기존 안전 규칙과 다른 어댑터의 동작은 변경하지 않는다.**

---

## 작업 내용

### 1. 인라인 Python 파서 제거 및 공통 추출기로 통합

- `adapter-opencode.sh`의 인라인 Python verdict 파서를 제거한다.
- 다른 어댑터와 동일하게 아래 한 줄을 기본 호출 경로로 사용한다.

```bash
"$SKILL_LIB/verdict-extractor.sh" extract "$response_file"
```

- OpenCode 응답이 NDJSON 이벤트 스트림인 경우, 정규화 로직을 `verdict-extractor.sh` 내부로 이동한다.
- 권장 함수 구조:

```bash
extract_opencode_text() {
  # NDJSON 이벤트 중 사용자에게 보이는 text part만 순서대로 결합
}

extract_verdict_json() {
  # 정규화된 평문에서 공통 verdict 스키마 추출
}
```

- NDJSON 파싱 시 다음을 고려한다.
  - 빈 줄 및 비 JSON 로그 허용
  - `type=text` 또는 동등한 텍스트 이벤트만 결합
  - 이벤트 순서 보존
  - 일부 손상된 라인이 있어도 전체 추출을 즉시 중단하지 않음
  - 최종적으로 텍스트가 비어 있을 때만 `EXTRACT_FAILED`

### 2. `<verdict>WORD</verdict>` 폴백의 빈 필드 hardcode 제거

현재 태그 폴백은 verdict 단어만 추출하고 다음 필드를 빈 값으로 고정한다.

- `summary`
- `findings`
- `changed_files`
- `tests_added_or_updated`
- `risks`
- `notes_for_reviewer`

수정 방향:

- 태그 폴백은 최소한 유효한 7개 필드 스키마를 생성해야 한다.
- `summary`는 응답 본문의 첫 의미 있는 문장 또는 제한 길이 요약으로 채운다.
- `findings`, `risks`, `notes_for_reviewer`는 관련 섹션이 없으면 빈 문자열 대신 명시적인 기본 문구를 사용한다.
- 응답 본문에서 파일 경로 후보를 추출할 수 있으나, 이는 **후보값**으로만 저장한다.
- 최종 `changed_files`는 반드시 실제 Git diff와 교차검증한다.

권장 우선순위:

1. 구조화 JSON
2. fenced JSON
3. 명시적 섹션 기반 텍스트
4. `<verdict>...</verdict>` 태그
5. 일반 텍스트 휴리스틱
6. 추출 실패

### 3. `changed_files`의 최종 결정 규칙 명확화

`changed_files`는 다음 순서로 처리한다.

1. 모델 응답에서 보고값 추출
2. Git에서 실제 변경 파일 수집
3. 두 목록 정규화
   - 상대 경로 통일
   - 중복 제거
   - 삭제 파일 포함 여부 명시
   - protected path 제외 또는 오류 처리
4. 교차검증
5. 최종 JSON에는 실제 Git 변경 파일을 기록
6. 불일치가 있으면 별도 메타데이터 또는 로그에 남김

권장 로그 예시:

```text
MODEL_CHANGED_FILES=src/a.sh,tests/a_test.sh
ACTUAL_CHANGED_FILES=src/a.sh
CHANGED_FILES_MISMATCH=tests/a_test.sh
```

다음 오류를 구분한다.

- `CHANGED_FILES_OMITTED`: 실제 diff는 있으나 모델 보고가 비어 있음
- `CHANGED_FILES_HALLUCINATED`: 모델 보고에는 있으나 실제 diff에는 없음
- `CHANGED_FILES_MISMATCH`: 양쪽 목록이 일부만 일치
- `NO_ACTUAL_CHANGES`: 모델은 완료를 주장했지만 실제 변경 없음

### 4. 파싱 실패 시 모델 재호출 전 복구 절차 추가

파싱 실패가 즉시 모델 재호출로 이어지지 않도록 다음 순서를 적용한다.

1. 원본 응답 파일 존재 여부 확인
2. NDJSON → 평문 재정규화
3. 공통 추출기 재실행
4. verdict 태그 직접 탐색
5. 실제 Git diff 확인
6. 테스트 실행 결과 확인
7. 작업 성공 증거가 충분하면 제한된 fallback verdict 생성
8. 성공 증거가 없을 때만 repair/fallback 모델 호출

제한된 fallback verdict 예시:

```json
{
  "verdict": "PASS",
  "summary": "Structured verdict parsing failed, but actual file changes and required tests were verified.",
  "findings": "Recovered from response parsing failure using repository evidence.",
  "changed_files": ["actual/file/path"],
  "tests_added_or_updated": [],
  "risks": "Model-provided structured report was unavailable.",
  "notes_for_reviewer": "Review the raw OpenCode response log if detailed rationale is required."
}
```

이 복구는 다음 조건을 모두 충족할 때만 허용한다.

- 실제 변경 파일 존재
- protected path 변경 없음
- 필수 테스트 성공
- 명시적 실패 메시지 없음
- role별 완료 조건 충족

### 5. `--variant` 기본값의 모델별 유효성 검증

- `KANT_OPENCODE_VARIANT` 기본값이 각 모델에서 실제로 유효한지 검증한다.
- 추정값을 코드에 바로 고정하지 않는다.
- `opencode models --verbose`, 도움말, 실제 호출 로그를 근거로 결정한다.
- 지원하지 않는 variant는 플래그 자체를 생략하여 OpenCode 기본값을 사용한다.

권장 동작:

```text
model supports configured variant -> --variant 전달
model does not support variant     -> 경고 후 플래그 생략
unknown support status             -> 안전하게 생략 + 진단 로그
```

모델→variant 매핑이 필요하면 Bash 3.2 호환 `case` 함수로 구현한다.

```bash
resolve_opencode_variant() {
  case "$1" in
    provider/model-a) printf '%s
' "high" ;;
    provider/model-b) printf '%s
' "" ;;
    *) printf '%s
' "${KANT_OPENCODE_VARIANT:-}" ;;
  esac
}
```

### 6. 모델 정규화 로직을 단일 함수로 추출

- 현재 분산된 모델명 `case` 분기를 `normalize_opencode_model()`로 통합한다.
- 프리픽스 매핑은 함수 상단에 명확하게 문서화한다.
- bare 모델명은 등록된 provider를 확인한 뒤 정규화한다.
- 알 수 없는 이름은 기존 WARN 동작을 유지하되 추천 형식을 출력한다.

예시:

```text
WARN: unknown bare model 'glm-x'.
Use a provider-qualified name such as 'zai-coding-plan/glm-x'.
```

### 7. provider 존재 여부를 health check에 추가

`health-check.sh`에서 다음을 확인한다.

- OpenCode 실행 파일 존재
- 설정 파일 접근 가능
- 지정 provider 존재
- 지정 model 존재 또는 조회 가능
- variant 지원 여부
- implement/repair 역할에 필요한 편집 및 shell 권한
- 출력 형식이 JSON 이벤트 스트림인지 여부

health check 실패는 모델 호출 후가 아니라 호출 전에 명확한 오류로 종료한다.

### 8. 쓰기 권한 검증 개선

`--auto`를 파일 쓰기 권한 자체로 간주하지 않는다.

확인 대상:

- agent 또는 OpenCode 설정의 `edit` 권한
- shell 명령 실행 권한
- deny 규칙
- 작업 디렉터리 접근 권한
- role별 권한 차이
- 비대화형 실행 시 승인 정책

필요 시 다음 환경 변수를 추가한다.

```bash
KANT_OPENCODE_WRITE_FLAGS
```

조건:

- 기본값은 기존 동작을 보존
- 사용자가 명시적으로 지정한 경우에만 추가 플래그 전달
- 위험한 전역 승인 플래그를 기본값으로 설정하지 않음
- 실제 지원 여부를 확인하지 않은 플래그는 추가하지 않음

### 9. `changed_files` git-diff 패치 로직의 운명 결정

현재 사후 패치 로직은 근본 원인 해결 후 다음 기준으로 판단한다.

#### 제거 조건

- GLM 모델별 quick 모드 5회 연속 성공
- 모델 보고와 실제 diff 불일치 0건
- 공통 추출기 회귀 테스트 통과
- 파싱 실패 0건

#### 유지 조건

불일치가 계속 발생하면 해당 로직을 단순 패치가 아니라 **공통 검증 계층**으로 재정의한다.

- OpenCode 전용 임시 보정으로 남기지 않는다.
- 필요하다면 모든 어댑터의 자기 보고를 Git diff와 비교하는 공통 함수로 이동한다.
- 최종 JSON에는 실제 diff를 사용하고, 모델 보고값은 진단 로그에만 남긴다.

### 10. GLM/OpenCode 특화 실패 모드 문서화

`references/failure-modes.md`에 다음 실패 모드를 추가한다.

- `EXTRACT_FAILED`
- `NDJSON_NORMALIZATION_FAILED`
- `CHANGED_FILES_OMITTED`
- `CHANGED_FILES_HALLUCINATED`
- `CHANGED_FILES_MISMATCH`
- `NO_ACTUAL_CHANGES`
- `PROVIDER_MODEL_NOT_FOUND`
- `VARIANT_UNSUPPORTED`
- `WRITE_PERMISSION_DENIED`

각 실패 모드에 대해 다음을 명시한다.

- 탐지 조건
- 사용자 메시지
- 재시도 가능 여부
- fallback-dispatcher 매핑
- 모델 재호출 여부
- 토큰 절감 관점의 처리 우선순위

### 11. 토큰 사용량 및 재시도 지표 추가

가능한 범위에서 실행 로그에 다음 지표를 기록한다.

```text
MODEL_CALL_COUNT
REPAIR_CALL_COUNT
FALLBACK_CALL_COUNT
EXTRACT_RETRY_COUNT
PARSE_RECOVERY_USED
PROMPT_BYTES
RESPONSE_BYTES
```

토큰 수를 직접 제공받을 수 없으면 호출 횟수와 프롬프트/응답 바이트를 대체 지표로 사용한다.

개선 전후 비교 기준:

- 동일 fixture 10회 실행
- 정상 완료율
- 평균 모델 호출 횟수
- 평균 repair 진입 횟수
- 파싱 복구 성공률
- `EXTRACT_FAILED` 발생률
- `CHANGED_FILES_MISMATCH` 발생률

---

## 수정 범위

- `scripts/adapters/adapter-opencode.sh`
- `scripts/lib/verdict-extractor.sh`
- `scripts/lib/health-check.sh`
- `scripts/lib/verify-changed-files.sh` 또는 동등 공통 함수
- `references/failure-modes.md`
- `scripts/tests/`
- 필요 시 실행 메트릭 로그 관련 파일

---

## 유지 조건

- **Kant-Looper 안전 5원칙 절대 준수**
  - 자동 push 금지
  - main 직접 커밋 금지
  - rebase 및 `reset --hard` 금지
  - protected paths 변경 금지
  - 작업 범위 밖 변경 금지

- **다른 4개 어댑터(codex, grok, agy, claude)의 기존 동작 변경 금지**
- **Bash 3.2 호환성 유지**
  - associative array 금지
  - `[[ ]]` 내 `\s` 사용 금지
  - `[[:space:]]` 사용
- **fallback-dispatcher 체인 호환성 유지**
  - `FAIL:${failure_mode}` 출력 형식 유지
  - exit code 201 시맨틱 유지
- **기존 환경 변수 시맨틱 유지**
  - `KANT_OPENCODE_VARIANT`
  - `KANT_OPENCODE_GLM_PROVIDER`
  - `KANT_MINIMAX_OPENCODE_PROVIDER`
- **verdict JSON 7개 필드 유지**
  - `verdict`
  - `summary`
  - `findings`
  - `changed_files`
  - `tests_added_or_updated`
  - `risks`
  - `notes_for_reviewer`
- `<verdict>PASS|CHANGES_REQUESTED|BLOCKED|INVALID_OUTPUT</verdict>` 요구사항 유지
- 원본 응답 로그를 보존하여 사후 분석 가능하도록 유지
- 파싱 복구를 이유로 명시적인 모델 실패를 PASS로 바꾸지 않음

---

## 구현 순서

### Phase 1. 재현 및 계측

- 현재 코드로 fixture를 반복 실행해 기준값 수집
- 모델 호출 수, repair 수, 추출 실패 수 기록
- 실패 응답 원본과 실제 Git diff 보존

### Phase 2. 추출기 통합

- 인라인 Python 파서 제거
- OpenCode NDJSON 정규화 함수 추가
- 공통 verdict 추출 경로 연결
- 7개 필드 스키마 보장

### Phase 3. 실제 diff 교차검증

- 모델 보고와 실제 diff 분리
- 최종 `changed_files` 결정 규칙 구현
- mismatch 오류 세분화

### Phase 4. 모델·variant·권한 검증

- 모델 정규화 함수 추가
- provider/model/variant health check 추가
- 쓰기 권한 검증
- 미지원 variant 자동 생략

### Phase 5. 회귀 및 비용 검증

- GLM/OpenCode 반복 테스트
- 다른 어댑터 회귀 테스트
- 개선 전후 모델 호출 횟수 비교
- git-diff 패치 로직 유지 여부 결정

---

## 검증

### 1. 정적 검사

```bash
bash -n scripts/adapters/adapter-opencode.sh
bash -n scripts/lib/verdict-extractor.sh
bash -n scripts/lib/health-check.sh
```

가능하면 ShellCheck도 실행한다. 단, Bash 3.2 호환성을 우선한다.

### 2. dry-run 라우팅 및 정규화 검증

```bash
scripts/kant-loop.sh run TASK-fixtures/hello.md --dry-run --agent opencode --model glm-4.7
scripts/kant-loop.sh run TASK-fixtures/hello.md --dry-run --agent opencode --model glm-5.2
scripts/kant-loop.sh run TASK-fixtures/hello.md --dry-run --agent opencode --model MiniMax-M3
```

확인 항목:

- `route`
- `normalized_model`
- provider
- variant 전달 또는 생략 여부
- write flags
- 호출 예정 명령

### 3. 추출기 단위 테스트

fixture를 추가한다.

- 정상 NDJSON + 구조화 JSON
- 정상 NDJSON + verdict 태그만 존재
- 여러 text 이벤트로 분할된 verdict
- 손상된 NDJSON 한 줄 포함
- 일반 로그와 JSON 이벤트 혼합
- 모델 보고 `changed_files` 누락
- 모델 보고 파일 환각
- 빈 응답
- 명시적 BLOCKED 응답

각 fixture에서 7개 필드가 항상 존재하는지 확인한다.

### 4. 어댑터 단독 호출

```bash
git worktree add /tmp/test-wt-glm47 -B test/glm-47

scripts/adapters/adapter-opencode.sh call implement   TASK-fixtures/create-file.md /tmp/test-wt-glm47 glm-4.7

cat /tmp/test-wt-glm47/.kant-looper/opencode-implement.json
```

확인 항목:

- `verdict`가 유효한 값인가
- 실제 파일 생성 시 `changed_files`가 비어 있지 않은가
- `summary`가 비어 있지 않은가
- 실제 diff와 JSON의 파일 목록이 일치하는가
- 응답 로그에 치명적 `FAIL:`이 없는가

### 5. quick 모드 반복 테스트

각 지원 모델에 대해 최소 5회 실행한다.

```bash
for i in 1 2 3 4 5; do
  scripts/kant-loop.sh run TASK-fixtures/create-file.md --quick     --agent opencode --model glm-5.2 --no-auto-commit
done
```

성공 기준:

- 5회 모두 `pass_no_commit` 또는 `completed`
- 실제 파일 생성 5회 확인
- `EXTRACT_FAILED` 0건
- `CHANGED_FILES_HALLUCINATED` 0건
- `CHANGED_FILES_MISMATCH` 0건
- 불필요한 repair/fallback 호출 0건
- `QUICK_VERDICT verdict=PASS` 5회 기록

### 6. 파싱 복구 테스트

의도적으로 구조화 verdict를 깨뜨린 fixture를 사용한다.

성공 기준:

- 모델 재호출 없이 원본 응답과 Git 증거로 복구
- `PARSE_RECOVERY_USED=1` 기록
- 최종 스키마 유효
- 명시적 실패 응답은 복구 PASS 처리하지 않음

### 7. 다른 어댑터 회귀 테스트

```bash
scripts/kant-loop.sh run TASK-fixtures/create-file.md --quick   --agent codex --model gpt-5.6-terra --no-auto-commit

scripts/kant-loop.sh run TASK-fixtures/create-file.md --quick   --agent grok --model grok-4.5 --no-auto-commit

scripts/kant-loop.sh run TASK-fixtures/create-file.md --quick   --agent agy --model gemini-3.5-flash --no-auto-commit
```

기존 지원 모델을 사용하며, 모두 수정 전과 동일하게 동작해야 한다.

### 8. 전체 테스트

```bash
bash scripts/tests/run-all.sh
```

### 9. 토큰 효율 대체 지표 비교

동일 fixture 10회 기준으로 개선 전후를 비교한다.

| 지표 | 목표 |
|---|---:|
| 평균 모델 호출 수 | 감소 또는 동일 |
| repair 호출 수 | 0 또는 유의미한 감소 |
| fallback 호출 수 | 0 또는 유의미한 감소 |
| 추출 실패율 | 0% |
| 실제 변경 누락률 | 0% |
| 정상 완료율 | 100% |
| 평균 프롬프트 재전송 횟수 | 0 |

---

## 완료 조건

- [ ] `adapter-opencode.sh`의 인라인 Python 파서 제거
- [ ] OpenCode NDJSON 정규화가 `verdict-extractor.sh` 내부에 구현됨
- [ ] OpenCode도 공통 verdict 추출기 한 줄 호출 사용
- [ ] `<verdict>` 폴백에서 `changed_files: []` 및 빈 문자열 hardcode 제거
- [ ] verdict JSON 7개 필드가 모든 성공 경로에서 존재
- [ ] 최종 `changed_files`가 실제 Git diff를 기준으로 결정됨
- [ ] 모델 보고와 실제 diff 불일치 오류가 세분화됨
- [ ] 파싱 실패 시 모델 재호출 전 로컬 복구 절차 구현
- [ ] provider/model/variant 검증 구현
- [ ] 미지원 variant는 안전하게 생략
- [ ] 쓰기 권한 검증이 `--auto`와 분리되어 있음
- [ ] GLM 4.7 및 5.2에서 quick 모드 5회 연속 성공
- [ ] `EXTRACT_FAILED`, `CHANGED_FILES_HALLUCINATED`, `CHANGED_FILES_MISMATCH` 0건
- [ ] 불필요한 repair/fallback 모델 호출 0건
- [ ] 다른 어댑터 회귀 테스트 통과
- [ ] 전체 테스트 스위트 통과
- [ ] 개선 전후 모델 호출 횟수 또는 대체 비용 지표 비교 결과 기록
- [ ] `references/failure-modes.md` 업데이트
- [ ] git-diff 사후 패치 로직 유지/제거 결정이 PR 설명에 명시됨
- [ ] 변경 사항은 `agent/kant/<run-id>` 작업 브랜치에만 커밋
- [ ] main 브랜치 직접 커밋 및 자동 push 없음

---

## PR 설명에 반드시 포함할 내용

1. 기존 문제의 재현 조건
2. 근본 원인
3. 인라인 파서 제거와 공통화 방식
4. Git diff를 최종 사실값으로 사용한 이유
5. 파싱 실패 시 모델 재호출을 줄이는 복구 절차
6. provider/model/variant/권한 검증 결과
7. 반복 테스트 결과
8. 다른 어댑터 회귀 결과
9. 개선 전후 호출 횟수 또는 비용 대체 지표
10. 기존 git-diff 패치 로직의 유지 또는 제거 결정
