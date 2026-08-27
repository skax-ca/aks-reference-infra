# Notepad
<!-- Auto-managed by OMC. Manual edits preserved in MANUAL section. -->

## Priority Context
<!-- ALWAYS loaded. Keep under 500 chars. Critical discoveries only. -->
## Priority Context

aks-reference-infra: bootstrap/ hub 실제 Azure 검증 완료(3-1+3-2, 2026-08-27). ARM eventual-consistency 버그 3건 수정(retry_on_replication_delay, role_definition_list_retry, roleDefinitionId 필터). 불변식(b) 관리그룹 제거(7→6종). 네이밍 약어 rg/st/entapp를 iac-module-library에 등재 후 hub 리소스 재생성(todo- 완전 제거). commit 6f088b8, 원격 없어 push 미해당. 남은 미결: dev(spoke) 검증(구독 1개뿐), 크로스구독 vWAN 권한 스코프, Option C 보류. 다음은 vWAN 스코프 확정 또는 Phase 1 networking plan→execute.

## Working Memory
<!-- Session notes. Auto-pruned after 7 days. -->
### 2026-08-27 05:15
2026-08-27 - deepinit으로 CLAUDE.md·notepad-sync 스킬 초기화(HANDOFF.md 삭제, 내용 병합). ralplan(5라운드, Architect/Critic 교차검증)으로 bootstrap/ 설계 v6 확정: AWS 2단 Role 체인 대신 RG스코프 커스텀 역할 2종+7종 권한0건 불변식. 사용자 확정: hub/dev 별도 구독, 배포는 브랜치정책만(무인자동화 유지), Option C는 보류. ralph(4라운드 리뷰)로 bootstrap/{README,config.sh,bootstrap.sh,verify.sh} 구현, ai-slop-cleaner로 검토이력 주석 정리. 핵심 발견: macOS bash 3.2가 $() 안에서 errexit 미적용 - TOP_PID+kill 시그널 패턴으로 해결(project-memory architecture 노트 참고). 최종 APPROVE, 단 실제 Azure 실행 검증은 미완(자격증명 없는 세션).
### 2026-08-27 06:44
### 2026-08-27 (2차 세션) - bootstrap/ 실제 Azure 검증 + 네이밍 정리

사용자가 Azure 자격증명 확보 후 hub 대상 3-1(멱등성)·3-2(음성 테스트) 실제 실행 요청.

**1라운드 - 실제 검증**: az login 확인(구독 1개뿐, Owner 권한) → hub 대상 bootstrap.sh 첫 실행 중
"Role doesn't exist" 에러로 exit 2 → retry_on_principal_not_found를 retry_on_replication_delay로
개명·확장해 해결 → 재실행 중 멱등성 붕괴(매번 role definition update 발생) 발견 → 존재 확인 후
재조회에 5회 재시도(role_definition_list_retry) 신설해 해결 → 3-1 완전 통과 → verify.sh가 관리
그룹 스코프 검사에서 AuthorizationFailed(테넌트 루트 MG Reader 필요) → 사용자에게 "OIDC 배포에
실제로 필요한가" 질문받고 확인 결과 불필요 → 사용자가 삭제 확정 → verify.sh에서 check_mg_scope_
assignments 전체 제거(7종→6종), README/CLAUDE.md 갱신, 설계 이력 문서(.omc/plans/bootstrap-
credential-design.md)엔 날짜 붙은 추가 기록만 남기고 원문은 보존 → 3-2 음성 테스트(FIC+Storage
drift 주입)까지 hub 대상으로 완전 통과.

**2라운드 - 네이밍 정리**: 사용자가 "todo-" 접두사 원인을 질문 → iac-module-library의 azure.md에
Network 6종뿐이고 RG/Storage Account/App Registration 약어가 없었던 게 원인임을 실측 확인(CAF
표 직접 조회) → App Registration은 ARM 리소스가 아니라 Microsoft Graph 객체라 CAF 표 자체에
없다는 것도 확인 → 사용자가 "약어부터 등록하고 기존 리소스는 삭제 후 재생성하자"고 결정 →
iac-module-library에 rg/st/entapp 3종 등재(entapp는 카탈로그의 첫 non-ARM 등재 사례,
validate-abbreviations.py 통과 확인) → aks-reference-infra의 config.sh 네이밍 함수 교체 →
hub 리소스 전체 삭제(잠금 해제→RG 2개 삭제→App Registration 삭제→역할 정의 2종 삭제) → 새
이름으로 bootstrap.sh 재실행 중 세 번째 버그 발견(RoleDefinitionWithSameNameExists, 최초
존재 확인 조회도 재시도 없었던 게 원인) → role_definition_list_retry를 최초 조회에도 적용 +
role assignment 조회를 roleDefinitionName에서 roleDefinitionId로 교체(join 지연 문제) →
3-1·3-2 처음부터 재통과 확인.

**커밋**: aks-reference-infra 6f088b8(CLAUDE.md·bootstrap/*, 5파일). iac-module-library는
사용자가 직접 커밋(azure.md). 둘 다 원격 없음/이미 push까지 사용자가 처리해 이 세션에서는
push 불필요.

**미결**: dev(spoke) 인스턴스 미검증(구독 1개뿐), 크로스 구독 vWAN 권한 스코프 미확정,
Option C 보류. 다음 세션은 vWAN 스코프 확정 또는 Phase 1 networking plan→execute.


## 2026-08-27 05:15
2026-08-27 - deepinit으로 CLAUDE.md·notepad-sync 스킬 초기화(HANDOFF.md 삭제, 내용 병합). ralplan(5라운드, Architect/Critic 교차검증)으로 bootstrap/ 설계 v6 확정: AWS 2단 Role 체인 대신 RG스코프 커스텀 역할 2종+7종 권한0건 불변식. 사용자 확정: hub/dev 별도 구독, 배포는 브랜치정책만(무인자동화 유지), Option C는 보류. ralph(4라운드 리뷰)로 bootstrap/{README,config.sh,bootstrap.sh,verify.sh} 구현, ai-slop-cleaner로 검토이력 주석 정리. 핵심 발견: macOS bash 3.2가 $() 안에서 errexit 미적용 - TOP_PID+kill 시그널 패턴으로 해결(project-memory architecture 노트 참고). 최종 APPROVE, 단 실제 Azure 실행 검증은 미완(자격증명 없는 세션).


## MANUAL
<!-- User content. Never auto-pruned. -->

