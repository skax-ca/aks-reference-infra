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

  # ⚠️ Phase 2 AKS 네트워킹 결정(2026-09-03 정정, aks-cluster 모듈 v0.3.0 대응):
  #
  #   CNI 모드는 Azure CNI **Overlay**를 쓴다(모듈 cni_mode 기본값 — Microsoft 공식
  #   문서 plan-pod-networking·AKS baseline 참조 아키텍처가 일반 권고로 명시). Pod IP는
  #   VNet 밖 오버레이 CIDR(aks-cluster 모듈의 pod_cidr 인자)에서 받으므로 이 VNet에는
  #   Pod 전용 대역이 전혀 필요 없다 — secondary address_space도, Pod 전용 서브넷도
  #   두지 않는다.
  #
  #   ⛔ 2026-08-28~2026-09-03 사이엔 Azure CNI Pod Subnet(flat, SNAT 없음)을 택해 이
  #      VNet에 secondary address_space(구 cidr_pod_dup = 100.64.0.0/16)를 예약해
  #      뒀었다 — Pod 단위 NSG 플로우 로그 가시성을 지키려는 목적이었다. aks-cluster
  #      모듈 v0.3.0이 cni_mode를 신설하며 기본값을 Overlay로 정정한 것을 따라 이
  #      repo도 되돌린다: 가시성 손실은 실재하지만(SNAT로 NSG 플로우 로그에서 Pod IP
  #      소실), Microsoft 유료 애드온 ACNS의 Container Network Observability(eBPF,
  #      SNAT 이전 캡처)로 다른 방식으로 메울 수 있고, NAP(Karpenter) 호환·서브넷 IP
  #      절약 등 Overlay의 이득이 이 트레이드오프를 상쇄한다고 판단했다(모듈 README
  #      「네트워킹」절 근거 인용). aks-node 서브넷은 계속 노드 전용이다 — Pod IP가
  #      여기서도 뜨지 않는 건 이전과 동일하지만 이유가 바뀌었다(Pod Subnet 미사용
  #      때문이 아니라 Overlay라 VNet 서브넷 자체를 안 쓰기 때문).
  #
  #      설계 이력 전문은 .omc/plans/live-hub-vwan-dev-networking.md의 2026-09-03
  #      추가 기록(13절) 참고 — 이 정정으로 무효화된 vWAN 라우팅 전제들을 그 절이
  #      기록한다.

  # 그룹별 CIDR. 10.60.5.0/24~10.60.15.0/24, 10.60.32.0/19 이후는 미할당으로 남겨둔다
  # (향후 AzureFirewallSubnet 등 필요 시 재조사 없이 바로 쓴다). Pod 대역은 이 VNet에
  # 없다 — Overlay CNI라 Pod IP는 aks-cluster 모듈의 pod_cidr(VNet 밖)에서 받는다.
  #
  # alb: Application Gateway for Containers(AGFC) 전용 위임 서브넷. 예비 대역
  # 10.60.4.0/24~10.60.15.0/24의 첫 칸을 쓴다(aks-platform-gitops
  # addon-selection.md·aks-platform-gitops-scaffold.md 참고). 공식 문서 요구사항:
  # "at least 250 available IP addresses (/24 or larger)"
  # (learn.microsoft.com/en-us/azure/application-gateway/for-containers/
  #  quickstart-create-application-gateway-for-containers-managed-by-alb-controller) —
  # /24는 254개 usable이라 정확히 하한을 만족한다.
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

    # 내부 LB. AWS elb-uniq 대응. 운영 라우트(hub↔spoke)를 얹을 자리라
    # route_table_enabled 를 켠다 — vWAN 연결 후 live/hub/vwan 또는 이 root 후속 변경이 채운다.
    #
    # ⚠️ 2026-09-04 정정: 원래 "ArgoCD ingress 등"을 상정했으나, GitOps addon으로
    #    Gateway API(AGFC)를 도입하기로 하면서 그 유스케이스는 alb 서브넷이
    #    흡수한다(ArgoCD 자신의 UI/API도 결국 HTTPRoute로 노출하는 쪽이 일관적).
    #    AGFC의 ALB Controller는 Ingress/Gateway/HTTPRoute/GRPCRoute만 처리하고
    #    TCPRoute는 명시적으로 무시한다(UDPRoute도 사실상 미지원, 공식 확인:
    #    github.com/MicrosoftDocs/azure-docs 의 alb-controller 문서) — 그래서 이
    #    서브넷의 남은 durable한 용도는 **Gateway API로 표현 안 되는 L4/비-HTTP
    #    내부 트래픽**(DB·MQTT 등, `service.beta.kubernetes.io/azure-load-balancer-
    #    internal: "true"` Service)이다. 소비자는 아직 없다(aks-platform-gitops
    #    미착수) — YAGNI 원칙상 지금 서브넷 자체를 없애지는 않는다(이미 배포됨,
    #    파괴적 변경이라 별도 승인 필요).
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

    # AGFC(Application Gateway for Containers) 전용 위임 서브넷. AWS 원본에
    # 대응물 없음 — Azure 고유 요구사항이다(AGFC ALB Controller가 이 서브넷에
    # Application Gateway for Containers 리소스를 연결/association한다).
    # ⚠️ 예약 이름 서브넷이 아니다(GatewaySubnet 등과 달리 이름 자유) — 위임
    #    (delegation)이 실제 제약이다. 이 서브넷은 노드/워크로드가 쓰지 않는다.
    "alb" = {
      address_prefixes = [local.subnet_cidrs["alb"]]
      nsg_enabled      = true
      delegations = [{
        name = "Microsoft.ServiceNetworking/trafficControllers"
        # ⚠️ 착수 시 재확인: 공식 CLI(`--delegations
        #    'Microsoft.ServiceNetworking/trafficControllers'`)는 내부적으로
        #    이 액션을 쓰는 것으로 알려져 있으나 이 root의 첫 plan에서 실측 확인.
        actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
      }]
    }

    # AKS 노드 자리(Phase 2, live/hub/aks 계획에서 소비 예정). AWS node-uniq 대응.
    # ⚠️ 이 서브넷은 노드 IP 전용이다 — Pod IP 는 여기서 뜨지 않는다(Overlay CNI, Pod
    #    는 VNet 밖 오버레이 CIDR 에서 받는다 — 근거는 위 locals 블록 주석 참고). /20
    #    크기는 노드 수 기준 잠정치다.
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
