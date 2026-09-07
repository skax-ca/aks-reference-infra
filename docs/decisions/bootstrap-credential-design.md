# Plan: bootstrap/ 자격증명 계층 설계 (aks-reference-infra, Azure Entra ID)

상태: **pending approval** (v6, ralplan 5회 반복 한도 도달, consensus 종료)
모드: ralplan consensus, deliberate

v1(REJECT) → v2 → v3(Architect, "대체"를 "합성" 규칙으로 전환) → v4(Critic, ITERATE —
워크로드 RG 잠금의 상속 부작용을 커스텀 역할로 대체) → v5(Architect, 커스텀 역할 2종의
권한 목록 정정) → 이 v6은 최종(5회차) Critic 검토(verdict: ITERATE — CRITICAL 1건:
그룹 경유 할당 우회, MAJOR 2건: notActions 목록이 여전히 부정확·verify.sh가 원칙 1과
충돌)를 반영한 마지막 개정이다. ralplan의 최대 반복 한도(5회)에 도달해 이 세션의
consensus 루프는 여기서 종료된다. 남은 검토 의견은 6절 끝 "미해결 항목" 참고. 각 절 끝에
`[반영: ...]`, 맨 끝 변경 이력에 전체 버전 이력.

## 0. 문제 정의

원본(`iac-reference-infra`) `bootstrap/README.md`는 GitHub OIDC 기반 2단 IAM Role 체인을 쓴다.

- 입구 Role: 신뢰 = OIDC provider(`aud`+`sub` 조건) 하나뿐, 권한 = 실행 Role에 대한 `sts:AssumeRole` 하나뿐
- 실행 Role: 신뢰 = 입구 Role 하나뿐, 권한 = `AdministratorAccess`

이 구조의 방어 본질: GitHub Actions가 직접 인증하는 신원(입구 Role)은 그 자체로 고권한을
갖지 않는다. 신뢰 정책이 잘못 넓어지거나 OIDC 설정이 오염돼도, 공격자는 assume-role 권한만
얻을 뿐 즉시 관리자 권한을 얻지 못한다.

Azure Entra ID(Workload Identity Federation)에는 AWS `AssumeRole`과 정확히 같은 형태의 임의
위임 체인은 없다. 다만 User-Assigned Managed Identity를 Federated Identity Credential로 쓰는
구성(MI-as-FIC)이 제한된 형태로 존재한다(1절 Option C 참고).

이 저장소는 아직 코드가 없는 설계 단계(Phase 0)다. 이번 범위는 로컬 스캐폴딩까지이며, GitHub
repo 생성·push는 별도 승인 대상이다(`CLAUDE.md` 2절).

## 1. RALPLAN-DR 요약

### Principles (원칙, 4개)

1. 공용 CI 자격증명은 구독·관리 그룹 스코프의 ARM role assignment를 하나도 갖지 않으며,
   권한은 사람이 사전에 만든 리소스 그룹 경계를 넘지 않는다. Entra 디렉터리 역할과
   Microsoft Graph 앱 권한도 0건이다. **App Registration/UAMI 자체에 정적 자격증명
   (client secret·certificate)도 0건이다**(v4 신설, Critic 2차 C3 — 정적 자격증명이
   붙는 순간 GitHub OIDC와 무관하게 인증 가능해져 이 원칙 전체가 무의미해진다). 이
   6가지가 3절 시나리오 1의 검사 대상이다. **예외 1건**: hub 신원이 크로스 구독 Virtual
   WAN 연결을 위해 dev 구독 내 리소스 스코프에 최소 권한을 갖는 것은 허용한다(6-0-e
   참고, 스코프는 아직 미확정). AWS 원본의 "신원 자체가 얇다"는 속성과 완전히 같지는
   않다 — 이 차이는 7절 ADR Consequences에 명시적 한계로 남긴다.
2. IaC 밖 스크립트 계층에 상시 컴퓨트 인프라(Function App, Automation Runbook 등)를 새로
   만들지 않는다. 진단 설정·Log Analytics 같은 관측 기능은 이 원칙의 금지 대상이 아니다.
3. 존재하지 않는 개념을 억지로 재현하지 않되, 존재하는 것을 존재하지 않는다고 단정하지도
   않는다. 사실 주장이 불확실하면 "검증 필요"로 명시하고 확정 결정 표에 올리지 않는다.
4. 검증 가능성을 유지한다. `verify.sh` 등가물은 원본 3-1(멱등성)·3-2(negative test)를
   1:1로 포함해야 하며, `exit 0`(일치)/`1`(drift)/`2`(실행 불가) 3분류를 갖는다.

구독 분리(hub/dev를 별도 Azure 구독으로) 여부는 이 계획이 임의로 확정할 수 없는 신규
결정이다(`CLAUDE.md` 2절 확정 결정 표에 없음). 원칙 목록에 넣지 않고 6절 선행 의존성으로
분리했다.

`[반영: Critic 2차 C3 → 원칙 1에 정적 자격증명 0건 추가, 4→6종으로 확장. Critic 2차 M3 →
크로스 구독 예외 1건을 원칙 1에 명시.]`

### Decision Drivers (상위 3개, 변경 없음)

1. 보안 속성 동등성: 공용 자격증명이 관리자 권한을 직접, 무조건 갖지 않아야 한다.
2. 운영 자동화 유지: GitHub Actions 무인 CI/CD에서 사람의 실시간 승인 없이 plan/apply가
   가능해야 한다.
3. Azure 네이티브성: Azure가 실제로 지원하지 않는 기능에 의존하지 않는다.

### Viable Options

#### Option A(기준선, 항상 채택): 단일 App Registration + RG 스코프 Contributor 변형만

- 환경별(hub, dev) App Registration 1개씩(테넌트당 총 2개). **FIC subject 패턴 집합은
  이 절에서 확정하지 않고 6-0-d의 답변으로 확정한다**(v4 정정, Critic 2차 Minor 1 —
  v3는 "두 패턴"과 "Option D 채택 시 한 패턴"을 동시에 써서 채택 규칙(항상 D 포함)과
  모순되는 사문을 남겼다). 6-0-d가 정한 patterns가 3절 시나리오 1(f)의 허용 목록이다.
- **리소스 그룹은 bootstrap 스크립트가 사람의 관리자 자격증명으로 선생성한다.** bootstrap
  계층은 이미 IaC 밖에 있고 사람이 실행하므로 새로운 신뢰 계층이 아니다.
- CI 신원에는 **built-in `Contributor`가 아니라 커스텀 역할**을 그 리소스 그룹 스코프로
  부여한다(아래 "백스톱" 항목 참고). 검증해야 할 불변식은 7가지다(3절 시나리오 1):
  구독 스코프 role assignment 0건, 관리 그룹 스코프 role assignment 0건, Entra
  디렉터리 역할 0건, Microsoft Graph 앱 권한 0건, App Registration/UAMI의 client
  secret·certificate 0건, FIC 전 필드(subject·issuer·audience) 완전 일치, **(v6
  정정, Critic 3차 최종 지적)** **이 SP/UAMI의 Entra 그룹 멤버십(transitive) 0건**
  — v5는 이를 "PIM eligible 할당 0건"으로 서술했으나, PIM eligible 할당은 사용자
  주체에만 만들 수 있고 서비스 주체·관리 ID에는 애초에 생성할 수 없다(Azure 공식
  문서: "you can't create eligible role assignments for applications, service
  principals, or managed identities because they can't perform the activation
  steps"). v3의 "FIC 와일드카드" 시나리오와 같은 유형의 오류였다(존재하지 않는
  위협을 검사 대상으로 삼음). **실재하는 위협은 그룹 경유 할당이다** — Azure CLI
  `az role assignment list --include-groups`는 **user 주체에만** 그룹 전개를
  수행하고 서비스 주체에는 작동하지 않으므로(공식 문서 명시), CI 신원을 어떤
  Entra 그룹에 넣고 그 그룹에 구독 Owner를 부여하면 (a)(b)의 직접 할당 검사가
  전부 통과한 채로 실질 관리자 권한을 갖게 된다. 완화책은 (a)(b)의 조회 대상을
  SP objectId 하나가 아니라 "SP objectId + 그 SP의 transitive group membership에
  속한 모든 group objectId"로 확장하는 것이지만, 이 계획은 더 단순하고 강한 형태로
  **"CI 신원의 transitive group membership이 공집합"** 을 불변식으로 못박는다 —
  그룹 멤버십 자체가 0이면 (a)(b)의 그룹 경유 우회 가능성이 원천 차단된다.
- 구독·테넌트 대조 가드(v4 확장, Critic 2차 M1): `EXPECTED_SUBSCRIPTION`과
  `EXPECTED_TENANT`(둘 다 기본값 없음, GUID 형식 검증)를 각각 `az account show
  --query id`·`--query tenantId`와 대조, 불일치·미설정 시 `exit 2`로 즉시 중단. 이
  설계가 만드는 App Registration·FIC·Entra 역할은 테넌트 스코프 객체이므로 구독
  대조만으로는 "다른 테넌트에 잘못 실행"을 못 잡는다 — 원본의 `EXPECTED_ACCOUNT`/
  `assert_account`가 지키던 "공용 계정에서 조용히 다른 계정을 건드리지 않는다"는
  속성을 구독·테넌트 두 축 모두에서 이식한 것이다.
- **백스톱의 재귀속과 v4 정정(Critic 2차 C1, 최우선 수정)**: state를 실제로 보호하는
  것은 리소스 잠금이 아니라 2절의 soft delete + versioning + 커스텀 데이터 역할이다.
  `CannotDelete` 리소스 잠금은 control plane 사고(리소스 그룹·Storage Account 자체의
  삭제)만 막고 blob 데이터는 보호하지 않는다(Azure 공식 문서: "A read-only lock or
  cannot-delete lock on a storage account doesn't protect its data... blob, queue,
  table, or file"). `Contributor` 역할 정의의 `notActions`에는
  `Microsoft.Authorization/*/Write`·`*/Delete`가 있어, 이 잠금을 가진 RG에서는 CI
  신원이 스스로 풀 수 없다.

  **이 잠금은 state RG에만 건다.** v3는 hub/dev 워크로드 RG(networking 등)에도 걸도록
  했으나, Azure의 리소스 잠금은 **상속**된다 — 부모 스코프에 건 잠금은 그 스코프 안의
  모든 리소스에 그대로 적용되고, 나중에 추가되는 리소스도 자동으로 상속받는다(Azure
  공식 문서, "Lock inheritance"). 워크로드 RG에 `CannotDelete`를 걸면 그 RG의 **모든
  리소스**가 삭제 불가 상태가 되어 `tofu apply`의 정상적인 리소스 교체(destroy →
  create)마다 실패한다. 이는 Decision Driver 2(무인 자동화)를 상시로 파괴하므로
  채택하지 않는다.

  **워크로드 RG의 "자기 RG 자체 삭제" 방지(v2 R5)는 잠금이 아니라 역할 정의로
  해결한다.** **(v5 정정, Architect 3차 실측)** v4는 이 커스텀 역할의 `notActions`를
  3개(`resourceGroups/delete`, `Authorization/*/Write`, `Authorization/*/Delete`)로만
  적었는데, `Actions: ["*"]`에서 이 3개만 뺀 역할은 built-in `Contributor`의 실제
  `notActions`(8개)보다 **좁아서 결과적으로 Contributor보다 넓은 권한**이 된다 —
  특히 `Microsoft.Authorization/elevateAccess/Action`과
  `Microsoft.Resources/deploymentStacks/manageDenySetting/action`이 되살아나
  Option E의 방어 근거(Contributor는 이 권한이 없다는 것)를 스스로 무효화한다.
  **역할은 "Contributor의 notActions 전체를 그대로 물려받고 그 위에 RG 삭제를 추가로
  뺀 델타"로 정의한다. (v6 정정, Critic 3차 최종 지적) 이 목록을 문서에 하드코딩하지
  않는다** — v4는 3개, v5는 8+1개로 두 번 연속 Contributor의 실제 `notActions`(실측
  시점 기준 11개, Azure가 값을 추가하면 더 늘어날 수 있다)를 잘못 옮겨 적었다. 같은
  오류가 세 버전에 걸쳐 재발했다는 것은 이 값을 "문서가 옮겨 적어 사람이 대조하는
  방식"으로 관리하는 것 자체가 틀린 접근이라는 신호다. **`bootstrap.sh`는 커스텀
  역할 생성 시 `az role definition list --name Contributor --query
  "[0].permissions[0].notActions"`로 그 시점의 실제 값을 **런타임에 조회**해,
  거기에 `Microsoft.Resources/subscriptions/resourceGroups/delete` 하나만 추가해
  커스텀 역할의 `notActions`로 쓴다.** `Actions`는 `["*"]`. `verify.sh`도 같은
  조회로 기대값을 계산해 실제 역할 정의와 완전 일치를 대조한다(3절 시나리오
  4(c)) — 이렇게 하면 "무엇을 적어야 하는가"라는, 이미 세 번 틀린 질문 자체가
  사라진다. 이렇게 하면 자기 RG는 삭제할 수 없지만 RG 내부 리소스의 정상 생성·
  교체·삭제는 그대로 유지되고, Contributor보다 넓어지지도 않는다(built-in 정의가
  바뀌어도 다음 실행이 자동으로 따라간다). 정당한 RG 자체 삭제·마이그레이션이
  필요하면 사람이 관리자 자격증명으로 처리한다. **주의**: `notActions`는 deny
  규칙이 아니다(Azure 공식 문서: "NotActions is not a deny rule") — 이 역할의
  안전성은 전적으로 "이 신원이 다른 role assignment를 하나도 갖지 않는다"는 3절
  시나리오 1의 불변식에 의존한다. 그 불변식이 깨지면 이 역할의 모든 제외가 동시에
  무의미해진다(7절 Consequence 참고).
- 크로스 구독 연결(dev VNet ↔ hub Virtual WAN 허브): 소유권을 hub 신원 쪽으로 몬다.
  **다만 정확한 권한 스코프는 이 시점에 확정하지 않는다**(v4 정정, Critic 2차 M3 —
  v3가 인용한 Microsoft 크로스 **테넌트** 문서는 원격 구독의 **구독 스코프**
  `Contributor`를 안내하는데, 이 저장소는 크로스 **구독**(동일 테넌트) 시나리오라
  그대로 적용할 근거가 약하고, 구독 스코프를 그대로 가져오면 원칙 1을 깬다). 6-0-e로
  선행 확인 항목을 승격한다.

**Pros**: 6종 불변식이라는 검증 가능한 형태로 "권한 축소" 논거가 실제로 성립한다. 상시
인프라 불필요. 무인 자동화 유지. Option C의 성패와 무관하게 그 자체로 완결된 방어선이다.
**Cons**: 그래도 GitHub Actions가 직접 인증하는 신원이 RG 스코프 커스텀 역할을 직접
갖는다는 점에서 AWS 원본의 "신원 자체가 얇다"는 속성과 완전히 같지는 않다. 이 한계는 7절
ADR에 명시적으로 기록한다.

#### Option B: 이중 App Registration + 브로커(Function App 등)

**기각 유지.** 상시 컴퓨트 인프라가 새로 필요해 원칙 2(상시 컴퓨트 금지)에 정면으로
위배된다. 그 Function 자체가 새 공격 표면이 되어 문제를 한 겹 미룰 뿐 해결하지 않는다.

#### Option C(선택적 추가 계층, 검증 게이트 필요): GitHub OIDC → UAMI(FIC, 권한 0) → App Registration

기준선(Option A)은 이 옵션의 성패와 무관하게 유지된다. C는 "누가 App Registration의
토큰을 발급받는가"의 앞단을 UAMI로 한 겹 더 얇게 만드는 **선택적 추가 계층**이다.

UAMI가 GitHub OIDC로 페더레이션되어(RBAC 역할 0개) `api://AzureADTokenExchange` 토큰을
얻고, 그 토큰을 App Registration의 client assertion으로 제출해 App 토큰을 발급받는다.

**채택 전 필수 게이트**: "비-IMDS `client_credentials` + `client_assertion` 경로로
UAMI의 서비스 주체에 `aud=api://AzureADTokenExchange` 토큰이 실제로 발급되는가?"
`az identity create` + `az ad app federated-credential create` + 토큰 교환 2회로 30분
내 실측 가능한 이진 질문이다.

**2차 채택 조건(v4 정정, Critic 2차 M2)**: 게이트 통과는 계약이 아니므로, 다음 중
하나를 추가로 만족해야 채택한다. (i) 이 동작이 Microsoft 공식 문서 또는 지원 채널에서
확인됨. (ii) **(v4 수정)** 실패 시 App Registration에 **평시에는 등록돼 있지 않은**
GitHub OIDC 직접 FIC를 `bootstrap.sh` 재실행 한 번으로 등록해 수 분 내 복구할 수 있도록
스크립트 경로를 준비해 둔다. v3의 "GitHub OIDC 직접 경로를 항상 병행 유지"는 App
Registration이 UAMI와 GitHub OIDC 양쪽을 **상시** 신뢰하게 만들어 Option C가 제거하려던
경로를 그대로 살려두는 자기모순이었다(Option C의 방어 효과가 0이 됨) — 평시 미등록·
장애 시 재등록으로 바꿔 이 모순을 없앤다. "무중단 회귀"라는 목표도 "수 분 내 복구
가능"으로 완화한다.

실패하면 Option A만 쓰고, 그 실패 사실을 `bootstrap/README.md`에 근거로 남긴다(원칙 3).

#### Option D: 2단 게이트를 Azure 신원이 아니라 GitHub Environments로 이전

FIC subject 패턴 집합에 `environment:<env>`(배포 브랜치 정책·필수 리뷰어 등 보호 규칙을
건 GitHub Environment)를 포함한다. Option A(또는 A+C) 위에 얹는 보강안이며 상시 인프라
0, 비용 0.

**Cons**: 필수 리뷰어를 걸면 apply가 사람 승인 대기 상태가 되어 Decision Driver
2(무인 자동화)와 충돌한다. plan/apply를 서로 다른 Environment로 분리하는 것이 실무
해법이지만 그러면 subject가 다시 2개가 된다. **6-0-d에서 사용자가 확인할 것**: 필수
리뷰어 없이 배포 브랜치 정책만 쓸지(무인 자동화 유지, 방어는 약함), 리뷰어를 걸고
plan/apply를 분리할지(방어는 강하나 무인 자동화 일부 상실).

#### Option E(승격, 검증 게이트 필요): Deployment Stacks의 `denySettings`

Contributor 역할 정의의 `notActions`에
`Microsoft.Resources/deploymentStacks/manageDenySetting/action`이 있다 — Azure는
"스택을 실행하는 신원이 자기 자신의 deny 설정을 못 바꾼다"는 성질을 역할 정의 수준에서
이미 설계해 뒀다. 다만 **이 옵션도 R1(잠금류는 data plane을 못 막는다는 사실)을
해결하지 않는다** — `denySettings` 역시 control plane 쓰기/삭제를 막을 뿐이다. state
보호의 실제 근거는 이 옵션이 채택되어도 여전히 2절이다.

**스파이크 게이트**: OpenTofu와 ARM 네이티브 Deployment Stacks의 통합 방법이
검증되지 않아, 이번 범위(로컬 스캐폴딩)에서는 실행하지 않는다. 별도 스파이크로
재검토한다.

### 채택 규칙("합성")

기준선은 항상 Option A + Option D + 2절(state 격리)이다. Option C가 게이트(위 2개
조건)를 통과하면 그 기준선 위에 C를 추가 계층으로 얹는다. 통과하지 못하면 기준선만 쓰고
그 사실을 기록한다. 어느 경우든 Option A의 요소(RG 선생성, 6종 권한 0건 불변식,
`EXPECTED_SUBSCRIPTION`/`EXPECTED_TENANT`, 커스텀 역할, state RG 전용 잠금)는
**무조건 요건**이며 3절·5절·6절이 이를 전제로 서술된다. Option B는 항상 기각, Option E는
별도 스파이크 완료 전까지 보류.

`[반영: Critic 2차 C1(최대 결함, 워크로드 RG 잠금의 상속 부작용) → 잠금을 state RG로
한정, 워크로드 RG는 커스텀 역할로 자기 삭제만 차단. C2 → 2절과 정합(아래). C3 → 원칙
1·불변식 4→6종 확장. M1 → EXPECTED_TENANT 신설. M2 → Option C 2차 조건 (ii) 자기모순
해소. M3 → 크로스 구독 권한을 6-0-e 선행 확인으로 승격, 원칙 1에 예외 명시. Minor 1 →
Option A subject 패턴 서술을 6-0-d로 위임.]`

## 2. state backend 설계

원본은 S3 + `use_lockfile = true`. Azure 대응은 `azurerm` backend(Storage Account + Blob
Container).

- 잠금: `azurerm` backend는 blob lease 기반 잠금을 네이티브로 지원한다. 별도 lock 테이블
  불필요.
- 인증: `use_azuread_auth = true`로 Azure AD 인증을 쓴다. 다만 이것만으로는 계정 키
  경로가 닫히지 않는다 — 어떤 데이터 역할이든 `Microsoft.Storage/storageAccounts/
  listKeys/action`을 가진 principal은 계정 키를 뽑아 RBAC을 완전히 우회할 수 있다.
  따라서 Storage Account 자체에 `allowSharedKeyAccess = false`를 강제한다(서버 측
  차단). 이 속성을 되돌리려면 계정 스코프 이상의 `Microsoft.Storage/storageAccounts/
  write`가 필요해, CI 신원(이 SA가 CI 스코프 밖에 있으므로 애초에 권한 없음)이 스스로
  되돌릴 수 없다.
- **RBAC 스코프와 데이터 역할(v5 정정, Architect 3차 실측)**: `Storage Blob Data
  Contributor`를 그대로 쓰면 컨테이너 스코프로 좁혀도 `containers/delete`(RBAC상
  `Actions`, 즉 **control-plane** 항목이다 — v4는 이를 data-plane으로 잘못
  분류했다)가 포함된다. **컨테이너 소프트 삭제는 blob 소프트 삭제와 별개 기능**이라
  이 경로를 막지 못한다(공식 문서: container soft delete는 컨테이너가 이미 삭제된
  경우에만 전체 복구, blob 단위 복구는 blob soft delete·versioning의 몫). 따라서 CI
  신원에는 `Storage Blob Data Contributor`에서 `containers/delete`만 제외한 델타
  커스텀 역할을 컨테이너 스코프로 부여한다. **v4는 이 델타를 "blobs/read·write·
  delete·move만"으로 좁게 다시 적어, `Actions`의 `containers/read`·
  `generateUserDelegationKey/action`과 `DataActions`의 `blobs/add/action`(신규 blob
  생성, 즉 첫 state 파일 생성에 필요)이 통째로 빠졌다** — 이 상태로는 첫 `tofu
  apply`가 state 파일을 만들지 못해 실패한다(3절 시나리오 1의 불변식이 지키려는
  것과 같은 종류의, 그러나 반대 방향의 실패다). 정확한 델타는 다음과 같다:
  - `Actions`: `containers/read`, `containers/write`,
    `generateUserDelegationKey/action` (`containers/delete`만 제외)
  - `DataActions`: `blobs/read`, `blobs/write`, `blobs/add/action`, `blobs/delete`,
    `blobs/move/action` (`blobs/permanentDelete/action`은 Data Contributor에 애초에
    없으므로 이 역할에도 없다 — 명시적 제외가 아니라 원래 없는 것이다)

  hub/dev가 같은 Storage Account를 공유하는 경우, 컨테이너 분리가 대체 격리 수단이
  된다(구독 분리가 승인되지 않을 경우, 6-0-a 참고). **주의**: CI가 `containers/write`는
  유지하므로, 컨테이너를 삭제하지 못해도 **소프트 삭제된 컨테이너와 동일한 이름으로
  새 컨테이너를 만들면 그 소프트 삭제분은 영구히 복구 불가능해진다**(공식 문서
  경고). 컨테이너 이름 재사용을 금지하는 것을 `bootstrap/README.md`에 운영 규칙으로
  남긴다.
- state Storage Account의 위치(어느 구독/리소스 그룹인가)는 CI 신원의 RBAC 스코프 밖에
  둔다.
- **state 보호의 실제 근거(v5 정정)**: 위 델타 역할이 `containers/delete`(control
  plane)를 제외하고 `blobs/permanentDelete/action`을 원래 갖지 않으므로, CI 신원이
  blob을 지워도 soft delete 보존 기간 내에는 복구 가능하고 컨테이너 자체도 삭제할 수
  없다. **이것이 이 설계에서 tfstate를 실제로 보호하는 메커니즘이며, 1절의 리소스
  잠금이 아니다** — 잠금은 control plane(계정 자체 삭제) 사고를 막을 뿐 data
  plane(blob 삭제)은 원래 막지 못한다. 소프트 삭제된 blob의 복구(Undelete Blob)는
  `containers/write`를 요구하므로 CI 신원도 자기 실수를 스스로 복구할 수 있다 —
  단 위 "컨테이너 재사용 금지" 규칙을 어기지 않은 경우에 한한다.
- 내구성: Blob 버전 관리(soft delete + versioning) **및 컨테이너 소프트 삭제**를 함께
  활성화한다(v4 추가, Critic 2차 C2 — 컨테이너 자체가 삭제되는 사고는 blob soft
  delete로 막히지 않으므로 별도로 켜야 한다). 주의: state 파일은 평문 시크릿을 담을
  수 있으므로, 버저닝은 "삭제한 시크릿의 이전 버전이 보존 기간 내내 남는다"는 뜻이기도
  하다. 보존 기간을 의식적으로 정한다.
- state key 규칙: 원본의 `<env>/<component>.tfstate`를 Blob 이름 규칙으로 유지.

`[반영: Architect 3차(v4의 델타 역할이 blobs/add/action·containers/read 누락으로 첫
apply 실패, containers/delete를 data-plane으로 오분류) → 정확한 델타 목록 명시,
컨테이너 재사용 금지 규칙 추가.]`

## 3. Pre-mortem (deliberate mode, 4개 실패 시나리오)

1. **구독/MG/디렉터리/Graph 권한, 정적 자격증명, FIC 오설정, 그룹 경유 할당이
   실수로 생긴다(v6 확장)**: 완화책은 "다음 7가지 전부가 허용 목록과 정확히
   일치하지 않으면 `exit 1`"이라는 불변식이다 — (a) 구독 스코프 role
   assignment(관련 구독 전체를 순회해 열거), (b) 관리 그룹 스코프 role
   assignment, (c) Entra 디렉터리 역할, (d) Microsoft Graph 앱 권한, (e) App
   Registration/UAMI의 `az ad app credential list` 결과(`passwordCredentials`·
   `keyCredentials`)가 0건, App/SP의 owners 목록이 허용 목록과 일치, (f) FIC의
   `subject`·`issuer`(`https://token.actions.githubusercontent.com`)·`audiences`
   (`api://AzureADTokenExchange`) **전 필드**가 6-0-d가 정한 허용 목록과 완전
   일치, (g) **(v6 정정, Critic 3차 최종 지적)** **이 SP/UAMI의 Entra 그룹
   멤버십(transitive)이 0건** — v5는 이 항목을 "PIM eligible 할당 0건"으로
   서술했으나, PIM eligible 할당은 사용자 주체 전용 기능이라 서비스 주체·관리
   ID에는 애초에 생성할 수 없다(공식 문서: "you can't create eligible role
   assignments for applications, service principals, or managed identities").
   실재하는 위협은 그룹 경유 할당이다 — `az role assignment list
   --include-groups`는 **user 주체에만** 그룹 전개를 수행하고 서비스 주체에는
   작동하지 않으므로, (a)(b)가 SP objectId 하나만 조회하면 "CI 신원을 어떤
   그룹에 넣고 그 그룹에 구독 Owner를 부여"하는 경로가 조용히 통과한다. 그룹
   멤버십 자체를 0건으로 못박으면 이 우회가 원천 차단된다("0건 세기"가 아니라
   "실제 집합 == 허용 집합"의 완전 일치로 검사한다).
2. **(v4 재작성, Critic 2차 M4) FIC의 subject/issuer/audience가 문법적으로 유효하지만
   의도와 다르게 설정되거나, 허용 목록 밖의 FIC가 추가된다**: v3의 "와일드카드로
   넓힌다"는 시나리오는 Azure에서 성립하지 않는다 — Entra 공식 문서가 "Wildcard
   characters aren't supported in any federated identity credential property value"라고
   명시해, 이 실패 자체가 애초에 생성되지 않는다(v3는 원본 AWS의 와일드카드 금지
   경고를 기계적으로 이식해 원칙 3을 스스로 어겼다). Azure의 실제 위험은 다르다:
   문법적으로 유효하지만 잘못된 `subject`(다른 repo, `pull_request:` 트리거,
   잘못된 env)나 `issuer`/`audience` 오설정은 **오류 없이 생성**되고 토큰 교환
   시점에야 실패한다(공식 문서 경고). 완화책: 시나리오 1(f)의 전 필드 완전 일치
   검사가 이를 잡는다.
3. **다른 구독/테넌트에 bootstrap을 잘못 실행한다**: `EXPECTED_SUBSCRIPTION`·
   `EXPECTED_TENANT` 중 하나라도 미설정 또는 실제 값과 불일치 시 `exit 2`로 즉시
   중단. 완화책은 가드 그 자체이며, 원본의 `EXPECTED_ACCOUNT`와 동일한 논리를 구독·
   테넌트 두 축에 적용한 것이다.
4. **state storage의 blob lease가 교착되거나, 신원 생성 직후 전파 지연으로 apply가
   실패한다(v4 확장, Critic 2차 M5)**: (a) CI가 apply 중 죽으면 lease가 풀리지 않아
   다음 실행이 잠긴다. 완화책: lease ID를 조회해 강제 해제하는 절차(`az storage blob
   lease break`)를 `bootstrap/README.md`에 명령 단위로 기록한다. 자동 해제는 하지
   않는다. (b) App Registration/Service Principal 생성 직후 그 principal에 role
   assignment를 걸면 Entra 복제 지연으로 `PrincipalNotFound`가 흔히 발생한다(원본
   README 128~131행이 AWS IAM에 대해 이미 경고한 것과 같은 계열의 문제). 완화책은
   5절의 재시도 규칙으로 별도 서술한다. (c) 워크로드 RG의 커스텀 역할 정의가 실수로
   built-in `Contributor`나 불완전한 `notActions` 목록으로 되돌아가면 R5(자기 RG
   삭제 가능) 또는 원칙 1 위반(Contributor보다 넓어짐)이 재발한다. **완화책(v5
   정정, Architect 3차 지적)**: `verify.sh`가 워크로드 RG에 부여된 역할의
   `notActions` **집합 전체**가 1절에 정의한 목록과 정확히 일치하는지 확인한다
   ("`resourceGroups/delete` 포함 여부"만 보면 Contributor보다 넓어지는 방향의
   오류를 잡지 못한다). (d) **(v5 신규)** state 데이터 커스텀 역할이 실수로
   `blobs/add/action`을 뺀 채 배포되면 첫 `tofu apply`가 state 파일을 생성하지
   못해 실패한다. 완화책: 4절 E2E에 "빈 컨테이너에 새 blob을 쓸 수 있다"는
   positive case를 추가해 배포 전에 이 역할의 최소 기능을 증명한다.

`[반영: Architect 3차 → 시나리오 1을 7종으로 확장(PIM 추가). 시나리오 4(c)의 검사
방식을 "포함 여부"에서 "집합 완전 일치"로 정정, (d) 신설(state 데이터 역할 최소
기능 검증).]`

## 4. 확장 테스트 계획 (deliberate mode)

- **Unit**: 리소스 그룹명·Storage Account명이 네이밍 규칙과 Azure의 물리적 제약(Storage
  Account: 3~24자, 소문자+숫자만, 하이픈 불가)을 동시에 만족하는지 검사한다. 선행
  의존성: `iac-module-library`의 `docs/naming/abbreviations/azure.md`에 필요한 약어
  (storage account·resource group·managed identity·log analytics workspace·virtual
  wan)가 현재 0건이다. 그 저장소의 등재 절차를 거쳐 먼저 등재해야 이 테스트가 실행
  가능해진다.
- **Integration**: `bootstrap.sh` 실행 후 3절 시나리오 1의 7종(a~g) 전부를 조회해
  기대값(완전 일치)과 대조한다. (a)(b)는 **관련 구독 전체를 순회**해 열거하되,
  **(v6 정정, Critic 3차 최종 지적)** SP objectId 하나만 조회해서는 안 된다 —
  `--include-groups`는 서비스 주체에 작동하지 않으므로, (g)의 그룹 멤버십 조회가
  공집합임을 먼저 확인한 뒤 (a)(b)를 SP objectId로 직접 조회하는 순서로 수행한다
  (그룹 멤버십이 0이면 그룹 경유 할당 자체가 있을 수 없으므로 이 순서로 충분하다).
  이것은 상태 조회이지 재실행 수렴 검사가 아니다 — 멱등성 검사는 5절로 분리한다.
- **E2E**: 다음을 모두 실행해 증명한다.
  1. 이 신원으로 OIDC 로그인 후 `az group show`로 배정된 리소스 그룹만 조회 가능하고,
     다른 리소스 그룹 조회 시 `AuthorizationFailed`.
  2. 이 신원이 자기 자신의 role assignment를 확장할 수 없다: `az role assignment
     create` 시도 → `AuthorizationFailed`.
  3. 이 신원이 다른 리소스 그룹을 삭제할 수 없다: 배정되지 않은 다른 RG 대상 `az
     group delete` → 거부 확인.
  4. 워크로드 RG에 대해 두 가지를 함께 확인한다: (positive) 이 신원이 RG 내부
     리소스를 정상적으로 생성·교체·삭제할 수 있다(커스텀 역할이 정상 운영을 막지
     않음을 증명), (negative) 이 신원이 **자기 자신의 RG는** 삭제할 수 없다.
  5. state 컨테이너에 대해 두 가지를 함께 확인한다(**v6 정정, Critic 3차 최종
     지적**: 두 명령 모두 `--auth-mode login`을 명시한다 — 기본값인 공유 키
     인증으로 실행하면 `allowSharedKeyAccess = false` 때문에 역할 권한과 무관한
     이유로 실패해 오진을 낳는다): (positive) 이 신원이 **빈 컨테이너에 새 blob을
     쓸 수 있다**(첫 `tofu apply`의 state 파일 생성을 시뮬레이션 —
     `blobs/add/action` 누락은 여기서 즉시 드러난다), (negative) 이 신원이
     **컨테이너 자체는 삭제할 수 없다**(`containers/delete` 제외를 증명).
- **Observability**: 정확한 Log Analytics 테이블과 알림 조건은 이 시점에는 확정하지
  않는다. 다만 미리 정할 수 있는 수용 기준 하나는 지금 명시한다:
  "`Microsoft.Authorization/roleAssignments/write` 거부 이벤트가 발생 시점으로부터
  30분 내 조회 가능해야 한다." 이 로그 소스가 Activity Log인지 다른 것인지는 6절
  선결 과제로 남긴다.

`[반영: Critic 3차 최종 → Integration 조회 순서 정정(그룹 멤버십 우선). E2E 항목 5에
--auth-mode login 명시(allowSharedKeyAccess=false와의 오진 방지).]`

## 5. 검증 절차 (원본 3절과 1:1 대응)

- **3-1 대응(멱등성)**: bootstrap 스크립트를 연속 두 번 실행한다. 두 번째 실행은 반드시
  `=== 변경 0건 ===`을 출력해야 한다. **아무것도 없는 처음 상태에서 실행하면 모든
  대상이 `absent`로 잡히고 `exit 1`이 나오는 것도 함께 확인한다**(원본 README
  162~163행과 동일, v4에서 명시).
- **신원 생성 직후 전파 지연 재시도(v4 확장, Critic 2차 M5)**: 원본이 AWS IAM에 대해
  건 것과 같은 계열의 재시도를 Entra 객체 전체에 일반화한다. 특정 오류 코드일 때만
  재시도한다(맹목적 재시도는 진짜 실패를 감춘다):
  - SP 생성 → role assignment: `PrincipalNotFound` 시 5초 간격 최대 10회.
  - FIC 생성 → 토큰 교환: `AADSTS70021` 시 재시도.
  - 같은 UAMI 하위 FIC 동시 생성: 409 충돌 시 직렬 재시도(공식 문서상 이 제약은
    user-assigned managed identity에 명시적으로 서술된 것이며, App Registration
    쪽으로 일반화한 것이 아니다).
- **생성 순서(원본 README 118~122행 대응)**: RG → SA/컨테이너 → App Registration/SP
  → FIC → role assignment → **잠금(반드시 마지막)**. 잠금을 먼저 걸면 이후 리소스
  생성·역할 할당이 그 RG 안에서 막힐 수 있다.
- **잠금 존재 시 재실행 절차(v5 신규, Architect 3차 지적)**: state RG의
  `CannotDelete` 잠금은 "cannot-delete lock prevents the deletion of Azure RBAC
  assignments"이자 "The lock overrides any user permissions"이므로, 멱등성
  재실행(3-1)이나 drift 수렴(3-2)이 그 RG 안의 role assignment를 다시 만들어야
  하는 경우 **사람 관리자도 예외 없이 막힌다.** `bootstrap.sh`는 이 RG에 변경이
  필요할 때 (1) 사람의 관리자 자격증명으로 잠금을 해제 → (2) 수렴 적용 → (3) 잠금을
  재적용하는 절차를 명시적으로 거친다. 이 절차 없이는 5절의 negative test(아래)가
  state RG를 대상으로 할 경우 두 번째 `bootstrap.sh` 실행에서 막힌다.
- **3-2 대응(negative test)**: 서로 다른 코드 경로 2개에 고의로 drift를 주입한다(예:
  FIC의 subject 값 하나를 변경, state Storage Account의 blob versioning을 비활성화) →
  `verify.sh` 실행 → drift 2건 검출, `exit 1` → `bootstrap.sh` 재실행(위 잠금
  해제/재적용 절차 포함) → 변경 2건만 수렴 → `verify.sh` 재실행 → drift 없음,
  `exit 0`, 변경 0건.
- **exit code 규약**: `0`=일치, `1`=drift, `2`=실행 불가(`EXPECTED_SUBSCRIPTION`·
  `EXPECTED_TENANT` 미설정·불일치 등). 원본과 동일.

`[반영: Architect 3차(state RG 잠금이 RBAC 할당 삭제도 막아 재실행 자체가 막힘) →
잠금 해제/재적용 절차 신설, negative test에 반영.]`

## 6. 다음 실행 단계

### 0. 선행 의존성 (사용자 확정 완료분 3건 + 남은 실행 준비 3건)

- **(a) 구독 분리: 확정 — 구독 2개 확보 가능.** hub/dev를 별도 Azure 구독으로
  분리한다(사용자 확인 완료). 이에 따라 (e)의 크로스 구독 vWAN 권한 스코프
  확정이 실제로 필요한 작업이 됐다(아래).
- **(b) 네이밍 약어 등재**: `iac-module-library`의 `docs/naming/abbreviations/azure.md`에
  필요한 약어를 등재한다(교차 저장소 작업). 4절 Unit 테스트의 선행 조건이다.
- **(c) Option C 실측 게이트: 보류 확정 — 기본 설계(Option A+D)로 먼저 진행.**
  사용자가 30분 실측 스파이크를 나중으로 미루기로 결정했다(Option A는 그 결과와
  무관하게 완결된 방어선이므로 지금 실행을 막지 않는다). Option C는 이후 언제든
  별도 스파이크로 재평가해 추가 계층으로 얹을 수 있다.
- **(d) Option D 방식: 확정 — 배포 브랜치 정책만(무인 자동화 유지).** 필수
  리뷰어는 걸지 않는다. FIC subject 허용 목록은 `repo:<org>/<repo>:
  ref:refs/heads/main`과 `repo:<org>/<repo>:environment:<env>` 두 패턴으로
  확정한다(3절 시나리오 1(f)의 대조 기준).
- **(e) 크로스 구독 vWAN 권한 스코프 확정(구독 분리 확정으로 실행 대상이 됨)**:
  hub 신원이 dev 구독 내에 가질 최소 권한의 정확한 역할 정의(최소한
  `Microsoft.Network/virtualNetworks/peer/action` 포함)를 확정한다. 이 역할의
  `AssignableScopes`는 구독 또는 리소스 그룹으로 두고, **할당 자체를** dev VNet
  리소스 스코프로 좁게 건다. `modules/azure/vnet`의 실제 출력값과 맞는지는 Phase 1
  networking 스캐폴딩 단계에서 재확인한다(현재 미확정으로 남김 — 모듈 계약을
  먼저 확인해야 하는 기술적 사안이라 이번 세션에서 임의로 정하지 않는다).
- **(f) `scripts/validate-doc-conventions.py` 이식 여부 확인**: `CLAUDE.md` 7절이
  요구하는 문서 문체 검증 스크립트가 아직 이식되지 않았다. 6-1-1이 작성할
  `bootstrap/README.md`가 그 규칙(400줄 제한, em-dash 금지 등) 적용 대상이므로, 이
  스크립트의 이식 시점을 여기서 함께 정한다.

`[반영: 사용자 확인(2026-08-27) → (a) 구독 2개 확보 가능, (c) Option C는 나중에(기본
설계 먼저 진행), (d) 배포 브랜치 정책만(무인 자동화 유지). (e)는 (a) 확정으로 실행
대상이 됐으나 모듈 계약 확인이 먼저 필요해 스코프는 Phase 1에서 확정.]`

### 1. 설계 확정 후

1. `bootstrap/README.md`(이 repo용) 전면 작성 — 원본 1~5절 구조를 참고하되 전부 이
   설계로 새로 쓴다. 원본이 다루는 항목 중 이 계획이 아직 명시하지 않은 것(출력값의
   행선지: `AZURE_CLIENT_ID`/`AZURE_TENANT_ID`/`AZURE_SUBSCRIPTION_ID`·SA/컨테이너명의
   GitHub repo 변수 대응표, `BOOTSTRAP_TARGET`/`SPOKE_ENV` 등가의 실행 대상 선택
   메커니즘, "표와 코드가 어긋나면 표를 고친다"는 SSOT 우선순위, IaC 승격 경로의
   자기발사 경고)를 이 단계에서 채운다.
2. `bootstrap/config.sh`·`bootstrap.sh`·`verify.sh` Azure CLI 버전 구현 —
   `EXPECTED_SUBSCRIPTION`·`EXPECTED_TENANT` 가드, 7종 권한 0건 불변식(그룹 멤버십
   포함), 1절·2절에 정의한 커스텀 역할 2종(워크로드 RG용은 런타임 조회 기반, state
   데이터용은 고정 델타), state RG 전용 잠금과 그 해제/재적용 절차, 5절의 생성
   순서·재시도 규칙을 포함한다. 커스텀 역할 정의의 생성·수정·삭제는
   `AssignableScopes`의 모든 스코프에서 `Microsoft.Authorization/roleDefinitions/
   write`를 요구한다 — 즉 `bootstrap.sh`를 실행하는 사람은 해당 구독의 Owner 또는
   User Access Administrator여야 한다. **(v6 정정, Critic 3차 최종 지적)** `verify.sh`가
   `roleDefinitions/read`만 있으면 되는 것은 3절 시나리오 1의 (a)(b)(ARM RBAC
   스코프 검사)뿐이다. (c)~(g)(Entra 디렉터리 역할, Graph 앱 권한, 정적 자격증명·
   owners, FIC 전 필드, 그룹 멤버십)는 Microsoft Graph 디렉터리 읽기 권한
   (`Application.Read.All`/`Directory.Read.All` 또는 앱 소유권)을 요구하는데,
   원칙 1은 CI 신원에 이런 Graph 권한을 0건으로 못박는다. 따라서 **`verify.sh`
   전체를 CI 파이프라인의 공용 자격증명으로 무인 실행할 수 없다** — ARM 스코프
   검사만 분리해 Reader 권한의 별도 신원으로 CI에 넣고, Entra/Graph 검사는 사람
   관리자가 수동으로 실행하는 것으로 6절 실행 단계를 설계한다. 이 한계를 7절
   Consequences에 기록한다.
3. `CLAUDE.md` 2절 확정 결정 표에 이 설계·state backend 결정·구독 분리 여부(0-a)·
   크로스 구독 권한 스코프(0-e)·Option C 채택 여부(0-c)를 추가하고, 4절의 "임의로
   결정하지 않는다" 경고를 해제한다. 원칙 1의 한계를 함께 명시한다.
4. Phase 2에서 AKS 배포가 `Microsoft.Authorization/roleAssignments/write`를 CI
   신원에 요구하게 되면, 이를 자동 통과가 아니라 이 설계 전체의 재검토 트리거로
   `CLAUDE.md`에 기록한다.

⚠️ 0·1절 모두 실행 단계다. 이 plan이 `pending approval`로 출력된 뒤, 사용자가 명시적으로
실행(`team` 또는 `ralph`)을 승인해야 시작한다.

## 7. ADR

- **Decision**: 기준선으로 Option A(RG 스코프 커스텀 역할 2종 — 워크로드용은
  Contributor의 `notActions`를 **런타임 조회**로 물려받고 `resourceGroups/delete`를
  추가로 제외, state 데이터용은 Storage Blob Data Contributor에서 `containers/delete`만
  제외 — ·7종 권한 0건 불변식(그룹 멤버십 포함)·사람이 사전 생성한 RG·state RG 전용
  resource lock과 그 해제/재적용 절차·`EXPECTED_SUBSCRIPTION`/`EXPECTED_TENANT` 가드) +
  Option D(GitHub Environments 보호 규칙)를 항상 채택한다. Option C(MI-as-FIC)의 실측
  게이트(6-0-c)와 2차 채택 조건을 모두 통과하면 그 기준선 위에 Option C를 추가
  계층으로 얹는다. 어느 경우든 Option A의 요소는 유지된다.
- **Drivers**: 보안 속성 동등성(완전 동등은 아니나 7종 권한 0건이라는 검증 가능한
  불변식으로 방어 깊이 확보), 무인 자동화 유지, Azure 네이티브성.
- **Alternatives considered**:
  - Option B(이중 App Registration + 브로커): 상시 컴퓨트 인프라 신설이 원칙 2에 정면
    위배되어 기각.
  - Option E(Deployment Stacks `denySettings`): Contributor가 `manageDenySetting`
    권한을 갖지 않는다는 사실이 Azure 네이티브 적합성을 뒷받침하나, OpenTofu와의
    통합이 검증되지 않고 잠금과 동일하게 data plane을 보호하지 못해, 이번 범위에서는
    판단 보류.
  - 워크로드 RG에 리소스 잠금(v3안): Azure의 잠금 상속 규칙 때문에 RG 내부 모든
    리소스의 정상 교체를 막아 무인 자동화를 파괴한다는 것을 확인해 기각. 커스텀
    역할로 대체.
  - 커스텀 역할의 `notActions`를 문서에 하드코딩(v4·v5안): 두 버전 모두 built-in
    Contributor의 실제 `notActions`(각각 8개, 10개로 적었으나 실측 시점 기준 11개)를
    정확히 옮기지 못해 매번 결과 역할이 Contributor보다 넓어졌다. 같은 오류가 3회
    연속 재발한 것을 근거로 "문서가 값을 옮겨 적고 사람이 대조하는 방식" 자체를
    기각하고, `bootstrap.sh`/`verify.sh`가 매 실행 시 `az role definition list`로
    런타임 조회하는 방식으로 대체했다(1절).
  - PIM eligible 할당 조회를 불변식으로 채택(v5안): PIM eligible 할당은 사용자
    주체 전용 기능이라 서비스 주체·관리 ID에는 생성 자체가 불가능하다는 것을
    최종 Critic 검토에서 확인해 기각(v3의 "FIC 와일드카드" 시나리오와 같은 유형의
    오류). 실재하는 위협인 그룹 경유 할당 검사(그룹 멤버십 0건)로 대체.
  - Option C를 기준선으로(A 없이) 채택: 문서에 명시되지 않은 동작에 설계 전체를
    의존시키는 것은 원칙 3 위반이라 채택하지 않는다.
- **Why chosen**: 워크로드 RG 잠금의 상속 부작용(무인 자동화 파괴)을 커스텀 역할
  기반 접근으로 해소한 뒤, 그 커스텀 역할 2종의 권한 목록을 "문서 하드코딩"에서
  "런타임 조회"(워크로드용)와 "실측 확정 델타"(state 데이터용)로 바꿔 built-in
  역할과의 불일치 재발을 구조적으로 막았다. 권한 불변식도 그룹 경유 할당까지
  포함한 7종으로 확장해 원칙 1이 실제로 커버하는 범위를 넓혔다. 다만 최종 Critic
  검토가 이 불변식의 조회 방식 자체(서비스 주체에 그룹 전개가 적용되지 않는
  `--include-groups`의 한계)와 `verify.sh`의 실행 주체 문제(Entra/Graph 검사가
  원칙 1과 충돌)를 새로 지적했고, 이번 v6에서 함께 반영했다.
- **Consequences**:
  1. 리소스 그룹을 CI가 아니라 사람이 bootstrap 시점에 만든다.
  2. CI 신원은 built-in `Contributor`가 아니라 커스텀 역할 2종(워크로드 RG용은
     런타임 조회 기반, state 데이터용은 고정 델타)을 쓴다 — 관리 오버헤드가 늘지만,
     워크로드용은 built-in 정의가 바뀌어도 다음 실행이 자동으로 따라간다.
  3. `notActions`는 deny 규칙이 아니다 — 이 역할들의 안전성은 전적으로 "CI 신원이
     다른 role assignment와 그룹 멤버십을 하나도 갖지 않는다"는 3절 시나리오 1의
     불변식에 의존한다. 그 불변식이 깨지면 커스텀 역할의 모든 제외가 동시에
     무의미해진다.
  4. bootstrap 실행자는 커스텀 역할 정의 권한(구독 Owner 또는 User Access
     Administrator)을 가져야 한다(6-1-2).
  5. **`verify.sh`는 CI 파이프라인의 공용 자격증명만으로 완전히 무인 실행할 수
     없다** — ARM 스코프 검사(불변식 (a)(b))는 Reader 권한으로 CI 분리 실행이
     가능하지만, Entra 디렉터리·Graph 앱 권한 검사(불변식 (c)~(g))는 원칙 1이 CI
     신원에 그 권한 자체를 금지하므로 사람 관리자가 수동으로 실행해야 한다(v6
     신규, 최종 Critic 검토 지적). 이것은 이 설계의 결함이 아니라 Azure 구조의
     귀결이지만, 원본 AWS 설계(같은 자격증명 평면에서 IAM read 가능)와의 명확한
     차이이므로 `bootstrap/README.md`에 그대로 기록한다.
  6. hub CI 신원이 dev 구독 내에도 최소 권한 role assignment를 가져야 하며, 정확한
     스코프는 6-0-e에서 확정한다(현재 미확정).
  7. `docs/naming/abbreviations/azure.md` 등재라는 교차 저장소 선행 작업이 새로 생겼다.
  8. 원칙 1은 "7종 권한 0건(그룹 멤버십 포함) + 크로스 구독 예외 1건"이라는
     실현 가능한 형태로 재정의됐다. "신원 자체가 얇다"는 AWS 원본의 정확한 속성은
     Option C가 채택되지 않는 한 여전히 없다.
  9. tfstate 보호의 실제 근거는 resource lock이 아니라 soft delete(blob·컨테이너) +
     versioning + 커스텀 데이터 역할의 권한 배제다. 컨테이너 이름 재사용 금지
     규칙과 함께 `bootstrap/README.md`에 명시해 오해를 막는다.
  10. Phase 2에서 AKS 배포가 `roleAssignments/write`를 요구하면, 이는 이 설계의
      재검토 트리거다(6-1-4).
- **Follow-ups**: 6절 그대로(0-a~0-f 선행, 이후 1-1~1-4). 추가: (i) Entra 그룹
  멤버십·PIM 관련 위협 모델은 이 설계 범위에서 그룹 멤버십 0건 검사로 닫았으나,
  Phase 2에서 CI 신원이 어떤 그룹에도 들어가지 않는다는 운영 규율이 유지되는지
  주기적으로 재확인한다. (ii) `DataActions`를 가진 커스텀 역할이 blob 컨테이너
  (하위 리소스) 스코프에 실제로 할당 가능한지는 공식 문서에서 명시적으로 확인하지
  못했다 — 6-0-c 게이트와 함께 승인 직후 가장 먼저 실측할 것을 권한다(불가능하면
  2절 전체가 재설계 대상이다).

## 6절 부록: 미해결 항목 (최종 Critic 검토 기준, 승인 전 검토 권장)

이 항목들은 v6에 반영했거나(①②) 반영 여부를 사용자가 판단해야 하는 것(③)이다.

① **(반영됨)** 그룹 경유 할당 우회 — 1절 원칙 1·3절 시나리오 1(g)·4절 Integration에
   그룹 멤버십 0건 검사로 반영.
② **(반영됨)** `verify.sh`가 원칙 1과 충돌 — 6-1-2·7절 Consequence 5에 한계로 기록.
③ **(권장, 미반영)** 워크로드 커스텀 역할의 `notActions`를 문서 하드코딩에서 런타임
   조회로 전환(1절에 이미 반영)했지만, **state 데이터 역할의 컨테이너 스코프 할당
   가능 여부** 자체는 이 세션에서 실측하지 못했다(위 Follow-ups (ii)). 이 실측
   결과에 따라 2절이 재설계될 수 있으므로, 실행 승인 전 30분 스파이크로 먼저
   확인하는 것을 권장한다.

## 추가 기록 (2026-09-04, workbench 배포 트리거 — 원칙 1 전면 개정, ralplan 밖·사용자 결정)

7절 Consequence 10("Phase 2에서 AKS 배포가 `roleAssignments/write`를 요구하면, 이는 이
설계의 재검토 트리거다")이 실제로 발동했다. `aks-workbench-v0.1.0`(iac-module-library) 소비
착수 중 identity·role assignment를 여전히 bootstrap에 둘지 다시 물었고, 그 답이 원칙 1
자체를 뒤집었다.

### 재검토 배경

사용자가 제기한 문제: "AWS는 STS role-chaining이라 다르다"는 v1~v6의 전제(0절)를 근거로
"Azure는 완충층이 없으니 사람이 나눈다"로 바로 갔는데, (1) Azure가 같은 목표를 다른
메커니즘으로 이미 지원하는지 확인하지 않았고 (2) AWS 원본(`eks-reference-infra`)이 실제로
무엇을 하는지도 재확인하지 않았다. bootstrap/Terraform 분리는 자동화의 이점(휴먼 에러
제거·추적성)을 스스로 깎아먹는 안티패턴이라는 지적이었다.

**조사 결과 3가지**(전부 공식 문서·소스코드 직접 확인, WebFetch 인용 포함):

1. **Azure ABAC 조건부 위임이 실재한다** — `Microsoft.Authorization/roleAssignments/write`에
   `condition`/`condition_version`(ABAC)을 걸어 "assign 가능한 RoleDefinitionId 허용목록"으로
   제한하는 기능이 GA, 무료(`learn.microsoft.com/azure/role-based-access-control/
   delegate-role-assignments-overview`). `azurerm_role_assignment`(이 프로젝트가 쓰는
   azurerm 5.x)가 `condition`/`condition_version` 인자를 이미 지원한다(provider 공식 문서
   확인). 이것만으로도 원칙 1의 "완충층이 없다"는 전제는 부분적으로 틀렸다 — **다만 이
   경로는 이번 결정(아래)에서 채택하지 않는다.**
2. **AWS 원본(`eks-reference-infra`) 실측 결과, 실행 Role은 이미 `AdministratorAccess`다**
   (`bootstrap/bootstrap.sh:199-203`, `242-246`, "D27-1 pattern"). v1~v6이 인용해 온 "AWS는
   신원 자체가 얇다"(0절)는 서술은 **입구 Role**에만 해당하고, 실제로 Terraform이 실행되는
   **실행 Role**은 IAM을 포함한 전권을 갖는다. 방어선은 권한의 크기가 아니라 "이 실행
   Role에 도달할 수 있는 경로가 입구 Role 신뢰 정책(GitHub OIDC `sub` claim, repo 단위) 하나뿐"이라는
   사실 하나였다.
3. **Azure는 이미 그 "도달 경로 하나" 방어선을 동등한 강도로 갖고 있다** — FIC(Federated
   Identity Credential)의 `subject`가 정확히 이 repo 하나로 스코프돼 있다(`<org>@<org_id>/
   <repo>@<repo_id>` 형식, 2026-08-27 AADSTS700213 정정 이력 참고, 위 「GitHub OIDC」절).
   AWS STS 임시 자격증명과 마찬가지로 Entra 토큰도 워크플로 실행당 federated 교환으로
   발급되는 세션 토큰이라 영구 secret이 아니다. 즉 "도달 경로를 하나로 좁힌다"는 AWS·Azure
   양쪽에서 이미 동등하게 성립하고, 다른 것은 "도달한 뒤 권한을 얼마나 주는가"뿐이었다 —
   그 축에서만 이 설계가 AWS보다 보수적으로 갔다.
   (참고: AWS도 `iam:PassRole`류 IAM 관리 권한은 `Resource`/`iam:PassedToService` 조건으로
   좁히는 관행이 있다(`docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_passrole.html`)
   — 이건 위 1의 Azure ABAC 조건과 구조적으로 대응한다. 그러나 **이 프로젝트의 실제
   sibling repo는 그 조건부 좁히기조차 쓰지 않고 그냥 `AdministratorAccess`를 붙인다** —
   사용자는 이 repo 자신의 실제 선례를 기준으로 삼기로 결정했다(아래).

### 결정: 원칙 1 폐기, AWS 원본과 완전 대칭

> **CI 신원의 권한 범위 자체는 더 이상 통제하지 않는다. 유일한 방어선은 그 신원에
> 도달할 수 있는 경로(FIC subject)를 정확히 하나의 GitHub repo로 좁히는 것이다.**
> hub·dev 신원 각각 자신의 **구독 전체**에 built-in `Owner`(또는 「RG 자기 삭제만 제외」
> 커스텀 변형, 아래 참고)를 부여한다. AWS `AdministratorAccess`(계정 전체 스케일)와
> 스코프 축에서 문자 그대로 대칭이다(2026-09-04, 사용자 확정 — RG 스코프로 남기는
> 대안도 제시했으나 "AWS와 완전히 대칭"을 명시적으로 택함).

이 결정으로 원칙 1(1절, "구독·관리 그룹 스코프 role assignment 0건 ... 권한은 RG 경계를
넘지 않는다")은 **폐기**된다. v1~v6 본문은 "그 시점에 무엇이 합의됐는가"를 보존하기 위해
고치지 않는다(2026-08-27 추가 기록과 같은 방침).

### 무엇이 남고 무엇이 뒤집히는가

7종 불변식(현재 6종, 2026-08-27에 (b) 삭제됨 — 위 참고) 각각의 운명:

| 불변식 | 이전 | 이후 |
|---|---|---|
| (a) 구독 스코프 role assignment 0건 | 유지 | **뒤집힘** — "구독 스코프에 Owner(또는 변형) 역할 할당이 정확히 1건 존재"로 재정의(음성 검사 → 양성 검사) |
| (구 b) 관리 그룹 스코프 0건 | 2026-08-27 삭제됨 | 그대로 삭제 상태 유지(무관한 축) |
| (c) Entra 디렉터리 역할 0건 | 유지 | **그대로 유지, 오히려 더 중요해짐** — admin급 ARM 권한과 별개로 Entra 자체 관리 권한까지 갖는 건 이 결정 범위 밖 |
| (d) Microsoft Graph 앱 권한 0건 | 유지 | **그대로 유지** — 같은 이유 |
| (e) 정적 자격증명 0건(FIC만 인증 경로) | 유지 | **그대로 유지 — 이제 이게 방어선의 전부이므로 가장 중요한 불변식이 된다** |
| (f) FIC 전 필드(subject·issuer·audience) 완전 일치 | 유지 | **그대로 유지, 방어선의 핵심** |
| (g) 그룹 멤버십(transitive) 0건 | 유지 | **그대로 유지** — admin 권한을 가진 신원이 그룹 경유로 더 얹히는 경로까지 막을 이유는 여전히 있음(우회가 아니라 권한이 여러 겹으로 불투명해지는 것 자체를 막는다) |
| 워크로드 역할 `notActions` = Contributor 런타임 조회 + `resourceGroups/delete` | 유지 | **삭제** — Owner 기반으로 교체(아래) |

**정리**: 폐기되는 건 "권한 크기를 좁힌다"는 축 하나뿐이다. "이 신원에 누가 도달할 수
있는가"를 지키는 불변식 4종((c)(e)(f)(g))은 전부 그대로 남고, 오히려 지금부터가 진짜
방어선이라 더 신중하게 지켜야 한다.

### 워크로드 역할 재정의

```
Actions:    ["*"]
NotActions: ["Microsoft.Resources/subscriptions/resourceGroups/delete"]  (권장, 아래 참고)
스코프:      구독 전체(변경 전: 워크로드 RG 하나)
```

- `bootstrap.sh`의 "Contributor의 notActions를 런타임 조회"(1절, v4~v6이 세 번 틀렸던 그
  값) 로직 자체가 **불필요해진다** — Owner는 애초에 `NotActions: []`라 조회할 대상이
  없다. v4~v6이 반복해서 틀렸던 실수 클래스가 구조적으로 사라진다는 게 이 변경의 부수
  이득이다.
- `resourceGroups/delete` 제외는 **보안 경계가 아니라 사고 방지 안전망으로 격을 낮춰
  유지를 권장**한다 — "실수로 `tofu destroy`가 RG 자체를 지우는" 흔한 사고를 막는
  값싼 장치이지, admin 신원이 압축됐을 때의 방어선은 아니다(Owner는 어차피 RG 안의
  모든 리소스를 지울 수 있다). 유지 여부는 구현 시 재확인.
- **state RG 잠금(`CannotDelete`)의 성격이 바뀐다.** 지금까지는 "Contributor의
  notActions가 Authorization 쓰기·삭제를 막아 CI가 스스로 못 푼다"(1절, 3-3)는
  보안 경계였다. Owner는 잠금 해제(`Microsoft.Authorization/locks/delete`)도 갖는다
  — **이 잠금은 이제 CI 신원 압축 시나리오의 방어선이 아니라 사람의 실수 방지용
  안전망으로 격이 내려간다.** tfstate의 실제 보호는 이미 7절 Consequence 9가 명시한
  대로 resource lock이 아니라 **soft delete + versioning + (state 데이터 역할이
  살아있다면 그 권한 배제)**다 — 이 축은 이번 결정과 무관하게 그대로 유효하다. 다만
  "권한 배제"라는 표현 자체가 CI가 admin이 되는 순간 무의미해지므로, tfstate 보호는
  최종적으로 **"즉시 영구 삭제는 안 된다(soft delete 30일), 사고 나도 복구 가능하다"는
  한 층으로 수렴**한다는 것을 명시적으로 인지한다.
- state 데이터 역할(2절, Storage Blob Data Contributor 델타)은 **이제 그 자체로 무의미**
  하다 — 워크로드 역할이 이미 구독 전체 Owner이므로 별도 role assignment가 불필요.
  다만 즉시 삭제하지 말고 「마이그레이션 체크리스트」에서 함께 정리한다(작동 중인
  role assignment를 건드리는 건 실제 Azure 상태 변경이라 신중히).

### identity·role assignment의 bootstrap 이관 가능성

CI 신원이 이제 `Microsoft.Authorization/roleAssignments/write`를 가지므로, 지금까지
"구조적으로 bootstrap에서만 만들 수 있었던" 산출물을 **Terraform(live root)으로 옮길 수
있게 된다**:

- `live/hub/aks`의 AKS identity + `Network Contributor` role assignment(현재
  `bootstrap.sh`의 `ensure_aks_identity`, 위 「AKS 클러스터용 identity·권한」절) — 이미
  동작 중이라 지금 당장 옮길 필요는 없다. 옮기면 "서브넷이 아직 없으면 건너뛴다"는
  현재의 죽은 경로(bootstrap이 VNet apply보다 먼저 실행돼 생기는 순서 의존, 위 절
  ⚠️ 참고)가 Terraform의 자연스러운 리소스 의존성으로 해소된다는 이점이 있다.
- **`live/hub/workbench`(신규, 이번 세션의 원래 목적)** — `aks-workbench` 모듈이 요구하는
  `identity_id`(user-assigned identity)와 「전제 role assignment」 3종(VM 로그인,
  AKS Cluster User Role, 필요시 RBAC 역할)을 **bootstrap 없이 처음부터 Terraform으로**
  만들 수 있다. 이게 이 결정의 가장 직접적인 실익이다.
- ⚠️ `azurerm_role_assignment`로 "방금 만든 identity"에 role을 붙일 때는
  `skip_service_principal_aad_check = true`를 쓴다 — AAD 복제 지연으로 인한
  `PrincipalNotFound`를 provider가 흡수한다(공식 문서: "If the principal_id is a newly
  provisioned Service Principal set this value to true..."). `bootstrap.sh`가 지금까지
  bash 재시도 로직(`retry_on_replication_delay`, 위 2026-08-27 기록)으로 직접 흡수해
  온 문제를 provider가 대신 해결해 주는 것 — Terraform 이관의 실질적 이득이다.
- `Microsoft.ContainerService` 등 리소스 프로바이더 등록은 여전히 **구독 스코프**
  액션(`*/register/action`)이라 이 변경과 무관하게 계속 논의 대상이다 — CI가 이제
  구독 전체 Owner이므로 **오히려 이제는 CI가 직접 RP 등록도 할 수 있어**, "사람이
  사전에 처리해야 한다"던 위 절의 제약(⚠️ Microsoft.ContainerService 등록을 사람이
  미리 처리하는 이유)도 함께 재검토 대상이 된다(마이그레이션 체크리스트 참고).

### Consequences (추가분)

11. 원칙 1(권한 축소 축)은 폐기되고, 방어선은 원칙 1의 나머지 절반(신뢰 정책 하나로
    좁힌다)에 전적으로 집중된다. FIC subject 완전 일치(불변식 f)가 사실상 이 설계
    전체의 유일한 방어선이 된다 — 이 검사가 실패하거나 우회되면 더 이상 "권한이
    좁아서 괜찮다"는 2차 방어선이 없다.
12. state RG 잠금·워크로드 역할의 `resourceGroups/delete` 제외는 보안 경계에서
    사고 방지 안전망으로 격이 내려간다. tfstate의 실제 보호는 soft delete +
    versioning 한 층으로 수렴한다(위 참고).
13. `bootstrap/README.md`의 "AWS 원본과 완전히 동등하지는 않다"(원본 서문, 1줄)는
    문구가 이제 **"완전히 동등하다(권한 스코프 축에서)"**로 바뀐다 — 유일하게 남는
    차이는 Azure에 AWS `AssumeRole`류 2단 체인 자체가 없어 **입구/실행이 물리적으로
    분리된 신원 2개가 아니라 신뢰 정책(FIC)이 그 역할을 대신한다**는 구조적 차이뿐이다.
14. `CLAUDE.md` 2절의 관련 문구를 재작성한다(이 세션에서 즉시 반영, 아래).
15. **Phase 2 이후 재검토 트리거를 다시 정의한다**: 이제 "CI 신원의 FIC subject에
    와일드카드가 들어가거나, 그 subject가 가리키는 GitHub repo/브랜치 보호 규칙이
    완화되는 것"이 이 설계의 다음 재검토 트리거다(이전 트리거였던
    `roleAssignments/write` 요구는 이번에 해소됨).

### 마이그레이션 체크리스트 (실행 전 별도 승인 — 이 세션은 설계·CLAUDE.md까지만)

이 추가 기록은 설계 확정이다. 아래는 다음 실행 세션이 순서대로 처리할 항목이며,
**이미 배포된 hub·dev의 실제 role assignment를 바꾸는 작업**이라 신중한 순서가 필요하다.

1. `bootstrap/config.sh`: `workload_role_definition_json`을 Owner 기반(Actions:`["*"]`,
   NotActions: `resourceGroups/delete`만)으로 교체, assignable scope를 워크로드 RG →
   구독으로 확장. Contributor 런타임 조회 로직 제거.
2. `bootstrap.sh`: workload role assignment 생성 시 스코프를 구독으로. state 데이터
   역할·그 role assignment는 무의미해지므로 제거 여부 결정(기존 role assignment 삭제는
   되돌릴 수 있는 작업이므로 먼저 실행, RG 스코프 커스텀 역할 정의 자체는 뒤에 정리).
3. `verify.sh`: 불변식 (a)를 "구독 스코프에 워크로드 역할 할당 정확히 1건 존재"로
   재정의(반전). notActions 완전일치 세부 검사를 Owner 기반 단순 비교로 교체.
4. `bootstrap/README.md`: 「기대 상태」·「커스텀 RBAC 역할 2종」·「AKS 클러스터용
   identity·권한」 절 갱신(권한 스코프 변경 반영, AKS identity/role assignment를
   Terraform 이관 여부에 따라 이 절 자체를 축소/삭제할 수도 있음).
5. hub·dev 각각 실제 재부트스트랩(멱등 수렴 확인, 3-1·3-2 재검증) — **실제 Azure
   상태 변경, 사용자 승인 필수**.
6. `CLAUDE.md` 0·2절(이 세션에서 텍스트 반영, 아래 참고).
7. `live/hub/workbench`(신규): identity+role assignment를 처음부터 Terraform으로
   포함해 설계(RALPLAN 별도 라운드, 이번 세션 원래 목적).
8. (선택, 급하지 않음) `live/hub/aks`의 기존 bootstrap 산출물(identity+role
   assignment)을 Terraform으로 이관 — 이미 동작 중이므로 우선순위 낮음.

### 실행 결과 (2026-09-04, hub 대상 실제 재부트스트랩 — 체크리스트 1~5번 완료)

체크리스트 1~4번(코드)을 반영한 뒤 hub 대상으로 실제 재부트스트랩(5번)을 실행하며
버그 2건을 발견·수정했다. 둘 다 이 저장소의 다른 bash 스크립트를 짤 때도 재발
가능한 일반적 교훈이라 기록해 둔다.

1. **az CLI `role definition update`가 `create`와 다른 키를 요구한다(azure-cli
   2.89.1 실측).** `az role definition create --role-definition <json>`은 카멜케이스
   변환 후 `role_definition.get("name")`을 읽지만, **`update`(id가 있는 경우)는
   같은 변환 후 `role_definition["roleName"]`을 직접 인덱싱**한다(az CLI 소스
   `azure/cli/command_modules/role/custom.py`의 `_create_update_role_definition`
   확인). 이 저장소는 `Name` 키만 써 왔는데(`config.sh`의 `*_role_definition_json`),
   그동안 실제로는 `create` 경로만 타 왔고(역할이 한 번도 실제로 갱신된 적이 없어서)
   이번 마이그레이션에서 처음으로 `update` 경로를 타면서 `KeyError: 'roleName'`으로
   드러났다. `Name`과 나란히 `RoleName`(같은 값)을 추가해 두 경로 모두 만족시켰다
   (`workload_role_definition_json`·`spoke_peer_role_definition_json`). 교훈: az CLI의
   같은 명령군(`create`/`update`) 서브커맨드가 내부적으로 다른 스키마를 기대할 수
   있다 — 소스가 최종 근거다(공식 문서는 보통 `create` 예시만 보여준다).
2. **bash `VAR=val cmd <<<"$(fn)"` 접두사 할당이 `fn` 내부까지 새어 들어간다(실측,
   bash 3.2·5.x 공통 — POSIX 단순 명령의 접두사 할당은 그 명령의 인자·리다이렉션
   전개 전체에 적용된다는 표준 동작이지, 이 저장소가 여러 번 문서화한 macOS bash
   3.2 특유의 버그가 아니다).** `verify.sh`가 `check_subscription_scope_assignments`의
   다중 반환값을 `IFS='|' read -r a b c <<<"$(check_subscription_scope_assignments)"`
   한 줄로 파싱하도록 짰는데, 이 한 줄 전체가 "하나의 단순 명령"이라 `IFS='|'`
   접두사가 리다이렉션 대상(`$(...)`) 평가 동안에도 유효했다 — 그 결과 함수
   내부의 `for sub in $subs`(기본 IFS로 개행 분리를 기대)가 `|`로만 쪼개져, 구독
   2개가 한 토큰으로 뭉쳐 `az role assignment list --subscription`이
   `Subscription '<두 GUID가 개행으로 붙은 문자열>' not found`로 깨졌다(hub·dev
   두 구독이 모두 보이는 이 세션에서 처음 드러남 — 이전에는 실행자 계정이 구독을
   하나만 보던 시기가 많아 단일 원소 순회로 우연히 안 걸렸을 가능성이 높다).
   해법: 명령 치환을 먼저 순수 변수 대입으로 캡처한 뒤, **이미 캡처된 문자열**에만
   `IFS='|' read`를 적용한다(`sub_scope_result="$(fn)"` → `IFS='|' read ... <<<
   "$sub_scope_result"`). 교훈: 여러 값을 반환하는 함수를 `IFS=구분자 read
   <<<"$(fn)"`로 직접 파싱하지 않는다 — 항상 캡처와 파싱을 두 줄로 분리한다.

3-1(멱등성)·3-2(음성 테스트, 이번 마이그레이션이 바꾼 두 코드 경로 — 커스텀 역할
정의·구독 스코프 role assignment에 고의 drift 주입) 전 과정을 hub 대상으로 실행해
통과 확인(DRIFT 2건 → 변경 2건 → drift 없음 → 변경 0건).

**dev(spoke) 재부트스트랩도 같은 세션에서 이어서 실행, 세 번째 버그 발견·수정.**

3. **역할 정의의 `AssignableScopes`를 update로 바꾼 직후 role assignment 생성이
   `RoleAssignmentScopeNotAssignableToRoleDefinition`으로 거부됐다(dev 실측,
   hub에서는 우연히 안 걸림).** ARM이 `AssignableScopes` 변경을 아직 전파하지
   않은 상태에서 새 스코프로 role assignment를 시도한 것 — 이전에도 여러 번
   나온 "역할 정의 변경 직후 ARM 캐시 전파 지연" 클래스의 새 얼굴이다(2026-08-27
   추가 기록의 "Role doesn't exist" 케이스와 근본 원인은 같고 증상만 다르다).
   이 클래스가 이번에 처음 `AssignableScopes` 자체의 변경으로도 발현된 이유는,
   그 전까지는 역할 정의가 갱신될 때 `Actions`/`NotActions`만 바뀌고
   `AssignableScopes`는 늘 그대로였기 때문이다(이번 마이그레이션이 RG 스코프
   →구독 스코프로 처음 바꿨다). `retry_on_replication_delay`(config.sh)의
   재시도 대상 오류 문자열에 `RoleAssignmentScopeNotAssignableToRoleDefinition`
   을 추가해 흡수했다 — 재시도 2회(약 10초) 만에 해소, dev도 3-1까지 완전
   통과(변경 1건 → 변경 0건).

**hub·dev 양쪽에 남아있던 구식(RG 스코프) 커스텀 역할 정의 자체는 아직 안 지웠다.**
`az role definition update`는 정의를 같은 ID로 **제자리 갱신**하므로(새로 안
만든다), 정의 자체는 이미 새 것(구독 스코프 Owner 등가)으로 바뀐 상태다 — 남아있는
건 정의가 아니라 **role assignment**뿐이었다. hub·dev 각각에서 다음 두 orphan
role assignment를 확인 후 삭제했다(둘 다 되돌릴 수 있는 작업, 정확한 대상 ID로
`az role assignment delete --ids`만 사용, 이름 기반 삭제는 쓰지 않았다):

- **구식 RG 스코프 workload role assignment**(이번 마이그레이션 이전에 만들어진
  것 — 정의는 제자리 갱신됐지만 이 RG 스코프 assignment 자체를 스크립트가 지운
  적이 없어 계속 남아있었다. 구독 스코프 assignment가 이미 상위 호환이라
  위험하진 않았지만 orphan 상태였다).
- **state 데이터 역할 role assignment**(위 본문 결정대로 역할이 무의미해져 —
  역할 **정의**는 사람이 나중에 정리하기로 하고 이번엔 assignment만 지웠다).

두 저장소 다 state RG에 `CannotDelete` 잠금이 걸려 있어 README 문서화된 절차(사람이
잠금 해제 → 변경 → `bootstrap.sh` 재실행으로 잠금 재적용)를 그대로 따랐다. 최종
상태: hub·dev 둘 다 `verify.sh` drift 없음, `bootstrap.sh` 재실행 변경 0건.

**남은 정리(선택, 급하지 않음)**: `aks-ref-bootstrap-state-data-hub`·
`aks-ref-bootstrap-state-data-dev` 역할 **정의**는 각 구독에 여전히 남아있다(더
이상 어떤 role assignment도 안 가리키는 상태). `az role definition delete`로
지울 수 있으나 이번 세션 범위 밖으로 미뤘다.

### 정정 (같은 날 — state 데이터 역할 삭제는 잘못된 판단이었다)

위 본문("워크로드 역할이 이제 state RG·컨테이너까지 전부 포괄하므로 state 데이터
역할은 무의미해져 제거했다")은 **틀렸다.** 사용자가 "vnet·aks 같은 소비 root에
이번에 지운 권한 리소스를 다시 추가할 필요는 없냐"고 물어서 재검토하다가
직접 실측으로 확인했다:

```
$ az role definition list --name Owner --query "[0].permissions[0]"
{ "actions": ["*"], "dataActions": [], ... }
```

**Azure RBAC는 control-plane(`Actions`)과 storage blob data-plane(`DataActions`)이
완전히 분리된 축이고, `Owner`조차 `dataActions: []`다.** 이 backend는
`use_azuread_auth = true`를 쓰므로 blob(tfstate 파일 자체) 읽기·쓰기는 반드시
`DataActions`를 가진 역할이 별도로 필요하다 — 워크로드 역할을 아무리 넓혀도
control-plane 축(리소스 그룹·계정·컨테이너 자체의 존재)만 커버할 뿐, 그 안의 blob
데이터에는 손을 못 댄다. state 데이터 역할을 지운 채로 뒀다면 hub·dev 모든 live
root의 다음 `tofu init`/`plan`/`apply`가 tfstate blob 접근 실패로 깨졌을 것이다.

**원인**: "control-plane 권한이 `*`로 넓으면 data-plane도 당연히 포함된다"는
검증 없는 가정. 실제로는 정반대이고, 이건 Azure RBAC를 다룰 때 반복적으로
틀리기 쉬운 지점이다(예: 이 프로젝트가 처음부터 `use_azuread_auth`를 택하고
"계정 키로 RBAC 우회 차단"이라고 CLAUDE.md 2절에 못박아 둔 것 자체가, 애초에
data-plane 접근을 RBAC로 명시 통제하겠다는 의도였다 — 그 의도를 이번 재검토
과정에서 스스로 어길 뻔했다).

**조치**: `state_data_role_definition_json`(config.sh)·`ensure_custom_role`/
`ensure_role_assignment` 호출(bootstrap.sh)·`check_state_data_role`(verify.sh)을
전부 원복하고, hub·dev 양쪽에 실제로 재적용(role assignment 재생성, 3-1 재확인
— 둘 다 `=== drift 없음 ===`/`=== 변경 0건 ===`). 워크로드 역할의 스코프를
RG→구독으로 넓힌 것(이번 재검토의 핵심 결정)은 그대로 유지한다. 이번 정정은
그 결정 자체가 아니라 "state 데이터 역할이 이제 필요 없다"는 **부수 결론**만
틀렸던 것이다. `bootstrap/README.md`도 함께 정정했다.

## 추가 기록 (2026-09-04, AKS 컨트롤 플레인 identity·role assignment를 bootstrap →
`live/hub/aks` Terraform으로 이관 — ralplan 밖, 사용자 결정)

사용자가 "`id-demo-hub-krc-aks-01`을 왜 bootstrap이 만드는지, MS 기본값(노드 RG
전체 Contributor)보다 좁게 간 이유는 무엇인지" 질문 → 답변 과정에서 이게 정확히
지난 세션들에서 반복해 온 "bootstrap/Terraform 분리는 그 이유가 사라지면 재검토
대상"이라는 원칙의 다음 적용 지점임을 확인. 좁은 스코프 자체는 실수가 아니라 MS
공식 문서(`concepts-network-cni-overview`)의 BYO-VNet 최소 권고를 정확히 따른
것("at least Network Contributor permissions on the subnet") — 다만 **왜 여전히
bootstrap이 만드는가**는 옛 제약("CI에 roleAssignments/write를 주지 않는다")이
사라진 지금 순수 관성이었다.

**결정**: `live/hub/aks` destroy → 기존 클러스터를 완전히 파기하고 identity·role
assignment도 처음부터 Terraform으로 다시 만든다. 대안으로 검토했던 `import` 블록
(기존 identity를 Terraform state에 그대로 편입)은 MS 공식 문서 경고
("changing identity type... this process can take several hours")를 근거로
기각했다 — 이미 살아있는 프로덕션 클러스터라면 `import`가 맞는 선택이었겠지만,
GitOps 워크로드가 아직 없는 데모 클러스터라 destroy 비용이 낮아 더 단순한 경로를
택했다(사용자 명시 결정).

**실행 순서**(전부 완료):
1. GitHub Actions `deploy-hub-aks.yml`을 `workflow_dispatch`(`action=destroy`,
   `confirm="destroy live/hub/aks"`)로 실행 — 성공(`az aks show`로 실물 삭제 확인).
2. bootstrap이 만들었던 구식 identity(`id-demo-hub-krc-aks-01`)·role
   assignment(Network Contributor @ aks-node 서브넷)를 사람이 정리
   (`az identity delete`·`az role assignment delete`) — Terraform이 같은 이름으로
   새로 만들 때 이름 충돌·ARM PUT 멱등성에 기대는 모호함을 피하기 위해서다.
3. `bootstrap.sh`/`config.sh`/`verify.sh`에서 AKS identity·role assignment 관련
   코드 전부 제거(`ensure_aks_identity`·`ensure_aks_node_subnet_role`·
   `AKS_IDENTITY_NAME` 등 상수·`aks_node_subnet_id()`·`check_aks_identity`·
   `check_aks_node_subnet_role`·`AZURE_HUB_AKS_IDENTITY_ID` 출력). RP 등록
   (`ensure_container_service_provider`)만 남겼다 — 저빈도 1회성 작업이라 옮길
   실익이 낮다는 별개 판단(identity 이관과 묶지 않음).
4. `live/hub/aks/main.tf`에 `azurerm_user_assigned_identity.aks`·
   `azurerm_role_assignment.aks_node_subnet`을 신설하고, `module.aks_cluster`의
   `identity_id`를 `var.aks_identity_id`(제거)에서 `azurerm_user_assigned_identity.
   aks.id`로 교체. 역할 할당은 `skip_service_principal_aad_check = true`로
   (방금 만든 identity라 AAD 복제 지연 가능 — provider가 흡수, bootstrap.sh가
   예전에 bash 재시도로 흡수하던 문제의 대체). `module.aks_cluster`에
   `depends_on = [azurerm_role_assignment.aks_node_subnet]` 명시(모듈이 role
   assignment 리소스를 참조하지 않아 암묵적 의존이 안 생긴다 — 없으면 옛
   bootstrap의 "순서 의존" 문제가 Terraform 그래프에서 그대로 재현된다).
5. `.github/workflows/deploy-hub-aks.yml`에서 `TF_VAR_aks_identity_id`·그
   주입원이던 사전조건 서술 제거.
6. `bootstrap/README.md`「AKS 클러스터용 identity·권한」절·「출력값의 행선지」
   표 갱신. `tofu validate`(backend 없이, `-backend=false`)·`tofu fmt -check`
   로컬 통과 확인.

**남은 작업**: GitHub repo 변수 `AZURE_HUB_AKS_IDENTITY_ID`는 미사용 상태로 남아있다
(삭제는 후속). `live/hub/aks` 재배포(apply)·실물 확인·커밋은 이 기록 다음 단계에서
진행한다.

## 추가 기록 (2026-08-27, 실제 Azure hub 부트스트랩 검증 세션 — ralplan 밖, 사용자 결정)

v6 승인 이후 사용자가 실제 Azure 자격증명을 확보해 hub 대상으로 `bootstrap.sh`/
`verify.sh`를 처음 실행하며 발견한 것들. ralplan 재실행 없이 사용자가 그 자리에서
확정했다.

- **③(위 Follow-ups, 미반영 항목) 해소**: state 데이터 역할의 컨테이너 스코프
  role assignment가 **실제로 가능함을 확인**했다(`aks-ref-bootstrap-state-data-hub`
  role assignment가 `.../containers/tfstate` 스코프에 정상 생성됨, 2026-08-27
  hub 1차 부트스트랩). 30분 스파이크 없이 실제 실행으로 바로 확인됐다.
- **불변식 (b)(관리 그룹 스코프 role assignment 0건) 삭제**: `check_mg_scope_assignments`
  실행 중 `Microsoft.Management/managementGroups/read` 권한 부족(`AuthorizationFailed`,
  테넌트 루트 관리 그룹 스코프)으로 발견됐다. 사용자가 "이 검사가 OIDC 배포에 실제로
  필요한가"를 물었고, 확인 결과 **필요 없다** — 이 설계의 role assignment는 항상
  RG·컨테이너 스코프에만 생성되고 관리 그룹은 배포 경로 어디에도 등장하지 않는다.
  (b)는 순전히 "아무도 몰래/실수로 이 SP에 관리 그룹 스코프 권한을 얹지 않았다"를
  증명하는 감사용 불변식이었는데, 그 증명 자체가 README 1절이 명시한 실행 전제(구독
  Owner/User Access Administrator)보다 훨씬 넓은 테넌트 루트 권한을 **검증자에게만**
  요구하는 불균형이 있었다. 사용자가 이 전제를 과설계(over-engineering)로 판단해
  삭제를 확정했고, 코드(`verify.sh`의 `check_mg_scope_assignments` 전체)와 현재
  상태 문서(`bootstrap/README.md`, `CLAUDE.md`)에서 7종 → 6종으로 반영했다. 이
  문서(설계 이력)는 v6이 실제로 7종으로 합의했다는 사실을 보존하기 위해 본문은 고치지
  않는다.
- **버그 2건 수정**(코드에서 실측으로 발견, `bootstrap/config.sh`·`bootstrap.sh`):
  (1) `retry_on_principal_not_found`(→ `retry_on_replication_delay`로 개명)가
  SP 복제 지연만 재시도 대상으로 잡고 있었는데, 커스텀 역할 정의 생성 직후의 ARM
  캐시 전파 지연("Role '...' doesn't exist.")은 재시도 대상이 아니어서 hub 1차
  부트스트랩이 `exit 2`로 죽었다 — 재시도 조건에 추가. (2) `ensure_custom_role`이
  역할 존재를 직접 확인한 직후에도 재조회가 빈 배열을 돌려주는 경우(같은 종류의 ARM
  캐시 전파 지연, `--name` 단건 조회와 `--custom-role-only` 전체 조회가 같은 시점에
  다른 결과를 냄)를 "불일치"로 오판해 매 실행마다 불필요한 `role definition update`를
  일으켜 3-1 멱등성 수용 기준("두 번째 실행은 changed=0")을 깼다 — 존재가 이미 확인된
  경우 재조회를 최대 5회 재시도하는 `role_definition_list_retry`를 `config.sh`에
  신설해 흡수했고, `update` 호출에 `id`를 명시해 CLI가 이름만으로 애매하게 찾지 않게
  했다.
- 3-1(멱등성)은 수정 후 hub 대상으로 완전히 통과 확인(변경 0건). 3-2(음성 테스트)도
  같은 세션에서 hub 대상으로 완전히 통과 확인(DRIFT 2건 → 변경 2건 → drift 없음 →
  변경 0건). (c)~(g) 검사는 사람 관리자 자격증명(이 세션 계정)으로 전부 통과했다 —
  관리 그룹 스코프(옛 (b))와 달리 이 계정 권한으로 충분했다.
- **네이밍 약어 등재 + hub 재생성 (같은 날, 2차 라운드)**: 사용자가 "todo-" placeholder
  네이밍을 그대로 두고 검증부터 끝낸 것을 지적, `iac-module-library`의
  `docs/naming/abbreviations/azure.md`에 `rg`(Resource Group)·`st`(Storage Account,
  CAF 표에서 그대로 채택)·`entapp`(App Registration, CAF 표에 없어 신규 제안 — CAF
  표는 ARM provider namespace가 있는 리소스만 다뤄 Entra 객체인 App Registration은
  애초에 그 표의 대상이 아니었다)를 등재했다. `config.sh`의 네이밍 함수만 교체하고
  (사용처는 안 건드림, 원래 설계대로), hub의 기존 리소스 전체(RG 2개·App
  Registration·커스텀 역할 2종 — 삭제 후 재생성 필요, App Registration/역할
  정의/FIC는 사실 이름만 바꿀 수도 있었지만 한꺼번에 정리했다)를 지우고 새 이름으로
  3-1·3-2를 처음부터 다시 통과시켰다.
- **버그 3번째**: 재생성 2차 실행에서 `RoleDefinitionWithSameNameExists`로
  `bootstrap.sh`가 죽었는데 `verify.sh`는 같은 순간 "drift 없음"이라고 확인했다 —
  `ensure_custom_role`의 **최초** 존재 확인 조회(위 버그 (2)에서 고친 "존재 확인 후
  재조회"가 아니라, 그 앞의 첫 조회)가 여전히 재시도 없는 단발 호출이었다.
  `role_definition_list_retry`를 최초 조회에도 적용해 이 구간 자체를 하나로
  합쳤다. 이어서 `ensure_role_assignment`(bootstrap.sh)·`check_role_assignment_exists`
  (verify.sh)가 `roleDefinitionName`(role assignment가 조회 시점에 역할 정의 쪽과
  조인해서 채우는 값이라 방금 만들거나 갱신한 직후엔 null일 수 있다)으로 필터링해
  실제로 존재하는 role assignment를 "부재"로 오판, 불필요한 재생성을 유발한 것도
  같은 근본 원인(join 지연)의 다른 얼굴이었다 — 조인이 필요 없는 `roleDefinitionId`
  필터로 교체해 두 스크립트 모두 고쳤다.

## 변경 이력 (v5 → v6, Critic 최종(3차) 검토 반영, ralplan 종료)

- CRITICAL: `--include-groups`가 서비스 주체에 작동하지 않아 그룹 경유 할당이
  탐지되지 않음 → 불변식 (g)를 "그룹 멤버십 0건" 검사로 재정의, 4절 Integration
  조회 순서 정정. 1절 원칙 1·Option A, 3절 시나리오 1.
- MAJOR: PIM eligible 할당은 서비스 주체·관리 ID에 애초에 생성 불가(v3의
  와일드카드 시나리오와 같은 유형의 오류) → 불변식 (g)에서 삭제, 그룹 멤버십
  검사로 대체.
- MAJOR: 워크로드 커스텀 역할의 `notActions`가 v4(8개)·v5(10개) 모두 실제
  Contributor 값(실측 시점 11개)과 불일치 → 문서 하드코딩을 폐기하고
  `bootstrap.sh`/`verify.sh`가 매 실행 시 런타임 조회하는 방식으로 전환. 같은
  오류가 3버전 연속 재발한 것을 구조적 원인으로 진단(7절 ADR Alternatives).
- MAJOR: `verify.sh`가 Reader 권한만으로 CI에서 완전 무인 실행 가능하다는 서술이
  원칙 1(Graph 권한 0건)과 충돌 → ARM 스코프 검사만 CI 분리, Entra/Graph 검사는
  사람 관리자 수동 실행으로 6-1-2·7절 Consequence 5에 명시.
- Minor: E2E 항목 5에 `--auth-mode login` 누락 시 `allowSharedKeyAccess=false`와
  충돌해 오진 가능 → 명시.
- Minor: 6-0-e의 "리소스 수준 커스텀 역할" 표현은 이미 v5에서 정정됨(변경 없음).
- 미반영(권장): state 데이터 역할의 컨테이너 스코프 할당 가능 여부 실측 — 6절
  부록 "미해결 항목" ③으로 남김.
- ralplan 최대 반복(5회) 도달 → consensus 루프 종료, 계획을 `pending approval`로
  마감.

## 변경 이력 (v4 → v5, Architect 3차 검토 반영)

- 워크로드 커스텀 역할이 Contributor보다 넓음(v4의 3개 제외 목록이 실제 8개
  `notActions`에 크게 못 미침) → Contributor `notActions` 전체 + RG 삭제 제외로
  재정의. 1절 Option A, 7절 ADR Alternatives·Consequences.
- state 데이터 커스텀 역할이 첫 apply를 실패시킴(`blobs/add/action`·
  `containers/read` 누락, `containers/delete`를 data-plane으로 오분류) → 정확한
  델타(`Storage Blob Data Contributor - containers/delete`)로 재정의, 컨테이너
  재사용 금지 규칙 추가. 2절.
- 불변식 6종에 PIM eligible 할당 누락 → 7종으로 확장. 1절 원칙 1·Option A, 3절
  시나리오 1, 4절 Integration.
- 시나리오 4(c)의 검사가 "포함 여부"라 Contributor보다 넓어지는 오류를 못 잡음 →
  "집합 완전 일치"로 정정. (d) 신설(state 데이터 역할 최소 기능 검증).
- 4절 E2E에 state 데이터 역할의 positive/negative 쌍 부재 → 항목 5 신설.
- state RG 잠금이 RBAC 할당 삭제도 막아 재실행 자체가 불가능 → 5절에 잠금 해제/
  재적용 절차 신설.
- 6-0-e의 "리소스 수준 커스텀 역할" 표현이 Azure 비권장 패턴으로 오독될 수 있음 →
  AssignableScopes와 할당 스코프를 구분해 재서술.
- bootstrap 실행자의 커스텀 역할 정의 선행 권한(`roleDefinitions/write`) 누락 →
  6-1-2에 명시.

## 변경 이력 (v3 → v4, Critic 2차 검토 반영)

- C1(최대 결함, 워크로드 RG 잠금이 상속되어 무인 자동화 파괴) → 잠금을 state RG로
  한정, 워크로드 RG는 `resourceGroups/delete` 제외 커스텀 역할로 자기 삭제만 차단.
  1절 Option A, 7절 ADR Alternatives·Consequences, 4절 E2E 항목 4 재작성.
- C2(컨테이너 삭제 경로 누락, state 전량 소실 가능) → CI 데이터 역할에서
  `containers/delete` 제외, 컨테이너 소프트 삭제 추가, "state 보호의 실제 근거" 서술
  정정. 2절, 7절 Consequence 6.
- C3(불변식 4종에 정적 자격증명·FIC 전 필드 누락) → 6종으로 확장(App/UAMI credential
  0건, FIC 완전 일치). 1절 원칙 1·Option A, 3절 시나리오 1, 4절 Integration, 7절.
- M1(테넌트 축 미검증) → `EXPECTED_TENANT` 신설. 1절 Option A, 3절 시나리오 3, 5절
  exit code.
- M2(Option C 2차 조건 (ii)가 자기모순, 방어 효과 0) → "상시 등록"을 "평시 미등록 +
  장애 시 재등록"으로 수정, "무중단"을 "수 분 내 복구"로 완화.
- M3(크로스 구독 vWAN 권한 스코프 미확정, 인용 근거가 실제 요구보다 좁음) → 6-0-e
  선행 확인 항목으로 승격, 원칙 1에 명시적 예외로 기록, 4절 Integration을 다중 구독
  순회로 확장.
- M4(pre-mortem 시나리오 2가 Azure에 없는 위험을 다룸, 원칙 3 위반) → 시나리오 2
  전면 재작성(와일드카드 전제 삭제, 유효하지만 잘못된 FIC 값이 실제 위험).
- M5(전파 지연 재시도가 FIC 하나뿐, 생성 순서 제약 부재) → 5절에 PrincipalNotFound
  포함 재시도, Azure 생성 순서(잠금 마지막) 신설.
- Minor 1(Option A와 채택 규칙 사이 사문 충돌) → subject 패턴 확정을 6-0-d로 위임.
- Minor 2(원본 5절 출력값 행선지 대응 없음) → 6-1-1에 포함 항목으로 명시.
- Minor 3(BOOTSTRAP_TARGET 등가 실행 대상 선택 메커니즘 없음) → 6-1-1에 포함.
- Minor 4(validate-doc-conventions.py 이식 시점 불명) → 6-0-f 신설.
- What's Missing(Observability 수용 기준 0개) → 4절에 미리 정할 수 있는 기준 1개 신설.

## 변경 이력 (v2 → v3, Architect 2차 검토 반영)

- R2(최대 결함, "Option C가 Option A를 대체"가 CRITICAL 1/2/3 수정을 무효화) → 채택
  규칙을 "대체"에서 "합성"으로 전환.
- R1(잠금은 control plane 전용) → 백스톱 재귀속(이후 C2에서 추가 보완).
- R3~R9 → 불변식 확장, hub의 dev 구독 내 권한 명시, 원칙 목록 정리, Option E 승격,
  FIC 생성 직렬화 등(이후 M1~M5에서 추가 보완).

## 변경 이력 (v1 → v2, 1차 검토 반영)

- Critic CRITICAL 1~3 → 구독 스코프 과잉 권한 제거, 존재하지 않는 백스톱 대체(이후
  C1·C2에서 재정정), `EXPECTED_ACCOUNT` 이식.
- Critic MAJOR 4~9, Minor 1 → 원칙 재정의, 대안 확장, 5절 전면 재작성.
- Architect 1차 사실확인(MI-as-FIC 존재) → Option C 신설.
