# live/hub/networking: VNet 배포 루트 (허브)
#
# iac-module-library 의 modules/azure/vnet 을 소비하는 root다.
#
# ⚠️ TGW 대응(Virtual WAN) 연결은 이 root 에 없다. live/hub/vwan(별도 state)이 담당한다.
#    AWS 원본처럼 vnet 과 hub-spoke 라우팅을 한 파일에 섞지 않는다.

locals {
  # ── CIDR (모듈 repo 규약: 계산의 소유는 모듈이 아니라 소비자 루트) ─────────────
  #
  # hub 는 10.60.0.0/16, spoke(dev)는 10.61.0.0/16 을 예약해 겹치지 않는다. 이 레퍼런스
  # 아키텍처는 hub·spoke 만 안 겹치면 되고, 기존 Azure 대역과의 충돌 조사는 하지 않는다
  # (계정 내 다른 VNet 이 없는 새 구독).
  vnet_cidr = "10.60.0.0/16"

  # CNI 모드는 Azure CNI **Overlay**를 쓴다(모듈 cni_mode 기본값. Microsoft 공식 문서
  # plan-pod-networking·AKS baseline 참조 아키텍처가 일반 권고로 명시). Pod IP는 VNet 밖
  # 오버레이 CIDR(aks-cluster 모듈의 pod_cidr 인자)에서 받으므로 이 VNet에는 Pod 전용
  # 대역이 필요 없다. secondary address_space도, Pod 전용 서브넷도 두지 않는다.
  #
  # ⛔ Azure CNI Pod Subnet(flat, SNAT 없음)으로 되돌리며 이 VNet에 secondary
  #    address_space(예: 100.64.0.0/16)를 예약하지 않는다. Pod 단위 NSG 플로우 로그
  #    가시성을 지킬 수는 있지만 NAP(Karpenter)이 Pod Subnet을 지원하지 않는다. 가시성
  #    손실은 Microsoft 유료 애드온 ACNS의 Container Network Observability(eBPF, SNAT
  #    이전 캡처)로 메운다. 근거는 iac-module-library
  #    docs/architectures/gitops-hub-spoke/azure/network.md 「Pod 네트워킹」.

  # 그룹별 CIDR. 10.60.5.0/24~10.60.15.0/24, 10.60.32.0/19 이후는 미할당으로 남겨둔다
  # (향후 AzureFirewallSubnet 등 필요 시 재조사 없이 바로 쓴다). Pod 대역은 이 VNet에
  # 없다. Overlay CNI라 Pod IP는 aks-cluster 모듈의 pod_cidr(VNet 밖)에서 받는다.
  #
  # alb: Application Gateway for Containers(AGFC) 전용 위임 서브넷이었으나 App Routing
  # 전환으로 소비자가 없다(아래 subnet_groups의 "alb" 항목 주석 참고).
  subnet_cidrs = {
    pub      = "10.60.0.0/24"
    ilb      = "10.60.1.0/24"
    vm       = "10.60.2.0/24"
    pe       = "10.60.3.0/24"
    alb      = "10.60.4.0/24"
    aks-node = "10.60.16.0/20"
  }
}

module "vnet" {
  # ⛔ 소싱 URL 은 git::https:// 하나로 유지한다(모듈 repo 규약, AWS 원본과 동일 근거).
  # ⛔ ?ref= 는 정확 태그 핀이다. git 소싱에 ~> 는 동작하지 않는다.
  source = "git::https://github.com/skax-ca/iac-module-library.git//modules/azure/vnet?ref=vnet-v0.2.0&depth=1"

  # 소비자는 리소스 타입 약어를 타이핑하지 않는다. 모듈이 조합한다(모듈 repo 규약).
  # {demo, hub, krc} → vnet-demo-hub-krc-main · snet-demo-hub-krc-pub
  naming = {
    workload    = var.workload
    env         = var.env
    region_code = var.region_code
  }
  purpose = "main"

  # 사람이 선생성한 워크로드 RG(rg-<workload>-<env>-krc-workload-01, bootstrap 기대 상태
  # 문서 참고). 이 root 가 RG 를 만들지 않는다. 모듈 자체가 RG 를 만들지 않는 설계와
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

    # 내부 LB. AWS elb-uniq 대응. 운영 라우트(hub↔spoke)를 얹을 자리라
    # route_table_enabled 를 켠다. vWAN 연결 후 live/hub/vwan 또는 이 root 후속 변경이 채운다.
    #
    # ⚠️ App Routing(Gateway API/Istio)은 위임 서브넷을 요구하지 않는다. 이 서브넷의
    #    용도는 **Gateway API로 표현 안 되는 L4/비-HTTP 내부 트래픽**(DB·MQTT 등,
    #    `service.beta.kubernetes.io/azure-load-balancer-internal: "true"` Service)이다.
    #    소비자는 아직 없다. 이미 배포된 서브넷을 지우는 건 파괴적 변경이라 별도 승인이
    #    필요하므로 지금 없애지 않는다.
    "ilb" = {
      address_prefixes    = [local.subnet_cidrs["ilb"]]
      nsg_enabled         = true
      route_table_enabled = true
    }

    # 관리·workbench VM. AWS vm-uniq 대응. NAT 아웃바운드.
    #
    # ⚠️ 이 그룹의 서브넷 레벨 NSG(nsg-demo-hub-krc-vm)는 이 root가 규칙을 만들지 않는다
    # (vnet 모듈 설계: "룰은 이 모듈이 만들지 않는다, 소비자가 얹는다"). live/hub/workbench가
    # SSH 인바운드 규칙을 우선순위 100-199로 예약해 얹고 있다(live/hub/workbench/main.tf
    # 참고). 이 서브넷에 다른 규칙을 추가할 땐 그 범위를 피한다(우선순위 중복은 apply
    # 시점 Azure API 에러).
    "vm" = {
      address_prefixes = [local.subnet_cidrs["vm"]]
      nat_routed       = true
      nsg_enabled      = true
    }

    # PaaS Private Endpoint 전용. AWS ep-uniq·db-uniq·data-uniq 를 하나로 통합했다. Azure
    # Private Endpoint 는 서비스 종류와 무관하게 같은 서브넷을 공유해도 되는 경우가 많고,
    # 특정 서비스가 전용/위임 서브넷을 요구하면 그때 분리한다(지금 쪼갤 근거가 없다).
    "pe" = {
      address_prefixes = [local.subnet_cidrs["pe"]]
      nsg_enabled      = true
    }

    # ⚠️ AGFC(Application Gateway for Containers) 전용 위임 서브넷이었다. App Routing
    #    (Gateway API/Istio 기반, live/hub/aks 참고)으로 전환하며 **소비자가 없는 고아
    #    서브넷**이 됐다. App Routing도 이 저장소의 다른 어떤 addon도 위임 서브넷을 요구하지
    #    않는다. 이미 배포된 서브넷을 지우는 건 파괴적 변경이라(VNet의
    #    `deletion_protection=true`가 막는 종류의 실수) 별도 PR로 명시적 승인을 받아 정리한다.
    "alb" = {
      address_prefixes = [local.subnet_cidrs["alb"]]
      nsg_enabled      = true
      delegations = [{
        name = "Microsoft.ServiceNetworking/trafficControllers"
        # 공식 CLI(`--delegations 'Microsoft.ServiceNetworking/trafficControllers'`)가
        # 내부적으로 쓰는 액션과 같다.
        actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      }]
    }

    # AKS 노드 자리(live/hub/aks가 소비). AWS node-uniq 대응.
    # ⚠️ 이 서브넷은 노드 IP 전용이다. Pod IP 는 여기서 뜨지 않는다(Overlay CNI, Pod
    #    는 VNet 밖 오버레이 CIDR 에서 받는다. 근거는 위 locals 블록 주석 참고). /20
    #    크기는 노드 수 기준 잠정치다.
    "aks-node" = {
      address_prefixes = [local.subnet_cidrs["aks-node"]]
      nat_routed       = true
      nsg_enabled      = true
    }
  }

  # hub 는 "구독 하나의 단일 고정 거처"라 AWS 원본이 문서화한 실수 삭제 최후 방어선과
  # 같은 의도로 켠다. 파기는 2단계다: deletion_protection = false 로 먼저 apply 한 뒤 destroy.
  # ⚠️ 지금 false인 것은 철거→재구축 중이라서다. 재구축 후 true로 되돌린다
  #    (docs/hub-lifecycle.md 철거 절).
  deletion_protection = false

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
