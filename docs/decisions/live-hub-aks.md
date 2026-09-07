# live/hub/aks - AKS 클러스터 배포 루트 설계 (RALPLAN, 2026-09-03 재작성)

**상태**: 완료(2026-09-03) - hub 구독에 실제 배포, 완료 판정 §4 8항목 전부 통과(v0.5.0 기준)
**범위**: hub 구독에 `iac-module-library`의 `aks-cluster` 모듈(**v0.5.0**)을 소비하는 새 배포 루트.
**범위 밖(사용자 명시 결정)**: workbench(private AKS 접근용 VM) - 별도 후속 계획.

## 0. 이 문서의 전신과 관계

같은 이름의 이전 초안(v0.1.0 기준)이 있었다. Architect·Critic 라운드 1 검토를 받았고
판정은 REVISE였다(`nat_routed` 누락·완료 판정 부실·`az aks command invoke` 미검토
등). 그런데 그 검토가 끝난 직후 모듈이 **`cni_mode`를 신설(0.2.0)하고 기본값을
Overlay로 전환(0.3.0)**해, 이전 초안의 전제(Pod Subnet 고정, Karpenter와 양립 불가)
자체가 사라졌다. 패치가 아니라 새로 썼다(이 문서 2026-09-03 최초 재작성).

그 재작성본을 Architect가 검토하는 과정에서 **v0.3.0 자체의 ARM 레벨 버그**를
찾았다: `cni_mode="overlay"`가 `network_data_plane="cilium"`은 조건부로 켜면서
`network_policy`는 `"azure"`로 고정해 둬, ARM이 "Cilium dataplane requires network
policy cilium."으로 거부한다 - 즉 Overlay 기본값 경로가 apply 단계에서 한 번도
성립한 적이 없었다(모듈 `tofu test`가 `mock_provider`라 이 정합성 오류를 구조적으로
못 잡는다). 사용자 결정에 따라 `iac-module-library`에서 직접 수정해
**`aks-cluster-v0.4.0`**을 발행했다(`network_policy`를 `cni_mode`에 따라 조건부화,
테스트 보강, 전 모듈 `tofu test`·`tflint`·`trivy` 재확인 통과). CNI 모드와 무관했던
지난 검토 결과(RP 등록, identity RG 배치, `az aks command invoke` 검증 경로)는
그대로 가져온다.

v0.4.0으로 첫 실배포(hub)를 마친 뒤, 완료 판정 #8(재-plan 수렴) 확인 과정에서
**두 번째 모듈 버그**를 발견했다: `default_node_pool`·추가 노드 풀 둘 다
`upgrade_settings`를 선언하지 않아, Azure가 채워 넣는 기본값(`max_surge="10%"`)과
매 plan마다 어긋나는 **perpetual diff**가 있었다 - 독립된 plan 3회 연속 같은
diff로 실측 확인(apply해도 수렴하지 않음, 파괴적이지는 않으나 완료 판정 #8을
통과할 수 없는 상태). `iac-module-library`에서 두 리소스 모두
`upgrade_settings { max_surge = "10%" }`를 명시해 정정하고 **`aks-cluster-v0.5.0`**
을 발행했다(회귀 방지 assertion 추가, 전 모듈 테스트 재확인 통과). 이 root의
모듈 소스 참조를 v0.5.0으로 올리고 재적용해 #8까지 통과했다. 이 문서는 v0.5.0을
전제로 한 최종본이다.

---

## 1. RALPLAN-DR 요약

### Principles

1. **모듈 계약은 신뢰하되 소스로 검증한다.** README·변수 설명을 1차 사료로 삼지
   않는다 - 지난 라운드에서 모듈 문서 자체의 오류(Karpenter 네트워킹 호환성 서술)를
   놓쳤던 실패를 반복하지 않는다. 이번 문서의 모든 모듈 인자 근거는 `main.tf`·
   `variables.tf` 원문 확인을 거쳤다.
2. **CI 신원의 권한 상한을 늘리지 않는다.** `Microsoft.Authorization/roleAssignments/write`
   금지(CLAUDE.md 2절)는 이번에도 예외 없다.
3. **소비자 없는 리소스를 미리 켜지 않는다.** Karpenter(NAP)는 GitOps가 관리할
   `NodePool`/`AKSNodeClass`가 있어야 의미가 있는데, `aks-platform-gitops` 자체가
   아직 없다(CLAUDE.md 0절). 기술적으로 켤 수 있다는 것과 지금 켜야 한다는 것은
   다른 질문이다.
4. **검증 가능한 완료 기준만 "성공"이라 부른다.** private 클러스터라 kubectl 직접
   접근은 없지만, `az aks command invoke`(ARM 경유, 워크로드 밖에서 실행)로 노드
   join까지 실제로 확인한다 - ARM 레벨 선언값(`provisioningState` 등)만으로 끝내지
   않는다.
5. **이미 존재하는 리소스를 다시 만들지 않는다.** `aks-node` 서브넷은 이미 배포돼
   있다(`live/hub/networking`, `nat_routed=true` 포함). Overlay는 Pod 서브넷 자체가
   필요 없으므로 이번 계획은 네트워킹 root를 전혀 건드리지 않는다.

### Decision Drivers

1. **`cni_mode` 기본값이 Overlay로 바뀌면서 Pod 서브넷·NAT·CIDR 문제가 전부 사라졌다** -
   지난 라운드 CRITICAL 발견(C1: `nat_routed` 누락)의 원인 자체가 없어졌다.
2. **CI 신원의 권한 상한을 늘리지 않는다** - identity·role assignment는 여전히 CI
   밖(bootstrap)에서 처리해야 한다(모듈 버전과 무관하게 유지되는 제약, `variables.tf`의
   `identity_id` 순서 의존 서술은 v0.4.0에서도 문구 그대로 유지됨, 아래 3-1 확인).
3. **Karpenter는 기술적으로 가능해졌지만 소비자가 없다** - `enable_karpenter` 기본값
   자체도 v0.4.0에서 `true`→`false`로 내려가 모듈 저자도 옵트인으로 재분류했다.
4. **`network_profile`·`private_cluster_enabled` 축이 ForceNew라 미확정 상태에선
   삭제 보호를 켤 수 없다** - `deletion_protection=true`는 이 축들이 더 이상 안
   바뀌기로 확정된 뒤에만 기술적으로 가능하다(3-4).

(이 4개는 ADR의 Drivers와 동일하게 유지한다 - 별도 목록으로 벌어지지 않도록 이
문서에서 SSOT는 여기 하나다.)

### Viable Options - Karpenter를 켤지 말지

#### 옵션 A: `enable_karpenter = false` 유지 (채택)

- Overlay + Karpenter 조합은 이제 지원된다(공식 문서 확인, `learn.microsoft.com/en-us/
  azure/aks/node-auto-provisioning-networking`의 Supported 목록에 Overlay 포함).
  기술적 장벽은 없다.
- 그러나 NAP이 실제로 무언가를 프로비저닝하려면 `NodePool`·`AKSNodeClass` CRD가
  있어야 하고, 그건 GitOps 소관이며 이 repo엔 GitOps 계층이 아직 없다. 지금 켜면
  `mode="Auto"`인데 아무 정책도 없는 죽은 설정이 된다(모듈 README가 이 시나리오를
  명시적으로 경고).
- Principle 3에 정확히 부합. 모듈 자신도 v0.4.0에서 기본값을 `false`로 낮춰 같은
  결론에 도달했다.

#### 옵션 B(기각): `enable_karpenter = true`로 지금 켜기

- 장점: `eks-cluster`(AWS 원본)의 기본값(`true`)과 대칭을 지금 맞출 수 있다.
- 기각 사유: GitOps 계층 없이 켜면 시스템 노드 풀 외엔 아무 노드도 자동 생성되지
  않는 죽은 설정이다 - 검증할 대상 자체가 없어 "검증 가능한 완료 기준만 '성공'이라
  부른다"는 Principle 4와 충돌한다. `aks-platform-gitops` 착수 시점에 켜는 게
  자연스러운 순서다(Follow-ups에 기록).

---

## 2. 아키텍처 개요

```
bootstrap/ (확장)
  └─ hub 대상: user-assigned identity 1개 생성
       + aks-node 서브넷(이미 존재)에 Network Contributor 부여
       + Microsoft.ContainerService 리소스 프로바이더 등록 확인
       → 출력: AZURE_HUB_AKS_IDENTITY_ID (GitHub repo 변수)

live/hub/networking/  ← 이번 계획에서 변경 없음 (aks-node 서브넷 이미 존재, Pod 서브넷 불필요)

live/hub/aks/ (신규 root)
  └─ data.azurerm_subnet으로 aks-node ID 조회 (Name 기반)
  └─ module "aks_cluster" { source = aks-cluster v0.5.0 }
       naming                   = { workload = var.workload, env = var.env, region_code = var.region_code }
       resource_group_name      = "rg-${var.workload}-${var.env}-${var.region_code}-workload-01" (기존 루트와 동일 보간 패턴, 3-5)
       location                 = var.location
       identity_id              = var.aks_identity_id (bootstrap 출력)
       node_subnet_id           = data.azurerm_subnet.aks_node.id
       cni_mode                 = "overlay" (모듈 기본값, 명시 고정)
       pod_cidr                 = "10.244.0.0/16"
       private_cluster_enabled  = true (기본값 유지, 최상위 속성 - network_profile 밖)
       enable_karpenter         = false (Principle 3, 3-2 근거)
       deletion_protection      = false (ForceNew 축 미확정, 3-4 근거)
       sku_tier                 = "Free"
       system_node_pool         = { vm_size = "Standard_D2s_v5", node_count = 2, auto_scaling_enabled = false, max_pods = 30 }
       tags                     = { Environment=..., Workload=..., RegionCode=..., ManagedBy="opentofu", Repository=... } (live/hub/networking와 동일 5종, 3-5)
```

## 3. 상세 설계

### 3-1. identity·role assignment (bootstrap 확장) - v0.1.0 결정 그대로 유지

`aks-cluster/variables.tf`의 `identity_id` 변수 설명은 v0.4.0에서도 동일하다: "이
모듈은 identity도 role assignment도 만들지 않는다 ... bootstrap 계층이 ①·②를
처리한다." CNI 모드 변경과 무관한 축이라 지난 라운드 Architect 검토(공식 문서
`managed-identity-overview`가 이 경로를 정식 권고로 명시)를 그대로 채택한다.

- `bootstrap.sh`(hub 대상)가 `az identity create`로 `id-<workload>-hub-krc-aks-01`을
  **워크로드 RG**(`rg-<workload>-hub-krc-workload-01`)에 생성한다. 워크로드 RG인
  이유: CI 커스텀 역할의 스코프가 그 RG 하나뿐이라, identity가 그 밖에 있으면
  `live/hub/aks` apply가 `Microsoft.ManagedIdentity/userAssignedIdentities/
  assign/action` 권한 부족으로 실패한다.
- 스코프는 **`aks-node` 서브넷 하나**(RG나 VNet 전체가 아니라)로 좁힌다. Microsoft
  공식 문서(`concepts-network-cni-overview`)의 최소 권고("at least Network
  Contributor permissions on the subnet")와 일치한다.
- ⚠️ **이 스코프 선택이 `bootstrap.sh`의 "처음부터 실행 가능" 계약과 어떻게
  공존하는지 명시한다.** hub는 지금 `aks-node`가 이미 배포돼 있어 순서 문제가 없지만,
  이 스크립트는 새 스포크(예: 미래의 `live/dev/aks`)에서도 다시 실행된다 - 그 시점의
  `bootstrap.sh` 최초 실행은 여전히 서브넷보다 먼저 온다(`peer/action`이 정확히 같은
  이유로 RG 스코프로 완화됐던 선례, `bootstrap/README.md` 크로스 구독 절). 그래서
  이 role assignment 단계는 **조건부·수렴형**으로 만든다: 대상 서브넷이 없으면 이
  단계만 경고 후 skip하고 나머지는 정상 진행, 서브넷이 생긴 뒤 `bootstrap.sh`를
  재실행하면 수렴한다(멱등). 최소 권한(서브넷 스코프)과 처음부터-실행 가능성을 동시에
  지키는 선택이고, `peer/action`과 다른 스코프를 택한 이유이기도 하다(액션 1개 대
  대상 1개라는 위험도 차이).
  - `verify.sh`의 `report()` 헬퍼(현재 `ok`는 통과, `absent`·`drift`는 `mismatch`→
    exit 1, 그 외 값은 `die`→exit 2)에 **4번째 상태**(예: `na` - "대상 서브넷 부재,
    미판정", MISMATCH 카운터를 증가시키지 않고 exit 0 유지)를 추가하는 구현
    작업이 필요하다. **이 구현은 hub 첫 배포 커밋에 포함한다**(다음 스포크로 미루지
    않는다) - hub는 서브넷이 이미 있어 이 분기를 안 타지만, 미리 만들어 두지
    않으면 다음 스포크에서 완료 판정 #2가 깨진다는 걸 알면서도 그대로 두는 것이
    되기 때문이다.
    이 상태는 `verify.sh`가 이미 갖고 있는 원칙("조회 대상이 없는 상황을 '0건이라
    통과'로 처리하지 않는다")과 문언상 충돌해 보이지만 범주가 다르다 - 그 원칙은
    **CI 신원 자체**의 권한을 조회하다 실패하는 경우를 가리키고, 여기서는 **아직
    안 만들어진 선행 리소스**(서브넷)를 기다리는 경우다. hub 첫 배포는 서브넷이
    이미 있어 이 분기를 타지 않지만, 다음 스포크(`live/dev/aks`)에서 이 구분이
    없으면 완료 판정 #2가 깨진다 - 지금 명확히 해 둔다.
- ⚠️ **향후 GitOps가 `ilb` 서브넷(내부 LB, ArgoCD ingress 등)에 리소스를 만들 때**
  Microsoft `internal-lb.md`가 요구하는 추가 권한(다른 서브넷을 쓰는 내부 LB는 VNet
  스코프 Network Contributor 또는 대상 서브넷 `subnets/join`+`subnets/read`)이
  필요해질 수 있다 - 지금 `aks-node` 단일 스코프로는 안 덮인다. GitOps 착수 시
  재검토 항목으로 Follow-ups에 남긴다.
- `verify.sh`에 이 identity·role assignment 존재 확인을 추가한다(음성 검사가 아니라
  다른 principal에 대한 양성 존재 확인 절 - 기존 6종 불변식과 범주가 다름을 명확히
  기록한다). 검사 범위는 **identity 리소스 존재 + 서브넷 스코프 role assignment
  존재** 둘 다다(역할 정의 Actions 완전 일치까지는 검사하지 않는다 - `Network
  Contributor`는 built-in 역할이라 워크로드 CI 역할처럼 매 실행 런타임 조회할
  필요가 없다). role assignment 존재까지 확인해야 3-1이 지목한 "②를 건너뛰면
  ③은 성공하고 노드만 조용히 실패한다"는 죽은 경로를 `verify.sh`가 실제로 잡는다
  - identity만 확인하면 이 경로를 놓친다.
- **`Microsoft.ContainerService` 리소스 프로바이더 등록**을 같은 bootstrap 단계에
  포함한다: `az provider register --namespace Microsoft.ContainerService` 확인 후
  미등록이면 등록. CI 신원은 구독 스코프 `*/register/action`이 없어(`live/hub/
  vwan/providers.tf`의 기존 실측 주석과 같은 이유) 미등록 시 apply가 CI 스스로
  복구 불가능한 실패로 막힌다 - 사람이 사전에 처리해야 한다.
- **`bootstrap/README.md` 갱신을 구현 작업에 포함한다.** 이 문서는 bootstrap 기대
  상태의 문서 SSOT다(`## 2. 기대 상태` 아래 산출물별 절 구조, `## 5. 출력값의
  행선지`가 GitHub 변수 배선을 소유) - 이번에 늘어나는 산출물(identity 1개,
  서브넷 스코프 role assignment, RP 등록, `AZURE_HUB_AKS_IDENTITY_ID` 출력) 넷 다
  이 문서에 신규 절/행으로 반영하지 않으면 `verify.sh`가 검사하는 기대 상태와
  문서가 어긋난다(크로스 구독 절이 이미 세운 선례를 따른다).

### 3-2. Karpenter - 끈 채로 시작, GitOps 착수 시 재검토

`enable_karpenter = false`(모듈 기본값과 동일). Overlay + Karpenter 조합 자체는
공식 문서상 지원되지만(1절 옵션 A 참조), `NodePool`/`AKSNodeClass`를 만들 GitOps
계층이 없어 지금 켜면 검증 불가능한 죽은 설정이 된다. `aks-platform-gitops` 착수
시점에 다시 연다(Follow-ups).

이 유보는 비용이 거의 없다 - Microsoft 공식 문서(`use-node-auto-provisioning`)가
`az aks update --node-provisioning-mode Auto`로 **기존 클러스터에 in-place 활성화**,
`Manual`로 **비활성화도 가능**하다고 명시한다(NAP 노드가 남아있지 않아야 한다는
조건만 있음). 단 전제조건이 하나 있다: "모든 노드 풀의 `enableAutoScaling`이
`false`여야 Auto로 전환 가능"하다 - `system_node_pool`을 고정 `node_count`(오토스케일링
끔)로 유지하는 이번 계획의 3-4 결정이 이 조건을 그대로 만족시킨다. 즉 지금
`auto_scaling_enabled=true`로 바꿔두면 나중에 Karpenter를 켤 때 시스템 풀을 다시
고정 크기로 되돌려야 하는 지뢰가 된다 - 3-4에서 이 제약을 함께 기록한다.

### 3-3. 네트워킹 - Overlay, `pod_cidr` 값 결정

`cni_mode = "overlay"`(모듈 기본값, 명시적으로 고정해 문서화). `pod_cidr =
"10.244.0.0/16"`(모듈 `examples/basic`·`az aks create` 관용 기본값과 동일 - 임의
추정이 아니라 모듈이 제시한 값을 그대로 채택).

⚠️ **이 축의 되돌릴 수 없음을 명시한다.** `network_profile` 블록 전체가 ForceNew라
`cni_mode`를 나중에 바꾸면 클러스터가 재생성된다 - 이번 첫 apply가 사실상 최종
선택이다. Overlay를 택한 근거의 SSOT는 이 계획이 아니라 `live/hub/networking/
main.tf`의 CNI 관련 locals 주석이다(이 repo가 이미 내린 결정을 이 계획은 상속만
한다). 모듈이 지원하는 세 번째 모드 `node_subnet`(SNAT 없어 Pod 단위 관측성 유지,
NAP도 호환)을 기각한 이유: 서브넷 하나가 노드+Pod IP를 함께 감당해 사이징을
다시 계산해야 하고, `aks-node`(`/20`)가 이미 노드 전용 크기로 배포돼 있어 지금
바꾸면 네트워킹 root까지 건드리게 된다(Principle 5 위반) - Overlay는 그 재계산이
필요 없다는 것도 채택 근거의 일부다.

충돌 확인:

| 대역 | 값 | 충돌? |
|---|---|---|
| hub VNet | `10.60.0.0/16` | 아니오 |
| dev VNet | `10.61.0.0/16` | 아니오 |
| vWAN 허브 | `10.62.0.0/22` | 아니오 |
| AKS `service_cidr` | 미지정(provider 기본값, 통상 `10.0.0.0/16`) | 아니오 |
| **`pod_cidr`** | **`10.244.0.0/16`** | - |

Overlay는 Pod 트래픽을 VNet/vWAN에 노출하지 않으므로(클러스터 밖으로 나갈 때 노드
IP로 SNAT) hub·dev가 **같은** `pod_cidr` 값을 써도 무방하다 - 각 클러스터의 오버레이는
서로 독립이다. `live/dev/aks`(미래)도 `10.244.0.0/16`을 그대로 쓰도록 이 값을
이 문서에서 관용값으로 못박는다(다음 스포크에서 재조사 불필요).

`aks-node` 서브넷은 이미 `nat_routed = true`로 배포돼 있다(`live/hub/networking/
main.tf`) - 모듈이 하드코딩한 `outbound_type = "userAssignedNATGateway"`(main.tf
확인) 요구를 이미 만족한다. 지난 라운드 C1(`nat_routed` 누락)이 문제였던 이유는
그때 새로 만들려던 `aks-pod` 서브넷에 이 인자가 빠졌던 것 - 이번엔 그 서브넷 자체가
없으므로 이 문제가 원천적으로 사라진다.

### 3-4. 기타 클러스터 설정값

| 인자 | 값 | 근거 |
|---|---|---|
| `private_cluster_enabled` | `true`(기본값 유지, 리소스 최상위 속성 - `network_profile` 밖) | eks-cluster의 `endpoint_public_access=false`와 철학은 유사하나, 모듈 `variables.tf`가 스스로 "이 축은 ralplan이 깊게 다루지 않았다"고 표시한 미확정 기본값이다(과장하지 않는다). `az aks command invoke`(3-6)로 workbench 없이도 검증 가능해 유지에 실질적 비용이 없다. |
| `enable_karpenter` | `false` | 3-2 |
| `deletion_protection` | `false` | 모듈이 이 값을 `prevent_destroy`로 구현하는데(`main.tf`), `prevent_destroy`는 파괴뿐 아니라 **ForceNew 교체까지 차단**한다. ForceNew 축(`network_profile` 블록 전체 + 리소스 최상위 `private_cluster_enabled`)이 확정되기 전(GitOps 연결 전 반복 단계)엔 `true`가 기술적으로 불가능하다 - "반복 단계라서"가 **아니라** "그렇게 두면 앞으로의 변경 자체가 plan에서 막힌다"가 근거다(§2·§5에서도 이 표현을 그대로 쓴다, 다른 근거로 다시 쓰지 않는다). ⚠️ **정정(라운드 2 재확인)**: `require_oidc` 가드가 로컬 destroy를 막는다는 이전 서술은 틀렸다 - `precondition`은 파괴 대상 리소스에 평가되지 않아 실측으로 재현 시(`live/hub/vwan/providers.tf`와 동일 가드, OpenTofu 1.12.5) 로컬 `destroy`가 `ci_run` 값과 무관하게 성공했다. 실제 방어선은 state 백엔드다: `allowSharedKeyAccess=false`+`use_azuread_auth=true`이고 Blob 데이터 역할은 CI SP에게만 할당돼 있어(구독 Owner도 데이터 플레인 RBAC 역할은 기본 미보유) 사람의 로컬 destroy는 state 접근 단계에서 막힌다. CI destroy는 여전히 `workflow_dispatch`의 `confirm` 문자열 정확 일치를 요구한다. ForceNew 축이 더 이상 안 바뀌기로 확정된 후 `true`로 전환한다(Follow-ups). |
| `sku_tier` | `"Free"` | `workload=demo` 레퍼런스 목적, Uptime SLA 불필요, `Standard`로의 전환은 in-place라 가역적. |
| `system_node_pool` | `{vm_size="Standard_D2s_v5", node_count=2, auto_scaling_enabled=false, max_pods=30}` | vm_size·node_count는 모듈 `examples/basic`·README Usage 예시값. `max_pods`를 명시하지 않으면 Overlay 기본값(250)이 그대로 적용되는데, `Standard_D2s_v5`(2 vCPU/8GiB)에 250은 비현실적이다(kubelet 예약만으로도 부족) - 데모 규모에 맞춰 30으로 낮춘다. `auto_scaling_enabled=false`는 3-2가 요구하는 향후 Karpenter in-place 전환 조건이기도 하다. |
| `workload_identity_enabled` | `false`(기본값) | 현재 소비자 없음(YAGNI). `oidc_issuer_url` 출력은 이 값과 무관하게 항상 나가 나중에 재생성 없이 확장 가능. |
| `kubernetes_version` | 미지정(provider 기본값) | 레퍼런스 repo 첫 배포, 최신 권장 버전으로 시작. |
| `local_account_disabled` | `false`(기본값 유지) | Entra 그룹이 아직 결정되지 않아 로컬 계정(브레이크글래스, `kube_admin_config`) 경로를 유지한다. `true`로 두려면 `entra_admin_group_object_ids`를 함께 채워야 한다(모듈 validation) - 지금은 그 그룹 자체가 없다. |
| `entra_admin_group_object_ids` | `[]`(기본값 유지) | Entra RBAC 그룹 미정, 옵트인 블록 자체를 만들지 않는다. GitOps 착수 시 재검토(Follow-ups). |

### 3-5. `live/hub/aks` root 구성

기존 루트(`live/hub/vwan` 등)와 같은 파일 구성으로 만든다(⚠️ 라운드 1의 finding #6과
같은 종류의 누락을 반복하지 않도록, 아래 목록을 전부 채운다 - `backend.hcl.example`·
`versions.tf`·`backend.tf`·`outputs.tf`는 라운드 1 초안에 없었다):

- `versions.tf`: `required_version >= 1.12.0`, `azurerm ~> 5.0`(모듈 repo 규약 - 상한을
  건다).
- `backend.tf`: 빈 `backend "azurerm" {}` 블록만(실제 값은 `backend.hcl`).
- `backend.hcl`(gitignore, `key = "hub/aks.tfstate"`) + `backend.hcl.example`(값
  없는 형태로 커밋, 다음 사람이 무엇을 채워야 하는지 보여줌).
- `providers.tf`(`require_oidc` 가드, `resource_provider_registrations = "none"` -
  3-1에서 `Microsoft.ContainerService`를 사전 등록하므로 이 값 그대로 안전).
- `variables.tf`: `workload`·`env`·`region_code`·`location`·`repository`·
  `subscription_id`·`require_oidc`·`ci_run`(기존 루트 공통 8종) + `aks_identity_id`
  (bootstrap 출력, TF_VAR 주입, 이 root 전용).
- `main.tf`: `data.azurerm_subnet.aks_node`(Name 기반 조회) + `module "aks_cluster"`.
  모듈 필수 입력(`naming`·`resource_group_name`·`location`) 전부 명시 배선하고,
  `tags`는 `live/hub/networking/main.tf`와 동일 5종(`Environment`·`Workload`·
  `RegionCode`·`ManagedBy`·`Repository`)을 채운다 - azurerm에 `default_tags`가
  없어 루트마다 명시해야 한다(모듈 README가 이미 이 경고를 갖고 있음).
- `outputs.tf`: 모듈의 `cluster_name`·`oidc_issuer_url`·`node_resource_group` 등을
  그대로 통과시킨다(후속 workbench·GitOps 계획이 참조할 값).
- `.github/workflows/deploy-hub-aks.yml`: 기존 워크플로와 동일 골격, `AZURE_HUB_AKS_
  IDENTITY_ID`를 TF_VAR로 주입.
- ⚠️ 이미 배포된 root(`live/hub/networking` 등)와 달리 이 root는 **신규 생성**이라
  "머지 전 로컬 plan" 같은 특수 절차가 필요 없다(`+ create`만 있을 것이 자명, 재생성
  위험이 없는 첫 apply).

### 3-6. 검증 경로 - `az aks command invoke` (workbench 없이 kubectl 동등 확인)

Microsoft 공식 문서(`learn.microsoft.com/en-us/azure/aks/access-private-cluster`)로
직접 재확인: private 클러스터에서도 VPN·피어링 없이 ARM API 경유로 `kubectl`·`helm`
명령을 실행할 수 있다. 필요 권한은 `Microsoft.ContainerService/managedClusters/
runcommand/action` + `commandResults/read`뿐이고, `bootstrap.sh`를 실행하는 사람은
이미 구독 Owner라 별도 부여가 필요 없다. ⚠️ 문서가 "프로그래매틱(자동화) 용도가
아니다"라고 명시하므로 CI가 아니라 **사람이 수동으로** 돌리는 검증 단계로 쓴다(기존
`verify.sh` 일부 수동 절차와 같은 성격).

```bash
az aks command invoke -g <rg> -n <cluster> --command "kubectl get nodes -o wide"
```

---

## 4. 완료 판정

| # | 확인 | 명령 | 무엇을 증명하나 |
|---|---|---|---|
| # | 확인 | 명령 | 결과 |
|---|---|---|---|
| 1 | 사전조건: RP 등록 | `az provider show -n Microsoft.ContainerService --query registrationState` → `Registered` | ✅ 2026-09-03 실측 이미 `Registered` |
| 2 | bootstrap.sh(hub) identity·role assignment 생성, verify.sh 신규 절 통과 | `./bootstrap/verify.sh` exit 0 | ✅ `=== drift 없음 ===`, exit 0 |
| 3 | `live/hub/aks` apply 성공(신규 root, `+ create`만) | CI plan/apply 로그 | ✅ 첫 시도는 `AZURE_HUB_AKS_IDENTITY_ID`의 `resourcegroups`(소문자) 세그먼트가 azurerm provider(v5 타입 SDK) 요구사항과 안 맞아 plan 실패("the segment at position 2 didn't match") - `bootstrap.sh`에 `sed`로 정규화 추가 후 재시도 성공 |
| 4 | 컨트롤 플레인 상태 | `az aks show -g <rg> -n <cluster> --query provisioningState` → `Succeeded` | ✅ `Succeeded` |
| 5 | **`network_profile` 조합이 실제로 요청대로 적용됐는지**(v0.3.0을 죽였던 바로 그 축) | `az aks show -g <rg> -n <cluster> --query "networkProfile.{mode:networkPluginMode,dp:networkDataplane,pol:networkPolicy,pod:podCidr,ob:outboundType}"` | ✅ `{"mode":"overlay","dp":"cilium","pol":"cilium","pod":"10.244.0.0/16","ob":"userAssignedNATGateway"}` - v0.4.0의 `network_policy` 수정이 실제로 동작함을 실증. ⚠️ CLI 필드명은 `networkDataplane`(소문자 p)이지 `networkDataPlane`이 아니다 - `az aks show --query networkProfile`로 전체 덤프해 실제 키를 확인할 것 |
| 6 | **노드가 실제로 서브넷에 join했는지**(선언값이 아니라 실물, VMSS 인스턴스 레벨) | `NODE_RG=$(az aks show -g <rg> -n <cluster> --query nodeResourceGroup -o tsv); VMSS=$(az vmss list -g "$NODE_RG" --query "[0].name" -o tsv); az vmss nic list -g "$NODE_RG" --vmss-name "$VMSS" --query "[].ipConfigurations[].subnet.id" -o tsv` | ✅ 노드 2대 모두 `snet-demo-hub-krc-aks-node` |
| 7 | **kubectl 레벨 확인**(workbench 없이) | `az aks command invoke -g <rg> -n <cluster> --command "kubectl get nodes -o wide"` | ✅ 노드 2대 `Ready`, `INTERNAL-IP` = `10.60.16.5`·`10.60.16.6`(`10.60.16.0/20` 대역 안) |
| 8 | 재-plan 수렴 | CI 재-plan → `No changes` | ⚠️→✅ 첫 재-plan에서 `default_node_pool.upgrade_settings` perpetual diff 발견(모듈이 이 블록을 선언 안 해 Azure 기본값 `max_surge="10%"`와 매번 어긋남, 독립 plan 3회로 재현 확인) - `iac-module-library`에서 `upgrade_settings { max_surge = "10%" }` 명시 후 `aks-cluster-v0.5.0` 발행, 이 root를 v0.5.0으로 올려 재적용 후 `No changes` 확인 |

## 5. 리스크·완화

| 리스크 | 완화 |
|---|---|
| **이 root가 `aks-cluster`의 최초 실제 Azure 배포다**(R1) - 모듈 `tofu test`는 `mock_provider`로 ARM 자체를 흉내 낼 뿐이라(v0.3.0의 `network_policy` 버그, v0.4.0의 `upgrade_settings` perpetual diff 둘 다 이 한계 때문에 릴리스까지 안 잡혔던 전례, 0절) 스키마 밖의 정합성 문제가 남아있을 수 있다 | 완료 판정을 선언값이 아니라 실물 확인(#5 `networkProfile` 직접 조회, #6 VMSS 인스턴스 NIC, #7 kubectl, #8 재-plan 수렴)으로 구성해 apply·재-plan 양쪽에서 바로 드러나게 한다 - 실제로 이 두 검증이 v0.4.0의 남은 버그(`upgrade_settings`)를 잡아 v0.5.0으로 이어졌다. 실패 시 모듈 저자(이 repo와 동일 조직) 이슈로 즉시 피드백 |
| `node_provisioning_profile` 블록이 `enable_karpenter=false`일 때도 항상 전송된다(`mode="Manual"`) - 이 속성이 구독 feature flag(`az feature register`) 등록을 요구하면 CI가 자가 복구 불가능한 실패에 빠질 수 있다(모듈 자신도 "스키마 수준만 보장한다"고 명시, `tofu validate`로만 확인됨) | 완료 판정 #1(RP 등록 확인) 단계에서 `az feature list --namespace Microsoft.ContainerService`도 함께 확인. **실측(2026-09-03, hub 구독)**: 257개 feature flag 전체에 `NodeAutoProvisioning*`·`Karpenter*` 항목 자체가 없다(GA된 기능은 목록에서 사라진다) - 이 리스크는 사실상 낮다 |
| `Microsoft.ContainerService` 미등록으로 첫 apply 실패 | 3-1에서 bootstrap 단계로 사전 등록 + 완료 판정 #1로 사전 확인. **실측(2026-09-03, hub 구독)**: 이미 `Registered` - 리스크는 사실상 소멸했고 bootstrap의 등록 단계는 멱등 안전망으로 남긴다 |
| identity RG 오배치로 `assign/action` 실패 | 3-1에서 워크로드 RG로 명시 고정. **실측(2026-09-03, hub 구독)**: CI 워크로드 역할이 이미 이 액션을 보유 확인(`Microsoft.Authorization/*/Write`만 제외, `roleAssignments/write`는 여전히 차단돼 CLAUDE.md 2절 유지) |
| `deletion_protection=false`로 실수 삭제 위험 | ForceNew 축(network_profile + private_cluster_enabled) 미확정이라 `true`가 기술적으로 불가능한 상태(3-4) - "리스크 수용"이 아니라 제약의 결과다. 실제 방어선은 state 백엔드(Blob 데이터 역할이 CI SP 전용, 구독 Owner도 데이터 플레인 기본 미보유) + CI destroy의 `confirm` 문자열 정확 일치다(`require_oidc` 가드는 로컬 destroy를 막지 못한다는 걸 실측으로 확인, 3-4 정정 참고). 안정화 후 `true` 전환을 Follow-ups에 명시, 방치하지 않는다 |
| `pod_cidr` 값이 향후 다른 클러스터와 충돌 | Overlay는 클러스터 간 격리라 원천적으로 무해(3-3) - 충돌 가능성 자체가 구조적으로 없음 |
| `service_cidr` 미지정으로 provider 기본값(`10.0.0.0/16`)에 암묵 의존 - 변경 시 ForceNew | `pod_cidr`처럼 관용값으로 명시하지 않은 이유: 클러스터 로컬 값이라 다른 클러스터와 중복돼도 무해하고(hub·dev VNet과도 충돌 없음, 3-3 표) 지금 명시할 실익이 없다(YAGNI) - 다만 CLAUDE.md 3절 "CIDR 배치는 각 루트 locals 주석이 실물 SSOT" 원칙에 따라 `live/hub/aks/main.tf`에 "provider 기본값 사용, 미지정" 주석은 남긴다 |
| Karpenter 재검토 시점을 놓침 | Follow-ups에 "GitOps 착수 시" 트리거를 명시(project-memory에도 기록) |
| 첫 apply가 클러스터는 만들고 노드 풀에서 실패하면 롤백 경로가 불명확 | 로컬 apply·destroy 둘 다 막혀 있으므로(3-4) 유일한 경로는 CI destroy(`workflow_dispatch` + `confirm='destroy live/hub/aks'`, 기존 워크플로와 동일 패턴) - 부분 실패 시 이 경로로 걷어내고 원인 파악 후 재시도한다 |
| 완료 후 "노드 2대의 빈 private 클러스터" 상태가 방치되면 상시 과금(VM 2대+NAT Gateway) 발생 | GitOps·workbench 후속 계획이 착수되지 않은 채 장기간(예: 2주) 방치되면 `cluster_enabled=false`로 파기하고 재배포 시점에 다시 apply한다 - project-memory에 착수 예정일 기록 |

---

## ADR

- **Decision**: `aks-cluster` v0.5.0을 `cni_mode="overlay"`(기본값), `enable_karpenter=false`,
  `private_cluster_enabled=true`(기본값), `deletion_protection=false`로 소비한다.
  identity·role assignment는 `bootstrap.sh` 확장(워크로드 RG의 `aks-node` 서브넷
  스코프)이 전담한다.
- **Drivers**: §1 Decision Drivers 4개와 동일(Overlay 기본값 전환, CI 권한 상한
  유지, Karpenter 소비자 부재, `network_profile`/`private_cluster_enabled`의
  ForceNew 제약).
- **Alternatives considered**: Karpenter 즉시 활성화(옵션 B, 기각 - GitOps 없어
  검증 불가능한 죽은 설정), identity role assignment를 VNet 스코프로 확대(모듈
  자신의 `examples/basic`이 채택한 형태이기도 함 - "노드·Pod 서브넷 둘 다 덮는다"가
  근거. 기각 - 최소 권한을 우선하되 3-1의 조건부·수렴형 설계로 새 스포크에서도
  성립하게 함, 다만 향후 `ilb` 확장 시 VNet 스코프로 재검토될 수 있음, Follow-up 5),
  `network_policy` 버그를 이 repo에서 우회(기각 - 모듈 자체의 결함이라 모듈에서
  고쳐 다른 소비자에게도 이득이 되도록 함, 0절).
- **Why chosen**: 모듈 기본값과 이 repo의 기존 원칙(YAGNI, CI 권한 최소화, 검증
  가능성)이 전부 같은 결론을 가리킨다 - 별도의 트레이드오프 없이 채택.
- **Consequences**: Karpenter·GitOps·Workload Identity 전부 "원시 재료만 준비되고
  실사용은 후속 계획" 상태로 남는다. `deletion_protection=false`는 `network_profile`
  축이 ForceNew라는 기술적 제약의 결과이지 리스크 수용이 아니다 - 다른 층(state
  백엔드 RBAC, `workflow_dispatch`의 `confirm` 문자열)이 실수 삭제를 이미 상당히
  막고 있다(`require_oidc` 가드는 apply만 막고 destroy는 막지 못한다는 걸 라운드 2에서
  실측으로 정정했다). identity role assignment의 조건부·수렴형 설계(3-1)는 다음
  스포크에서 재검증이 필요하다는 부채를 남긴다.
- **Follow-ups**:
  1. workbench 후속 계획(사용자 결정, 별도 진행 중)
  2. `aks-platform-gitops` 착수 시 `enable_karpenter=true` 재검토
  3. ForceNew 축(`network_profile` 블록의 `cni_mode`·`service_cidr` + 리소스
     최상위 `private_cluster_enabled`)이 더 이상 바뀌지 않기로 확정된 후
     `deletion_protection=true` 전환
  4. `live/dev/aks`도 이 문서의 `pod_cidr`(`10.244.0.0/16`) 관용값을 그대로 승계
  5. GitOps가 `ilb` 서브넷에 내부 LB를 세울 때 identity role assignment 스코프
     확장 필요 여부 재검토(3-1)
  6. 구현 시 `bootstrap/config.sh`의 `peer/action` 스코프 관련 stale 주석("실제
     할당 스코프는 VNet 리소스 하나뿐이다 - RG 전체가 아니다", 실제 코드는 RG
     스코프)을 같은 커밋에서 정정 - 이 계획 3-1이 그 코드를 선례로 인용하므로
     다음 독자의 오독을 막는다
