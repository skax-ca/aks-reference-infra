# live/dev/aks: AKS 클러스터 배포 루트 (dev 스포크)
#
# live/hub/aks 를 템플릿으로 복제한 두 번째 인스턴스다. 기능 범위를 hub 와 동일하게
# 승계한다(Karpenter/NAP + KEDA + App Routing Gateway API/Istio). hub 와 갈리는 것은
# 크로스 구독 GitOps 등록에 필요한 Entra RBAC·공개 FQDN·hub ArgoCD role assignment다.
#
# ⚠️ 이 root가 자기 identity·role assignment를 직접 만든다(아래
#    azurerm_user_assigned_identity·azurerm_role_assignment). CI 신원이 구독 전체
#    Owner 등가라 가능하다(bootstrap/config.sh 참고). aks-cluster 모듈 자체가 identity를
#    안 만드는 경계 원칙(iac-module-library docs/decisions.md 「모듈 경계」)은 그대로다.
#    이 root가 소비자로서 만들어 입력으로 넘기는 것뿐이다.
#
# ⚠️ 네트워킹은 live/dev/networking 이 소유한다. 이 root 는 이미 배포된 aks-node 서브넷을
#    Name 기반 data 로 조회만 한다. 서브넷을 새로 만들지 않는다.

locals {
  # ── CIDR (모듈 repo 규약: 계산의 소유는 모듈이 아니라 소비자 루트) ─────────────
  #
  # Azure CNI Overlay 라 Pod IP 는 VNet **밖**의 이 오버레이 대역에서 뜬다. hub VNet
  # (10.60.0.0/16)·dev VNet(10.61.0.0/16)·vHub(10.62.0.0/22) 어느 것과도 겹치지 않고,
  # 애초에 겹쳐도 무해하다. Overlay 는 Pod 트래픽을 VNet/vWAN 에 노출하지 않고(클러스터
  # 밖으로 나갈 때 노드 IP 로 SNAT) 각 클러스터의 오버레이가 서로 독립이기 때문이다.
  # 그래서 이 값은 live/hub/aks 와 **의도적으로 같다**. 스포크마다 다르게 둘 이유가 없다.
  #
  # 값 자체는 임의 추정이 아니라 aks-cluster 모듈 examples/basic 과 az aks create 의
  # 관용 기본값을 그대로 채택한 것이다.
  #
  # ⚠️ network_profile 블록 전체가 provider 에 의해 ForceNew 다. 이 값과 cni_mode 를
  #    나중에 바꾸면 클러스터가 재생성된다. 첫 apply 가 사실상 최종 선택이다.
  pod_cidr = "10.244.0.0/16"

  # service_cidr·dns_service_ip 는 **의도적으로 지정하지 않는다**(provider 기본값 사용,
  # 통상 10.0.0.0/16). pod_cidr 처럼 명시하지 않는 이유: 클러스터 로컬 값이라 다른
  # 클러스터와 중복돼도 무해하고 hub·dev VNet 과도 충돌하지 않아, 지금 고정할 실익이
  # 없다(YAGNI). 다만 이 축도 ForceNew 라 나중에 명시하려면 클러스터 재생성을 각오해야
  # 한다. CIDR 배치의 실물 SSOT 는 각 루트 locals 주석이므로 미지정 사실 자체를 여기 남긴다.

  # 사람이 선생성한 워크로드 RG(bootstrap 기대 상태 문서 참고). 이 root 는 RG 를 만들지
  # 않는다. aks-cluster 모듈이 RG 를 만들지 않는 설계와 일관된다(파괴 반경 한정).
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

# 노드가 붙을 서브넷은 live/dev/networking 이 이미 만들어 뒀다(nat_routed = true 포함.
# aks-cluster 모듈이 하드코딩한 outbound_type = "userAssignedNATGateway" 요구를 이미
# 만족한다. live/dev/networking/main.tf 의 aks-node 그룹 참고). 같은 구독·같은 RG 라
# 추가 권한이 필요 없다.
#
# ⛔ terraform_remote_state 를 쓰지 않는다. 루트 간 결합은 Name 기반 data 조회다
#    (CLAUDE.md 「저장소 구조」). 이름을 하드코딩하지 않고 naming 토큰 3개로 재조합하는 이유도 같다:
#    vnet 모듈이 "snet-<workload>-<env>-<region_code>-<그룹키>" 로 합성하므로
#    (modules/azure/vnet/main.tf), 두 root 가 같은 토큰을 공유하는 것 자체가 결합 수단이다.
data "azurerm_subnet" "aks_node" {
  name                 = "snet-${var.workload}-${var.env}-${var.region_code}-aks-node"
  virtual_network_name = "vnet-${var.workload}-${var.env}-${var.region_code}-main"
  resource_group_name  = local.resource_group_name
}

# AKS 컨트롤 플레인이 쓰는 user-assigned managed identity. aks-cluster 모듈은 이걸
# 만들지 않고 입력으로만 받는다(모듈 경계 원칙, iac-module-library docs/decisions.md).
# 소비자인 이 root가 만들어 넘긴다. 이름은 live/hub/aks 와 같은 naming 규칙을 따른다
# (env 토큰만 dev 로 갈린다: id-demo-dev-krc-aks-01).
resource "azurerm_user_assigned_identity" "aks" {
  name                = "id-${var.workload}-${var.env}-${var.region_code}-aks-01"
  resource_group_name = local.resource_group_name
  location            = var.location
  tags                = local.tags
}

# MS 공식 문서(concepts-network-cni-overview)의 BYO-VNet 최소 권고: "at least Network
# Contributor permissions on the subnet". AKS가 네트워킹까지 자동 관리하는 기본
# 시나리오의 기본값(노드 리소스 그룹 전체 Contributor)보다 훨씬 좁다. 이 root는
# VNet을 live/dev/networking이 소유하는 BYO-VNet 시나리오라 이 최소치로 충분하다.
#
# skip_service_principal_aad_check: 방금 만든 identity에 role을 붙이는 것이라 AAD
# 복제 지연으로 PrincipalNotFound가 날 수 있다. provider가 이 플래그로 그 검사를
# 건너뛰고 흡수한다(bootstrap.sh의 retry_on_replication_delay가 bash로 흡수하는 것과
# 같은 클래스의 문제).
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
  # hub 보다 높은 태그를 쓴다. entra_integration_enabled·private_cluster_public_fqdn_enabled
  # (아래)는 dev 고유 요구사항이라 hub 가 쓰는 태그에 없다. hub 의 self-managed ArgoCD 는
  # 자기 자신이 도는 클러스터를 가리키는 self-hosting 지름길(cluster-secret 의
  # server: https://kubernetes.default.svc)만 쓰므로 Entra RBAC 노출이 필요 없고, dev 는
  # hub 구독의 ArgoCD 가 크로스 구독으로 접근해야 해서 필요하다.
  # ⚠️ 태그를 내리면 아래 인자가 "Unsupported argument"로 깨진다. 태그를 올릴 때는 모듈
  #    CHANGELOG(태그 메시지)로 ForceNew 축 변경 여부를 먼저 본다.
  source = "git::https://github.com/skax-ca/iac-module-library.git//modules/azure/aks-cluster?ref=aks-cluster-v0.9.0&depth=1"

  # 소비자는 리소스 타입 약어를 타이핑하지 않는다. 모듈이 조합한다(모듈 repo 규약).
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
  # (모듈이 role assignment 리소스를 참조하지 않으므로 암묵적 의존이 없다). 명시한다.
  # 이게 없으면 role assignment 전에 identity가 클러스터에 붙어 노드가 서브넷 join에
  # 조용히 실패할 수 있다(옛 bootstrap의 "순서 의존" 문제를 Terraform 그래프로 재현한 것).
  depends_on = [azurerm_role_assignment.aks_node_subnet]

  # ── 네트워킹 ────────────────────────────────────────────────────────────────
  #
  # cni_mode 는 모듈 기본값과 같지만 명시한다. ForceNew 축이라 "기본값이 바뀌면 클러스터가
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
  # ForceNew 아님. azurerm provider 소스(kubernetes_cluster_resource.go)의 CustomizeDiff
  # ForceNew 목록에 이 필드가 없고, HasChanges 시 in-place update 경로
  # (ManagedClusters.CreateOrUpdate)가 있다. 클러스터 재생성 승인 불필요.
  workload_identity_enabled = true

  # ── Entra RBAC(크로스 구독 GitOps 접근) ────────────────────────────────────
  #
  # ⛔ 비가역. Azure 공식 문서(managed-azure-ad): "Microsoft Entra integration
  # can't be disabled after it's enabled on a cluster." 되돌리려면 클러스터
  # 재생성이 필요하다. `az aks update --disable-azure-rbac`는 azure_rbac_enabled
  # 만 개별로 끌 뿐 Entra 통합 자체는 못 끈다.
  #
  # entra_admin_group_object_ids는 넘기지 않는다(모듈 기본값 [] 유지). 사람 admin
  # 그룹은 만들지 않는다. 접근 권한은 이 블록이 아니라 클러스터 리소스 ID 스코프의
  # azurerm_role_assignment로 개별 부여한다(workbench UAMI는 live/dev/workbench가,
  # hub ArgoCD UAMI는 이 root 아래 절이 만든다). local_account_disabled 는 건드리지
  # 않는다(모듈 기본값 false 유지). 로컬 admin kubeconfig(break-glass) 경로는 그대로 살려둔다.
  #
  # ForceNew 아님. azurerm provider 소스(kubernetes_cluster_resource.go)에서
  # azure_active_directory_role_based_access_control 블록은 CustomizeDiff의 ForceNew
  # 목록에 없고 in-place 업데이트 경로(ResetAADProfileThenPoll)가 있다. 클러스터 재생성
  # 없이 반영된다.
  entra_integration_enabled = true

  # 모듈 기본값과 같지만 명시한다(위 cni_mode 와 같은 이유. 이 값도 ForceNew 다).
  # GitOps(pull) 전제라 공개 엔드포인트가 필요 없다. private 클러스터라도 검증은
  # `az aks command invoke`(ARM 경유)로 workbench 없이 가능하다.
  private_cluster_enabled = true

  # hub의 self-managed ArgoCD가 이 클러스터를 크로스 구독으로 관리하려면 API 서버 이름
  # 해석이 돼야 한다. private DNS zone을 hub VNet에 링크하는 대신 공개 FQDN을 켠다. 이름은
  # 공개 DNS로 풀리지만 반환되는 IP는 여전히 private다(공식 문서: "A public FQDN doesn't
  # create a public API endpoint or remove the requirement for network connectivity to
  # the private endpoint"). AWS EKS의 private-only 엔드포인트가 "resolved by public DNS
  # servers to a private IP address"로 동작하는 것과 같은 모양이다. ForceNew 아님(모듈
  # 변수 설명·provider 소스 확인). 근거는 iac-module-library
  # docs/architectures/gitops-hub-spoke/azure/network.md 「스포크 API 서버에 도달하기」.
  # ⚠️ 클러스터를 재생성하면 FQDN의 무작위 접미사가 바뀐다. aks-platform-gitops의
  #    cluster Secret·AppProject destination을 갱신한다(docs/spoke-lifecycle.md).
  private_cluster_public_fqdn_enabled = true

  # ── 노드 프로비저닝 ──────────────────────────────────────────────────────────
  #
  # hub 와 동일 정책이다. NAP(Karpenter)은 정책(NodePool·AKSNodeClass CR)이 있어야
  # 동작한다. 그 CR은 aks-platform-gitops의 catalog addon(addons/catalog/karpenter.yaml)이
  # cluster Secret의 addon-karpenter: enabled 라벨로 옵트인해 배포한다. 이 값만 켜고 CR이
  # 없으면 mode=Auto만 도는 죽은 설정이다. node_provisioning_profile.mode는 ForceNew가
  # 아니라 in-place 전환이고, cni_mode=overlay는 karpenter-provider-azure가 지원하지 않는
  # pod_subnet이 아니라 모듈 validation을 통과한다. 아래 system_node_pool의
  # auto_scaling_enabled = false가 전제 조건이다.
  enable_karpenter = true

  # KEDA managed add-on. Karpenter/NAP과 달리 GitOps 소관 CR이 없다.
  # ScaledObject/ScaledJob은 애플리케이션 팀이 직접 워크로드에 선언하는 리소스라
  # 플랫폼 GitOps가 미리 갖출 것이 없다(enable_keda 변수 설명 참조). workload_identity_enabled
  # 는 이미 true라 공식 문서가 요구하는 순서(Workload Identity 먼저) 조건을 만족한다.
  enable_keda = true

  # App Routing 오퍼레이터(DNS/TLS 통합)를 켠다. azurerm이 실제로 아는 하위 필드만
  # 여기서 선언한다(모듈의 web_app_routing 변수 설명 참조). Gateway API/Istio 필드는
  # azurerm 스키마 밖이라 아래 azapi_update_resource가 담당한다. 이 값 하나만으로는
  # App Routing이 완성되지 않는다.
  #
  # ⚠️ 이 인자를 빼지 않는다. azapi가 얹는 ingressProfile.webAppRouting 하위 필드를
  #    azurerm이 읽고 "HCL에 없는 블록"으로 보아 매 plan마다 지우려 한다.
  web_app_routing = {
    # 레거시 NGINX 기반 IngressClass 자동 생성을 명시적으로 끈다. 이 저장소는 Gateway
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
  #    확인한다. 부족하면 apply 가 쿼터 오류로 실패한다.
  # ⚠️ max_pods 를 명시하지 않으면 Overlay 기본값 250 이 그대로 적용되는데,
  #    Standard_D2s_v5(2 vCPU / 8 GiB)에 250 은 비현실적이다(kubelet 예약만으로도 부족).
  #    데모 규모에 맞춰 30 으로 낮춘다.
  # ⚠️ auto_scaling_enabled = false 는 규모 결정이자 위 enable_karpenter 의 전제조건이다.
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
  #    앞으로의 변경 자체가 plan 에서 막힌다. "반복 단계라서"가 아니라 그것이 이유다.
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
# hub 와 동일 구성이다. 근거는 live/hub/aks/main.tf 의 같은 절에 있다(AGFC를 쓰지 않는
# 이유, azurerm 미노출 필드를 azapi로 얹는 이유, 잔존 Gateway API CRD 충돌, azapi가
# body drift를 감지하지 않는 점). 여기서 반복하지 않는다.
resource "azapi_update_resource" "aks_app_routing_gateway_api" {
  type        = "Microsoft.ContainerService/managedClusters@2026-04-02-preview"
  resource_id = module.aks_cluster.cluster_id

  # ⚠️ webAppRouting.enabled·nginx는 이 body에 없다. module.aks_cluster의
  # web_app_routing 인자(azurerm 관리)가 그 하위 필드를 담당한다(위 헤더 주석 참고).
  # 이 리소스는 azurerm 스키마 밖의 두 필드만 PATCH한다. azapi_update_resource는
  # ignore_missing_property=true(기본값)라 이 body에 없는 형제 필드(enabled·nginx)를
  # 덮어쓰지 않는다. 부분 병합이지 전체 치환이 아니다.
  body = {
    properties = {
      ingressProfile = {
        # Managed Gateway API installation. `az aks update --enable-gateway-api`에
        # 대응(learn.microsoft.com/en-us/azure/aks/managed-gateway-api). CRD만
        # 설치하고 관리한다. 실제 구현체(Istio)는 아래 webAppRouting이 켠다.
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

# ── hub ArgoCD UAMI 발견 + 자기 자신에 대한 role assignment ────────────────────
#
# 권한은 리소스를 소유하는 쪽이 만든다. hub ArgoCD가 이 클러스터에 접근할 role
# assignment는 hub가 스포크를 발견해 hub state 안에 만드는 것이 아니라, dev 자신의 apply
# 안에서 dev 자신의 구독 전체 Owner 권한으로 만든다. hub에서 받는 것은 UAMI를 찾는 read
# 권한(hub-peer 역할)뿐이다. 근거는 iac-module-library
# docs/architectures/gitops-hub-spoke/azure/README.md 「클러스터 등록」.
#
# 2단 조회다. azurerm_resources.resources는 {id,location,name,resource_group_name,tags,type}
# 만 반환하고 identity/principal_id가 없다(`tofu providers schema -json`). 1단만으로는
# principal_id가 null이라 아래 role assignment가 count=0으로 조용히 무동작한다. 그래서
# 1단(리스트, soft-fail)으로 이름만 얻고, 2단(명명 조회 data "azurerm_user_assigned_identity")
# 에서 principal_id를 얻는다.
data "azurerm_resources" "hub_argocd_uami" {
  provider = azurerm.hub

  resource_group_name = "rg-${var.workload}-hub-${var.region_code}-workload-01"
  type                = "Microsoft.ManagedIdentity/userAssignedIdentities"
  required_tags = {
    Workload = var.workload
    Role     = "argocd-hub" # live/hub/aks의 UAMI에 이 태그가 붙어 있어야 한다
  }
}

# for_each가 0건이면 이 data source 자체가 호출되지 않는다. 1단에서 이미 존재를
# 확인한 이름만 조회하므로 "존재 확인 없는 하드 실패"가 아니다. 크로스 구독 참조는
# 대상 부재(hub 재구축 중)를 하드 에러로 만들지 않는다.
data "azurerm_user_assigned_identity" "hub_argocd" {
  for_each = { for r in data.azurerm_resources.hub_argocd_uami.resources : r.name => r }

  provider            = azurerm.hub
  name                = each.value.name
  resource_group_name = each.value.resource_group_name
}

locals {
  hub_argocd_principal_id = try(values(data.azurerm_user_assigned_identity.hub_argocd)[0].principal_id, null)
}

# principal이 다른 구독(hub) 소속이라 skip_service_principal_aad_check가 필요하다.
# ⚠️ hub가 재구축되면 UAMI의 principal_id가 바뀌어 이 role assignment도 교체된다. hub
#    재구축 뒤 이 root를 다시 apply한다(docs/hub-lifecycle.md).
resource "azurerm_role_assignment" "argocd_hub_access" {
  count = local.hub_argocd_principal_id != null ? 1 : 0

  scope                            = module.aks_cluster.cluster_id # 자기 자신의 리소스
  role_definition_name             = "Azure Kubernetes Service RBAC Cluster Admin"
  principal_id                     = local.hub_argocd_principal_id
  skip_service_principal_aad_check = true
}

# count=0 경로가 "정상"(hub 재구축 윈도우)과 "설정 실수"(태그 누락 등)를 구분 못
# 하면 조용한 무동작이 재발한다. plan/apply 로그에 경고를 남긴다.
check "hub_argocd_uami_discovered" {
  assert {
    condition     = local.hub_argocd_principal_id != null
    error_message = "hub ArgoCD UAMI를 발견하지 못했다. hub가 재구축 중이거나(정상, 재apply로 해소) live/hub/aks의 UAMI에 Role=argocd-hub 태그가 빠졌을 수 있다(비정상)."
  }
}
