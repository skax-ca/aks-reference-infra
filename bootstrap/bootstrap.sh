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
#   ⑤ role assignment(워크로드 커스텀 역할, 구독 전체 스코프 — 2026-09-04부터.
#     이전엔 워크로드 역할이 RG 스코프 + state 데이터 역할이 별도였다)
#   ⑥ AKS 클러스터용 identity + 노드 서브넷 권한 + RP 등록(hub 대상만)
#   ⑦ state RG 잠금 — 반드시 마지막
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
  # ⚠️ 존재 여부를 판단하는 "첫" 조회도 role_definition_list_retry를 거친다.
  # 예전엔 이 최초 조회만 재시도 없이 단발이었는데, 2026-08-27 hub 재생성 세션
  # 2차 실행에서 실제 캐시 지연에 걸렸다 — role이 실제로 존재하고 verify.sh도
  # "일치"로 확인했는데, 이 단발 조회만 빈 배열을 돌려줘 "부재"로 오판, `role
  # definition create`가 `RoleDefinitionWithSameNameExists`로 죽었다. 진짜
  # 부재(최초 부트스트랩)라면 재시도 5회 후에도 빈 배열이라 정상적으로 create
  # 경로를 탄다 — 그 경우의 비용은 최대 15초뿐이다.
  local role_name="$1" definition="$2" label="$3" current existing_id
  current="$(role_definition_list_retry "$role_name")"
  existing_id="$(jq -r '.[0].id // empty' <<<"$current")"
  if [[ -z "$existing_id" ]]; then
    az_ role definition create --role-definition "$definition" >/dev/null
    changed "[$label] 커스텀 역할 생성: $role_name"
  else
    if role_definition_matches "$definition" "$current"; then
      ok "[$label] 커스텀 역할 일치: $role_name"
    else
      # id를 명시해야 이름 기반의 애매한 검색 없이 정확히 이 객체를 갱신한다
      # (id 없이 update하면 CLI가 'Role "id" is missing' 경고를 내며 이름으로
      # 다시 찾는다 — 실측 확인, 2026-08-27).
      az_ role definition update \
        --role-definition "$(jq --arg id "$existing_id" '. + {id: $id}' <<<"$definition")" >/dev/null
      changed "[$label] 커스텀 역할 갱신: $role_name (Actions/NotActions/DataActions 불일치)"
    fi
  fi
}

RG_SCOPE="/subscriptions/${EXPECTED_SUBSCRIPTION}/resourceGroups/${RG_NAME}"

ensure_custom_role "$WORKLOAD_ROLE_NAME" "$(workload_role_definition_json "$SUBSCRIPTION_SCOPE")" "workload"

# ── 6. role assignment (기본 assignee = 이 대상 자신의 CI 신원 SP_ID) ────────
ensure_role_assignment() {  # ensure_role_assignment <role-name> <scope> <label> <assignee-object-id>
  # ⚠️ roleDefinitionName이 아니라 roleDefinitionId로 필터링한다. roleDefinitionName은
  # role assignment 객체가 조회 시점에 역할 정의 쪽과 조인해서 채우는 값이라, 방금
  # role assignment를 만들거나 역할 정의를 갱신한 직후엔 한동안 null로 보일 수 있다
  # (실측 확인, 2026-08-27 hub 재생성 세션 — role assignment는 실제로 1건만 존재하고
  # verify.sh도 "존재"로 확인했는데, 이 필터만 0건으로 봐서 불필요한 create를 유발했다).
  # roleDefinitionId는 조인이 필요 없는 role assignment 자신의 직접 속성이라 지연이 없다.
  #
  # ⚠️ assignee를 4번째 인자로 명시한다(2026-09-03, live/hub/vwan 5단계 세션에서
  # 크로스 구독 스포크 연결 권한을 추가하며 리팩터링 — 이전엔 전역 $SP_ID에
  # 암묵 의존했으나, 그 assignee가 이 대상 자신이 아니라 hub SP인 호출이 생겨
  # 암묵 의존이 더 이상 성립하지 않는다).
  local role_name="$1" scope="$2" label="$3" assignee="$4"
  local role_id existing
  role_id="$(jq -r '.[0].id' <<<"$(role_definition_list_retry "$role_name")")"
  existing="$(az_ role assignment list --assignee "$assignee" --scope "$scope" \
    --query "[?roleDefinitionId=='$role_id']" -o json)"
  if [[ "$(jq 'length' <<<"$existing")" -eq 0 ]]; then
    retry_on_replication_delay az_ role assignment create --assignee "$assignee" \
      --role "$role_name" --scope "$scope"
    changed "[$label] role assignment 생성: $role_name @ $scope"
  else
    ok "[$label] role assignment 존재: $role_name"
  fi
}
ensure_role_assignment "$WORKLOAD_ROLE_NAME" "$SUBSCRIPTION_SCOPE" "workload" "$SP_ID"
# ⚠️ state 데이터 역할 assignment는 2026-09-04부로 여기서 만들지 않는다(위
# 「role_definition_json」·config.sh 참고 — 워크로드 역할이 이미 구독 전체 Owner라
# state RG·컨테이너까지 포함한다). 이전 실행이 만든 실물은 사람이 수동 정리한다.

# ── 6-1. 크로스 구독 스포크 연결 권한 (스포크 대상만, 계획 4-1 Option A —
#    2026-09-03 절충: VNet 리소스 스코프 대신 워크로드 RG 스코프로 완화해 dev
#    VNet이 아직 없는 이 시점(bootstrap.sh는 항상 networking apply보다 먼저
#    실행된다)에 함께 끝낸다. 대가는 hub SP가 이 RG에 나중에 생길 다른 VNet에도
#    자동으로 peer 권한을 갖는다는 것 — peer/action은 단일 액션이라 위험도가
#    낮고, 스포크가 늘 때마다 별도 스크립트를 한 번 더 실행하는 마찰을 없앤다.
#    AWS 원본(RAM 계정/OU 단위 공유 후 스포크가 자기 계정에서 attachment 생성)과
#    가장 가까운 근사다 — Azure vWAN엔 RAM의 정확한 대응물이 없다) ──────────
if [[ "$BOOTSTRAP_TARGET" == "spoke" ]]; then
  HUB_APP_ID="$(az_or_die "hub App Registration" -- az_ ad app list --display-name "$HUB_APP_NAME" --query "[0].appId" -o tsv)"
  [[ -n "$HUB_APP_ID" && "$HUB_APP_ID" != "None" ]] \
    || die "hub App Registration이 없다: $HUB_APP_NAME (hub bootstrap을 먼저 실행할 것)"
  HUB_SP_ID="$(az_or_die "hub Service Principal" -- az_ ad sp list --filter "appId eq '$HUB_APP_ID'" --query "[0].id" -o tsv)"
  [[ -n "$HUB_SP_ID" && "$HUB_SP_ID" != "None" ]] || die "hub Service Principal이 없다: $HUB_APP_NAME"
  ok "[hub] Service Principal 확인: $HUB_SP_ID ($HUB_APP_NAME)"

  ensure_custom_role "$SPOKE_PEER_ROLE_NAME" "$(spoke_peer_role_definition_json "$RG_SCOPE")" "spoke-peer"
  ensure_role_assignment "$SPOKE_PEER_ROLE_NAME" "$RG_SCOPE" "spoke-peer" "$HUB_SP_ID"
fi

# ── 6-2. AKS 클러스터용 identity·권한·RP 등록 (hub 대상만, 계획
#    .omc/plans/live-hub-aks.md 「identity·role assignment (bootstrap 확장)」절) ─
# aks-cluster 모듈은 identity도 role assignment도 만들지 않고 입력으로만 받는다.
# 그리고 CI 신원에는 roleAssignments/write를 주지 않는다는 제약(CLAUDE.md 2절)이
# 있어, 이 둘은 구조적으로 CI 밖(여기)에서만 만들 수 있다.
ensure_aks_identity() {
  local existing
  existing="$(az_ identity show --name "$AKS_IDENTITY_NAME" --resource-group "$RG_NAME" \
    --query id -o tsv 2>/dev/null)" || existing=""
  if [[ -z "$existing" || "$existing" == "None" ]]; then
    az_ identity create --name "$AKS_IDENTITY_NAME" --resource-group "$RG_NAME" \
      --location "$REGION" \
      --tags "Workload=$TAG_WORKLOAD" "Environment=$TAG_ENVIRONMENT" "ManagedBy=$TAG_MANAGED_BY" \
      >/dev/null
    changed "[aks] user-assigned identity 생성: $AKS_IDENTITY_NAME"
  else
    ok "[aks] user-assigned identity 존재: $AKS_IDENTITY_NAME"
  fi
  # ⚠️ create의 --query 출력을 그대로 받지 않고 다시 show로 조회한다. az의 create
  # 계열은 경고를 stderr로 섞어 내보내는 경우가 있어, 값을 얻는 경로를 조회 하나로
  # 통일하는 편이 안전하다(기존 ensure_app_registration의 create→list 패턴과 동일).
  #
  # ⚠️ `az identity show`가 반환하는 리소스 ID는 `/resourcegroups/`(소문자)다. ARM
  # 자체는 대소문자를 구분하지 않지만, azurerm provider(v5, 타입 SDK)는 세그먼트
  # 리터럴을 정확히 `/resourceGroups/`로 요구해 그대로 넘기면 "the segment at
  # position 2 didn't match"로 plan이 실패한다(2026-09-03 live/hub/aks 첫 apply
  # 실측). sed로 그 세그먼트만 정규화한다.
  AKS_IDENTITY_ID="$(az_or_die "AKS identity 리소스 ID" -- \
    az_ identity show --name "$AKS_IDENTITY_NAME" --resource-group "$RG_NAME" --query id -o tsv \
    | sed 's#/resourcegroups/#/resourceGroups/#')"
  AKS_IDENTITY_PRINCIPAL_ID="$(az_or_die "AKS identity principalId" -- \
    az_ identity show --name "$AKS_IDENTITY_NAME" --resource-group "$RG_NAME" --query principalId -o tsv)"
}

# ⚠️ **조건부·수렴형**이다. 이 스크립트는 새 스포크에서도 다시 실행되는데, 그
# 시점의 최초 실행은 언제나 live/<env>/networking apply보다 먼저 온다(peer/action이
# RG 스코프로 완화됐던 것과 같은 닭과 달걀 문제, bootstrap/README.md 「크로스 구독
# 연결」절). 그래서 대상 서브넷이 없으면 **이 단계만** 건너뛰고 나머지는 정상
# 진행한다. 서브넷이 생긴 뒤 재실행하면 수렴한다. peer/action과 달리 스코프를
# 완화하지 않고 이 방식을 택한 이유는 위험도 차이다(액션 1개 대 대상 1개).
ensure_aks_node_subnet_role() {
  local subnet_id
  subnet_id="$(aks_node_subnet_id)"
  if [[ -z "$subnet_id" ]]; then
    warn "[aks] 노드 서브넷이 아직 없어 role assignment를 건너뛴다: $AKS_NODE_SUBNET_NAME"
    warn "[aks] live/$ENV_TOKEN/networking apply 후 이 스크립트를 다시 실행하면 수렴한다"
    return 0
  fi
  ensure_role_assignment "$AKS_NODE_ROLE_NAME" "$subnet_id" "aks" "$AKS_IDENTITY_PRINCIPAL_ID"
}

# CI 신원은 구독 스코프 */register/action을 갖지 않는다(워크로드 커스텀 역할의
# 스코프가 RG 하나뿐이다). 미등록 상태로 apply가 시작되면 CI가 스스로 복구할 수
# 없는 실패로 막히므로 사람이 여기서 사전에 처리한다.
#
# ⚠️ --wait를 붙인다. 등록은 비동기라 --wait 없이는 다음 실행이 아직 "Registering"을
# 보고 다시 register를 호출해 "재실행하면 변경 0건"이라는 이 스크립트의 수용 기준이
# 깨진다.
ensure_container_service_provider() {
  local state
  state="$(az_or_die "Microsoft.ContainerService 등록 상태" -- \
    az_ provider show --namespace Microsoft.ContainerService --query registrationState -o tsv)"
  if [[ "$state" == "Registered" ]]; then
    ok "[aks] Microsoft.ContainerService 리소스 프로바이더 등록됨"
  else
    az_ provider register --namespace Microsoft.ContainerService --wait >/dev/null
    changed "[aks] Microsoft.ContainerService 리소스 프로바이더 등록(이전 상태: $state)"
  fi
}

if [[ "$BOOTSTRAP_TARGET" == "hub" ]]; then
  ensure_aks_identity
  ensure_aks_node_subnet_role
  ensure_container_service_provider
fi

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
OUT

# hub 대상에서만 나온다 — live/hub/aks가 TF_VAR로 주입받는 값이다.
if [[ "$BOOTSTRAP_TARGET" == "hub" ]]; then
  printf '  GitHub repo 변수  AZURE_HUB_AKS_IDENTITY_ID = %s\n' "$AKS_IDENTITY_ID"
fi

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
