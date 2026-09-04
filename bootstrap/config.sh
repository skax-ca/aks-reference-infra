#!/usr/bin/env bash
# 부트스트랩 기대 상태 — bootstrap.sh 와 verify.sh 가 공유한다.
#
# ⚠️ 이 파일이 "기대 상태"의 코드 측면이고, README.md 의 표가 문서 측면이다.
#    둘이 어긋나면 README를 고친다 — 사람이 읽는 쪽이 SSOT다(원본 eks-reference-infra와
#    동일 원칙).
#
# 설계 근거: .omc/plans/bootstrap-credential-design.md (v6, ralplan 5라운드 확정 +
# 2026-09-04 추가 기록 — CI 신원 권한 모델을 RG 스코프 커스텀 역할에서 구독 전체
# Owner로 전환, AWS 원본 AdministratorAccess와 스코프 축 대칭)
#
# ⚠️ 2026-09-04 이전에는 워크로드 커스텀 역할의 notActions를 built-in Contributor
#    에서 매 실행 런타임 조회했다(v4/v5가 이 값을 문서에 옮겨 적다 두 번 연속
#    틀렸던 것의 대체). 이제 워크로드 역할은 Owner 기반(NotActions는 고정값 1개,
#    resourceGroups/delete)이라 그 조회 로직 자체가 불필요해졌다 — Owner는 애초에
#    NotActions가 비어 있어 조회할 대상이 없다.

set -euo pipefail

[[ -n "${BASH_VERSION:-}" ]] || {
  echo "ERROR: bash로 실행해야 한다. 예: bash bootstrap.sh" >&2
  return 1 2>/dev/null || exit 1
}

# ── 대상 ─────────────────────────────────────────────────────────────────────
readonly REGION="koreacentral"
readonly REGION_CODE="krc"
# TODO: 이 저장소의 workload 코드는 아직 CLAUDE.md 확정 결정 표에 없다. 원본
# eks-reference-infra와 동일한 관례(workload=demo)를 임시로 따르되, 확정되면
# 이 기본값을 갱신한다.
readonly WORKLOAD="${WORKLOAD:-demo}"

# ⛔ 구독/테넌트 ID는 git에 두지 않는다(계정 식별 정보 일반). 기본값을 두지 않는
#    것이 핵심이다 — 실행자가 매번 명시하게 해 공용 테넌트에서 조용히 다른
#    구독/테넌트를 건드리지 않도록 한다. 원본의 EXPECTED_ACCOUNT와 동일한 논리를
#    Azure의 구독·테넌트 두 축에 적용한 것이다(계획 1절 Option A, 3절 시나리오 3).
#
# ⚠️ `: "${VAR:?msg}"`를 쓰지 않는다 — bash 기본 exit 1을 내는데, verify.sh의
#    계약은 0=일치/1=drift/2=실행 불가다. 미설정은 drift가 아니라 실행 불가이므로
#    반드시 exit 2로 끝나야 한다(원본과 동일한 이유).
[[ -n "${EXPECTED_SUBSCRIPTION:-}" ]] || {
  echo "ERROR: EXPECTED_SUBSCRIPTION이 설정되지 않았다 — 어느 구독에 부트스트랩할지 명시할 것." >&2
  echo "       예: EXPECTED_SUBSCRIPTION=<GUID> EXPECTED_TENANT=<GUID> bash bootstrap.sh" >&2
  echo "       값은 Azure 구독 관리자에게 확인한다." >&2
  exit 2
}
[[ "$EXPECTED_SUBSCRIPTION" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || {
  echo "ERROR: EXPECTED_SUBSCRIPTION은 GUID 형식이어야 한다 (받은 값: $EXPECTED_SUBSCRIPTION)" >&2
  exit 2
}
readonly EXPECTED_SUBSCRIPTION

[[ -n "${EXPECTED_TENANT:-}" ]] || {
  echo "ERROR: EXPECTED_TENANT가 설정되지 않았다 — 어느 테넌트에서 실행할지 명시할 것." >&2
  echo "       App Registration·FIC·Entra 역할은 테넌트 스코프 객체라 구독 대조만으로는" >&2
  echo "       부족하다(계획 1절 Option A 구독·테넌트 대조 가드)." >&2
  exit 2
}
[[ "$EXPECTED_TENANT" =~ ^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$ ]] || {
  echo "ERROR: EXPECTED_TENANT는 GUID 형식이어야 한다 (받은 값: $EXPECTED_TENANT)" >&2
  exit 2
}
readonly EXPECTED_TENANT

# ── hub-spoke 토폴로지 (원본과 동일한 역할 분리) ────────────────────────────
# hub는 구독마다 단일 고정 거처, spoke는 여러 인스턴스가 가능한 역할이며 dev가
# 첫 인스턴스다(계획 6-0-a: hub/dev 별도 구독으로 확정).
readonly BOOTSTRAP_TARGET="${BOOTSTRAP_TARGET:-hub}"
case "$BOOTSTRAP_TARGET" in
  hub|spoke) ;;
  *)
    echo "ERROR: BOOTSTRAP_TARGET은 hub 또는 spoke여야 한다 (받은 값: $BOOTSTRAP_TARGET)" >&2
    exit 2
    ;;
esac
readonly SPOKE_ENV="${SPOKE_ENV:-dev}"
readonly ENV_TOKEN="$([[ "$BOOTSTRAP_TARGET" == hub ]] && echo hub || echo "$SPOKE_ENV")"

# ── 네이밍 ───────────────────────────────────────────────────────────────────
# iac-module-library의 docs/naming/abbreviations/azure.md에 resource group(`rg`)·
# storage account(`st`)·앱 등록(`entapp`)을 등재했다(2026-08-27, 실제 Azure 검증
# 세션). "todo" placeholder는 이 등재로 해소됐다 — 등재 전까지는 이 네이밍 함수만
# 교체하면 되도록 설계했었고, 실제로 사용처(RG_NAME 등을 참조하는 bootstrap.sh·
# verify.sh)는 하나도 안 건드렸다.
readonly RG_NAME="rg-${WORKLOAD}-${ENV_TOKEN}-${REGION_CODE}-workload-01"
readonly STATE_RG_NAME="rg-${WORKLOAD}-${ENV_TOKEN}-${REGION_CODE}-tfstate-01"
readonly APP_NAME="entapp-${WORKLOAD}-${ENV_TOKEN}-${REGION_CODE}-gha-01"

# 워크로드 커스텀 역할의 스코프(2026-09-04부터 구독 전체 — 이전에는 RG_NAME 하나).
# bootstrap.sh·verify.sh 둘 다 이 값을 쓴다(각자 계산하면 갈릴 위험이 있어 공유
# 계층으로 올렸다).
readonly SUBSCRIPTION_SCOPE="/subscriptions/${EXPECTED_SUBSCRIPTION}"

# hub App Registration 이름 — 대상과 무관하게(hub·spoke 어느 쪽에서 소싱하든) 항상
# "hub" 토큰으로 고정 계산한다. bootstrap.sh의 크로스 구독 스포크 연결 절이 dev 구독
# 컨텍스트에서 hub SP를 조회할 때 쓴다(.omc/plans/live-hub-vwan-dev-networking.md 4-1).
readonly HUB_APP_NAME="entapp-${WORKLOAD}-hub-${REGION_CODE}-gha-01"

# Storage Account 이름: 3~24자, 소문자+숫자만, 하이픈 불가(Azure 물리 제약) — 등재된
# `st` 약어에서 하이픈만 뺀 접두사를 쓴다(azure.md A.3의 캐비어트 참고). 원본의
# "이름을 git에 남기지 않는다" 요건(임의 접미사)을 지키려고 8자리 hex 접미사를 더한다.
readonly SA_PREFIX="st${WORKLOAD}${ENV_TOKEN}"
readonly CONTAINER_NAME="tfstate"

# SA_PREFIX + 8자리 hex 접미사가 24자를 넘으면 new_storage_account_name()의
# ${base:0:24} 절단이 접미사를 깎아 이름이 SA_PREFIX로 시작하지 않게 되고,
# find_storage_account()의 starts_with 조회가 매번 실패해 실행마다 새 계정을
# 만드는 멱등성 붕괴로 이어진다. 여기서 조기에 막는다.
[[ "${#SA_PREFIX}" -le 16 ]] || {
  echo "ERROR: SA_PREFIX '${SA_PREFIX}'가 16자를 넘는다(현재 ${#SA_PREFIX}자)." >&2
  echo "       WORKLOAD/SPOKE_ENV를 줄이거나 config.sh의 네이밍을 조정할 것." >&2
  exit 2
}
[[ "$SA_PREFIX" =~ ^[a-z0-9]+$ ]] || {
  echo "ERROR: SA_PREFIX '${SA_PREFIX}'는 소문자+숫자만 허용한다(Storage Account 물리 제약)." >&2
  exit 2
}

new_storage_account_name() {
  local rand base
  rand="$(openssl rand -hex 4)"
  base="${SA_PREFIX}${rand}"
  echo "${base:0:24}"
}

# ── 커스텀 역할 이름 ─────────────────────────────────────────────────────────
readonly WORKLOAD_ROLE_NAME="aks-ref-bootstrap-workload-ci-${ENV_TOKEN}"
# 2026-09-04부로 이 스크립트는 state 데이터 역할을 더 이상 만들지 않는다(위
# 「워크로드 커스텀 역할」절 참고). 이 이름은 이전 실행이 만든 실물을 사람이
# 수동 정리할 때 오타 없이 참조하기 위한 용도로만 남긴다.
readonly STATE_DATA_ROLE_NAME="aks-ref-bootstrap-state-data-${ENV_TOKEN}"
# 스포크(dev)에서만 의미가 있다 — hub CI 신원에게 이 스포크 VNet을 vWAN 허브에
# 연결할 권한(peer/action 단일 액션)을 주는 역할이다(계획 4-1 Option A).
readonly SPOKE_PEER_ROLE_NAME="aks-ref-bootstrap-spoke-peer-${ENV_TOKEN}"

# ── AKS 클러스터용 identity·권한 (.omc/plans/live-hub-aks.md 「identity·role
#    assignment (bootstrap 확장)」절) ──────────────────────────────────────────
# aks-cluster 모듈은 identity도 role assignment도 스스로 만들지 않고 입력으로만
# 받는다. 그래서 이 두 가지의 소유자는 bootstrap 계층(IaC 밖, 사람이 실행)이다.
#
# ⚠️ identity를 **워크로드 RG**에 두는 이유: CI 커스텀 역할의 스코프가 그 RG 하나뿐
#    이라, identity가 그 밖에 있으면 live/hub/aks apply가 Microsoft.ManagedIdentity/
#    userAssignedIdentities/assign/action 권한 부족으로 실패한다.
readonly AKS_IDENTITY_NAME="id-${WORKLOAD}-${ENV_TOKEN}-${REGION_CODE}-aks-01"

# VNet·노드 서브넷 이름은 live/<env>/networking 루트가 소비하는 vnet 모듈이
# "vnet-<workload>-<env>-<region_code>-<purpose>" · "snet-...-<그룹명>"으로 조합한
# 값이다(purpose="main", 그룹명="aks-node"). 이 스크립트는 그 서브넷을 만들지 않고
# role assignment 스코프로 참조만 한다.
readonly AKS_VNET_NAME="vnet-${WORKLOAD}-${ENV_TOKEN}-${REGION_CODE}-main"
readonly AKS_NODE_SUBNET_NAME="snet-${WORKLOAD}-${ENV_TOKEN}-${REGION_CODE}-aks-node"

# ⚠️ 이것만 **built-in 역할**이다(커스텀 역할이 아니다). 그래서
#    role_definition_matches()로 정의 완전 일치를 검사하지 않는다 — 정의를 Azure가
#    소유하므로 이 저장소가 기대값을 가질 근거 자체가 없다. 검사 대상은 "이 역할을
#    가리키는 role assignment가 서브넷 스코프에 존재하는가" 하나다. 서브넷 스코프로
#    좁힌 근거는 Microsoft 공식 문서(concepts-network-cni-overview)의 최소 권고
#    ("at least Network Contributor permissions on the subnet")다.
readonly AKS_NODE_ROLE_NAME="Network Contributor"

# 노드 서브넷의 리소스 ID를 찾는다. 없으면 **빈 문자열**을 stdout에 낸다(호출자가
# 판단한다: bootstrap.sh는 role assignment 단계를 건너뛰고, verify.sh는 na로 보고).
# 두 스크립트가 **같은 함수**를 써야 한다 — 기준이 갈리면 "bootstrap은 만들었다는데
# verify는 미판정"처럼 서로 다른 결론이 나온다(role_definition_matches와 같은 이유).
#
# ⚠️ VNet 존재 확인과 서브넷 조회를 2단계로 나눈 것이 핵심이다. VNet 부재는 정당한
#    "아직 안 만들어짐"이지만, VNet이 있는데 조회가 실패하는 것은 권한 문제 등이라
#    fail-closed(exit 2)여야 한다. 한 번의 `subnet show`로 합치면 그 둘이 구분되지
#    않아 조회 실패가 "부재"로 둔갑하고, verify.sh 쪽에서는 그것이 na(exit 0)라는
#    유일한 통과 경로로 새어 나간다.
aks_node_subnet_id() {
  az_ network vnet show --resource-group "$RG_NAME" --name "$AKS_VNET_NAME" &>/dev/null \
    || { echo ""; return; }
  local id
  id="$(az_or_die "노드 서브넷 조회($AKS_NODE_SUBNET_NAME)" -- \
    az_ network vnet subnet list --resource-group "$RG_NAME" --vnet-name "$AKS_VNET_NAME" \
      --query "[?name=='${AKS_NODE_SUBNET_NAME}'].id | [0]" -o tsv)"
  [[ "$id" == "None" ]] && id=""
  echo "$id"
}

# ── FIC subject (계획 6-0-d 확정: 배포 브랜치 정책만, 필수 리뷰어 없음) ─────
#
# ⚠️ 이름만으로 조합한 subject(`repo:org/repo:...`)는 실제 GitHub OIDC 토큰과 맞지 않는다.
# 이 조직/계정에서는 GitHub가 org·repo 이름 뒤에 불변 숫자 ID를 붙인
# `repo:org@org_id/repo@repo_id:...` 형태로 sub 클레임을 발급한다(2026-08-27 hub CI 최초
# 실행에서 AADSTS700213으로 실측 확인 — 이름 기반 FIC는 항상 인증 실패한다). 원인은
# GitHub 쪽의 sub 클레임 정책이지 이 스크립트가 결정할 수 있는 값이 아니므로, `gh api`로
# 실제 ID를 조회해 조합한다. 이름 기반으로 되돌리지 않는다.
command -v gh >/dev/null || {
  echo "ERROR: gh CLI가 필요하다 (FIC subject의 org/repo 불변 ID 조회용)." >&2
  exit 1
}
readonly GH_ORG_REPO="${GH_ORG_REPO:-skax-ca/aks-reference-infra}"
readonly GH_ORG="${GH_ORG_REPO%%/*}"
readonly GH_REPO_NAME="${GH_ORG_REPO##*/}"
readonly GH_ORG_ID="$(gh api "orgs/${GH_ORG}" --jq '.id')"
readonly GH_REPO_ID="$(gh api "repos/${GH_ORG_REPO}" --jq '.id')"
readonly GH_ORG_REPO_SUBJECT="${GH_ORG}@${GH_ORG_ID}/${GH_REPO_NAME}@${GH_REPO_ID}"
readonly FIC_ISSUER="https://token.actions.githubusercontent.com"
readonly FIC_AUDIENCE="api://AzureADTokenExchange"
readonly SUB_MAIN="repo:${GH_ORG_REPO_SUBJECT}:ref:refs/heads/main"
readonly SUB_ENV="repo:${GH_ORG_REPO_SUBJECT}:environment:${ENV_TOKEN}"
readonly FIC_NAME_MAIN="gha-${ENV_TOKEN}-main"
readonly FIC_NAME_ENV="gha-${ENV_TOKEN}-environment"

# ── 거버넌스 태그 ────────────────────────────────────────────────────────────
readonly TAG_WORKLOAD="$WORKLOAD"
readonly TAG_MANAGED_BY="bootstrap.sh"
readonly TAG_ENVIRONMENT="$ENV_TOKEN"

# ── 출력 헬퍼 (원본과 동일 패턴, stderr로 통일 — stdout은 함수 반환값 전용) ──
readonly C_OK=$'\033[32m'; readonly C_CHG=$'\033[33m'
readonly C_ERR=$'\033[31m'; readonly C_OFF=$'\033[0m'
ok()      { printf '%s  ok%s      %s\n' "$C_OK" "$C_OFF" "$*" >&2; }
changed() { printf '%s changed%s  %s\n' "$C_CHG" "$C_OFF" "$*" >&2; CHANGES=$((CHANGES + 1)); }
mismatch(){ printf '%s  DRIFT%s   %s\n' "$C_ERR" "$C_OFF" "$*" >&2; DRIFTS=$((DRIFTS + 1)); }
# ⚠️ warn()은 **어떤 카운터도 올리지 않는다**. "지금은 판정할 수 없다"(선행 리소스가
# 아직 없다)를 drift와 구분해 알리는 용도다. 조회가 실패한 경우에 쓰면 안 된다 —
# 그건 fail-closed 대상이라 die()로 exit 2여야 한다.
warn()    { printf '%s   warn%s   %s\n' "$C_CHG" "$C_OFF" "$*" >&2; }

# ⚠️ TOP_PID + kill 패턴: macOS 시스템 bash(3.2, GPLv3 문제로 이 버전에 고정)는
# `$( )` 명령 치환 안에서 `errexit`를 전혀 적용하지 않는다 —
# `x="$(false; echo survived)"`가 `set -euo pipefail` 아래에서도 죽지 않고
# 계속 실행된다(실측 확인). `die()`가 그냥 `exit 2`만 하면, check_* 함수
# 안에서 실패해도 그 exit은 가장 안쪽 서브셸만 죽이고 바깥 스크립트는 빈
# 문자열을 받아 계속 진행한다(그리고 `[[ "" -eq 0 ]]`가 bash에서 참이라 "0건
# 통과"로 둔갑한다). TOP_PID에 SIGTERM을 보내고 최상위 스크립트가 그 신호를
# trap해 exit하면, 서브셸이 몇 겹이든 bash 버전이 무엇이든 결과가 같아진다.
readonly TOP_PID=$$
trap 'exit 2' TERM
die() {
  printf '%s  ERROR%s   %s\n' "$C_ERR" "$C_OFF" "$*" >&2
  kill -s TERM "$TOP_PID" 2>/dev/null
  exit 2
}

# 조회 결과가 정수인지 검증한다. 조회 실패로 count 변수가 빈 문자열이 되면
# `[[ "" -eq 0 ]]`가 bash에서 참으로 평가되어 "0건이라 통과"로 둔갑한다 —
# 이 함수가 그 함정을 여기서 차단한다. die()가 TOP_PID로 신호를 보내지만,
# 이 함수를 호출한 지점 자체가 이미 서브셸을 벗어난 위치(카운트 변수 대입
# 다음 줄)이므로 이 가드만으로도 즉시 멈춘다.
require_int() {  # require_int <value> <label>
  [[ "$1" =~ ^[0-9]+$ ]] || die "$2 - 판정 불가(조회 실패 또는 예상치 못한 응답: '$1')"
}

# ── 공통 확인 ────────────────────────────────────────────────────────────────
az_() { az "$@"; }

# 일반 az 호출 — 실패하면 즉시 exit 2 한다(fail-closed). 호출자는 항상
# `"$(az_or_die '설명' -- az 서브커맨드...)"` 형태로 쓴다. 원래 verify.sh에만
# 있었으나, role_definition_list_retry가 bootstrap.sh·verify.sh 양쪽에서
# 같은 fail-closed 기준으로 조회 실패를 판정해야 해서 공유 계층으로 옮겼다.
az_or_die() {  # az_or_die <error-context> -- <command...>
  local ctx="$1"; shift
  [[ "$1" == "--" ]] && shift
  local out
  if ! out="$("$@" 2>&1)"; then
    die "$ctx 조회 실패: $out"
  fi
  echo "$out"
}

assert_subscription_tenant() {
  local actual_sub actual_tenant
  actual_sub="$(az_ account show --query id -o tsv 2>/dev/null)" \
    || die "az 로그인 없음. 'az login' 먼저 실행할 것"
  [[ "$actual_sub" == "$EXPECTED_SUBSCRIPTION" ]] \
    || die "구독 불일치: 기대 $EXPECTED_SUBSCRIPTION, 실제 $actual_sub — 공용 테넌트이므로 중단한다"
  actual_tenant="$(az_ account show --query tenantId -o tsv)"
  [[ "$actual_tenant" == "$EXPECTED_TENANT" ]] \
    || die "테넌트 불일치: 기대 $EXPECTED_TENANT, 실제 $actual_tenant — App Registration은 테넌트 스코프 객체다"
}

# ── 재시도 헬퍼 (계획 5절, 특정 오류 코드일 때만 재시도. 맹목적 재시도는 진짜
#    실패를 감춘다) ───────────────────────────────────────────────────────────
#
# role assignment 생성 직후 실행 시 여러 복제 지연이 독립적으로 터질 수 있다:
#   - PrincipalNotFound: SP 생성 직후 Entra 복제 지연(원본 README 128~131행이
#     AWS IAM에 대해 경고한 것과 같은 계열)
#   - "Role '...' doesn't exist.": 커스텀 역할 정의(ensure_custom_role) 생성 직후
#     ARM 캐시 전파 지연. 실측(2026-08-27 hub 부트스트랩 1차 실행)으로 확인 —
#     원래는 PrincipalNotFound만 재시도 대상이었는데, workload 커스텀 역할 생성
#     직후 role assignment가 이 오류로 즉시 die했다.
#   - RoleAssignmentScopeNotAssignableToRoleDefinition: 역할 정의의
#     AssignableScopes를 update로 바꾼 직후(2026-09-04, RG 스코프 → 구독 스코프
#     마이그레이션) 그 변경이 아직 전파되지 않은 상태에서 새 스코프로 role
#     assignment를 만들면 "이 스코프에서 사용 불가"로 거부된다. hub에서는
#     우연히 안 걸렸지만 dev 재부트스트랩에서 실측(2026-09-04) — 같은 ARM 캐시
#     전파 지연 계열의 새 얼굴이다. AssignableScopes가 바뀐 건 이번이 처음이라
#     (그 전엔 Actions/NotActions만 바뀌었다) 이전엔 드러날 기회가 없었다.
retry_on_replication_delay() {
  local attempt=0 err
  while :; do
    if err="$("$@" 2>&1 >/dev/null)"; then return 0; fi
    attempt=$((attempt + 1))
    if [[ "$err" != *"PrincipalNotFound"* && "$err" != *"does not exist in the directory"* \
          && "$err" != *"doesn't exist"* \
          && "$err" != *"RoleAssignmentScopeNotAssignableToRoleDefinition"* ]] \
       || (( attempt >= 10 )); then
      die "재시도 초과 또는 다른 오류: $err"
    fi
    printf '            … 복제 전파 대기 (%d/10)\n' "$attempt" >&2
    sleep 5
  done
}

# AADSTS70021은 FIC 생성 후 GitHub Actions가 실제로 토큰 교환을 시도할 때(이
# bootstrap 스크립트 밖, CI 워크플로 실행 시점) 전파 지연으로 발생할 수 있다.
# bootstrap.sh 자신은 토큰 교환을 수행하지 않으므로 여기서는 다루지 않는다 —
# 이 저장소에 실제 GitHub Actions 워크플로가 생기면 그 시점에 같은 형태의
# 재시도 헬퍼(retry_on_conflict()를 참고)를 그쪽 코드에 추가한다. FIC 생성
# 자체에서 발생 가능한 오류는 동시 생성 충돌(409)이며, retry_on_conflict()가
# 처리한다.

# 409(Conflict): 같은 App/UAMI 하위에 FIC를 동시 생성하면 충돌한다(공식 문서상
# 이 제약은 user-assigned managed identity에 명시적으로 서술된 것이며, App
# Registration 쪽으로 일반화한 것이 아니다 — 다만 직렬 재시도 자체는 무해하므로
# 두 경로 모두에 재사용 가능한 형태로 둔다).
retry_on_conflict() {
  local attempt=0 err
  while :; do
    if err="$("$@" 2>&1 >/dev/null)"; then return 0; fi
    attempt=$((attempt + 1))
    if [[ "$err" != *"Conflict"* && "$err" != *"409"* ]] || (( attempt >= 10 )); then
      die "재시도 초과 또는 다른 오류: $err"
    fi
    printf '            … 동시 생성 충돌 재시도 (%d/10)\n' "$attempt" >&2
    sleep 3
  done
}

# ── 워크로드 커스텀 역할: 구독 전체 Owner 등가, RG 자기 삭제만 제외 (2026-09-04
#    결정, .omc/plans/bootstrap-credential-design.md 추가 기록) ─────────────────
# Owner는 built-in 정의 자체가 NotActions: []다 — Contributor처럼 런타임 조회할
# 대상이 없다(그 조회 로직이 v4·v5에서 두 번 틀렸던 근본 원인이었는데, Owner
# 기반으로 바꾸면서 그 실수 클래스 자체가 사라졌다). "RG 자체 삭제 방지"만
# 값싼 사고 방지 안전망으로 유지한다 — 더 이상 보안 경계가 아니다(Owner는 RG
# 안의 다른 모든 리소스를 어차피 지울 수 있다).
workload_role_definition_json() {  # workload_role_definition_json <assignable-scope>
  local scope="$1"
  jq -n \
    --arg name "$WORKLOAD_ROLE_NAME" \
    --arg scope "$scope" \
    '{
      Name: $name,
      # ⚠️ az CLI 실측 버그(azure-cli 2.89.1, ensure_custom_role의 update 경로):
      # `az role definition update`는 카멜케이스 변환 후 role_definition["roleName"]을
      # 직접 읽는데, create는 role_definition.get("name")을 읽는다 — 같은 명령군인데
      # 요구하는 키가 다르다. Name만 쓰면 update 시 KeyError: 'roleName'으로 죽는다
      # (2026-09-04 hub 재부트스트랩 실측). RoleName을 추가로 넣어 두 경로 다 만족시킨다
      # (create/worker.create_role_definition은 role_name을 별도 인자로 받아 role_definition
      # dict의 여분 키를 무시하므로 부작용 없음).
      RoleName: $name,
      Description: "CI identity for aks-reference-infra: subscription-wide Owner except deleting the workload resource group itself (2026-09-04 decision, AWS AdministratorAccess parity — see .omc/plans/bootstrap-credential-design.md).",
      Actions: ["*"],
      NotActions: ["Microsoft.Resources/subscriptions/resourceGroups/delete"],
      DataActions: [],
      NotDataActions: [],
      AssignableScopes: [$scope]
    }'
}

# ⚠️ state 데이터 역할(Storage Blob Data Contributor 델타, RG_NAME 안 컨테이너
# 스코프)은 2026-09-04부로 이 스크립트가 더 이상 만들지 않는다 — 워크로드 역할이
# 이미 구독 전체 Owner라 그 안에 포함된 state RG·컨테이너까지 전부 커버해 별도
# role assignment가 무의미해졌다. 이전에 실행된 bootstrap.sh가 만든 실제 role
# 정의·assignment(이름: aks-ref-bootstrap-state-data-<env>)는 이 스크립트가
# 자동으로 지우지 않는다(이 저장소의 스크립트는 항상 추가·수렴만 하지 삭제하지
# 않는다) — 실제 재부트스트랩 시 사람이 확인 후 `az role assignment delete`·
# `az role definition delete`로 정리한다.

# ── 스포크 연결 역할: peer/action 단일 액션 (계획 4-1 Option A) ────────────
# hub CI 신원이 이 역할을 dev 워크로드 RG 스코프로 받아 live/hub/vwan의
# azurerm_virtual_hub_connection.spoke를 성립시킨다. assignable scope와 실제 할당
# 스코프가 **둘 다 스포크 워크로드 RG**다(bootstrap.sh의 크로스 구독 스포크 연결
# 절이 $RG_SCOPE를 그대로 양쪽에 넘긴다). VNet 리소스 단위로 좁히는 최초안은
# 2026-09-03에 기각됐다 — bootstrap.sh는 항상 networking apply보다 먼저 실행돼
# 그 시점엔 VNet이 아직 없다(bootstrap/README.md 「크로스 구독 연결」절).
spoke_peer_role_definition_json() {  # spoke_peer_role_definition_json <assignable-scope>
  local scope="$1"
  jq -n \
    --arg name "$SPOKE_PEER_ROLE_NAME" \
    --arg scope "$scope" \
    '{
      Name: $name,
      # RoleName 중복 이유는 workload_role_definition_json 주석 참고(az CLI update 경로 버그).
      RoleName: $name,
      Description: "Single-action grant for the hub CI identity to peer this spoke VNet into the hub Virtual WAN hub (aks-reference-infra live/hub/vwan spoke connection, plan 4-1 Option A).",
      Actions: ["Microsoft.Network/virtualNetworks/peer/action"],
      NotActions: [],
      DataActions: [],
      NotDataActions: [],
      AssignableScopes: [$scope]
    }'
}

# ── FIC 기대 정의 (subject/issuer/audience 전 필드, 계획 3절 시나리오 1(f)) ──
fic_expected_json() {  # fic_expected_json <name> <subject>
  jq -n --arg name "$1" --arg subject "$2" --arg issuer "$FIC_ISSUER" --arg aud "$FIC_AUDIENCE" \
    '{name: $name, subject: $subject, issuer: $issuer, audiences: [$aud]}'
}

# JSON 의미 비교 — 키 순서·공백 차이로 가짜 drift가 나지 않게 정규화한다.
json_eq() { [[ "$(jq -cS . <<<"$1")" == "$(jq -cS . <<<"$2")" ]]; }

# 배열을 집합으로 비교한다(순서 무관, 완전 일치). "포함 여부"가 아니라 "집합
# 완전 일치" 검사에 쓴다 — 계획이 명시적으로 요구하는 방식이다.
array_set_eq() {  # array_set_eq <json-array-1> <json-array-2>
  [[ "$(jq -cS 'sort' <<<"$1")" == "$(jq -cS 'sort' <<<"$2")" ]]
}

# `az role definition list --name` 단건 조회가, 같은 역할이 방금 생성/갱신된
# 직후 일시적으로 빈 배열을 돌려주는 경우가 실측됐다(2026-08-27 hub 부트스트랩
# 2차 실행 — --name 단건 조회와 --custom-role-only 전체 목록 조회가 같은 시점에
# 서로 다른 결과를 냈다. Azure RBAC 조회 경로 간 캐시 전파 지연으로 보인다).
# bootstrap.sh·verify.sh 양쪽에서 같은 재시도로 흡수한다 — 각자 따로 재시도를
# 구현하면 한쪽만 고쳐지고 다른 쪽은 계속 소음을 낸다.
role_definition_list_retry() {  # role_definition_list_retry <role-name>
  local role_name="$1" current attempt=0
  while :; do
    current="$(az_or_die "역할 정의 조회($role_name)" -- az_ role definition list --name "$role_name" -o json)"
    [[ "$(jq 'length' <<<"$current")" -gt 0 ]] && { echo "$current"; return 0; }
    attempt=$((attempt + 1))
    (( attempt < 5 )) && printf '            … 역할 정의 조회 캐시 지연 대기 (%d/5)\n' "$attempt" >&2
    (( attempt < 5 )) || { echo "$current"; return 0; }
    sleep 3
  done
}

# 커스텀 역할 정의 전체(Actions/NotActions/DataActions/NotDataActions)를
# 완전 일치로 비교한다. bootstrap.sh(수렴 판단)와 verify.sh(drift 감지)가
# **반드시 같은 함수**를 써야 한다 — 두 스크립트가 각자 기준을 가지면 "bootstrap
# 은 ok인데 verify는 실패"가 생기고, 그러면 verify.sh는 완화책이 아니라 소음이
# 된다(원본 config.sh의 check_* 공유 원칙과 동일한 이유). 비교 대상을
# NotActions 하나로 좁히면 state 데이터 역할의 Actions/DataActions drift를
# 영원히 수렴시키지 못하므로, 4개 필드 전부를 본다.
#
# <current-role-list-json>은 `az role definition list --name <role>`의 원시
# 출력(배열)이다. 역할이 존재하지 않으면(빈 배열) 1을 반환한다(불일치로 취급).
role_definition_matches() {  # role_definition_matches <expected-definition-json> <current-role-list-json>
  local expected="$1" current="$2"
  [[ "$(jq 'length' <<<"$current")" -gt 0 ]] || return 1
  local exp_actions exp_notactions exp_dataactions exp_notdataactions
  local cur_actions cur_notactions cur_dataactions cur_notdataactions
  exp_actions="$(jq -c '.Actions' <<<"$expected")"
  exp_notactions="$(jq -c '.NotActions' <<<"$expected")"
  exp_dataactions="$(jq -c '.DataActions' <<<"$expected")"
  exp_notdataactions="$(jq -c '.NotDataActions' <<<"$expected")"
  cur_actions="$(jq -c '.[0].permissions[0].actions' <<<"$current")"
  cur_notactions="$(jq -c '.[0].permissions[0].notActions' <<<"$current")"
  cur_dataactions="$(jq -c '.[0].permissions[0].dataActions' <<<"$current")"
  cur_notdataactions="$(jq -c '.[0].permissions[0].notDataActions' <<<"$current")"
  array_set_eq "$exp_actions" "$cur_actions" \
    && array_set_eq "$exp_notactions" "$cur_notactions" \
    && array_set_eq "$exp_dataactions" "$cur_dataactions" \
    && array_set_eq "$exp_notdataactions" "$cur_notdataactions"
}
