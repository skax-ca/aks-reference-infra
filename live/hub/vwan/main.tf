# live/hub/vwan — Virtual WAN 배포 루트 (허브, TGW 대응)
#
# AWS 원본(eks-reference-infra의 live/hub/tgw)과 같은 이유로 live/hub/networking과
# 분리된 별도 state다 — TGW/vWAN이 그 root와 같은 apply에서 생기면, 거기 붙는 spoke
# 연결을 자동 발견하는 for_each가 "허브 ID가 plan 시점에 unknown"이라 실패할 여지가
# 있다. 허브를 먼저 이 root로 세워두면 하류(dev)가 이미 존재하는 실물로 참조할 수
# 있다 — "레이어로 키운다"는 이 repo의 일반 원칙과 같은 이유다(live/hub/tgw/main.tf
# 참고).
#
# ⛔ 모듈을 쓰지 않는다. AWS 원본의 live/hub/tgw도 raw aws_ec2_transit_gateway
# 리소스였다(모듈화 안 함). iac-module-library의 Azure 모듈은 vnet·aks-cluster
# 뿐이고, 이 repo는 모듈 자체를 만들지 않는다(CLAUDE.md 서두). 소비자가 vWAN 허브
# 하나뿐이라 모듈화의 값(재사용)도 없다.

locals {
  # ⚠️ vHub 주소 공간은 생성 후 변경 불가하다(learn.microsoft.com/en-us/azure/
  # virtual-wan/hub-settings). 최소는 /24, 권장은 /23이지만 vWAN 안에 Azure Firewall을
  # 두는 경우(Secured Virtual Hub) 최소 /22가 요구된다 — Firewall 배포 여부가 아직
  # 미결이므로 나중에 선택지를 남기는 값으로 지금 잡는다. 사설 대역에서 /22와 /23의
  # 비용 차이는 0이다.
  vhub_address_prefix = "10.62.0.0/22"

  # azurerm 은 provider 레벨 default_tags 인자가 없어 여기서 명시 배선한다
  # (live/hub/networking/main.tf와 동일 근거, vnet 모듈 README 확인).
  tags = {
    Environment = var.env
    Workload    = var.workload
    RegionCode  = var.region_code
    ManagedBy   = "opentofu"
    Repository  = var.repository
  }
}

# hub VNet은 이 root가 만들지 않는다(live/hub/networking 소유) — 같은 구독·같은 RG를
# data source로 참조한다. 추가 권한이 필요 없다(CI 신원이 이미 이 RG에 전권을 가짐).
data "azurerm_resource_group" "workload" {
  name = "rg-${var.workload}-${var.env}-${var.region_code}-workload-01"
}

data "azurerm_virtual_network" "hub" {
  name                = "vnet-${var.workload}-${var.env}-${var.region_code}-main"
  resource_group_name = data.azurerm_resource_group.workload.name
}

# 스포크(dev) VNet 자동 발견 — 2026-09-08, CI 변수 주입(휘발성 workflow_dispatch
# input)에서 태그 기반 data source 조회로 교체. AWS 원본(eks-reference-infra의
# live/hub/tgw)이 spoke attachment를 태그로 자동 발견하는 것과 같은 패턴이다.
# `azurerm_resources`는 대상이 없으면 하드 에러가 아니라 빈 리스트를 반환한다
# (registry.terraform.io hashicorp/azurerm docs/d/resources.html.markdown의
# Example Usage 자체가 "타입+태그로 spoke VNet을 찾아 peering" 시나리오다) — dev가
# 아직 없어도 이 root는 스포크 연결 0개로 정상 apply된다. dev networking이 생긴
# 뒤 이 root를 한 번 더 apply하면 자동으로 발견해 연결이 생긴다(AWS 원본의 "hub
# networking 재적용" 단계와 대칭, docs/hub-lifecycle.md 4절 참고).
#
# 필요 권한은 dev 구독의 virtualNetworks/read 하나뿐이다(bootstrap.sh
# BOOTSTRAP_TARGET=spoke가 spoke-peer 역할에 peer/action과 나란히 부여, 2026-09-08).
data "azurerm_resources" "dev_spoke_vnets" {
  provider = azurerm.dev

  type = "Microsoft.Network/virtualNetworks"
  required_tags = {
    Workload    = var.workload
    Environment = "dev"
  }
}

locals {
  # 오늘은 스포크가 dev 하나뿐이라 고정 키("dev")로 묶는다. 스포크가 늘어나면
  # (qa 등) 이 local을 태그의 Environment 값으로 그룹핑하도록 넓힌다 — 지금은
  # YAGNI로 미룬다.
  spoke_connections = {
    for r in data.azurerm_resources.dev_spoke_vnets.resources : "dev" => r.id
  }
}

resource "azurerm_virtual_wan" "this" {
  name                = "vwan-${var.workload}-${var.env}-${var.region_code}-main"
  resource_group_name = data.azurerm_resource_group.workload.name
  location            = var.location
  type                = "Standard"

  # hub 는 "구독 하나의 단일 고정 거처"(CLAUDE.md 2절) — live/hub/networking의 VNet과
  # 같은 이유로 실수 삭제 최후 방어선을 켠다. 파기는 2단계(prevent_destroy=false로
  # 먼저 apply한 뒤 destroy)다.
  # 2026-09-08 hub 철거→재구축 실검증(docs/hub-lifecycle.md 11절)을 위해 일시 해제했다가,
  # 재구축 완료 후 이 커밋으로 복원했다(⛔ 11절 원칙대로).
  lifecycle {
    prevent_destroy = true
  }

  tags = local.tags
}

resource "azurerm_virtual_hub" "this" {
  name                = "vhub-${var.workload}-${var.env}-${var.region_code}-main"
  resource_group_name = data.azurerm_resource_group.workload.name
  location            = var.location
  virtual_wan_id      = azurerm_virtual_wan.this.id
  address_prefix      = local.vhub_address_prefix

  # Standard vWAN과 짝을 맞춘다 — Basic SKU 허브는 연결·라우팅 테이블 대부분을 지원하지
  # 않는다.
  sku = "Standard"

  # 2026-09-08 hub 철거→재구축 실검증(docs/hub-lifecycle.md 11절)을 위해 일시 해제했다가,
  # 재구축 완료 후 이 커밋으로 복원했다(⛔ 11절 원칙대로).
  lifecycle {
    prevent_destroy = true
  }

  tags = local.tags
}

# hub VNet ↔ vHub 연결. 스포크 연결(azurerm_virtual_hub_connection.spoke)과 정적
# 라우트는 vHub에 종속된 하위 객체라 별도 네이밍 약어를 쓰지 않는다(iac-module-library
# docs/naming/abbreviations/azure.md 「종속 객체」 규약) — 부모(vHub) 이름에 역할
# 접미사만 붙인다.
#
# routing 블록을 커스터마이즈하지 않는다 — Default 라우팅 테이블에 정상
# associate + propagate하는 vWAN 기본값을 그대로 쓴다. Overlay CNI 채택으로 Pod IP가
# VNet/vWAN 라우팅에 아예 노출되지 않아, "Propagate to none" + 정적 라우트 같은
# 특수 배선이 필요 없다.
resource "azurerm_virtual_hub_connection" "hub" {
  name                      = "${azurerm_virtual_hub.this.name}-hub"
  virtual_hub_id            = azurerm_virtual_hub.this.id
  remote_virtual_network_id = data.azurerm_virtual_network.hub.id
}

# 스포크 연결 — dev VNet ID는 위 data source(azurerm_resources)로 자동 발견한다.
resource "azurerm_virtual_hub_connection" "spoke" {
  for_each = local.spoke_connections

  name                      = "${azurerm_virtual_hub.this.name}-${each.key}"
  virtual_hub_id            = azurerm_virtual_hub.this.id
  remote_virtual_network_id = each.value
}

# ── dev(spoke) GitOps 등록 — hub ArgoCD의 Entra Workload Identity ──────────────
#
# .omc/plans/dev-gitops-registration.md(6.5차 패치) 결정: 이 UAMI+FIC는 이 root에
# 둔다(live/hub/aks가 아니라) — DNS Link(아래)와 같은 "hub↔dev 크로스 구독 배선"
# 역할의 연장이고, 새 root를 만들면 워크플로·backend key 신설 비용이 든다.
#
# ⛔ AWS의 cross-account-trust-role과 대칭되는 "신뢰 전용" 리소스를 dev 쪽에 만들지
# 않는다 — Azure RBAC 역할 할당은 tenant 전역 ARM 오퍼레이션이라 그런 게 필요 없다
# (entra-id-authorization 공식 문서: role assignment의 assignee는 어느 구독
# 소속이든 상관없다. 단 assignment 자체는 대상 구독 ARM에 저장된다 — "0개"가 아니라
# "AWS 대비 1개 적다"가 정확한 표현).
#
# 이 identity는 접속 *대상*(scratch든 실 dev든)과 무관하게 hub 자신의 OIDC issuer +
# K8s ServiceAccount subject에만 묶인다 — 영속 리소스이고 scratch 리허설 때도
# 파기 대상에서 제외한다(5차 Architect 검토, FIC는 hub 쪽 issuer 종속).
resource "azurerm_user_assigned_identity" "argocd" {
  name                = "id-${var.workload}-${var.env}-${var.region_code}-argocd-01"
  resource_group_name = data.azurerm_resource_group.workload.name
  location            = var.location
  tags                = local.tags
}

# hub AKS 클러스터의 OIDC issuer URL 조회. 결정적 네이밍 → data 조회(CLAUDE.md 1절) —
# live/hub/aks가 이미 이 이름으로 클러스터를 만들었다(module.aks_cluster 네이밍 규약과
# 동일 합성식).
data "azurerm_kubernetes_cluster" "hub" {
  name                = "aks-${var.workload}-${var.env}-${var.region_code}-main-01"
  resource_group_name = data.azurerm_resource_group.workload.name
}

# ArgoCD SA 2개(argo-cd 10.3.0 chart, release명 "argocd")를 federate한다. 두 이름
# 모두 release명으로 템플릿되지 않는 chart values의 리터럴 기본값이다(controller.
# serviceAccount.name·server.serviceAccount.name) — application-controller가
# 실제로 스포크 API 서버와 통신해 reconcile하고, server는 UI·CLI·`argocd app diff`
# 경로에서 같은 API를 호출한다(둘 다 필요, Architect 검토 M-4).
resource "azurerm_federated_identity_credential" "argocd" {
  for_each = toset(["argocd-application-controller", "argocd-server"])

  name                      = "fic-argocd-${each.value}"
  audience                  = ["api://AzureADTokenExchange"]
  issuer                    = data.azurerm_kubernetes_cluster.hub.oidc_issuer_url
  user_assigned_identity_id = azurerm_user_assigned_identity.argocd.id
  subject                   = "system:serviceaccount:argocd:${each.value}"
}

# ── 스포크 AKS 자동 발견 — hub ArgoCD의 인가(role assignment) 스코프용 ─────────
#
# dev-gitops-registration Step 7: 위 UAMI+FIC는 인증(hub ArgoCD가 자기 신원을
# 증명하는 것)만 담당한다 — 그 신원으로 실제 K8s API 요청이 인가받으려면
# 대상 클러스터 리소스 ID 스코프의 role assignment가 별도로 필요하다(인증·
# 인가는 별개 축, Step 2 실측이 이미 확인한 잔존 리스크와 같은 구분).
#
# spoke_connections(위 45~74행, VNet 자동 발견)과 같은 이유로 dev AKS 리소스
# ID를 CI 변수 주입이 아니라 태그 기반 azurerm_resources로 직접 조회한다
# (bootstrap/config.sh의 spoke-peer 역할에 2026-09-09 managedClusters/read
# 추가, dev 구독에 이미 적용·verify.sh로 drift 없음 확인 완료).
#
# ⚠️ spoke_connections와 달리 그룹핑 키를 리터럴 "dev"로 고정하지 않는다 —
# r.tags["Environment"]로 뽑는다. provider(azurerm.dev)가 구독 단위로
# 고정돼 있어 오늘은 결과가 dev 하나뿐이지만, 한 구독에 여러 환경이 같이
# 있는 경우(예: 비프로덕션 구독에 dev+qa 공존)까지 대비한 것이다 — 리터럴
# 키였다면 그 경우 서로 다른 스포크가 조용히 한 키로 뭉개진다. 비용은
# 이 한 줄뿐이라 지금 반영한다(2026-09-09, "다중 스포크 확장성 검토" 요청
# 대응). `spoke_connections` 자체의 리터럴 "dev" 키는 이 변경과 별개
# open-item으로 계획 문서에 남겨두고 이번 스코프에서는 건드리지 않는다.
data "azurerm_resources" "spoke_aks_clusters" {
  provider = azurerm.dev

  type = "Microsoft.ContainerService/managedClusters"
  required_tags = {
    Workload = var.workload
  }
}

locals {
  spoke_aks_ids = {
    for r in data.azurerm_resources.spoke_aks_clusters.resources : r.tags["Environment"] => r.id
  }
}

# hub ArgoCD UAMI에 각 스포크 AKS의 K8s API 인가 권한 부여 — Step 2에서
# 검증한 토큰 교환 경로(argocd-k8s-auth azure)가 실제로 인가받는 지점이
# 여기다. principal이 다른 구독 소속이라 skip_service_principal_aad_check가
# 필요하다(live/dev/aks/main.tf의 같은 패턴과 동일 근거).
resource "azurerm_role_assignment" "argocd_spoke_aks_access" {
  for_each = local.spoke_aks_ids

  scope                            = each.value
  role_definition_name             = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id                     = azurerm_user_assigned_identity.argocd.principal_id
  skip_service_principal_aad_check = true
}
