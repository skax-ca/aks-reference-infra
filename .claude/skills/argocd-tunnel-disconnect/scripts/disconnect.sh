#!/usr/bin/env bash
# argocd-tunnel-connect 로 연 hub ArgoCD 터널을 해제한다. 로컬 watchdog(ssh -L)·원격
# kubectl port-forward watchdog 을 전부 정리한다.
#
# eks-reference-infra의 argocd-tunnel-disconnect를 대조해 포팅. SSM 세션 대신 SSH
# 프로세스를 정리한다는 점만 다르다.
set -uo pipefail

SSH_USER="azureuser"
SSH_KEY="${HOME}/.ssh/workbench_ed25519"

# connect.sh가 쓴 상태 폴더를 그대로 읽는다(짝 스킬 argocd-tunnel-connect 밑의 .state/,
# 이 위치를 쓰는 이유는 connect.sh 쪽 주석 참고).
STATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/argocd-tunnel-connect/.state"
PID_FILE="$STATE_DIR/local-watchdog.pid"
IP_FILE="$STATE_DIR/public-ip.txt"
PORT_FILE="$STATE_DIR/local-port.txt"

if [[ ! -f "$PID_FILE" ]]; then
  echo "NOT_CONNECTED (state 없음. 이미 해제됐거나 이 스킬로 연 적이 없다)"
  exit 0
fi

LOCAL_PID=$(cat "$PID_FILE")
PUBLIC_IP=$(cat "$IP_FILE" 2>/dev/null || echo "")
LOCAL_PORT=$(cat "$PORT_FILE" 2>/dev/null || echo "18080")

# ── 1) 로컬 watchdog(+ 그 자식 ssh -L) 종료 ──
if kill -0 "$LOCAL_PID" 2>/dev/null; then
  pkill -P "$LOCAL_PID" 2>/dev/null || true
  kill "$LOCAL_PID" 2>/dev/null || true
fi
# 고아로 남았을 수 있는 세션도 포트 기준으로 정리
pkill -f -- "-L ${LOCAL_PORT}:127.0.0.1:8080" 2>/dev/null || true

# ── 2) 원격 kubectl port-forward watchdog 종료 ──
# pkill -f 패턴이 kubectl 프로세스뿐 아니라, 같은 문자열을 argv 에 담고 있는
# 바깥 watchdog(while 루프) bash 프로세스까지 함께 잡는다. 별도 마커가 필요 없다
# (argocd-tunnel-connect의 REMOTE_CMD와 동일 패턴).
#
# ⚠️ $$(자기 PID)를 명시적으로 제외한다. SSH는 명령 문자열을 그대로 원격 셸의
# 커맨드라인 인자로 넘기므로, pkill의 검색 패턴이 그 pkill을 실행 중인 셸 자신의
# 커맨드라인에도 들어있어 자기 자신을 죽이는 자기매칭이 생긴다(AWS SSM 기반 원본에는
# 없던, SSH 기반 원격 실행 특유의 함정).
if [[ -z "$PUBLIC_IP" ]]; then
  echo "WARNING: 원격 workbench IP를 알 수 없다. 로컬만 정리했다" >&2
elif [[ ! -f "$SSH_KEY" ]]; then
  echo "WARNING: SSH private key가 없다 ($SSH_KEY). 원격 정리를 건너뛰고 로컬만 정리했다" >&2
else
  if ! ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o BatchMode=yes -o ConnectTimeout=10 \
    "${SSH_USER}@${PUBLIC_IP}" 'CUR=$$; for p in $(pgrep -f "kubectl port-forward -n argocd svc/argocd-server" 2>/dev/null); do [ "$p" = "$CUR" ] && continue; kill "$p" 2>/dev/null; done; echo STOPPED' > /dev/null 2>&1; then
    echo "WARNING: 원격 정리 명령 전송 실패 (workbench가 꺼져 있거나 SSH 접속 불가할 수 있다)" >&2
  fi
fi

rm -f "$PID_FILE" "$IP_FILE" "$PORT_FILE"

sleep 1
if curl -sk -o /dev/null --max-time 3 "https://localhost:$LOCAL_PORT/" 2>/dev/null; then
  echo "WARNING: 로컬 포트 $LOCAL_PORT 가 여전히 응답한다. 수동 확인: lsof -i :$LOCAL_PORT" >&2
fi

echo "DISCONNECTED port=$LOCAL_PORT ip=$PUBLIC_IP"
