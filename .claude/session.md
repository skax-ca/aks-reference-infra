# Session — aks-reference-infra

## 지난 세션 (2026-09-15)
OMC 종속성을 전부 걷어냈다. 로컬 `.omc/`(루트·하위 8개·모듈 캐시 2개) 삭제, `.gitignore` 규칙
삭제(45059e0), 고유 계획 파일 2개는 `~/archive/aks-reference-infra-omc-20260915.tar.gz`에만
보관(GUID 포함, git 금지). 그 인용을 풀어 쓰는 김에 코드·문서 주석을 iac-module-library
`conventions.md` 「주석」 기준으로 다시 썼다: PR #47(52파일, 비주석 변경은 description·
error_message·echo 문구뿐, 7루트 validate 통과), 문서·스킬 b7802a7. 그 과정에서 spoke-peer
역할의 미사용 `roleAssignments/*`·`managedClusters/read`를 회수했다(PR #46, bootstrap 2회
changed 1→0, verify drift 없음). 결정의 자리는 iac-module-library
`docs/architectures/gitops-hub-spoke/azure/`(3cc5c6a·af98957)와 CLAUDE.md 0절 ⛔(좌표 금지)에 있다.
인프라는 전부 철거 상태라 main push CI는 networking 2개만 성공하고 5개는 not found로 실패한다(정상).

## 다음 할 일
- [ ] 재구축 후 `deletion_protection`/`prevent_destroy`를 `true`로 복원(hub·dev networking, hub vwan)
- [ ] GitHub repo 변수 `AZURE_HUB_AKS_IDENTITY_ID` 삭제(코드 참조 0, README 안내도 지웠음)
- [ ] `docs/runbooks.md` 포팅
- [ ] `scripts/validate-doc-conventions.py` + `.githooks/` 로컬 게이트 이식(CLAUDE.md 4절)
- [ ] 재구축 시 ArgoCD 초기 admin 비밀번호 교체 + `argocd-initial-admin-secret` 삭제
- [ ] Azure Firewall을 vWAN 허브에 둘지 결정(vHub는 `/22`라 선택지는 열려 있음)
