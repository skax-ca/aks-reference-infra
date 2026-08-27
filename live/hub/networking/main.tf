# live/hub/networking — VNet 배포 루트 (허브)
#
# iac-module-library 의 modules/azure/vnet 을 실제로 처음 소비하는 root다(Phase 1 첫 배포 루트).
# 설계 전문은 .omc/plans/live-hub-networking.md 참조.
#
# ⚠️ TGW 대응(Virtual WAN) 연결은 이 root 에 없다 — live/hub/vwan(별도 state)이 담당한다
#    (CLAUDE.md 3·5절). AWS 원본처럼 vnet 과 hub-spoke 라우팅을 한 파일에 섞지 않는다.

locals {
  # ── CIDR (모듈 repo 규약: 계산의 소유는 모듈이 아니라 소비자 루트) ─────────────
  #
  # hub 는 10.60.0.0/16, spoke(dev, 아직 미착수)는 10.61.0.0/16 을 예약해 겹치지 않는다.
  # 사용자 확정: 이 레퍼런스 아키텍처는 hub·spoke 만 안 겹치면 되고, 기존 Azure 대역과의
  # 충돌 조사는 불필요하다(계정 내 다른 VNet 이 없는 새 구독).
  vnet_cidr = "10.60.0.0/16"

  # 그룹별 CIDR. 10.60.4.0/24~10.60.15.0/24, 10.60.32.0/19 이후는 미할당으로 남겨둔다
  # (향후 Pod 서브넷·AzureFirewallSubnet 등 필요 시 재조사 없이 바로 쓴다).
  subnet_cidrs = {
    pub      = "10.60.0.0/24"
    ilb      = "10.60.1.0/24"
    vm       = "10.60.2.0/24"
    pe       = "10.60.3.0/24"
    aks-node = "10.60.16.0/20"
  }
}

module "vnet" {
  # ⛔ 소싱 URL 은 git::https:// 하나로 유지한다(모듈 repo 규약, AWS 원본과 동일 근거).
  # ⛔ ?ref= 는 정확 태그 핀이다. git 소싱에 ~> 는 동작하지 않는다.
  source = "git::https://github.com/skax-ca/iac-module-library.git//modules/azure/vnet?ref=vnet-v0.2.0&depth=1"

  # 소비자는 리소스 타입 약어를 타이핑하지 않는다 — 모듈이 조합한다(모듈 repo 규약).
  # {demo, hub, krc} → vnet-demo-hub-krc-main · snet-demo-hub-krc-pub
  naming = {
    workload    = var.workload
    env         = var.env
    region_code = var.region_code
  }
  purpose = "main"

  # 사람이 선생성한 워크로드 RG(rg-<workload>-<env>-krc-workload-01, bootstrap 기대 상태
  # 문서 참고). 이 root 가 RG 를 만들지 않는다 — 모듈 자체가 RG 를 만들지 않는 설계와
  # 일관된다(파괴 반경 한정).
  resource_group_name = "rg-${var.workload}-${var.env}-${var.region_code}-workload-01"
  location            = var.location

  address_space = [local.vnet_cidr]

  subnet_groups = {
    # 인터넷 대면 LB/App Gateway. AWS pub-uniq 대응.
    "pub" = {
      address_prefixes = [local.subnet_cidrs["pub"]]
      nsg_enabled      = true
    }

    # 내부 LB(ArgoCD ingress 등). AWS elb-uniq 대응. 운영 라우트(hub↔spoke)를 얹을 자리라
    # route_table_enabled 를 켠다 — vWAN 연결 후 live/hub/vwan 또는 이 root 후속 변경이 채운다.
    "ilb" = {
      address_prefixes    = [local.subnet_cidrs["ilb"]]
      nsg_enabled         = true
      route_table_enabled = true
    }

    # 관리·workbench VM. AWS vm-uniq 대응. NAT 아웃바운드.
    "vm" = {
      address_prefixes = [local.subnet_cidrs["vm"]]
      nat_routed       = true
      nsg_enabled      = true
    }

    # PaaS Private Endpoint 전용. AWS ep-uniq·db-uniq·data-uniq 를 하나로 통합했다 — Azure
    # Private Endpoint 는 서비스 종류와 무관하게 같은 서브넷을 공유해도 되는 경우가 많고,
    # 특정 서비스가 전용/위임 서브넷을 요구하면 그때 분리한다(지금 쪼갤 근거가 없다).
    "pe" = {
      address_prefixes = [local.subnet_cidrs["pe"]]
      nsg_enabled      = true
    }

    # AKS 노드 자리(Phase 2, 모듈 아직 없음 — 자리만 미리 확보). AWS node-uniq 대응.
    # ⚠️ /20 크기는 잠정적이다 — Azure CNI Overlay 냐 기존 CNI 냐에 따라 과잉/부족이 갈린다.
    #    Phase 2 에서 AKS 모듈의 CNI 모드가 정해지면 재검토한다.
    "aks-node" = {
      address_prefixes = [local.subnet_cidrs["aks-node"]]
      nat_routed       = true
      nsg_enabled      = true
    }
  }

  # dev(spoke)가 아직 없어도 hub 는 이미 "구독 하나의 단일 고정 거처"(CLAUDE.md 2절) —
  # AWS 원본이 문서화한 실수 삭제 최후 방어선과 같은 의도로 켠다.
  # ⚠️ 파기는 2단계다: deletion_protection = false 로 먼저 apply 한 뒤 destroy.
  deletion_protection = true

  # azurerm 은 provider 레벨 default_tags 인자가 없어(vnet 모듈 README 확인) 여기서 명시
  # 배선한다. 태그 키 이름은 AWS 원본과 맞춘다.
  tags = {
    Environment = var.env
    Workload    = var.workload
    RegionCode  = var.region_code
    ManagedBy   = "opentofu"
    Repository  = var.repository
  }
}
