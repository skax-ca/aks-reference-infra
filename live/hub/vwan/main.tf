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
    Workload = var.workload
  }
}

locals {
  # 2026-09-09 정정 — 이전에는 required_tags에 Environment="dev"까지 고정해 둬
  # 이 data source 자체가 dev 외 스포크(같은 azurerm.dev 구독 안의 qa 등, 예:
  # 비프로덕션 구독에 dev+qa 공존)를 애초에 조회하지 못했고, 그룹핑 키도 리터럴
  # "dev"라 설사 조회되더라도 서로 다른 스포크가 한 키로 뭉개졌을 것이다.
  # 태그만 맞으면 재적용만으로 두 번째 vHub 연결이 자동으로 생긴다. 여전히
  # provider alias(azurerm.dev) 자체는 구독 하나에 고정이라, 완전히 다른
  # 구독의 새 스포크는 별도 provider alias+data source 블록 추가가 필요하다
  # (raw OpenTofu 루트의 의도된 트레이드오프). 2026-09-10 — 이 패턴을 공유하던
  # spoke_aks_ids(hub ArgoCD role assignment 발견용)는 방향 전환으로 제거됐다
  # (아래 removed 블록 참고) — spoke_connections(이 local)는 vHub 연결 자체가
  # hub 소유 리소스라 방향 전환 대상이 아니므로 그대로 남는다.
  spoke_connections = {
    for r in data.azurerm_resources.dev_spoke_vnets.resources : r.tags["Environment"] => r.id
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
  # 2026-09-10 dev까지 포함한 전체 철거→재구축 e2e 검증(US-009) 착수 — destroy 전 재해제.
  lifecycle {
    prevent_destroy = false
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
  # 2026-09-10 dev까지 포함한 전체 철거→재구축 e2e 검증(US-009) 착수 — destroy 전 재해제.
  lifecycle {
    prevent_destroy = false
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
# 2026-09-10 — 이 root에서 live/hub/aks로 이전했다. 원래 이유(.omc/plans/
# dev-gitops-registration.md 6.5차 패치 - "새 root를 만들면 워크플로·backend key
# 신설 비용이 든다")는 그대로 맞지만, 애초에 live/hub/aks가 *이미 있는* root라는
# 점을 놓쳤다 - FIC의 issuer가 hub AKS의 OIDC issuer URL에 묶이는데, 그 값을 여기서는
# `data "azurerm_kubernetes_cluster" "hub"`로 **이름 기반 재조회**해야 했다(CLAUDE.md
# 1절의 일반 원칙을 그대로 따른 선택이었으나, 이 경우엔 함정이었다). 전체
# 철거→재구축 e2e 검증(US-009) 중 hub AKS를 먼저 destroy한 뒤 이 root를 destroy하려다
# 바로 이 data source가 "클러스터를 찾을 수 없음"으로 하드 실패하는 걸 실측
# 확인했다 - hub-lifecycle.md가 문서화한 구축 순서(networking→vwan→aks)로 이 root를
# *처음* apply했다면 AKS가 아직 없어 **생성 시점에도** 똑같이 실패했을 것이다(한 번도
# from-scratch로 실행된 적이 없어 지금까지 드러나지 않았을 뿐). live/hub/aks는
# outputs.tf에 이미 `oidc_issuer_url`을 노출해 두고 있었다("Workload Identity
# Federation 배선의 원시 재료") - 데이터 재조회가 아니라 **같은 root의 리소스
# 참조**(`module.aks_cluster.oidc_issuer_url`)로 직접 쓸 수 있는 자리였다. 옮긴
# 뒤에는 aks 생성 순서 안에서 자동으로 올바르게 해결되고, vwan은 networking에만
# 의존하는 원래의 단순한 역할로 돌아간다. live/dev/aks의 발견 로직(아래 참고)은
# 리소스 그룹+태그 기반이라 이 root 이동에 영향받지 않는다.
#
# "영속 리소스, scratch 리허설에도 파기 대상에서 제외"(5차 Architect 검토)라는 이전
# 결정도 함께 재검토했다 - FIC의 값 자체가 특정 AKS 인스턴스의 OIDC issuer에 묶여
# 있어 hub AKS가 재생성되면 issuer도 바뀐다(영속시켜도 다음 apply에서 갱신이
# 필요하긴 마찬가지다). live/dev/aks의 발견 로직이 이름+태그 기반이라 UAMI가 매번
# 재생성돼도(새 clientId) 다음 apply에서 자동으로 다시 찾으므로, "영속" 예외를 두는
# 것보다 aks 클러스터 자체와 생애주기를 맞추는(같은 root에서 함께 생성·파기되는)
# 쪽이 더 단순하고 이 repo의 "disposable reference infra" 기조와도 맞다. 다만
# spoke-lifecycle.md 14절(재배포 시 GitOps 재등록)에 "AZURE_CLIENT_ID도 hub AKS
# 재구축 시 갱신 대상"이라는 내용을 추가해야 한다(아직 미반영, 다음 정리 대상).
#
# (UAMI·FIC 정의는 live/hub/aks/main.tf "hub ArgoCD의 Entra Workload Identity" 절
# 참고.)
#
# ── 스포크 AKS 자동 발견 — hub ArgoCD의 인가(role assignment) 스코프용 ─────────
# 2026-09-10 방향 전환(.omc/plans/hub-argocd-rbac-direction-flip.md)으로 이미
# 제거된 발견 로직(data "azurerm_resources" "spoke_aks_clusters" ·
# local.spoke_aks_ids · resource "azurerm_role_assignment"
# "argocd_spoke_aks_access")의 `removed` 블록은 마이그레이션(PR #36~38)이 실제
# apply로 적용 완료됐다 - plan 5단계가 지시한 코드 삭제(26차 이월 항목)를 이제
# 실행한다. 소유권은 live/dev/aks의 azurerm_role_assignment.argocd_hub_access에
# 있다.
