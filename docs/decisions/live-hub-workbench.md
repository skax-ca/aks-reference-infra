# live/hub/workbench - AKS 운영 workbench 배포 루트 설계

**상태**: 배포 완료. hub 구독에 실제 가동 중 — SSH 로그인(sudo 없이 kubectl 사용
가능)·k alias·krew 플러그인·helm/argocd/az CLI 전부 실측 검증 통과(`aks-workbench-v0.5.0`
소비). 첫 실배포 이후 발견한 버그(9절)는 전부 수정·재적용 완료.
**범위**: hub 구독에 `iac-module-library`의 `aks-workbench` 모듈을 소비하는
새 배포 루트. `live/hub/aks`(`aks-demo-hub-krc-main-01`)의 일상 운영 지점(SSH·kubectl·helm·
argocd·az CLI)을 만든다.
**범위 밖**: GUI 데스크톱 workbench(Ubuntu Desktop+xfce4+Firefox + Azure Bastion Standard
SKU 전용 서브넷 - 상시 과금이 발생하고 AWS 원본의 "CLI 전용, GUI 없음" 철학과 이질적이라
후순위로 밀린 안), `live/dev/aks`용 workbench(dev 인스턴스 자체가 아직 없음), Bastion.

## 0. 검증 절차 근거

CLAUDE.md의 신규 배포 루트 절차(deepinit→plan→ralplan→team→verify) 중 이 문서는 `/plan`
표준 모드로 작성했다(ralplan 아님) - 사용자 확정(2026-09-04, AskUserQuestion). 근거: 모듈
자체의 아키텍처 설계(접속 모델·NSG·신원 경계)는 `iac-module-library`에서 RALPLAN-DR 5회로
이미 끝났고(`aks-workbench-v0.1.0`), 이 root는 그 모듈을 소비하는 작업이라 `live/hub/aks`가
필요로 했던 수준의 재설계 검증 대상이 아니다.

## 1. 이미 확정된 조건 (재조사 불필요, 근거 인용)

- **모듈 경계 원칙**: `aks-workbench`는 identity·role assignment·서브넷·RG를 만들지 않고
  전부 입력으로 받는다(`iac-module-library/modules/azure/aks-workbench/README.md:6-8`).
  `aks-cluster`와 동일 원칙 - `live/hub/aks/main.tf:70-95`가 이미 이 repo에서 그 원칙을
  따른 선례다.
- **배치**: `live/hub/networking`이 이미 `vm` 서브넷을 예약해 뒀다
  (`live/hub/networking/main.tf:47,90-95` - `10.60.2.0/24`, `nat_routed=true`,
  `nsg_enabled=true`). 신규 서브넷을 만들지 않는다.
- **RG**: `rg-demo-hub-krc-workload-01` (hub workload RG, `live/hub/aks/main.tf:43`와 동일 값).
- **hub AKS는 Entra RBAC를 켜지 않았다**: `live/hub/aks/main.tf`의 `module.aks_cluster` 호출에
  `entra_admin_group_object_ids` 인자가 없다 → 클러스터는 로컬 계정 인증 경로만 갖는다 →
  workbench의 `aks_entra_rbac_enabled = false`, `identity_client_id` 불필요, `kubelogin`
  변환 단계 없음(모듈 `variables.tf:292-313`의 교차 validation 대상 밖).
- **private DNS 도달성 전제조건은 이미 충족**: `aks-cluster` 모듈이 `private_dns_zone_id`를
  지정하지 않아 Azure 기본값(`System`)이 hub VNet 전체에 자동 링크된다(`az network
  private-dns zone list`로 재확인 가능) - `vm` 서브넷이 `aks-node`와 같은 VNet이라 모듈
  README의 "DNS 해석" 절(`README.md:125-145`) 1번 케이스에 해당, 추가 조치 불필요.
- **CI 신원은 구독 전체 Owner 등가다**(`docs/decisions/bootstrap-credential-design.md`
  참고) → identity·role assignment는 bootstrap이 아니라 이 root가 Terraform으로 직접
  만든다 - `live/hub/aks`가 세운 패턴(`live/hub/aks/main.tf:70-95`)을 그대로
  승계한다.
- **hub 구독**: `57bb4b4a-6916-4c2d-9446-f908ba60e7d0`(`az account show` 실측, `rg-demo-hub-
  krc-workload-01` 존재로 hub임을 교차 확인 - dev 구독엔 이 RG가 없음).
- **사용자 Entra objectId**: `b8d644f4-06fb-4392-a71a-cb78d5b9f9c3`(`az ad signed-in-user
  show` 실측, `조경민`) - SSH 로그인 권한을 부여할 대상.

## 2. 사용자 결정 (AskUserQuestion, 2026-09-04)

- **SSH 접속 모델**: 레퍼런스 프로파일(모듈 README 표의 "VPN 미보유" 행) - hub VNet에
  VPN/ExpressRoute가 없음(`live/hub/networking/main.tf` 전체 확인, P2S/S2S 게이트웨이 없음).
  `public_ip_enabled = true`, `ssh_ingress_cidrs = ["211.45.60.3/32"]`(사용자 현재 공인 IP,
  `curl ifconfig.me` 실측), `entra_ssh_login_enabled = true`(모듈 기본값 유지).
- **검증 강도**: `/plan` 표준(0절 근거).

## 3. 신규로 실측·확정한 값

| 항목 | 값 | 근거 |
|---|---|---|
| VM 이미지 | `Canonical:ubuntu-24_04-lts:server:24.04.202608270` | `az vm image list --location koreacentral --publisher Canonical --offer ubuntu-24_04-lts --sku server --all` 실측 최신값(2026-09-04). `version="latest"`는 모듈이 거부한다(`variables.tf:214-218`). |
| `az_cli_version` | `2.88.0-1~noble` | `packages.microsoft.com/repos/azure-cli/dists/noble/main/binary-amd64/Packages` 실측 최신값. 모듈 권고 하한 2.72.0 충족(`README.md:319-322`). |
| `kubectl_version` | `v1.37.0` | `dl.k8s.io/release/stable.txt` 실측. |
| `argocd_version` | `v3.5.2` | GitHub 최신 릴리스 리다이렉트 실측. |
| `helm_version` | `v4.2.4` | 구현 착수 시 재조회로 확정(2026-09-04, 앞서 rate limit로 막혔던 조사를 리다이렉트 방식으로 재시도해 성공 - GitHub 최신 stable, prerelease 아님). |

## 4. `.tf` 구현 설계

### 4-1. 파일 구성 (`live/hub/workbench/`)

`live/hub/aks/`와 동일한 6파일 구조를 그대로 복제한다: `main.tf`·`variables.tf`·
`providers.tf`·`versions.tf`·`outputs.tf`·`backend.tf`(+`backend.hcl.example`).

### 4-2. `main.tf` - locals·data·identity·role assignment·module 순서

```hcl
locals {
  resource_group_name = "rg-${var.workload}-${var.env}-${var.region_code}-workload-01"
  tags = {
    Environment = var.env
    Workload    = var.workload
    RegionCode  = var.region_code
    ManagedBy   = "opentofu"
    Repository  = var.repository
  }
}

# vm 서브넷은 live/hub/networking이 이미 만들어 뒀다(main.tf:90-95) - Name 기반 data
# 조회(CLAUDE.md 1절, ⛔ terraform_remote_state 금지). live/hub/aks의 aks_node 조회와
# 완전히 같은 패턴(live/hub/aks/main.tf:64-68).
data "azurerm_subnet" "vm" {
  name                 = "snet-${var.workload}-${var.env}-${var.region_code}-vm"
  virtual_network_name = "vnet-${var.workload}-${var.env}-${var.region_code}-main"
  resource_group_name  = local.resource_group_name
}

# 크로스 root 결합: role assignment 스코프에 실제 리소스 ID가 필요해 Name 기반 data로
# hub AKS 클러스터를 조회한다(같은 RG). aks_cluster_name/aks_resource_group_name 입력값
# 자체는 naming 토큰으로 재조합해도 되지만(문자열 보간), role assignment의 scope는
# 문자열 조립이 아니라 실물 리소스 ID여야 하므로 data가 필요하다.
data "azurerm_kubernetes_cluster" "hub" {
  name                = "aks-${var.workload}-${var.env}-${var.region_code}-main-01"
  resource_group_name = local.resource_group_name
}

resource "azurerm_user_assigned_identity" "workbench" {
  name                = "id-${var.workload}-${var.env}-${var.region_code}-workbench-01"
  resource_group_name = local.resource_group_name
  location            = var.location
  tags                = local.tags
}

# kubeconfig 부트스트랩(모듈 custom_data, README.md:192-202)이 az aks get-credentials를
# VM 최초 부팅 시 1회 실행한다 - 이 role assignment가 그 전에 존재해야 한다
# (live/hub/aks/main.tf:126-130과 동일 클래스의 순서 의존, 아래 module 블록의 depends_on 참고).
resource "azurerm_role_assignment" "workbench_aks_cluster_user" {
  scope                            = data.azurerm_kubernetes_cluster.hub.id
  role_definition_name             = "Azure Kubernetes Service Cluster User Role"
  principal_id                     = azurerm_user_assigned_identity.workbench.principal_id
  skip_service_principal_aad_check = true
}

# Entra SSH 로그인 시 sudo 권한(모듈 README.md:171 표). 스코프는 VM 단위가 아니라 RG
# 단위 - Azure 플랫폼 자체의 최소 요구사항이다(README.md:171 "MS Learn" 인용,
# "VM이 아니라 그 VM·NIC·공용 IP·NSG를 포함하는 리소스 그룹"), 이 root가 임의로 넓힌
# 것이 아니다. principal_id가 사람(User) 객체라 skip_service_principal_aad_check는
# 안 쓴다(그 플래그는 서비스 프린시펄 전용 - azurerm provider 문서).
resource "azurerm_role_assignment" "workbench_admin_login" {
  scope                = data.azurerm_resource_group.workload.id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = var.admin_login_principal_id
}
```

구현 단계에서 스코프를 문자열 수동 조립 대신 `data "azurerm_resource_group" "workload"` 조회로
바꿨다(provider가 검증한 실물 ID를 쓰는 게 더 안전 - `subscription_id` 오타·형식 오류를 plan
단계에서 걸러낸다). 아래 module 블록 앞에 이 data 선언이 추가된다:

```hcl
data "azurerm_resource_group" "workload" {
  name = local.resource_group_name
}

module "aks_workbench" {
  source = "git::https://github.com/skax-ca/iac-module-library.git//modules/azure/aks-workbench?ref=aks-workbench-v0.1.0&depth=1"

  naming               = { workload = var.workload, env = var.env, region_code = var.region_code }
  resource_group_name  = local.resource_group_name
  location             = var.location

  subnet_id   = data.azurerm_subnet.vm.id
  identity_id = azurerm_user_assigned_identity.workbench.id

  depends_on = [azurerm_role_assignment.workbench_aks_cluster_user]

  # ── 접속 모델 (2절 사용자 결정) ──────────────────────────────────────────
  ssh_ingress_cidrs = var.ssh_ingress_cidrs
  public_ip_enabled = true

  admin_ssh_public_key = file("${path.module}/workbench_ed25519.pub")

  # ── 이미지 (3절 실측값) ──────────────────────────────────────────────────
  source_image_reference = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "24.04.202608270"
  }

  # ── AKS 연동 ────────────────────────────────────────────────────────────
  aks_cluster_name        = data.azurerm_kubernetes_cluster.hub.name
  aks_resource_group_name = local.resource_group_name
  aks_entra_rbac_enabled  = false

  # ── 도구 (3절 실측값, helm_version은 구현 시점 재확인 후 채움) ─────────────
  az_cli_version  = "2.88.0-1~noble"
  kubectl_version = "v1.37.0"
  helm_version    = "REPLACE_AT_IMPLEMENTATION"
  argocd_version  = "v3.5.2"

  tags = local.tags
}
```

### 4-3. `variables.tf` - `live/hub/aks/variables.tf`와 동일 골격 + 신규 2종

`workload`·`env`·`region_code`·`location`·`repository`·`subscription_id`·`require_oidc`·
`ci_run`은 `live/hub/aks/variables.tf`를 그대로 복제(기본값 포함 - 이 root도 hub 단일
환경이라 `env` 기본값 `"hub"` 유지). 신규:

```hcl
variable "ssh_ingress_cidrs" {
  description = <<-EOT
    SSH(22/tcp) 인바운드를 허용할 CIDR 목록. 사무실/재택 공인 IP는 시간에 따라 바뀌므로
    subscription_id와 같은 이유로 git에 기본값을 두지 않는다 - CI는 repo 변수(JSON 배열
    문자열), 로컬은 TF_VAR_ssh_ingress_cidrs로 주입한다.
  EOT
  type = list(string)
}

variable "admin_login_principal_id" {
  description = <<-EOT
    Virtual Machine Administrator Login 역할을 받을 Entra 계정(사람)의 objectId.
    subscription_id와 같은 이유로 git에 기본값을 두지 않는다.
  EOT
  type = string
}
```

### 4-4. `providers.tf`·`versions.tf`·`backend.tf`

`live/hub/aks`와 완전히 동일하게 복제한다(provider 인증·`require_oidc_guard`·terraform
블록 전부 이 root 고유의 변경 사유가 없다). `backend.tf`의 `key`만
`"hub/workbench.tfstate"`로 바꾼다(CLAUDE.md 2절 state key 규칙).

### 4-5. `outputs.tf`

```hcl
output "workbench_private_ip" {
  value = module.aks_workbench.workbench_private_ip
}
output "workbench_public_ip" {
  value = module.aks_workbench.workbench_public_ip
}
```

### 4-6. SSH 키페어 - 실행 시점 절차 (계획에 값을 미리 만들어 넣지 않는다)

1. `ssh-keygen -t ed25519 -f ~/.ssh/workbench_ed25519 -C "workbench@aks-reference-infra"`
   (private key는 `~/.ssh/`에만 존재, git에 절대 넣지 않는다 - `backend.hcl`과 같은
   git-밖 관리 원칙).
2. `~/.ssh/workbench_ed25519.pub`을 `live/hub/workbench/workbench_ed25519.pub`로 복사해
   커밋한다 - **공개키는 비밀이 아니다**(정의상 공개해도 안전), `.gitignore` 예외 대상.

### 4-7. CI 워크플로 - `.github/workflows/deploy-hub-workbench.yml`

`deploy-hub-aks.yml`을 그대로 복제하고 다음만 바꾼다:

- `TF_ROOT: live/hub/workbench`
- `concurrency.group: live-hub-workbench`
- `paths: [live/hub/workbench/**, .github/workflows/deploy-hub-workbench.yml]`
- `backend.hcl` 조립 스텝의 `key = "hub/workbench.tfstate"`
- `env:` 블록에 신규 2종 추가:
  ```yaml
  TF_VAR_ssh_ingress_cidrs: ${{ vars.AZURE_HUB_WORKBENCH_SSH_CIDRS }}
  TF_VAR_admin_login_principal_id: ${{ vars.AZURE_HUB_WORKBENCH_ADMIN_OBJECT_ID }}
  ```

**사람이 apply 전에 끝내야 하는 사전조건**(`live/hub/aks`가 RP 등록을 요구했던 것과 같은
클래스, `deploy-hub-aks.yml:11-14` 패턴):

1. GitHub repo 변수 신설: `AZURE_HUB_WORKBENCH_SSH_CIDRS = ["211.45.60.3/32"]`(JSON 배열
   문자열 그대로), `AZURE_HUB_WORKBENCH_ADMIN_OBJECT_ID = "b8d644f4-06fb-4392-a71a-cb78d5b9f9c3"`.
   둘 다 비밀이 아니다(공인 IP·objectId는 `AZURE_HUB_CLIENT_ID`와 같은 급의 식별자) -
   `secrets`가 아니라 `vars`로 등록한다.
2. `~/.ssh/workbench_ed25519.pub` 생성 + 커밋(4-6절).

## 5. 브랜치·PR

CLAUDE.md 5절: `.tf`·`.github/workflows/`는 브랜치→PR. 이 작업 전체가 여기 해당한다
(공개키 파일도 `.tf` 변경과 같은 커밋 단위로 묶어 PR 하나로 처리 - 별도 분리할 이유 없음).
현재 `main`이 origin과 정확히 동기화된 상태(2026-09-04 세션 시작 시 확인)에서 새 브랜치를
딴다. `feat/alb-controller-iam`(별도 미병합 작업)과는 독립이다.

## 6. Acceptance Criteria

- [ ] `tofu validate`가 `live/hub/workbench`에서 통과한다(로컬, `require_oidc=false` 명시).
- [ ] CI `plan` job이 `0 add`가 아닌 실제 리소스 생성 계획을 보고한다(첫 apply이므로 정확한
      개수는 identity 1 + role assignment 2 + module 내부 리소스 7종 = 10 전후 - module
      README `Resources` 표 기준 최소 7개).
- [ ] `workflow_dispatch` apply 성공 후 재-plan이 `No changes`로 수렴한다(`live/hub/aks`의
      완료 판정과 동일 기준, perpetual diff 없음을 확인).
- [ ] `ssh -i ~/.ssh/workbench_ed25519 azureuser@<public_ip>` 또는 `az ssh vm --resource-group
      rg-demo-hub-krc-workload-01 --name vm-demo-hub-krc-workbench-01`(Entra SSH)로 실제
      로그인 성공.
- [ ] 로그인 후 `kubectl get nodes`가 hub AKS 노드 2대를 정상 출력(private API 도달성 +
      역할 배정 + kubeconfig 부트스트랩 3개 축이 전부 성립했다는 실물 증거).
- [ ] `cloud-init status --wait` exit 0, `/var/log/cloud-init-output.log`에 도구 설치 실패
      로그 없음(4-7절 도구 버전 4종 전부 부팅 시 정상 설치 확인).
- [ ] `az network nsg rule list --nsg-name nsg-demo-hub-krc-workbench-01`로 `DenyAllInbound`(4096)와
      `AllowSsh`(100, 사용자 CIDR만) 두 규칙만 실제로 존재함을 확인(NIC 레벨, 모듈 README NSG 절
      주장의 실물 검증).
- [ ] `az network nsg rule list --nsg-name nsg-demo-hub-krc-vm`로 서브넷 레벨 NSG에도
      `AllowSshFromWorkbench`(100, 사용자 CIDR만) 규칙이 존재함을 확인 - 이게 없으면 NIC 레벨
      규칙이 아무리 맞아도 SSH가 안 된다(2026-09-04 사고, 아래 9절 참고). **NIC 레벨만 확인하고
      "규칙 2종 확인됨"이라 판정하지 않는다** - 이 체크리스트가 실제로 그 실수를 한 번 냈다.

## 7. Risks and Mitigations

| 리스크 | 완화 |
|---|---|
| 사용자 공인 IP(`211.45.60.3`)가 유동 IP라 바뀌면 SSH가 즉시 막힌다 | `ssh_ingress_cidrs`는 변수라 `tfvars`/repo 변수 갱신 후 재적용으로 회복 가능(VM 재생성 불필요, NSG 규칙만 갱신). Entra SSH 경로가 살아있으면 `az ssh vm`이 네트워크 자체는 여전히 막혀 있어 대안이 못 된다는 점 인지 - 완전히 막히면 `az vm run-command`(브레이크글래스)로 NSG 규칙을 긴급 갱신. |
| `helm_version` 미확정 값(`REPLACE_AT_IMPLEMENTATION`)을 그대로 커밋하면 `custom_data`가 깨진다 | 구현 착수 시 최우선으로 재조회해 채운다(3절) - 이 값이 남아있으면 리뷰에서 반려 대상. |
| role assignment 순서 의존(`depends_on`) 누락 시 kubeconfig 부트스트랩이 조용히 실패 | 4-2절 `depends_on`을 반드시 포함 - `live/hub/aks`가 이미 겪은 클래스의 버그(`main.tf:126-130` 주석)를 그대로 재현하지 않도록 코드 리뷰에서 확인. |
| `admin_login_principal_id`를 RG 스코프로 주면 향후 이 RG에 추가되는 다른 VM에도 로그인 권한이 함께 열린다 | Azure의 구조적 최소 스코프가 RG다(모듈 README 실측 인용) - 이 root가 임의로 넓힌 게 아니다. 다른 VM이 이 RG에 추가되는 시점에 재검토(지금은 workbench가 유일한 VM). |
| 이미지 버전(`24.04.202608270`)이 몇 주 뒤 실제 apply 시점엔 새 빌드로 대체돼 조회 결과가 달라질 수 있음 | 문제 없음 - Marketplace 이미지는 특정 버전을 계속 조회 가능(deprecation 없이 유지), 핀한 버전 그대로 apply된다. 재현성이 목적이라 최신값 추종이 목표가 아니다. |

## 8. Verification Steps (실행 후)

1. `tofu -chdir=live/hub/workbench validate` (로컬)
2. CI `plan` job 실행(push) → `plan.txt`에서 생성 리소스 개수·타입 확인
3. `workflow_dispatch apply` 승인
4. apply 후 재-plan 수렴 확인(워크플로 자체 스텝)
5. `az vm boot-diagnostics get-boot-log` → `cloud-init-output.log` 확인
6. 실제 SSH 로그인 + `kubectl get nodes` + `helm version`/`argocd version --client`/`az version`
7. `az network nsg rule list --resource-group rg-demo-hub-krc-workload-01 --nsg-name <workbench nsg>`로 규칙 2종만 확인

## 9. 2026-09-04 추가 기록 - 첫 실배포 사고 2건

PR #7 머지·apply 후 실제 SSH 접속 시도 중 계획에서 놓쳤던 것 2가지가 실측으로
드러났다.

**사고 1 - 서브넷 레벨 NSG 누락(PR #8로 수정)**: 이 계획은 `aks-workbench` 모듈이
만드는 NIC 레벨 NSG(`AllowSsh`)만 검토했다. 그런데 `live/hub/networking`이 `vm`
서브넷에 이미 만들어 둔 **서브넷 레벨 NSG**(`nsg-demo-hub-krc-vm`)는 vnet 모듈
설계상("룰은 이 모듈이 만들지 않는다") 커스텀 규칙이 0개였다 - 인터넷發 인바운드는
`AllowVNetInBound`(플랫폼 기본)가 커버 안 해 `DenyAllInBound`(65500)에 먼저 막혀
SSH가 전부 `Operation timed out`. 두 NSG(서브넷 레벨 + NIC 레벨) 모두 허용해야
트래픽이 통과한다는 걸 계획 단계에서 확인 못했다 - `azurerm_subnet.nsg_enabled`가
서브넷별로 별도 NSG를 만든다는 사실 자체를 놓쳤다. `live/hub/workbench/main.tf`에
`azurerm_network_security_rule.vm_subnet_allow_ssh`(우선순위 100-199 예약)를
추가해 해결.

**사고 2 - az CLI 설치 실패(iac-module-library PR #44로 수정)**: cloud-init 로그
실측 결과 `apt-get install -y azure-cli=...`가 `Could not get lock
/var/lib/dpkg/lock-frontend`로 실패 - 부팅 초반 cloud-init 자신의 다른 백그라운드
apt 프로세스와 경합. 스크립트에 `set -e`가 없어 이 실패가 조용히 넘어가고 뒤이은
`az login`·`az aks get-credentials`까지 연쇄 실패, kubeconfig가 아예 안 만들어졌다
(kubectl/helm/argocd는 이 블록과 독립이라 정상 설치돼 실패가 안 보였음). 모듈의
`cloud-init.sh.tftpl`에 `-o DPkg::Lock::Timeout=180`을 모든 `apt-get` 호출에
추가해 해결(`aks-workbench-v0.2.0`).

**교훈**: (1) 모듈 README가 검증했다고 주장하는 것(NIC 레벨 NSG)과 실제 트래픽이
거치는 전체 경로(서브넷 레벨까지)는 다를 수 있다 - "이 계층만 확인하면 된다"는
가정을 실물 배포 전에 다시 확인할 것. (2) cloud-init 스크립트에 `set -e`가 없으면
부분 실패가 "성공"으로 보고된다 - `cloud-init status --wait` exit 0만으로 완료
판정하지 말고 boot log 내용(특히 실패 문자열: `E: `, `command not found`)까지
직접 확인해야 한다는 게 이번 사고로 실측 확인됨.
