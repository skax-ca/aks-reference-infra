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

  # ⚠️ Phase 2 AKS 네트워킹 기본값 결정(2026-08-28, AWS 원본·Azure 공식 문서 대조 세션):
  #
  #   CNI 모드는 Azure CNI **Pod Subnet(flat)** 을 기본으로 한다. Azure CNI **Overlay**
  #   는 채택하지 않는다 — Overlay 는 성능은 flat 과 동급이지만(캡슐화 없음, MS 공식
  #   문서 확인), 클러스터 밖으로 나가는 Pod 트래픽이 노드 IP로 SNAT 돼 NSG 플로우
  #   로그·Network Watcher·온프레미스 방화벽 로그에서 Pod 단위 가시성이 사라진다.
  #   AWS 원본이 VPC CNI(underlay, SNAT 없음)를 기본으로 하고 IP 고갈 시에도 이
  #   가시성을 포기하지 않는(custom networking 으로 대응) 설계 철학과 어긋난다.
  #
  #   Pod IP 대역은 이 VNet 의 **secondary address_space** 인 cidr_pod_dup 에서
  #   뗀다 — AWS 원본의 3계층 CIDR(cidr_primary·cidr_uniq·cidr_dup, eks-reference-infra
  #   의 live/hub/networking/main.tf)과 정확히 같은 구조다. aks-node 서브넷(아래
  #   subnet_cidrs)은 **노드** IP 전용이고 Pod 는 여기서 뜨지 않는다.
  #
  #   ⛔ 아직 하지 않은 것: Pod 전용 azurerm_subnet 자체는 만들지 않는다(Phase 2 AKS
  #      모듈이 없어 소비자가 없다 — 소비자 없는 리소스를 미리 만들지 않는다,
  #      .claude/rules/terraform.md). VNet 레벨 secondary CIDR **연결**만 지금 한다 —
  #      이건 이 root(live/hub/networking) 가 소유한 리소스(azurerm_virtual_network)의
  #      속성이라 Phase 2 를 기다릴 이유가 없다.
  #
  #   ⛔ 정정(2026-08-28, live/hub/vwan 설계 세션, .omc/plans/live-hub-vwan-dev-
  #      networking.md 4-4): 이전 버전의 이 주석은 "AWS 처럼 dup 대역을 스포크마다
  #      중복 사용하고 vWAN 라우팅에서 전파 제외하면 된다"고 썼다. 틀렸다 — AWS 가
  #      스포크 간 dup 대역 재사용을 할 수 있었던 이유는 VPC CNI 가 VPC 밖으로 나가는
  #      Pod 트래픽을 노드 IP 로 SNAT 하기 때문이다. Phase 2 기본값으로 확정한 Azure
  #      CNI Pod Subnet 은 크로스 VNet 트래픽에도 SNAT 를 하지 않는다("the pod IP is
  #      always the source address for any traffic from the pod", learn.microsoft.com/
  #      en-us/azure/aks/concepts-network-legacy-cni) — 즉 hub 와 dev 가 같은
  #      100.64.0.0/16 을 쓰면 dev 가 그 대역을 자기 로컬 Pod 대역으로 착각해 hub 로
  #      가는 응답을 돌려보내지 못한다(overlapping CIDR 은 양방향 라우팅과 근본적으로
  #      양립 불가 — vWAN 의 "Propagate to none" + 정적 라우트로도 못 고친다, 목적지
  #      주소만으로는 "내 로컬 Pod"와 "hub 로 돌려줄 응답"을 구분할 수 없기 때문이다).
  #      대신 **스포크마다 고유한 Pod 대역**을 준다 — dev 는 100.65.0.0/16(hub 는 이
  #      100.64.0.0/16 을 유지, 이 VNet 은 값 변경 없음). 두 vWAN 연결 모두 Default
  #      라우팅 테이블에 정상 propagate 해 hub↔dev Pod 트래픽이 실제로 왕복한다(Phase 2
  #      ArgoCD 가 spoke API 서버를 관리하는 이 아키텍처의 존재 이유). 대가: Pod 트래픽이
  #      vWAN 허브를 건너므로 AWS 원본(TGW 를 건넌 적 없음) 대비 노출면이 넓어지고 NSG 가
  #      유일한 보상 통제다 — 사용자 승인 완료(같은 계획 문서 참고).
  cidr_pod_dup = "100.64.0.0/16" # RFC 6598, AWS 원본 cidr_dup 과 동일 대역 — Phase 2 AKS Pod Subnet 전용

  # 그룹별 CIDR. 10.60.4.0/24~10.60.15.0/24, 10.60.32.0/19 이후는 미할당으로 남겨둔다
  # (향후 AzureFirewallSubnet 등 필요 시 재조사 없이 바로 쓴다). Pod 대역은 여기 없다 —
  # cidr_pod_dup(secondary address_space) 소관이다.
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

  address_space = [local.vnet_cidr, local.cidr_pod_dup]

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
    # ⚠️ 이 서브넷은 노드 IP 전용이다 — Pod IP 는 여기서 뜨지 않는다. Phase 2 기본값은
    #    Azure CNI Pod Subnet(flat)이고 Pod 는 위 locals.cidr_pod_dup(secondary
    #    address_space)에서 전용 Pod Subnet 으로 배정한다. 근거·Overlay 를 채택하지
    #    않은 이유는 locals 블록 주석 참고. /20 크기는 노드 수 기준 잠정치다.
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
