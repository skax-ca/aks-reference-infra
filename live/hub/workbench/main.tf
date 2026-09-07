# live/hub/workbench — AKS 운영 workbench 배포 루트 (허브)
#
# iac-module-library 의 modules/azure/aks-workbench(aks-workbench-v0.3.0) 를 소비한다.
#
# ⚠️ 네트워킹은 live/hub/networking 이 소유한다. 이 root 는 이미 배포된 vm 서브넷을
#    Name 기반 data 로 조회만 한다 — 서브넷을 새로 만들지 않는다(CLAUDE.md 1절,
#    ⛔ terraform_remote_state 금지).
#
# ⚠️ identity·role assignment는 이 root가 Terraform으로 직접 만든다 — live/hub/aks와
#    같은 패턴이다(CI 신원이 구독 전체 Owner 등가라 구조적 제약 없음, config.sh의
#    관련 주석 참조). aks-workbench 모듈 자체는 identity도
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

# vm 서브넷에는 live/hub/networking이 이미 서브넷 레벨 NSG를 만들어 뒀다(vnet 모듈의
# nsg_enabled=true). 그 모듈은 규칙을 만들지 않는다 — "룰은 이 모듈이 만들지 않는다.
# 소비자가 azurerm_network_security_rule 별도 리소스로 얹는다"(vnet 모듈 main.tf 주석) —
# 그래서 지금은 커스텀 규칙이 0개다. 이 root가 그 소비자다(아래 azurerm_network_security_rule).
#
# ⚠️ vm 서브넷은 workbench 전용이 아니다(live/hub/networking 주석: "관리·workbench VM") —
# 이 규칙은 이 서브넷에 붙는 모든 VM에 적용된다(NIC 레벨이 아니라 서브넷 레벨이라
# 구조적으로 그렇다). 나중에 이 서브넷에 다른 관리 VM이 추가되면 그 VM도 같은
# ssh_ingress_cidrs를 물려받는다는 뜻 — 의도된 트레이드오프이지 결함이 아니다(서브넷
# 자체가 "관리 전용" 용도로 분리돼 있어 워크로드 트래픽과 섞이지 않는다). 우선순위
# 100-199는 이 root가 예약한다 — live/hub/networking이나 다른 소비자가 이 NSG에 규칙을
# 더 얹을 땐 이 범위를 피해야 충돌(우선순위 중복은 apply 시점 Azure API 에러) 없다.
data "azurerm_network_security_group" "vm_subnet" {
  name                = "nsg-${var.workload}-${var.env}-${var.region_code}-vm"
  resource_group_name = local.resource_group_name
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

# skip_service_principal_aad_check(위)는 role assignment "생성" 시점의 AAD 존재 확인만
# 우회한다 — 생성된 role이 실제 인가 판단(authorization)에 반영되기까지의 캐시 전파
# 지연은 별개다(이 repo가 이미 여러 차례 실측한 클래스, config.sh의
# retry_on_replication_delay 관련 주석 참고 — "역할 정의 AssignableScopes 변경 직후
# role assignment 생성이 거부" 등). VM의 custom_data는 provider 스키마상 ForceNew라
# cloud-init이 최초 부팅 시 1회만 az aks get-credentials를 실행하고 재시도가 없다
# (aks-workbench 모듈 README「부팅 후 확인」절) — 이 유예 없이 실패하면 VM 재생성이
# 유일한 복구 경로가 된다. 첫 apply 한정 비용(60초)으로 그 리스크를 피한다.
resource "time_sleep" "role_propagation" {
  depends_on      = [azurerm_role_assignment.workbench_aks_cluster_user]
  create_duration = "60s"
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

# NIC 레벨 NSG(module.aks_workbench가 만드는 AllowSsh)만으로는 부족하다 — 인터넷發
# 인바운드는 AllowVNetInBound(플랫폼 기본 규칙)가 커버하지 않아, 서브넷 레벨 NSG의
# 커스텀 규칙이 0개인 지금은 플랫폼 기본 DenyAllInBound(65500)가 여기서 먼저 막는다.
# 2026-09-04 실측: 이 규칙 없이 apply한 직후 SSH가 전부 타임아웃됨(TCP 자체가 상대편에
# 도달 못함, NIC NSG 로그에는 아예 안 잡히는 것으로 실측 — 서브넷 레벨에서 끊긴 것과
# 정합). workbench_enabled·ssh_ingress_cidrs가 비면(순수 Run Command 프로파일) 이 구멍
# 자체를 만들지 않는다.
resource "azurerm_network_security_rule" "vm_subnet_allow_ssh" {
  count = var.workbench_enabled && length(var.ssh_ingress_cidrs) > 0 ? 1 : 0

  name                        = "AllowSshFromWorkbench"
  priority                    = 100
  direction                   = "Inbound"
  access                      = "Allow"
  protocol                    = "Tcp"
  source_port_range           = "*"
  destination_port_range      = "22"
  source_address_prefixes     = var.ssh_ingress_cidrs
  destination_address_prefix  = "*"
  resource_group_name         = local.resource_group_name
  network_security_group_name = data.azurerm_network_security_group.vm_subnet.name
}

module "aks_workbench" {
  # ⛔ 소싱 URL 은 git::https:// 하나로 유지한다(모듈 repo 규약).
  # ⛔ ?ref= 는 정확 태그 핀이다. git 소싱에 ~> 는 동작하지 않는다.
  #
  # v0.2.0으로 올린 이유: v0.1.0의 custom_data가 apt-get 락 경합 시 재시도 없이
  # 실패해(2026-09-04 첫 실배포 실측 — "Could not get lock /var/lib/dpkg/lock-frontend")
  # az CLI 설치·kubeconfig 부트스트랩이 연쇄 실패했다.
  #
  # v0.3.0으로 올린 이유: v0.2.0은 az aks get-credentials가 root(cloud-init)로 실행돼
  # kubeconfig가 /root/.kube/config에만 생기고 실제 로그인 계정(admin_username)에는
  # 없어 sudo 없이는 kubectl을 못 썼다(2026-09-04 실측). 이 root가 admin_username을
  # 오버라이드하지 않아 모듈 기본값 "azureuser"를 그대로 쓰므로, admin_username 하나에만
  # 사용자별 kubeconfig 사본이 자동 배포된다. Entra SSH 계정에는 자동으로 안 준다
  # (모듈 code-review 2라운드로 발견한 보안 회귀 — 로그인 역할 2단계 구분이 무너지는
  # 문제, iac-module-library PR #45 참고).
  #
  # custom_data는 ForceNew라 이 버전 변경 자체가 VM 재생성을 유발한다 — 의도된 것
  # (9절 사고 기록 참고).
  #
  # v0.4.0으로 올린 이유: 2026-09-07 실측 — AWS 원본 modules/aws/workbench/
  # user-data.sh.tftpl과 대조한 결과, kubectl·helm·argocd·krew를 설치는 했지만
  # /etc/profile.d 로그인 프로파일 블록 자체가 없어 k alias·kubectl completion·
  # KREW_ROOT PATH가 전혀 안 잡혀 있었다. v0.4.0이 그 블록을 신설했다.
  #
  # v0.5.0으로 올린 이유: v0.4.0을 이 root에 처음 실제 적용하면서(krew_version을
  # 이 root가 그날 처음 넘김) krew install이 "unknown flag: --krew-root"로 실패하는
  # 것을 실측 발견 — krew는 그 플래그를 지원하지 않는다(공식 문서 확인, KREW_ROOT
  # 환경변수만으로 충분). v0.5.0이 그 플래그를 제거했다.
  source = "git::https://github.com/skax-ca/iac-module-library.git//modules/azure/aks-workbench?ref=aks-workbench-v0.5.0&depth=1"

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
  # time_sleep을 거치는 이유는 위 time_sleep.role_propagation 주석 참고(AAD 전파 지연).
  depends_on = [time_sleep.role_propagation]

  # 모듈이 설계한 kill switch(파괴 방향, README: "수시 생성·파기가 정상 운용") — VM만
  # 다시 만들고 싶을 때 identity·role assignment까지 건드리는 전체 CI destroy 없이
  # 이 값 하나로 끝내려고 변수로 연다(기본값 true, variables.tf 참고).
  workbench_enabled = var.workbench_enabled

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

  # 2026-09-07 실측(gh api repos/.../releases) 추가 — 이전까지 이 root가 아예 안 넘겨서
  # krew·aks-node-viewer가 설치조차 안 되고 있었다(모듈은 v0.3.0부터 이미 지원, 소비자
  # 누락). krew_plugins는 모듈 기본값(ctx·ns·neat·rbac-tool·view-secret·whoami)을 그대로 쓴다.
  krew_version = "v0.5.0"
  # ⚠️ Azure/aks-node-viewer는 2024-11-10 이후 갱신 없는 alpha 단계(모듈 변수 설명 경고).
  # 설치 실패는 부팅을 막지 않는다(모듈 자체가 || true로 감쌈).
  aks_node_viewer_version = "v0.0.2-alpha"

  tags = local.tags
}
