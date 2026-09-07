# aks-platform-gitops: AGFC(ALB Controller) 매니페스트 설계

**대상 저장소**: `skax-ca/aks-platform-gitops`(로컬 `~/born2k/ai/aks-platform-gitops`).
**상태**: 구현·배포 완료(2026-09-04). hub 클러스터의 `alb-controller`·`alb-loadbalancer`
Application이 Synced/Healthy로 가동 중.
**입력**: `docs/decisions/aks-platform-gitops-addon-selection.md`(GitOps 엔진·Ingress
addon 선택 근거).

## 1. Decision

AGFC(Application Gateway for Containers)를 self-managed ArgoCD로 배포한다. 컨트롤러는
Helm(OCI `mcr.microsoft.com/application-lb/charts`), `ApplicationLoadBalancer` CR은
로컬 helm 차트로 GitOps가 소유한다. IAM(Managed Identity·federated credential·role
assignment)과 위임 서브넷은 Terraform(`live/hub/aks`·`live/hub/networking`)이 만든다 -
계층 분리 원칙: Terraform은 전제조건만, 컨트롤러 설치는 Helm, CR은 GitOps.

**Decision Drivers**:

1. **Azure RBAC 폭발 반경**: 컨트롤러 Managed Identity는 node RG `Configuration Manager`
   + 위임 서브넷 `Network Contributor` 2종으로 한정된다(공식 quickstart 문서 `az role
   assignment create` 명령 실측, Reader는 불필요). ⚠️ 이 축은 Azure RBAC에만 해당한다 -
   K8s RBAC 축에서는 helm 차트의 ClusterRole이 클러스터 전역 Secret 쓰기 권한을 갖는다.
   벤더 차트 자체의 설계이고 이 계획이 축소할 수 있는 범위 밖이라 4절에 위험으로만
   기록한다.
2. **재현성**: `root-app.yaml`의 자기소멸 원칙상, workbench에서 손으로 apply하는 내용과
   커밋본이 바이트 단위로 같아야 한다.
3. **이 클러스터의 실제 구성**: private cluster + Azure CNI Overlay + Cilium + Korea
   Central. AGFC의 Overlay 지원 최소 버전(v1.7.9+)을 채택한다.

원칙: AWS 원본(`eks-platform-gitops`)과 1:1로 가되, 어긋날 때는 공식 문서 인용과 함께
명시적으로 어긋난다. Terraform(계층 1)은 IAM+네트워킹 전제조건, 컨트롤러는 Helm, CR은
GitOps. `apps/` 디렉토리는 만들지 않는다.

## 2. 선행 조건 - CI 자격증명 모델

이 설계는 CI 신원이 구독 전체 `Owner`인 상태를 전제한다(`docs/decisions/
bootstrap-credential-design.md`). 그 이전 모델(RG 스코프 커스텀 역할)에서는 아래
`azurerm_role_assignment`·`azurerm_federated_identity_credential`이 CI 권한 밖이라
이 설계 자체가 성립하지 않는다.

## 3. 산출물

### 3-1. `clusters/hub/aks-demo-hub-krc-main-01/cluster-secret.yaml`

| 필드 | 값 | 근거 |
|---|---|---|
| `metadata.name` | `aks-demo-hub-krc-main-01` | `live/hub/aks/main.tf` naming 조합, `cluster_name` output과 일치 |
| `metadata.labels."argocd.argoproj.io/secret-type"` | `cluster` | ArgoCD가 클러스터 등록으로 인식하는 필수 키 |
| `metadata.labels.environment` | `hub` | selector가 존재만 검사 |
| `metadata.labels.tier` | `prd` | 원본과 동일 분류 기준 |
| `metadata.labels.region` | `krc` | |
| `metadata.labels.albControllerClientId` | `<UAMI clientId, GUID>` | 클러스터명에서 파생 불가 - `live/hub/aks`가 소유하는 identity의 clientId. 재도출: `az identity show -g rg-demo-hub-krc-workload-01 -n id-demo-hub-krc-alb-controller --query clientId -o tsv` |
| `type` | `Opaque` | 원본 그대로 |
| `stringData.name` | `aks-demo-hub-krc-main-01` | |
| `stringData.server` | `https://kubernetes.default.svc` | self-managed ArgoCD 표준값 |
| `stringData.project` | `platform` | `projects/platform.yaml`의 이름과 일치해야 함 |

`albSubnetId` 라벨은 채택하지 않았다(6절 참고) - 실제 서브넷 리소스 ID가 K8s 라벨 값
제약(63자, `/` 금지)을 위반해 `clusters/hub/aks-demo-hub-krc-main-01/values.yaml`
경로로 전환했다.

### 3-2. `projects/platform.yaml`

**`sourceRepos`**:
- `https://github.com/skax-ca/aks-platform-gitops.git`(이 저장소)
- `https://argoproj.github.io/argo-helm`(ArgoCD 자기 관리)
- `mcr.microsoft.com/application-lb/charts`(AGFC, OCI - `oci://` 접두사 없음, karpenter
  규약과 동일)

**`clusterResourceWhitelist`**(`helm template` 실행 결과와 정확히 일치, digest
`sha256:8163eec4...`):

| kind | 근거 |
|---|---|
| `{group: "", kind: Namespace}` | 차트가 `azure-alb-system` Namespace를 직접 렌더(`CreateNamespace=true` 불필요) |
| `{group: rbac.authorization.k8s.io, kind: ClusterRole}` | 컨트롤러 RBAC |
| `{group: rbac.authorization.k8s.io, kind: ClusterRoleBinding}` | 컨트롤러 RBAC |

⛔ CRD를 넣지 않는다 - Gateway API CRD는 컨트롤러가 런타임에 동적 생성한다
(`installGatewayApiCRDs: true` values, ArgoCD가 소유하지 않음).

### 3-3. `addons/baseline/alb-controller.yaml` (ApplicationSet 2개, Karpenter 패턴)

**① 컨트롤러(OCI helm, sync-wave 0)**:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: alb-controller
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchExpressions:
            - key: environment
              operator: Exists
            # 라벨 누락 시 배포 자체를 막는다 - 없으면 SA 애노테이션에 리터럴
            # "{{...}}"가 들어가 런타임에만 조용히 실패한다.
            - key: albControllerClientId
              operator: Exists
  template:
    metadata:
      name: '{{name}}-alb-controller'
      finalizers:
        - resources-finalizer.argocd.argoproj.io
      annotations:
        argocd.argoproj.io/sync-wave: "0"
    spec:
      project: platform
      source:
        repoURL: mcr.microsoft.com/application-lb/charts
        chart: alb-controller
        targetRevision: 1.11.4
        helm:
          releaseName: alb-controller
          parameters:
            - name: albController.namespace
              value: azure-alb-system
            - name: albController.podIdentity.clientID
              value: '{{metadata.labels.albControllerClientId}}'
      destination:
        server: '{{server}}'
        namespace: azure-alb-system
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - ServerSideApply=true
```

**② ApplicationLoadBalancer CR(로컬 helm 차트, sync-wave 5)**:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: alb-loadbalancer
  namespace: argocd
spec:
  generators:
    - clusters:
        selector:
          matchExpressions:
            - key: environment
              operator: Exists
            - key: albSubnetId
              operator: Exists
  template:
    metadata:
      name: '{{name}}-alb-loadbalancer'
      finalizers:
        - resources-finalizer.argocd.argoproj.io
      annotations:
        argocd.argoproj.io/sync-wave: "5"
    spec:
      project: platform
      source:
        repoURL: https://github.com/skax-ca/aks-platform-gitops.git
        targetRevision: main
        path: addons/alb-controller/loadbalancer  # 로컬 helm 차트, Karpenter nodepool과 동형
        helm:
          parameters:
            - name: subnetId
              value: '{{metadata.labels.albSubnetId}}'
      destination:
        server: '{{server}}'
        namespace: azure-alb-system
      syncPolicy:
        automated:
          prune: true
          selfHeal: true
        syncOptions:
          - SkipDryRunOnMissingResource=true
          - ServerSideApply=true
```

`addons/alb-controller/loadbalancer/`(로컬 차트)의 `templates/`는
`ApplicationLoadBalancer` CR 하나다:

```yaml
apiVersion: alb.networking.azure.io/v1
kind: ApplicationLoadBalancer
metadata:
  name: alb-demo-hub-krc-main
  namespace: azure-alb-system
spec:
  associations:
    - {{ .Values.subnetId }}
```

공식 API 스펙 문서(`for-containers/api-specification-kubernetes`) 확인: `spec.associations`는
`[]string`(subnet 리소스 ID 문자열 배열 그대로, `.id` 하위 필드 없음). 이 경로는
root-app.yaml 스캔에서 `+argocd:skip-file-rendering` 마커로 제외한다(3-4 참고). Managed
배포 전략이므로 이 CR 적용이 실제 ALB(Application Gateway for Containers) ARM 리소스를
컨트롤러가 동적으로 생성하는 트리거다 - Terraform은 이 리소스를 만들지 않는다(ALBC
선례와 동형).

namespace-scoped 리소스다(같은 문서, 예시가 `metadata.namespace: alb-test-infra`를
명시). `clusterResourceWhitelist`에 추가할 것은 없다 - `projects/platform.yaml`의
`namespaceResourceWhitelist: [{group: '*', kind: '*'}]`가 이미 커버한다.

### 3-4. `bootstrap/root-app.yaml`

원본과 거의 동일 - `repoURL`을 이 저장소로, `exclude`는 원본과 같은 이유로 유지:
`'{clusters/**/values.yaml,bootstrap/argocd-values.yaml}'`. 원본 exclude 목록에는
karpenter 경로가 없다(마커 방식으로 뺀다, exclude 목록이 아니다) - 3-3의
`addons/alb-controller/loadbalancer/`도 같은 방식(마커)으로 뺀다. exclude 목록에 이
경로를 추가하면 자기소멸 데드락(spec 변경과 그 변경이 있어야 읽을 수 있는 파일을 같은
커밋에 넣을 수 없음)이 발생한다. `Chart.yaml`을 그 디렉토리에 두면 Directory 타입이
아니라 Helm 타입으로 인식되므로 마커 누락 시 전담 Application도 자기 파일을 걸러버리는
함정도 피한다.

## 4. Terraform 전제조건 - `live/hub/aks/main.tf`에 직접 추가

CI가 구독 Owner라 `roleAssignments/write` 제약이 없으므로, IAM 리소스 3종을
`live/hub/aks`가 직접 소유한다.

```hcl
# workload_identity_enabled: ForceNew 아님(azurerm v5.3.0 소스 확인, in-place
# update 경로 존재) - aks_cluster 모듈 블록에 한 줄 추가
module "aks_cluster" {
  # ...기존 인자...
  workload_identity_enabled = true
}

resource "azurerm_user_assigned_identity" "alb_controller" {
  name                = "id-${var.workload}-${var.env}-${var.region_code}-alb-controller"
  resource_group_name = local.resource_group_name
  location            = var.location
  tags                = local.tags
}

resource "azurerm_federated_identity_credential" "alb_controller" {
  # FIC는 identity 하위 스코프라 CAF Name 재구성 대상이 아니다(azure.md에 등재된
  # 약어 없음) - identity 안에서만 고유하면 된다.
  name                = "alb-controller"
  resource_group_name = local.resource_group_name
  parent_id           = azurerm_user_assigned_identity.alb_controller.id
  audience            = ["api://AzureADTokenExchange"]
  issuer              = module.aks_cluster.oidc_issuer_url
  subject             = "system:serviceaccount:azure-alb-system:alb-controller-sa"
}

resource "azurerm_role_assignment" "alb_controller_config_manager" {
  scope              = "/subscriptions/${var.subscription_id}/resourceGroups/${module.aks_cluster.node_resource_group}"
  role_definition_id = "/subscriptions/${var.subscription_id}/providers/Microsoft.Authorization/roleDefinitions/fbc52c3f-28ad-4303-a892-8a056630b8f1"
  principal_id       = azurerm_user_assigned_identity.alb_controller.principal_id
}

resource "azurerm_role_assignment" "alb_controller_network_contributor" {
  scope                = data.azurerm_subnet.alb.id  # live/hub/networking이 만든 위임 서브넷
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.alb_controller.principal_id
}

resource "azurerm_resource_provider_registration" "service_networking" {
  name = "Microsoft.ServiceNetworking"
}

resource "azurerm_resource_provider_registration" "network_function" {
  name = "Microsoft.NetworkFunction"
}
```

`data.azurerm_subnet.alb`는 `live/hub/aks/main.tf`의 기존 `data.azurerm_subnet.aks_node`와
같은 패턴(Name 기반 조회, `terraform_remote_state` 아님)으로 추가한다.

역할 GUID(공식 quickstart 문서 `az role assignment create` 명령 원문 실측): Configuration
Manager `fbc52c3f-28ad-4303-a892-8a056630b8f1`, Network Contributor는 built-in role이라
`role_definition_name`으로 충분(GUID `4d97b98b-1d4f-4787-a291-c67834d212e7`도 같은 문서가
명시). Reader는 필요 없다 - 이 배포 전략(Managed by ALB Controller, Helm 설치) 기준
정확히 2개 역할뿐이다.

## 5. `live/hub/networking` 변경 - ALB 위임 서브넷

```hcl
# locals.subnet_cidrs에 추가
alb = "10.60.4.0/24"  # 예비 대역(10.60.4.0/24~10.60.15.0/24) 중 첫 칸, 기존 주석과 일치

# subnet_groups에 추가
"alb" = {
  address_prefixes = [local.subnet_cidrs["alb"]]
  delegations = [{
    name    = "Microsoft.ServiceNetworking/trafficControllers"
    actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
  }]
}
```

vnet 모듈(v0.2.0)은 `delegations`를 이미 지원한다(`variables.tf:135`,
`main.tf:59-68`) - 모듈 변경 불필요.

⚠️ 이 root는 `live/hub/aks`와 별도 state다(CLAUDE.md 1절) - CLAUDE.md 5절에 따라 별도
브랜치·PR로 진행하고, `live/hub/aks`의 role assignment apply보다 먼저 머지·apply돼야
한다(서브넷이 선존재해야 그 스코프의 role assignment가 유효).

## 6. 계획 대비 실측으로 바뀐 것

- **`albSubnetId` 라벨 값이 K8s 제약을 위반한다**: 실제 서브넷 리소스 ID(`az network vnet
  subnet show ... --query id`)가 191자(한도 63자) + `/` 포함(라벨 값 비허용 문자)이라
  라벨로 쓸 수 없다. `clusters/hub/aks-demo-hub-krc-main-01/values.yaml`로 전환하고,
  `alb-loadbalancer` ApplicationSet을 matrix generator(cluster + git files)로
  재설계했다. ⚠️ 이 generator는 이름 기준 join이 아니라 Cartesian product라 클러스터가
  2개 이상이 되면 재검증이 필요하다.
- **`albControllerClientId`(UAMI clientId, GUID 36자)는 라벨 제약을 통과해** 원래
  설계대로 라벨로 유지한다.
- **K8s RBAC 축 최소권한 미달성**은 벤더 차트 설계라 이 계획이 축소할 수 없다(1절
  Decision Driver 1) - 수용하고 별도 완화책을 두지 않는다.
- **`pre-delete` helm 훅**이 실제로 존재한다(`helm.sh/hook: pre-delete`,
  `alb-controller-cleanup` Job) - addon 제거 시 이 훅이 Azure 리소스 orphan을 막는다.
  런북에 "addon 제거 시 사람이 Azure 리소스 확인" 항목이 필요하다(별도 후속).

## 7. 검증 절차 (실행 순서)

1. `helm template alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller
   --version 1.11.4 --set albController.namespace=azure-alb-system --set
   albController.podIdentity.clientID=00000000-0000-0000-0000-000000000000` - cluster-scoped
   리소스 3종(Namespace 1·ClusterRole 2·ClusterRoleBinding 2), CRD 0건, `pre-delete` 훅
   실물을 확인한다. 렌더 결과는 `ApplicationLoadBalancer` CR 관련 정보를 담지 않는다
   (런타임 동적 생성이 정상).
2. `live/hub/networking`(위임 서브넷) plan → PR → apply, `az network vnet subnet show`로
   delegation 실물 확인.
3. `live/hub/aks`(IAM 3종+workload identity) plan → PR → apply.
4. `az aks show`의 `securityProfile.workloadIdentity.enabled=true` **와** `az aks command
   invoke -- kubectl get pods -n kube-system -l azure-workload-identity.io/system=true`로
   웹훅 파드 기동을 함께 확인한다(전자만으로는 부족).
5. `mcr.microsoft.com` OCI 호스트 egress canary: `az aks command invoke`로 private
   cluster 안에 임시 파드(`mcr.microsoft.com/azure-cli:latest`)를 띄워 `curl -sS -m 8
   https://mcr.microsoft.com/v2/` 실행 - `http_code=200`, NAT Gateway 경유 egress 확인.
   파드는 `--rm`으로 자동 정리한다.
6. root-app sync 후 `alb-controller`·`alb-loadbalancer` Application이 `Synced`/`Healthy`인지
   확인한다.
7. `kubectl get pods -n azure-alb-system`으로 컨트롤러 Running 확인.
8. `ApplicationLoadBalancer` CR 적용 후 실제 Azure ALB 리소스 생성 확인(`az resource list
   --resource-type Microsoft.ServiceNetworking/trafficControllers`).
9. 테스트 Gateway/HTTPRoute로 private cluster 내부 트래픽 실측.
10. **teardown 리허설**: addon 제거(git revert) 후 ArgoCD prune, Azure ALB 리소스가 CR
    lifecycle을 따라 실제로 정리되는지 확인한다(Managed 전략의 핵심 전제).

## 8. Follow-ups (이 설계 범위 밖)

- **GitHub App**: 기존 `skax-ca-gitops-reader`(2026-08-07 발급, `eks-platform-gitops`용)를
  재사용한다(신규 발급 안 함). 이 App의 설치 범위에 `aks-platform-gitops` repo를
  추가해야 seed를 실행할 수 있다.
- `addons/catalog/`(opt-in addon) 설계는 아직 없다.
