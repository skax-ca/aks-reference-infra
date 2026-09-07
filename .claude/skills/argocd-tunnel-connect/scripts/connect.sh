#!/usr/bin/env bash
# hub ArgoCD 콘솔 접속용 2단 SSH 터널을 연다.
#   로컬 --(ssh -L)--> hub workbench --(kubectl port-forward)--> argocd-server
# 멱등성: 이미 같은 포트로 정상 연결돼 있으면 아무것도 하지 않고 끝난다.
#         연결이 끊겨 있으면(프로세스 죽음·curl 실패) 정리 후 새로 연결한다.
#
# eks-reference-infra의 argocd-tunnel-connect를 대조해 포팅. AWS SSM 대응물이 Azure에
# 없어 1단(로컬↔workbench) 구간만 ssh -L로 대체했다 — SKILL.md 참고.
#
# 사용: AZURE_HUB_SUBSCRIPTION_ID=<GUID> scripts/connect.sh [LOCAL_PORT]  (기본 18080)
# 기본값을 8080이 아닌 18080으로 둔 이유: eks-reference-infra가 로컬에서 이미 8080을
# 점유하는 환경이 있어(같은 머신에서 두 레퍼런스 인프라 저장소를 동시에 다루는 사용자
# 워크플로), 서로 다른 클라우드의 터널 스킬이 기본값을 공유하지 않도록 분리했다.
set -uo pipefail

WORKLOAD="demo"
ENV_NAME="hub"
REGION_CODE="krc"
RESOURCE_GROUP="rg-${WORKLOAD}-${ENV_NAME}-${REGION_CODE}-workload-01"
VM_NAME="vm-${WORKLOAD}-${ENV_NAME}-${REGION_CODE}-workbench-01"
SSH_USER="azureuser"
SSH_KEY="${HOME}/.ssh/workbench_ed25519"
LOCAL_PORT="${1:-18080}"

# 이 스킬 디렉토리(argocd-tunnel-connect) 밑에 전용 상태 폴더를 둔다 — .omc/state/는
# OMC 자체의 세션·워크트리 생명주기에 묶여 있어(worktree 삭제 시 .omc/ 상태가 함께
# 지워질 수 있음) PID 추적 파일을 두기에 부적절하다(이 저장소는 향후 .omc 참조를 전부
# 끊어낼 계획이기도 하다). scripts/ 의 부모(스킬 루트) 밑에 .state/를 둔다.
STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/.state"
mkdir -p "$STATE_DIR"
PID_FILE="$STATE_DIR/local-watchdog.pid"
IP_FILE="$STATE_DIR/public-ip.txt"
PORT_FILE="$STATE_DIR/local-port.txt"
LOG_FILE="$STATE_DIR/local-watchdog.log"

if [[ -z "${AZURE_HUB_SUBSCRIPTION_ID:-}" ]]; then
  echo "ERROR: AZURE_HUB_SUBSCRIPTION_ID가 설정되지 않았다 — 어느 구독의 workbench인지 명시할 것." >&2
  echo "       예: AZURE_HUB_SUBSCRIPTION_ID=<GUID> bash connect.sh" >&2
  exit 1
fi

if [[ ! -f "$SSH_KEY" ]]; then
  echo "ERROR: SSH private key가 없다 ($SSH_KEY) — workbench_ed25519가 이 머신에 있는지 확인." >&2
  exit 1
fi

check_healthy() {
  local port="$1"
  curl -sk -o /dev/null -w '%{http_code}' "https://localhost:${port}/" --max-time 5 2>/dev/null | grep -q '^200$'
}

open_browser() {
  local port="$1"
  command -v open >/dev/null 2>&1 && open "https://localhost:${port}" >/dev/null 2>&1 || true
}

SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10)

# ── 멱등성 판단 ──────────────────────────────────────────────────────────
if [[ -f "$PID_FILE" ]]; then
  OLD_PID=$(cat "$PID_FILE")
  OLD_PORT=$(cat "$PORT_FILE" 2>/dev/null || echo "$LOCAL_PORT")
  if kill -0 "$OLD_PID" 2>/dev/null && check_healthy "$OLD_PORT"; then
    echo "ALREADY_CONNECTED port=$OLD_PORT pid=$OLD_PID"
    open_browser "$OLD_PORT"
    exit 0
  fi
  # 죽었거나 응답이 없다 — 잔여 프로세스 정리 후 재연결로 진행한다
  kill -- "-$OLD_PID" 2>/dev/null || kill "$OLD_PID" 2>/dev/null || true
  rm -f "$PID_FILE"
fi

# PID 파일에 안 잡히는 고아 프로세스 대비: LOCAL_PORT를 실제로 점유 중인 프로세스가
# 있으면 전부 정리한다(eks-reference-infra 원본과 동일 근거 — 이전 세션 터미널 강제
# 종료 등으로 PID 파일 없이 세션이 남을 수 있다).
STALE_PIDS=$(lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN -t 2>/dev/null || true)
if [[ -n "$STALE_PIDS" ]]; then
  for p in $STALE_PIDS; do
    PARENT=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    [[ -n "$PARENT" ]] && kill "$PARENT" 2>/dev/null || true
    kill "$p" 2>/dev/null || true
  done
  sleep 1
fi

# ── 1) 구독 확인 + workbench 공인 IP 동적 조회 ──────────────────────────────
# 하드코딩 금지: VM 이름은 네이밍 컨벤션으로 고정돼 있어 그대로 쓰지만, 공인 IP는 VM이
# 재생성되면 바뀔 수 있어(live/hub/workbench의 aks-workbench 모듈 버전업 시 custom_data가
# ForceNew) 매번 조회한다.
ACTUAL_SUB=$(az account show --query id -o tsv 2>/dev/null || echo "")
if [[ "$ACTUAL_SUB" != "$AZURE_HUB_SUBSCRIPTION_ID" ]]; then
  echo "ERROR: 현재 az CLI 컨텍스트 구독($ACTUAL_SUB)이 hub 구독($AZURE_HUB_SUBSCRIPTION_ID)과 다르다 — az account set --subscription $AZURE_HUB_SUBSCRIPTION_ID 실행 후 재시도." >&2
  exit 1
fi

VM_INFO=$(az vm show -d --resource-group "$RESOURCE_GROUP" --name "$VM_NAME" \
  --subscription "$AZURE_HUB_SUBSCRIPTION_ID" --query "[powerState, publicIps]" -o tsv 2>/dev/null)
if [[ -z "$VM_INFO" ]]; then
  echo "ERROR: workbench VM을 찾지 못했다 ($VM_NAME, RG=$RESOURCE_GROUP)" >&2
  exit 1
fi
# 실측: az의 -o tsv는 리스트 쿼리(`[a, b]`)를 탭이 아니라 줄바꿈으로 구분해 출력한다
# (IFS=$'\t' read로는 못 나눈다). macOS 기본 bash 3.2에는 mapfile/readarray가 없어
# (이 저장소의 기존 교훈, project-memory.json architecture 노트 참고) sed로 줄 단위 추출한다.
POWER_STATE=$(echo "$VM_INFO" | sed -n '1p')
PUBLIC_IP=$(echo "$VM_INFO" | sed -n '2p')

if [[ "$POWER_STATE" != "VM running" ]]; then
  echo "ERROR: workbench VM 상태가 running이 아니다 (실측: $POWER_STATE, $VM_NAME)" >&2
  exit 1
fi
if [[ -z "$PUBLIC_IP" ]]; then
  echo "ERROR: workbench 공인 IP를 조회하지 못했다 ($VM_NAME)" >&2
  exit 1
fi

# ── 2) 원격 watchdog 기동 — kubectl port-forward가 끊기면(예: pod 재시작) 자동 재시작 ──
# 비대화형 SSH 원격 명령에서 disown은 job control 부재로 조용히 실패한다(exit 255,
# 2026-09-04 13차 세션 실측) — 서브셸 백그라운드 (cmd &)로 대체해 SSH 세션 종료 후에도
# 원격 프로세스가 살아남게 한다.
#
# ⚠️ pkill -f "kubectl port-forward -n argocd svc/argocd-server" 를 그대로 쓰면 안 된다
# (이번 스킬 작성 중 직접 실측): AWS SSM(send-command)은 명령을 스크립트 파일로 저장해
# 실행하지만, SSH는 명령 문자열을 그대로 원격 셸의 커맨드라인 인자로 넘긴다 — 그래서
# pkill의 검색 패턴이 그 pkill을 실행 중인 셸 자신의 커맨드라인에도 그대로 들어있어
# 자기 자신(정확히는 그 부모 bash)을 죽이고 SSH 세션이 exit 255·무출력으로 끊긴다.
# $$(자기 PID)를 명시적으로 제외해 이 자기 자신 매칭을 피한다 — eks-reference-infra
# 원본(SSM 기반)에는 없던, SSH 기반 원격 실행 특유의 함정이다.
REMOTE_CMD='CUR=$$; for p in $(pgrep -f "kubectl port-forward -n argocd svc/argocd-server" 2>/dev/null); do [ "$p" = "$CUR" ] && continue; kill "$p" 2>/dev/null; done; sleep 1; (setsid nohup bash -c "while true; do kubectl port-forward -n argocd svc/argocd-server 8080:443 --address 127.0.0.1; sleep 2; done" > ~/argocd-portforward.log 2>&1 < /dev/null &) ; sleep 2; ss -ltnp | grep 8080'

if ! ssh "${SSH_OPTS[@]}" "${SSH_USER}@${PUBLIC_IP}" "$REMOTE_CMD"; then
  echo "ERROR: 원격 kubectl port-forward 기동 실패 (workbench SSH 접속 또는 원격 명령 실패)" >&2
  exit 1
fi

# ── 3) 로컬 watchdog — SSH 세션이 끊기면(네트워크 전환 등) 자동 재연결 ──
(
  while true; do
    ssh "${SSH_OPTS[@]}" -N -L "${LOCAL_PORT}:127.0.0.1:8080" \
      -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes \
      "${SSH_USER}@${PUBLIC_IP}"
    sleep 3
  done
) > "$LOG_FILE" 2>&1 &
LOCAL_PID=$!
disown

echo "$LOCAL_PID" > "$PID_FILE"
echo "$PUBLIC_IP" > "$IP_FILE"
echo "$LOCAL_PORT" > "$PORT_FILE"

# ── 4) 검증 ──────────────────────────────────────────────────────────────
sleep 5
if check_healthy "$LOCAL_PORT"; then
  echo "CONNECTED port=$LOCAL_PORT ip=$PUBLIC_IP pid=$LOCAL_PID"
  open_browser "$LOCAL_PORT"
else
  echo "WARNING: 터널은 떴지만 https://localhost:$LOCAL_PORT 응답이 아직 없다 — 몇 초 후 다시 확인할 것" >&2
  echo "CONNECTED_UNVERIFIED port=$LOCAL_PORT ip=$PUBLIC_IP pid=$LOCAL_PID"
fi
