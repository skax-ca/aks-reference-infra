#!/usr/bin/env bash
# 부트스트랩 (IaC 밖). state Storage Account · App Registration · 커스텀 역할 ·
# 리소스 잠금을 만든다.
#
# 멱등: 항목마다 먼저 검사하고 **다를 때만** 적용한다. 두 번째 실행은 changed=0
#       이어야 한다. 그것이 이 스크립트의 수용 기준이다.
#
# 생성 순서가 자유롭지 않다. Entra는 존재 검증을 하는 참조가 있고, 잠금은 그 스코프
# 안의 모든 후속 변경을 막는다:
#   ① 리소스 그룹(워크로드·state 각각 선생성)
#   ② Storage Account + 컨테이너
#   ③ App Registration + Service Principal
#   ④ Federated Identity Credential
#   ⑤ role assignment(워크로드 커스텀 역할은 구독 전체 스코프 / state 데이터
#     커스텀 역할은 컨테이너 스코프. control-plane과 분리된 blob data-plane 축이라
#     워크로드 역할이 아무리 넓어도 대체 못 한다, config.sh 참고)
#   ⑥ RP 등록(hub·spoke 공통)
#   ⑦ state RG 잠금. 반드시 마지막
#
# ⛔ 워크로드 리소스 그룹에는 잠금을 걸지 않는다. Azure 리소스 잠금은 상속되므로
#    워크로드 RG에 걸면 그 안의 모든 리소스 교체(destroy → create)가 막혀 무인
#    자동화가 파괴된다. 자기 RG 삭제 방지는 커스텀 역할의 notActions로 해결한다.

cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

CHANGES=0

echo "=== 부트스트랩 (target=$BOOTSTRAP_TARGET env=$ENV_TOKEN subscription=$EXPECTED_SUBSCRIPTION) ==="
assert_subscription_tenant
echo "구독/테넌트 확인 완료"
echo

# ── 1. 리소스 그룹 선생성 (사람의 관리자 자격증명으로, CI 신원은 관여하지 않는다) ─
# bootstrap 계층은 이미 IaC 밖에 있고 사람이 실행하므로, 여기서 RG를 만드는 것은
# 새로운 신뢰 계층이 아니다. 이렇게 하면 "RG 생성/삭제용 구독 스코프 권한"이 CI
# 신원에 아예 필요 없어진다.
ensure_resource_group() {  # ensure_resource_group <name> <label>
  local name="$1" label="$2"
  if az_ group show --name "$name" &>/dev/null; then
    ok "[$label] 리소스 그룹 존재: $name"
  else
    az_ group create --name "$name" --location "$REGION" \
      --tags "Workload=$TAG_WORKLOAD" "Environment=$TAG_ENVIRONMENT" "ManagedBy=$TAG_MANAGED_BY" \
      >/dev/null
    changed "[$label] 리소스 그룹 생성: $name"
  fi
}
ensure_resource_group "$RG_NAME" "workload"
ensure_resource_group "$STATE_RG_NAME" "state"

# ── 2. Storage Account + 컨테이너 ────────────────────────────────────────────
# state Storage Account는 워크로드 RG가 아니라 별도 RG(STATE_RG_NAME)에 둔다. 7단계의
# CannotDelete 잠금을 워크로드 RG에 걸지 않으면서 state만 보호하기 위해서다. CI 신원은
# 구독 전체 Owner 등가라 RBAC로는 두 RG를 구분하지 않는다.
find_storage_account() {
  az_ storage account list --resource-group "$STATE_RG_NAME" \
    --query "[?starts_with(name, '${SA_PREFIX}')].name | [0]" -o tsv 2>/dev/null
}

ensure_storage_account() {
  SA_NAME="$(find_storage_account)"
  if [[ -z "$SA_NAME" || "$SA_NAME" == "None" ]]; then
    SA_NAME="$(new_storage_account_name)"
    az_ storage account create \
      --name "$SA_NAME" --resource-group "$STATE_RG_NAME" --location "$REGION" \
      --sku Standard_LRS --kind StorageV2 \
      --allow-shared-key-access false \
      --min-tls-version TLS1_2 \
      --tags "Workload=$TAG_WORKLOAD" "Environment=$TAG_ENVIRONMENT" "ManagedBy=$TAG_MANAGED_BY" \
      >/dev/null
    changed "[state] Storage Account 생성: $SA_NAME"
  else
    ok "[state] Storage Account 존재: $SA_NAME"
    local shared_key
    shared_key="$(az_ storage account show --name "$SA_NAME" --resource-group "$STATE_RG_NAME" \
      --query allowSharedKeyAccess -o tsv)"
    if [[ "$shared_key" != "false" ]]; then
      az_ storage account update --name "$SA_NAME" --resource-group "$STATE_RG_NAME" \
        --allow-shared-key-access false >/dev/null
      changed "[state] allowSharedKeyAccess=false 강제 적용"
    else
      ok "[state] allowSharedKeyAccess=false"
    fi
  fi
  readonly SA_NAME
}
ensure_storage_account

# 내구성: blob 버전 관리 + blob soft delete + 컨테이너 소프트 삭제.
# 컨테이너 자체가 삭제되는 사고는 blob soft delete로 막히지 않으므로 별도로 켠다.
ensure_durability_settings() {
  # ⚠️ enabled 여부는 *DeleteRetentionPolicy.enabled로 판정한다. .days 필드만
  # 보면 비활성 상태에서도 이전에 쓰던 값이 남아 있을 수 있어(Azure 동작) 오탐이
  # 난다. verify.sh의 check_durability()도 같은 필드를 본다.
  local versioning blob_enabled container_enabled
  versioning="$(az_ storage account blob-service-properties show \
    --account-name "$SA_NAME" --resource-group "$STATE_RG_NAME" \
    --query isVersioningEnabled -o tsv)"
  blob_enabled="$(az_ storage account blob-service-properties show \
    --account-name "$SA_NAME" --resource-group "$STATE_RG_NAME" \
    --query deleteRetentionPolicy.enabled -o tsv 2>/dev/null || echo "false")"
  container_enabled="$(az_ storage account blob-service-properties show \
    --account-name "$SA_NAME" --resource-group "$STATE_RG_NAME" \
    --query containerDeleteRetentionPolicy.enabled -o tsv 2>/dev/null || echo "false")"

  if [[ "$versioning" == "true" && "$blob_enabled" == "true" && "$container_enabled" == "true" ]]; then
    ok "[state] 버전 관리 + blob/컨테이너 소프트 삭제"
  else
    az_ storage account blob-service-properties update \
      --account-name "$SA_NAME" --resource-group "$STATE_RG_NAME" \
      --enable-versioning true \
      --enable-delete-retention true --delete-retention-days 30 \
      --enable-container-delete-retention true --container-delete-retention-days 30 \
      >/dev/null
    changed "[state] 버전 관리 + blob/컨테이너 소프트 삭제(30일) 설정"
  fi
}
ensure_durability_settings

ensure_container() {
  if az_ storage container show --name "$CONTAINER_NAME" --account-name "$SA_NAME" --auth-mode login &>/dev/null; then
    ok "[state] 컨테이너 존재: $CONTAINER_NAME"
  else
    az_ storage container create --name "$CONTAINER_NAME" --account-name "$SA_NAME" --auth-mode login \
      >/dev/null
    changed "[state] 컨테이너 생성: $CONTAINER_NAME"
  fi
}
ensure_container

# ── 3. App Registration + Service Principal ─────────────────────────────────
ensure_app_registration() {
  local app_id
  app_id="$(az_ ad app list --display-name "$APP_NAME" --query "[0].appId" -o tsv)"
  if [[ -z "$app_id" || "$app_id" == "None" ]]; then
    app_id="$(az_ ad app create --display-name "$APP_NAME" --query appId -o tsv)"
    changed "[$ENV_TOKEN] App Registration 생성: $APP_NAME ($app_id)"
  else
    ok "[$ENV_TOKEN] App Registration 존재: $APP_NAME ($app_id)"
  fi
  readonly APP_ID="$app_id"

  local sp_id
  sp_id="$(az_ ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv)"
  if [[ -z "$sp_id" || "$sp_id" == "None" ]]; then
    retry_on_replication_delay az_ ad sp create --id "$APP_ID"
    sp_id="$(az_ ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv)"
    changed "[$ENV_TOKEN] Service Principal 생성: $sp_id"
  else
    ok "[$ENV_TOKEN] Service Principal 존재: $sp_id"
  fi
  readonly SP_ID="$sp_id"
}
ensure_app_registration

# ⛔ 정적 자격증명(client secret·certificate)을 이 스크립트 어디에서도 만들지
#    않는다. GitHub OIDC(FIC)만이 유일한 인증 경로다. verify.sh가 0건을 검사한다.

# ── 4. Federated Identity Credential (배포 브랜치 정책만) ─────────────────────
ensure_fic() {  # ensure_fic <fic-name> <subject>
  local name="$1" subject="$2" existing
  existing="$(az_ ad app federated-credential list --id "$APP_ID" \
    --query "[?name=='$name']" -o json)"
  if [[ "$(jq 'length' <<<"$existing")" -eq 0 ]]; then
    retry_on_conflict az_ ad app federated-credential create --id "$APP_ID" --parameters \
      "$(fic_expected_json "$name" "$subject")"
    changed "[$ENV_TOKEN] FIC 생성: $name ($subject)"
  else
    local current
    current="$(jq -c '.[0] | {name, subject, issuer, audiences}' <<<"$existing")"
    if json_eq "$current" "$(fic_expected_json "$name" "$subject")"; then
      ok "[$ENV_TOKEN] FIC 일치: $name"
    else
      local fed_id
      fed_id="$(jq -r '.[0].id' <<<"$existing")"
      az_ ad app federated-credential update --id "$APP_ID" --federated-credential-id "$fed_id" \
        --parameters "$(fic_expected_json "$name" "$subject")" >/dev/null
      changed "[$ENV_TOKEN] FIC 갱신: $name"
    fi
  fi
}
ensure_fic "$FIC_NAME_MAIN" "$SUB_MAIN"
ensure_fic "$FIC_NAME_ENV" "$SUB_ENV"

# ── 5. 커스텀 역할 생성/갱신 (정확한 정의는 config.sh 참고) ───────────────────
# ⚠️ 비교는 config.sh의 role_definition_matches()로 한다(NotActions만 비교하지
# 않는다). 이 함수를 verify.sh도 그대로 쓴다. 수렴 판단과 drift 감지가 각자
# 다른 기준을 쓰면 "bootstrap은 ok인데 verify는 실패"가 생겨 verify.sh가
# 소음이 된다.
ensure_custom_role() {  # ensure_custom_role <role-name> <definition-json> <label> [subscription]
  # ⚠️ 존재 여부를 판단하는 "첫" 조회도 role_definition_list_retry를 거친다.
  # 단발 조회는 캐시 지연으로 실재하는 역할을 빈 배열로 돌려줄 수 있고, 그러면
  # "부재"로 오판해 `role definition create`가 `RoleDefinitionWithSameNameExists`로
  # 죽는다. 진짜 부재(최초 부트스트랩)라면 재시도 5회 후에도 빈 배열이라 정상적으로
  # create 경로를 탄다. 그 경우의 비용은 최대 15초뿐이다.
  #
  # [subscription]이 주어지면(hub-peer 전용) 이 대상 자신의 구독이 아닌 다른
  # 구독에 역할을 만든다/갱신한다. az 전역 --subscription로 현재 컨텍스트와
  # 무관하게 라우팅한다. 빈 배열 전개 대신 두 분기를 완전히 분리한다(macOS
  # bash 3.2가 `set -u` 아래에서 빈 배열 참조를 unbound variable로 죽인다,
  # config.sh의 role_definition_list_retry 주석 참고).
  local role_name="$1" definition="$2" label="$3" sub="${4:-}" current existing_id
  current="$(role_definition_list_retry "$role_name" "$sub")"
  existing_id="$(jq -r '.[0].id // empty' <<<"$current")"
  if [[ -z "$existing_id" ]]; then
    if [[ -n "$sub" ]]; then
      az_ role definition create --role-definition "$definition" --subscription "$sub" >/dev/null
    else
      az_ role definition create --role-definition "$definition" >/dev/null
    fi
    changed "[$label] 커스텀 역할 생성: $role_name"
  else
    if role_definition_matches "$definition" "$current"; then
      ok "[$label] 커스텀 역할 일치: $role_name"
    else
      # id를 명시해야 이름 기반의 애매한 검색 없이 정확히 이 객체를 갱신한다
      # (id 없이 update하면 CLI가 'Role "id" is missing' 경고를 내며 이름으로
      # 다시 찾는다).
      if [[ -n "$sub" ]]; then
        az_ role definition update \
          --role-definition "$(jq --arg id "$existing_id" '. + {id: $id}' <<<"$definition")" \
          --subscription "$sub" >/dev/null
      else
        az_ role definition update \
          --role-definition "$(jq --arg id "$existing_id" '. + {id: $id}' <<<"$definition")" >/dev/null
      fi
      changed "[$label] 커스텀 역할 갱신: $role_name (Actions/NotActions/DataActions 불일치)"
    fi
  fi
}

RG_SCOPE="/subscriptions/${EXPECTED_SUBSCRIPTION}/resourceGroups/${RG_NAME}"
STATE_RG_SCOPE="/subscriptions/${EXPECTED_SUBSCRIPTION}/resourceGroups/${STATE_RG_NAME}"

ensure_custom_role "$WORKLOAD_ROLE_NAME" "$(workload_role_definition_json "$SUBSCRIPTION_SCOPE")" "workload"
ensure_custom_role "$STATE_DATA_ROLE_NAME" "$(state_data_role_definition_json "$STATE_RG_SCOPE")" "state-data"

# ── 6. role assignment (기본 assignee = 이 대상 자신의 CI 신원 SP_ID) ────────
ensure_role_assignment() {  # ensure_role_assignment <role-name> <scope> <label> <assignee-object-id> [subscription]
  # ⚠️ roleDefinitionName이 아니라 roleDefinitionId로 필터링한다. roleDefinitionName은
  # role assignment 객체가 조회 시점에 역할 정의 쪽과 조인해서 채우는 값이라, 방금
  # role assignment를 만들거나 역할 정의를 갱신한 직후엔 한동안 null로 보인다. 그러면
  # 이미 있는 할당을 0건으로 봐서 불필요한 create를 유발한다. roleDefinitionId는
  # 조인이 필요 없는 role assignment 자신의 직접 속성이라 지연이 없다.
  #
  # ⚠️ assignee를 4번째 인자로 명시한다. 전역 $SP_ID에 암묵 의존하면, assignee가 이
  # 대상 자신이 아니라 hub SP인 호출(spoke-peer)이 틀린 신원에 할당된다.
  #
  # [subscription]이 주어지면(hub-peer 전용) 역할 정의·role assignment 둘 다
  # 이 대상 자신의 구독이 아닌 다른 구독(hub)에 있다는 뜻이다. az 전역
  # --subscription로 라우팅한다. ensure_custom_role과 동일한 이유로 빈 배열
  # 전개 대신 두 분기를 분리한다.
  local role_name="$1" scope="$2" label="$3" assignee="$4" sub="${5:-}"
  local role_id existing
  role_id="$(jq -r '.[0].id' <<<"$(role_definition_list_retry "$role_name" "$sub")")"
  if [[ -n "$sub" ]]; then
    existing="$(az_ role assignment list --assignee "$assignee" --scope "$scope" --subscription "$sub" \
      --query "[?roleDefinitionId=='$role_id']" -o json)"
  else
    existing="$(az_ role assignment list --assignee "$assignee" --scope "$scope" \
      --query "[?roleDefinitionId=='$role_id']" -o json)"
  fi
  if [[ "$(jq 'length' <<<"$existing")" -eq 0 ]]; then
    if [[ -n "$sub" ]]; then
      retry_on_replication_delay az_ role assignment create --assignee "$assignee" \
        --role "$role_name" --scope "$scope" --subscription "$sub"
    else
      retry_on_replication_delay az_ role assignment create --assignee "$assignee" \
        --role "$role_name" --scope "$scope"
    fi
    changed "[$label] role assignment 생성: $role_name @ $scope"
  else
    ok "[$label] role assignment 존재: $role_name"
  fi
}
ensure_role_assignment "$WORKLOAD_ROLE_NAME" "$SUBSCRIPTION_SCOPE" "workload" "$SP_ID"
CONTAINER_SCOPE="${STATE_RG_SCOPE}/providers/Microsoft.Storage/storageAccounts/${SA_NAME}/blobServices/default/containers/${CONTAINER_NAME}"
ensure_role_assignment "$STATE_DATA_ROLE_NAME" "$CONTAINER_SCOPE" "state-data" "$SP_ID"

# ── 6-1. 크로스 구독 스포크 연결 권한 (스포크 대상만) ──────────────────────────
#    VNet 리소스 스코프 대신 워크로드 RG 스코프로 완화해 스포크 VNet이 아직 없는 이
#    시점(bootstrap.sh는 항상 networking apply보다 먼저 실행된다)에 함께 끝낸다.
#    대가는 hub SP가 이 RG에 나중에 생길 다른 VNet에도 peer·read 권한을 갖는다는
#    것이다. 그 대신 스포크가 늘 때마다 별도 스크립트를 한 번 더 실행하는 마찰이
#    없다. AWS 원본(RAM 계정/OU 단위 공유 후 스포크가 자기 계정에서 attachment
#    생성)과 가장 가까운 근사다. Azure vWAN엔 RAM의 정확한 대응물이 없다.
if [[ "$BOOTSTRAP_TARGET" == "spoke" ]]; then
  HUB_APP_ID="$(az_or_die "hub App Registration" -- az_ ad app list --display-name "$HUB_APP_NAME" --query "[0].appId" -o tsv)"
  [[ -n "$HUB_APP_ID" && "$HUB_APP_ID" != "None" ]] \
    || die "hub App Registration이 없다: $HUB_APP_NAME (hub bootstrap을 먼저 실행할 것)"
  HUB_SP_ID="$(az_or_die "hub Service Principal" -- az_ ad sp list --filter "appId eq '$HUB_APP_ID'" --query "[0].id" -o tsv)"
  [[ -n "$HUB_SP_ID" && "$HUB_SP_ID" != "None" ]] || die "hub Service Principal이 없다: $HUB_APP_NAME"
  ok "[hub] Service Principal 확인: $HUB_SP_ID ($HUB_APP_NAME)"

  ensure_custom_role "$SPOKE_PEER_ROLE_NAME" "$(spoke_peer_role_definition_json "$RG_SCOPE")" "spoke-peer"
  ensure_role_assignment "$SPOKE_PEER_ROLE_NAME" "$RG_SCOPE" "spoke-peer" "$HUB_SP_ID"

  # ── 6-1-b. hub-peer(spoke-peer와 정반대 방향) ───────────────────────────────
  #    이 spoke의 CI 신원(자기 자신, $SP_ID)이 hub 구독의 hub
  #    워크로드 RG에서 ArgoCD UAMI를 읽을 수 있게 한다. 역할 정의·할당 둘 다
  #    hub 구독 안에서 이뤄지므로(스코프가 spoke가 아니라 hub RG) az 컨텍스트가
  #    이미 spoke 구독인 이 실행 중에도 --subscription "$HUB_SUBSCRIPTION"으로
  #    명시 라우팅한다. spoke-peer는 이 RG_SCOPE(spoke 자기 RG)에 만들지만,
  #    hub-peer는 HUB_RG_SCOPE(hub RG, 다른 구독)에 만든다. 스코프 변수를
  #    혼동하지 않는다.
  HUB_RG_SCOPE="/subscriptions/${HUB_SUBSCRIPTION}/resourceGroups/${HUB_RG_NAME}"
  ensure_custom_role "$HUB_PEER_ROLE_NAME" "$(hub_peer_role_definition_json "$HUB_RG_SCOPE")" "hub-peer" "$HUB_SUBSCRIPTION"
  ensure_role_assignment "$HUB_PEER_ROLE_NAME" "$HUB_RG_SCOPE" "hub-peer" "$SP_ID" "$HUB_SUBSCRIPTION"
fi

# ── 6-2. RP 등록 (hub·spoke 공통) ────────────────────────────────────────────
# ⚠️ AKS 클러스터용 identity·role assignment는 여기서 만들지 않는다(config.sh 참고.
# `live/<env>/aks`가 자기 identity를 Terraform으로 직접 만든다). RP 등록만 남긴다.
# CI가 구독 전체 Owner라 `*/register/action`도 갖지만, 저빈도 1회성 작업이라 옮길
# 실익이 낮다(README 참고).
#
# hub·spoke 구분 없이 실행한다. 스포크 구독도 이 RP들이 등록돼 있어야 `live/<env>/aks`
# apply가 성립하고, 이 검사는 구독 단위 상태 조회라 대상과 무관하게 멱등이고 비용이 없다.
#
# 목록은 `live/<env>/aks`가 실제로 만드는 리소스 기준 최소 집합이다(AKS →
# ContainerService, azurerm_user_assigned_identity → ManagedIdentity, aks-cluster
# 모듈의 VMSS 노드 → Compute). 새 구독은 셋 다 NotRegistered일 수 있다. 이보다 넓은
# 다른 RP(hub 구독에 있지만 이 저장소와 무관한 것들)는 등록하지 않는다.
#
# ⚠️ --wait를 붙인다. 등록은 비동기라 --wait 없이는 다음 실행이 아직 "Registering"을
# 보고 다시 register를 호출해 "재실행하면 변경 0건"이라는 이 스크립트의 수용 기준이
# 깨진다.
ensure_aks_resource_providers() {
  local ns state
  for ns in Microsoft.ContainerService Microsoft.Compute Microsoft.ManagedIdentity; do
    state="$(az_or_die "${ns} 등록 상태" -- \
      az_ provider show --namespace "$ns" --query registrationState -o tsv)"
    if [[ "$state" == "Registered" ]]; then
      ok "[aks] ${ns} 리소스 프로바이더 등록됨"
    else
      az_ provider register --namespace "$ns" --wait >/dev/null
      changed "[aks] ${ns} 리소스 프로바이더 등록(이전 상태: $state)"
    fi
  done
}

ensure_aks_resource_providers

# ── 7. state RG 잠금 (반드시 마지막. 이후 어떤 변경도 이 RG 안에서 막힌다) ────
# 잠금 존재 시 재실행 절차: 이 RG에 변경이 필요하면 (1) 사람이 잠금 해제 → (2) 이
# 스크립트 재실행으로 수렴 → (3) 잠금 재적용을 수동으로 거친다. 자동 해제는 하지
# 않는다. 자동화하면 진짜 사고와 정상 변경을 구분할 수 없다.
ensure_state_lock() {
  if az_ lock show --name "state-rg-protect" --resource-group "$STATE_RG_NAME" &>/dev/null; then
    ok "[state] CannotDelete 잠금 존재"
  else
    az_ lock create --name "state-rg-protect" --resource-group "$STATE_RG_NAME" \
      --lock-type CanNotDelete \
      --notes "aks-reference-infra bootstrap: control-plane 삭제 방지. 해제 필요 시 bootstrap.sh 7단계 절차를 따를 것." \
      >/dev/null
    changed "[state] CannotDelete 잠금 적용"
  fi
}
ensure_state_lock

echo
echo "=== 변경 ${CHANGES}건 ==="
if [[ "$CHANGES" -eq 0 ]]; then
  echo "이미 기대 상태다 (멱등 확인)."
fi

# 워크플로가 읽는 repo 변수 이름은 env 토큰을 대문자로 끼운 AZURE_<ENV>_*다
# (.github/workflows/deploy-*.yml의 ARM_CLIENT_ID·ARM_SUBSCRIPTION_ID 참고).
ENV_UPPER="$(tr '[:lower:]' '[:upper:]' <<<"$ENV_TOKEN")"
cat <<OUT

── 다음 단계에 필요한 값 ($ENV_TOKEN) ────────────────────────────────────────
⚠️ 아래 값은 git에 커밋하지 않는다. GitHub repo 변수/시크릿과 gitignore된
   backend.hcl에만 둔다.

  GitHub repo 변수  AZURE_${ENV_UPPER}_CLIENT_ID       = $APP_ID
  GitHub repo 변수  AZURE_TENANT_ID             = $EXPECTED_TENANT
  GitHub repo 변수  AZURE_${ENV_UPPER}_SUBSCRIPTION_ID = $EXPECTED_SUBSCRIPTION
OUT

cat <<OUT

  로컬 backend.hcl (live/$ENV_TOKEN/*, gitignore됨):
    resource_group_name  = "$STATE_RG_NAME"
    storage_account_name = "$SA_NAME"
    container_name       = "$CONTAINER_NAME"
    key                  = "$ENV_TOKEN/<root>.tfstate"
    use_azuread_auth     = true

  검증:  EXPECTED_SUBSCRIPTION=$EXPECTED_SUBSCRIPTION EXPECTED_TENANT=$EXPECTED_TENANT \\
           BOOTSTRAP_TARGET=$BOOTSTRAP_TARGET SPOKE_ENV=$SPOKE_ENV ./verify.sh
OUT
