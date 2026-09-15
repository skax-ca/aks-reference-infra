#!/usr/bin/env bash
# drift 감지. **read-only**, 아무것도 만들거나 고치지 않는다.
#
# 부트스트랩이 IaC 밖이라 `tofu plan`이 없다. 이 스크립트가 그 역할을 대신한다.
# 기대 상태는 config.sh가 bootstrap.sh와 **공유**한다. 기준이 갈리면 소음이 된다.
#
# exit 0 = 기대 상태와 일치 / exit 1 = drift / exit 2 = 실행 불가(자격증명·구독·
# 테넌트 불일치, 또는 조회 자체가 실패해 판정할 수 없음)
#
# ⚠️ 이 스크립트는 음성 테스트로 증명해야 한다. 리소스를
#    일부러 어긋나게 한 뒤 exit 1이 나오는 것을 보지 않으면, "완화책이 있다"는
#    착각만 남는다. 구체적인 주입·복구 절차는 README.md에 있다.
#
# ⛔ **fail-closed 원칙**: 조회 자체가 실패하면(권한 부족, 네트워크 오류, 잘못된
#    쿼리 등) 절대 "0건이라 통과"로 처리하지 않는다. exit 2(실행 불가)로 즉시
#    중단한다. "권한이 없어 못 봤다"를 "0건이라 검증됐다"로 둔갑시키는 것은 이
#    스크립트 자신이 방지하려는 바로 그 실패 양상이다(원본 config.sh의
#    check_*가 조회 실패 시 absent로 처리하는 fail-closed 관례와 같은 정신).
#
# ⛔ 이 스크립트 전체를 CI 파이프라인의 공용 자격증명으로 무인 실행할 수 없다.
#    (a) ARM RBAC 스코프 검사(구독)는 Reader 권한으로 충분해 CI 분리 실행이
#    가능하지만, (c)~(g)(Entra 디렉터리 역할, Graph 앱 권한, 정적 자격증명·
#    owners, FIC 전 필드, 그룹 멤버십)는 Microsoft Graph 디렉터리 읽기 권한
#    (Application.Read.All/Directory.Read.All 또는 앱 소유권)을 요구하는데, 이
#    저장소는 CI 신원에 Graph 권한 자체를 0건으로 유지한다. 이 스크립트는 **사람
#    관리자 자격증명으로 수동 실행**하는 것을 전제로 작성됐다.
#
# ⚠️ 관리 그룹 스코프 role assignment 0건 검사는 두지 않는다. 이 설계의 OIDC 배포
#    경로는 관리 그룹을 쓰지 않는데(role assignment는 항상 구독·RG·컨테이너 스코프),
#    그 부재를 증명하려면 검증자에게 테넌트 루트 `Microsoft.Management/
#    managementGroups/read`가 필요하다. README가 명시한 실행 전제(구독 Owner/UAA)보다
#    훨씬 넓은 권한을 검증자에게만 요구하는 불균형이라 뺐다.
#
# ⚠️ **불변식 (a)는 "0건"이 아니라 "정확히 1건"이다.** CI 신원이 구독 전체 Owner
#    등가 역할을 가지므로(AWS 원본 `AdministratorAccess`와 스코프 축 대칭) "정확히
#    워크로드 역할 1건, 이 구독에만"이 기대 상태다. 권한 크기는 방어선이 아니고,
#    (c)~(g)(신뢰 경로·정적 자격증명·그룹 멤버십 관련 불변식)만 방어선이다. 그래서
#    그 검사들이 더 중요하다. **state 데이터 역할은 그대로 검사한다.** control-plane
#    (`Actions`)과 blob data-plane(`DataActions`)은 분리된 축이라, 워크로드 역할이
#    아무리 넓어도(Owner도 `dataActions: []`다) blob 데이터 접근은 대체하지 못한다.

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
      # 전혀 적용하지 않는다. check_x 안에서 die()가 exit 2를 해도 그
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

# Microsoft Graph 호출. 실패하면 즉시 exit 2 한다. --query로 서버 측 JMESPath를
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
# ⚠️ az_or_die로 감싼다. 감싸지 않으면 Graph 조회 권한 부족 등으로 이 명령
# 자체가 실패했을 때 exit 1(die가 아니라 az의 원래 종료 코드)로 끝나 "drift"로
# 오분류된다. exit code 규약상 조회 실패는 exit 2여야 한다.
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

# ── 불변식 (a): 구독 스코프 role assignment 정확히 1건(워크로드 역할, 이 구독) ──
# CI가 구독 전체 Owner 등가 역할을 가지므로 "0건"이 아니라 "정확히 워크로드
# 역할 1건, 그 구독에만"이 기대 상태다. 다른(엉뚱한) 구독에 role assignment가
# 있으면 여전히 drift다. 방어선이 FIC subject 하나뿐이므로, 이 검사는
# "그 도달 경로로 실제로 얻는 권한이 의도한 구독·역할과 정확히 일치하는가"를
# 확인하는 것으로 성격이 바뀌었다.
# ⚠️ az account list로 접근 가능한 구독만 순회한다. 실행자의 Azure 계정이 모든
#    관련 구독을 볼 수 있어야 이 검사가 완전하다. 조회 실패는 die로 즉시 중단
#    한다(fail-closed).
check_subscription_scope_assignments() {
  local subs sub total=0 role_id_here="" workload_role_id
  workload_role_id="$(jq -r '.[0].id // empty' <<<"$(role_definition_list_retry "$WORKLOAD_ROLE_NAME")")"
  subs="$(az_or_die "구독 목록" -- az_ account list --query "[].id" -o tsv)"
  for sub in $subs; do
    local scope assignments count
    scope="/subscriptions/${sub}"
    assignments="$(az_or_die "구독 $sub 의 role assignment" -- \
      az_ role assignment list --assignee "$SP_ID" --scope "$scope" \
        --subscription "$sub" --query "[?scope=='$scope']" -o json)"
    count="$(jq 'length' <<<"$assignments")"
    total=$((total + count))
    [[ "$sub" == "$EXPECTED_SUBSCRIPTION" ]] && role_id_here="$(jq -r '.[0].roleDefinitionId // empty' <<<"$assignments")"
  done
  if [[ "$total" -eq 1 && -n "$workload_role_id" && "$role_id_here" == "$workload_role_id" ]]; then
    echo "ok|${total}|${role_id_here}"
  else
    echo "drift|${total}|${role_id_here}"
  fi
}
# ⚠️ 명령 치환을 read의 리다이렉션 인자 자리에서 직접 평가하지 않는다. `IFS='|'
# read ... <<<"$(fn)"`처럼 쓰면 접두사 IFS 할당이 그 명령의 인자 전개(리다이렉션
# 대상의 명령 치환 포함) 동안에도 적용돼, `fn` 내부의 `for x in $y`(기본 IFS
# 기대)까지 IFS='|'를 물려받는다. check_subscription_scope_assignments 내부의
# 구독 순회 for문이 `\n` 대신 `|`로만 쪼개져 두 구독 ID가 한 토큰으로 뭉쳐 az
# 호출이 깨진다. 그래서 명령
# 치환을 먼저 일반 대입으로 캡처한 뒤, 이미 캡처된 순수 문자열에만 IFS='|' read
# 를 적용한다.
sub_scope_result="$(check_subscription_scope_assignments)"
IFS='|' read -r sub_scope_status sub_scope_total sub_scope_role_id <<<"$sub_scope_result"
require_int "$sub_scope_total" "[$ENV_TOKEN] 구독 스코프 role assignment 개수"
if [[ "$sub_scope_status" == ok ]]; then
  ok "[$ENV_TOKEN] 구독 스코프 role assignment: 워크로드 역할 1건과 일치($EXPECTED_SUBSCRIPTION)"
else
  mismatch "[$ENV_TOKEN] 구독 스코프 role assignment - 기대(워크로드 역할 1건 @ $EXPECTED_SUBSCRIPTION)와 다르다(총 ${sub_scope_total}건, 이 구독의 역할 ID: ${sub_scope_role_id:-없음})"
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

# ── 커스텀 역할 정의: Actions/NotActions 완전 일치 ──────────────────────────
# config.sh의 role_definition_matches()를 bootstrap.sh와 공유한다(수렴 판단과
# drift 감지가 각자 다른 기준을 쓰면 "bootstrap은 ok인데 verify는 실패"가
# 생겨 verify.sh가 소음이 된다).
RG_SCOPE="/subscriptions/${EXPECTED_SUBSCRIPTION}/resourceGroups/${RG_NAME}"
STATE_RG_SCOPE="/subscriptions/${EXPECTED_SUBSCRIPTION}/resourceGroups/${STATE_RG_NAME}"

check_workload_role() {
  local current
  current="$(role_definition_list_retry "$WORKLOAD_ROLE_NAME")"
  role_definition_matches "$(workload_role_definition_json "$SUBSCRIPTION_SCOPE")" "$current" && echo ok || echo drift
}
report "[workload] 커스텀 역할 Actions/NotActions 완전 일치" "$(check_workload_role)"

# ⚠️ state 데이터 역할을 "워크로드 역할이 이미 커버한다"고 보고 검사에서 빼지
# 않는다(config.sh 참고. Azure RBAC는 control-plane Actions와 blob data-plane
# DataActions가 분리된 축이라, Owner 등가 워크로드 역할이 아무리 넓어도 blob
# 데이터 접근은 별도로 필요하다).
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

# ⚠️ 워크로드 역할의 별도 "role assignment 존재" 확인은 위 불변식 (a)(구독
# 스코프 정확히 1건 검사)가 이미 포함해 여기서 다시 안 한다(중복 판정 방지).
# state-data는 (a)가 보지 않는 컨테이너 스코프라 여기서 별도로 확인한다. 이것이
# 없으면 role assignment가 지워져도 verify.sh가 drift 없음을 보고한다.
check_role_assignment_exists() {  # check_role_assignment_exists <role-name> <scope>
  local role_name="$1" scope="$2" role_id count
  role_id="$(jq -r '.[0].id // empty' <<<"$(role_definition_list_retry "$role_name")")"
  [[ -n "$role_id" ]] || { echo absent; return; }
  count="$(az_or_die "role assignment($role_name @ $scope)" -- \
    az_ role assignment list --assignee "$SP_ID" --scope "$scope" \
      --query "length([?roleDefinitionId=='$role_id'])" -o tsv)"
  [[ "$count" -gt 0 ]] && echo ok || echo absent
}
if [[ -n "$SA_NAME" ]]; then
  CONTAINER_SCOPE="${STATE_RG_SCOPE}/providers/Microsoft.Storage/storageAccounts/${SA_NAME}/blobServices/default/containers/${CONTAINER_NAME}"
  report "[state-data] role assignment 존재" "$(check_role_assignment_exists "$STATE_DATA_ROLE_NAME" "$CONTAINER_SCOPE")"
else
  mismatch "[state-data] role assignment - Storage Account가 없어 스코프를 계산할 수 없다"
fi

# ── 불변식 (a) 예외: 스포크 워크로드 RG 스코프의 외부 principal role assignment
#    허용 목록 완전 일치 ("0건"을 "허용 목록과 완전 일치"로 승격한 유일한 예외.
#    스코프는 VNet 리소스가 아니라 워크로드 RG 전체다. 스포크 VNet이 아직 없는
#    bootstrap 시점에 함께 끝내기 위한 의도적 완화이고, 대가는 hub SP가 이 RG에
#    나중에 생길 다른 VNet에도 peer·read를 갖는다는 것이다) ──
#
# ⚠️ 이 허용 목록은 두 갈래로 구성된다:
#    1) hub SP + spoke-peer 역할(bootstrap.sh 6-1절이 만든다). principal·역할
#       둘 다 정확히 일치해야 하는 엄격 검사.
#    2) `WORKBENCH_ADMIN_LOGIN_ROLE_NAME`(live/<env>/workbench가 Terraform으로
#       만드는, 사람이 SSH sudo 로그인하는 role assignment). bootstrap이 만든
#       게 아니라 principal identity를 알 수 없으므로(Terraform 변수, GitHub
#       repo 변수 소관) 위 "App Registration owners"와 같은 원칙: 존재 자체는
#       허용하되 신원은 사람이 육안 대조한다.
#    이 두 갈래 중 어디에도 안 걸리는 항목은 여전히 fail-closed로 drift
#    취급한다(예상 밖 principal이 RG 스코프에 role assignment를 얻은 경우).
#
# ⚠️ RG 스코프에 직접 걸린 할당만 본다(`[?scope=='$RG_SCOPE']`). 하위 리소스
#    스코프의 할당은 이 검사가 잡지 못한다. spoke-peer에 roleAssignments/write를
#    주지 않는 이유 중 하나다(config.sh).
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
    # 역할, 이미 위에서 확인됨)"를 뺀 나머지를 세 갈래로 분류한다. "정확히 1건,
    # hub SP" 단일 판정은 workbench_admin_login이 있으면 틀린다. "자기 자신 제외"로
    # 걸러야 workload role assignment 존재 확인과 중복 판정하지 않는다.
    rg_assignments="$(az_or_die "$ENV_TOKEN 워크로드 RG 스코프 role assignment" -- \
      az_ role assignment list --scope "$RG_SCOPE" --query "[?scope=='$RG_SCOPE']" -o json)"
    external_assignments="$(jq --arg sp "$SP_ID" '[.[] | select(.principalId != $sp)]' <<<"$rg_assignments")"
    external_count="$(jq 'length' <<<"$external_assignments")"
    require_int "$external_count" "[$ENV_TOKEN] 워크로드 RG 스코프 외부 principal role assignment 개수"

    spoke_peer_role_id="$(jq -r '.[0].id // empty' <<<"$(role_definition_list_retry "$SPOKE_PEER_ROLE_NAME")")"
    hub_peer_assignments="$(jq --arg rid "$spoke_peer_role_id" '[.[] | select(.roleDefinitionId == $rid)]' <<<"$external_assignments")"
    hub_peer_count="$(jq 'length' <<<"$hub_peer_assignments")"
    admin_login_assignments="$(jq --arg name "$WORKBENCH_ADMIN_LOGIN_ROLE_NAME" \
      '[.[] | select(.roleDefinitionName == $name)]' <<<"$external_assignments")"
    admin_login_count="$(jq 'length' <<<"$admin_login_assignments")"
    other_assignments="$(jq --arg rid "$spoke_peer_role_id" --arg name "$WORKBENCH_ADMIN_LOGIN_ROLE_NAME" \
      '[.[] | select(.roleDefinitionId != $rid and .roleDefinitionName != $name)]' <<<"$external_assignments")"
    other_count="$(jq 'length' <<<"$other_assignments")"

    # 1) hub SP + spoke-peer 역할. 엄격 검사(principal·역할 둘 다 정확히 일치해야
    #    한다).
    if [[ "$hub_peer_count" -eq 1 ]]; then
      actual_principal_id="$(jq -r '.[0].principalId' <<<"$hub_peer_assignments")"
      if [[ -n "$spoke_peer_role_id" && "$actual_principal_id" == "$HUB_SP_ID_CHECK" ]]; then
        ok "[$ENV_TOKEN] 워크로드 RG 스코프 hub SP role assignment: 허용 목록과 완전 일치($SPOKE_PEER_ROLE_NAME)"
      else
        mismatch "[$ENV_TOKEN] 워크로드 RG 스코프 hub SP role assignment - principal 불일치(기대: hub SP $HUB_SP_ID_CHECK, 실제: $actual_principal_id)"
      fi
    else
      mismatch "[$ENV_TOKEN] 워크로드 RG 스코프 hub SP($SPOKE_PEER_ROLE_NAME) role assignment - ${hub_peer_count}건 존재(정확히 1건이어야 한다)"
    fi

    # 2) workbench admin login. bootstrap이 만든 게 아니라(live/<env>/workbench,
    #    Terraform 소관) principal identity를 이 스크립트가 검증할 수 없다.
    #    "App Registration owners"와 같은 원칙: 존재는 허용하되 신원은 사람이
    #    육안 대조한다.
    if [[ "$admin_login_count" -le 1 ]]; then
      ok "[$ENV_TOKEN] 워크로드 RG 스코프 $WORKBENCH_ADMIN_LOGIN_ROLE_NAME role assignment: ${admin_login_count}건(live/${ENV_TOKEN}/workbench 소관. 사람이 예상 계정과 육안 대조할 것)"
    else
      mismatch "[$ENV_TOKEN] 워크로드 RG 스코프 $WORKBENCH_ADMIN_LOGIN_ROLE_NAME role assignment - ${admin_login_count}건 존재(0~1건이어야 한다)"
    fi

    # 3) 그 외. 여전히 fail-closed. 알려진 두 갈래 어디에도 안 걸리면 drift.
    if [[ "$other_count" -eq 0 ]]; then
      ok "[$ENV_TOKEN] 워크로드 RG 스코프 알 수 없는 외부 principal role assignment: 0건"
    else
      mismatch "[$ENV_TOKEN] 워크로드 RG 스코프 알 수 없는 외부 principal role assignment - ${other_count}건 존재(0건이어야 한다)"
    fi
  fi

  # ── hub-peer(spoke-peer와 정반대 방향) drift 검사 ────────────────────────────
  #    역할 정의·role assignment 둘 다 hub 구독에 있으므로 --subscription
  #    "$HUB_SUBSCRIPTION"으로 명시 라우팅한다(bootstrap.sh와 같은 패턴). 할당
  #    대상은 이 spoke 자신의 SP_ID다. hub-peer는 "이 spoke가 hub를 읽을 권한"이라
  #    assignee가 항상 자기 자신이고, spoke-peer와 달리 외부 principal을 찾을 필요가
  #    없다.
  HUB_RG_SCOPE="/subscriptions/${HUB_SUBSCRIPTION}/resourceGroups/${HUB_RG_NAME}"

  check_hub_peer_role() {
    local current
    current="$(role_definition_list_retry "$HUB_PEER_ROLE_NAME" "$HUB_SUBSCRIPTION")"
    role_definition_matches "$(hub_peer_role_definition_json "$HUB_RG_SCOPE")" "$current" && echo ok || echo drift
  }
  report "[hub-peer] 커스텀 역할 Actions 완전 일치" "$(check_hub_peer_role)"

  check_hub_peer_assignment_exists() {
    local role_id count
    role_id="$(jq -r '.[0].id // empty' <<<"$(role_definition_list_retry "$HUB_PEER_ROLE_NAME" "$HUB_SUBSCRIPTION")")"
    [[ -n "$role_id" ]] || { echo absent; return; }
    count="$(az_or_die "role assignment($HUB_PEER_ROLE_NAME @ $HUB_RG_SCOPE)" -- \
      az_ role assignment list --assignee "$SP_ID" --scope "$HUB_RG_SCOPE" --subscription "$HUB_SUBSCRIPTION" \
        --query "length([?roleDefinitionId=='$role_id'])" -o tsv)"
    [[ "$count" -gt 0 ]] && echo ok || echo absent
  }
  report "[hub-peer] role assignment 존재" "$(check_hub_peer_assignment_exists)"
fi

# ── RP 등록 (hub·spoke 공통) ─────────────────────────────────────────────────
# ⚠️ AKS 클러스터용 identity·role assignment는 검사하지 않는다. 그 산출물은
# `live/<env>/aks`의 Terraform state 안에 있어 `tofu plan`이 자기 검증 역할을 하고,
# CI 신원(App Registration) 권한을 보는 이 스크립트의 검사 대상이 아니다. RP 등록만
# 검사한다(목록과 근거는 bootstrap.sh의 같은 자리 주석).
check_resource_provider() {
  local ns="$1" state
  state="$(az_or_die "${ns} 등록 상태" -- \
    az_ provider show --namespace "$ns" --query registrationState -o tsv)"
  [[ "$state" == "Registered" ]] && echo ok || echo drift
}
for ns in Microsoft.ContainerService Microsoft.Compute Microsoft.ManagedIdentity; do
  report "[aks] ${ns} 리소스 프로바이더 등록" "$(check_resource_provider "$ns")"
done

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
