#!/usr/bin/env bash
# 부트스트랩 (IaC 밖). state Storage Account · App Registration · 커스텀 역할 ·
# 리소스 잠금을 만든다.
#
# 멱등: 항목마다 먼저 검사하고 **다를 때만** 적용한다. 두 번째 실행은 changed=0
#       이어야 한다. 그것이 이 스크립트의 수용 기준이다(계획 5절 3-1 대응).
#
# 생성 순서가 자유롭지 않다(계획 5절, 원본 README 118~122행과 같은 이유 — Entra는
# 존재 검증을 하는 참조가 있고, 잠금은 그 스코프 안의 모든 후속 변경을 막는다):
#   ① 리소스 그룹(워크로드·state 각각 선생성)
#   ② Storage Account + 컨테이너
#   ③ App Registration + Service Principal
#   ④ Federated Identity Credential
#   ⑤ role assignment(워크로드 커스텀 역할, state 데이터 커스텀 역할)
#   ⑥ state RG 잠금 — 반드시 마지막
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
# state Storage Account의 위치(STATE_RG_NAME)는 CI 신원의 RBAC 스코프 밖에 둔다
# (계획 2절) — 워크로드 커스텀 역할은 RG_NAME 스코프만 갖고 STATE_RG_NAME은
# 건드릴 권한이 없다.
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

# 내구성: blob 버전 관리 + blob soft delete + 컨테이너 소프트 삭제(계획 2절).
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
    retry_on_principal_not_found az_ ad sp create --id "$APP_ID"
    sp_id="$(az_ ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv)"
    changed "[$ENV_TOKEN] Service Principal 생성: $sp_id"
  else
    ok "[$ENV_TOKEN] Service Principal 존재: $sp_id"
  fi
  readonly SP_ID="$sp_id"
}
ensure_app_registration

# ⛔ 정적 자격증명(client secret·certificate)을 이 스크립트 어디에서도 만들지
#    않는다. 계획 1절 원칙 1이 App Registration/SP의 정적 자격증명을 0건으로
#    못박는다 — GitHub OIDC(FIC)만이 유일한 인증 경로다.

# ── 4. Federated Identity Credential (계획 6-0-d: 배포 브랜치 정책만) ────────
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

# ── 5. 커스텀 역할 생성/갱신 (계획 1절, 2절 — 정확한 정의는 config.sh 참고) ──
# ⚠️ 비교는 config.sh의 role_definition_matches()로 한다(NotActions만 비교하지
# 않는다). 이 함수를 verify.sh도 그대로 쓴다 — 수렴 판단과 drift 감지가 각자
# 다른 기준을 쓰면 "bootstrap은 ok인데 verify는 실패"가 생겨 verify.sh가
# 소음이 된다.
ensure_custom_role() {  # ensure_custom_role <role-name> <definition-json> <label>
  local role_name="$1" definition="$2" label="$3" existing_id
  existing_id="$(az_ role definition list --name "$role_name" --query "[0].id" -o tsv 2>/dev/null || true)"
  if [[ -z "$existing_id" || "$existing_id" == "None" ]]; then
    az_ role definition create --role-definition "$definition" >/dev/null
    changed "[$label] 커스텀 역할 생성: $role_name"
  else
    local current
    current="$(az_ role definition list --name "$role_name" -o json)"
    if role_definition_matches "$definition" "$current"; then
      ok "[$label] 커스텀 역할 일치: $role_name"
    else
      az_ role definition update --role-definition "$definition" >/dev/null
      changed "[$label] 커스텀 역할 갱신: $role_name (Actions/NotActions/DataActions 불일치)"
    fi
  fi
}

RG_SCOPE="/subscriptions/${EXPECTED_SUBSCRIPTION}/resourceGroups/${RG_NAME}"
STATE_RG_SCOPE="/subscriptions/${EXPECTED_SUBSCRIPTION}/resourceGroups/${STATE_RG_NAME}"
CONTAINER_SCOPE="${STATE_RG_SCOPE}/providers/Microsoft.Storage/storageAccounts/${SA_NAME}/blobServices/default/containers/${CONTAINER_NAME}"

ensure_custom_role "$WORKLOAD_ROLE_NAME" "$(workload_role_definition_json "$RG_SCOPE")" "workload"
ensure_custom_role "$STATE_DATA_ROLE_NAME" "$(state_data_role_definition_json "$STATE_RG_SCOPE")" "state-data"

# ── 6. role assignment (CI 신원 = SP_ID) ─────────────────────────────────────
ensure_role_assignment() {  # ensure_role_assignment <role-name> <scope> <label>
  local role_name="$1" scope="$2" label="$3"
  local existing
  existing="$(az_ role assignment list --assignee "$SP_ID" --scope "$scope" \
    --query "[?roleDefinitionName=='$role_name']" -o json)"
  if [[ "$(jq 'length' <<<"$existing")" -eq 0 ]]; then
    retry_on_principal_not_found az_ role assignment create --assignee "$SP_ID" \
      --role "$role_name" --scope "$scope"
    changed "[$label] role assignment 생성: $role_name @ $scope"
  else
    ok "[$label] role assignment 존재: $role_name"
  fi
}
ensure_role_assignment "$WORKLOAD_ROLE_NAME" "$RG_SCOPE" "workload"
ensure_role_assignment "$STATE_DATA_ROLE_NAME" "$CONTAINER_SCOPE" "state-data"

# ── 7. state RG 잠금 (반드시 마지막 — 이후 어떤 변경도 이 RG 안에서 막힌다) ──
# 잠금 존재 시 재실행 절차(계획 5절): 이 RG에 변경이 필요하면 (1) 사람이 잠금
# 해제 → (2) 이 스크립트 재실행으로 수렴 → (3) 잠금 재적용을 수동으로 거친다.
# 자동 해제는 하지 않는다 — 자동화하면 진짜 사고와 정상 변경을 구분할 수 없다.
ensure_state_lock() {
  if az_ lock show --name "state-rg-protect" --resource-group "$STATE_RG_NAME" &>/dev/null; then
    ok "[state] CannotDelete 잠금 존재"
  else
    az_ lock create --name "state-rg-protect" --resource-group "$STATE_RG_NAME" \
      --lock-type CanNotDelete \
      --notes "aks-reference-infra bootstrap: control-plane 삭제 방지. 해제 필요 시 계획 5절 절차를 따를 것." \
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

cat <<OUT

── 다음 단계에 필요한 값 ($ENV_TOKEN) ────────────────────────────────────────
⚠️ 아래 값은 git에 커밋하지 않는다. GitHub repo 변수/시크릿과 gitignore된
   backend.hcl에만 둔다(원본 D25와 동일 원칙).

  GitHub repo 변수  AZURE_CLIENT_ID       = $APP_ID
  GitHub repo 변수  AZURE_TENANT_ID       = $EXPECTED_TENANT
  GitHub repo 변수  AZURE_SUBSCRIPTION_ID = $EXPECTED_SUBSCRIPTION

  로컬 backend.hcl (live/$ENV_TOKEN/*, gitignore됨):
    resource_group_name  = "$STATE_RG_NAME"
    storage_account_name = "$SA_NAME"
    container_name       = "$CONTAINER_NAME"
    key                  = "$ENV_TOKEN/<root>.tfstate"
    use_azuread_auth     = true

  ⚠️ 이 세션은 Azure 자격증명 없이 실행됐으므로 실제 az CLI 호출은 수행하지
     않았다. 실제 실행은 사용자가 Azure 자격증명을 확보한 뒤 별도로 수행한다.

  검증:  EXPECTED_SUBSCRIPTION=$EXPECTED_SUBSCRIPTION EXPECTED_TENANT=$EXPECTED_TENANT \\
           BOOTSTRAP_TARGET=$BOOTSTRAP_TARGET SPOKE_ENV=$SPOKE_ENV ./verify.sh
OUT
