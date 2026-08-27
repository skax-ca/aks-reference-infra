# Notepad
<!-- Auto-managed by OMC. Manual edits preserved in MANUAL section. -->

## Priority Context
<!-- ALWAYS loaded. Keep under 500 chars. Critical discoveries only. -->
aks-reference-infra: bootstrap/ 자격증명 계층 구현 완료(ralplan 5R+ralph 4R, APPROVE). 다음 세션: 사용자가 실제 Azure로 3-1/3-2 검증 실행 필요. 미확정: 네이밍 약어 등재(iac-module-library), 크로스구독 vWAN 권한 스코프(Phase 1). live/*(Terraform) 아직 없음, 다음은 Phase 1 networking plan→execute.

## Working Memory
<!-- Session notes. Auto-pruned after 7 days. -->
### 2026-08-27 05:15
2026-08-27 - deepinit으로 CLAUDE.md·notepad-sync 스킬 초기화(HANDOFF.md 삭제, 내용 병합). ralplan(5라운드, Architect/Critic 교차검증)으로 bootstrap/ 설계 v6 확정: AWS 2단 Role 체인 대신 RG스코프 커스텀 역할 2종+7종 권한0건 불변식. 사용자 확정: hub/dev 별도 구독, 배포는 브랜치정책만(무인자동화 유지), Option C는 보류. ralph(4라운드 리뷰)로 bootstrap/{README,config.sh,bootstrap.sh,verify.sh} 구현, ai-slop-cleaner로 검토이력 주석 정리. 핵심 발견: macOS bash 3.2가 $() 안에서 errexit 미적용 - TOP_PID+kill 시그널 패턴으로 해결(project-memory architecture 노트 참고). 최종 APPROVE, 단 실제 Azure 실행 검증은 미완(자격증명 없는 세션).


## MANUAL
<!-- User content. Never auto-pruned. -->

