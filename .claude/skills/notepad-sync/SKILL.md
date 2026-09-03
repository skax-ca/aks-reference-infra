---
name: notepad-sync
description: 이 프로젝트(aks-reference-infra)의 .omc/notepad.md·project-memory.json 관리 절차. 전역 session-start/session-end 스킬이 3단계(세션 태스크 확인/메모리 갱신)에서 이 스킬이 있으면 호출하도록 위임한다. OMC가 이 머신에서 비활성 상태(~/.claude/.omc-enabled 없음)면 조용히 건너뛴다.
---

# Notepad Sync (project-scoped)

이 프로젝트는 `eks-reference-infra`·`iac-module-library`와 **동일한** OMC notepad 3단 구조
(**Priority** 포인터, 500자 이내 / **Working** 세션 서술, 7일 자동 소멸 / **MANUAL** 영구 아카이브,
자동 로드 안 됨)와 `project-memory.json`(구조화 영구 사실)을 쓴다(원본 `eks-reference-infra`가
2026-08-19에 통일한 방식을 deepinit 시점부터 그대로 적용). 세션 종료 시 "무엇을 어디에 저장할지"
판단은 **OMC가 이미 제공하는 `oh-my-claudecode:remember` 스킬에 위임**한다. 그 판단 로직을 여기서
다시 만들지 않는다. 이 파일은 그 위임 전 가드와, `remember`가 모르는 이 repo 고유의 제약만 얹는다.

## 0. 가드(OMC가 이 머신에서 꺼져 있으면 전부 건너뛴다)

`~/.claude/.omc-enabled` 파일이 없으면(또는 `oh-my-claudecode:remember` 스킬이 안 보이면)
아래 1~2절 전부 건너뛰고 다음 한 줄만 안내한다: "이 머신은 OMC 비활성화 상태라 프로젝트 컨텍스트
확인/저장을 생략합니다(`touch ~/.claude/.omc-enabled`로 활성화 가능)." 에러로 취급하지 않는다.
이 프로젝트가 OMC를 쓰기로 한 것과, 지금 이 머신에서 OMC를 켰는지는 별개다.

## ⛔ 2026-09-01, `mcp__t__notepad_*`/`mcp__t__project_memory_*` 도구 사용을 전면 중단

원인: `iac-module-library`가 실측한 바(2026-08-28·08-30·09-01 여러 차례 재현)로, 이 MCP 도구는
"읽기"조차 내부적으로 프로젝트를 재스캔해 서술형 필드를 빈 스키마로 덮어쓰거나, `add_note`가
20개 FIFO로 경고 없이 오래된 항목을 삭제하거나, git 상태가 방금 바뀐 직후(clone/pull 등)
stale 캐시 기반으로 파일을 통째로 재작성해 헤더를 중복 삽입하는 부수효과를 갖고 있다 — 표준
Read/Edit 도구엔 없는 숨은 로직이다. 이 repo의 `.omc/notepad.md`에서도 실제로 같은 클래스의
중복(Priority Context 4중복·세션 서술 3중복)이 발견돼 2026-09-01에 정리했다(과거 어느 세션이
이 도구로 쓰다가 겪은 것으로 추정, 정확한 발생 시점은 git blame으로 특정 안 함).

대응: `.claude/settings.json`에 `permissions.deny`로 이 두 도구군(`notepad_*`·`project_memory_*`,
읽기·쓰기 전부)을 등록해 **Claude의 도구 목록에서 아예 제거**했다(호출을 막는 게 아니라 존재
자체를 안 보이게 하는 방식 — PreToolUse 훅보다 근본적이고, 훅 타임아웃으로 새는 경우도 없다).
그래서 이제 `.omc/notepad.md`·`.omc/project-memory.json` 두 파일은 **읽기·쓰기 전부 Read/Edit
도구로 직접** 다룬다 — `CLAUDE.md`를 다루는 것과 완전히 같은 방식이다. 과거에 있던 "이 도구는
세션이 시작된 worktree에 고정된다"는 worktree 격리 캐비어트도, 도구 자체를 안 쓰니 더 이상
해당 없음.

이 결정은 `iac-module-library`(2026-09-01 최초 적용, 커밋 `35d7c2b`)에서 먼저 반영·검증됐고,
`eks-reference-infra`에도 같은 시점에 동일하게 반영 중이다.

## 세션 시작 시 (session-start 3번에서 호출됨, 가드 통과 후)

1. `Read`로 `.omc/notepad.md`를 열어 `## Priority Context` 섹션을 사용자에게 보여준다.
2. `Read`로 `.omc/project-memory.json`을 열어 `customNotes`에서 미결 항목을 확인한다.
3. 같은 `.omc/notepad.md`의 `## Working Memory` 섹션에 최근 7일 내 세션 서술이 있으면 함께
   보여준다.
4. Priority Context가 눈대중으로 500자를 넘어 보이면 정리하지 말고 사용자에게 먼저 알린다.

## 세션 종료 시 (session-end 2번에서, 커밋 전에 호출됨, 가드 통과 후)

1. **`oh-my-claudecode:remember` 스킬을 호출**해 이번 세션의 발견 사항을 분류·저장시킨다
   (project memory / notepad priority / notepad working / docs 중 어디로 갈지는 그 스킬이 판단한다).
2. `remember`가 모르는, 이 repo만의 제약을 그 판단에 추가로 적용한다:
   - **`.omc/notepad.md`·`.omc/project-memory.json` 두 파일 전부 `Edit`/`Read` 도구로 직접
     다루는 것이 유일한 경로다**(2026-09-01부터 MCP 도구는 `permissions.deny`로 아예 제거됨,
     위 절 참조). Priority Context는 500자 이내 유지(전체 교체 방식, append 아님). Working
     Memory는 최신 항목을 `## Working Memory` 바로 아래(상단)에 추가. 쓴 뒤에는 반드시
     `git diff`로 의도한 변경만 있는지, 헤더 중복이 없는지 확인한다.
   - `docs/*.md`에는 날짜·사건 서술을 쓰지 않는다(`CLAUDE.md` 1절이 가리키는 module repo
     `docs/conventions.md`를 그대로 적용). `remember`가 "docs"를 저장 후보로 제안해도 서술형
     내용이면 notepad로 돌린다.
   - `project-memory.json`은 `.gitignore` 화이트리스트로 git 커밋 대상이다(notepad.md와 함께
     크로스 머신 SSOT). 이 머신에만 유효한 임시 정보는 넣지 않는다.
   - ⛔ **fork/서브에이전트(team 모드 포함)는 notepad에 직접 쓰지 않는다.** 결과를 텍스트로
     보고만 하고, notepad 기록은 **team-lead(메인 세션)가 세션당 한 번만** 통합해서 쓴다 —
     여러 세션이 각자 notepad를 따로 쓰면 헤더 중복이 재발한다(이 repo가 2026-09-01에 정리한
     4중복·3중복이 정확히 그 증상).
3. 이 단계가 끝난 뒤에만 session-end 3번(커밋)으로 넘어간다. 위 변경분이 그 커밋에 함께 실려야 한다.

## opencode 세션

원본 두 repo(`eks-reference-infra`·`iac-module-library`)는 `.opencode/plugins/notepad.ts`로 같은
3단 구조를 opencode 세션에서도 제공한다. 이 repo는 아직 `.opencode/` 자체가 없다(2026-08-27
deepinit 시점 기준, Phase 0). opencode에서 이 repo 작업이 필요해지면 그때 같은 플러그인을
이식한다. 지금은 Claude Code 세션만 지원 대상이다.
