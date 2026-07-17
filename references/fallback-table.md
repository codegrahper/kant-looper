# fallback-table.md

> 각 도구/모델의 fallback 체인. routing 가이드 8·10·11절을 그대로 코드에 옮긴 매핑.

이 표는 **skill 폴더 내부 SSOT**입니다. 절대 외부 경로 참조 안 함. 갱신은 `/kant-looper update-guide` 또는 이 파일 직접 편집.

## 코드 매핑 (script에서 사용)

```yaml
fallback_chains:
  codex:
    primary: openai/gpt-5.6-sol
    fallback_1: openai/gpt-5.6-terra   # 더 가벼움
    fallback_2: zai/glm-5.2            # 다른 공급자
    fallback_3: xai/grok-4.5           # 다른 공급자
    final: claude:default               # claude 구독 로그인, --model 미지정
    on_429: wait 30s + other_provider
    on_401: immediate other_provider
    on_timeout: lighter_same_provider

  grok:
    primary: xai/grok-4.5
    fallback_1: openai/gpt-5.6-terra   # 다른 공급자
    fallback_2: zai/glm-5.2
    final: claude:default

  opencode:
    primary: zai/glm-5.2
    fallback_1: zai/glm-4.7            # 같은 공급자, 더 가벼움
    fallback_2: openai/gpt-5.6-terra
    final: claude:default

  agy:
    primary: google/gemini-3.5-flash
    fallback_1: google/gemini-3.1-pro-preview  # 같은 공급자, 더 강함
    fallback_2: zai/glm-5.2
    final: claude:default

  claude:
    primary: claude:default (구독 로그인)
    fallback: null  # 마지막 폴백
```

## 실패 모드별 1차 / 최종 대응

| 실패 모드 | 1차 | 최종 |
|---|---|---|
| timeout | 더 가벼운 같은 공급자 모델 | claude |
| 401 (auth) | 즉시 다른 공급자 | claude |
| 403 (forbidden) | 즉시 다른 공급자 | claude |
| 429 (rate limit) | wait 30s + 다른 공급자 | claude |
| 500/502/503 | retry 1회 (backoff 10s) | 다른 공급자 → claude |
| 504 (gateway timeout) | retry 1회 | 다른 공급자 → claude |
| connection refused | retry 1회 | 다른 공급자 → claude |
| DNS 실패 | retry 1회 | 다른 공급자 → claude |
| 형식 오류 (INVALID_OUTPUT) | 같은 모델 retry 1회 | 다른 모델 → claude |
| 도구 자체 에러 | 다른 모델 | claude |

## 호출 모드별 기본 라우트

routing 가이드 8.3의 routes 섹션을 그대로:

```yaml
routes:
  tiny:
    primary: openai/gpt-5.6-luna
    fallbacks:
      - google/gemini-3.1-flash-lite
      - zai/glm-4.7-flash
      - minimax/MiniMax-M2.7-highspeed

  standard_repo:
    primary: openai/gpt-5.6-terra
    fallbacks:
      - minimax/MiniMax-M2.7
      - google/gemini-3.5-flash
      - zai/glm-4.7

  hard_repo:
    primary: openai/gpt-5.6-sol
    fallbacks:
      - zai/glm-5.2
      - xai/grok-4.5
      - minimax/MiniMax-M3

  huge_context:
    primary: zai/glm-5.2
    fallbacks:
      - minimax/MiniMax-M3
      - google/gemini-3.5-flash

  visual_browser:
    primary: google/gemini-3.5-flash
    harness: antigravity
    fallbacks:
      - minimax/MiniMax-M3
      - zai/glm-5v-turbo
      - openai/gpt-5.6-sol

  independent_review:
    rule: provider_must_differ_from_implementer
```

## 호출 도구별 매핑 (script에서 사용)

```yaml
tool_to_default_model:
  codex: openai/gpt-5.6-terra        # T1/T2 기본
  codex_review: openai/gpt-5.6-sol   # 검증 단계
  grok: xai/grok-4.5
  opencode: zai/glm-5.2
  opencode_quick: zai/glm-4.7        # T1 작업 시
  agy: google/gemini-3.5-flash       # Antigravity default
  claude: default                    # claude 구독 로그인, --model 미지정
```

## TASK 키워드 → 라우트 매핑 (참고용 휴리스틱)

클로드가 작업을 판단할 때 참고하는 휴리스틱 — 이 표를 파싱하는 코드는 없다
(판단은 클로드가 그 자리에서 한다):

```yaml
keyword_to_route:
  ui:
    keywords: ["UI", "component", "screen", "stitch", "modal", "drawer", "tailwind"]
    route: visual_browser
    tool: agy

  test:
    keywords: ["test", "unit test", "fixture", "mock", "snapshot"]
    route: tiny
    tool: codex
    model: gpt-5.6-luna

  refactor:
    keywords: ["refactor", "migrate", "rewrite", "restructure", "cleanup"]
    route: hard_repo
    tool: opencode
    model: glm-5.2

  terminal:
    keywords: ["terminal", "cli", "shell", "bash", "zsh", "rust", "C++", "system"]
    route: standard_repo
    tool: grok

  review:
    keywords: ["review", "verify", "audit", "check", "validate"]
    route: independent_review
    tool: codex
    model: gpt-5.6-sol

  long_context:
    keywords: ["1M", "huge", "large repo", "entire codebase"]
    route: huge_context
    tool: opencode
    model: glm-5.2

  default:
    route: standard_repo
    tool: codex
    model: gpt-5.6-terra
```

## 무진전 중단 임계값

```yaml
no_progress_limits:
  same_diff_count: 3
  same_test_failure_count: 2
  tool_calls_without_progress: 10
  max_elapsed_seconds: 1800  # 30분
  max_tokens: 500000
  max_cost_usd: 5.0
  context_compression_loss: true  # 압축 후 핵심 제약 누락 감지
```

`NO_PROGRESS_LIMIT` (env, default 3): 위 임계값들의 종합 점.

## 가이드 갱신 절차

1. `/Users/drumqube/Downloads/multimodel-coding-agent-routing-guide.md`를 이바가 직접 편집 (또는 외부 출처에서 새로 받음)
2. `/kant-looper update-guide` 호출
3. claude가 diff 표시 → 이바 승인
4. 클로드가 `references/multimodel-coding-agent-routing-guide.md`에 복사
5. claude가 `references/fallback-table.md`도 새 가이드에 맞춰 업데이트 제안 (이바가 한 번 더 승인)
6. 다음 작업부터 새 매핑 자동 적용

코드 자체는 가이드 파일을 동적 파싱하므로 직접 수정 불필요. 단 fallback-table.md 자체는 직접 편집 가능 (가이드 외에 운영 노하우 포함).

## 환경별 기본값 오버라이드

다음은 환경에 따라 다를 수 있어, 운영 중 변경 가능:

```yaml
# 운영 중 자주 조정하는 값
OPERATION_TIMEOUT_SECONDS:
  plan: 600
  implement: 1800
  review: 900
  verify: 900
  repair: 1800

RETRY_POLICY:
  on_timeout:
    max_retries: 1
    backoff_seconds: 5
  on_rate_limit:
    max_retries: 1
    backoff_seconds: 30
  on_format_error:
    max_retries: 1
    backoff_seconds: 0
  on_network_error:
    max_retries: 2
    backoff_seconds: 10
```
