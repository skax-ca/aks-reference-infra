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

resource "azurerm_virtual_wan" "this" {
  name                = "vwan-${var.workload}-${var.env}-${var.region_code}-main"
  resource_group_name = data.azurerm_resource_group.workload.name
  location            = var.location
  type                = "Standard"

  # hub 는 "구독 하나의 단일 고정 거처"(CLAUDE.md 2절) — live/hub/networking의 VNet과
  # 같은 이유로 실수 삭제 최후 방어선을 켠다. 파기는 2단계(prevent_destroy=false로
  # 먼저 apply한 뒤 destroy)다.
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

# 스포크 연결 — dev VNet ID는 data source로 조회하지 않고 CI 변수로 주입한다.
# 조회하려면 dev 구독에 virtualNetworks/read가 추가로 필요한데, 그 한 액션을
# 아끼는 편이 낫다 — 존재하지
# 않는 VNet ID를 넘기면 peer/action 호출 자체가 실패해 큰 소리로 드러난다.
resource "azurerm_virtual_hub_connection" "spoke" {
  for_each = var.spoke_connections

  name                      = "${azurerm_virtual_hub.this.name}-${each.key}"
  virtual_hub_id            = azurerm_virtual_hub.this.id
  remote_virtual_network_id = each.value
}
