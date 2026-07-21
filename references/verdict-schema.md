# verdict-schema.md

> ⚠️ **낡은 문서**: 이 문서는 폐기된 HPRAR 라운드 상태 모델을 설명합니다. 현재 `kant-loop.sh`는 `implement`/`review`/`repair` 3역할만 사용합니다. 역사적 기록으로 보존합니다.

> 외부 에이전트 응답 스키마. 모든 role 공통 4-value enum + role별 required 필드.

## 공통 스키마

```json
{
  "type": "object",
  "properties": {
    "verdict": {
      "enum": ["PASS", "CHANGES_REQUESTED", "BLOCKED", "INVALID_OUTPUT"]
    },
    "summary": { "type": "string" },
    "findings": {
      "type": "array",
      "items": {
        "type": "object",
        "properties": {
          "severity": { "enum": ["blocker", "major", "minor"] },
          "location": { "type": "string" },
          "message": { "type": "string" }
        },
        "required": ["severity", "location", "message"]
      }
    }
  },
  "required": ["verdict", "summary", "findings"]
}
```

## 4-value enum

| verdict | 의미 | 백엔드 처리 |
|---|---|---|
| `PASS` | 모든 검증 통과 | 다음 phase 또는 commit |
| `CHANGES_REQUESTED` | 구체적 fix 필요 | 다음 라운드 (repair) |
| `BLOCKED` | 외부 요인으로 진행 불가 | 즉시 중단, 사용자에게 보고 |
| `INVALID_OUTPUT` | JSON 파싱 실패 또는 required 누락 | 재시도 1회 → 다른 모델 → claude 폴백 |

## role별 추가 required

### plan (PLAN_AGENT, 기본 glm-5.2)

```json
{
  "verdict": "...",
  "summary": "...",
  "findings": [...],

  "scope": "string (수정 대상 파일/디렉터리)",
  "implementation_steps": ["string"],
  "acceptance_criteria": ["string"],
  "verification_commands": ["string"]
}
```

### repair-plan (Round 2 진입 시)

```json
{
  "verdict": "...",
  "summary": "...",
  "findings": [...],

  "root_cause": "string",
  "repair_steps": ["string"],
  "do_not_touch": ["string"],
  "verification_commands": ["string"],
  "acceptance_criteria": ["string"]
}
```

### implement / repair

```json
{
  "verdict": "...",
  "summary": "...",
  "findings": [...],

  "changed_files": ["string"],
  "tests_added_or_updated": ["string"],
  "risks": ["string"],
  "notes_for_reviewer": "string"
}
```

### review

```json
{
  "verdict": "...",
  "summary": "...",
  "findings": [...],

  "required_fixes": ["string"],
  "evidence": ["string"],
  "requires_repair_round": "boolean",
  "gate_interpretation": "string",
  "commit_ready": "boolean"
}
```

### verify

```json
{
  "verdict": "...",
  "summary": "...",
  "findings": [...],

  "review_findings_resolved": "boolean",
  "gate_interpretation": "string",
  "commit_ready": "boolean",
  "requires_repair_round": "boolean"
}
```

## verdict-extractor 파이프라인

`scripts/lib/verdict-extractor.sh` 동작 순서:

```text
[1] response_file에서 raw stdout 읽기

[2] extract_json_object:
    - ```json ... ``` 코드블록 안의 JSON 추출
    - 또는 { ... } 중괄호 카운팅으로 첫 번째 valid JSON object 추출
    - trailing text 무시

[3] jq로 verdict 필드 파싱

[4] validate_verdict_json:
    - verdict ∈ {PASS, CHANGES_REQUESTED, BLOCKED, INVALID_OUTPUT} 확인
    - role별 required 필드 확인
    - 누락 시 INVALID_OUTPUT 처리

[5] state dir에 role별 .json 저장
```

## commit_ready 플래그

`commit_ready=true`는 마지막 verify/review 단계에서 commit 가능을 명시.

이중 안전망:
- review/verify verdict=PASS 이어도 commit_ready=false 면 commit 안 함
- commit_ready=true 여도 verdict=PASS 아니면 commit 안 함

둘 다 만족해야 commit.

## INVALID_OUTPUT 발생 시 대응

```text
원인 후보:
- 모델이 코드블록 안에 JSON 넣음
- 모델이 JSON 바깥에 설명 텍스트 추가
- 모델이 required 필드 일부 누락
- 모델이 출력 도중 잘림 (timeout 직전)

대응:
[1] extract_json_object 재시도 (1회)
[2] 같은 모델 다른 prompt로 재시도 (1회)
[3] fallback_dispatch: 다른 모델로 전환
[4] 최종 폴백: claude (subagent)

이 과정이 모두 실패하면 BLOCKED.
```

## 예시 — 정상 응답

```
{에이전트이름}, 안녕하세요. reverse 함수 추가 부탁드려요.

## 작업
TASK.md 본문...

## 보고 형식 (반드시 지킬 것)
너의 응답은 아래 JSON 객체 하나만 출력한다.

```json
{
  "verdict": "PASS",
  "summary": "reverse 함수를 src/utils/string.ts에 추가하고 3개 테스트 통과",
  "findings": [],
  "changed_files": ["src/utils/string.ts", "src/utils/string.test.ts"],
  "tests_added_or_updated": ["src/utils/string.test.ts"],
  "risks": [],
  "notes_for_reviewer": "rim case (empty string) 처리"
}
```

마지막 줄에 <verdict>PASS</verdict> 태그도 함께 출력한다.
```

## 예시 — JSON 파싱 fallback

도구가 다음을 반환했다고 가정:

```
작업을 완료했습니다. 다음은 결과입니다:

The changes are complete. Here's the JSON:
{
  "verdict": "PASS",
  "summary": "..."
}

이상입니다.
```

`extract_json_object`는 중괄호 카운팅으로 첫 번째 valid JSON object를 추출. 모델의 사족 텍스트는 무시.
