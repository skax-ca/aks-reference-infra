# Session — aks-reference-infra

## 지난 세션 (2026-09-16)
원본(`eks-reference-infra`)에서 남아 있던 이식 항목을 전부 끝냈다. `docs/runbooks.md` 포팅
(a0a551e. EKS 전제인 업그레이드 순서·workbench 교체·taint 전략은 AKS 실물에 맞춰 다시 씀,
hub-lifecycle의 root-app `revisions`→`revision` 오기 정정), 로컬 게이트 `.githooks/`+
`scripts/validate-*.py`+`.tflint.hcl`(azurerm 0.32.0)+`.trivyignore`(PR #48, 전체 기준선 통과),
`scripts/teardown-verify.sh`(PR #49. 원본과 달리 fail-closed, hub·dev 철거 상태에서 exit 0과
exit 2 경로 셋을 실측). hub aks 모듈 태그를 dev와 같은 v0.9.0으로 맞췄다(PR #49, validate 통과,
plan은 No changes 예상). GitHub 변수 `AZURE_HUB_AKS_IDENTITY_ID` 삭제. 할 일에서 ArgoCD 비밀번호
교체(hub-lifecycle 완료 조건에 이미 있음)·Azure Firewall(인터넷 노출 없는 패턴이라 불필요)·
삭제 보호 복원(hub-lifecycle 0단계 ⛔에 이미 있음)을 뺐다. 인프라는 여전히 전부 철거 상태다.

## 다음 할 일
- [ ] CLAUDE.md를 eks(24줄)처럼 "값·좌표만"으로 줄인다. **선행 조건**: `iac-module-library/CLAUDE.md`에
  「배포 루트 공통」이 실제로 생긴 뒤(사용자가 그 repo에서 설계 예정. 현재 eks 머리말이 가리키지만
  절이 없다). 분류: 0절 위치 표·2절 엔진·5절 브랜치는 module CLAUDE.md와 이미 중복이라 삭제.
  state 분리·`data` 조회 결합·plan→apply·rerun `--failed`·로컬 init+validate·인라인 주석 SSOT·
  ADR 없음·좌표 금지·게이트 파이프라인·모듈 계약 확인·문서 규칙·naming 합성은 공통으로 올림.
  남길 값: 7루트·state key·backend(`use_azuread_auth`·`allowSharedKeyAccess=false`)·repo 변수명
  (`AZURE_HUB_*`/`AZURE_DEV_*`)·`demo`/`hub|dev`/`krc`·훅 활성화+azurerm ruleset 0.32.0·dev workbench
  `Standard_B2s_v2`·docs 좌표 3개·`docs/architectures/gitops-hub-spoke/azure/` 좌표. Azure 고유라
  공통에 못 올리는 것: CI 신원(App Registration 1개, 구독 Owner) + ⛔ FIC subject 와일드카드·경로
  확장 금지. 이건 별도 절로 남긴다.
