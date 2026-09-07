# live/hub/vwan + live/dev/networking 설계

**상태**: 승인됨(approved) — 사용자가 Pod CIDR 변경(4-4 Option A) + dev
`deletion_protection=true`를 확정(2026-08-28). 구현은 아직 시작하지 않았다.
**모드**: RALPLAN-DR **DELIBERATE**(pre-mortem + 확장 테스트 계획 포함).
**작성**: 2026-08-28

✅ 이 계획은 **이미 배포된 결정 하나를 뒤집는다**(dev Pod CIDR 중복 사용 폐기).
근거는 4-4, 사용자 승인 완료(2026-08-28) — `live/dev/networking` 착수 가능.

## 0. 요약: 이번 조사가 바꾼 것

두 가지를 Microsoft 공식 문서로 실측 확인했고, 그 결과 기존 가정 하나가 무너졌다.

1. **vWAN 허브 라우팅에서 특정 대역을 빼는 메커니즘은 존재한다.** AWS TGW의 "자동 전파
   끄고 정적 라우트만 명시"와 1:1 대응하는 것이 vWAN에도 있다(연결의 "Propagate to
   none" + Default 라우팅 테이블의 정적 라우트). 이건 좋은 소식이다.
2. ⛔ **그런데 그 메커니즘이 떠받치려던 전제가 Azure에서 성립하지 않는다.** AWS 원본이
   Pod 대역(`100.64.0.0/16`)을 모든 스포크에서 재사용할 수 있었던 이유는 VPC CNI가
   VPC 밖으로 나가는 Pod 트래픽을 노드 IP로 SNAT하기 때문이다. Phase 2 기본값으로
   확정한 Azure CNI Pod Subnet(dynamic IP allocation)에는 **그 SNAT가 없다**.

   > "But for Azure CNI for dynamic IP allocation, no matter the connection is inside
   > the same virtual network or cross virtual networks, the pod IP is always the
   > source address for any traffic from the pod. ... Hence, it eliminates the use of
   > `ip-masq-agent`, which is still used by traditional Azure CNI."
   > (`learn.microsoft.com/en-us/azure/aks/concepts-network-legacy-cni`)

   따라서 hub와 dev가 같은 `100.64.0.0/16`을 쓰면, hub ArgoCD Pod가 dev API 서버로
   보낸 요청의 **응답이 hub로 돌아오지 못한다**(dev 입장에서 `100.64.x.x`는 자기
   로컬 대역이다). hub-spoke 패턴이 존재하는 바로 그 용도가 깨진다.

`live/hub/networking/main.tf`의 `cidr_pod_dup` 주석("cidr_pod_dup를 허브 라우팅
테이블에서 전파 제외해야 스포크마다 중복 허용이 실제로 성립한다")은 이 조사 이전에
쓰인 것이고, 지금 근거로 삼으면 안 된다.

## 1. Principles

1. **AWS 원본과 1:1로 간다. 어긋날 때는 공식 문서 인용과 함께 명시적으로 어긋난다.**
   침묵하는 편차가 가장 비싸다.
2. **크로스 구독 권한은 "0건 불변식"을 포기하지 않고 "허용 목록 완전 일치"로 승격한다.**
   예외를 만들되 검증 가능한 형태로만 만든다.
3. **되돌릴 수 없는 값은 처음에 넉넉히 잡는다.** vHub 주소 공간은 생성 후 변경 불가다.
4. **이 repo는 모듈을 만들지 않는다.** 소비만 한다.
5. **소비자 없는 리소스를 미리 만들지 않는다.** 단, 소유한 리소스의 속성은 미룰 이유가 없다.

## 2. Decision Drivers (top 3)

1. **폭발 반경**: hub는 구독 하나의 단일 고정 거처다. dev CI 신원이 hub의 공유
   컨트롤 플레인에 쓰기 권한을 갖는 순간, 구독 분리로 세운 1차 방어선이 무의미해진다.
2. **되돌림 비용**: vHub 주소 공간과 VNet address_space는 사후 변경이 파괴적이다.
   Pod CIDR 결정은 `live/dev/networking` apply 전에 끝나야 한다.
3. **Phase 2 정합성**: 이 네트워킹 설계의 유일한 소비자는 Phase 2 AKS다. CNI 기본값
   (Azure CNI Pod Subnet, flat)과 라우팅 설계가 어긋나면 지금은 아무 증상이 없고
   클러스터 두 개가 다 선 뒤에 터진다.

## 3. CIDR 배치(확정 제안)

| 대역 | 용도 | 상태 |
|---|---|---|
| `10.60.0.0/16` | hub VNet primary | ✅ 배포됨 |
| `100.64.0.0/16` | hub VNet secondary(Pod) | ✅ 배포됨 |
| `10.61.0.0/16` | dev VNet primary | ⏳ 예약됨 |
| `100.65.0.0/16` | dev VNet secondary(Pod) | ⏳ **이 계획의 제안**(4-4) |
| `10.62.0.0/22` | vHub 주소 공간 | ⏳ **이 계획의 제안** |

vHub `/22` 근거: 최소는 `/24`, 권장은 `/23`이지만, vWAN 안에 Azure Firewall을 두는
경우(Secured Virtual Hub) 최소 `/22`가 요구된다. 그리고 **vHub 주소 공간은 생성 후
변경할 수 없다**. Firewall 배포 여부는 아직 확정된 바 없으므로, 나중에 선택지를
남기는 값으로 지금 잡는다. 우리가 통제하는 사설 대역에서 `/22`와 `/23`의 비용 차이는
0이다. (`learn.microsoft.com/en-us/azure/virtual-wan/hub-settings`)

Pod 대역은 전부 RFC 6598 `100.64.0.0/10` 안에서 `/16`씩 뗀다. 스포크 N번째는
`100.(64+N).0.0/16`. 온프레미스 비라우팅이라는 성질은 그대로 유지된다.

## 4. 네 가지 질문에 대한 권고

### 4-1. 크로스 구독 vWAN 권한 스코프 (Q1)

**필요한 권한은 정확히 확정됐다.** `learn.microsoft.com/en-us/azure/virtual-wan/roles-permissions`
의 "Example 1"이 hub virtual network connection 생성에 필요한 권한을 열거한다.

> - Create a Hub Virtual Network connection (Microsoft.Network/virtualHubs/hubVirtualNetworkConnections/write)
> - Create a Virtual Network peering with the spoke Virtual Network (Microsoft.Network/virtualNetworks/peer/action)
> - Read the route table(s) that the Virtual Network connections are referencing (Microsoft.Network/virtualhubs/hubRouteTables/read)

세 권한 중 앞의 둘째만 **원격(dev) 구독**에 필요하고, 나머지 둘은 hub 구독 안이다.
연결 리소스 자체가 vHub의 자식이기 때문이다. 그리고 hub의 vWAN·vHub는 hub 워크로드
RG 안에 만들 것이므로, **hub 쪽에는 새 권한이 전혀 필요 없다**(기존 워크로드 커스텀
역할이 이미 그 RG에서 `Actions:["*"]`이고 `peer/action`은 Contributor의 notActions에
없다).

⚠️ **`Contributor` 안내는 우리 시나리오의 근거가 아니다.** 검색에서 자주 나오는
"원격 VNet 구독의 Contributor가 필요하다"는 문장은 크로스 **테넌트** 문서
(`cross-tenant-vnet`)의 것이다. 우리는 동일 테넌트의 크로스 **구독**이고, 위
roles-permissions 문서가 액션 단위로 정확히 답한다. 이전 설계 반복이 이미 같은
정정을 한 번 거쳤다(`bootstrap-credential-design.md`의 v4 정정).

#### Option A (권고): hub CI 신원이 연결을 소유한다

dev 구독에 **단일 액션 커스텀 역할**을 만들고, **dev VNet 리소스 스코프**에 할당한다.

```
roleName:         aks-ref-bootstrap-spoke-peer-dev
actions:          ["Microsoft.Network/virtualNetworks/peer/action"]
assignableScopes: ["/subscriptions/<dev>/resourceGroups/rg-demo-dev-krc-workload-01"]
할당 스코프:       .../virtualNetworks/vnet-demo-dev-krc-main   ← RG가 아니라 VNet 리소스
할당 대상:         hub App Registration(entapp-demo-hub-krc-gha-01)의 SP
```

**불변식과의 양립**: 기존 불변식 (a)("CI 신원이 자기 워크로드 RG 밖에 role assignment
0건")를 **"허용 목록과 완전 일치"로 승격**한다. 허용 목록은 정확히 위 1건이다.
`verify.sh`가 (1) 건수가 정확히 1인지, (2) 역할 이름이 정확히 일치하는지, (3) 스코프가
정확히 그 VNet 리소스 ID인지를 검사한다. "0건"이 "1건 + 완전 일치"가 되는 것이지,
검증 가능성을 잃는 게 아니다. dev 쪽 `verify.sh`에도 대칭 검사를 추가한다(외부
principal이 자기 VNet에 갖는 할당이 그 1건뿐인가).

**Pros**: 원격 구독에 새는 권한이 액션 1개, 리소스 1개. hub가 스포크 연결의 단일
소유자라 "hub는 단일 고정 거처" 원칙과 일치. dev CI는 hub를 전혀 모른다.
**Cons**: dev VNet이 존재한 뒤에야 할당을 걸 수 있어 착수 순서가 5단계가 된다(4-3).
AWS 원본은 스포크가 attachment를 소유했으므로 소유권 방향이 반대다.

#### Option B: dev CI 신원이 연결을 소유한다 (AWS 원본과 같은 방향)

**Pros**: AWS 원본(`live/dev/networking`이 attachment 소유)과 소유 방향이 같다.
`live/hub/vwan`이 dev의 존재를 몰라도 되어 순서가 단순해진다.
**Cons**: dev CI에 hub의 `virtualHubs/hubVirtualNetworkConnections/write`와
`hubRouteTables/read`가 필요하다. 이건 **공유 컨트롤 플레인에 대한 쓰기**다. 탈취된
dev CI가 임의 VNet을 허브에 붙이거나 hub 자신의 연결을 지울 수 있다. 액션 1개짜리
Option A와 폭발 반경이 비교가 안 된다. AWS는 RAM이 "공유 대상을 계정 단위로 못박고
자동 수락"하는 별도 계층을 제공해 이 문제를 흡수했는데, **Azure에 RAM의 정확한
대응물은 없다**.

→ **Option A 권고.** 이전 설계가 "소유권을 hub 신원 쪽으로 몬다"고 방향만 잡아둔 것을,
이제 액션 1개 + 리소스 스코프라는 구체값으로 확정한다.

### 4-2. 모듈 vs raw 리소스 (Q2)

**`live/hub/vwan`은 raw `azurerm_*` 리소스로 만든다.** 독립적인 근거 3개가 같은 답을
가리키므로 사실상 이미 결정된 사안이다.

1. 이 repo의 헌장이 "모듈 자체는 만들지 않는다"이다. 모듈은 `iac-module-library` 소관.
2. AWS 원본도 TGW를 모듈화하지 않았다(`live/hub/tgw/main.tf`가 raw
   `aws_ec2_transit_gateway`·`aws_ram_*`·`aws_ec2_managed_prefix_list`).
3. 소비자가 1개다. vWAN 허브는 구독당 하나이고 재사용 압력이 없다. 모듈은 소비자가
   둘 이상일 때 값이 생긴다.

Option B(먼저 `iac-module-library`에 `vwan` 모듈을 만든다)는 **Pros**: 계약·테스트·문서가
`vnet`과 일관되고 이후 고객사 재사용이 쉽다. **Cons**: Phase 1이 크로스 repo 작업에
블록된다. 소비자 1개짜리 모듈을 먼저 만드는 것은 이 repo가 아니라 모듈 repo의
설계 원칙에도 어긋난다. → 기각. 나중에 `vwan` 모듈이 생기면 `moved`/import로 옮기는
문제이지 재설계가 아니다.

⚠️ 다만 **네이밍 약어 등재는 선행 과제다.** `vwan`·`vhub`는 `iac-module-library`의
`docs/naming/abbreviations/azure.md`에 아직 없다. `rg`·`st`·`entapp` 때와 같은 크로스
repo 작업이 한 번 더 필요하다.

### 4-3. 착수 순서와 dev 구독 bootstrap (Q3)

**dev 구독에도 별도 state Storage Account가 필요하다.** bootstrap 기대 상태 문서가
state Storage Account를 "대상별 1개"로 정의하고, state 데이터 커스텀 역할의 스코프도
대상별 컨테이너다. hub의 SA를 dev가 공유하면 dev CI 신원에 hub 구독 리소스에 대한
권한이 생겨 구독 분리가 무의미해진다.

순서(각 단계가 다음 단계 없이도 독립적으로 검증 가능하도록 잘랐다):

1. **dev 구독 bootstrap.** `BOOTSTRAP_TARGET=spoke SPOKE_ENV=dev
   EXPECTED_SUBSCRIPTION=af8171fb-... EXPECTED_TENANT=7d49e97a-... ./bootstrap.sh`.
   워크로드 RG·state RG·SA·App Registration·FIC 2종(`ref:refs/heads/main`,
   `environment:dev`)·커스텀 역할 2종·state RG 잠금이 생긴다.
   ⚠️ **2026-09-03 갱신**: 아래 4단계의 role assignment도 이제 이 단계에 포함된다
   (12절 참고) — 별도 스텝이 아니다.
   - `SA_PREFIX`는 `stdemodev`(9자)로 16자 제한 안이다. 검증 불필요.
   - `GH_ORG_REPO`가 같은 repo이므로 org/repo 불변 ID 조회는 hub와 동일하게 동작한다.
   - GitHub에 `dev` environment를 만들고 repo 변수를 심는다(아래 ⚠️ 참고).
2. **`live/hub/vwan` 1차 apply (스포크 연결 없음).** vWAN + vHub + hub VNet 연결까지만.
   hub 신원만으로, 전부 hub 워크로드 RG 안이라 **새 권한이 없다**. AWS 원본이 TGW를
   networking보다 먼저 별도 레이어로 세운 것과 같은 이유로, 스포크가 없어도 이
   단계가 독립적으로 완결된다.
3. **`live/dev/networking` apply.** `modules/azure/vnet` 재소비. dev 신원만 쓰고
   크로스 구독 요소가 전혀 없다. vWAN을 모른다.
4. **크로스 구독 role assignment(사람).** ~~4-1의 커스텀 역할 생성 + dev VNet 리소스
   스코프 할당. dev VNet이 3단계에서 생긴 뒤라야 스코프를 지정할 수 있다.~~
   ⚠️ **2026-09-03 갱신(12절)**: 스코프를 워크로드 RG로 완화해 1단계(`bootstrap.sh`)에
   통합했다 — VNet 존재 여부와 무관해져 별도 단계가 아니다. ⛔ CI가 하지 않는다는
   원칙은 그대로다 — role assignment 자동화는 이 설계 전체의 재검토 트리거다.
5. **`live/hub/vwan` 2차 apply.** `spoke_connections`에 dev를 추가해 dev 연결 생성.

**연결 리소스가 사는 곳**: 5단계의 연결은 `live/hub/vwan` state에 둔다(Option i).
대안(Option ii: 스포크별 별도 루트 `live/hub/vwan-spoke-dev`)은 스포크가 늘 때
vWAN 루트 전체를 재-plan하지 않아도 되는 장점이 있으나, state·워크플로가 스포크마다
하나씩 늘고 지금 스포크는 1개다. dev VNet ID는 data source로 조회하지 않고 CI 변수로
주입한다 (조회하려면 dev 구독 `virtualNetworks/read`가 추가로 필요한데, 그 한 액션을
아끼는 편이 낫다. 존재하지 않으면 `peer/action` 호출이 큰 소리로 실패한다).

⚠️ **repo 변수 이름 충돌**: 지금 hub 워크플로는 `vars.AZURE_CLIENT_ID`처럼 밋밋한
이름을 쓴다. 한 repo가 Azure 신원 2개를 다루게 되므로 `AZURE_HUB_CLIENT_ID` /
`AZURE_DEV_CLIENT_ID`로 분리해야 한다. GitHub environment 스코프 변수로는 풀 수 없다.
plan job이 의도적으로 `environment:`를 선언하지 않기 때문이다(FIC subject 패턴과의
대응 때문). **동작 중인 hub 워크플로를 건드리는 변경**이므로 별도 커밋으로 분리한다.

### 4-4. Pod 대역을 허브 라우팅에서 빼는 방법 (Q4)

**메커니즘 자체는 있다.** AWS TGW의 `default_route_table_propagation = "disable"` +
정적 라우트 조합에 정확히 대응하는 것이 vWAN에 있다.

- 연결 쪽: **"Propagate to none"**. `learn.microsoft.com/en-us/azure/virtual-wan/howto-connect-vnet-hub`
  가 연결 생성 옵션으로 명시한다("Changing the switch to Yes makes the configuration
  options for Propagate to Route Tables and Propagate to labels unavailable").
  허브마다 **None route table**이 따로 있다("Propagating to the None route table
  implies that no routes are required to be propagated from the connection").
- 허브 쪽: Default 라우팅 테이블에 정적 라우트를 얹는다. `azurerm_virtual_hub_route_table_route`
  로 `destinations_type = "CIDR"`, `next_hop = azurerm_virtual_hub_connection.<x>.id`.
  "Routes added statically take precedence over dynamically learned routes for the
  same prefixes."

**그런데 이 메커니즘이 떠받치려던 전제가 무너졌다.** 0절의 SNAT 인용이 결정적이다.
추가로 Microsoft는 같은 허브에 붙는 스포크 VNet 간 주소 중복을 지원하지 않는다고
문서화한다("Please ensure the updated address space does not overlap with the address
space for any existing spoke VNets in your Virtual WAN",
`learn.microsoft.com/en-us/azure/virtual-wan/virtual-wan-faq`).

#### Option A (권고): Pod 대역을 VNet마다 고유하게 준다

dev Pod 대역을 `100.65.0.0/16`으로 한다. 두 연결 모두 Default 라우팅 테이블에
associate + propagate 한다(vWAN 기본값). 정적 라우트도, None 라우팅 테이블도 쓰지
않는다.

**Pros**: hub ArgoCD Pod ↔ dev API 서버 왕복이 실제로 성립한다(이 아키텍처의 존재
이유). Azure가 문서로 요구하는 "스포크 간 비중복"을 지킨다. 배선이 단순해 vWAN의
BGP 기본 동작을 그대로 쓴다. RFC 6598 `100.64.0.0/10` 안이라 "싼 대역"이라는 성질과
온프레미스 비라우팅 성질은 그대로 유지된다.
**Cons**: AWS 원본의 "모든 스포크가 같은 dup 대역을 재사용한다"는 성질을 잃는다.
`100.64.0.0/10` 안에서 스포크당 `/16`씩 쓰면 스포크 64개까지다(이 레퍼런스 규모에서
제약이 아니다). 그리고 **AWS와 달리 Pod 대역이 허브를 건너 라우팅된다** 
(AWS에서는 절대 건너지 않았다). 노출면이 넓어지므로 NSG가 그 보상 통제가 된다.
`live/hub/networking/main.tf`의 `cidr_pod_dup` 주석과 `CLAUDE.md`의 Phase 2 절을
같은 커밋에서 정정해야 한다(리소스 변경은 없다, 주석뿐).

#### Option B: dev도 `100.64.0.0/16`을 쓰고 전파에서 뺀다

두 연결 모두 None 라우팅 테이블로 전파하고, Default 라우팅 테이블에 정적 라우트 2개
(`10.60.0.0/16` → hub 연결, `10.61.0.0/16` → dev 연결)만 둔다. AWS 원본과 도형이 같다.

**Pros**: AWS 원본과 1:1이다. Pod 대역이 허브를 절대 건너지 않아 노출면이 최소다.
**Cons**: ⛔ **Phase 2에서 hub ArgoCD가 dev 클러스터를 관리하지 못한다.** hub Pod가
보낸 패킷의 출발지가 `100.64.x.x`(SNAT 없음)인데 dev에게 그건 자기 로컬 대역이라
응답이 hub로 돌아오지 않는다. 이 증상은 클러스터 두 개가 다 선 Phase 2에서야 나타난다.
추가로 Azure가 스포크 간 주소 중복을 지원하지 않는다고 문서화하고 있어, 연결 생성
자체가 거부될지 여부도 미검증이다. 회피하려면 Overlay CNI로 되돌리거나(SNAT가
생기지만 Pod 단위 가시성을 잃어 이미 기각한 선택지다) `ip-masq-agent`를 수동 배선해야
하는데, 둘 다 확정된 결정을 뒤집는다.

→ **Option A 권고.** Option B의 Cons가 이 아키텍처의 목적 자체를 무효화한다.
None + 정적 라우트 패턴은 폐기하지 않고, "어떤 대역이 허브를 건너면 안 될 때 쓰는
도구"로 문서에 남긴다.

## 5. Implementation Steps

각 단계가 독립적으로 검증 가능한 단위이고, 순서는 4-3을 따른다.

1. **선행 정리(코드 변경 없음 + 주석 정정)**
   - ✅ `iac-module-library`의 `docs/naming/abbreviations/azure.md`에 `vwan`·`vhub` 등재
     완료(`main` 커밋 `5b30155`, 사용자가 이 계획 착수 전 별도로 처리).
   - `live/hub/networking/main.tf`의 `cidr_pod_dup` 주석과 `CLAUDE.md` Phase 2 절에서
     "스포크마다 Pod 대역 중복" 서술을 4-4의 결론으로 교체. 인용 URL 2개를 남긴다.
   - **수용 기준**: `tofu plan`이 `No changes`(주석만 고쳤으므로). 약어 표에 2종 추가.
2. **dev 구독 bootstrap + GitHub 배선**
   - `BOOTSTRAP_TARGET=spoke SPOKE_ENV=dev`로 `bootstrap.sh` → `verify.sh`.
   - GitHub `dev` environment 생성, repo 변수 분리(`AZURE_HUB_*` / `AZURE_DEV_*`,
     `DEV_TF_STATE_ACCOUNT`), hub 워크플로의 변수 이름 갱신을 **별도 커밋**으로.
   - **수용 기준**: `verify.sh`가 `exit 0`, 변경 0건. hub 워크플로가 이름 변경 후에도
     plan에 성공한다.
3. **`live/hub/vwan` 신설(스포크 연결 없이)**
   - `main.tf`(raw `azurerm_virtual_wan` type="Standard", `azurerm_virtual_hub`
     address_prefix `10.62.0.0/22`, `azurerm_virtual_hub_connection.hub`),
     `providers.tf`·`variables.tf`·`versions.tf`·`backend.tf`·`outputs.tf`는 
     `live/hub/networking`에서 그대로 가져온다(`require_oidc`/`ci_run` 가드,
     `resource_provider_registrations = "none"` 포함).
   - hub VNet ID는 `azurerm_virtual_network` data source로 조회한다(같은 구독·같은 RG라
     추가 권한이 없다).
   - `lifecycle { prevent_destroy = true }`를 vWAN·vHub에 건다(`vnet` 모듈의
     `deletion_protection`과 같은 의도).
   - `spoke_connections` 변수를 `map(string)`(스포크 이름 → VNet 리소스 ID), 기본 `{}`.
   - `.github/workflows/deploy-hub-vwan.yml`은 `deploy-hub-network.yml` 구조를 그대로
     복제하고 `TF_ROOT`·state key(`hub/vwan.tfstate`)·concurrency group만 바꾼다.
   - **수용 기준**: CI plan → dispatch apply → apply 후 재-plan이 `exit 0`.
     `az network vhub get-effective-routes`가 Default RT에서 `10.60.0.0/16`과
     `100.64.0.0/16`을 hub 연결 next hop으로 보여준다.
4. **`live/dev/networking` 신설**
   - `live/hub/networking/main.tf`를 착수 템플릿으로 복사해 `vnet_cidr = 10.61.0.0/16`,
     `cidr_pod_dup = 100.65.0.0/16`, subnet_cidrs를 `10.61.x`로 재배치.
   - ⚠️ `deletion_protection`은 dev도 `true`로 둘지 사용자에게 확인한다(hub는 true,
     AWS 원본의 dev는 false였다). 6절 Open Questions.
   - `.github/workflows/deploy-dev-network.yml`(`AZURE_DEV_*`, `environment: dev`,
     state RG `rg-demo-dev-krc-tfstate-01`, key `dev/networking.tfstate`).
   - **수용 기준**: CI apply 성공 + 재-plan 수렴. hub와 CIDR이 하나도 겹치지 않는다.
5. **크로스 구독 권한 + dev 연결**
   - ⚠️ **먼저 권한 주장 자체를 소규모로 실측한다.** 4-1의 `peer/action` 단일 액션이
     실제로 hub virtual network connection 생성을 성립시키는지는 공식 문서 인용
     하나에만 의존한 상태다(bootstrap 검증에서 문서와 실측이 어긋난 전례가 이미
     3건 있었다 — role definition 조회 지연, join 필드 null, `getenv()` 부재). 자동화에
     넣기 전에 커스텀 역할 생성 → 스코프 할당 → CI 없이 사람이 `az` CLI로 연결 1건을
     수동 시도해 성립 여부를 먼저 확인한다. 실패하면(예: 추가로
     `virtualNetworks/read`가 필요하다고 나오면) 4-1을 그 실측 결과로 갱신한 뒤에만
     다음 단계로 진행한다.
   - `bootstrap/`에 멱등 스크립트 추가(4-1의 커스텀 역할 생성 + VNet 리소스 스코프
     할당). `verify.sh` 양쪽에 허용 목록 완전 일치 검사 추가.
   - `live/hub/vwan`에 `spoke_connections = { dev = "<dev VNet ID>" }`를 CI 변수로 주입해
     2차 apply.
   - **수용 기준**: 6절 검증 단계 전체 통과.

## 6. Verification Steps

**unit**
- 두 루트에서 `tofu validate` + `tofu plan`. `variables.tf`에 CIDR 중복 금지
  `validation` 블록(vHub 대역이 hub/dev 어느 VNet 대역과도 겹치지 않는지).
- 네이밍 조합이 등재된 약어와 일치하는지 눈으로 대조.

**integration**
- 3단계 후: `az network vhub get-effective-routes --resource-type RouteTable
  --resource-id <defaultRouteTable>` 로 hub 연결 경로만 존재함을 확인.
- 5단계 후: 같은 명령으로 `10.61.0.0/16`·`100.65.0.0/16`이 dev 연결 next hop으로
  추가됐는지 확인. 겹치는 prefix가 하나도 없어야 한다.
- 연결 양쪽의 `routingState`가 `Provisioned`인지 확인.

**e2e**
- hub `vm` 서브넷과 dev `vm` 서브넷에 임시 VM을 하나씩 띄우고 양방향 TCP 도달 확인.
  Phase 2를 기다리지 않고 라우팅을 실증하는 가장 싼 방법이다.
- Network Watcher connection troubleshoot로 hub VM → dev VM 경로를 기록으로 남긴다.

**observability**
- 양쪽 `vm` 서브넷 NSG에 플로우 로그를 켜고, 위 e2e 트래픽의 **출발지 IP가 실제로
  기록되는지** 확인한다. Pod 단위 가시성이 flat CNI를 택한 이유이므로, 이 확인이
  없으면 그 근거가 검증되지 않은 채로 남는다.

**negative(이 설계의 핵심 방어선이 실제로 동작함을 증명한다)**
- dev VNet의 `peer/action` 할당을 RG 스코프로 넓힌 뒤 `verify.sh`가 `exit 1`을 내는지.
- 같은 할당을 built-in `Contributor`로 바꾼 뒤 `exit 1`을 내는지.
- 둘 다 되돌린 뒤 `exit 0`, 변경 0건으로 수렴하는지.
  (hub bootstrap 검증에서 이미 통과시킨 3-2 음성 테스트와 같은 형식이다.)

## 7. Pre-mortem (3 시나리오)

1. **vHub 주소 공간을 잘못 잡고 나중에 발견한다.** vHub 주소 공간은 생성 후 변경
   불가다. 고치려면 vHub를 파기해야 하고, 그러면 모든 연결과 라우팅이 함께 사라진다.
   Phase 2에서 Azure Firewall을 넣기로 하면 `/23`으로는 부족하다.
   **완화**: `/22`로 시작한다. plan 시점 `validation`으로 중복을 막는다.
2. **크로스 구독 권한이 조용히 넓어진다.** `LinkedAccessCheckFailed` 오류 메시지는
   **한 번에 누락 권한 하나만** 알려준다(공식 문서가 명시한다). 사람이 오류를 반복해
   맞다가 지쳐서 "일단 되게" dev 구독 스코프 `Contributor`로 올리기 쉽고, 크로스
   테넌트 문서가 정확히 그걸 안내한다. 그 순간 원칙 1이 무너지는데 아무 경보도 없다.
   **완화**: 필요한 액션 3개를 4-1에 미리 다 적어둔다(반복 시행착오 자체를 없앤다).
   `verify.sh` 허용 목록 검사를 5단계 완료 선언 **전에** 돌린다.
3. **Pod CIDR 결정을 늦게 뒤집는다.** dev를 `100.64.0.0/16`으로 먼저 배포하면 연결도
   성공하고 VM 간 통신도 정상이라 아무 증상이 없다. 깨지는 것은 Phase 2에서 hub
   ArgoCD가 dev API 서버를 잡을 때이고, 그때는 VNet address_space 변경이 파괴적이다.
   **완화**: 4-4를 `live/dev/networking` apply **전에** 사용자 승인으로 확정한다.
   그리고 기존 주석을 같은 커밋에서 정정한다. 낡은 근거가 문서에 남아 있으면 다음
   세션이 그걸 현재 결정으로 다시 읽는다.

## 8. Open Questions

`docs/decisions/open-questions.md`에도 함께 기록한다.

- 🔴 **dev Pod CIDR을 `100.65.0.0/16`으로 바꾸는 것에 동의하는가**(4-4 Option A).
  `live/dev/networking` 착수를 막는 유일한 결정 게이트다.
- dev VNet의 `deletion_protection`을 `true`로 둘 것인가. hub는 `true`, AWS 원본의
  dev는 `false`였다(파기가 잦은 환경이라).
- Azure Firewall을 vWAN 허브에 둘 것인가. **지금 답할 필요는 없지만**, vHub 주소
  공간을 `/22`로 잡을지가 여기 걸린다(사후 변경 불가).
- `azurerm_virtual_hub_connection`이 "Propagate to none"을 어떤 인자 형태로 표현하는지
  미확인. 4-4 Option A를 택하면 무관해진다.
- 같은 허브에 주소가 겹치는 VNet 연결이 **생성 단계에서 거부되는지** 미실측. 마찬가지로
  Option A를 택하면 무관해진다.
- `scripts/validate-doc-conventions.py` 이식 시점(아직 미이식, hub bootstrap 때부터
  밀려 있다).

## 9. ADR

- **Decision**: (1) `live/hub/vwan`을 raw `azurerm` 리소스로 신설하고 vHub 주소 공간을
  `10.62.0.0/22`로 잡는다. (2) hub CI 신원이 스포크 연결을 소유하고, dev 구독에는
  `Microsoft.Network/virtualNetworks/peer/action` 단일 액션 커스텀 역할을 dev VNet
  **리소스 스코프**로만 할당한다. ⚠️ **2026-09-03 갱신(12절)**: 스코프를 dev **워크로드
  RG**로 완화하고 `bootstrap.sh`에 통합했다 — 소유 방향·단일 액션 원칙은 유지, 스코프
  크기만 바뀌었다. (3) Pod 대역을 VNet마다 고유하게 준다
  (hub `100.64.0.0/16`, dev `100.65.0.0/16`), 두 연결 모두 Default 라우팅 테이블에
  associate + propagate 한다.
- **Drivers**: 폭발 반경(구독 분리를 무의미하게 만들지 않는다) · 되돌림 비용(vHub 주소
  공간과 VNet address_space는 사후 변경이 파괴적) · Phase 2 정합성(Azure CNI Pod
  Subnet은 SNAT를 하지 않는다).
- **Alternatives considered**: dev CI가 연결을 소유(hub 컨트롤 플레인 쓰기 권한 필요,
  기각) · `iac-module-library`에 `vwan` 모듈 선행 추가(소비자 1개, Phase 1 블록, 기각) ·
  dev도 `100.64.0.0/16`을 쓰고 None 라우팅 테이블 + 정적 라우트로 전파 제외(AWS와
  1:1이지만 hub ArgoCD → dev API 서버 왕복이 성립하지 않아 기각) · 스포크별 별도
  연결 루트(스포크 1개인 지금은 과잉, 보류).
- **Why chosen**: AWS 원본의 dup 대역 재사용은 VPC CNI의 노드 SNAT라는 **AWS 고유
  메커니즘 위에** 서 있었고, Azure CNI Pod Subnet에는 그 메커니즘이 없다. 원본의
  도형을 그대로 베끼면 Phase 2에서 조용히 깨진다. 크로스 구독 권한은 vWAN 공식
  roles-permissions 문서가 액션 단위로 답을 주므로, 크로스 테넌트 문서의 `Contributor`
  안내를 따를 이유가 없다.
- **Consequences**: AWS 원본과 Pod 대역 정책이 갈라진다(문서에 인용과 함께 명시해야
  하고, 고객사 복사본에도 그대로 전달된다). Pod 트래픽이 허브를 건너 라우팅되므로
  AWS 대비 노출면이 넓어지고 NSG가 보상 통제가 된다. 불변식 (a)가 "0건"에서 "허용
  목록 1건과 완전 일치"로 바뀐다. hub 워크플로의 repo 변수 이름이 바뀐다(동작 중인
  파이프라인 변경). 스포크가 늘 때마다 4-3의 4·5단계(사람 개입 role assignment)가
  반복된다.
- **Follow-ups**: `iac-module-library`에 `vwan`·`vhub` 약어 등재 · `verify.sh` 양쪽에
  크로스 구독 허용 목록 검사 추가 · `live/hub/networking/main.tf`와 `CLAUDE.md`의
  Pod 대역 서술 정정 · Phase 2에서 AKS가 `roleAssignments/write`를 요구하면 이 설계
  전체 재검토(기존 트리거 유지).

## 10. Architect/Critic 검토

세션 사용량 한도로 서브에이전트(Architect) 검증이 중단되어, 팀 리드가 같은 기준으로
직접 검토했다.

**Architect — 4-4(Pod CIDR 중복 불가) steelman 반론과 그 기각**: "UDR로 dev 쪽에서
hub 대역행 트래픽만 분기하면 되지 않나"를 검토했다. 성립하지 않는다 — 라우팅은
목적지 주소만으로 판단하는데, hub와 dev가 같은 `100.64.0.0/16`을 쓰면 그 대역으로
가는 패킷이 "내 로컬 Pod"인지 "hub 응답을 돌려줘야 할 상대"인지 주소만으로 구분할
방법이 없다. UDR은 목적지 prefix로 분기하는 도구라 이 모호성 자체를 풀 수 없다.
NAT 없이는 해법이 없고(Overlay 복귀 또는 `ip-masq-agent`), 둘 다 Phase 2에서 이미
기각한 "Pod 단위 가시성" 요구와 충돌한다. 따라서 4-4의 결론은 Azure 특이 동작이
아니라 overlapping CIDR과 양방향 라우팅이 근본적으로 양립 불가능하다는 일반 원리에서
나온 것이며, 대안이 없다.

**Architect — 잔여 리스크**: 4-1의 `peer/action` 단일 액션 주장은 공식 문서 인용
하나에만 근거한다. 세부 액션 단위 권한 문서가 실제 ARM 제어 평면과 어긋난 전례가
이 프로젝트에 이미 3건 있다(role definition 조회 지연, join 필드 null,
`getenv()` 부재 — 위 note 참고). → 5절 Implementation Steps 5단계에 **자동화 이전
소규모 실측** 단계를 추가했다.

**Critic 판정 — APPROVE(보강 반영)**: 원칙-옵션 일관성, 대안 탐색의 공정성, 리스크
완화 명확성, 검증 가능한 수용 기준 4개 기준 모두 통과. 보강 2건을 반영했다:
(1) 위 실측 단계 추가. (2) 아래 보안 트레이드오프를 ADR 각주가 아니라 **사용자가
직접 결정하는 게이트**로 승격.

🔴 **추가 결정 게이트 — Pod 트래픽의 구독 경계 노출**: 이 설계에서 Pod 트래픽은
vWAN 허브를 실제로 건넌다(AWS 원본은 TGW를 건넌 적이 없다 — TGW는 uniq 대역만
전파했다). 노출면이 넓어진 만큼 NSG가 유일한 보상 통제가 된다. `open-questions.md`의
🔴 항목(Pod CIDR 변경 동의)과 사실상 같은 결정이지만, "Pod 대역이 왜 다른가"뿐 아니라
"그 대역이 왜 이제 구독 경계를 넘는가"까지 사용자가 인지한 상태에서 승인해야 한다.

**사용자 승인 완료(2026-08-28)** — 아래 대안 검토 후 확정.

## 11. 대안 검토 기록 — 경계 통과 시점 SNAT (기각)

사용자가 승인 전 세 가지 대안을 제기해 순서대로 공식 문서로 검증했다. 전부 기각했고
근거를 남긴다(다음 세션이 같은 조사를 반복하지 않도록).

**11-1. Azure NAT Gateway로 경계 SNAT**: 기각. (1) 공식 문서가 명시:
"Azure NAT Gateway isn't supported in a secured virtual hub network (vWAN)
architecture"(`learn.microsoft.com/en-us/azure/nat-gateway/nat-gateway-resource`).
vWAN 아키텍처 자체에서 못 쓴다. (2) 설계 자체가 인터넷 아웃바운드 전용("the subnet's
default next hop type for all outbound traffic **directed to the internet**")이라
VNet 간 사설 트래픽에 원래 관여하지 않는다.

**11-2. Azure Firewall(Secured vHub) SNAT로 경계 SNAT**: 기각. Firewall의 private-range
SNAT 우회는 **목적지** 기준이지 출발지 기준이 아니다(`learn.microsoft.com/en-us/azure/
firewall/snat-private-range`). 우리 트래픽(hub Pod → dev API 서버)의 목적지는 dev의
RFC 1918 uniq 대역이라 기본 설정에서 이미 SNAT 우회 대상이라 문제가 그대로 남고,
RFC 1918을 우회 목록에서 빼서 강제로 SNAT 걸면 hub의 **모든** 사설 트래픽(문제
없던 VM 서브넷 간 통신 포함)까지 SNAT돼 flat CNI를 택한 이유 자체를 광범위하게
훼손한다. "Pod dup 대역에서 나가는 트래픽만" 스코프 지정은 지원하지 않는다(출발지
기준 정책 없음).

**11-3. ip-masq-agent(노드 레벨 스코프 SNAT, AWS VPC CNI 기본 동작과 동일 원리)**:
기각하되 근거가 중요하다. Overlay의 캡슐화 기반 가시성 손실과는 **메커니즘이 다르다**
(목적지 대역 선택적 SNAT일 뿐 캡슐화가 아니다) — 이 문서 0절·CLAUDE.md 이전 버전이
"ip-masq-agent도 Overlay와 같은 트레이드오프"라고 뭉뚱그린 것은 부정확했다. 실제
기각 사유는 다르다: Azure CNI Pod Subnet(dynamic IP allocation)은 이 훅 자체가
데이터플레인에 없다. 공식 문서 원문(`concepts-network-legacy-cni` "Azure CNI Pod
Subnet frequently asked questions"):

> "But for Azure CNI dynamic IP allocation, no matter the connection is inside the
> same virtual network or cross virtual networks, the pod IP is always the source
> address for any traffic from the pod. ... Hence, it eliminates the use of
> `ip-masq-agent`, which is still used by traditional Azure CNI."

ip-masq-agent를 쓰려면 traditional Azure CNI(Node Subnet, 구식 모드)로 돌아가야
하는데, 이는 Pod Subnet을 택한 이유(Node Subnet은 노드·Pod가 같은 서브넷을 쓰고
노드당 최대 Pod 수만큼 IP를 사전 예약해 IP 고갈이 잦다)를 재도입하는 것이라 기각.
AWS VPC CNI는 어느 모드든 이 SNAT 스위치(`AWS_VPC_K8S_CNI_EXTERNALSNAT`)를 계속
갖고 있는 반면, Azure Pod Subnet 모드는 "Pod IP를 항상 보존"이 모드 정의 자체라
설계상 그 훅을 제거했다 — AWS와 Azure의 진짜 플랫폼 차이다.

**유일하게 남는 경계 SNAT 경로**: 자체 NVA(iptables MASQUERADE, source-CIDR
스코프, VM/VMSS + HA 이중화 필요) — 기술적으로는 가능하나 새 컴포넌트 운영 부담이
크고, RFC 6598 공간이 스포크 64개(`/16`씩)까지 여유가 있어(3절) 지금 주소 절약이
필요한 상황도 아니라 채택하지 않는다. 미래에 실제로 필요해지면 재검토.

## 12. 추가 기록(2026-09-03) — 4-1 스코프를 VNet 리소스에서 워크로드 RG로 완화

5절 5단계(크로스 구독 role assignment)를 실제로 구현하는 세션에서 사용자가 질문했다:
"bootstrap.sh를 만들 때 SP가 애초에 이 권한을 갖게 할 수는 없나? AWS는 스포크가 추가될
때 뭘 해야 하나? 지금 구조는 스포크가 늘 때마다 스크립트를 실행해야 하는 건가?"

**AWS 원본과의 근본적 차이를 재확인했다.** AWS는 RAM(Resource Access Manager)으로 hub가
TGW를 계정/OU 단위로 한 번 공유하면, 스포크는 **자기 계정의 이미 가진 전권**으로
attachment를 직접 만든다 — hub 계정에 새 IAM 권한이 전혀 필요 없고, OU 단위로 공유해두면
이후 스포크는 완전히 자동으로 상속받는다. Azure vWAN에는 이 RAM의 정확한 대응물이 없다
(4-1 Option B 기각 사유와 같은 근거) — 그래서 이 설계는 hub가 연결을 소유하는 반대
방향(Option A)을 유지하고, "스포크가 늘 때마다 사람이 한 번 개입한다"는 비용(9절
Consequences에 이미 명시)은 없어지지 않는다.

**다만 "몇 번 개입하는가"는 줄일 수 있었다.** 최초안(Option A)은 `peer/action` 할당
스코프를 **VNet 리소스 하나**로 좁혔는데, `bootstrap.sh`는 항상 `live/*/networking`의
VNet apply보다 먼저 실행되므로 그 시점엔 VNet이 존재하지 않는다(닭과 달걀) — 그래서
`cross-subscription-peer.sh`라는 **별도** 스크립트를 5단계(VNet 생성 후)에 한 번 더
실행해야 했다. 사용자가 이 절충을 제안했고 확인 결과 실제로 성립했다: 스코프를 스포크
**워크로드 RG**(bootstrap.sh 1단계가 이미 만드는 리소스)로 완화하면, `peer/action`
할당을 `bootstrap.sh` 자신의 6-1절로 통합할 수 있다 — 스포크 부트스트랩 1회 실행만으로
끝난다. 대가는 hub SP가 그 RG에 나중에 생길 다른 리소스(예: Phase 2 AKS 노드 관련
리소스)에도 `peer/action`을 자동으로 갖게 된다는 것이다. `peer/action`은 단일 액션(VNet
피어링 연결 생성만 가능, 다른 어떤 것도 못 한다)이라 위험도가 낮다고 판단해 사용자가
이 완화를 승인했다.

**바뀐 것**: assignable scope/할당 스코프가 VNet 리소스 ID(`.../virtualNetworks/vnet-...`)
에서 워크로드 RG(`.../resourceGroups/rg-...-workload-01`)로 바뀌었다. 별도 스크립트
`cross-subscription-peer.sh`는 만들었다가 이 세션에서 바로 폐기했다(git에 커밋되지
않았다). 실제 구현은 `bootstrap.sh` "6-1. 크로스 구독 스포크 연결 권한" 절,
`config.sh`의 `HUB_APP_NAME`/`SPOKE_PEER_ROLE_NAME`/`spoke_peer_role_definition_json`,
`verify.sh`의 "불변식 (a) 예외" 절(가드를 `ENV_TOKEN == "dev"`가 아니라
`BOOTSTRAP_TARGET == "spoke"`로 일반화 — 다음 스포크에도 자동 적용). dev 대상으로
음성 테스트(RG 스코프 assignment를 Contributor로 치환 → verify.sh DRIFT 확인 →
원복 → bootstrap.sh로 재수렴 → drift 없음)까지 통과했다. `bootstrap/README.md`
"크로스 구독 연결" 절이 이 확정 상태를 반영한다(이전 "미확정" 문구 대체).

**바뀌지 않은 것**: 4-1의 핵심 판단(hub가 연결을 소유, Option A) 자체, 단일 액션
`peer/action`이라는 권한 선택, "CI가 이 role assignment를 자동화하지 않는다 — 사람이
`bootstrap.sh`를 실행할 때만 생긴다"는 원칙, `verify.sh`의 "허용 목록 완전 일치" 검증
방식.

## 13. 추가 기록(2026-09-03) — Overlay CNI 채택으로 Pod CIDR 유일성 전제 무효화

`iac-module-library`의 `aks-cluster` 모듈이 v0.3.0에서 `cni_mode` 기본값을 Azure CNI
**Overlay**로 정정했다(근거: Microsoft 공식 문서 `plan-pod-networking`의 일반 권고,
AKS baseline 참조 아키텍처). Overlay는 Pod IP를 VNet 밖 오버레이 CIDR에서 받으므로
Pod가 VNet 주소 공간에 전혀 속하지 않는다 — 이 문서 3절·4절(특히 4-4)·9절 ADR·11절이
전제한 "Azure CNI Pod Subnet(flat, SNAT 없음)이라 Pod IP가 VNet/vWAN을 통해 실제로
라우팅된다"는 사실 자체가 더 이상 성립하지 않는다.

**이 문서에서 무효화되는 부분** (원문은 보존, 여기서 지적만 한다):
- 3절 CIDR 배치: hub `100.64.0.0/16`·dev `100.65.0.0/16`(구 `cidr_pod_dup`)를
  "스포크마다 고유해야 한다"고 결정한 근거 — 이제 이 두 대역 자체가 존재하지 않는다
  (`live/hub/networking/main.tf`·`live/dev/networking/main.tf`에서 제거,
  2026-09-03 같은 커밋).
- 4-4: "Azure CNI Pod Subnet은 크로스 VNet 트래픽에도 SNAT하지 않는다 → 중복 CIDR이면
  양방향 라우팅이 성립 불가" 라는 핵심 논거 — Overlay는 애초에 Pod 트래픽을 VNet/vWAN
  라우팅 테이블에 노출하지 않고 클러스터 밖으로 나갈 때 노드 IP로 SNAT하므로, 이
  논거가 다루던 문제 자체가 사라진다.
- 9절 ADR의 Consequences 일부("Pod 트래픽이 vWAN 허브를 건너므로 노출면이 넓어지고
  NSG가 유일한 보상 통제") — Overlay에서는 Pod 트래픽이 노드 IP로 대체돼 vWAN을
  건너므로, "Pod 단위" 노출이라는 표현 자체가 더 이상 정확하지 않다(노드 단위 노출로
  치환된다 — 이건 hub·dev VNet 간 통상적인 노드-대-노드 트래픽과 같은 성격이라 새로운
  위험이 아니다).
- 11절(경계 통과 시점 SNAT 대안 기각)의 기각 사유 일부 — Pod Subnet 고유 성질을
  전제로 한 비교였으므로, Overlay 채택 이후 이 대안 비교는 더 이상 유효한 대조군이
  아니다(Overlay 자체가 SNAT 기반이라 원래 기각했던 대안과 메커니즘이 수렴한다).

**바뀌지 않는 것**: 12절이 다루는 크로스 구독 vWAN **연결**(`peer/action`, hub가
연결 소유) 설계는 VNet 피어링 권한에 관한 것이라 CNI 모드와 무관하다 — 그대로
유효하다. hub·dev VNet 자체의 CIDR(`10.60.0.0/16`·`10.61.0.0/16`)과 vWAN 허브 CIDR
(`10.62.0.0/22`)도 변경 없다.

**후속**: Pod 네트워킹의 새 설계 근거는 `live/hub/networking/main.tf`·
`live/dev/networking/main.tf`의 해당 locals 주석이 실물 SSOT를 넘겨받는다(이 문서를
더 갱신하지 않는다, CLAUDE.md 3절 원칙). `live/hub/aks` 배포 계획(`docs/decisions/
live-hub-aks.md`)이 이 정정을 반영해 재작성된다.
