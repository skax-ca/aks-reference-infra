# live/hub/vwan + live/dev/networking 설계

**상태**: 배포 완료. hub VNet·dev VNet·vWAN 허브·양방향 스포크 연결 전부 실제
Azure에 적용되고 수렴 검증까지 통과했다.
**작성**: 2026-08-28, 2026-09-03 갱신(Overlay CNI 채택으로 Pod CIDR 설계 전체가
무효화됨에 따라 전면 재작성).

## 1. Decision

1. `live/hub/vwan`을 raw `azurerm` 리소스(모듈 아님)로 신설하고 vHub 주소 공간을
   `10.62.0.0/22`로 잡는다.
2. hub CI 신원이 스포크 연결을 소유한다. dev 구독에는
   `Microsoft.Network/virtualNetworks/peer/action` 단일 액션 커스텀 역할을 dev
   **워크로드 리소스 그룹** 스코프로 할당한다(`bootstrap.sh`가 스포크 부트스트랩
   1회 실행으로 함께 만든다).
3. Pod 네트워킹은 Azure CNI **Overlay**를 쓴다(`aks-cluster` 모듈 v0.3.0 기본값).
   Pod IP는 VNet 밖 오버레이 대역에서 나오므로, hub·dev VNet 어느 쪽에도 Pod
   전용 secondary CIDR을 두지 않는다.

**Decision Drivers**:

1. **폭발 반경**: hub는 구독 하나의 단일 고정 거처다. dev CI 신원이 hub의 공유
   컨트롤 플레인에 쓰기 권한을 갖는 순간, 구독 분리로 세운 1차 방어선이
   무의미해진다.
2. **되돌림 비용**: vHub 주소 공간과 VNet `address_space`는 사후 변경이
   파괴적이다. CIDR 결정은 각 루트의 첫 apply 전에 끝나야 한다.
3. **Phase 2 정합성**: 이 네트워킹 설계의 유일한 소비자는 Phase 2 AKS다.

## 2. CIDR 배치

| 대역 | 용도 | 상태 |
|---|---|---|
| `10.60.0.0/16` | hub VNet | ✅ 배포됨 |
| `10.61.0.0/16` | dev VNet | ✅ 배포됨 |
| `10.62.0.0/22` | vHub 주소 공간 | ✅ 배포됨 |

Pod IP는 이 표의 어느 대역에도 속하지 않는다 - Overlay CNI가 VNet 밖 오버레이
CIDR(`aks-cluster` 모듈의 `pod_cidr` 인자)에서 할당하기 때문이다(3절 참고).

vHub `/22` 근거: 최소는 `/24`, 권장은 `/23`이지만 Secured Virtual Hub(vWAN 안에
Azure Firewall을 두는 구성)는 최소 `/22`가 요구된다. vHub 주소 공간은 생성 후
변경할 수 없고, Firewall 도입 여부가 아직 미정이므로 나중에 선택지를 남기는 값을
지금 잡는다. 우리가 통제하는 사설 대역에서 `/22`와 `/23`의 비용 차이는 0이다.
(`learn.microsoft.com/en-us/azure/virtual-wan/hub-settings`)

## 3. Pod 네트워킹 - Overlay CNI 채택으로 CIDR 유일성 문제가 소멸

이 설계는 원래 Azure CNI Pod Subnet(flat, 클러스터 밖으로 나가는 트래픽을
SNAT하지 않음)을 전제로, hub·dev가 서로 다른 Pod CIDR(`100.64.0.0/16`·
`100.65.0.0/16`)을 쓰고 그 대역이 vWAN을 건너 라우팅되게 하는 안이었다 - AWS VPC
CNI(모든 스포크가 노드 SNAT 덕분에 같은 dup 대역을 재사용)와 달리, Azure CNI Pod
Subnet은 크로스 VNet 트래픽에서도 Pod IP를 그대로 보존해(`concepts-network-legacy-cni`
공식 문서) 대역이 겹치면 왕복이 성립하지 않기 때문이었다.

`iac-module-library`의 `aks-cluster` 모듈이 v0.3.0에서 `cni_mode` 기본값을 Azure CNI
**Overlay**로 정정하면서(Microsoft 공식 문서 `plan-pod-networking`의 일반 권고,
AKS baseline 참조 아키텍처) 이 전제 자체가 사라졌다. Overlay는 Pod 트래픽을
VNet/vWAN 라우팅 테이블에 전혀 노출하지 않고, 클러스터 밖으로 나갈 때 노드 IP로
SNAT한다 - Pod CIDR을 스포크마다 다르게 잡을 이유도, vWAN에서 그 대역을 선택적으로
전파·제외할 이유도 없어졌다. `live/hub/networking/main.tf`·`live/dev/networking/main.tf`
에서 옛 secondary CIDR(`cidr_pod_dup`)을 제거했다(2026-09-03, 같은 커밋).

경계 통과 시점 SNAT 대안(Azure NAT Gateway, Azure Firewall SNAT, `ip-masq-agent`)도
같은 이유로 검토가 무의미해졌다 - 필요했던 문제 자체가 없어졌다. Overlay가 아닌
경로로 되돌아갈 이유가 생기면 이 대안들을 처음부터 다시 검토한다.

## 4. 크로스 구독 vWAN 연결 권한

`learn.microsoft.com/en-us/azure/virtual-wan/roles-permissions`의 "Example 1"이
hub virtual network connection 생성에 필요한 권한을 액션 단위로 명시한다.

> - Create a Hub Virtual Network connection (`Microsoft.Network/virtualHubs/hubVirtualNetworkConnections/write`)
> - Create a Virtual Network peering with the spoke Virtual Network (`Microsoft.Network/virtualNetworks/peer/action`)
> - Read the route table(s) that the Virtual Network connections are referencing (`Microsoft.Network/virtualhubs/hubRouteTables/read`)

셋 중 둘째만 **원격(dev) 구독**에 필요하고, 나머지 둘은 hub 구독 안(hub의 vWAN·vHub가
hub 워크로드 RG 안에 있으므로 기존 워크로드 커스텀 역할이 이미 커버한다)이다.

⚠️ 검색에서 자주 나오는 "원격 VNet 구독의 `Contributor`가 필요하다"는 안내는 크로스
**테넌트** 문서(`cross-tenant-vnet`)의 것이다. 이 저장소는 동일 테넌트의 크로스
**구독**이고, 위 roles-permissions 문서가 액션 단위로 정확히 답한다.

**채택**: hub CI 신원이 연결을 소유한다(AWS 원본은 스포크가 attachment를
소유해 방향이 반대다). dev 구독에 단일 액션 커스텀 역할을 만들어 **dev 워크로드
리소스 그룹** 스코프로 할당한다.

```
roleName:         aks-ref-bootstrap-spoke-peer-dev
actions:          ["Microsoft.Network/virtualNetworks/peer/action"]
assignableScopes: ["/subscriptions/<dev>/resourceGroups/rg-demo-dev-krc-workload-01"]
할당 스코프:       .../resourceGroups/rg-demo-dev-krc-workload-01
할당 대상:         hub App Registration(entapp-demo-hub-krc-gha-01)의 SP
```

**대안이었던 dev CI 소유 방식(기각)**: AWS 원본과 소유 방향이 같아 `live/hub/vwan`이
dev의 존재를 몰라도 되는 장점이 있지만, dev CI에 hub의
`virtualHubs/hubVirtualNetworkConnections/write`·`hubRouteTables/read`가 필요해져
공유 컨트롤 플레인에 대한 쓰기 권한이 된다. 탈취된 dev CI가 임의 VNet을 허브에
붙이거나 hub 자신의 연결을 지울 수 있어, 액션 1개짜리 채택안과 폭발 반경이 다르다.
AWS RAM이 제공하는 "계정 단위로 못박고 자동 수락"하는 계층이 Azure vWAN에는 없어
이 위험을 흡수할 수단이 없다.

**불변식과의 양립**: 기존 불변식("CI 신원이 자기 워크로드 RG 밖에 role assignment
0건")를 "허용 목록과 완전 일치"로 승격한다. 허용 목록은 정확히 위 1건이다.
`verify.sh`가 (1) 건수가 정확히 1인지, (2) 역할 이름이 정확히 일치하는지, (3) 스코프가
정확히 그 워크로드 RG인지를 검사한다. dev 쪽 `verify.sh`에도 대칭 검사가 있다(외부
principal이 이 RG에 갖는 할당이 그 1건뿐인가).

**스코프를 VNet 리소스에서 워크로드 RG로 완화한 이유(2026-09-03)**: `bootstrap.sh`는
항상 `live/*/networking`의 VNet apply보다 먼저 실행되므로, 최초안(스코프를 VNet
리소스 하나로 좁힘)은 VNet이 아직 없는 시점엔 스코프를 지정할 수 없어 별도 스크립트를
VNet 생성 후에 한 번 더 실행해야 했다. 스코프를 스포크 워크로드 RG(`bootstrap.sh`
1단계가 이미 만드는 리소스)로 완화하면 `peer/action` 할당을 `bootstrap.sh` 자신의
"6-1. 크로스 구독 스포크 연결 권한" 절로 통합할 수 있어, 스포크 부트스트랩 1회
실행만으로 끝난다. 대가는 hub SP가 그 RG에 나중에 생길 다른 리소스에도
`peer/action`을 자동으로 갖게 되는 것인데, 이 액션은 VNet 피어링 연결 생성만
가능해 위험도가 낮다고 판단했다. 실제 구현은 `bootstrap.sh` "6-1" 절,
`config.sh`의 `HUB_APP_NAME`·`SPOKE_PEER_ROLE_NAME`·
`spoke_peer_role_definition_json`, `verify.sh`의 "불변식 (a) 예외" 절(가드를
`BOOTSTRAP_TARGET == "spoke"`로 일반화해 다음 스포크에도 자동 적용)이다. dev 대상
음성 테스트(RG 스코프 assignment를 `Contributor`로 치환 → `verify.sh` drift 확인 →
원복 → `bootstrap.sh`로 재수렴 → drift 없음)까지 통과했다.

## 5. 모듈이 아니라 raw 리소스로 만든 이유

`live/hub/vwan`은 raw `azurerm_*` 리소스로 만든다. 독립적인 근거 3개가 같은 답을
가리킨다.

1. 이 repo의 헌장이 "모듈 자체는 만들지 않는다"이다. 모듈은 `iac-module-library` 소관.
2. AWS 원본도 TGW를 모듈화하지 않았다(`live/hub/tgw/main.tf`가 raw
   `aws_ec2_transit_gateway`·`aws_ram_*`·`aws_ec2_managed_prefix_list`).
3. 소비자가 1개다. vWAN 허브는 구독당 하나이고 재사용 압력이 없다.

먼저 `iac-module-library`에 `vwan` 모듈을 만드는 대안은 계약·테스트·문서가 `vnet`과
일관되고 이후 재사용이 쉽지만, 소비자 1개짜리 모듈을 먼저 만드는 것은 이 repo가
아니라 모듈 repo의 설계 원칙에도 어긋나 기각했다. 나중에 `vwan` 모듈이 생기면
`moved`/import로 옮기는 문제이지 재설계가 아니다.

## 6. 연결 리소스가 사는 곳

스포크 연결은 `live/hub/vwan` state에 둔다. 대안(스포크별 별도 루트
`live/hub/vwan-spoke-dev`)은 스포크가 늘 때 vWAN 루트 전체를 재-plan하지 않아도
되는 장점이 있으나, state·워크플로가 스포크마다 하나씩 늘고 지금 스포크는 1개라
채택하지 않았다. dev VNet ID는 data source로 조회하지 않고 CI 변수(`spoke_connections`)로
주입한다 - 조회하려면 dev 구독에 `virtualNetworks/read`가 추가로 필요한데, 그 한
액션을 아끼는 편이 낫다.

## 7. 검증 절차

- `az network vhub get-effective-routes --resource-type RouteTable --resource-id
  <defaultRouteTable>`로 hub·dev 양쪽 대역이 서로의 연결 next hop으로 전파됐는지
  확인한다.
- 연결 양쪽의 `routingState`가 `Provisioned`인지 확인한다.
- hub `vm` 서브넷과 dev `vm` 서브넷에 임시 VM을 하나씩 띄우고 양방향 TCP 도달을
  확인한다.
- **negative(권한 방어선이 실제로 동작함을 증명)**: dev VNet의 `peer/action` 할당을
  RG 밖 스코프로 넓히거나 built-in `Contributor`로 바꾼 뒤 `verify.sh`가 drift를
  검출하는지, 원복 후 수렴하는지 확인한다.

## 8. Open Questions (해소분 제외, 잔여만)

`docs/decisions/open-questions.md`에도 함께 기록한다.

- Azure Firewall을 vWAN 허브에 둘 것인가 - 지금 답할 필요는 없지만 vHub 주소 공간을
  `/22`로 잡은 이유가 여기 걸려 있다(사후 변경 불가, 2절).
- `scripts/validate-doc-conventions.py` 이식 시점(아직 미이식).

## 9. ADR

- **Decision**: `live/hub/vwan`을 raw `azurerm` 리소스로 신설(vHub `10.62.0.0/22`).
  hub CI 신원이 스포크 연결을 소유하고, dev 구독에는 `peer/action` 단일 액션
  커스텀 역할을 dev 워크로드 RG 스코프로 할당한다(`bootstrap.sh`에 통합). Pod
  네트워킹은 Overlay CNI를 써서 Pod CIDR을 VNet/vWAN 설계에서 완전히 분리한다.
- **Drivers**: 폭발 반경(구독 분리를 무의미하게 만들지 않는다) · 되돌림 비용(vHub
  주소 공간과 VNet `address_space`는 사후 변경이 파괴적) · Phase 2 정합성.
- **Alternatives considered**: dev CI가 연결을 소유(hub 컨트롤 플레인 쓰기 권한
  필요, 기각) · `iac-module-library`에 `vwan` 모듈 선행 추가(소비자 1개, 기각) ·
  스포크별 별도 연결 루트(스포크 1개인 지금은 과잉, 보류).
- **Consequences**: 불변식 (a)가 "0건"에서 "허용 목록 1건과 완전 일치"로 바뀐다.
  스포크가 늘 때마다 그 스포크의 `bootstrap.sh` 실행이 이 role assignment를
  함께 만든다(사람 개입 1회, 자동화하지 않는다는 원칙 유지). Pod 네트워킹은 이
  설계와 완전히 무관해졌다 - CIDR 계획을 다시 세울 필요가 없다.
- **Follow-ups**: `verify.sh` 양쪽 크로스 구독 허용 목록 검사 유지 · Phase 2에서
  AKS가 추가 `roleAssignments/write`를 요구하면 이 설계 전체 재검토.
