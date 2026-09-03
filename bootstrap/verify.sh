#!/usr/bin/env bash
# drift 감지 — **read-only**. 아무것도 만들거나 고치지 않는다.
#
# 부트스트랩이 IaC 밖이라 `tofu plan`이 없다. 이 스크립트가 그 역할을 대신한다.
# 기대 상태는 config.sh가 bootstrap.sh와 **공유**한다 — 기준이 갈리면 소음이 된다.
#
# exit 0 = 기대 상태와 일치 / exit 1 = drift / exit 2 = 실행 불가(자격증명·구독·
# 테넌트 불일치, 또는 조회 자체가 실패해 판정할 수 없음)
#
# ⚠️ 이 스크립트는 음성 테스트로 증명해야 한다(계획 5절 3-2 대응). 리소스를
#    일부러 어긋나게 한 뒤 exit 1이 나오는 것을 보지 않으면, "완화책이 있다"는
#    착각만 남는다. 구체적인 주입·복구 절차는 README.md에 있다.
#
# ⛔ **fail-closed 원칙**: 조회 자체가 실패하면(권한 부족, 네트워크 오류, 잘못된
#    쿼리 등) 절대 "0건이라 통과"로 처리하지 않는다 — exit 2(실행 불가)로 즉시
#    중단한다. "권한이 없어 못 봤다"를 "0건이라 검증됐다"로 둔갑시키는 것은 이
#    스크립트 자신이 방지하려는 바로 그 실패 양상이다(원본 config.sh의
#    check_*가 조회 실패 시 absent로 처리하는 fail-closed 관례와 같은 정신).
#
# ⛔ 이 스크립트 전체를 CI 파이프라인의 공용 자격증명으로 무인 실행할 수 없다.
#    (a) ARM RBAC 스코프 검사(구독)는 Reader 권한으로 충분해 CI 분리 실행이
#    가능하지만, (c)~(g)(Entra 디렉터리 역할, Graph 앱 권한, 정적 자격증명·
#    owners, FIC 전 필드, 그룹 멤버십)는 Microsoft Graph 디렉터리 읽기 권한
#    (Application.Read.All/Directory.Read.All 또는 앱 소유권)을 요구하는데,
#    원칙 1이 CI 신원에 그 권한 자체를 0건으로 금지한다. 이 스크립트는 **사람
#    관리자 자격증명으로 수동 실행**하는 것을 전제로 작성됐다.
#
# ⚠️ 원래 (b) 관리 그룹 스코프 role assignment 0건 검사가 있었으나 제거했다
#    (2026-08-27, 실제 Azure 검증 세션). 이 설계의 OIDC 배포 경로는 관리 그룹을
#    전혀 쓰지 않는데(role assignment는 항상 RG·컨테이너 스코프에만 생성),
#    그 부재를 증명하려면 검증자에게 테넌트 루트 `Microsoft.Management/
#    managementGroups/read`가 필요했다 — README가 명시한 실행 전제(구독
#    Owner/UAA)보다 훨씬 넓은 권한을 검증자에게만 요구하는 불균형이라 사용자가
#    직접 삭제를 확정했다. 이 판단의 전체 맥락은
#    `.omc/plans/bootstrap-credential-design.md`의 2026-08-27 추가 기록을 참고.

cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

DRIFTS=0

report() {  # report <이름> <상태>
  case "$2" in
    ok)     ok "$1" ;;
    absent) mismatch "$1 - 존재하지 않는다" ;;
    drift)  mismatch "$1 - 기대 상태와 다르다" ;;
    # ⚠️ na는 MISMATCH를 올리지 않는다(exit 0 유지). 위 fail-closed 원칙("조회 대상이
    # 없는 상황을 0건이라 통과로 처리하지 않는다")과 문언상 충돌해 보이지만 범주가
    # 다르다: 그 원칙은 **CI 신원 자체**의 권한을 조회하다 실패하는 경우를 가리키고,
    # na는 **아직 만들어지지 않은 선행 리소스**(예: networking apply 전의 노드 서브넷)를
    # 기다리는 경우다. 조회 실패는 여전히 az_or_die가 exit 2로 처리한다.
    # 이 상태를 쓰는 검사는 반드시 "그 선행 리소스가 무엇인지"를 이름에 담아야 한다.
    na)     warn "$1 - 미판정(선행 리소스가 아직 없다)" ;;
    *)
      # ⚠️ 방어 계층 하나일 뿐, 이것만으로는 부족하다. macOS 시스템
      # bash(3.2)는 `$( )` 명령 치환 안에서 errexit를
      # 전혀 적용하지 않는다 — check_x 안에서 die()가 exit 2를 해도 그
      # 서브셸만 죽고 바깥은 계속 진행되며(할당문이든 명령 인자든 동일하게
      # 영향받는다, 위치의 문제가 아니다), check_x가 "실패했지만 ok/absent/
      # drift 중 하나로 보이는 값"을 반환하면 이 default 분기에도 안 걸린다.
      # 진짜 방어는 config.sh의 die()가 TOP_PID에 SIGTERM을 보내 최상위
      # 스크립트를 직접 끝내는 것과, 숫자 카운트마다 require_int로 형식을
      # 검증하는 것이다(아래 (a)(b)(c)(d)(e)(g) 참고). 이 default 분기는
      # 그 두 방어를 다 빠져나간, 정말 예상 밖의 값만 잡는 마지막 안전망이다.
      die "$1 - 상태를 판정하지 못했다(예상 밖의 값). 위 ERROR 메시지를 확인할 것"
      ;;
  esac
}

# Microsoft Graph 호출 — 실패하면 즉시 exit 2 한다. --query로 서버 측 JMESPath를
# 걸지 않고 항상 원시 JSON을 받아 jq로 걸러낸다. `@odata.type` 같은 필드를
# JMESPath에 그대로 넣으면 az CLI 인자 파싱 단계에서 거부되지만, jq는 이런
# 필드명도 문제없이 다룬다.
graph_get() {  # graph_get <url>
  local out
  if ! out="$(az_ rest --method GET --url "$1" -o json 2>&1)"; then
    die "Microsoft Graph 조회 실패($1): $out / Application.Read.All 또는 Directory.Read.All 권한이 있는 사람 관리자 자격증명으로 실행할 것"
  fi
  echo "$out"
}

echo "=== verify (read-only . target=$BOOTSTRAP_TARGET env=$ENV_TOKEN) ==="
assert_subscription_tenant

# ── App Registration / Service Principal 조회 (없으면 이후 전부 absent) ────
# ⚠️ az_or_die로 감싼다 — 감싸지 않으면 Graph 조회 권한 부족 등으로 이 명령
# 자체가 실패했을 때 exit 1(die가 아니라 az의 원래 종료 코드)로 끝나 "drift"로
# 오분류된다(계획 5절 exit code 규약: 조회 실패는 exit 2여야 한다).
APP_ID="$(az_or_die "App Registration 목록" -- az_ ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)"
if [[ -z "$APP_ID" || "$APP_ID" == "None" ]]; then
  mismatch "[$ENV_TOKEN] App Registration - 존재하지 않는다: $APP_NAME"
  echo
  echo "=== drift ${DRIFTS}건 - bootstrap.sh를 실행하면 수렴한다 ===" >&2
  exit 1
fi
ok "[$ENV_TOKEN] App Registration 존재: $APP_NAME ($APP_ID)"

SP_ID="$(az_or_die "Service Principal 목록" -- az_ ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv)"
if [[ -z "$SP_ID" || "$SP_ID" == "None" ]]; then
  mismatch "[$ENV_TOKEN] Service Principal - 존재하지 않는다"
  echo
  echo "=== drift ${DRIFTS}건 - bootstrap.sh를 실행하면 수렴한다 ===" >&2
  exit 1
fi
ok "[$ENV_TOKEN] Service Principal 존재: $SP_ID"

# ── 불변식 (g): Entra 그룹 멤버십(transitive) 0건 - 반드시 (a)보다 먼저 ──
# 검사한다. az role assignment list --include-groups는 user 주체에만 그룹
# 전개를 수행하고 서비스 주체에는 작동하지 않는다(Azure 공식 문서). 그룹
# 멤버십이 0이면 (a)의 그룹 경유 우회 가능성이 원천 차단되므로, SP objectId
# 하나만 직접 조회하는 이후 검사가 유효해진다.
check_group_membership() {
  local memberships
  memberships="$(graph_get "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_ID}/transitiveMemberOf?\$select=id")"
  jq '.value | length' <<<"$memberships"
}
group_count="$(check_group_membership)"
require_int "$group_count" "[$ENV_TOKEN] Entra 그룹 멤버십"
if [[ "$group_count" -eq 0 ]]; then
  ok "[$ENV_TOKEN] Entra 그룹 멤버십: 0건"
else
  mismatch "[$ENV_TOKEN] Entra 그룹 멤버십 - ${group_count}건 존재(0건이어야 한다). 그룹 경유 role assignment가 이 검사를 우회할 수 있다"
fi

# ── 불변식 (a): 구독 스코프 role assignment 0건 (관련 구독 전체 순회) ───────
# ⚠️ 이 세션에서는 az account list로 접근 가능한 구독만 순회한다. 실행자의
#    Azure 계정이 모든 관련 구독을 볼 수 있어야 이 검사가 완전하다. 구독
#    목록 조회나 개별 role assignment 조회가 실패하면 die로 즉시 중단한다
#    (fail-closed) - "이 구독은 못 봤다"를 "이 구독엔 0건"으로 넘기지 않는다.
check_subscription_scope_assignments() {
  local subs sub count total=0
  subs="$(az_or_die "구독 목록" -- az_ account list --query "[].id" -o tsv)"
  for sub in $subs; do
    count="$(az_or_die "구독 $sub 의 role assignment" -- \
      az_ role assignment list --assignee "$SP_ID" --scope "/subscriptions/${sub}" \
        --subscription "$sub" --query "length([?scope=='/subscriptions/${sub}'])" -o tsv)"
    total=$((total + count))
  done
  echo "$total"
}
sub_scope_count="$(check_subscription_scope_assignments)"
require_int "$sub_scope_count" "[$ENV_TOKEN] 구독 스코프 role assignment"
if [[ "$sub_scope_count" -eq 0 ]]; then
  ok "[$ENV_TOKEN] 구독 스코프 role assignment: 0건"
else
  mismatch "[$ENV_TOKEN] 구독 스코프 role assignment - ${sub_scope_count}건 존재(0건이어야 한다)"
fi

# ── 불변식 (c): Entra 디렉터리 역할 0건 ─────────────────────────────────────
check_directory_roles() {
  local memberships
  memberships="$(graph_get "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_ID}/memberOf?\$select=id")"
  jq '[.value[] | select(."@odata.type"=="#microsoft.graph.directoryRole")] | length' <<<"$memberships"
}
dir_role_count="$(check_directory_roles)"
require_int "$dir_role_count" "[$ENV_TOKEN] Entra 디렉터리 역할"
if [[ "$dir_role_count" -eq 0 ]]; then
  ok "[$ENV_TOKEN] Entra 디렉터리 역할: 0건"
else
  mismatch "[$ENV_TOKEN] Entra 디렉터리 역할 - ${dir_role_count}건 존재(0건이어야 한다)"
fi

# ── 불변식 (d): Microsoft Graph 앱 권한 0건 ─────────────────────────────────
check_graph_app_permissions() {
  local assignments
  assignments="$(graph_get "https://graph.microsoft.com/v1.0/servicePrincipals/${SP_ID}/appRoleAssignments")"
  jq '.value | length' <<<"$assignments"
}
graph_perm_count="$(check_graph_app_permissions)"
require_int "$graph_perm_count" "[$ENV_TOKEN] Microsoft Graph 앱 권한"
if [[ "$graph_perm_count" -eq 0 ]]; then
  ok "[$ENV_TOKEN] Microsoft Graph 앱 권한: 0건"
else
  mismatch "[$ENV_TOKEN] Microsoft Graph 앱 권한 - ${graph_perm_count}건 존재(0건이어야 한다)"
fi

# ── 불변식 (e): 정적 자격증명 0건 + owners 목록 확인 ────────────────────────
# ⚠️ jq 결과를 바로 `$(( $(jq ...) + $(jq ...) ))` 형태로 산술 조립하지 않는다
# - 입력이 비면 "syntax error: operand expected"로 스크립트가 다른 이유로
# 깨진다. 각 길이를 변수로 받아 require_int로 검증한 뒤 더한다.
check_static_credentials() {
  local passwords keys pw_len key_len
  passwords="$(az_or_die "App 정적 자격증명(password)" -- az_ ad app credential list --id "$APP_ID" -o json)"
  keys="$(az_or_die "App 정적 자격증명(key)" -- az_ ad app show --id "$APP_ID" --query "keyCredentials" -o json)"
  pw_len="$(jq 'length' <<<"$passwords")"
  key_len="$(jq 'length' <<<"$keys")"
  require_int "$pw_len" "[$ENV_TOKEN] App 정적 자격증명(password) 개수 파싱"
  require_int "$key_len" "[$ENV_TOKEN] App 정적 자격증명(key) 개수 파싱"
  echo "$((pw_len + key_len))"
}
static_cred_count="$(check_static_credentials)"
require_int "$static_cred_count" "[$ENV_TOKEN] App Registration 정적 자격증명"
if [[ "$static_cred_count" -eq 0 ]]; then
  ok "[$ENV_TOKEN] App Registration 정적 자격증명: 0건"
else
  mismatch "[$ENV_TOKEN] App Registration 정적 자격증명 - ${static_cred_count}건 존재(0건이어야 한다). GitHub OIDC(FIC)만이 유일한 인증 경로여야 한다"
fi
# owners 허용 목록은 이 저장소가 아직 확정하지 않았다(bootstrap을 실행하는 사람이
# 자연히 owner가 되므로, 그 목록을 사람이 육안으로 확인하는 것으로 충분하다).
# 조회만 하고 이 스크립트가 자동으로 pass/fail을 매기지 않는다.
owner_names="$(az_or_die "App owners" -- az_ ad app owner list --id "$APP_ID" --query "[].userPrincipalName" -o tsv)"
owner_count="$(wc -l <<<"$owner_names" | tr -d ' ')"
[[ -z "$owner_names" ]] && owner_count=0
ok "[$ENV_TOKEN] App Registration owners: ${owner_count}건 (${owner_names:-없음}) - bootstrap 실행자가 예상 목록과 육안 대조할 것"

# ── 불변식 (f): FIC 전 필드(subject/issuer/audience) 완전 일치 ─────────────
check_fic() {  # check_fic <name> <expected-subject>
  local name="$1" expected_subject="$2" existing
  existing="$(az_or_die "FIC 목록" -- az_ ad app federated-credential list --id "$APP_ID" \
    --query "[?name=='$name']" -o json)"
  if [[ "$(jq 'length' <<<"$existing")" -eq 0 ]]; then
    echo absent; return
  fi
  local current
  current="$(jq -c '.[0] | {name, subject, issuer, audiences}' <<<"$existing")"
  json_eq "$current" "$(fic_expected_json "$name" "$expected_subject")" && echo ok || echo drift
}
report "[$ENV_TOKEN] FIC ($FIC_NAME_MAIN)" "$(check_fic "$FIC_NAME_MAIN" "$SUB_MAIN")"
report "[$ENV_TOKEN] FIC ($FIC_NAME_ENV)"  "$(check_fic "$FIC_NAME_ENV" "$SUB_ENV")"

# ── 커스텀 역할 정의: Actions/NotActions/DataActions 완전 일치 ──────────────
# config.sh의 role_definition_matches()를 bootstrap.sh와 공유한다(수렴 판단과
# drift 감지가 각자 다른 기준을 쓰면 "bootstrap은 ok인데 verify는 실패"가
# 생겨 verify.sh가 소음이 된다).
RG_SCOPE="/subscriptions/${EXPECTED_SUBSCRIPTION}/resourceGroups/${RG_NAME}"
STATE_RG_SCOPE="/subscriptions/${EXPECTED_SUBSCRIPTION}/resourceGroups/${STATE_RG_NAME}"

check_workload_role() {
  local current
  current="$(role_definition_list_retry "$WORKLOAD_ROLE_NAME")"
  role_definition_matches "$(workload_role_definition_json "$RG_SCOPE")" "$current" && echo ok || echo drift
}
report "[workload] 커스텀 역할 Actions/NotActions 완전 일치" "$(check_workload_role)"

check_state_data_role() {
  local current
  current="$(role_definition_list_retry "$STATE_DATA_ROLE_NAME")"
  role_definition_matches "$(state_data_role_definition_json "$STATE_RG_SCOPE")" "$current" && echo ok || echo drift
}
report "[state-data] 커스텀 역할 Actions/DataActions 완전 일치" "$(check_state_data_role)"

# ── 리소스 그룹 존재 확인 ────────────────────────────────────────────────────
# ⚠️ 순서: RG 존재 -> Storage Account 조회(RG가 있어야 유효한 조회다) -> 그
# 결과에 의존하는 컨테이너/role assignment 검사, 순으로 진행한다. state RG가
# 아직 없는 최초 상태에서 Storage Account를 먼저 조회하면
# ResourceGroupNotFound로 az_or_die가 die(exit 2)해, "처음 상태는 전부
# absent, exit 1"이라는 README의 멱등성 수용 기준과 어긋난다. RG가 없으면
# 그 밑에 걸린 모든 것을 absent로 즉시 보고하고 Storage Account 조회 자체를
# 시도하지 않는다.
check_rg_exists() {  # check_rg_exists <name>
  az_ group show --name "$1" &>/dev/null && echo ok || echo absent
}
workload_rg_status="$(check_rg_exists "$RG_NAME")"
state_rg_status="$(check_rg_exists "$STATE_RG_NAME")"
report "[workload] 리소스 그룹 존재" "$workload_rg_status"
report "[state] 리소스 그룹 존재" "$state_rg_status"

if [[ "$state_rg_status" == "ok" ]]; then
  SA_NAME="$(az_or_die "state Storage Account" -- az_ storage account list --resource-group "$STATE_RG_NAME" \
    --query "[?starts_with(name, '${SA_PREFIX}')].name | [0]" -o tsv)"
  [[ "$SA_NAME" == "None" ]] && SA_NAME=""
else
  SA_NAME=""
fi

if [[ -z "$SA_NAME" ]]; then
  mismatch "[state] Storage Account - 존재하지 않는다(prefix: $SA_PREFIX)"
else
  ok "[state] Storage Account 존재: $SA_NAME"
fi

check_container_exists() {
  [[ -n "$SA_NAME" ]] || { echo absent; return; }
  az_ storage container show --name "$CONTAINER_NAME" --account-name "$SA_NAME" --auth-mode login &>/dev/null \
    && echo ok || echo absent
}
report "[state] 컨테이너 존재" "$(check_container_exists)"

# ── role assignment 존재 확인 ────────────────────────────────────────────────
# bootstrap.sh가 만드는 두 role assignment가 실제로 존재하는지 확인한다. 이것이
# 없으면 CI 신원의 role assignment가 삭제돼도 verify.sh가 drift 없음을 보고한다.
check_role_assignment_exists() {  # check_role_assignment_exists <role-name> <scope>
  # roleDefinitionName이 아니라 roleDefinitionId로 필터링한다 — bootstrap.sh의
  # ensure_role_assignment와 같은 이유(join 지연, 2026-08-27 실측 확인).
  local role_name="$1" scope="$2" role_id count
  role_id="$(jq -r '.[0].id // empty' <<<"$(role_definition_list_retry "$role_name")")"
  [[ -n "$role_id" ]] || { echo absent; return; }
  count="$(az_or_die "role assignment($role_name @ $scope)" -- \
    az_ role assignment list --assignee "$SP_ID" --scope "$scope" \
      --query "length([?roleDefinitionId=='$role_id'])" -o tsv)"
  [[ "$count" -gt 0 ]] && echo ok || echo absent
}
report "[workload] role assignment 존재" "$(check_role_assignment_exists "$WORKLOAD_ROLE_NAME" "$RG_SCOPE")"
if [[ -n "$SA_NAME" ]]; then
  CONTAINER_SCOPE="${STATE_RG_SCOPE}/providers/Microsoft.Storage/storageAccounts/${SA_NAME}/blobServices/default/containers/${CONTAINER_NAME}"
  report "[state-data] role assignment 존재" "$(check_role_assignment_exists "$STATE_DATA_ROLE_NAME" "$CONTAINER_SCOPE")"
else
  mismatch "[state-data] role assignment - Storage Account가 없어 스코프를 계산할 수 없다"
fi

# ── 불변식 (a) 예외: 스포크 워크로드 RG 스코프의 외부(hub) principal role
#    assignment 허용 목록 완전 일치 (계획 4-1 Option A, 2026-09-03 절충 —
#    "0건"을 "허용 목록 1건과 완전 일치"로 승격한 유일한 예외. bootstrap.sh
#    6-1절이 만든다. 스코프는 VNet 리소스가 아니라 워크로드 RG 전체다 — dev
#    VNet이 아직 없는 bootstrap 시점에 함께 끝내기 위한 의도적 완화, 대가는
#    hub SP가 이 RG에 나중에 생길 다른 리소스에도 peer/action을 갖는다는 것) ──
if [[ "$BOOTSTRAP_TARGET" == "spoke" ]]; then
  HUB_APP_ID_CHECK="$(az_or_die "hub App Registration" -- az_ ad app list --display-name "$HUB_APP_NAME" --query "[0].appId" -o tsv)"
  if [[ -z "$HUB_APP_ID_CHECK" || "$HUB_APP_ID_CHECK" == "None" ]]; then
    mismatch "[$ENV_TOKEN] 크로스 구독 스포크 연결 - hub App Registration이 없다: $HUB_APP_NAME"
  else
    HUB_SP_ID_CHECK="$(az_or_die "hub Service Principal" -- az_ ad sp list --filter "appId eq '$HUB_APP_ID_CHECK'" --query "[0].id" -o tsv)"

    check_spoke_peer_role() {
      local current
      current="$(role_definition_list_retry "$SPOKE_PEER_ROLE_NAME")"
      role_definition_matches "$(spoke_peer_role_definition_json "$RG_SCOPE")" "$current" && echo ok || echo drift
    }
    report "[spoke-peer] 커스텀 역할 Actions 완전 일치" "$(check_spoke_peer_role)"

    # 워크로드 RG 스코프의 role assignment 전체에서 "이 대상 자신의 SP(workload
    # 역할, 이미 위에서 확인됨)"를 뺀 나머지가 허용 목록(hub SP + spoke-peer
    # 역할 1건)과 완전히 일치해야 한다. 이렇게 "자기 자신 제외"로 걸러야
    # workload role assignment 존재 확인과 중복 판정하지 않는다.
    rg_assignments="$(az_or_die "$ENV_TOKEN 워크로드 RG 스코프 role assignment" -- \
      az_ role assignment list --scope "$RG_SCOPE" --query "[?scope=='$RG_SCOPE']" -o json)"
    external_assignments="$(jq --arg sp "$SP_ID" '[.[] | select(.principalId != $sp)]' <<<"$rg_assignments")"
    external_count="$(jq 'length' <<<"$external_assignments")"
    require_int "$external_count" "[$ENV_TOKEN] 워크로드 RG 스코프 외부 principal role assignment 개수"
    if [[ "$external_count" -ne 1 ]]; then
      mismatch "[$ENV_TOKEN] 워크로드 RG 스코프 외부 principal role assignment - ${external_count}건 존재(정확히 1건이어야 한다)"
    else
      spoke_peer_role_id="$(jq -r '.[0].id // empty' <<<"$(role_definition_list_retry "$SPOKE_PEER_ROLE_NAME")")"
      actual_role_id="$(jq -r '.[0].roleDefinitionId' <<<"$external_assignments")"
      actual_principal_id="$(jq -r '.[0].principalId' <<<"$external_assignments")"
      if [[ -n "$spoke_peer_role_id" && "$actual_role_id" == "$spoke_peer_role_id" && "$actual_principal_id" == "$HUB_SP_ID_CHECK" ]]; then
        ok "[$ENV_TOKEN] 워크로드 RG 스코프 외부 principal role assignment: 허용 목록과 완전 일치(hub SP, $SPOKE_PEER_ROLE_NAME)"
      else
        mismatch "[$ENV_TOKEN] 워크로드 RG 스코프 외부 principal role assignment - 역할/principal 불일치(기대: $SPOKE_PEER_ROLE_NAME @ hub SP $HUB_SP_ID_CHECK, 실제: role=$actual_role_id principal=$actual_principal_id)"
      fi
    fi
  fi
fi

# ── AKS 클러스터용 identity·권한·RP 등록 (hub 대상만, 계획
#    .omc/plans/live-hub-aks.md 「identity·role assignment (bootstrap 확장)」절) ─
#
# ⚠️ 위 6종 불변식과 **범주가 다르다**. 불변식들은 CI 신원(App Registration)의 권한이
#    0건 또는 허용 목록과 완전히 일치하는지 보는 **음성 검사**다. 여기 세 검사는 CI
#    신원이 아닌 다른 principal(AKS 클러스터용 UAMI)에 대한 **양성 존재 확인**이다.
#
# role assignment 존재까지 확인하는 이유: identity만 확인하면 "identity는 있는데
# 서브넷 권한이 없는" 상태를 놓친다. 그 상태에서 live/hub/aks apply는 성공으로
# 끝나고 노드만 조용히 join에 실패한다 — verify.sh가 잡아야 하는 바로 그 죽은
# 경로다.
if [[ "$BOOTSTRAP_TARGET" == "hub" ]]; then
  check_aks_identity() {
    local principal_id
    principal_id="$(az_ identity show --name "$AKS_IDENTITY_NAME" --resource-group "$RG_NAME" \
      --query principalId -o tsv 2>/dev/null)" || principal_id=""
    [[ -n "$principal_id" && "$principal_id" != "None" ]] && echo ok || echo absent
  }
  report "[aks] user-assigned identity 존재 ($AKS_IDENTITY_NAME)" "$(check_aks_identity)"

  # ⚠️ 필터를 roleDefinitionId로 거는 것도, 스코프 동등 비교를 하지 않는 것도
  # bootstrap.sh의 ensure_role_assignment와 **의도적으로 동일**하다. 두 스크립트가
  # 서로 다른 기준을 쓰면 "bootstrap은 ok인데 verify는 실패"가 생겨 verify.sh가
  # 완화책이 아니라 소음이 된다(이 파일 앞부분의 커스텀 역할 검사와 같은 이유).
  check_aks_node_subnet_role() {
    local principal_id subnet_id role_id count
    principal_id="$(az_ identity show --name "$AKS_IDENTITY_NAME" --resource-group "$RG_NAME" \
      --query principalId -o tsv 2>/dev/null)" || principal_id=""
    [[ -n "$principal_id" && "$principal_id" != "None" ]] || { echo absent; return; }
    subnet_id="$(aks_node_subnet_id)"
    [[ -n "$subnet_id" ]] || { echo na; return; }
    role_id="$(jq -r '.[0].id // empty' <<<"$(role_definition_list_retry "$AKS_NODE_ROLE_NAME")")"
    [[ -n "$role_id" ]] || { echo absent; return; }
    count="$(az_or_die "role assignment($AKS_NODE_ROLE_NAME @ $subnet_id)" -- \
      az_ role assignment list --assignee "$principal_id" --scope "$subnet_id" \
        --query "length([?roleDefinitionId=='$role_id'])" -o tsv)"
    require_int "$count" "[aks] 노드 서브넷 role assignment 개수"
    [[ "$count" -gt 0 ]] && echo ok || echo absent
  }
  report "[aks] 노드 서브넷 role assignment ($AKS_NODE_ROLE_NAME @ $AKS_NODE_SUBNET_NAME)" \
    "$(check_aks_node_subnet_role)"

  check_container_service_provider() {
    local state
    state="$(az_or_die "Microsoft.ContainerService 등록 상태" -- \
      az_ provider show --namespace Microsoft.ContainerService --query registrationState -o tsv)"
    [[ "$state" == "Registered" ]] && echo ok || echo drift
  }
  report "[aks] Microsoft.ContainerService 리소스 프로바이더 등록" "$(check_container_service_provider)"
fi

# ── state RG 잠금 + 내구성 설정 ──────────────────────────────────────────────
check_state_lock() {
  az_ lock show --name "state-rg-protect" --resource-group "$STATE_RG_NAME" &>/dev/null \
    && echo ok || echo absent
}
report "[state] CannotDelete 잠금" "$(check_state_lock)"

# ⚠️ enabled 여부는 *DeleteRetentionPolicy.enabled로 판정한다(.days만 보면
# 비활성 상태에서도 이전 값이 남아 오탐이 난다 - bootstrap.sh의
# ensure_durability_settings()와 동일한 기준을 쓴다).
check_durability() {
  [[ -n "$SA_NAME" && "$SA_NAME" != "None" ]] || { echo absent; return; }
  local versioning blob_enabled container_enabled shared_key
  versioning="$(az_or_die "blob 버전 관리" -- az_ storage account blob-service-properties show \
    --account-name "$SA_NAME" --resource-group "$STATE_RG_NAME" --query isVersioningEnabled -o tsv)"
  blob_enabled="$(az_or_die "blob soft delete" -- az_ storage account blob-service-properties show \
    --account-name "$SA_NAME" --resource-group "$STATE_RG_NAME" --query deleteRetentionPolicy.enabled -o tsv)"
  container_enabled="$(az_or_die "컨테이너 soft delete" -- az_ storage account blob-service-properties show \
    --account-name "$SA_NAME" --resource-group "$STATE_RG_NAME" --query containerDeleteRetentionPolicy.enabled -o tsv)"
  shared_key="$(az_or_die "allowSharedKeyAccess" -- az_ storage account show --name "$SA_NAME" \
    --resource-group "$STATE_RG_NAME" --query allowSharedKeyAccess -o tsv)"
  if [[ "$versioning" == "true" && "$blob_enabled" == "true" && "$container_enabled" == "true" && "$shared_key" == "false" ]]; then
    echo ok
  else
    echo drift
  fi
}
report "[state] 버전 관리/소프트 삭제/allowSharedKeyAccess=false" "$(check_durability)"

echo
if [[ "$DRIFTS" -gt 0 ]]; then
  echo "=== drift ${DRIFTS}건 - bootstrap.sh를 실행하면 수렴한다 ===" >&2
  exit 1
fi
echo "=== drift 없음 ==="
