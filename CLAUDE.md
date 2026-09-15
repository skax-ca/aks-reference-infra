# CLAUDE.md: 프로젝트 규칙

**읽는 사람**: 이 저장소에서 배포·운영 작업을 하거나 코드를 검토하는 사람(과 Claude Code).

hub-spoke AKS GitOps 패턴의 **레퍼런스 배포 루트**다(`eks-reference-infra`의 Azure 대응).
`iac-module-library`의 모듈을 **소비**해 실제로 세우고 걷어내는 코드를 갖는다. 모듈 자체를
만들지 않는다.

## 0. 이 repo의 위치 (반드시 먼저 읽을 것)

| repo | 역할 | SSOT |
|------|------|------|
| **이 repo (`aks-reference-infra`)** | hub-spoke 패턴을 **소비해 배포**하는 루트 | 이 배포 코드. 설계 근거는 해당 `.tf`/`.sh` 파일의 인라인 주석이 SSOT다. 운영 절차는 `docs/hub-lifecycle.md`(✅)·`docs/spoke-lifecycle.md`(✅)·`docs/runbooks.md`(⏳) |
| `iac-module-library` | Terraform/OpenTofu 모듈·설계 | 모듈 계약(`docs/module-catalog.md`), 네이밍 약어(`docs/naming/abbreviations/azure.md`), 저장소 전역 결정(`docs/decisions.md`), **hub-spoke 패턴의 설계 갈림길과 기각(`docs/architectures/gitops-hub-spoke/azure/`)**, 문서·주석 규칙(`docs/conventions.md`) |
| `aks-platform-gitops` | ArgoCD Application·AppProject·cluster-secret (계층 2) | ✅ hub·dev 양쪽 등록 완료(self-managed ArgoCD·AKS App Routing·Karpenter·Kyverno, `eks-platform-gitops` 대응. dev는 Entra Workload Identity 기반으로 등록). 설계 근거는 그 저장소 자신의 `README.md` |

⚠️ **설계·컨벤션의 근거는 이 repo에 없다.** "왜 OpenTofu인가" 같은 질문은
`iac-module-library`의 `CLAUDE.md`·`docs/decisions.md`가, "왜 role assignment를
스포크가 만드는가"·"왜 공개 FQDN인가" 같은 패턴 갈림길은 같은 repo의
`docs/architectures/gitops-hub-spoke/azure/`가 갖는다. 이 repo 고유의 판단(Pod CIDR
배치, 2단 조회가 필요한 이유 등)은 별도 문서가 아니라 그 판단이 적용된 `.tf`/`.sh`
파일의 인라인 주석이 SSOT다. 원본(`eks-reference-infra`)도 설계 문서를 따로 두지 않고
코드 주석에 근거를 남기는 관례를 그대로 따른다.

⛔ **주석·문서에 좌표를 쓰지 않는다.** 날짜, 계획 파일 경로나 절 번호, 세션 차수, PR
번호, "실측했다" 같은 사건 서술은 `git blame`과 커밋 메시지가 갖는다. 주석은 "왜 이
값인가"와 "바꾸면 무엇이 깨지는가"에만 답한다(`iac-module-library` `docs/conventions.md`
「주석」). 이 규칙이 없을 때 git 밖 계획 파일을 인용한 주석이 쌓여 아무도 열 수 없었다.

**운영 절차 SSOT는 이 repo다.** 원본(`eks-reference-infra`)은 `docs/hub-lifecycle.md`·
`docs/spoke-lifecycle.md`·`docs/runbooks.md` 세 문서가 그 역할을 한다. 이 repo는
`docs/hub-lifecycle.md`·`docs/spoke-lifecycle.md`를 포팅했다(✅, 둘 다 전체
철거→재구축 e2e 검증까지 완료). `docs/runbooks.md`는 아직이다(⏳).
ADR류 설계 문서 계층(`docs/decisions/`)은 두지 않는다. 한 차례 만들었다가 `.tf`/`.sh`
주석과 내용이 겹치고 코드가 바뀐 뒤 갱신되지 않아 지웠다(git 이력에 남아 있다).

## 1. 저장소 구조

```
bootstrap/              ✅ state Storage Account · App Registration · 커스텀 역할(IaC 밖, 사람이 스크립트로 실행)
live/hub/networking/    ✅ VNet(hub)
live/hub/vwan/          ✅ Virtual WAN(hub, networking과 분리된 state)
live/hub/aks/           ✅ AKS 클러스터(hub, Karpenter/NAP·KEDA·App Routing·hub ArgoCD workload identity 포함)
live/hub/workbench/     ✅ CLI 전용 운영 VM(hub, private 클러스터의 유일한 일상 접근 지점)
live/dev/networking/    ✅ VNet(spoke 첫 인스턴스), vWAN 스포크 연결 완료
live/dev/aks/           ✅ AKS 클러스터(dev, hub와 풀 패리티. Karpenter/NAP·KEDA·App Routing 포함, 노드 2대 Ready 확인)
live/dev/workbench/     ✅ CLI 전용 운영 VM(dev, hub와 풀 패리티. vm_size만 Standard_B2s_v2로 오버라이드 - 이 구독의 Standard_B2s 용량 제약 때문)
.github/workflows/      배포 루트마다 워크플로 하나(plan은 push, apply/destroy는 workflow_dispatch)
docs/                   ✅ hub-lifecycle.md·spoke-lifecycle.md · ⏳ runbooks.md
scripts/                ⏳ 아직 없음(원본의 `validate-doc-conventions.py` 등 포팅 예정, 4절)
```

같은 repo 안에서 `live/hub/*`와 `live/dev/*`는 **각자 별도 state**를 쓴다(같은 배포 루트
안의 다른 env). `live/hub/networking`과 `live/hub/vwan`도 서로 분리된 state다. 루트 간
결합은 `terraform_remote_state`가 아니라 **Name·태그 기반 `data` 조회**로 하거나(같은
구독 안), 크로스 구독인 경우 CI 변수로 리소스 ID를 명시 주입한다(`live/hub/vwan`의
`spoke_connections`, 근거는 `live/hub/vwan/main.tf`의 관련 주석).

## 2. 실행 모델

| 항목 | 규칙 |
|------|------|
| 엔진 | OpenTofu(`tofu` 1.12.5), Terraform이 아니다 |
| backend | Azure Storage Account + Blob Container. `use_azuread_auth = true`, `allowSharedKeyAccess = false`(계정 키로 RBAC 우회 차단). 계정명은 git에 없다(GitHub 저장소 변수 `AZURE_HUB_*`/`AZURE_DEV_*` + 로컬 `backend.hcl`, 둘 다 git 밖) |
| state key | `<env>/<component>.tfstate`(예: `hub/vwan.tfstate`, `dev/networking.tfstate`) |
| 자격증명 | GitHub OIDC → 단일 App Registration, 구독 전체 스코프 `Owner`(AWS 원본의 `AdministratorAccess` 실행 Role과 스코프 축에서 완전 대칭). 방어선은 권한 크기가 아니라 FIC subject 하나로 좁힌 도달 경로뿐이다(아래 ⛔ 참고). 권한 크기를 방어선으로 삼는 설계(RG 스코프 커스텀 역할 + 불변식 검사)를 기각한 이유는 `iac-module-library` `docs/architectures/gitops-hub-spoke/azure/README.md` 「하지 않는 것」 |
| plan → apply | plan은 push에서 자동 실행, `workflow_dispatch`를 누르는 것 자체가 apply 승인이다 |
| 로컬에서 되는 것 | `init` + `validate`까지. **apply는 로컬에서 안 된다.** `require_oidc`/`var.ci_run` 가드가 `var.ci_run != true`이면 즉시 실패시킨다 |

⚠️ **재시도할 때 새 `workflow_dispatch`를 누르지 않는다.** 실패한 job이 apply라면
`gh run rerun <run-id> --failed`로 **저장된 plan을 그대로** 재적용한다. 새 dispatch는
plan을 처음부터 다시 돌려 승인한 것과 다른 계획을 만든다.

⛔ **CI 신원(App Registration)의 FIC(Federated Identity Credential) `subject`에
와일드카드를 넣거나, 그 `subject`가 가리키는 GitHub repo·브랜치 보호 규칙을 완화하지
않는다.** 이 신원은 구독 전체 `Owner`이므로(위 「자격증명」행), 이
신원에 도달할 수 있는 경로를 정확히 하나(이 repo, `main` 브랜치)로 좁히는 것이 유일한
방어선이다. 권한 크기는 방어선이 아니다. 이 경로가 넓어지면(subject 완화, 정적 자격증명
추가, Entra 그룹 편입 등) 설계 자체를 재검토하는 트리거로 취급한다.

## 3. 네이밍·태깅

`Name` 포맷과 리소스 타입 약어는 `iac-module-library`의
`docs/naming/abbreviations/azure.md`가 SSOT다(임의 생성 금지, `rg`·`st`·`entapp`·
`vwan`·`vhub` 등재 완료). 이 repo에서 실제로 쓰는 값:

- `workload` = `demo`(고정, `live/hub`·`live/dev` 모두 반드시 동일해야 한다)
- `env` = `hub` 또는 `dev`(spoke 첫 인스턴스), `region` = `koreacentral`(`krc`)
- 예: `vnet-demo-hub-krc-main`, `vnet-demo-dev-krc-main`, `rg-demo-hub-krc-workload-01`

CIDR 배치(hub/dev VNet, Pod secondary 대역)는 `Name`처럼 재조합하는 값이 아니라 각
루트의 `main.tf` locals 주석이 실물 SSOT다. 왜 스포크마다 Pod 대역이 다른가, Azure CNI
Pod Subnet을 택한 이유도 그 주석에 있다.

## 4. 로컬 게이트 (⏳ 아직 이식 안 됨)

원본(`eks-reference-infra`)은 `scripts/validate-doc-conventions.py` +
`tofu fmt`/`tflint`/`trivy`를 `.githooks/`(pre-commit/pre-push)로 강제한다. 이 repo는
`scripts/`·`.githooks/`를 아직 포팅하지 않아 이 게이트가 없다. `docs/runbooks.md`
포팅(0절 표 참고)과 함께 진행할 후속 작업이다. 그때까지는 사람이 직접 `tofu fmt`·
문서 규칙을 지킨다.

## 5. 브랜치·PR 규칙

| 변경 대상 | 경로 |
|-----------|------|
| **`.tf` · `.github/workflows/`** | **브랜치 → PR** |
| **문서 전용(`docs/**/*.md`·`CLAUDE.md`)** | **`main` 직접 커밋** |

원본과 동일한 기준: *"CI가 머지 전에 막아야 하는가"* 하나뿐이다. 각 워크플로는
`push: branches: [main]`에도 plan까지 돌므로 "PR이어야 CI가 돈다"는 성립하지 않는다.

⚠️ **초기 스캐폴딩 단계의 커밋은 이 규칙 확정 전이라 `.tf`·워크플로 변경도 `main` 직접
push였다.** 과거 커밋을 소급 정정하지 않는다.

## 6. 문서 작성 규칙

`docs/*.md`·`README.md`·이 파일은 원본과 동일하게 `iac-module-library`의
`docs/conventions.md`가 정하는 규칙을 따른다: 문서 간 절 번호 인용 금지, 이모지는
`✅⏳❌⚠️⛔🔴🔑` 7종만, 문서당 400줄 제한, em-dash(유니코드 U+2014) 금지. 검증
스크립트(`scripts/validate-doc-conventions.py`)는 아직 이식하지 않아(4절) 지금은
수동으로 지킨다. `docs/` 디렉토리 자체(`hub-lifecycle.md` 등 운영 절차)도 원본에서
기계적으로 이식할 대상이다.

## 7. 새 리소스·모듈 인자를 쓰기 전에

이 repo는 모듈 내부를 고치지 않지만, 루트 `main.tf`가 모듈에 넘기는 변수·참조하는
출력은 추정하지 않는다: `iac-module-library`의 `modules/azure/vnet` 소스(각
`live/*/.terraform/modules/vnet/modules/azure/vnet/`에 다운로드된 실물, 또는 module
repo를 직접 확인)로 실제 계약을 확인한다.
