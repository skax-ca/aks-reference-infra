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
- [ ] 재구축(hub-lifecycle → spoke-lifecycle 순서). 그때 hub aks v0.9.0 plan이 No changes인지, `teardown-verify.sh`를 철거 전 "현황 목록"으로도 써 보는지 확인
- [ ] 다른 Mac에서 clone하면 `git config core.hooksPath .githooks` + `tflint --init` 1회(CLAUDE.md 4절)
- [ ] Azure Firewall을 두지 않는 결정을 `iac-module-library` `docs/architectures/gitops-hub-spoke/azure/README.md` 「하지 않는 것」에 한 줄 남길지 결정(그 repo 작업)
