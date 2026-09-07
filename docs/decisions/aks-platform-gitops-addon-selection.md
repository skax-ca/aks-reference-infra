# aks-platform-gitops addon 설계 - GitOps 엔진 + Ingress(ALBC 대응) 선택

**상태**: 리서치 완료, 착수 전(`aks-platform-gitops` repo 자체가 아직 없음 - CLAUDE.md 0절
참고). 실제 `aks-platform-gitops` deepinit 시점에 이 문서를 1차 설계 근거로 소비한다.
**모드**: 순수 리서치(6라운드, 전부 공식 문서 기반, canary 실측은 아직 없음).
**작성**: 2026-09-04

## 0. 요약

AWS 원본 `eks-platform-gitops`(self-managed ArgoCD, ALBC를 baseline addon으로 helm
배포)를 Azure `aks-platform-gitops`로 옮기기 전에 두 가지를 확정해야 했다.

1. **GitOps 엔진**: self-managed ArgoCD 유지. Azure 관리형 ArgoCD 확장은 아직
   Public Preview이고, Flux v2는 GA지만 `AppProject` 가드레일이 없어 구조 재설계가
   필요하다.
2. **Ingress/L7(ALBC 대응)**: **Application Gateway for Containers(AGFC/ALB
   Controller)를 self-managed Helm으로 설치.** AKS 관리형 add-on 경로가 아니라,
   ALBC와 동일하게 "Terraform은 IAM만, 컨트롤러는 Helm" 패턴을 그대로 따른다.

두 결정 다 "모범사례가 무엇을 권고하는가"·"azurerm provider로 실제 재현 가능한가"·
"이 클러스터가 이미 쓰는 구성(Azure CNI Overlay + Cilium 데이터플레인 + private
cluster)과 충돌하지 않는가" 세 축을 전부 통과해야 확정으로 인정했다. 6라운드 중
3라운드가 모범사례에서, 4~5라운드가 나머지 두 축에서 각각 한 번씩 결론을 뒤집었다.

## 1. 배경

`eks-platform-gitops`(AWS 원본)의 addon 분류 기준: baseline(워크로드 아키텍처와
무관하게 플랫폼이 보편적으로 요구하는가) vs catalog(opt-in). ALBC는 baseline이고,
컨트롤러 자체는 helm(`aws.github.io/eks-charts`)이 배포하며 Terraform은 Pod
Identity association(IAM)만 만든다. `apps/` 디렉토리가 없고 계층 1(Terraform)/계층
2(플랫폼 GitOps)/계층 3(앱팀 GitOps)이 명확히 분리된 구조다.

이 문서는 이 구조를 Azure로 옮길 때 갈릴 수밖에 없는 두 지점(GitOps 엔진 자체,
ALBC에 대응하는 L7 addon)을 다룬다. 대상 클러스터는 hub 구독의
`aks-demo-hub-krc-main-01`: private cluster, Azure CNI **Overlay** 모드,
network_dataplane=**Cilium**, Korea Central.

## 2. Decision 1 - GitOps 엔진

| 옵션 | 지원 등급 | eks-platform-gitops 구조 재사용성 |
|---|---|---|
| 관리형 ArgoCD(`Microsoft.KubernetesConfiguration/extensions`, `Microsoft.ArgoCD`) | ⚠️ Public Preview(2026-03 발표), AKS 공식 `cluster-extensions` 목록에 미등재 | 매우 높음(같은 API/CRD) - 단 ArgoCD 자신의 ConfigMap을 git으로 못 흡수해 `root-app.yaml` 자기소멸 원칙 일부가 깨짐 |
| Flux v2(`fluxConfigurations`) | GA, 무과금 | 낮음 - `AppProject` 가드레일 개념 자체가 없음(네임스페이스 격리로 대체), `root-app.yaml` 패턴도 Kustomization `dependsOn` 체인으로 전면 재설계 필요 |
| **self-managed ArgoCD**(채택) | GA(ArgoCD 프로젝트 자체) | 100% - `eks-platform-gitops` 구조 그대로 이식 |

출처: `learn.microsoft.com/en-us/azure/azure-arc/kubernetes/tutorial-use-gitops-argocd`
(Preview 경고 원문), `learn.microsoft.com/en-us/azure/azure-arc/kubernetes/conceptual-gitops-flux2`
(멀티테넌시 모델), `learn.microsoft.com/en-us/azure/aks/cluster-extensions`(공식 확장 목록).

**결정**: self-managed ArgoCD 유지. 재고 트리거: 관리형 확장이 GA로 전환되는 시점
(그때는 CRD가 동일해 마이그레이션 비용이 낮고 Entra SSO/workload identity가
내장돼 있어 재검토 가치가 있다).

## 3. Decision 2 - Ingress/L7(ALBC 대응)

### 3-1. 후보와 라운드별 판정 변화

| 라운드 | 결론 | 뒤집힌 이유 |
|---|---|---|
| 2(제품 문서) | AGFC 권고 | Web App Routing(nginx)은 단종 경로(upstream 2026-03 유지보수 종료) 확인 후 제외 |
| 3(모범사례: WAF/Architecture Center/AKS Baseline) | App Routing(Istio)+Gateway API로 변경 | AKS 전용 WAF 가이드가 AGFC를 "서비스 메시 mTLS 자동화"로만 좁히고, 일반 ingress는 App Routing을 예시로 들었기 때문 |
| 4(azurerm provider 스키마 확인) | 블로커 발견 | `web_app_routing`/`service_mesh_profile` 어느 블록에도 App Routing-Istio 활성화 필드가 없음(GitHub 이슈 #31177 Open, ETA 없음). Cilium 자체 Gateway API도 AKS가 ConfigMap 커스터마이징을 공식 차단해 탈락 |
| 5(self-managed Helm 관점 재검토) | **AGFC로 회귀** | AGIC·AGFC 둘 다 "Terraform=IAM, 컨트롤러=Helm" 공식 경로가 있어 4라운드 블로커와 무관함을 확인. self-managed Istio는 Cilium ConfigMap 잠금이라는 새 블로커 가능성이 남아 탈락 |
| 6(최종 검증) | AGFC 확정 | Korea Central GA 확인, Overlay CNI 명시 지원(v1.7.9+), Cilium 공존 공식 확인. WAF 가이드의 "Gateway API 사용" 권고가 "for example"로 App Routing을 예시로 든 것뿐이라 AGFC(Gateway API v1.5 구현체)도 이 권고를 만족 |

### 3-2. 최종 채택 - AGFC(Application Gateway for Containers) self-managed Helm

ALBC와 정확히 같은 패턴:

| | Terraform(계층 1)이 만드는 것 | GitOps(계층 2)가 배포하는 것 |
|---|---|---|
| ALBC(AWS 원본) | IAM Role(Pod Identity association) | `helm install`(aws.github.io/eks-charts) |
| **AGFC(Azure)** | User-assigned Managed Identity + federated credential(workload identity, subject `system:serviceaccount:azure-alb-system:alb-controller-sa`) + AKS node resource group 스코프 `Reader` role(`acdd72a7-3385-48ef-bd42-f606fba81ae7`) | `helm install alb-controller oci://mcr.microsoft.com/application-lb/charts/alb-controller --version 1.11.4` |

전부 `azurerm_user_assigned_identity`/`azurerm_federated_identity_credential`/
`azurerm_role_assignment`로 이미 지원되는 리소스만 쓴다. AKS 관리형 add-on
활성화(`az aks` 확장)는 필요 없다. 사전조건: AKS Azure CNI 또는 **Azure CNI
Overlay**(이 클러스터가 이미 쓰는 조합), `--enable-oidc-issuer
--enable-workload-identity`.

출처: `learn.microsoft.com/.../quickstart-deploy-application-gateway-for-containers-alb-controller-helm`,
`learn.microsoft.com/en-us/azure/application-gateway/for-containers/container-networking`
(Overlay/Cilium 공존 확인 - "AGC respects your chosen network policy engine
including Cilium"), `learn.microsoft.com/en-us/azure/well-architected/service-guides/azure-kubernetes-service`
(WAF 가이드 "for example" 원문).

### 3-3. 검토했으나 기각한 후보

- **AGIC**: self-managed Helm 경로도 동일하게 존재하고 블로커도 없다(3-2와 대칭
  패턴, Managed Identity + App Gateway 스코프 `Contributor` + RG 스코프 `Reader`).
  다만 AKS 전용 WAF 가이드가 AGFC를 후속 설계로 명시하고, Architecture Center의
  멀티테넌트 레퍼런스 아키텍처 문서 자체가 옛 AGIC 경로(`aks-agic/aks-agic`)를
  AGFC 콘텐츠로 치환한 상태라 신규 채택 근거로는 약하다. 재검토 트리거: AGFC의
  Gateway API conformance나 private cluster 호환성 실측에서 예상 밖 문제가 나올 때.
- **App Routing(Istio 기반 Gateway API 구현체, GA 2026-04-28)**: AKS 전용 WAF
  가이드의 1순위 예시였으나 (1) azurerm provider 미지원(GitHub #31177 Open) (2)
  self-managed Helm으로 우회해도 Cilium 공식 문서가 요구하는
  `socketLB.hostNamespaceOnly`/`cni.exclusive` ConfigMap 값 변경이 AKS의 Cilium
  커스터마이징 차단 정책과 충돌할 가능성이 있어(이 클러스터의 실제 kube-proxy
  replacement 상태는 미확인) 기각. 재검토 트리거: azurerm이 이 기능을 지원하거나,
  AKS가 Cilium ConfigMap 예외를 늘릴 때.
- **Cilium 자체 Gateway API**: 이미 쓰는 데이터플레인이라 매력적이었으나 AKS
  공식 문서(`azure-cni-powered-by-cilium`)가 ConfigMap 커스터마이징을 명시
  차단해 1라운드 만에 탈락.
- **Envoy Gateway / NGINX Gateway Fabric**: 블로커 자체가 없다(사이드카·CNI
  체이닝 불필요, Terraform 사전조건 없음). 다만 AKS 1st-party 제품이 아니라
  "공식 지원 우선" 원칙에서 AGFC보다 한 단계 밀린다. AGFC 채택 후 예상 밖 문제가
  누적되면 대체 후보 1순위.

## 4. 미해결 유보 사항

- ⚠️ **Gateway API conformance는 벤더 자체 선언 수준.** Kubernetes SIG-Network
  공식 목록(`gateway-api.sigs.k8s.io/implementations/`)에 AGFC/ALB Controller가
  미등재 - MS 자체 문서는 v1.5·GatewayClass/Gateway/HTTPRoute/GRPCRoute 전부
  지원한다고 명시하지만 제3자 conformance 테스트 결과는 아님.
- ⚠️ **private cluster 조합의 canary 실측이 아직 없다.** 지금까지의 근거는
  Architecture Center 멀티테넌트 문서(Bastion 네이티브 연동 언급)뿐이고, 이
  저장소의 실제 배포(private + Overlay + Cilium + Korea Central)로 직접 검증한
  적은 없다. `eks-platform-gitops`가 각 addon을 canary(`helm template`로
  cluster-scoped 리소스 실측)로 검증해온 관행을 그대로 적용해야 한다.
- ⏳ **`iac-module-library`의 `aks-cluster` 모듈은 현재 이 기능과 무관한 필드만
  가진다**(로컬 grep으로 확인, istio/gateway/web_app_routing/service_mesh/
  app_routing 매치 0건). AGFC 채택 자체는 모듈에 새 필드를 요구하지 않는다
  (workload identity federated credential은 이미 별도 issuer/OIDC 설정으로
  가능한 범위) - 단 실제 구현 시 모듈 계약을 다시 확인해야 한다(CLAUDE.md 7절).

## 5. 다음 단계 (aks-platform-gitops 실제 착수 시)

1. deepinit으로 `aks-platform-gitops` repo 초기화.
2. 이 문서의 Decision 1·2를 1차 설계 입력으로 ralplan(Architect+Critic)에 제출 -
   특히 4절의 미해결 유보 2건(conformance 벤더선언·private cluster 미실측)을
   설계 단계에서 canary로 해소할 계획을 포함해야 한다.
3. `eks-platform-gitops`의 `bootstrap/`·`clusters/`·`projects/`·`addons/baseline/`
   레이아웃을 그대로 이식하되, `addons/baseline/aws-load-balancer-controller.yaml`
   자리에 3-2의 AGFC helm 배포를 대응시킨다.
