# 멀티모델 코딩 에이전트·도구 호출 라우팅 가이드

- 기준일: 2026-07-12
- 대상: Claude Code, Codex CLI, Grok Build, Google Antigravity, MCP 서버, 백그라운드 서브에이전트
- 조사 범위: Z.AI GLM, OpenAI Codex/GPT, xAI Grok, Google Antigravity/Gemini, MiniMax M
- 출처 원칙: 공급사 공식 문서·공식 릴리스·공식 GitHub 우선
- 중요: 벤치마크는 실행 하네스, 시간 제한, 추론량, 재시도 정책이 서로 달라 절대적인 단일 순위로 해석하면 안 된다.

---

## 1. 먼저 바로잡아야 할 명칭

| 표현 | 공식적으로 확인된 의미 |
|---|---|
| GLM 5.2 | Z.AI 모델 ID `glm-5.2` |
| Codex 5.6 | 단일 모델이 아니라 `gpt-5.6-sol`, `gpt-5.6-terra`, `gpt-5.6-luna` 모델군 |
| Grok | 현재 코딩 중심 대표 모델은 `grok-4.5`; 코딩 에이전트 제품은 Grok Build |
| AGY | 모델명이 아니라 Google Antigravity 에이전트 개발 플랫폼/하네스 |
| MiniMax 3 | 공식 모델 ID `MiniMax-M3` |
| MiniMax 2.7 | `MiniMax-M2.7`, 고속형은 `MiniMax-M2.7-highspeed` |

---

## 2. 한눈에 보는 기본 추천

| 작업 | 우선 모델/환경 | 이유 |
|---|---|---|
| 모호하고 어려운 대규모 리팩터링 | GPT-5.6 Sol High/Max | 복합 코딩, 도구 사용, 컴퓨터 사용, 장기 작업에 가장 강한 OpenAI 계층 |
| 일상적인 기능 구현·버그 수정 | GPT-5.6 Terra | Sol보다 저렴하면서 강한 일상형 |
| 명확한 대량 반복 작업 | GPT-5.6 Luna | 빠르고 저렴하며 완료 기준이 명확한 작업에 적합 |
| 1M 토큰 대형 저장소·장기 세션 | GLM-5.2 또는 MiniMax-M3 | 공식적으로 1M 컨텍스트와 장기 에이전트 작업을 강조 |
| 빠른 터미널·시스템 코딩 | Grok 4.5 | 터미널, Rust/C/C++, 풀스택, 빠른 도구 루프 강점 |
| 화면·브라우저·이미지·영상 기반 개발 | Antigravity + Gemini 3.5 Flash | 멀티모달과 에이전트 실행 환경의 결합 |
| 복잡한 멀티모달 설계·분석 | Gemini 3.1 Pro Preview | 고난도 reasoning과 agentic/vibe coding |
| 저비용 병렬 서브에이전트 | Gemini 3.1 Flash-Lite / GLM-4.7-Flash / MiniMax-M2.7-highspeed | 고처리량·저지연 작업 |
| OpenClaw 장기 작업 | GLM-5-Turbo | Z.AI가 OpenClaw 시나리오 최적화를 명시 |
| 독립 코드 리뷰 | 구현 모델과 다른 공급자의 상위 모델 | 동일 모델의 오류 상관관계 감소 |

---

# 3. Z.AI GLM 계열

## 3.1 현행·주요 모델

| 모델 | 상태 | 핵심 강점 | 적합한 작업 |
|---|---|---|---|
| `glm-5.2` | 최신 주력 | 1M 컨텍스트, 장기 프로젝트 맥락 유지, 복잡한 시스템 엔지니어링, 깊은 디버깅 | 대형 저장소, 장시간 리팩터링, 복잡한 장애 수정 |
| `glm-5.1` | 이전 주력 | 장기 자율 작업, 계획→실행→반복 개선 | 5.2 회귀 비교, 기존 안정 환경 |
| `glm-5` | 이전 기반형 | 에이전트 엔지니어링, 백엔드 리팩터링, 장기 계획 | 기존 통합 유지 |
| `glm-5-turbo` | 특화형 | OpenClaw, 지속 실행, 긴 도구 체인 | 예약 작업, 운영 자동화, 백그라운드 에이전트 |
| `glm-4.7` | 실용형 | 200K 컨텍스트, 코딩, 다단계 도구 실행, 프런트엔드 완성도 | 일상 개발, 비용·품질 균형 |
| `glm-4.7-flashx` | 고속형 | 빠른 생성과 낮은 지연 | 병렬 서브태스크, 테스트 생성 |
| `glm-4.7-flash` | 경량형 | 저비용 반복 작업 | 보일러플레이트, 작은 수정, 분류 |
| `glm-4.6` | 레거시 | 200K, 코딩·검색·도구 사용 | 기존 워크플로 유지 |
| `glm-4.5` | 레거시 | 에이전트 지향 기반 모델 | 호환성 목적 |
| `glm-4.5-air` | 레거시 경량형 | 비용 대비 효율 | 오래된 대량 작업 설정 |
| `glm-5v-turbo` | 비전 코딩 | 이미지·영상 이해 후 계획·코딩·실행 | UI 스크린샷 구현, 시각 버그 분석 |

## 3.2 공식 공개 성능 예

Z.AI 공식 자료 기준:

- GLM-5.2: SWE-Bench Pro 62.1
- GLM-5.2: Terminal-Bench 2.1 81.0
- GLM-4.7: SWE-Bench Verified 73.8
- GLM-4.7: Terminal-Bench 2.0 41.0
- GLM-4.7: LiveCodeBench V6 84.9

주의: 위 점수는 벤치마크 버전과 하네스가 다르므로 다른 공급자의 수치와 단순 합산하지 않는다.

## 3.3 GLM 라우팅 규칙

```text
1M 컨텍스트·대형 저장소·장기 작업  -> glm-5.2
OpenClaw·예약·긴 도구 체인          -> glm-5-turbo
일상적인 코딩                       -> glm-4.7
짧고 명확한 병렬 작업               -> glm-4.7-flashx / flash
화면·이미지·영상 기반 구현          -> glm-5v-turbo
이전 버전은 회귀·호환 목적           -> glm-5.1 / 5 / 4.6 / 4.5
```

## 3.4 도구 호출 팁

- `glm-5.2[1m]` 형태와 Claude Code 자동 압축 창 설정은 Z.AI 문서대로 사용한다.
- 복잡한 코딩은 높은 effort, 단순 작업은 낮은 effort로 분리한다.
- 1M 컨텍스트라도 저장소 전체를 무조건 넣지 말고 심볼 인덱스→후보 파일→세부 파일 순으로 확장한다.
- 장기 실행에서는 목표, 허용 경로, 테스트, 최대 도구 호출 수를 매 요청에 유지한다.

---

# 4. OpenAI Codex / GPT 계열

## 4.1 GPT-5.6 모델군

| 모델 | 위치 | 핵심 강점 | 적합한 작업 |
|---|---|---|---|
| `gpt-5.6-sol` | 최상위 | 복잡한 코딩, 컴퓨터 사용, 연구, 사이버보안, 긴 작업 | 핵심 아키텍처, 어려운 디버깅, 고위험 변경 |
| `gpt-5.6-terra` | 균형형 | GPT-5.5급에 가까운 일상 성능과 낮은 비용 | 일반 기능 구현, 저장소 유지보수 |
| `gpt-5.6-luna` | 효율형 | 빠르고 저렴한 반복 작업 | 추출, 변환, 테스트 생성, 정형 수정 |
| `gpt-5.5` | 이전 주력 | 복합 코딩·컴퓨터 사용·지식 작업 | 회귀 기준 |
| `gpt-5.4` | 이전 전문형 | 코딩·reasoning·도구 사용 | 기존 설정 유지 |
| `gpt-5.4-mini` | 소형 | 빠른 코딩과 서브에이전트 | 검색, 작은 패치, 병렬 리뷰 |
| `gpt-5.3-codex-spark` | 연구 Preview | 거의 실시간인 텍스트 코딩 반복 | 페어 프로그래밍, 즉시 수정 |
| `gpt-5.2`, `gpt-5.3-codex` | Codex ChatGPT 로그인 경로 Deprecated | 레거시 | 새 설정에서 제거 권장 |

## 4.2 GPT-5.6 공개 코딩 수치

OpenAI 공식 발표 기준:

| 평가 | Sol | Terra | Luna |
|---|---:|---:|---:|
| SWE-Bench Pro | 64.6% | 63.4% | 62.7% |
| DeepSWE v1.1 | 72.7% | 69.6% | 67.2% |
| Terminal-Bench 2.1 | 88.8% | 87.4% | 84.7% |
| Artificial Analysis Coding Agent Index | 80.0 | 77.4 | 74.6 |

Sol Ultra의 Terminal-Bench 2.1 공개 수치는 91.9%다. Ultra는 다중 서브에이전트 모드이므로 단일 모델 실행과 구분해야 한다.

## 4.3 Codex 선택 규칙

```text
모호하고 고난도·고가치 작업       -> gpt-5.6-sol
일상 저장소 작업                  -> gpt-5.6-terra
정형·고처리량 작업                -> gpt-5.6-luna
작은 병렬 서브태스크              -> gpt-5.4-mini
실시간 페어 코딩                  -> gpt-5.3-codex-spark
```

## 4.4 Reasoning 선택

- Low: 파일 검색, 단순 변환, 명확한 작은 패치
- Medium: 일반 기능 구현의 기본
- High/Extra High: 여러 단계와 트레이드오프가 있는 작업
- Max: 하나의 매우 어려운 문제를 깊게 처리
- Ultra: 의미 있게 분할 가능한 복합 작업을 여러 서브에이전트로 병렬 처리

Ultra는 같은 파일을 여러 에이전트가 동시에 수정하는 작업에는 부적합하다.

## 4.5 CLI 예

```bash
codex -m gpt-5.6-sol
codex exec -m gpt-5.6-terra "현재 변경을 검토하고 테스트를 실행하라"
codex exec -m gpt-5.6-luna "변경 함수의 단위 테스트만 추가하라"
```

---

# 5. xAI Grok 계열

## 5.1 주요 모델·제품

| 모델/제품 | 상태 | 핵심 강점 | 적합한 작업 |
|---|---|---|---|
| `grok-4.5` | 최신 주력 | 코딩, agentic task, 지식 작업, 빠른 토큰 생성, 함수 호출·코드 실행 | 터미널 코딩, 시스템 코드, 풀스택 |
| `grok-build-0.1` | 코딩 에이전트 모델 | 256K, 함수 호출, 구조화 출력, reasoning | 저비용 코딩 자동화 |
| Grok Build | 에이전트 CLI/제품 | TUI, headless 실행, ACP 연동 | CLI 작업, 봇·스크립트 통합 |
| `grok-4.3` | 이전 범용형 | configurable reasoning, 함수 호출, 구조화 출력 | 기존 API 통합 |
| Grok 4 Fast | 이전 효율형 | 2M 컨텍스트, reasoning/non-reasoning, 강한 검색·도구 사용 | 긴 입력, 비용 민감 검색·도구 작업 |
| Grok Code Fast 1 | 이전 코딩형 | 빠른 agentic coding | 레거시 |

## 5.2 Grok 4.5 공식 공개 수치

xAI 공식 발표 기준:

- SWE-Bench Pro 64.7%
- Terminal-Bench 2.1 83.3%
- DeepSWE 1.0 62.0%
- SWE Marathon 29.0%
- 서비스 속도 약 80 TPS라고 발표

## 5.3 Grok 선택 규칙

```text
품질과 속도를 모두 원하는 터미널 코딩 -> grok-4.5
가격 민감 코딩 에이전트              -> grok-build-0.1
기존 통합과 configurable reasoning    -> grok-4.3
매우 긴 입력·검색·비용 효율           -> Grok 4 Fast 계열
```

## 5.4 도구 호출 팁

- 파일 수정, 셸 실행, 웹 검색을 별도 도구로 분리한다.
- 빠른 모델은 실패 루프도 빨라지므로 최대 호출 수와 무진전 감지를 둔다.
- 복잡한 작업만 reasoning을 high로 올린다.
- 코드 실행 도구는 허용된 디렉터리·명령·타임아웃을 강제한다.

---

# 6. Google Antigravity(AGY)와 Gemini

## 6.1 AGY의 정체

Google Antigravity는 모델이 아니라 에이전트 개발 플랫폼이다. 공식 소개상 여러 에이전트를 독립 프로젝트에서 병렬로 오케스트레이션하고, IDE·독립 앱·에이전트 실행 흐름을 제공한다.

라우터에는 다음을 분리해서 저장한다.

```yaml
provider: google
harness: antigravity
model: gemini-3.5-flash
```

## 6.2 코딩에 관련된 Gemini 모델

| 모델 | 상태 | 강점 | 적합한 작업 |
|---|---|---|---|
| `gemini-3.5-flash` | Stable | 장기 agentic/coding 성능, 속도, 멀티모달 | AGY 기본 코딩, 브라우저/UI, 병렬 작업 |
| `gemini-3.1-pro-preview` | Preview | 복잡한 문제 해결, 강한 agentic·vibe coding | 어려운 설계, 복잡한 멀티모달 저장소 |
| `gemini-3.1-flash-lite` | Stable | 비용·속도·대량 처리 | 추출, 요약, 파일 분류, 작은 코드 보조 |
| `gemini-3-flash-preview` | Preview | 빠른 프런티어급 모델 | 회귀 비교·Preview 실험 |
| `gemini-2.5-pro` | 이전 고성능 | 깊은 reasoning과 코딩 | 기존 통합 |
| `gemini-2.5-flash` | 이전 균형형 | 저지연·고처리량 reasoning | 레거시 워크로드 |
| `gemini-2.5-flash-lite` | 이전 경량형 | 저비용 | 대량 단순 작업 |

Gemini 3.1 Flash-Lite Preview와 Gemini 3 Pro Preview의 구형 Preview 엔드포인트는 종료됐으므로 Stable 또는 최신 Preview ID를 사용한다.

## 6.3 AGY/Gemini 선택 규칙

```text
AGY 기본 코딩·멀티모달·빠른 반복 -> gemini-3.5-flash
복잡한 설계·정밀한 reasoning      -> gemini-3.1-pro-preview
대량 저비용 서브태스크            -> gemini-3.1-flash-lite
기존 회귀                         -> gemini-2.5 계열
```

## 6.4 주의점

- Preview 모델은 생산 환경에서 고정 버전·회귀 테스트가 필요하다.
- `latest` 별칭은 내부 모델이 교체될 수 있으므로 프로덕션은 특정 Stable ID를 우선한다.
- Computer Use는 화면 변화에 취약하므로 DOM·접근성 트리·확인 단계를 우선한다.
- AGY 하네스와 실제 Gemini 모델의 장애·비용·버전을 별도 기록한다.

---

# 7. MiniMax M 계열

## 7.1 현행 모델

| 모델 | 상태 | 컨텍스트 | 핵심 강점 |
|---|---|---:|---|
| `MiniMax-M3` | 최신 | 1,000,000 | 멀티모달 코딩, 장기 에이전트, 도구 사용, 이미지·영상·컴퓨터 조작 |
| `MiniMax-M2.7` | 현행 | 204,800 | 실제 소프트웨어 엔지니어링, 로그 분석, 보안, ML, 약 60 TPS |
| `MiniMax-M2.7-highspeed` | 현행 고속형 | 204,800 | M2.7 성능 지향, 약 100 TPS |
| `MiniMax-M2.5` | Legacy | 204,800 | 코드 생성·리팩터링, 복잡한 업무 |
| `MiniMax-M2.5-highspeed` | Legacy 고속형 | 204,800 | M2.5 저지연형 |
| `MiniMax-M2.1` | Legacy | 204,800 | 다국어 코딩, 정밀 리팩터링 |
| `MiniMax-M2.1-highspeed` | Legacy 고속형 | 204,800 | 다국어 대량 작업 |
| `MiniMax-M2` | Legacy | 약 200K | 함수 호출, agentic reasoning, 스트리밍 |

## 7.2 M3 공식 공개 수치

MiniMax 공식 발표 기준:

- SWE-Bench Pro 59.0%
- Terminal-Bench 2.1 66.0%
- SWE-fficiency 34.8%
- KernelBench Hard 28.8%
- MCP Atlas 74.2%

MiniMax는 일부 평가를 Claude Code 또는 별도 하네스로 실행했다고 명시하므로 다른 공급사 점수와 직접 비교할 때 주의한다.

## 7.3 MiniMax 선택 규칙

```text
1M·멀티모달·장기 자율 작업       -> MiniMax-M3
일반 강한 코딩·비용 균형         -> MiniMax-M2.7
낮은 지연시간                    -> MiniMax-M2.7-highspeed
검증된 기존 배포                 -> M2.5 계열
다국어 레거시 프로젝트           -> M2.1 계열
```

---

# 8. 실전 모델 라우팅 정책

## 8.1 작업 난도

| 등급 | 설명 | 모델 예 |
|---|---|---|
| T0 | 읽기·요약·정형 변환 | Luna, Flash-Lite, GLM Flash, M2.7-highspeed |
| T1 | 한두 파일·완료 조건 명확 | Terra, Gemini 3.5 Flash, M2.7, GLM-4.7 |
| T2 | 여러 파일·일반 설계 판단 | Terra Medium, GLM-5.2, Grok 4.5 |
| T3 | 저장소 전체 영향·모호성 큼 | Sol High/Max, GLM-5.2, Grok 4.5, M3, Gemini Pro |
| T4 | 장기·다중 시스템·고위험 | 계획자+구현자+독립 리뷰+사람 승인 |

## 8.2 모델 레지스트리 예

```yaml
models:
  openai/gpt-5.6-sol:
    tags: [frontier_coding, terminal, computer_use, security, long_horizon]
    tier: premium

  openai/gpt-5.6-terra:
    tags: [general_coding, tool_use]
    tier: standard

  openai/gpt-5.6-luna:
    tags: [fast, batch, structured]
    tier: economy

  zai/glm-5.2:
    tags: [one_million_context, coding, long_horizon, tool_use]

  xai/grok-4.5:
    tags: [coding, terminal, systems, fast, tool_use]

  google/gemini-3.5-flash:
    harness: antigravity
    tags: [coding, multimodal, agentic, fast]

  minimax/MiniMax-M3:
    tags: [one_million_context, multimodal, coding, long_horizon]
```

## 8.3 기본 경로 예

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

---

# 9. MCP·CLI 도구 호출 계약

## 9.1 권장 요청 스키마

```json
{
  "task_id": "uuid",
  "provider": "openai",
  "model": "gpt-5.6-terra",
  "harness": "codex-cli",
  "objective": "결제 콜백 중복 처리 버그를 수정한다.",
  "cwd": "/workspace/project",
  "constraints": {
    "mode": "patch",
    "allowed_paths": ["src/payment/**", "tests/payment/**"],
    "forbidden_paths": [".env", "secrets/**", "infra/prod/**"],
    "network": "deny",
    "max_changed_files": 6,
    "max_tool_calls": 30,
    "timeout_sec": 1800,
    "destructive_commands": "deny"
  },
  "acceptance_tests": [
    "npm test -- callback.test.ts",
    "npm run typecheck",
    "동일 이벤트가 두 번 와도 결제가 한 번만 반영될 것"
  ],
  "reasoning": "medium",
  "return_fields": [
    "status",
    "summary",
    "changed_files",
    "diff",
    "tests_run",
    "test_results",
    "remaining_risks"
  ]
}
```

## 9.2 MCP 도구 분리

권장:

```text
inspect_repository
plan_code_change
apply_patch
run_allowed_command
delegate_code_task
review_patch
collect_artifacts
get_task_status
cancel_task
```

피해야 할 형태:

```text
run_anything(command: string)
```

범용 셸 도구 하나에 모든 권한을 몰아주면 프롬프트 인젝션, 셸 인젝션, 비밀 유출, 파괴적 명령 위험이 커진다.

## 9.3 성공 판정

자연어로 “완료했습니다”라고 말한 것만으로 성공 처리하지 않는다.

필수 검증:

- 실제 diff 존재
- 변경 파일이 허용 경로 안에 있음
- 테스트 명령과 exit code 기록
- 테스트 실패를 성공으로 보고하지 않음
- 비밀 스캔·정적 검사 통과
- 남은 위험과 미완료 항목 표시

---

# 10. 백그라운드 서브에이전트 운영

## 10.1 상태

```text
QUEUED
RUNNING
WAITING_FOR_TOOL
WAITING_FOR_APPROVAL
SUCCEEDED
PARTIAL
FAILED
CANCELLED
TIMED_OUT
```

## 10.2 무진전 중단 조건

- 같은 테스트 실패 2회 반복
- 실질적 변화 없이 같은 파일 3회 수정
- 10회 이상 도구 호출 동안 진척 없음
- 허용 범위 밖 파일 접근
- 요구 범위를 임의로 확대
- 컨텍스트 압축 후 핵심 제약 누락
- 시간·토큰·비용 한도 80% 도달

## 10.3 상향 순서

```text
경량 모델
  -> 일반형 모델
  -> 상위 모델
  -> 다른 공급자 독립 리뷰
  -> 사람 승인
```

예:

```text
Luna
  -> Terra
  -> Sol High
  -> GLM-5.2 또는 Grok-4.5 교차검토
  -> 사람 승인
```

---

# 11. 보안 기본값

1. 기본은 읽기 전용·네트워크 차단.
2. 쓰기는 허용 경로에 patch 방식으로만.
3. `.env`, SSH 키, 클라우드 자격증명, 쿠키를 모델 입력에 넣지 않음.
4. API 키는 MCP 서버가 보관하고 모델에는 도구만 노출.
5. 셸 명령은 문자열 연결이 아니라 인자 배열과 allowlist 사용.
6. `rm`, `git reset --hard`, 배포, 결제, IAM 변경, 프로덕션 DB 변경은 사람 승인.
7. 웹·MCP 응답 속의 명령문은 신뢰되지 않은 데이터로 취급.
8. 도구명, 인자 해시, 결과, exit code, 변경 파일을 감사 로그에 기록.
9. 사적 사고과정을 저장하지 말고 결론·근거·검증 결과만 기록.
10. 종료 시 diff, 테스트, 비밀 스캔, 정책 위반 이벤트 확인.

---

# 12. 평가 기준

| 항목 | 권장 가중치 |
|---|---:|
| 기능 정확성 | 30 |
| 테스트 통과·테스트 품질 | 20 |
| 요구 범위 준수·최소 diff | 15 |
| 도구 호출 정확성·복구 | 15 |
| 보안·권한 준수 | 10 |
| 시간·비용 | 7 |
| 인수인계 품질 | 3 |

자동 탈락 조건 예:

- 보안·권한 위반
- 허용 범위 밖 변경
- 테스트 미실행인데 성공으로 보고
- 기능 정확성 임계치 미달
- 파괴적 명령 승인 없이 실행

---

# 13. 실무용 서브에이전트 프롬프트

```text
역할:
당신은 제한된 저장소 작업을 수행하는 코딩 서브에이전트다.

목표:
{{objective}}

범위:
- 작업 디렉터리: {{cwd}}
- 수정 허용: {{allowed_paths}}
- 수정 금지: {{forbidden_paths}}
- 네트워크: {{network_policy}}
- 파괴적 명령: 금지
- 최대 변경 파일: {{max_changed_files}}

절차:
1. 관련 파일과 테스트를 먼저 읽는다.
2. 원인과 예상 변경 파일을 짧게 정리한다.
3. 허용 범위 안에서 최소 diff로 수정한다.
4. 지정 테스트를 실행한다.
5. 동일 실패를 반복하지 않는다.
6. 성공 여부는 exit code와 테스트 결과로 판단한다.

완료 조건:
{{acceptance_tests}}

반환:
- 상태
- 원인
- 변경 파일
- diff 요약
- 테스트 명령과 exit code
- 남은 위험
- 사람 승인이 필요한 항목
```

---

# 14. 공식 출처

## Z.AI

- GLM-5.2: https://docs.z.ai/guides/llm/glm-5.2
- 모델 전환·1M 설정: https://docs.z.ai/devpack/latest-model
- GLM-4.7: https://docs.z.ai/guides/llm/glm-4.7
- GLM-5-Turbo: https://docs.z.ai/guides/llm/glm-5-turbo
- 릴리스 노트: https://docs.z.ai/release-notes/new-released
- MCP: https://docs.z.ai/devpack/mcp

## OpenAI

- Codex 모델: https://learn.chatgpt.com/docs/models
- GPT-5.6 발표·평가: https://openai.com/index/gpt-5-6/
- Codex CLI GitHub: https://github.com/openai/codex
- Codex MCP: https://developers.openai.com/codex/mcp

## xAI

- Grok 4.5: https://docs.x.ai/developers/grok-4-5
- Grok 4.5 발표: https://x.ai/news/grok-4-5
- Grok Build: https://docs.x.ai/build/overview
- Grok Build 0.1: https://docs.x.ai/developers/models/grok-build-0.1
- 함수 호출: https://docs.x.ai/developers/tools/function-calling

## Google

- Antigravity: https://antigravity.google/
- Antigravity 문서: https://antigravity.google/docs
- Gemini 모델: https://ai.google.dev/gemini-api/docs/models
- Gemini 릴리스: https://ai.google.dev/gemini-api/docs/changelog
- Gemini 종료 일정: https://ai.google.dev/gemini-api/docs/deprecations
- Gemini 3 개발자 가이드: https://ai.google.dev/gemini-api/docs/gemini-3

## MiniMax

- 모델 목록: https://platform.minimax.io/docs/guides/models-intro
- 모델 호출·컨텍스트: https://platform.minimax.io/docs/guides/text-generation
- M3 발표: https://www.minimax.io/blog/minimax-m3
- M2.7: https://www.minimax.io/models/text/m27
- Claude Code 연동: https://platform.minimax.io/docs/token-plan/claude-code
- 기타 코딩 도구: https://platform.minimax.io/docs/token-plan/other-tools

## MCP

- 공식 문서: https://modelcontextprotocol.io/docs/getting-started/intro
- 명세: https://modelcontextprotocol.io/specification/2025-11-25
- GitHub: https://github.com/modelcontextprotocol

---

# 15. 유지보수

다음이 발생하면 문서를 갱신한다.

- 새 주력 코딩 모델 출시
- 모델 ID·별칭 변경
- Stable/Preview/Deprecated 상태 변경
- 컨텍스트·도구 호출·가격 변경
- CLI 기본 모델 변경
- 사내 회귀 평가에서 순위가 의미 있게 변경

권장 점검:

```text
모델 목록·Deprecated 상태: 매주
가격·쿼터: 매주 또는 배포 전
공식 벤치마크: 새 모델 출시 시
사내 저장소 회귀 평가: 월 1회
MCP·보안 정책: 분기 1회
```

---

## 16. 메타 에이전트 워크플로우

이 라우팅 가이드는 **자동 라우팅 엔진이 아니라 메타 에이전트의 참조 문서**다.

### 16.1 핵심 원칙

- **자동 감지/고정 매핑 금지.** 키워드 보고 도구를 선택하지 않는다.
- **사용자의 의도를 메타 에이전트가 파악**한다. 사용자는 코드 구현 난이도를 모르는 경우가 많다.
- **메타 에이전트(클로드)는 모델 강점·추론 능력·속도를 학습**하고 있어야 한다.
- 가이드 md는 메타 에이전트가 매 작업마다 참조하는 SSOT이다.

### 16.2 단계별 흐름

1. **사용자가 작업을 자연어로 제시** (한국어/영어 무관)
2. **메타 에이전트가 작업을 다음으로 분해**:
   - 작업 본질 (구현 / 리뷰 / 리팩터 / 디버그 / 분석 / 디자인 / 문서)
   - 난이도 등급 (T0~T4, §8.1 참조)
   - 도메인 (백엔드 / 프론트 / 시스템 / 멀티모달 / 모바일)
   - 필요한 강점 (1M 컨텍스트, 속도, 정밀도, 멀티모달, 한국어, 가격 민감 등)
   - 제약 (시간, 비용, 보안)
3. **메타 에이전트가 가이드 §3~§7을 교차 조회**:
   - §3 GLM 계열 (다양한 변형)
   - §4 GPT-5.6 계열
   - §5 Grok 계열
   - §6 Gemini/Antigravity
   - §7 MiniMax M 계열
   - §8.1 난이도 매트릭스
   - §8.2 모델 태그 (tags, tier)
   - §17 모델 추론 능력 요약 (이 문서에 추가됨)
4. **메타 에이전트가 2~3개 후보 모델 선정** 후 사용자에게 제시:
   - 작업 메타 프롬프트 (정제된 objective + constraints + acceptance_tests)
   - 추천 A안 (균형) / B안 (빠름) / C안 (고품질) — 각 안의 trade-off 명시
5. **사용자 선택** → 그 모델/도구로 호출
6. **fallback chain** (fallback-table.md 참조)은 메타 에이전트가 아닌 `fallback-dispatcher.sh`가 자동 처리. 단, 메타 에이전트가 미리 제외시킬 도구(예: API 키 만료)를 표시할 수 있다.

### 16.3 메타 에이전트가 추천할 때 포함할 정보

각 추천마다 다음을 사용자에게 제시:

- 모델 ID (예: `zai/glm-4.7`)
- 도구/하네스 (예: `opencode run`)
- **왜 이 모델인가** (가이드 §3~§7 + §17 근거)
- **trade-off** (속도 vs 품질 vs 비용)
- **추론** (이 작업이 T2 정도, 다단계 도구 실행 필요, 한국어 응답 OK)
- **예상 시간** (경험적 추정치)

### 16.4 자동 추천이 적절한 경우

다음은 메타 에이전트 없이도 fallback-dispatcher가 자동 처리 가능:

- 명시적 모델 실패 (timeout, rate limit, AUTH_FAILED)
- 도구 unavailable (health-check FAIL)

다음은 **반드시 메타 에이전트의 판단** 필요:

- 새 작업 시작 시 모델 선택
- fallback chain의 다음 후보 선택 (fallback-dispatcher가 결정하지만, 사용자가 "다른 모델로" 명시 가능)

---

## 17. 모델 추론 능력 요약

메타 에이전트가 매 작업마다 §3~§7을 grep할 필요 없도록, **추론 능력 + 강점 + 한계를 한눈에** 정리한다. 작업 본질과 강점을 매칭할 때 이 표를 먼저 본다.

### 17.1 핵심 추론 능력 매트릭스

| 모델 | 추론 깊이 | 속도 (TPS) | 한국어 | 1M 컨텍스트 | 멀티모달 | 가격대 |
|---|---|---|---|---|---|---|
| `gpt-5.6-sol` | 매우 깊음 (Max/Ultra 지원) | 중간 | 강 | ❌ | ✓ (Computer Use) | 높음 |
| `gpt-5.6-terra` | 중상 (Medium~High) | 빠름 | 강 | ❌ | △ | 중 |
| `gpt-5.6-luna` | 중간 (Low~Medium) | 매우 빠름 | 강 | ❌ | △ | 낮음 |
| `glm-5.2` | 깊음 | 중간 | 중 | ✓ | △ | 중상 |
| `glm-4.7` | 중 (Multi-step tool) | 빠름 | 중 | ❌ (200K) | △ | 중 |
| `glm-5-turbo` | 중 | 빠름 | 중 | ❌ | △ | 중 |
| `glm-4.7-flashx` | 낮음~중 | 매우 빠름 | 중 | ❌ | △ | 낮음 |
| `grok-4.5` | 중 (Terminal 강) | 매우 빠름 (~80 TPS) | 약함 | ❌ | △ | 중 |
| `grok-build-0.1` | 중 | 빠름 | 약함 | ❌ (256K) | △ | 낮음 |
| `gemini-3.5-flash` (AGY) | 중상 | 빠름 | 중 | △ | ✓ (멀티모달 강) | 중 |
| `gemini-3.1-pro-preview` | 깊음 | 중간 | 중 | △ | ✓ | 중상 |
| `gemini-3.1-flash-lite` | 낮음 | 매우 빠름 | 중 | △ | △ | 낮음 |
| `glm-5v-turbo` | 중 (비전) | 빠름 | 중 | △ | ✓ (Vision 강) | 중 |
| `MiniMax-M3` | 깊음 | 중간 (~60 TPS) | 강 | ✓ (1M) | ✓ | 중상 |
| `MiniMax-M2.7` | 중상 | 빠름 (~100 TPS) | 강 | ❌ (200K) | △ | 중 |
| `MiniMax-M2.7-highspeed` | 중상 | 매우 빠름 | 강 | ❌ (200K) | △ | 중 |

### 17.2 강점 키워드 빠른 매칭

작업 키워드 → 적합 모델:

- **UI / 컴포넌트 / 화면 / 디자인**: agy:gemini-3.5-flash, glm-5v-turbo
- **백엔드 / API / DB**: codex:gpt-5.6-terra, opencode:glm-4.7
- **터미널 / 시스템 / Rust / C/C++**: grok:grok-4.5
- **테스트 / fixture / mock**: codex:gpt-5.6-luna, opencode:glm-4.7-flashx
- **리팩터 / migrate / cleanup**: opencode:glm-5.2, codex:gpt-5.6-sol
- **1M / huge / large repo**: opencode:glm-5.2, minimax:MiniMax-M3
- **리뷰 / audit / 보안 / 고위험**: codex:gpt-5.6-sol, glm-5.2, MiniMax-M3
- **디자인 + 코드 (vibe coding)**: agy:gemini-3.1-pro-preview
- **한국어 응답 필수**: codex:gpt-5.6-sol, codex:gpt-5.6-terra, MiniMax-M3
- **빠른 응답 (페어 프로그래밍)**: codex:gpt-5.3-codex-spark, opencode:glm-4.7-flashx
- **장기 자율 / 무인 백그라운드**: opencode:glm-5-turbo, MiniMax-M3

### 17.3 추론 깊이 선택 가이드

`codex` 모델의 reasoning effort 선택:

- **Low**: 파일 검색, 단순 변환, 명확한 작은 패치
- **Medium**: 일반 기능 구현의 기본
- **High/Extra High**: 여러 단계와 트레이드오프가 있는 작업
- **Max**: 하나의 매우 어려운 문제를 깊게 처리
- **Ultra**: 의미 있게 분할 가능한 복합 작업을 여러 서브에이전트로 병렬 (단, 같은 파일을 여러 에이전트가 동시에 수정하는 작업에는 부적합)

### 17.4 한계 / 함정

- **GLM/Grok의 한국어**: 모델 카드는 영문. 한국어 응답은 약함.
- **Preview 모델**: `gemini-3.1-pro-preview` 등은 회귀 테스트 없이 prod 사용 금지.
- **`latest` 별칭**: 내부 모델이 교체될 수 있음. Stable ID 우선.
- **Computer Use**: 화면 변화에 취약. DOM·접근성 트리 우선.
- **AGY 하네스**: AGY 자체의 장애와 Gemini 모델의 장애를 별도 추적.

---

## 18. Codex 런타임 정책

`sections/skills-directory/skill-codex`와 Hermes Codex app-server 런타임을 차용.

### 18.1 흡수한 3가지 규칙

1. **headless 실행은 `codex exec`** — 비대화형 모드. 진행은 stderr, 최종 응답은 stdout.
2. **백그라운드는 stdin을 `</dev/null`로 명시 차단** — Codex가 stdin 대기하며 무한 hang하는 것 방지.
3. **Codex 출력을 Kant가 독립 검증** — Codex의 "완료했습니다"를 그대로 신뢰하지 않음. safety-check.sh + gate-runner로 재검증.

### 18.2 adapter-codex.sh 적용

```bash
cmd=(
  codex exec
  --json
  -o "$response_file"
  -s "$sandbox_mode"
  -C "$worktree"
  -m "$model"
  --skip-git-repo-check      # 비-git 환경 호환
)
# detached 모드:
cmd+=( -c "approval_policy=never" )

runner_output="$("$timeout_runner" run ... "${cmd[@]}" </dev/null)"
```

### 18.3 detached 모드 approval 정책

`KANT_DETACHED=1` 환경변수로 어댑터에 알림. detached에서는:
- `approval_policy=never` — Codex가 server-initiated approval 요청 안 보냄
- `workspace_write` sandbox 경계는 그대로 유지 — worktree 밖 접근은 실패
- Kant의 `safety-check.sh`가 별도로 protected paths / forbidden patterns 검사

이는 안전 약속 5개(자동 push 금지 등)와 양립. Codex의 자동 승인은 sandbox 안에서만 발생.

### 18.4 사용 예

```bash
# foreground (사용자 개입 가능)
kant-loop.sh run TASK.md --quick --agent codex

# detached (사용자 부재, 자동 진행)
KANT_DETACHED=1 kant-loop.sh run TASK.md --quick --agent codex --detach
```

### 18.5 향후 단계 (Goal 3, 4)

- **Goal 3**: Python `codex-app-server-client.py` 추가 — JSON-RPC over stdio. thread resume + 실시간 이벤트 + 서버 initiated approval 자동 처리. process scope = per_run.
- **Goal 4**: 안정성 검증(20회+ 테스트, process crash recovery, worktree 밖 파일 차단) 후 `codex exec` → `app-server` 기본값 전환. `app-server` 장애 시 `codex exec`로 fallback.

### 18.6 제외 사항

- `--full-auto` 사용 금지 (deprecated 호환 옵션). 명시적 sandbox + approval policy 사용.
- Kant를 MCP 서버로 노출 금지 (재귀 오케스트레이션 위험).
- Codex 내부 `review/start`를 Kant의 최종 리뷰로 사용 금지 (provider_must_differ_from_implementer 위반).
