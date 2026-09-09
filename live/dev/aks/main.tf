# live/dev/aks — AKS 클러스터 배포 루트 (dev 스포크)
#
# live/hub/aks 를 템플릿으로 복제한 두 번째 인스턴스다. 기능 범위를 hub 와 완전히
# 동일하게 승계한다(Karpenter/NAP + KEDA + App Routing Gateway API/Istio) — 여러
# 세션에 걸쳐 hub 에서 실증된 설계라 여기서 다시 고르지 않는다. 아래 주석의 "실측"
# 근거는 대부분 hub 에서 얻은 것이고, 그 출처를 명시해 뒀다.
#
# ⚠️ 이 root가 자기 identity·role assignment를 직접 만든다(아래
#    azurerm_user_assigned_identity·azurerm_role_assignment). "CI 신원에
#    roleAssignments/write를 주지 않는다"던 방어선이 이제 없어서다(CI가 구독 전체
#    Owner 등가, bootstrap/config.sh 참고). aks-cluster
#    모듈 자체가 identity를 안 만드는 경계 원칙(iac-module-library ADR)은 그대로다 —
#    이 root가 소비자로서 만들어 입력으로 넘기는 것뿐이다.
#
# ⚠️ 네트워킹은 live/dev/networking 이 소유한다. 이 root 는 이미 배포된 aks-node 서브넷을
#    Name 기반 data 로 조회만 한다 — 서브넷을 새로 만들지 않는다.

locals {
  # ── CIDR (모듈 repo 규약: 계산의 소유는 모듈이 아니라 소비자 루트) ─────────────
  #
  # Azure CNI Overlay 라 Pod IP 는 VNet **밖**의 이 오버레이 대역에서 뜬다 — hub VNet
  # (10.60.0.0/16)·dev VNet(10.61.0.0/16)·vHub(10.62.0.0/22) 어느 것과도 겹치지 않고,
  # 애초에 겹쳐도 무해하다. Overlay 는 Pod 트래픽을 VNet/vWAN 에 노출하지 않고(클러스터
  # 밖으로 나갈 때 노드 IP 로 SNAT) 각 클러스터의 오버레이가 서로 독립이기 때문이다.
  # 그래서 이 값은 live/hub/aks 와 **의도적으로 같다** — 스포크마다 다르게 둘 이유가 없다
  # (live/hub/aks/main.tf 의 같은 자리 주석이 이 승계를 미리 명시해 뒀다).
  #
  # 값 자체는 임의 추정이 아니라 aks-cluster 모듈 examples/basic 과 az aks create 의
  # 관용 기본값을 그대로 채택한 것이다.
  #
  # ⚠️ network_profile 블록 전체가 provider 에 의해 ForceNew 다 — 이 값과 cni_mode 를
  #    나중에 바꾸면 클러스터가 재생성된다. 첫 apply 가 사실상 최종 선택이다.
  pod_cidr = "10.244.0.0/16"

  # service_cidr·dns_service_ip 는 **의도적으로 지정하지 않는다**(provider 기본값 사용,
  # 통상 10.0.0.0/16). pod_cidr 처럼 명시하지 않는 이유: 클러스터 로컬 값이라 다른
  # 클러스터와 중복돼도 무해하고 hub·dev VNet 과도 충돌하지 않아, 지금 고정할 실익이
  # 없다(YAGNI). 다만 이 축도 ForceNew 라 나중에 명시하려면 클러스터 재생성을 각오해야
  # 한다 — CLAUDE.md 3절이 요구하는 "CIDR 배치의 실물 SSOT 는 각 루트 locals 주석" 규칙에
  # 따라 미지정 사실 자체를 여기 남긴다.

  # 사람이 선생성한 워크로드 RG(bootstrap 기대 상태 문서 참고). 이 root 는 RG 를 만들지
  # 않는다 — aks-cluster 모듈이 RG 를 만들지 않는 설계와 일관된다(파괴 반경 한정).
  resource_group_name = "rg-${var.workload}-${var.env}-${var.region_code}-workload-01"

  # azurerm 은 provider 레벨 default_tags 인자가 없어 여기서 명시 배선한다
  # (live/dev/networking·live/hub/aks 와 동일 근거, aks-cluster 모듈 README 확인).
  tags = {
    Environment = var.env
    Workload    = var.workload
    RegionCode  = var.region_code
    ManagedBy   = "opentofu"
    Repository  = var.repository
  }
}

# 노드가 붙을 서브넷은 live/dev/networking 이 이미 만들어 뒀다(nat_routed = true 포함 —
# aks-cluster 모듈이 하드코딩한 outbound_type = "userAssignedNATGateway" 요구를 이미
# 만족한다. live/dev/networking/main.tf 의 aks-node 그룹 참고). 같은 구독·같은 RG 라
# 추가 권한이 필요 없다.
#
# ⛔ terraform_remote_state 를 쓰지 않는다 — 루트 간 결합은 Name 기반 data 조회다
#    (CLAUDE.md 1절). 이름을 하드코딩하지 않고 naming 토큰 3개로 재조합하는 이유도 같다:
#    vnet 모듈이 "snet-<workload>-<env>-<region_code>-<그룹키>" 로 합성하므로
#    (modules/azure/vnet/main.tf), 두 root 가 같은 토큰을 공유하는 것 자체가 결합 수단이다.
data "azurerm_subnet" "aks_node" {
  name                 = "snet-${var.workload}-${var.env}-${var.region_code}-aks-node"
  virtual_network_name = "vnet-${var.workload}-${var.env}-${var.region_code}-main"
  resource_group_name  = local.resource_group_name
}

# AKS 컨트롤 플레인이 쓰는 user-assigned managed identity. aks-cluster 모듈은 이걸
# 만들지 않고 입력으로만 받는다(모듈 경계 원칙, iac-module-library ADR) — 소비자인
# 이 root가 만들어 넘긴다. 이름은 live/hub/aks 와 같은 naming 규칙을 따른다
# (env 토큰만 dev 로 갈린다: id-demo-dev-krc-aks-01).
resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-${var.workload}-${var.env}-${var.region_code}-aks-01"
  resource_group_name = local.resource_group_name
  location            = var.location
  tags                = local.tags
}

# MS 공식 문서(concepts-network-cni-overview)의 BYO-VNet 최소 권고: "at least Network
# Contributor permissions on the subnet". AKS가 네트워킹까지 자동 관리하는 기본
# 시나리오의 기본값(노드 리소스 그룹 전체 Contributor)보다 훨씬 좁다 — 이 root는
# VNet을 live/dev/networking이 소유하는 BYO-VNet 시나리오라 이 최소치로 충분하다.
#
# skip_service_principal_aad_check: 방금 만든 identity에 role을 붙이는 것이라 AAD
# 복제 지연으로 PrincipalNotFound가 날 수 있다 — provider가 이 플래그로 그 검사를
# 건너뛰고 흡수한다(bootstrap.sh가 예전에 bash 재시도로 흡수하던 문제와 동일 클래스,
# 이제 provider가 대신 해결한다).
resource "azurerm_role_assignment" "aks_node_subnet" {
  scope                            = data.azurerm_subnet.aks_node.id
  role_definition_name             = "Network Contributor"
  principal_id                     = azurerm_user_assigned_identity.aks.principal_id
  skip_service_principal_aad_check = true
}

module "aks_cluster" {
  # ⛔ 소싱 URL 은 git::https:// 하나로 유지한다(모듈 repo 규약, AWS 원본과 동일 근거).
  # ⛔ ?ref= 는 정확 태그 핀이다. git 소싱에 ~> 는 동작하지 않는다.
  #
  # ref 는 v0.8.0 — 여기서 처음으로 hub(v0.7.0 유지)와 갈라진다. 지금까지 "hub 와
  # 같은 태그" 원칙을 지켜온 건 두 클러스터가 같은 기능 범위(Karpenter/NAP·KEDA·
  # App Routing)를 승계했기 때문인데, entra_integration_enabled(v0.8.0 신설, 아래)는
  # dev 고유 요구사항이다 — hub 의 self-managed ArgoCD 는 자기 자신이 도는 클러스터를
  # 가리키는 self-hosting 지름길(cluster-secret 의 server: https://kubernetes.default.svc)
  # 만 쓰므로 Entra RBAC 노출이 필요 없고, dev 는 hub 구독의 ArgoCD 가 크로스 구독으로
  # 접근해야 해서 필요하다(dev-gitops-registration 설계). hub 가 v0.7.0 에 도달하기까지의
  # 경위(v0.3.0 의 cilium/network_policy 정합성 오류 → v0.4.0, upgrade_settings 미선언으로
  # 인한 perpetual diff → v0.5.0, KEDA 변수 신설 → v0.6.0, web_app_routing passthrough
  # 신설 → v0.7.0)는 live/hub/aks/main.tf 의 같은 자리 주석이 전부 기록하고 있다 — 여기서
  # 중복 서술하지 않는다.
  source = "git::https://github.com/skax-ca/iac-module-library.git//modules/azure/aks-cluster?ref=aks-cluster-v0.9.0&depth=1"

  # 소비자는 리소스 타입 약어를 타이핑하지 않는다 — 모듈이 조합한다(모듈 repo 규약).
  # {demo, dev, krc} → aks-demo-dev-krc-main-01
  naming = {
    workload    = var.workload
    env         = var.env
    region_code = var.region_code
  }

  resource_group_name = local.resource_group_name
  location            = var.location

  identity_id = azurerm_user_assigned_identity.aks.id

  # role assignment는 module의 identity_id 참조만으로는 자동으로 순서가 안 잡힌다
  # (모듈이 role assignment 리소스를 참조하지 않으므로 암묵적 의존이 없다) — 명시한다.
  # 이게 없으면 role assignment 전에 identity가 클러스터에 붙어 노드가 서브넷 join에
  # 조용히 실패할 수 있다(옛 bootstrap의 "순서 의존" 문제를 Terraform 그래프로 재현한 것).
  depends_on = [azurerm_role_assignment.aks_node_subnet]

  # ── 네트워킹 ────────────────────────────────────────────────────────────────
  #
  # cni_mode 는 모듈 기본값과 같지만 명시한다 — ForceNew 축이라 "기본값이 바뀌면 클러스터가
  # 재생성된다"가 성립하는 자리다. 기각한 대안: "node_subnet"(SNAT 없어 Pod 단위 관측성
  # 유지, NAP 호환)은 서브넷 하나가 노드+Pod IP 를 함께 감당해 aks-node(/20) 사이징을
  # 다시 계산해야 하고, 그러면 이미 배포된 live/dev/networking 까지 건드리게 된다.
  cni_mode       = "overlay"
  pod_cidr       = local.pod_cidr
  node_subnet_id = data.azurerm_subnet.aks_node.id

  # KEDA managed add-on(아래 enable_keda)이 공식 문서가 요구하는 순서(Workload
  # Identity 먼저)를 만족하려면 클러스터의 workload identity 웹훅이 켜져 있어야
  # 한다. 모듈은 oidc_issuer_enabled를 이 값과 무관하게 항상 켜지만(모듈 main.tf
  # 확인, workload_identity_enabled 변수 설명 참고), 웹훅 자체는 이 값이 true여야 뜬다.
  #
  # ⚠️ ForceNew 아님 - azurerm provider 소스(kubernetes_cluster_resource.go) 확인
  # 결과 CustomizeDiff의 ForceNew 목록에 이 필드가 없고, HasChanges 시 in-place
  # update 경로(ManagedClusters.CreateOrUpdate)가 있다. 클러스터 재생성 승인 불필요.
  workload_identity_enabled = true

  # ── Entra RBAC(크로스 구독 GitOps 접근) ────────────────────────────────────
  #
  # ⛔ 비가역 — Azure 공식 문서(managed-azure-ad): "Microsoft Entra integration
  # can't be disabled after it's enabled on a cluster." 되돌리려면 클러스터
  # 재생성이 필요하다. `az aks update --disable-azure-rbac`는 azure_rbac_enabled
  # 만 개별로 끌 뿐 Entra 통합 자체는 못 끈다.
  #
  # entra_admin_group_object_ids는 넘기지 않는다(모듈 기본값 [] 유지) — 사람 admin
  # 그룹은 만들지 않는다. 접근 권한은 이 블록이 아니라 클러스터 리소스 ID 스코프의
  # azurerm_role_assignment로 개별 부여한다(workbench UAMI·hub ArgoCD UAMI 각각
  # 별도 커밋 — dev-gitops-registration 설계 7차, Step 6·7). local_account_disabled
  # 는 건드리지 않는다(모듈 기본값 false 유지, G2 원칙) — 로컬 admin kubeconfig
  # (break-glass) 경로는 그대로 살려둔다.
  #
  # ⚠️ ForceNew 아님 — azurerm provider 소스(kubernetes_cluster_resource.go)
  # 확인 결과 azure_active_directory_role_based_access_control 블록은
  # CustomizeDiff의 ForceNew 목록에 없고 in-place 업데이트 경로
  # (ResetAADProfileThenPoll)가 있다. 클러스터 재생성 없이 반영된다.
  entra_integration_enabled = true

  # 모듈 기본값과 같지만 명시한다(위 cni_mode 와 같은 이유 — 이 값도 ForceNew 다).
  # GitOps(pull) 전제라 공개 엔드포인트가 필요 없다. private 클러스터라도 검증은
  # `az aks command invoke`(ARM 경유)로 workbench 없이 가능하다 — dev 에는 hub 의
  # workbench 같은 운영 VM 이 없으므로 이 경로가 유일한 kubectl 접근 수단이다.
  private_cluster_enabled = true

  # dev-gitops-registration 설계 8차(2026-09-09) — hub의 self-managed ArgoCD가 이
  # 클러스터를 크로스 구독으로 관리하려면 API 서버 이름 해석이 돼야 한다. 당초 계획한
  # private DNS zone VNet link(Step 9, hub VNet을 이 zone에 추가 링크)는 AWS EKS 조사
  # 결과 근본적으로 불필요하다고 판단해 대체했다 — AWS 공식 문서(cluster-endpoint.html)
  # 확인 결과 EKS의 private-only 엔드포인트는 "resolved by public DNS servers to a
  # private IP address"로 동작해 zone 링크 자체가 없다. Azure도 이 필드로 같은 효과를
  # 낸다 — 이름은 공개 DNS로 풀리지만 반환되는 IP는 여전히 private다(공식 문서: "A
  # public FQDN doesn't create a public API endpoint or remove the requirement for
  # network connectivity to the private endpoint"). ForceNew 아님(모듈 변수 설명·
  # provider 소스 확인 완료, aks-cluster-v0.9.0에서 신설) — 이미 떠 있는 이 클러스터에도
  # 재생성 없이 적용된다.
  private_cluster_public_fqdn_enabled = true

  # ── 노드 프로비저닝 ──────────────────────────────────────────────────────────
  #
  # hub 와 동일 정책이다: azurerm 공식 문서(kubernetes_cluster.html.markdown) 확인 결과
  # node_provisioning_profile.mode는 ForceNew 표시가 없어 in-place 전환이며, cni_mode=overlay
  # (ForceNew라 이미 확정된 값)는 karpenter-provider-azure가 지원하지 않는 pod_subnet이 아니라
  # 이 모듈의 validation을 통과한다. 아래 system_node_pool의 auto_scaling_enabled = false도
  # 이 모드의 전제조건이라 이미 충족돼 있다.
  #
  # ⚠️ NodePool/AKSNodeClass CR 자체는 이 root 가 아니라 aks-platform-gitops 의 catalog
  # addon(addons/catalog/karpenter.yaml)이 배포한다 — 그 저장소의 cluster Secret 에
  # 이 dev 클러스터를 등록하고 addon-karpenter: enabled 라벨을 붙이기 전까지는
  # "정책 없이 mode=Auto만 도는" 상태다(그 등록은 이 저장소 범위 밖의 후속 작업).
  enable_karpenter = true

  # KEDA managed add-on(aks-cluster v0.6.0에서 신설). Karpenter/NAP과 달리 GitOps 소관 CR이
  # 없다 — ScaledObject/ScaledJob은 애플리케이션 팀이 직접 워크로드에 선언하는 리소스라
  # 플랫폼 GitOps가 미리 갖출 것이 없다(enable_keda 변수 설명 참조). workload_identity_enabled
  # 는 이미 true라 공식 문서가 요구하는 순서(Workload Identity 먼저) 조건을 만족한다.
  enable_keda = true

  # App Routing 오퍼레이터(DNS/TLS 통합)를 켠다 — azurerm이 실제로 아는 하위 필드만
  # 여기서 선언한다(모듈 v0.7.0의 web_app_routing 변수 설명 참조). Gateway API/Istio
  # 필드는 azurerm 스키마 밖이라 여전히 아래 azapi_update_resource가 담당한다 — 이
  # 값 하나만으로는 App Routing이 완성되지 않는다.
  web_app_routing = {
    # 레거시 NGINX 기반 IngressClass 자동 생성을 명시적으로 끈다 — 이 저장소는 Gateway
    # API 경로만 쓴다(ingress-nginx 업스트림 은퇴 공지, aks-platform-gitops의
    # addons/baseline/gateway.yaml 헤더 참고). 생략하면 provider 기본값
    # (AnnotationControlled)이 적용돼 원치 않는 NGINX 컨트롤러가 함께 뜬다.
    default_nginx_controller = "None"
  }

  # 시스템 노드 풀. vm_size·node_count 는 hub 와 동일 값(모듈 examples/basic·README
  # Usage 예시값)이다.
  #
  # ⚠️ dev 구독의 vCPU 쿼터는 hub 구독과 별개다. 첫 apply 전에
  #    `az vm list-usage --location koreacentral`로 Standard DSv5 Family 여유를
  #    확인한다 — 부족하면 apply 가 쿼터 오류로 실패한다.
  # ⚠️ max_pods 를 명시하지 않으면 Overlay 기본값 250 이 그대로 적용되는데,
  #    Standard_D2s_v5(2 vCPU / 8 GiB)에 250 은 비현실적이다(kubelet 예약만으로도 부족).
  #    데모 규모에 맞춰 30 으로 낮춘다.
  # ⚠️ auto_scaling_enabled = false 는 규모 결정이자 위 enable_karpenter 의 전제조건이다 —
  #    true 로 바꾸면 시스템 풀을 다시 고정 크기로 되돌려야 하는 지뢰가 된다.
  system_node_pool = {
    vm_size              = "Standard_D2s_v5"
    node_count           = 2
    auto_scaling_enabled = false
    max_pods             = 30
  }

  # workload = demo 레퍼런스 목적이라 Uptime SLA 가 필요 없다. Standard 로의 전환은
  # in-place 라 가역적이다.
  sku_tier = "Free"

  # ⛔ true 로 올리지 않는다. 모듈이 이 값을 prevent_destroy 로 구현하는데(모듈 main.tf),
  #    prevent_destroy 는 파괴뿐 아니라 **ForceNew 교체까지 차단**한다. ForceNew 축
  #    (network_profile 블록 전체 + 최상위 private_cluster_enabled)이 확정되기 전에 켜면
  #    앞으로의 변경 자체가 plan 에서 막힌다 — "반복 단계라서"가 아니라 그것이 이유다.
  #
  # 실수 삭제의 실제 방어선은 이 인자가 아니라 다른 층이다: state 백엔드 RBAC
  # (allowSharedKeyAccess=false + Blob 데이터 역할이 CI SP 전용이라 사람의 로컬 destroy 는
  # state 접근 단계에서 막힌다) + CI destroy 의 confirm 문자열 정확 일치.
  # ForceNew 축이 확정된 뒤 true 로 전환한다(아직 미확정).
  deletion_protection = false

  tags = local.tags
}

# ── AKS App Routing(Gateway API/Istio 기반) 활성화 ────────────────────────────
#
# hub 와 동일 구성이다. 이 저장소는 AGFC(Application Gateway for Containers)를 쓰지
# 않는다 — AGFC frontend 는 공인 FQDN만 지원해(private/internal 옵션 없음, Microsoft
# 공식 문서로 확정: learn.microsoft.com/en-us/azure/application-gateway/for-containers/
# application-gateway-for-containers-components — "Private IP addresses aren't
# currently supported") "전부 private" 원칙과 부딪힌다. App Routing 은 AKS 가
# 컨트롤러·CRD·GatewayClass를 전부 관리하는 GA 경로다(내부 LB는 표준 Service
# annotation 하나로 끝난다 — 자세한 경위는 aks-platform-gitops의
# addons/baseline/gateway.yaml 헤더 참조).
#
# 🔴 azurerm 프로바이더는 아직 이 기능(`az aks update --enable-gateway-api
# --enable-app-routing-istio`에 대응하는 ingressProfile 필드)을 노출하지 않는다
# (hashicorp/terraform-provider-azurerm#22392, 확인 시점 2026-09-07) — azapi로
# 이 클러스터(azurerm 관리)의 ARM 리소스 위에 그 속성만 얹는다. 이 패턴은 Microsoft
# 공식 가이드가 직접 권장하는 조합이다(learn.microsoft.com/en-us/azure/developer/
# terraform/provider-selection-azurerm-vs-azapi의 "When to use both providers
# together" 절 — azurerm이 관리하는 AKS 클러스터에 azapi_update_resource로
# networkProfile 같은 미노출 필드를 얹는 예시가 그 문서의 정식 예제다).
#
# ✅ 아래 필드 조합은 hub 에서 실제 CI apply 로 검증됐다(2026-09-07, run 34106148693 —
# "Apply complete! Resources: 1 added"). 그리고 그 첫 apply 직후 azurerm 이
# ingressProfile.webAppRouting 을 지우려는 비수렴 diff 를 냈던 문제는 모듈
# aks-cluster-v0.7.0 의 web_app_routing passthrough(위 module.aks_cluster 인자)로
# 해소됐다 — 이 azapi 리소스는 azurerm 스키마 밖의 두 필드(gatewayAPI·
# gatewayAPIImplementations)만 담당한다.
#
# ⚠️ hub 의 apply 중 한 번은 실패했는데, 필드 구조가 아니라 클러스터에 이미 있던 다른
# Gateway API CRD(구 AGFC alb-controller 차트가 설치해 둔 bundle v1.5.1)와 Managed
# Gateway API가 요구하는 bundle(v1.4.1)이 충돌해서였다. dev 는 AGFC 를 쓴 적이 없어
# 이 충돌이 재현될 이유가 없다 — 그래도 같은 증상이 나오면 `kubectl get crd`로
# 잔존 CRD를 대조하는 같은 진단으로 접근한다.
#
# ⚠️ azapi_update_resource 는 자기 body 의 drift 를 스스로 감지하지 않는다(공식 문서:
# 속성 자체의 상태를 추적하지 않는다). apply 할 때마다 plan 에 module.aks_cluster 의
# web_app_routing 관련 diff 가 없는지 확인하는 습관은 유지한다.
resource "azapi_update_resource" "aks_app_routing_gateway_api" {
  type        = "Microsoft.ContainerService/managedClusters@2026-04-02-preview"
  resource_id = module.aks_cluster.cluster_id

  # ⚠️ webAppRouting.enabled·nginx는 이 body에 없다 — module.aks_cluster의
  # web_app_routing 인자(azurerm 관리)가 그 하위 필드를 담당한다(위 헤더 주석 참고).
  # 이 리소스는 azurerm 스키마 밖의 두 필드만 PATCH한다. azapi_update_resource는
  # ignore_missing_property=true(기본값)라 이 body에 없는 형제 필드(enabled·nginx)를
  # 덮어쓰지 않는다 — 부분 병합이지 전체 치환이 아니다.
  body = {
    properties = {
      ingressProfile = {
        # Managed Gateway API installation — `az aks update --enable-gateway-api`에
        # 대응(learn.microsoft.com/en-us/azure/aks/managed-gateway-api). CRD만
        # 설치하고 관리한다 — 실제 구현체(Istio)는 아래 webAppRouting이 켠다.
        gatewayAPI = {
          installation = "Standard"
        }
        webAppRouting = {
          gatewayAPIImplementations = {
            appRoutingIstio = {
              # `--enable-app-routing-istio`에 대응. GatewayClass 이름은 AKS가
              # `approuting-istio`로 고정 생성한다(learn.microsoft.com/en-us/azure/
              # aks/app-routing-gateway-api).
              mode = "Enabled"
            }
          }
        }
      }
    }
  }
}
