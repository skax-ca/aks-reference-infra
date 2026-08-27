#!/usr/bin/env bash
# 부트스트랩 기대 상태 — bootstrap.sh 와 verify.sh 가 공유한다.
#
# ⚠️ 이 파일이 "기대 상태"의 코드 측면이고, README.md 의 표가 문서 측면이다.
#    둘이 어긋나면 README를 고친다 — 사람이 읽는 쪽이 SSOT다(원본 iac-reference-infra와
#    동일 원칙).
#
# 설계 근거: .omc/plans/bootstrap-credential-design.md (v6, ralplan 5라운드 확정)
#
# ⛔ 이 파일 어디에도 built-in Contributor의 notActions를 하드코딩하지 않는다.
#    설계 v4/v5가 그 값을 문서에 옮겨 적다 두 번 연속 틀렸다(3차 Architect 검토가
#    실측으로 확인) — 대신 워크로드 커스텀 역할 생성 시 매 실행 az role definition
#    list로 런타임 조회한다. 같은 실수를 세 번째로 반복하지 않기 위한 구조적 결정이다.

set -euo pipefail

[[ -n "${BASH_VERSION:-}" ]] || {
  echo "ERROR: bash로 실행해야 한다. 예: bash bootstrap.sh" >&2
  return 1 2>/dev/null || exit 1
}

# ── 대상 ─────────────────────────────────────────────────────────────────────
readonly REGION="koreacentral"
readonly REGION_CODE="krc"
# TODO: 이 저장소의 workload 코드는 아직 CLAUDE.md 확정 결정 표에 없다. 원본
# iac-reference-infra와 동일한 관례(workload=demo)를 임시로 따르되, 확정되면
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
readonly STATE_DATA_ROLE_NAME="aks-ref-bootstrap-state-data-${ENV_TOKEN}"

# ── FIC subject (계획 6-0-d 확정: 배포 브랜치 정책만, 필수 리뷰어 없음) ─────
readonly GH_ORG_REPO="${GH_ORG_REPO:-skax-ca/aks-reference-infra}"
readonly FIC_ISSUER="https://token.actions.githubusercontent.com"
readonly FIC_AUDIENCE="api://AzureADTokenExchange"
readonly SUB_MAIN="repo:${GH_ORG_REPO}:ref:refs/heads/main"
readonly SUB_ENV="repo:${GH_ORG_REPO}:environment:${ENV_TOKEN}"
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
# role assignment 생성 직후 실행 시 두 가지 복제 지연이 독립적으로 터질 수 있다:
#   - PrincipalNotFound: SP 생성 직후 Entra 복제 지연(원본 README 128~131행이
#     AWS IAM에 대해 경고한 것과 같은 계열)
#   - "Role '...' doesn't exist.": 커스텀 역할 정의(ensure_custom_role) 생성 직후
#     ARM 캐시 전파 지연. 실측(2026-08-27 hub 부트스트랩 1차 실행)으로 확인 —
#     원래는 PrincipalNotFound만 재시도 대상이었는데, workload 커스텀 역할 생성
#     직후 role assignment가 이 오류로 즉시 die했다.
retry_on_replication_delay() {
  local attempt=0 err
  while :; do
    if err="$("$@" 2>&1 >/dev/null)"; then return 0; fi
    attempt=$((attempt + 1))
    if [[ "$err" != *"PrincipalNotFound"* && "$err" != *"does not exist in the directory"* \
          && "$err" != *"doesn't exist"* ]] \
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

# ── 워크로드 커스텀 역할: notActions를 런타임 조회한다 (계획 1절, 하드코딩 금지) ─
# built-in Contributor의 notActions를 그대로 물려받고 RG 삭제만 추가로 뺀다.
# Azure가 Contributor 정의를 바꿔도 다음 실행이 자동으로 따라간다 — "문서가 값을
# 옮겨 적고 사람이 대조하는 방식" 자체가 v4·v5에서 두 번 틀렸던 근본 원인이었다.
workload_role_not_actions_json() {
  local contributor_not_actions
  # ⚠️ 이 호출은 워크로드 커스텀 역할(가장 권한이 넓은 대상)의 기대값을
  # 만드는 유일한 az 호출이다. 실패하면 die로 즉시 중단하고, 성공하더라도
  # 결과가 "비어있지 않은 배열"인지 검증한다 -
  # jq의 `. + [...]`는 null이 와도 오류 없이 통과시키므로, 조회가 조용히
  # null/빈 배열을 반환하면 워크로드 역할의 notActions가 실제 Contributor
  # 정의보다 크게 좁아져(예: RG 삭제 제외 하나만 남음) CI 신원이 사실상
  # 스스로에게 상위 역할을 부여할 수 있는 상태가 되고, bootstrap.sh와
  # verify.sh가 이 같은 함수를 공유하므로 verify.sh도 그 축소된 값을
  # "일치"로 보고한다 - 이 검증이 그 경로를 막는다.
  if ! contributor_not_actions="$(az_ role definition list --name Contributor \
    --query "[0].permissions[0].notActions" -o json 2>&1)"; then
    die "Contributor 역할 정의 조회 실패: $contributor_not_actions"
  fi
  jq -e 'type == "array" and length > 0' <<<"$contributor_not_actions" >/dev/null \
    || die "Contributor notActions 조회 결과가 유효한 배열이 아니다(받은 값: $contributor_not_actions)"
  jq -c '. + ["Microsoft.Resources/subscriptions/resourceGroups/delete"]' <<<"$contributor_not_actions"
}

workload_role_definition_json() {  # workload_role_definition_json <assignable-scope>
  local scope="$1" not_actions
  not_actions="$(workload_role_not_actions_json)"
  jq -n \
    --arg name "$WORKLOAD_ROLE_NAME" \
    --arg scope "$scope" \
    --argjson notActions "$not_actions" \
    '{
      Name: $name,
      Description: "CI identity for aks-reference-infra bootstrap: full RG control except deleting the RG itself and Contributor-excluded actions (notActions inherited at runtime from built-in Contributor).",
      Actions: ["*"],
      NotActions: $notActions,
      DataActions: [],
      NotDataActions: [],
      AssignableScopes: [$scope]
    }'
}

# ── state 데이터 커스텀 역할: Storage Blob Data Contributor에서
#    containers/delete만 뺀 고정 델타(계획 2절, 실측 확정값이라 하드코딩 유지 —
#    이 값은 Contributor처럼 플랫폼이 바꿀 여지가 적은 안정된 built-in 정의다) ──
state_data_role_definition_json() {  # state_data_role_definition_json <assignable-scope>
  local scope="$1"
  jq -n \
    --arg name "$STATE_DATA_ROLE_NAME" \
    --arg scope "$scope" \
    '{
      Name: $name,
      Description: "state container data role for aks-reference-infra bootstrap: Storage Blob Data Contributor minus containers/delete.",
      Actions: [
        "Microsoft.Storage/storageAccounts/blobServices/containers/read",
        "Microsoft.Storage/storageAccounts/blobServices/containers/write",
        "Microsoft.Storage/storageAccounts/blobServices/generateUserDelegationKey/action"
      ],
      NotActions: [],
      DataActions: [
        "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read",
        "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/write",
        "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/add/action",
        "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/delete",
        "Microsoft.Storage/storageAccounts/blobServices/containers/blobs/move/action"
      ],
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
