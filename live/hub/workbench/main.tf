# live/hub/workbench — AKS 운영 workbench 배포 루트 (허브)
#
# iac-module-library 의 modules/azure/aks-workbench(aks-workbench-v0.1.0) 를 소비한다.
# 설계 전문(ADR·완료 판정·리스크)은 .omc/plans/live-hub-workbench.md 참조.
#
# ⚠️ 네트워킹은 live/hub/networking 이 소유한다. 이 root 는 이미 배포된 vm 서브넷을
#    Name 기반 data 로 조회만 한다 — 서브넷을 새로 만들지 않는다(CLAUDE.md 1절,
#    ⛔ terraform_remote_state 금지).
#
# ⚠️ identity·role assignment는 이 root가 Terraform으로 직접 만든다 — live/hub/aks가
#    2026-09-04에 세운 패턴과 동일(CI 신원이 구독 전체 Owner 등가라 구조적 제약 없음,
#    .omc/plans/bootstrap-credential-design.md 참조). aks-workbench 모듈 자체는 identity도
#    role assignment도 만들지 않는 경계 원칙을 그대로 유지한다(모듈 README 「신원」절).

locals {
  # 사람이 선생성한 워크로드 RG. 이 root 는 RG 를 만들지 않는다 — live/hub/aks·networking과
  # 동일 근거(파괴 반경 한정).
  resource_group_name = "rg-${var.workload}-${var.env}-${var.region_code}-workload-01"

  # azurerm 은 provider 레벨 default_tags 인자가 없어 여기서 명시 배선한다
  # (live/hub/aks·networking과 동일 근거).
  tags = {
    Environment = var.env
    Workload    = var.workload
    RegionCode  = var.region_code
    ManagedBy   = "opentofu"
    Repository  = var.repository
  }
}

# workbench VM 이 붙을 서브넷은 live/hub/networking 이 이미 만들어 뒀다(vm 그룹,
# nat_routed=true 포함). 같은 구독·같은 RG 라 추가 권한이 필요 없다. live/hub/aks의
# aks_node 서브넷 조회와 완전히 같은 패턴(live/hub/aks/main.tf).
data "azurerm_subnet" "vm" {
  name                 = "snet-${var.workload}-${var.env}-${var.region_code}-vm"
  virtual_network_name = "vnet-${var.workload}-${var.env}-${var.region_code}-main"
  resource_group_name  = local.resource_group_name
}

# 크로스 root 결합: role assignment 스코프에는 실제 리소스 ID가 필요해 Name 기반 data로
# hub AKS 클러스터를 조회한다(같은 RG, CLAUDE.md 1절 — terraform_remote_state 대신 data).
data "azurerm_kubernetes_cluster" "hub" {
  name                = "aks-${var.workload}-${var.env}-${var.region_code}-main-01"
  resource_group_name = local.resource_group_name
}

# role assignment 스코프용. RG 리소스 ID를 문자열로 직접 조립하지 않고 data로 조회해
# provider가 검증한 실물 ID를 쓴다(subscription_id 오타·형식 오류를 plan 단계에서 걸러낸다).
data "azurerm_resource_group" "workload" {
  name = local.resource_group_name
}

# workbench VM 이 쓰는 user-assigned managed identity. aks-workbench 모듈은 이걸 만들지
# 않고 입력으로만 받는다(모듈 경계 원칙) — 소비자인 이 root가 만들어 넘긴다.
resource "azurerm_user_assigned_identity" "workbench" {
  name                = "id-${var.workload}-${var.env}-${var.region_code}-workbench-01"
  resource_group_name = local.resource_group_name
  location            = var.location
  tags                = local.tags
}

# kubeconfig 부트스트랩(모듈 custom_data, README「AKS 연동」절)이 az aks get-credentials를
# VM 최초 부팅 시 1회 실행한다 — 이 role assignment가 그 전에 존재해야 한다. VM은 ForceNew라
# 재부팅으로는 재시도되지 않는다(README「부팅 후 확인」절).
resource "azurerm_role_assignment" "workbench_aks_cluster_user" {
  scope                            = data.azurerm_kubernetes_cluster.hub.id
  role_definition_name             = "Azure Kubernetes Service Cluster User Role"
  principal_id                     = azurerm_user_assigned_identity.workbench.principal_id
  skip_service_principal_aad_check = true
}

# Entra SSH 로그인 시 sudo 권한(모듈 README「전제 role assignment」표). 스코프는 VM 단위가
# 아니라 RG 단위 — Azure 플랫폼 자체의 최소 요구사항이다(MS Learn, 모듈 README 인용: "VM이
# 아니라 그 VM·NIC·공용 IP·NSG를 포함하는 리소스 그룹"), 이 root가 임의로 넓힌 게 아니다.
# principal_id가 사람(User) 객체라 skip_service_principal_aad_check는 쓰지 않는다(그
# 플래그는 서비스 프린시펄 전용 — azurerm provider 문서).
resource "azurerm_role_assignment" "workbench_admin_login" {
  scope                = data.azurerm_resource_group.workload.id
  role_definition_name = "Virtual Machine Administrator Login"
  principal_id         = var.admin_login_principal_id
}

module "aks_workbench" {
  # ⛔ 소싱 URL 은 git::https:// 하나로 유지한다(모듈 repo 규약).
  # ⛔ ?ref= 는 정확 태그 핀이다. git 소싱에 ~> 는 동작하지 않는다.
  source = "git::https://github.com/skax-ca/iac-module-library.git//modules/azure/aks-workbench?ref=aks-workbench-v0.1.0&depth=1"

  # 소비자는 리소스 타입 약어를 타이핑하지 않는다 — 모듈이 조합한다.
  # {demo, hub, krc} → vm-demo-hub-krc-workbench-01
  naming = {
    workload    = var.workload
    env         = var.env
    region_code = var.region_code
  }

  resource_group_name = local.resource_group_name
  location            = var.location

  subnet_id   = data.azurerm_subnet.vm.id
  identity_id = azurerm_user_assigned_identity.workbench.id

  # role assignment 순서 의존 명시(live/hub/aks/main.tf의 동일 클래스 문제와 같은 이유) —
  # 이게 없으면 kubeconfig 부트스트랩이 role assignment 전에 실행돼 조용히 실패할 수 있다.
  depends_on = [azurerm_role_assignment.workbench_aks_cluster_user]

  # ── 접속 모델 — SSH가 일상 경로, Run Command가 브레이크글래스 ────────────────────
  #
  # hub VNet에 VPN/ExpressRoute가 없어 모듈 README의 "레퍼런스(VPN 미보유)" 프로파일을
  # 쓴다: Public IP + 공인 IP 화이트리스트. ssh_ingress_cidrs는 유동 IP라 변수로 받는다
  # (기본값 없음, variables.tf 참고).
  ssh_ingress_cidrs = var.ssh_ingress_cidrs
  public_ip_enabled = true

  admin_ssh_public_key = file("${path.module}/workbench_ed25519.pub")

  # ── 이미지 — 재현성을 위해 정확한 버전을 핀(모듈이 "latest"를 거부한다) ─────────────
  # 2026-09-04 실측 최신값(az vm image list --location koreacentral --publisher Canonical
  # --offer ubuntu-24_04-lts --sku server --all).
  source_image_reference = {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "24.04.202608270"
  }

  # ── AKS 연동 — kubeconfig 부트스트랩만, RBAC은 로컬 계정 경로 ────────────────────
  # hub AKS(live/hub/aks)가 Entra RBAC를 켜지 않아(entra_admin_group_object_ids 미설정)
  # kubelogin 변환 단계가 필요 없다.
  aks_cluster_name        = data.azurerm_kubernetes_cluster.hub.name
  aks_resource_group_name = local.resource_group_name
  aks_entra_rbac_enabled  = false

  # ── 도구 — 전부 2026-09-04 실측 최신 안정 버전 ────────────────────────────────
  az_cli_version  = "2.88.0-1~noble"
  kubectl_version = "v1.37.0"
  helm_version    = "v4.2.4"
  argocd_version  = "v3.5.2"

  tags = local.tags
}
