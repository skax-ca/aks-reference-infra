# bootstrap: 부트스트랩 (IaC 밖)

**읽는 사람**: 부트스트랩 스크립트를 처음 실행하거나 고치는 사람.

state Storage Account, App Registration, 커스텀 RBAC 역할 2종, 리소스 잠금, 그리고 AKS
클러스터용 user-assigned identity를 Azure CLI 스크립트로 만든다. `tofu`가 이것들을 만들려면 이미 state 저장소가 있어야 하는 닭과 달걀
문제가 있어서, 이 한 겹만 IaC 밖에 둔다(원본 `eks-reference-infra`와 동일한 이유).

CI 신원(App Registration)은 **구독 전체 스코프의 `Owner` 등가 커스텀 역할**을 갖는다.
AWS 원본의 실행 Role(`AdministratorAccess`)과 권한 스코프 축에서 완전히 대칭이다.
방어선은 권한 크기가 아니라 이 신원에 도달할 수 있는 경로(FIC subject)를 정확히 이
repo 하나로 좁히는 것뿐이다(Azure Entra ID에는 AWS `AssumeRole` 같은 2단 체인이 없어,
FIC의 `subject` 완전 일치 검사가 그 역할을 대신한다). 설계 근거 전문은 `config.sh`의
관련 주석 참고.

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
(CAF 표에서 그대로 채택).

### state Storage Account (대상별 1개)

| 항목 | 값 |
|------|-----|
| 이름 | `st<workload><env><8자리 hex>`(3~24자, 소문자+숫자만, 하이픈 불가, Azure 물리 제약. `st` 약어는 CAF 표에서 그대로 채택, 2026-08-27 등재) |
| 이름의 소재 | git에 없다. GitHub repo 변수 또는 로컬 `backend.hcl`(gitignore됨) |
| 인증 | `use_azuread_auth = true`. `allowSharedKeyAccess = false` 강제(계정 키로 RBAC 우회 차단) |
| 내구성 | blob 버전 관리 + blob soft delete(30일) + **컨테이너 소프트 삭제**(30일, blob soft delete와 별개 기능이라 반드시 함께 켠다) |
| 컨테이너 | `tfstate` 1개. **동일 이름으로 재사용 금지**(소프트 삭제된 컨테이너와 같은 이름으로 새로 만들면 그 소프트 삭제분은 영구 복구 불가) |

### CI 신원 권한 (워크로드 역할=구독 전체 Owner 등가)

CI 신원(App Registration) 하나에 **커스텀 역할 2종**을 부여한다. built-in `Owner`를
그대로 쓰지 않는 이유는 "워크로드 RG 자체를 실수로 삭제하는" 흔한 사고를 값싸게
막기 위해서다(아래 참고). 워크로드 역할은 그 외엔 `Owner`와 동일하다.

| 역할 | 스코프 | 정의 방식 |
|------|--------|-----------|
| 워크로드 CI 역할 | **구독 전체** | `Actions:["*"]`, `NotActions:["Microsoft.Resources/subscriptions/resourceGroups/delete"]`(고정값 1개) |
| state 데이터 역할 | state 컨테이너 | Storage Blob Data Contributor에서 `containers/delete`만 제외한 고정 델타 |

⚠️ **워크로드 역할의 스코프는 구독 전체다.** AWS 원본(`eks-reference-infra`)의 실행
Role이 이미 `AdministratorAccess`를 쓰고, 방어선은 "권한 크기를 좁힌다"가 아니라
"이 신원에 도달할 수 있는 경로를 하나로 좁힌다"(입구 Role 신뢰 정책, Azure에서는 FIC
subject)에 있다는 것이 근거다. Azure도 이미 그 "도달 경로 하나" 방어선을 FIC subject
완전 일치 검사로 동등하게 갖고 있어, 워크로드 역할을 RG로 좁히는 것은 AWS 원본에
없는 과잉설계로 본다. 전체 근거는 `config.sh`의 관련 주석 참고.

⛔ **state 데이터 역할은 워크로드 역할과 별개로 반드시 유지한다.** Azure RBAC는
control-plane(`Actions`)과 storage blob data-plane(`DataActions`)이 완전히 분리된
축이다. `az role definition list --name Owner`로 확인한 결과 `Owner`도
`dataActions: []`다. 이 backend는 `use_azuread_auth = true`를 쓰므로, 워크로드
역할이 아무리 넓어도 state 데이터 역할 없이는 `tofu init`/`plan`/`apply`가 tfstate
blob 접근 자체에서 실패한다(모든 live root가 이 backend를 공유하므로 영향 범위가
전체다). control-plane 권한이 넓다고 data-plane 접근이 자동으로 딸려오지는 않는다.
Azure RBAC에서는 항상 별개다.

⚠️ `NotActions`는 deny 규칙이 아니다. 워크로드 역할의 `resourceGroups/delete`
제외는 이제 **보안 경계가 아니라 사고 방지 안전망**이다. 이 역할은 Owner와 거의
동등하므로 RG 안의 다른 모든 리소스는 어차피 지울 수 있다. 이 역할의 실제
안전성은 전적으로 아래 「GitHub OIDC」절의 FIC subject 완전 일치·정적 자격증명
0건·그룹 멤버십 0건 검사가 항상 참이라는 것에 의존한다.

### 리소스 잠금

| 대상 | 잠금 | 이유 |
|------|------|------|
| state RG | `CannotDelete` | control-plane 삭제 사고 방지. **워크로드 RG에는 걸지 않는다**(Azure 잠금은 상속되어, 걸면 그 RG 안의 모든 리소스 교체(destroy → create)가 막혀 무인 자동화가 파괴된다) |
| 워크로드 RG 자기 삭제 방지 | 잠금 아님 | 위 커스텀 역할의 `NotActions`에 `resourceGroups/delete`를 넣어 역할 정의로 해결한다 |

⚠️ **잠금은 tfstate 데이터를 보호하지 않는다.** `CannotDelete`는 control-plane(리소스
그룹·계정 자체의 삭제)만 막고 blob 데이터(data-plane)는 보호하지 않는다. tfstate의
실제 보호는 위 내구성 설정(soft delete 30일 + versioning) 한 층으로 수렴한다. state
데이터 역할이 `containers/delete`를 갖지 않아도, 워크로드 역할이 구독 전체 Owner
등가로 `Actions:["*"]`를 갖는 이상 그 역할을 통해 컨테이너 자체를 지울 수 있다.
즉시 영구 삭제는 안 된다(30일 내 복구 가능)는 것이 방어의 전부이고, CI가 아예 못
지운다는 보장은 없다.

⚠️ state RG에 잠금이 걸려 있으면 **사람 관리자도 예외 없이** 그 RG 안의 role
assignment를 다시 만들 수 없다(`CannotDelete`가 RBAC 할당 삭제까지 막는다). 정당한
변경이 필요하면: (1) 사람이 잠금 해제 → (2) `bootstrap.sh` 재실행으로 수렴 → (3) 잠금
재적용. 자동화하지 않는다. 진짜 사고와 정상 변경을 자동으로 구분할 수 없다. **CI
신원도 이제 이 잠금을 스스로 풀 수 있다**(Owner 등가라 `Microsoft.Authorization/
locks/delete`를 갖는다). 이 잠금은 이제 CI 신원 압축 시나리오의 방어선이 아니라
사람의 실수(`tofu destroy`가 이 RG를 잘못 겨냥하는 등) 방지용 안전망이다.

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
| 역할 | `aks-ref-bootstrap-spoke-peer-<env>`(`peer/action`+`virtualNetworks/read`+`managedClusters/read` 3액션, 2026-09-08 read 추가·2026-09-09 managedClusters/read 추가 - 아래 참고) |
| assignable scope / 할당 스코프 | 스포크 **워크로드 RG**(`rg-<workload>-<env>-krc-workload-01`) |
| 할당 대상 | hub App Registration(`entapp-<workload>-hub-krc-gha-01`)의 SP |
| 실행 주체 | `bootstrap.sh`가 `BOOTSTRAP_TARGET=spoke`일 때만 자동 포함(「크로스 구독 스포크 연결 권한」절). CI가 아니라 `bootstrap.sh`를 실행하는 사람이 만든다 |

⚠️ **스코프는 특정 VNet 리소스가 아니라 워크로드 RG 전체다.** `bootstrap.sh`는 항상
`live/*/networking`의 VNet apply보다 먼저 실행되므로, 그 시점엔 VNet이 아직 없어 리소스
단위로 좁힐 수 없다(닭과 달걀 문제). VNet 리소스 단위로 좁히는 대안도 검토했으나,
그러면 스포크마다 별도 스크립트를 한 번 더 실행해야 해 `bootstrap.sh` 1회로 끝나지
않는다. 세 액션 다 쓰기 범위가 좁아(피어링·읽기, 리소스 생성/삭제 불가) 위험도가
낮으므로, RG 스코프로 완화하고 `bootstrap.sh`에 통합하는 쪽을 택했다. 대가는 hub SP가
이 RG에 나중에 생길 다른 리소스에도 이 세 액션을 갖는다는 것이다.

⚠️ **2026-09-08 `virtualNetworks/read` 추가.** 원래는 `peer/action` 하나였다 - dev VNet
ID를 CI 변수(workflow_dispatch input)로 직접 주입해 read 없이 버텼는데, 그 값이
push-triggered plan이나 입력을 깜빡한 dispatch마다 비어(spoke 연결이 destroy로 잘못
잡히는) 사고 위험이 있었다(hub 철거→재구축 실검증 중 실측). `live/hub/vwan`이
`azurerm_resources`(태그 기반)로 dev VNet을 직접 조회하도록 바꿔 이 위험을 구조적으로
없앴다 - CI 신원에 이미 구독 전체 Owner 등가를 준 것(위)과 같은 실용적 판단이다.

⚠️ **2026-09-09 `managedClusters/read` 추가.** dev-gitops-registration 설계(hub
self-managed ArgoCD를 dev AKS에 등록) Step 7 - hub ArgoCD UAMI에 dev AKS 접근 role
assignment를 주려면 그 리소스 ID가 필요한데, 위 VNet과 같은 이유로 CI 변수 주입 대신
`live/hub/vwan`이 `azurerm_resources`(태그 기반)로 dev AKS도 직접 조회하도록 했다.
이름은 여전히 `spoke-peer`이지만("VNet 피어링 전용" 딱지가 이제 정확하지 않다) - 새
역할을 또 만들면 `verify.sh`의 "RG 스코프 외부 principal 허용 목록" 검사 항목이
늘어나 관리 비용만 커져(YAGNI), 이미 있는 "hub가 스포크를 발견하기 위한 read 전용
권한 모음"에 추가하는 쪽을 택했다.

⚠️ **`Contributor` 안내는 이 시나리오의 근거가 아니다.** 검색에서 자주 나오는 "원격 VNet
구독의 Contributor가 필요하다"는 문장은 크로스 **테넌트** 문서의 것이다. 이 설계는 동일
테넌트의 크로스 **구독**이고, 위 roles-permissions 문서가 액션 단위로 정확히 답한다.

⚠️ **AWS 원본과 소유 방향이 다르다.** AWS(`eks-reference-infra`)는 AWS RAM으로 hub가 TGW를
계정/OU 단위로 공유하면 스포크가 자기 계정의 전권으로 attachment를 직접 만든다. hub 계정에
새 IAM 권한이 필요 없다. Azure vWAN에는 RAM의 정확한 대응물이 없다. 반대 방향(스포크 CI가
연결을 소유)을 택하면 스포크 CI가 hub의 공유 컨트롤 플레인 쓰기 권한
(`hubVirtualNetworkConnections/write`)을 가져야 해 위 두 액션보다 훨씬 위험하다.
그래서 이 설계는 hub가 연결을 소유하는 방향을 유지한다. 대가로 **새 스포크를 추가할
때마다 `bootstrap.sh`(스포크 대상)를 한 번 더 실행해야 한다.** 자동으로 상속되지 않는다.

⛔ `verify.sh`는 스포크 워크로드 RG 스코프에서 "이 대상 자신의 SP를 제외한" role
assignment가 정확히 이 1건(hub SP + `spoke-peer` 역할)과 완전히 일치하는지 검사한다
(`BOOTSTRAP_TARGET=spoke`일 때만). 설계 근거 전문은 `config.sh`의 관련 주석 참고.

### AKS 클러스터용 identity·권한 (bootstrap이 아니라 Terraform이 만든다)

`aks-cluster` 모듈은 identity도 role assignment도 스스로 만들지 않고 **입력으로만
받는다**(모듈 경계 원칙, `iac-module-library`의 `docs/decisions.md` ADR 소관, 그대로
유지). **소비자인 이 repo는 그 identity·role assignment를 `live/hub/aks`의
Terraform으로 만든다.** bootstrap(IaC 밖)이 아니다. CI 신원이 구독 전체 Owner
등가가 되면서 "CI에 `roleAssignments/write`를 주지 않는다"던 옛 방어선이 사라져,
bootstrap에 둘 구조적 이유가 없어졌기 때문이다(`config.sh`의 관련 주석 참고).

이관 방식은 **live 재배포**다. 기존 클러스터를 destroy(GitHub Actions
`workflow_dispatch`, `action=destroy`) → bootstrap이 만들었던 구식 identity·role
assignment를 사람이 정리(`az identity delete`·`az role assignment delete`) →
`live/hub/aks`가 `azurerm_user_assigned_identity`·`azurerm_role_assignment`를
직접 만들도록 Terraform 수정 → 재배포. (대안이었던 `import` 블록으로 기존 리소스를
그대로 편입하는 방식은, MS 공식 문서가 "identity 전환 시 컨트롤 플레인이 새
identity로 넘어가는 데 수 시간 걸릴 수 있다"고 경고해 이번엔 채택하지 않았다. 이미
GitOps 워크로드가 없는 데모 클러스터라 destroy 비용이 낮았다.)

| 항목 | 값 | 관리 주체 |
|------|-----|-----------|
| user-assigned identity | `id-<workload>-hub-krc-aks-01` | `live/hub/aks`(Terraform, `azurerm_user_assigned_identity.aks`) |
| identity의 거처 | 워크로드 RG(`rg-<workload>-hub-krc-workload-01`) | 〃 |
| role assignment | built-in `Network Contributor` | `live/hub/aks`(Terraform, `azurerm_role_assignment.aks_node_subnet`) |
| role assignment 스코프 | `aks-node` 서브넷 리소스 하나 | 〃 |
| 리소스 프로바이더 | `Microsoft.ContainerService`·`Microsoft.Compute`·`Microsoft.ManagedIdentity`가 `Registered` | **여전히 bootstrap**(아래 참고) |

⚠️ 스코프가 노드 RG 전체가 아니라 서브넷 하나로 좁은 건 실수가 아니다. MS 공식
문서(`concepts-network-cni-overview`)가 BYO-VNet 시나리오(이 root처럼 VNet을
`live/hub/networking`이 별도 소유하는 경우)의 최소 권고로 명시하는 값이다. "노드
리소스 그룹 전체 Contributor"는 AKS가 네트워킹까지 자동 관리하는 기본 시나리오의
기본값이라 여기엔 해당하지 않는다.

⚠️ `skip_service_principal_aad_check = true`를 쓴다. 방금 만든 identity에 role을
붙이는 것이라 AAD 복제 지연으로 `PrincipalNotFound`가 날 수 있는데, bootstrap.sh가
예전에 bash 재시도(`retry_on_replication_delay`)로 흡수하던 문제를 이제 provider가
대신 흡수한다.

⚠️ **RP 등록 3종(`Microsoft.ContainerService`·`Microsoft.Compute`·
`Microsoft.ManagedIdentity`)만 bootstrap에 남아있다.** CI가 이제 구독 스코프
`*/register/action`도 가지므로 이것도 Terraform으로 옮길 수 있지만, 사람이
부트스트랩 시점에 한 번 처리하면 되는 저빈도 작업이라 옮길 실익이 낮다고 판단해
남겨 뒀다(별개 판단, identity·role assignment 이관과 묶지 않았다). 등록은 비동기라
`bootstrap.sh`는 `--wait`로 완료까지 기다린다. 2026-09-08부로 이 등록·검사는
`BOOTSTRAP_TARGET`과 무관하게 hub·spoke 양쪽에서 무조건 실행된다. `live/dev/aks`
신설로 "AKS는 hub만 쓴다"는 원래 가정이 깨졌고, 구독 단위 상태 조회라 대상과 무관하게
멱등이고 비용이 없다. 목록에 `Microsoft.Compute`·`Microsoft.ManagedIdentity`가 추가된
이유: dev 구독을 `az provider list`로 hub와 직접 비교(`comm -23`) 실측한 결과 이 둘도
`NotRegistered`였다. hub는 과거 다른 작업(예: `live/hub/workbench`의 VM 배포)으로
이미 등록돼 있어 이 요구사항 자체가 지금까지 드러나지 않았을 뿐이다.

## 3. 검증

### 3-1. 멱등성

재실행하면 이미 있는 항목은 전부 `ok`로 표시되고 `=== 변경 0건 ===`이 출력되어야
한다. 아무것도 없는 처음 상태에서 실행하면 `verify.sh`가 `exit 1`을 내야 한다.

⚠️ `verify.sh`는 App Registration이 없으면 그 지점에서 즉시 `exit 1`로 끝난다
(RG·Storage 등 이후 항목은 App Registration 존재를 전제로 하는 조회라 App
Registration이 없으면 검사 자체가 무의미하기 때문이다). "모든 항목이 개별적으로
absent로 보고된다"는 뜻이 아니다. drift 1건 보고 + exit 1이면 수용 기준을 충족한
것이다.

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

✅ **hub 대상으로 실제 Azure에서 3-1·3-2 전 과정을 실행해 확인했다.** 위 순서 그대로
DRIFT 2건 → 변경 2건 → drift 없음 → 변경 0건이 재현됐다. 이 과정에서 버그 3건(역할
정의 생성 직후·역할 정의 재조회·role assignment 조회의 ARM 캐시/조인 지연 미대응)을
발견해 고쳤고, 불변식 (b)(관리 그룹 스코프)를 제거했다. 상세 경위는 `config.sh`의
관련 주석 참고. dev(spoke) 인스턴스는 별도 구독이 필요해 이번에는 검증하지 않았다.

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
| state Storage Account명·컨테이너명 | 로컬 `backend.hcl`(각 `live/<env>/` 디렉토리, gitignore됨). `tofu init -backend-config=backend.hcl` |

⚠️ `AZURE_HUB_AKS_IDENTITY_ID`는 2026-09-04부로 더 이상 출력하지 않는다. AKS
컨트롤 플레인 identity를 이제 `live/hub/aks`가 Terraform으로 직접 만든다(위 「AKS
클러스터용 identity·권한」절). 기존 GitHub repo 변수는 미사용 상태로 정리한다.

새 spoke 인스턴스(`dev`가 아닌 환경)를 추가하면 워크플로 배선(repo 변수 이름,
`live/<env>/` 루트)이 아직 없다. 그 배선은 이 부트스트랩과 별개로 설계해야 한다.
