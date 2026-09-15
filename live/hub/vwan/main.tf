# live/hub/vwan: Virtual WAN 배포 루트 (허브, TGW 대응)
#
# AWS 원본(eks-reference-infra의 live/hub/tgw)과 같은 이유로 live/hub/networking과
# 분리된 별도 state다. TGW/vWAN이 그 root와 같은 apply에서 생기면, 거기 붙는 spoke
# 연결을 자동 발견하는 for_each가 "허브 ID가 plan 시점에 unknown"이라 실패할 여지가
# 있다. 허브를 먼저 이 root로 세워두면 하류(dev)가 이미 존재하는 실물로 참조할 수
# 있다. "레이어로 키운다"는 이 repo의 일반 원칙과 같은 이유다.
#
# ⚠️ 이 root는 networking에만 의존한다. hub AKS 같은 다른 root의 리소스를 이름으로
#    재조회하는 data source를 여기 두지 않는다. 구축 순서(networking→vwan→aks)상 그
#    리소스가 아직 없어 from-scratch apply와 destroy 순서가 깨진다.
#
# ⛔ 모듈을 쓰지 않는다. AWS 원본의 live/hub/tgw도 raw aws_ec2_transit_gateway
# 리소스였다(모듈화 안 함). 이 repo는 모듈 자체를 만들지 않는다(CLAUDE.md 서두).
# 소비자가 vWAN 허브 하나뿐이라 모듈화의 값(재사용)도 없다.

locals {
  # ⚠️ vHub 주소 공간은 생성 후 변경 불가하다(learn.microsoft.com/en-us/azure/
  # virtual-wan/hub-settings). 최소는 /24, 권장은 /23이지만 vWAN 안에 Azure Firewall을
  # 두는 경우(Secured Virtual Hub) 최소 /22가 요구된다. Firewall 배포 여부가 아직
  # 미결이므로 선택지를 남기는 값으로 잡는다. 사설 대역에서 /22와 /23의 비용 차이는 0이다.
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

# hub VNet은 이 root가 만들지 않는다(live/hub/networking 소유). 같은 구독·같은 RG를
# data source로 참조한다. 추가 권한이 필요 없다(CI 신원이 이미 이 구독에 전권을 가짐).
data "azurerm_resource_group" "workload" {
  name = "rg-${var.workload}-${var.env}-${var.region_code}-workload-01"
}

data "azurerm_virtual_network" "hub" {
  name                = "vnet-${var.workload}-${var.env}-${var.region_code}-main"
  resource_group_name = data.azurerm_resource_group.workload.name
}

# 스포크 VNet은 CI 변수가 아니라 태그로 발견한다. AWS 원본(eks-reference-infra의
# live/hub/tgw)이 spoke attachment를 태그로 자동 발견하는 것과 같은 패턴이다.
#
# ⛔ VNet ID를 workflow_dispatch 입력으로 주입하지 않는다. push로 도는 plan이나 입력을
#    빠뜨린 dispatch에서 값이 비어 스포크 연결이 destroy로 계획된다.
#
# `azurerm_resources`는 대상이 없으면 하드 에러가 아니라 빈 리스트를 반환한다
# (registry.terraform.io hashicorp/azurerm docs/d/resources.html.markdown의
# Example Usage 자체가 "타입+태그로 spoke VNet을 찾아 peering" 시나리오다). dev가
# 아직 없어도 이 root는 스포크 연결 0개로 정상 apply된다. dev networking이 생긴
# 뒤 이 root를 한 번 더 apply하면 자동으로 발견해 연결이 생긴다(AWS 원본의 "hub
# networking 재적용" 단계와 대칭, docs/hub-lifecycle.md 참고).
#
# 필요 권한은 dev 구독의 virtualNetworks/read 하나뿐이다(bootstrap.sh
# BOOTSTRAP_TARGET=spoke가 spoke-peer 역할에 peer/action과 나란히 부여한다).
data "azurerm_resources" "dev_spoke_vnets" {
  provider = azurerm.dev

  type = "Microsoft.Network/virtualNetworks"
  required_tags = {
    Workload = var.workload
  }
}

locals {
  # 그룹핑 키는 리터럴이 아니라 Environment 태그 값이다. required_tags에 Environment를
  # 고정하거나 키를 "dev"로 박으면, 같은 azurerm.dev 구독 안의 다른 스포크(예: 비프로덕션
  # 구독에 dev+qa 공존)를 조회하지 못하거나 한 키로 뭉갠다. 태그만 맞으면 재적용만으로
  # 두 번째 vHub 연결이 생긴다. 다만 provider alias(azurerm.dev) 자체는 구독 하나에
  # 고정이라, 완전히 다른 구독의 새 스포크는 별도 provider alias+data source 블록
  # 추가가 필요하다(raw OpenTofu 루트의 의도된 트레이드오프).
  #
  # vHub 연결은 hub 소유 리소스라 hub가 발견해 만든다. hub ArgoCD의 스포크 클러스터
  # 권한(role assignment)은 반대로 스포크 자신의 live/<env>/aks가 만든다. 이 root에
  # 스포크 AKS를 발견하는 로직을 두지 않는다.
  spoke_connections = {
    for r in data.azurerm_resources.dev_spoke_vnets.resources : r.tags["Environment"] => r.id
  }
}

resource "azurerm_virtual_wan" "this" {
  name                = "vwan-${var.workload}-${var.env}-${var.region_code}-main"
  resource_group_name = data.azurerm_resource_group.workload.name
  location            = var.location
  type                = "Standard"

  # hub 는 "구독 하나의 단일 고정 거처"라 live/hub/networking의 VNet과 같은 이유로
  # 실수 삭제 최후 방어선을 켠다. 파기는 2단계(prevent_destroy=false로 먼저 apply한 뒤
  # destroy)다.
  # ⚠️ 지금 false인 것은 철거→재구축 중이라서다. 재구축 후 true로 되돌린다
  #    (docs/hub-lifecycle.md 철거 절).
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

  # Standard vWAN과 짝을 맞춘다. Basic SKU 허브는 연결·라우팅 테이블 대부분을 지원하지
  # 않는다.
  sku = "Standard"

  # 위 azurerm_virtual_wan과 같은 이유로 실수 삭제 방어선을 켠다.
  # ⚠️ 지금 false인 것은 철거→재구축 중이라서다. 재구축 후 true로 되돌린다.
  lifecycle {
    prevent_destroy = false
  }

  tags = local.tags
}

# hub VNet ↔ vHub 연결. 스포크 연결(azurerm_virtual_hub_connection.spoke)과 정적
# 라우트는 vHub에 종속된 하위 객체라 별도 네이밍 약어를 쓰지 않는다(iac-module-library
# docs/naming/abbreviations/azure.md 「종속 객체」 규약). 부모(vHub) 이름에 역할
# 접미사만 붙인다.
#
# routing 블록을 커스터마이즈하지 않는다. Default 라우팅 테이블에 정상
# associate + propagate하는 vWAN 기본값을 그대로 쓴다. Overlay CNI 채택으로 Pod IP가
# VNet/vWAN 라우팅에 아예 노출되지 않아, "Propagate to none" + 정적 라우트 같은
# 특수 배선이 필요 없다.
resource "azurerm_virtual_hub_connection" "hub" {
  name                      = "${azurerm_virtual_hub.this.name}-hub"
  virtual_hub_id            = azurerm_virtual_hub.this.id
  remote_virtual_network_id = data.azurerm_virtual_network.hub.id
}

# 스포크 연결. 스포크 VNet ID는 위 data source(azurerm_resources)로 자동 발견한다.
resource "azurerm_virtual_hub_connection" "spoke" {
  for_each = local.spoke_connections

  name                      = "${azurerm_virtual_hub.this.name}-${each.key}"
  virtual_hub_id            = azurerm_virtual_hub.this.id
  remote_virtual_network_id = each.value
}
