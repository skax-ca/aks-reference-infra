# CLAUDE.md: 프로젝트 규칙

**읽는 사람**: 이 저장소에서 배포·운영 작업을 하거나 코드를 검토하는 사람(과 Claude Code).

hub-spoke AKS GitOps 패턴의 **레퍼런스 배포 루트**다(`eks-reference-infra`의 Azure 대응).
`iac-module-library`의 모듈을 **소비**해 실제로 세우고 걷어내는 코드를 갖는다. 모듈 자체를
만들지 않는다.

## 0. 이 repo의 위치 (반드시 먼저 읽을 것)

| repo | 역할 | SSOT |
|------|------|------|
| **이 repo (`aks-reference-infra`)** | hub-spoke 패턴을 **소비해 배포**하는 루트 | 이 배포 코드. GitOps 운영 절차(구축·철거·런북)는 아직 이식 전(6절) |
| `iac-module-library` | Terraform/OpenTofu 모듈·설계 | 모듈 계약(`docs/module-catalog.md`), 네이밍 약어(`docs/naming/abbreviations/azure.md`), 아키텍처 결정(`docs/decisions.md`), 문서 문체 규칙(`docs/conventions.md`) |
| `aks-platform-gitops` | ArgoCD Application·AppProject·cluster-secret (계층 2) | ⏳ 아직 없음(Phase 2 AKS 이후, `eks-platform-gitops` 대응) |

⚠️ **설계·컨벤션의 근거는 이 repo에 없다.** "왜 OpenTofu인가" 같은 질문은
`iac-module-library`의 `CLAUDE.md`·`docs/decisions.md`가 갖는다. 이 repo 고유의 설계
판단(크로스 구독 권한 스코프, Pod CIDR 배치 등)은 `.omc/plans/*.md`(ADR 형식)가 SSOT다.
문서 문체 규칙(em-dash 금지·이모지 7종·400줄 제한)의 텍스트 SSOT도 여전히 module repo다.

**운영 절차 SSOT는 이 repo가 될 예정이다.** 원본(`eks-reference-infra`)은
`docs/hub-lifecycle.md`·`docs/spoke-lifecycle.md`·`docs/runbooks.md` 세 문서가 그 역할을
한다. 이 repo는 `docs/`를 아직 포팅하지 않아(6절), 지금은 `.omc/plans/*.md`가 설계
근거와 착수 순서를 임시로 겸한다. `docs/` 포팅 후 운영 절차 부분만 그리로 이관한다.

## 1. 저장소 구조

```
bootstrap/              ✅ state Storage Account · App Registration · 커스텀 역할(IaC 밖, 사람이 스크립트로 실행)
live/hub/networking/    ✅ VNet(hub)
live/hub/vwan/          ✅ Virtual WAN(hub, networking과 분리된 state)
live/dev/networking/    ✅ VNet(spoke 첫 인스턴스), vWAN 스포크 연결 완료
live/hub/aks/           ⏳ Phase 2(iac-module-library에 aks 모듈 준비 전까지 생성하지 않음)
live/dev/aks/           ⏳ Phase 2(위와 동일)
.github/workflows/      배포 루트마다 워크플로 하나(plan은 push, apply/destroy는 workflow_dispatch)
docs/                   ⏳ 아직 없음(원본의 운영 절차 SSOT를 여기로 포팅 예정, 6절)
scripts/                ⏳ 아직 없음(원본의 `validate-doc-conventions.py` 등 포팅 예정, 4절)
```

같은 repo 안에서 `live/hub/*`와 `live/dev/*`는 **각자 별도 state**를 쓴다(같은 배포 루트
안의 다른 env). `live/hub/networking`과 `live/hub/vwan`도 서로 분리된 state다. 루트 간
결합은 `terraform_remote_state`가 아니라 **Name·태그 기반 `data` 조회**로 하거나(같은
구독 안), 크로스 구독인 경우 CI 변수로 리소스 ID를 명시 주입한다(`live/hub/vwan`의
`spoke_connections`, 근거는 `.omc/plans/live-hub-vwan-dev-networking.md` 4-3).

## 2. 실행 모델

| 항목 | 규칙 |
|------|------|
| 엔진 | OpenTofu(`tofu` 1.12.5), Terraform이 아니다 |
| backend | Azure Storage Account + Blob Container. `use_azuread_auth = true`, `allowSharedKeyAccess = false`(계정 키로 RBAC 우회 차단). 계정명은 git에 없다(GitHub 저장소 변수 `AZURE_HUB_*`/`AZURE_DEV_*` + 로컬 `backend.hcl`, 둘 다 git 밖) |
| state key | `<env>/<component>.tfstate`(예: `hub/vwan.tfstate`, `dev/networking.tfstate`) |
| 자격증명 | GitHub OIDC → 단일 App Registration(RG 스코프 커스텀 역할). AWS 원본의 "입구 Role → 실행 Role" 2단 체인을 Azure Entra ID로 그대로 재현할 수 없어, 대신 권한을 리소스 그룹 하나로 좁히고 6종 불변식(0건 또는 허용 목록 완전 일치)으로 검증한다. 설계 근거는 `bootstrap/README.md`·`.omc/plans/bootstrap-credential-design.md` |
| plan → apply | plan은 push에서 자동 실행, `workflow_dispatch`를 누르는 것 자체가 apply 승인이다 |
| 로컬에서 되는 것 | `init` + `validate`까지. **apply는 로컬에서 안 된다.** `require_oidc`/`var.ci_run` 가드가 `var.ci_run != true`이면 즉시 실패시킨다 |

⚠️ **재시도할 때 새 `workflow_dispatch`를 누르지 않는다.** 실패한 job이 apply라면
`gh run rerun <run-id> --failed`로 **저장된 plan을 그대로** 재적용한다. 새 dispatch는
plan을 처음부터 다시 돌려 승인한 것과 다른 계획을 만든다.

⛔ **`Microsoft.Authorization/roleAssignments/write`를 CI 신원에 자동으로 부여하지
않는다.** 그 권한이 부여되는 순간 CI 신원이 자기 자신에게 상위 역할을 부여할 수 있어
위 방어선 전체가 무의미해진다. Phase 2 AKS 배포가 이 권한을 요구하게 되면, 부여하기
전에 이 설계 자체를 재검토하는 트리거로 취급한다.

## 3. 네이밍·태깅

`Name` 포맷과 리소스 타입 약어는 `iac-module-library`의
`docs/naming/abbreviations/azure.md`가 SSOT다(임의 생성 금지, `rg`·`st`·`entapp`·
`vwan`·`vhub` 등재 완료). 이 repo에서 실제로 쓰는 값:

- `workload` = `demo`(고정, `live/hub`·`live/dev` 모두 반드시 동일해야 한다)
- `env` = `hub` 또는 `dev`(spoke 첫 인스턴스), `region` = `koreacentral`(`krc`)
- 예: `vnet-demo-hub-krc-main`, `vnet-demo-dev-krc-main`, `rg-demo-hub-krc-workload-01`

CIDR 배치(hub/dev VNet, Pod secondary 대역)는 `Name`처럼 재조합하는 값이 아니라 각
루트의 `main.tf` locals 주석이 실물 SSOT다. 설계 근거 전문(왜 스포크마다 Pod 대역이
다른가, Azure CNI Pod Subnet을 택한 이유)은
`.omc/plans/live-hub-vwan-dev-networking.md` 참고.

## 4. 로컬 게이트 (⏳ 아직 이식 안 됨)

원본(`eks-reference-infra`)은 `scripts/validate-doc-conventions.py` +
`tofu fmt`/`tflint`/`trivy`를 `.githooks/`(pre-commit/pre-push)로 강제한다. 이 repo는
`scripts/`·`.githooks/`를 아직 포팅하지 않아 이 게이트가 없다. `docs/` 포팅(6절)과
함께 진행할 후속 작업이다. 그때까지는 사람이 직접 `tofu fmt`·문서 규칙을 지킨다.

## 5. 브랜치·PR 규칙

| 변경 대상 | 경로 |
|-----------|------|
| **`.tf` · `.github/workflows/`** | **브랜치 → PR** |
| **문서 전용(`docs/*.md`·`CLAUDE.md`·`.omc/notepad.md`)** | **`main` 직접 커밋** |

원본과 동일한 기준: *"CI가 머지 전에 막아야 하는가"* 하나뿐이다. 각 워크플로는
`push: branches: [main]`에도 plan까지 돌므로 "PR이어야 CI가 돈다"는 성립하지 않는다.

⚠️ **2026-09-03 이전 커밋은 이 규칙 확정 전(1인 스캐폴딩 단계)이라 `.tf`·워크플로
변경도 전부 `main` 직접 push였다.** 이 규칙은 지금부터 적용한다. 과거 커밋을 소급
정정하지 않는다.

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
