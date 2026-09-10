# live/dev/networking — VNet 배포 루트 (spoke 첫 인스턴스)
#
# live/hub/networking을 착수 템플릿으로 복사해 dev 구독 값으로 바꾼 것이다 — 구조는
# 동일하고 CIDR·env만 다르다.
#
# ⚠️ vWAN 연결은 이 root에 없다 — live/hub/vwan(hub 구독, 별도 state)이 담당한다.
#    이 root는 dev VNet만 만들고 vWAN을 전혀 모른다(소유권은 hub 쪽, live/hub/vwan/main.tf 참고).

locals {
  # hub는 10.60.0.0/16, 이 VNet(dev)은 10.61.0.0/16 — 겹치지 않는다
  # (live/hub/networking/main.tf와 CLAUDE.md 6절에서 이미 예약된 값).
  vnet_cidr = "10.61.0.0/16"

  # ⛔ 2026-09-03 정정: hub와 같은 이유로 secondary CIDR(구 cidr_pod_dup =
  # 100.65.0.0/16)을 더 이상 두지 않는다 — aks-cluster 모듈 v0.3.0이 cni_mode
  # 기본값을 Overlay로 정정해, Pod IP가 VNet 밖 오버레이 대역(모듈의 pod_cidr)에서
  # 나온다. 근거 전문은 live/hub/networking/main.tf의 해당 locals 주석 참고(반복하지
  # 않는다).

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

  address_space = [local.vnet_cidr]

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

    # AKS 노드 자리(Phase 2, live/dev/aks 계획에서 소비 예정). Pod IP는 여기서 뜨지
    # 않는다 — Overlay CNI라 VNet 밖 오버레이 CIDR에서 받는다(hub와 동일 근거,
    # live/hub/networking/main.tf 참고).
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
  #
  # 2026-09-09: spoke-lifecycle.md 철거→재구축 실측 검증 완료(9~14절) — 재구축 후 true로 복원.
  # 2026-09-10: hub까지 포함한 전체 철거→재구축 e2e 검증(US-009) 완료 — 재구축 후 복원.
  deletion_protection = true

  tags = {
    Environment = var.env
    Workload    = var.workload
    RegionCode  = var.region_code
    ManagedBy   = "opentofu"
    Repository  = var.repository
  }
}
