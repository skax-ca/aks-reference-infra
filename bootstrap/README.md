# bootstrap: 부트스트랩 (IaC 밖)

**읽는 사람**: 부트스트랩 스크립트를 처음 실행하거나 고치는 사람.

state Storage Account, App Registration, 커스텀 RBAC 역할 2종, 리소스 잠금, 그리고 AKS
클러스터용 user-assigned identity를 Azure CLI 스크립트로 만든다. `tofu`가 이것들을 만들려면 이미 state 저장소가 있어야 하는 닭과 달걀
문제가 있어서, 이 한 겹만 IaC 밖에 둔다(원본 `eks-reference-infra`와 동일한 이유).

설계 근거는 `.omc/plans/bootstrap-credential-design.md`(v6, ralplan 5라운드 확정)다. AWS
원본의 "입구 Role → 실행 Role" 2단 체인을 Azure Entra ID에 그대로 재현할 수 없어, 대신
"CI 신원의 권한을 리소스 그룹 하나로 좁히고, 6가지 불변식으로 검증"하는 방식으로
대체했다. 이 대체가 원본과 완전히 동등하지는 않다. 그 한계는 아래 2절과 4절에
명시한다.

## 1. 실행

```bash
export EXPECTED_SUBSCRIPTION=<GUID>   # 필수. 기본값이 없다
export EXPECTED_TENANT=<GUID>         # 필수. 기본값이 없다

cd bootstrap
./bootstrap.sh      # 생성·수렴 (BOOTSTRAP_TARGET 기본 hub)
./verify.sh         # drift 확인만 (읽기 전용). exit 0=일치 / 1=drift / 2=실행 불가
```

spoke(dev) 인스턴스는 대상과 환경 토큰을 명시한다.

```bash
BOOTSTRAP_TARGET=spoke SPOKE_ENV=dev \
  EXPECTED_SUBSCRIPTION=<dev 구독 GUID> EXPECTED_TENANT=<GUID> ./bootstrap.sh

BOOTSTRAP_TARGET=spoke SPOKE_ENV=dev \
  EXPECTED_SUBSCRIPTION=<dev 구독 GUID> EXPECTED_TENANT=<GUID> ./verify.sh
```

⛔ **`EXPECTED_SUBSCRIPTION`·`EXPECTED_TENANT`에 기본값을 두지 않는다.** 구독/테넌트
ID는 git에 남기지 않는다. 값은 Azure 구독 관리자에게 확인한다. 미설정이면 스크립트가
즉시 중단한다(`exit 2`, drift가 아니라 실행 불가로 분류된다).

⚠️ **대상 구독은 실행마다 명시한다.** hub와 spoke(dev)는 서로 다른 구독이다(설계
계획 문서에서 hub/dev 별도 구독으로 확정). 스크립트가 `az account show`로 실제 구독·테넌트와
`EXPECTED_SUBSCRIPTION`/`EXPECTED_TENANT`를 대조하고 다르면 즉시 중단한다. 공용
테넌트에서 조용히 다른 구독을 건드리지 않게 하는 장치다. App Registration·FIC·Entra
역할은 테넌트 스코프 객체라 구독 대조만으로는 부족해 테넌트도 함께 대조한다.

⚠️ 스크립트는 bash 전용이다. zsh에서 `source`하지 않는다.

⚠️ `az login`으로 먼저 인증되어 있어야 한다. `bootstrap.sh`를 실행하는 사람은 해당
구독의 **Owner 또는 User Access Administrator**여야 한다. 커스텀 역할 정의의
생성·수정은 `AssignableScopes`의 모든 스코프에서 `Microsoft.Authorization/
roleDefinitions/write`를 요구한다.

## 2. 기대 상태

`config.sh`가 코드 측면이고 이 표가 문서 측면이다. **둘이 어긋나면 이 표를 고친다.**
사람이 읽는 쪽을 SSOT로 둔 이유는, 코드 주석만으로는 "지금 실제로 뭐가 만들어져
있어야 하는가"를 한눈에 확인하기 어렵기 때문이다.

hub는 구독 하나의 단일 고정 거처이고, spoke는 별도 구독에 놓이는 여러 인스턴스다.
첫 spoke 인스턴스의 환경 토큰은 `dev`다.

### 리소스 그룹 (대상별 2개: 워크로드용·state용)

| 항목 | 값 |
|------|-----|
| 워크로드 RG | `rg-<workload>-<env>-krc-workload-01` (사람이 선생성, CI는 관여하지 않는다) |
| state RG | `rg-<workload>-<env>-krc-tfstate-01` (CI 신원의 RBAC 스코프 밖) |

`rg` 약어는 `iac-module-library`의 `docs/naming/abbreviations/azure.md`에 등재됐다
(2026-08-27, 실제 Azure 검증 세션 — CAF 표에서 그대로 채택). 등재 전에는 `rg-todo-...`
placeholder를 썼었다.

### state Storage Account (대상별 1개)

| 항목 | 값 |
|------|-----|
| 이름 | `st<workload><env><8자리 hex>`(3~24자, 소문자+숫자만, 하이픈 불가, Azure 물리 제약. `st` 약어는 CAF 표에서 그대로 채택, 2026-08-27 등재) |
| 이름의 소재 | git에 없다. GitHub repo 변수 또는 로컬 `backend.hcl`(gitignore됨) |
| 인증 | `use_azuread_auth = true`. `allowSharedKeyAccess = false` 강제(계정 키로 RBAC 우회 차단) |
| 내구성 | blob 버전 관리 + blob soft delete(30일) + **컨테이너 소프트 삭제**(30일, blob soft delete와 별개 기능이라 반드시 함께 켠다) |
| 컨테이너 | `tfstate` 1개. **동일 이름으로 재사용 금지**(소프트 삭제된 컨테이너와 같은 이름으로 새로 만들면 그 소프트 삭제분은 영구 복구 불가) |

### 커스텀 RBAC 역할 2종

원본의 "입구 Role → 실행 Role" 2단 체인 대신, CI 신원(App Registration) 하나에 아래
역할 2종만 부여한다. **built-in `Contributor`를 그대로 쓰지 않는다.**

| 역할 | 스코프 | 정의 방식 |
|------|--------|-----------|
| 워크로드 CI 역할 | 워크로드 RG | `Actions:["*"]`, `NotActions` = **매 실행 런타임 조회**한 built-in Contributor의 notActions + `resourceGroups/delete` 추가 |
| state 데이터 역할 | state 컨테이너 | Storage Blob Data Contributor에서 `containers/delete`만 제외한 **고정 델타**(실측 확정값, 하드코딩 유지) |

⚠️ **워크로드 역할의 `notActions`를 문서·코드에 하드코딩하지 않는다.** 이전 설계
반복에서 이 목록을 두 번 연속 손으로 옮겨 적다 틀렸다(built-in 정의와 불일치, 결과적으로
Contributor보다 넓은 권한이 됨). `bootstrap.sh`/`verify.sh`가 `az role definition list
--name Contributor`로 그 시점의 실제 값을 조회해 쓴다. Azure가 Contributor 정의를
바꿔도 다음 실행이 자동으로 따라간다.

⚠️ **컨테이너 스코프 역할 할당 자체의 가능 여부는 미실측이다.** state 데이터
역할의 권한 델타(Actions 3개, DataActions 5개) 값 자체는 실측 확정값이지만,
`DataActions`를 가진 커스텀 역할을 Storage 컨테이너(하위 리소스) 스코프에
실제로 **할당**할 수 있는지는 Azure 공식 문서에서 명시적으로 확인하지 못했다.
불가능하다고 밝혀지면 이 역할의 스코프를 Storage Account 전체로 넓혀야 하며,
그 경우 hub/dev 컨테이너 분리에 의존하던 격리 수단도 재검토 대상이 된다.
실행 승인 전에 이 가능 여부를 먼저 실측할 것을 권한다.

⚠️ `NotActions`는 deny 규칙이 아니다. 이 두 역할의 안전성은 전적으로 아래 "권한
불변식"이 항상 참이라는 것에 의존한다. 그 불변식이 깨지면 두 역할의 모든 제외가
동시에 무의미해진다.

### 리소스 잠금

| 대상 | 잠금 | 이유 |
|------|------|------|
| state RG | `CannotDelete` | control-plane 삭제 사고 방지. **워크로드 RG에는 걸지 않는다**(Azure 잠금은 상속되어, 걸면 그 RG 안의 모든 리소스 교체(destroy → create)가 막혀 무인 자동화가 파괴된다) |
| 워크로드 RG 자기 삭제 방지 | 잠금 아님 | 위 커스텀 역할의 `NotActions`에 `resourceGroups/delete`를 넣어 역할 정의로 해결한다 |

⚠️ **잠금은 tfstate 데이터를 보호하지 않는다.** `CannotDelete`는 control-plane(리소스
그룹·계정 자체의 삭제)만 막고 blob 데이터(data-plane)는 보호하지 않는다. tfstate를
실제로 보호하는 것은 state 데이터 역할이 `containers/delete`(컨테이너 자체 삭제,
control-plane)와 `blobs/permanentDelete/action`(원래 이 역할에 없음)을 갖지 않는다는
사실과, 위 내구성 설정(soft delete + versioning)이다.

⚠️ state RG에 잠금이 걸려 있으면 **사람 관리자도 예외 없이** 그 RG 안의 role
assignment를 다시 만들 수 없다(`CannotDelete`가 RBAC 할당 삭제까지 막는다). 정당한
변경이 필요하면: (1) 사람이 잠금 해제 → (2) `bootstrap.sh` 재실행으로 수렴 → (3) 잠금
재적용. 자동화하지 않는다. 진짜 사고와 정상 변경을 자동으로 구분할 수 없다.

### GitHub OIDC (Federated Identity Credential)

| 항목 | 값 |
|------|-----|
| issuer | `https://token.actions.githubusercontent.com` |
| audience | `api://AzureADTokenExchange` |
| subject 패턴 | `repo:<org>@<org_id>/<repo>@<repo_id>:ref:refs/heads/main`, `repo:<org>@<org_id>/<repo>@<repo_id>:environment:<env>` |
| 배포 승인 방식 | **배포 브랜치 정책만**(사용자 확정, 필수 리뷰어 없음, 무인 자동화 유지) |

`<org>/<repo>`는 `skax-ca/aks-reference-infra`로 확정됐다(2026-08-27, GitHub repo 생성 후
`GH_ORG_REPO` 기본값을 갱신, `bootstrap/config.sh` 참고).

🔴 **`<org>@<org_id>/<repo>@<repo_id>` 형식이다. 이름만 쓴 subject는 인증에 실패한다.**
이 조직/계정에서는 GitHub가 org·repo 이름 뒤에 불변 숫자 ID를 붙여 OIDC `sub` 클레임을
발급한다(2026-08-27 hub CI 최초 실행에서 `AADSTS700213: No matching federated identity
record found`로 실측 확인). `config.sh`가 `gh api`로 실제 ID를 조회해 자동으로 조합하므로
사람이 직접 계산할 필요는 없다.

⛔ 와일드카드를 쓰지 않는다. Entra ID의 Federated Identity Credential은 애초에
와일드카드를 지원하지 않는다(생성 자체가 거부된다). 실제 위험은 문법적으로 유효하지만
잘못된 subject(다른 repo, `pull_request:` 트리거 등)나 issuer/audience 오설정이며,
이는 **오류 없이 생성**되고 토큰 교환 시점에야 실패한다. `verify.sh`가 subject·issuer·
audience 전 필드 완전 일치를 검사해 이를 잡는다.

⛔ App Registration/Service Principal에 정적 자격증명(client secret·certificate)을
절대 만들지 않는다. GitHub OIDC(FIC)만이 유일한 인증 경로다.

### 크로스 구독 연결 (확정, 2026-09-03)

hub CI 신원이 스포크 구독의 VNet을 hub Virtual WAN 허브에 연결(`live/hub/vwan`의
`azurerm_virtual_hub_connection.spoke`)하려면, 연결 리소스 자체는 hub 구독에 생기더라도
ARM이 원격(스포크) VNet에 대한 `Microsoft.Network/virtualNetworks/peer/action` 권한을
호출자(hub SP)에게 요구한다(`learn.microsoft.com/en-us/azure/virtual-wan/roles-permissions`
"Example 1"). 이 권한은 스포크 구독 안에서 hub SP에게 부여해야 하는 유일한 예외다.

| 항목 | 값 |
|------|-----|
| 역할 | `aks-ref-bootstrap-spoke-peer-<env>` — `peer/action` 단일 액션만 |
| assignable scope / 할당 스코프 | 스포크 **워크로드 RG**(`rg-<workload>-<env>-krc-workload-01`) |
| 할당 대상 | hub App Registration(`entapp-<workload>-hub-krc-gha-01`)의 SP |
| 실행 주체 | `bootstrap.sh`가 `BOOTSTRAP_TARGET=spoke`일 때만 자동 포함(「크로스 구독 스포크 연결 권한」절) — CI가 아니라 `bootstrap.sh`를 실행하는 사람이 만든다 |

⚠️ **스코프는 특정 VNet 리소스가 아니라 워크로드 RG 전체다.** `bootstrap.sh`는 항상
`live/*/networking`의 VNet apply보다 먼저 실행되므로, 그 시점엔 VNet이 아직 없어 리소스
단위로 좁힐 수 없다(닭과 달걀 문제). VNet 리소스 단위로 좁히는 대안도 검토했으나
(`.omc/plans/live-hub-vwan-dev-networking.md` 4-1 최초안), 그러면 스포크마다 별도
스크립트를 한 번 더 실행해야 해 `bootstrap.sh` 1회로 끝나지 않는다. `peer/action`은
단일 액션이라 위험도가 낮으므로, RG 스코프로 완화하고 `bootstrap.sh`에 통합하는 쪽을
택했다(2026-09-03, 사용자 결정). 대가는 hub SP가 이 RG에 나중에 생길 다른 리소스에도
`peer/action`을 갖는다는 것이다.

⚠️ **`Contributor` 안내는 이 시나리오의 근거가 아니다.** 검색에서 자주 나오는 "원격 VNet
구독의 Contributor가 필요하다"는 문장은 크로스 **테넌트** 문서의 것이다. 이 설계는 동일
테넌트의 크로스 **구독**이고, 위 roles-permissions 문서가 액션 단위로 정확히 답한다.

⚠️ **AWS 원본과 소유 방향이 다르다.** AWS(`eks-reference-infra`)는 AWS RAM으로 hub가 TGW를
계정/OU 단위로 공유하면 스포크가 자기 계정의 전권으로 attachment를 직접 만든다 — hub 계정에
새 IAM 권한이 필요 없다. Azure vWAN에는 RAM의 정확한 대응물이 없다. 반대 방향(스포크 CI가
연결을 소유)을 택하면 스포크 CI가 hub의 공유 컨트롤 플레인 쓰기 권한
(`hubVirtualNetworkConnections/write`)을 가져야 해 `peer/action` 하나보다 훨씬 위험하다 —
그래서 이 설계는 hub가 연결을 소유하는 방향을 유지한다. 대가로 **새 스포크를 추가할
때마다 `bootstrap.sh`(스포크 대상)를 한 번 더 실행해야 한다** — 자동으로 상속되지 않는다.

⛔ `verify.sh`는 스포크 워크로드 RG 스코프에서 "이 대상 자신의 SP를 제외한" role
assignment가 정확히 이 1건(hub SP + `spoke-peer` 역할)과 완전히 일치하는지 검사한다
(`BOOTSTRAP_TARGET=spoke`일 때만). 설계 근거 전문은
`.omc/plans/live-hub-vwan-dev-networking.md` 4-1, 2026-09-03 추가 기록 참고.

### AKS 클러스터용 identity·권한 (hub 대상만, 확정 2026-09-03)

`live/hub/aks`가 소비하는 `aks-cluster` 모듈은 identity도 role assignment도 스스로
만들지 않고 **입력으로만 받는다**. 그리고 CI 신원에는
`Microsoft.Authorization/roleAssignments/write`를 주지 않는다(위 「커스텀 RBAC 역할
2종」절의 원칙). 두 제약이 겹쳐 이 산출물들은 구조적으로 부트스트랩 계층에서만 만들 수
있다. 설계 근거 전문은 `.omc/plans/live-hub-aks.md`의 「identity·role assignment
(bootstrap 확장)」절 참고.

| 항목 | 값 |
|------|-----|
| user-assigned identity | `id-<workload>-hub-krc-aks-01` |
| identity의 거처 | **워크로드 RG**(`rg-<workload>-hub-krc-workload-01`) |
| role assignment | built-in `Network Contributor` |
| role assignment 스코프 | `aks-node` 서브넷 리소스 하나(`snet-<workload>-hub-krc-aks-node`) |
| 할당 대상 | 위 identity의 principal |
| 리소스 프로바이더 | `Microsoft.ContainerService`가 `Registered` |

⚠️ **identity를 워크로드 RG에 두는 것은 선택이 아니라 제약이다.** CI 커스텀 역할의
스코프가 그 RG 하나뿐이라, identity가 그 밖에 있으면 `live/hub/aks` apply가
`Microsoft.ManagedIdentity/userAssignedIdentities/assign/action` 권한 부족으로 실패한다.

⚠️ **role assignment 단계만 조건부다.** 스코프가 서브넷 리소스 하나라, 그 서브넷을
만드는 `live/hub/networking` apply보다 `bootstrap.sh`가 먼저 실행되는 상황이 성립한다
(위 「크로스 구독 연결」절의 `peer/action`이 RG 스코프로 완화됐던 것과 같은 닭과 달걀
문제). 그래서 서브넷이 없으면 **이 단계만** 경고 후 건너뛰고 나머지는 정상 진행하며,
서브넷이 생긴 뒤 재실행하면 수렴한다. `peer/action`처럼 스코프를 RG로 완화하지 않은
이유는 위험도 차이다(액션 1개 대 대상 1개). hub는 `aks-node` 서브넷이 이미 배포돼 있어
실제로는 이 분기를 타지 않지만, 다음 스포크를 위해 지금 만들어 둔다.

⚠️ **`verify.sh`의 이 절 검사는 위 권한 불변식과 범주가 다르다.** 불변식들은 CI 신원의
권한이 0건 또는 허용 목록과 완전히 일치하는지 보는 음성 검사인데, 여기 검사는 CI 신원이
아닌 다른 principal에 대한 **양성 존재 확인**이다. 서브넷 부재로 판정할 수 없을 때는
`warn`으로 보고하고 drift로 세지 않는다(`exit 0` 유지). 조회 자체가 실패하는 경우는
여전히 `exit 2`다.

⛔ **identity 존재 확인만으로는 부족해 role assignment 존재까지 검사한다.** identity는
있는데 서브넷 권한이 없으면 `live/hub/aks` apply는 성공으로 끝나고 노드만 조용히 join에
실패한다. 그 죽은 경로를 잡는 것이 이 검사의 목적이다.

⚠️ **`Microsoft.ContainerService` 등록을 사람이 미리 처리하는 이유**: CI 신원은 구독
스코프 `*/register/action`을 갖지 않는다(워크로드 커스텀 역할의 스코프가 RG 하나뿐이다).
미등록 상태로 apply가 시작되면 CI가 스스로 복구할 수 없는 실패로 막힌다. 등록은
비동기라 `bootstrap.sh`는 `--wait`로 완료까지 기다린다(그래야 재실행이 변경 0건으로
수렴한다). 2026-09-03 hub 구독 실측 기준 이미 `Registered`라, 이 단계는 사실상 멱등
안전망이다.

## 3. 검증

### 3-1. 멱등성

재실행하면 이미 있는 항목은 전부 `ok`로 표시되고 `=== 변경 0건 ===`이 출력되어야
한다. 아무것도 없는 처음 상태에서 실행하면 `verify.sh`가 `exit 1`을 내야 한다.

⚠️ `verify.sh`는 App Registration이 없으면 그 지점에서 즉시 `exit 1`로 끝난다
(RG·Storage 등 이후 항목은 App Registration 존재를 전제로 하는 조회라 App
Registration이 없으면 검사 자체가 무의미하기 때문 — 실측 확인, 2026-08-27). "모든
항목이 개별적으로 absent로 보고된다"는 뜻이 아니다. drift 1건 보고 + exit 1이면
수용 기준을 충족한 것이다.

### 3-2. 음성 테스트: verify.sh가 실제로 drift를 잡는지 증명한다

drift 감지가 있다고 주장하려면 그것이 동작하는 것을 직접 보여야 한다. 서로 다른 코드
경로 2개에 고의로 drift를 주입한 뒤 `exit 1`이 나오는지 확인하지 않으면 "완화책이
있다"는 착각만 남는다.

```bash
source ./config.sh   # ⚠️ bash로 실행할 것

# drift 주입: 서로 다른 코드 경로 2개 (FIC, Storage)
az ad app federated-credential update --id "$APP_ID" \
  --federated-credential-id <fic-id> \
  --parameters '{"name":"'"$FIC_NAME_MAIN"'","issuer":"https://wrong-issuer.example","subject":"'"$SUB_MAIN"'","audiences":["api://AzureADTokenExchange"]}'
az storage account blob-service-properties update \
  --account-name "$SA_NAME" --resource-group "$STATE_RG_NAME" --enable-versioning false

./verify.sh     # → DRIFT 2건, exit 1이어야 한다
./bootstrap.sh  # → 변경 2건만 (나머지는 ok). state RG가 이미 잠겨 있다면 먼저
                #    수동으로 잠금을 해제한 뒤 실행하고, 완료 후 잠금을 재적용한다
./verify.sh     # → drift 없음, exit 0
./bootstrap.sh  # → 변경 0건
```

이 순서대로 결과가 나오면 `verify.sh`는 소음이 아니라 실제 탐지기임이 증명된 것이다.

✅ **hub 대상으로 실제 Azure에서 3-1·3-2 전 과정을 실행해 확인했다(2026-08-27, 정식
네이밍 약어 등재 후 리소스 재생성까지 마친 최종 상태 기준).** 위 순서 그대로 DRIFT
2건 → 변경 2건 → drift 없음 → 변경 0건이 재현됐다. 이 과정에서 버그 3건(역할 정의
생성 직후·역할 정의 재조회·role assignment 조회의 ARM 캐시/조인 지연 미대응)을
발견해 고쳤고, 불변식 (b)(관리 그룹 스코프)를 제거했다 — 상세 경위는
`.omc/plans/bootstrap-credential-design.md`의 2026-08-27 추가 기록 참고. dev(spoke)
인스턴스는 별도 구독이 필요해 이번에는 검증하지 않았다.

### 검증 실행 권한의 한계

⛔ **`verify.sh` 전체를 CI 파이프라인의 공용 자격증명으로 무인 실행할 수 없다.** 구독
스코프 검사(a)는 Reader 권한으로 CI 분리 실행이 가능하지만, Entra 디렉터리·Graph
앱 권한 검사((c)~(g))는 `Application.Read.All`/`Directory.Read.All` 같은 Microsoft
Graph 디렉터리 읽기 권한을 요구하는데, 이 설계의 원칙 1이 CI 신원에 그런 Graph 권한
자체를 0건으로 금지한다. 따라서 Entra/Graph 관련 검사는 **사람 관리자가 수동으로
실행**해야 한다. 이것은 이 설계의 결함이 아니라 Azure 구조의 귀결이지만, 원본 AWS
설계(같은 자격증명 평면에서 IAM read 가능)와의 명확한 차이다.

## 4. IaC 승격 경로 (`import` 초안)

지금은 올리지 않는다. 올릴 때 처음부터 다시 설계하지 않도록 방향만 남긴다.

```hcl
variable "state_resource_group" { type = string }  # 값을 여기 적지 않는다
variable "env"                  { type = string }  # 예: hub 또는 dev

import {
  to = azurerm_storage_account.tfstate
  id = "/subscriptions/<sub>/resourceGroups/${var.state_resource_group}/providers/Microsoft.Storage/storageAccounts/<name>"
}
import {
  to = azuread_application.gha
  id = "<application-object-id>"
}
import {
  to = azurerm_role_definition.workload_ci
  id = "/subscriptions/<sub>/providers/Microsoft.Authorization/roleDefinitions/<guid>"
}
```

⚠️ 진짜 문제는 import 문법이 아니라, state 저장소를 관리하는 루트의 state를 그
저장소 자신에 두면 파괴 시 자기 발을 쏘게 된다는 점이다(원본과 동일한 경고). 승격할
때는 별도 backend 또는 그에 준하는 보호를 함께 설계해야 한다. 지금 올리지 않는
이유가 이것이다.

## 5. 출력값의 행선지

`bootstrap.sh`가 실행 끝에 값을 출력한다. **어느 것도 git에 커밋하지 않는다.**

| 값 | 행선지 |
|----|--------|
| `AZURE_CLIENT_ID` (App Registration의 appId) | GitHub repo 변수 |
| `AZURE_TENANT_ID` | GitHub repo 변수 |
| `AZURE_SUBSCRIPTION_ID` | GitHub repo 변수 |
| `AZURE_HUB_AKS_IDENTITY_ID` (AKS 클러스터용 identity의 리소스 ID) | GitHub repo 변수. **hub 대상 실행에서만 출력된다.** `live/hub/aks` 워크플로가 `TF_VAR_aks_identity_id`로 주입한다 |
| state Storage Account명·컨테이너명 | 로컬 `backend.hcl`(각 `live/<env>/` 디렉토리, gitignore됨). `tofu init -backend-config=backend.hcl` |

새 spoke 인스턴스(`dev`가 아닌 환경)를 추가하면 워크플로 배선(repo 변수 이름,
`live/<env>/` 루트)이 아직 없다. 그 배선은 이 부트스트랩과 별개로 설계해야 한다.
