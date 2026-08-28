# live/dev/networking — VNet 배포 루트 (spoke 첫 인스턴스)
#
# live/hub/networking을 착수 템플릿으로 복사해 dev 구독 값으로 바꾼 것이다 — 구조는
# 동일하고 CIDR·env만 다르다. 설계 전문은 .omc/plans/live-hub-vwan-dev-networking.md
# (4-3 착수 순서, 5절 Implementation Steps 4단계) 참조.
#
# ⚠️ vWAN 연결은 이 root에 없다 — live/hub/vwan(hub 구독, 별도 state)이 담당한다.
#    이 root는 dev VNet만 만들고 vWAN을 전혀 모른다(설계 계획 4-3, 소유권은 hub 쪽).

locals {
  # hub는 10.60.0.0/16, 이 VNet(dev)은 10.61.0.0/16 — 겹치지 않는다
  # (live/hub/networking/main.tf와 CLAUDE.md 6절에서 이미 예약된 값).
  vnet_cidr = "10.61.0.0/16"

  # ⛔ hub와 같은 100.64.0.0/16을 쓰지 않는다 — Azure CNI Pod Subnet은 크로스 VNet
  # 트래픽에도 SNAT를 하지 않아, 중복 대역이면 hub↔dev Pod 트래픽의 응답이 돌아오지
  # 못한다(overlapping CIDR은 양방향 라우팅과 근본적으로 양립 불가). 전체 근거는
  # live/hub/networking/main.tf의 cidr_pod_dup 주석 참고 — 여기서는 반복하지 않는다.
  # 스포크 N번째는 100.(64+N).0.0/16 규칙(계획 문서 3절) — dev는 N=1.
  cidr_pod_dup = "100.65.0.0/16" # RFC 6598, hub(100.64.0.0/16)와 겹치지 않는 고유 대역

  # hub와 같은 서브넷 그룹 구성을 10.61.x로 그대로 옮긴다(대칭 유지 — 나중에 3번째
  # 스포크가 생겨도 같은 패턴을 복사하면 된다).
  subnet_cidrs = {
    pub      = "10.61.0.0/24"
    ilb      = "10.61.1.0/24"
    vm       = "10.61.2.0/24"
    pe       = "10.61.3.0/24"
    aks-node = "10.61.16.0/20"
  }
}

module "vnet" {
  source = "git::https://github.com/skax-ca/iac-module-library.git//modules/azure/vnet?ref=vnet-v0.2.0&depth=1"

  # {demo, dev, krc} → vnet-demo-dev-krc-main · snet-demo-dev-krc-pub
  naming = {
    workload    = var.workload
    env         = var.env
    region_code = var.region_code
  }
  purpose = "main"

  # 사람이 선생성한 워크로드 RG(bootstrap.sh, BOOTSTRAP_TARGET=spoke SPOKE_ENV=dev로
  # 이미 생성 완료 — rg-demo-dev-krc-workload-01).
  resource_group_name = "rg-${var.workload}-${var.env}-${var.region_code}-workload-01"
  location            = var.location

  address_space = [local.vnet_cidr, local.cidr_pod_dup]

  subnet_groups = {
    "pub" = {
      address_prefixes = [local.subnet_cidrs["pub"]]
      nsg_enabled      = true
    }

    "ilb" = {
      address_prefixes    = [local.subnet_cidrs["ilb"]]
      nsg_enabled         = true
      route_table_enabled = true
    }

    "vm" = {
      address_prefixes = [local.subnet_cidrs["vm"]]
      nat_routed       = true
      nsg_enabled      = true
    }

    "pe" = {
      address_prefixes = [local.subnet_cidrs["pe"]]
      nsg_enabled      = true
    }

    # AKS 노드 자리(Phase 2, 모듈 아직 미소비 — 자리만 미리 확보). Pod IP는 여기서 뜨지
    # 않는다 — cidr_pod_dup(secondary address_space) 소관(위 locals 참고).
    "aks-node" = {
      address_prefixes = [local.subnet_cidrs["aks-node"]]
      nat_routed       = true
      nsg_enabled      = true
    }
  }

  # 사용자 결정(2026-08-28, live/hub/vwan+live/dev/networking 설계 세션): hub와 동일하게
  # true. AWS 원본의 dev는 false(파기가 잦은 환경 가정)였지만, 이 레퍼런스 인스턴스는
  # 실수 삭제 방지를 우선한다. 해제하려면 deletion_protection=false로 먼저 apply한 뒤
  # destroy(hub와 동일 2단계 절차).
  deletion_protection = true

  tags = {
    Environment = var.env
    Workload    = var.workload
    RegionCode  = var.region_code
    ManagedBy   = "opentofu"
    Repository  = var.repository
  }
}
