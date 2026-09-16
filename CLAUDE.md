# CLAUDE.md

Azure hub-spoke AKS 배포 루트(`eks-reference-infra`의 Azure 대응). `iac-module-library`의 모듈을 소비해
세우고 걷어낸다. 규칙(엔진·실행 모델·브랜치·네이밍·주석·문서·모듈 계약 확인)은
`iac-module-library/CLAUDE.md`의 「배포 루트 공통」이 갖는다. 이 파일은 이 repo의 값과 문서 좌표,
그리고 Azure에만 있는 규칙 하나(CI 신원)를 갖는다.

## 이 repo가 소유하는 문서 (작업 전에 먼저 읽는다)

- `docs/hub-lifecycle.md`: hub 구축·철거
- `docs/spoke-lifecycle.md`: spoke 구축·철거
- `docs/runbooks.md`: 이미 선 환경 운영

패턴 갈림길("왜 role assignment를 스포크가 만드는가", "왜 공개 FQDN인가")은
`iac-module-library/docs/architectures/gitops-hub-spoke/azure/`가 갖는다. 이 repo 고유의 판단(Pod CIDR
배치, 2단 조회가 필요한 이유 등)은 해당 `.tf`/`.sh` 인라인 주석이 SSOT다. CIDR 배치는 각 루트
`main.tf`의 locals 주석이 실물이다.

## 값

| 항목 | 값 |
|------|-----|
| 배포 루트 | `live/hub/{networking,vwan,aks,workbench}` · `live/dev/{networking,aks,workbench}`, 7개 전부 **별도 state** |
| state key | `<env>/<component>.tfstate` |
| backend | Azure Storage Account + Blob Container. `use_azuread_auth = true`, `allowSharedKeyAccess = false`(계정 키로 RBAC 우회 차단) |
| git 밖 값 | repo 변수 `AZURE_HUB_*`/`AZURE_DEV_*` + 로컬 `backend.hcl` |
| 네이밍 | `workload=demo`(hub·dev 동일 필수) · `env=hub|dev` · `region=krc` |
| 루트 간 결합 예외 | 크로스 구독은 `data` 조회 대신 CI 변수로 리소스 ID를 주입한다(`live/hub/vwan`의 `spoke_connections`) |
| 로컬 apply 가드 | `require_oidc`/`var.ci_run`. `ci_run != true`이면 즉시 실패 |
| dev workbench | `vm_size = Standard_B2s_v2` 오버라이드(이 구독의 `Standard_B2s` 용량 제약) |
| 로컬 게이트 | `git config core.hooksPath .githooks` + `tflint --init`(clone마다 1회). azurerm ruleset 핀 `0.32.0` |

## CI 신원

GitHub OIDC → App Registration 1개, 구독 전체 스코프 `Owner`(AWS 원본의 `AdministratorAccess` 실행
Role과 스코프 축에서 대칭). 방어선은 권한 크기가 아니라 FIC(Federated Identity Credential) `subject`
하나로 좁힌 도달 경로다. 권한 크기를 방어선으로 삼는 설계(RG 스코프 커스텀 역할 + 불변식 검사)를
기각한 이유는 `iac-module-library/docs/architectures/gitops-hub-spoke/azure/README.md` 「하지 않는 것」.

⛔ **FIC `subject`에 와일드카드를 넣거나, 그 `subject`가 가리키는 GitHub repo·브랜치 보호 규칙을
완화하지 않는다.** 이 신원에 도달하는 경로를 정확히 하나(이 repo, `main`)로 좁히는 것이 유일한
방어선이다. 경로가 넓어지는 변경(subject 완화, 정적 자격증명 추가, Entra 그룹 편입)은 설계 자체를
재검토하는 트리거로 취급한다.
