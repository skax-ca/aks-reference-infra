# aks-platform-gitops 초기 매니페스트 설계 (RALPLAN-DR, short) v2

**상태**: `pending approval`. Architect+Critic 1차 검토(REJECT) 반영해 REVISE,
canary 실측(helm template + 공식 API 스펙 문서)으로 v2의 미해결 항목 대부분
해소(2026-09-04). 2차 전체 Architect/Critic 재검토는 한계효용이 낮다고 판단해
생략(사용자 확인) - 남은 미확인 항목(
provider 등록 리소스 적용 가능성, `albSubnetId` 라벨 문자 제약)은 5절 검증
단계가 실행 시점에 흡수한다.
**대상 저장소**: `skax-ca/aks-platform-gitops`(로컬 `~/born2k/ai/aks-platform-gitops`).
**입력**: `.omc/plans/aks-platform-gitops-addon-selection.md`(GitOps 엔진·Ingress addon
6라운드 리서치), 1차 Architect/Critic 검토(Critic REJECT), 사용자 결정 3건(AGFC 유지,
Managed 배포 전략, 자격증명 모델 신규 전환 확정).
**작성**: 2026-09-04

## v1 → v2 변경 요약 (Architect/Critic 반영)

| 항목 | v1 | v2 |
|---|---|---|
| `workload_identity_enabled` | ForceNew 여부 미확인, 위험으로 이연 | provider 소스(`kubernetes_cluster_resource.go`) 확인 완료 - **in-place**, 위험 아님 |
| IAM 리소스 배치 | "Architect 검토 필요"로 미정 | **`live/hub/aks`에 직접 추가**(자격증명 모델이 구독 Owner로 전환되며 CI가 role assignment/federated credential을 직접 만들 수 있게 됨 - bootstrap 2-phase 불필요, 아래 2절) |
| 필요 역할 | Reader 1종만 | **Configuration Manager(MC RG) + Network Contributor(ALB 서브넷) 2종**(공식 quickstart 문서 `az role assignment create` 명령 실측, Reader 불필요로 정정) |
| 위임 서브넷 | 언급 없음 | `live/hub/networking`에 신규 추가(10.60.4.0/24, 예비 대역) |
| CR 소유 | 산출물에 없음(C2) | `addons/baseline/alb-controller.yaml`에 2번째 ApplicationSet으로 추가(Karpenter 패턴과 동형) |
| 배포 전략 | 미결정 | **Managed**(BYO 아님 - ALBC 선례·계층 분리 원칙, 아래 1-5) |
| OCI repoURL | `oci://` 접두사 + chart 중복 | 원본 karpenter 규약대로 정정 |
| clusterResourceWhitelist | 추정 | `helm template` 실측 3종(Namespace/ClusterRole/ClusterRoleBinding), CRD 없음 |
| clientID 전달 | 미해결 | cluster Secret 라벨(`karpenterNodeRole`과 동일 계열), selector에 존재 검사 추가 |
| 검증 4단계(helm install 수동) | 자기소멸 원칙과 충돌 | 삭제 - ArgoCD sync만으로 설치, canary는 `helm template`(dry-run)로 대체 |

## RALPLAN-DR 요약 (v1에서 유지, Decision Driver 1만 축 명시로 수정)

### Principles

1. AWS 원본과 1:1로 간다. 어긋날 때는 공식 문서 인용과 함께 명시적으로 어긋난다.
2. addon-selection.md가 이미 확정한 두 결정(GitOps 엔진, Ingress addon)은 이
   계획에서 재검토하지 않는다 - 단 **그 결정의 구현 세부(역할·서브넷·CR 소유)는
   재검토 대상이다**(v1이 이 경계를 잘못 그어 Critic C1의 직접 원인이 됐다 -
   addon-selection.md 자신이 "canary 실측은 아직 없음"이라고 선언한 문서다).
3. Terraform(계층 1)은 IAM+네트워킹 전제조건, 컨트롤러는 Helm, CR은 GitOps.
4. 되돌릴 수 없는 값은 실측 확인 후 채운다.
5. `apps/` 디렉토리는 만들지 않는다.

### Decision Drivers (top 3, 축 명시)

1. **폭발 반경(Azure RBAC 축)**: AGFC 컨트롤러의 Managed Identity는 node RG
   `Configuration Manager`, 위임 서브넷 `Network Contributor` 2종으로
   한정된다(공식 quickstart 문서 실측 - Reader는 불필요). ⚠️ **이 축은 Azure
   RBAC에만 해당한다** - K8s RBAC 축에서는 helm
   차트의 ClusterRole이 클러스터 전역 Secret 쓰기 권한을 갖는다(차트 자체
   설계, 이 계획이 축소할 수 있는 범위 밖 - 위험 표에 별도 기록).
2. **재현성**: root-app.yaml의 자기소멸 원칙상, workbench에서 손으로 apply하는
   내용과 커밋본이 바이트 단위로 같아야 한다.
3. **이 클러스터의 실제 구성**: private cluster + Azure CNI Overlay + Cilium +
   Korea Central. AGFC의 Overlay 지원 최소 버전(v1.7.9+)을 채택한다.

## 0. 선행 조건 - 자격증명 모델 전환

이 계획은 **CI 신원이 구독 전체 `Owner`로 전환된 이후**를 전제한다(CLAUDE.md
2절, 2026-09-04 결정, 이 작업과 함께/직전 재부트스트랩 예정 - 사용자 확인
완료). 전환 전 상태(RG 스코프 커스텀 역할)에서는 아래 2절의 `azurerm_role_assignment`
3종·`azurerm_federated_identity_credential`이 CI 권한 밖이라 이 계획 자체가
성립하지 않는다 - 재부트스트랩이 먼저 완료돼야 이 계획을 적용할 수 있다.

새 방어선(FIC `subject` 완전 일치, 와일드카드·정적 자격증명 추가 금지)은 이
계획이 만드는 리소스와 무관한 축이라 이 계획에서 추가로 지킬 것은 없다 - 단
`bootstrap/README.md`·`.omc/plans/bootstrap-credential-design.md`(2026-09-04
추가 기록)를 실제 재부트스트랩 시점에 확인한다(이 계획의 범위 밖).

## 1. 산출물별 설계

### 1-1. `clusters/hub/aks-demo-hub-krc-main-01/cluster-secret.yaml`

| 필드 | 값 | 근거 |
|---|---|---|
| `metadata.name` | `aks-demo-hub-krc-main-01` | `live/hub/aks/main.tf` naming 조합, `cluster_name` output과 일치 |
| `metadata.labels."argocd.argoproj.io/secret-type"` | `cluster` | **필수** - ArgoCD가 클러스터 등록으로 인식하는 키(v1 누락, 원본 실물 그대로 승계) |
| `metadata.labels.environment` | `hub` | selector가 존재만 검사 |
| `metadata.labels.tier` | `prd` | 원본과 동일 분류 기준 |
| `metadata.labels.region` | `krc` | |
| `metadata.labels.albControllerClientId` | `<UAMI clientId, GUID>` | **클러스터명에서 파생 불가, bootstrap이 아니라 이제 `live/hub/aks`가 소유하는 identity의 clientId** - `karpenterNodeRole`과 같은 계열(재구축을 견딤, 클러스터와 identity의 수명주기가 분리돼 있음). 재도출: `az identity show -g rg-demo-hub-krc-workload-01 -n id-demo-hub-krc-alb-controller --query clientId -o tsv` |
| `metadata.labels.albSubnetId` | `<위임 서브넷 리소스 ID, URL-safe 인코딩 필요>` | ALB 리소스가 붙을 서브넷 - 클러스터명에서 파생 안 됨, `albControllerClientId`와 같은 계열. 라벨 값의 `/` 때문에 K8s 라벨 값 제약(63자, 특정 문자 제한)에 걸릴 수 있어 **실측 필요**(Architect/Critic 재검토 항목으로 남김 - 안 되면 `values.yaml` 경로로 전환) |
| `type` | `Opaque` | 원본 그대로 |
| `stringData.name` | `aks-demo-hub-krc-main-01` | |
| `stringData.server` | `https://kubernetes.default.svc` | self-managed ArgoCD 표준값 |
| `stringData.project` | `platform` | `projects/platform.yaml`의 이름과 일치해야 함 |

⚠️ **v1의 `vpcName` 분석 정정**: v1은 "Azure에 대응 개념이 없다"고 적었으나
틀렸다 - `albSubnetId`가 정확히 같은 역할(클러스터별 네트워크 대상 식별자)을
한다.

### 1-2. `projects/platform.yaml`

**`sourceRepos`**:
- `https://github.com/skax-ca/aks-platform-gitops.git`(이 저장소)
- `https://argoproj.github.io/argo-helm`(ArgoCD 자기 관리, Follow-up 1)
- `mcr.microsoft.com/application-lb/charts`(AGFC, OCI - **`oci://` 접두사 없음**,
  원본 karpenter 규약과 동일)

**`clusterResourceWhitelist`** (✅ 2026-09-04 canary 실측 완료 - `helm template`
실행 결과와 정확히 일치, digest `sha256:8163eec4...`):

| kind | 근거 |
|---|---|
| `{group: "", kind: Namespace}` | 차트가 `azure-alb-system` Namespace를 직접 렌더(CreateNamespace=true 불필요) |
| `{group: rbac.authorization.k8s.io, kind: ClusterRole}` | 컨트롤러 RBAC |
| `{group: rbac.authorization.k8s.io, kind: ClusterRoleBinding}` | 컨트롤러 RBAC |

⛔ **CRD를 넣지 않는다** - Gateway API CRD는 컨트롤러가 런타임에 동적 생성한다
(`installGatewayApiCRDs: true` values, ArgoCD가 소유하지 않음 - 원본 README가
Kyverno 동적 웹훅에서 경고한 것과 같은 함정, 3-1 검증이 유일한 판정 수단).

### 1-3. `addons/baseline/alb-controller.yaml` (2개 ApplicationSet, Karpenter 패턴)

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
            # 라벨 누락 시 배포 자체를 막는다(Architect 권고) - 없으면
            # SA 애노테이션에 리터럴 "{{...}}"가 들어가 런타임에만 조용히 실패한다.
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
        targetRevision: 1.11.4  # 착수 시 mcr.microsoft.com 태그 재조회
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
`ApplicationLoadBalancer` CR 하나:

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

✅ **공식 API 스펙 문서(`for-containers/api-specification-kubernetes`)로 실측
확정**: `spec.associations`는 `[]string`(subnet 리소스 ID 문자열 배열 그대로,
`.id` 하위 필드 없음 - v1 스케치가 틀렸던 부분 정정) - 예시 원문:
`spec: {associations: [<ALB_SUBNET_ID>]}`. 이 경로는 root-app.yaml 스캔에서
`+argocd:skip-file-rendering` 마커로 제외한다(1-4 참고). **Managed 배포
전략**이므로 이 CR 적용이 실제 ALB(Application Gateway for Containers) ARM
리소스를 컨트롤러가 동적으로 생성하는 트리거다 - Terraform은 이 리소스를
만들지 않는다(2절 참고, ALBC 선례와 동형).

✅ **namespace-scoped 확정**(같은 문서, 예시가 `metadata.namespace:
alb-test-infra`를 명시). `clusterResourceWhitelist`에 추가할 것 없음 -
`projects/platform.yaml`의 `namespaceResourceWhitelist: [{group: '*', kind:
'*'}]`가 이미 커버한다.

### 1-4. `bootstrap/root-app.yaml`

원본과 거의 동일 - `repoURL`을 이 저장소로, `exclude`는 원본과 같은 이유로
유지: `'{clusters/**/values.yaml,bootstrap/argocd-values.yaml}'`.

⛔ **v1의 오류 정정**: v1은 "Karpenter 전용 로컬 helm 차트 경로를 exclude
목록에서 제외한다"고 적었으나, **원본 exclude 목록에는 애초에 karpenter
경로가 없다**(마커 방식으로 뺀다, exclude 목록이 아니다). 1-3의
`addons/alb-controller/loadbalancer/`도 같은 방식(마커)으로 뺀다 - **exclude
목록에 이 경로를 추가하지 않는다**(추가하면 원본이 경고하는 자기소멸
데드락 - "spec 변경과 그 변경이 있어야 읽을 수 있는 파일은 같은 커밋에 넣을
수 없다"). `Chart.yaml`을 그 디렉토리에 두면 Directory 타입이 아니라 Helm
타입으로 인식되므로 마커 누락 시의 "전담 Application도 자기 파일을 걸러버리는"
함정도 피한다.

## 2. Terraform 전제조건 - `live/hub/aks/main.tf`에 직접 추가

0절 전환 완료를 전제로, IAM 리소스 3종을 `live/hub/aks`가 직접 소유한다(v1의
"어느 root에 둘지 미정" 질문은 자격증명 모델 전환으로 답이 나왔다 - CI가 이제
구독 Owner라 `roleAssignments/write` 제약이 없다).

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
  # 약어 없음, rg/st/entapp/id처럼 "Name" 태그를 갖는 최상위 리소스가 아니라서
  # 임의 접두어를 새로 만들지 않는다) - identity 안에서만 고유하면 된다.
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

`data.azurerm_subnet.alb`는 `live/hub/aks/main.tf`의 기존
`data.azurerm_subnet.aks_node`와 같은 패턴(Name 기반 조회, `terraform_remote_state`
아님)으로 추가한다.

✅ **역할 GUID 확정**(공식 quickstart 문서 `az role assignment create` 명령
원문 실측): Configuration Manager `fbc52c3f-28ad-4303-a892-8a056630b8f1`,
Network Contributor는 built-in role이라 `role_definition_name`으로 충분(GUID
`4d97b98b-1d4f-4787-a291-c67834d212e7`도 같은 문서가 명시). Reader는 이
문서의 명령 목록에 없어 **삭제**(1차 조사에서 다른 배포 전략 문서가 섞였던
것으로 추정, 이 배포 전략 - Managed by ALB Controller, Helm 설치 - 기준
정확히 2개 명령뿐).

⚠️ **재검토 필요**: 프로바이더 등록 리소스(`azurerm_resource_provider_registration`)가
CI(구독 Owner)로 실제 apply 가능한지 재확인 대상(구독 스코프 쓰기라 이전
모델에선 절대 불가능했던 종류의 작업 - 새 모델에서 처음 등장하는 유형이라
신중하게 실측).

## 3. `live/hub/networking` 변경 - ALB 위임 서브넷

```hcl
# locals.subnet_cidrs에 추가
alb = "10.60.4.0/24"  # 예비 대역(10.60.4.0/24~10.60.15.0/24) 중 첫 칸, 기존 주석과 일치

# subnet_groups에 추가
"alb" = {
  address_prefixes = [local.subnet_cidrs["alb"]]
  delegations = [{
    name    = "Microsoft.ServiceNetworking/trafficControllers"
    actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]  # 재확인 필요
  }]
}
```

vnet 모듈(v0.2.0)은 `delegations`를 이미 지원한다(`variables.tf:135`,
`main.tf:59-68`) - 모듈 변경 불필요. `actions` 값은 공식 문서
(`az network vnet subnet create --delegations
'Microsoft.ServiceNetworking/trafficControllers'`)가 내부적으로 무엇을
쓰는지 착수 시 재확인.

⚠️ 이 root는 `live/hub/aks`와 **별도 state**다(CLAUDE.md 1절) - CLAUDE.md
5절에 따라 별도 브랜치·PR로 진행하고, `live/hub/aks`의 role assignment
apply보다 먼저 머지·apply돼야 한다(서브넷이 선존재해야 그 스코프의
role assignment가 유효).

## 4. 위험과 완화 (v1 표 갱신)

| 위험 | 완화 |
|---|---|
| ~~`clusterResourceWhitelist`를 추정으로 채움~~ | ✅ **해소(2026-09-04 canary 실측 완료)** - `helm template`로 직접 렌더, 예측한 3종(Namespace/ClusterRole ×2/ClusterRoleBinding ×2, kind 기준 3종)과 CRD 0건 그대로 확인 |
| K8s RBAC 축 최소권한 미달성(차트 자체가 클러스터 전역 Secret 쓰기 권한을 가짐) | 이 계획이 축소할 수 없는 벤더 설계 - Decision Driver 1에 축을 명시해 오독 방지, 별도 완화책 없음(수용) |
| `pre-delete` helm 훅이 ArgoCD 훅 매핑(PreSync/PostSync/PostDelete)에 없어 addon 제거 시 Azure 리소스 orphan 가능 | ✅ **훅 존재 직접 실측 확인**(`helm.sh/hook: pre-delete`, `alb-controller-cleanup` Job) - 5절 검증에 teardown 리허설 추가, 런북에 "addon 제거 시 사람이 Azure 리소스 확인" 항목 필요(별도 후속) |
| `albSubnetId` 라벨 값이 K8s 라벨 문자 제약에 걸릴 가능성(리소스 ID에 `/` 포함) | 착수 시 즉시 실측 - 안 되면 `values.yaml` + `$values` 경로로 전환(원본에 없는 패턴이라 별도 설계 필요) |
| ~~`ApplicationLoadBalancer` CR의 namespace/cluster 스코프 미확정~~ | ✅ **해소(공식 API 스펙 문서 확인)** - namespace-scoped, `spec.associations`는 `[]string`(1-3 참고) |
| provider 등록 리소스(`azurerm_resource_provider_registration`)의 실제 적용 가능성 미검증 | 2절 각주의 재확인 항목, 첫 plan에서 즉시 드러남(파괴적이지 않음) |

## 5. 검증 단계 (v1의 4단계 helm-install 수동 설치 제거, 순서 재배열)

1. ✅ **canary(완료, 2026-09-04)**: `helm template alb-controller
   oci://mcr.microsoft.com/application-lb/charts/alb-controller --version
   1.11.4 --set albController.namespace=azure-alb-system --set
   albController.podIdentity.clientID=00000000-0000-0000-0000-000000000000`
   실행 완료 - cluster-scoped 리소스 3종(kind 기준: Namespace 1·ClusterRole
   2·ClusterRoleBinding 2) 확인, CRD 0건 확인, `pre-delete` 훅 실물 확인
   (`helm.sh/hook: pre-delete`, `alb-controller-cleanup` Job). 렌더 결과는
   `ApplicationLoadBalancer` CR 관련 정보를 전혀 담지 않음(런타임 동적 생성
   확인) - CR 스펙은 공식 API 문서로 별도 확인(1-3).
2. `live/hub/networking`(위임 서브넷) plan → PR → apply, `az network vnet
   subnet show`로 delegation 실물 확인.
3. `live/hub/aks`(IAM 3종+workload identity) plan → PR → apply.
4. `az aks show`의 `securityProfile.workloadIdentity.enabled=true` **와**
   `az aks command invoke -- kubectl get pods -n kube-system -l
   azure-workload-identity.io/system=true`로 웹훅 파드 기동 확인(Architect
   권고 - 전자만으로는 부족).
5. ✅ **mcr.microsoft.com OCI 호스트 egress canary(완료, 2026-09-04)**:
   `az aks command invoke`로 private cluster 안에 임시 파드
   (`mcr.microsoft.com/azure-cli:latest`)를 띄워 `curl -sS -m 8
   https://mcr.microsoft.com/v2/` 실행 - `http_code=200`,
   `time_total=0.1s`로 NAT Gateway 경유 egress 정상 확인(DNS 해석은
   curl 자체 조회로 암묵 확인, `nslookup` 바이너리 부재는 이미지 구성
   문제일 뿐 실패 아님). 파드는 `--rm`으로 자동 정리 확인. repo-server
   자체는 아직 미배포(Follow-up 1 선행 필요, 6번 항목)라 범용 canary
   파드로 대체 - 원본이 chart repo마다 개별 호스트 확인한 관행과 동일한
   목적.
6. Follow-up 1(ArgoCD 자기관리 파일) 완료 후에만 seed 진행(1-4 참고, Option A
   제약).
7. root-app sync 후 `alb-controller`/`alb-loadbalancer` Application이
   `Synced`/`Healthy` 확인.
8. `kubectl get pods -n azure-alb-system`으로 컨트롤러 Running 확인.
9. `ApplicationLoadBalancer` CR 적용 후 실제 Azure ALB 리소스 생성 확인(`az
   resource list --resource-type Microsoft.ServiceNetworking/trafficControllers`).
10. 테스트 Gateway/HTTPRoute로 private cluster 내부 트래픽 실측(`az aks
    command invoke` 경로, addon-selection.md 4절 유보 해소).
11. **teardown 리허설**: addon 제거(git revert) 후 ArgoCD prune, Azure ALB
    리소스가 CR lifecycle을 따라 실제로 정리되는지 확인(Managed 전략의 핵심
    전제 - 안 되면 Decision 재검토).

## 6. Follow-ups (이 계획 범위 밖)

1. ✅ **매니페스트 작성 완료(2026-09-04)** - ArgoCD 자기관리 파일
   (`bootstrap/argocd-app.yaml`, `bootstrap/argocd-values.yaml`,
   `bootstrap/argocd-seed.sh` vendoring), `bootstrap/root-app.yaml`,
   `projects/platform.yaml`, `clusters/hub/aks-demo-hub-krc-main-01/
   cluster-secret.yaml`, `addons/baseline/alb-controller.yaml`,
   `addons/alb-controller/loadbalancer/`(로컬 helm 차트) 전부
   `skax-ca/aks-platform-gitops`에 작성·YAML/bash 구문 검증·`helm template`
   렌더 검증 완료. ⏳ **실행은 아직** - workbench(`live/hub/workbench`, 별도
   세션) 완료 후로 미룸(2026-09-04 사용자 결정, private cluster라 helm
   install·kubectl apply를 실행할 환경이 필요).
   - **GitHub App**: 기존 `skax-ca-gitops-reader`(2026-08-07 발급,
     eks-platform-gitops용) 재사용 확정(신규 발급 안 함) - 이 App의 설치
     범위에 aks-platform-gitops repo 추가는 seed 실행 전 남은 작업.
   - ⛔ 이 Follow-up은 `bootstrap/root-app.yaml`의 `exclude` 목록을 수정하지
     않는다(1-4 데드락 경고) - 실제로 마커 방식(`+argocd:skip-file-rendering`)
     그대로 지켜서 작성함.
   - 🔴 **1-1절이 "실측 필요"로 남긴 `albSubnetId` 라벨 문제, 답은 "안 된다"로
     확정**: 실제 서브넷 리소스 ID(`az network vnet subnet show ... --query
     id`)가 191자(한도 63자) + `/` 포함(라벨 값 비허용 문자)이라 K8s 라벨 값
     제약을 실측으로 위반함을 확인. 계획이 예비해 둔 대안대로
     `clusters/hub/aks-demo-hub-krc-main-01/values.yaml`로 전환하고,
     `alb-loadbalancer` ApplicationSet을 matrix generator(cluster + git
     files)로 재설계 - 단 이 generator는 이름 기준 join이 아니라 Cartesian
     product라 **클러스터가 2개 이상이 되면 재검증 필수**(파일 헤더에 기록,
     `argocd-app.yaml`이 이미 경고한 "단일 클러스터가 팬아웃 결함을 숨긴다"와
     같은 계열의 함정).
   - `albControllerClientId`(UAMI clientId, GUID 36자)는 라벨 제약을 통과해
     원래 설계대로 라벨 유지 - 실측: `az identity show -g
     rg-demo-hub-krc-workload-01 -n id-demo-hub-krc-alb-controller-01
     --query clientId` → `5d5b3144-b21b-495e-a1b0-f8f83b1ede3c`.
2. `addons/catalog/`(opt-in addon) 설계 - 아직 후보 없음.
3. ~~아k-cluster 모듈 workload_identity_enabled 변수 확인~~ - v1 Follow-up,
   2절에서 해소 완료(변수 존재 확인됨, 삭제).
