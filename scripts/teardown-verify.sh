#!/usr/bin/env bash
# teardown-verify.sh: 철거 후 잔존물 검사(read-only). 절차는 docs/hub-lifecycle.md·
# docs/spoke-lifecycle.md 「4단계: 잔존물 검증」.
#
# 삭제는 사람이 한다(워크플로 destroy). 이 스크립트는 지우지 않고 남은 것을 찾을 뿐이다.
# bootstrap.sh는 만드는 스크립트라 멱등성이 안전망이지만 teardown은 한 번만 잘못 돌려도 끝이다.
#
# ⚠️ 대상 구독이 공용일 수 있으므로 모든 조회를 Workload·Environment 태그로 좁힌다. 이름을 눈으로
#    보고 판단하지 않는다. 비슷한 이름이 남의 것일 수 있다. 예외는 node resource group(MC_*) 하나다:
#    AKS가 만드는 RG라 태그 전파를 100% 신뢰할 수 없어 이름 접두 + 태그 둘 중 하나로 잡는다.
#
# ⛔ fail-closed: 조회 자체가 실패하면(권한 부족·네트워크·잘못된 쿼리) "0건이라 통과"로 처리하지
#    않고 exit 2로 즉시 중단한다. bootstrap/verify.sh와 같은 원칙이다. "권한이 없어 못 봤다"를
#    "잔존물 없음"으로 둔갑시키면 이 스크립트가 막으려는 과금 사고가 그대로 난다.
#
# 종료 코드: 0 = 잔존물 없음 / 1 = 잔존물 있음 / 2 = 실행 불가
# ⚠️ bash 3.2 호환으로 쓴다(macOS 기본 bash). 연상배열·mapfile을 쓰지 않는다.

set -Eeuo pipefail

WORKLOAD="${WORKLOAD:-}"
ENVIRONMENT="${ENVIRONMENT:-}"
EXPECTED_SUBSCRIPTION="${EXPECTED_SUBSCRIPTION:-}"

usage() {
  cat <<'USAGE'
사용법: WORKLOAD=<code> ENVIRONMENT=<env> EXPECTED_SUBSCRIPTION=<GUID> ./scripts/teardown-verify.sh

  WORKLOAD               워크로드 코드 (이 repo는 demo)                       필수
  ENVIRONMENT            환경 (hub, dev)                                       필수
  EXPECTED_SUBSCRIPTION  대상 구독 GUID. az 활성 구독과 대조한다(기본값 없음)  필수

비용이 계속 나는 것부터 순서대로 검사한다. 아무것도 지우지 않는다.
USAGE
}

if [ -z "$WORKLOAD" ] || [ -z "$ENVIRONMENT" ] || [ -z "$EXPECTED_SUBSCRIPTION" ]; then
  usage
  exit 2
fi

command -v az >/dev/null 2>&1 || { echo "ERROR: az CLI 가 없다" >&2; exit 2; }

# 구독 대조. bootstrap/config.sh와 같은 이유: 구독 식별 정보를 git에 두지 않고, hub/dev를
# 잘못 섞어 보는 사고를 막는다. 검사 대상이 "지금 az가 보고 있는 구독"이라 이 대조가 곧
# 안전장치다.
ACTIVE_SUBSCRIPTION=$(az account show --query id -o tsv 2>/dev/null) || {
  echo "ERROR: az 자격증명으로 호출할 수 없다(az login 필요)" >&2
  exit 2
}
if [ "$ACTIVE_SUBSCRIPTION" != "$EXPECTED_SUBSCRIPTION" ]; then
  echo "ERROR: 활성 구독($ACTIVE_SUBSCRIPTION)이 EXPECTED_SUBSCRIPTION과 다르다." >&2
  echo "       az account set --subscription $EXPECTED_SUBSCRIPTION" >&2
  exit 2
fi

# JMESPath 조각. 모든 조회가 이 두 태그로 좁혀진다.
TAGGED="tags.Workload=='${WORKLOAD}' && tags.Environment=='${ENVIRONMENT}'"

echo "구독 ${ACTIVE_SUBSCRIPTION} · 대상 태그 Workload=${WORKLOAD} Environment=${ENVIRONMENT}"
echo

FOUND=0

# 조회 실행. 성공 시 stdout(tsv)을 돌려주고, 실패 시 exit 2. 호출자는 반드시
#   r=$(query ...) || exit 2
# 형태로 받는다. $(...) 안의 exit는 서브셸만 끝내므로 호출자의 `|| exit 2`가 fail-closed의
# 실제 관문이다. report의 인자 자리에서 곧바로 $(query ...)를 쓰면 실패가 빈 문자열로 둔갑해
# "없음"으로 찍힌다(이 스크립트가 막으려는 바로 그 양상).
# stderr는 캡처하지 않는다. az 확장(aks-preview 등)이 stderr로 내는 WARNING이 결과에 섞여
# "남아 있음" 오탐을 만든다. 오류 본문은 터미널로 그대로 흘려 보낸다.
# $1=설명(오류 메시지용) $2...=az 명령
query() {
  local label="$1"; shift
  local out
  out=$("$@" -o tsv) || {
    echo "ERROR: 조회 실패($label). 권한·네트워크를 확인한다. 판정 불가로 중단한다." >&2
    exit 2
  }
  printf '%s' "$out"
}

# $1=순위 $2=설명 $3=조회 결과
report() {
  if [ -n "$3" ]; then
    FOUND=1
    printf '  [%s] 남아 있음: %s\n' "$1" "$2"
    printf '%s\n' "$3" | sed 's/^/        /'
  else
    printf '  [%s] 없음: %s\n' "$1" "$2"
  fi
}

echo "== 비용이 계속 나는 것 =="

r=$(query "nat gateway" az network nat gateway list --query "[?${TAGGED}].name") || exit 2
report 1 "NAT Gateway (트래픽 0이어도 시간당 과금)" "$r"

r=$(query "vm" az vm list --query "[?${TAGGED}].[name,hardwareProfile.vmSize]") || exit 2
report 2 "VM (NAP 고아 노드·workbench)" "$r"

r=$(query "vmss" az vmss list --query "[?${TAGGED}].[name,sku.capacity]") || exit 2
report 3 "VMSS (시스템 노드 풀)" "$r"

# `az disk list`는 구독 전체 조회에 -g를 요구한다(CLI 2.89 기준). REST의 subscription-level
# List는 그 제약이 없어 az rest로 직접 부른다.
r=$(query "disk" az rest --method get \
  --url "https://management.azure.com/subscriptions/${ACTIVE_SUBSCRIPTION}/providers/Microsoft.Compute/disks?api-version=2024-03-02" \
  --query "value[?properties.diskState=='Unattached' && ${TAGGED}].[name,properties.diskSizeGB]") || exit 2
report 4 "Managed Disk (Unattached, 붙어 있지 않아도 과금)" "$r"

r=$(query "public-ip" az network public-ip list \
  --query "[?ipConfiguration==null && ${TAGGED}].[name,ipAddress]") || exit 2
report 5 "Public IP (미연결일 때 과금)" "$r"

r=$(query "lb" az network lb list --query "[?${TAGGED}].name") || exit 2
report 6 "Load Balancer (kubernetes-internal·AGFC)" "$r"

r=$(query "aks" az aks list --query "[?${TAGGED}].[name,powerState.code]") || exit 2
report 7 "AKS 클러스터 (노드 0대여도 컨트롤 플레인 과금)" "$r"

echo
echo "== 과금은 없으나 다음 삭제를 막는 것 =="

r=$(query "nic" az network nic list \
  --query "[?virtualMachine==null && ${TAGGED}].[name,ipConfigurations[0].privateIPAddress]") || exit 2
report 8 "NIC (VM 미연결, 서브넷·VNet 삭제를 막는다)" "$r"

r=$(query "vnet" az network vnet list --query "[?${TAGGED}].[name,addressSpace.addressPrefixes[0]]") || exit 2
report 9 "VNet" "$r"

# MC_* 는 AKS가 만드는 RG라 이 스크립트가 유일하게 이름으로도 잡는 항목이다. 클러스터 삭제 시
# "대개" 자동 정리되지만 IaC 밖 자원(AGFC·PVC 디스크)이 남아 있으면 지연되거나 남는다.
r=$(query "group" az group list \
  --query "[?starts_with(name, 'MC_') && (${TAGGED} || contains(name, '${WORKLOAD}-${ENVIRONMENT}'))].[name,properties.provisioningState]") || exit 2
report 10 "node resource group (MC_*)" "$r"

echo
echo "== 보존 요건을 먼저 확인할 것 =="

r=$(query "log-analytics" az monitor log-analytics workspace list --query "[?${TAGGED}].name") || exit 2
report 11 "Log Analytics workspace (보존 기간만큼 저장 과금)" "$r"

echo
echo "== 태그로 잡히는 나머지 전부 (위 항목의 중복 포함, 누락 확인용) =="

# state Storage Account(bootstrap 소유, st<workload><env>+hex 접미사)는 live/ 철거 후에도 남아
# 있어야 정상이다(state가 거기 있다. hub-lifecycle.md 「되돌릴 수 없는 것」). 잔존물로 세지 않고
# 따로 표시만 한다.
STATE_SA="type=='Microsoft.Storage/storageAccounts' && starts_with(name, 'st${WORKLOAD}${ENVIRONMENT}')"
r=$(query "resource" az resource list --tag "Workload=${WORKLOAD}" --tag "Environment=${ENVIRONMENT}" \
  --query "[?!(${STATE_SA})].[type,name]") || exit 2
report 12 "태그 일치 리소스 (state Storage Account 제외)" "$r"

r=$(query "state storage account" az resource list --tag "Workload=${WORKLOAD}" --tag "Environment=${ENVIRONMENT}" \
  --query "[?${STATE_SA}].name") || exit 2
printf '  [-] bootstrap 소유(남아 있어야 정상): state Storage Account %s\n' "${r:-(없음. bootstrap도 지워졌다)}"

echo
if [ "$FOUND" -eq 0 ]; then
  echo "잔존물 없음."
  exit 0
fi

cat <<'NEXT'

잔존물이 있다. docs/hub-lifecycle.md 또는 docs/spoke-lifecycle.md의 「자주 막히는 지점」을 본다.

주의:
  - NAP(Karpenter) 노드 VM은 NodePool·AKSNodeClass 를 먼저 지웠어야 회수된다.
  - MC_* RG 가 남았다면 AGFC 리소스나 PVC 디스크가 먼저 안 죽은 것이다. RG 안을 태그로 특정한다.
  - 태그가 없는 자원은 이 스크립트가 찾지 못한다. 포털에서 RG 기준으로 한 번 더 본다.
  - dev 단독 철거라면 hub 구독의 vWAN 연결(az network vhub connection list)은 이 스크립트
    범위 밖이다(다른 구독). spoke-lifecycle.md 「dev 단독 teardown 시 hub vWAN 잔존 연결」.
NEXT
exit 1
