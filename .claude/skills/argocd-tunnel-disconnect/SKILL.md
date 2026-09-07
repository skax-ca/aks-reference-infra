---
name: argocd-tunnel-disconnect
description: argocd-tunnel-connect로 연 hub ArgoCD 콘솔 터널(로컬 SSH -L + workbench의 kubectl port-forward watchdog)을 전부 정리한다. 사용자가 "argocd 터널 해제", "argocd 연결 끊어줘", "터널 정리해줘"라고 할 때 사용한다. argocd-tunnel-connect와 짝을 이루는 스킬이다.
---

# ArgoCD Tunnel Disconnect

`argocd-tunnel-connect`가 연 2단 SSH 터널(로컬 watchdog + 원격 kubectl port-forward
watchdog)을 양쪽 다 종료하고 상태 파일을 지운다. `eks-reference-infra`의
`argocd-tunnel-disconnect`를 그대로 대조해 포팅했다 — SSM 세션 대신 SSH 프로세스를
정리한다는 점만 다르다(SKILL.md 쌍인 `argocd-tunnel-connect`의 「차이」절 참고).

## 실행

```bash
bash .claude/skills/argocd-tunnel-disconnect/scripts/disconnect.sh
```

인자 없음 — `argocd-tunnel-connect/.state/`(짝 스킬의 상태 폴더)의 파일에서 무엇을
종료해야 하는지 전부 읽는다.

## 출력

| 출력 | 의미 |
|---|---|
| `NOT_CONNECTED (...)` | 연결 상태가 아니다(이미 해제됐거나 애초에 이 스킬 쌍으로 연 적 없음) — 정상 종료 |
| `DISCONNECTED port=N ip=<공인IP>` | 로컬·원격 프로세스 정리 완료, 상태 파일 삭제 완료 |
| `WARNING: ...`(stderr) | 원격 정리 명령이 실패했거나(workbench가 꺼져 있음 등) 로컬 포트가 여전히 응답함 — 수동 확인 필요 |

## 정리 대상 (양쪽 다)

1. **로컬**: watchdog 프로세스(자식인 `ssh -L` 포함)를 죽인다. 혹시 고아로 남은 세션이
   있으면 포트 번호로 한 번 더 정리한다.
2. **원격**: workbench에 SSH로 `pkill -f "kubectl port-forward -n argocd svc/argocd-server"`를
   보낸다 — 이 패턴 하나로 실제 `kubectl` 프로세스와 그걸 감싼 `while` 루프 watchdog
   bash 프로세스가 **함께 잡힌다**(watchdog의 스크립트 문자열 자체가 그 패턴을 포함하기
   때문에 별도 마커가 필요 없다). watchdog까지 죽어야 재시작되지 않는다. 이 SSH 호출이
   실패하면(workbench가 이미 꺼져 있거나 네트워크 단절) 원격 프로세스는 workbench가
   재부팅될 때까지 남아있을 수 있다 — 다음 `connect.sh` 실행이 어차피 같은 `pkill`을
   먼저 실행하므로 실질적 위험은 낮다.

## 전제

- SSH 개인키(`~/.ssh/workbench_ed25519`)가 없으면 원격 정리 단계만 건너뛰고
  `WARNING`을 낸다 — 로컬 정리는 키 없이도 항상 수행된다.

## 언제 쓰는가

- ArgoCD 콘솔 확인 작업이 끝났을 때 — 터널을 열어둔 채로 세션을 끝내면 workbench에서
  불필요한 프로세스가 계속 돈다.
- `argocd-tunnel-connect`를 다른 포트로 다시 열기 전에 정리가 필요할 때.

`argocd-tunnel-connect`가 멱등적이라 재연결 전에 항상 disconnect를 먼저 부를 필요는
없다 — 이미 정상 연결돼 있으면 connect가 알아서 아무것도 안 한다. disconnect는
**정말로 닫고 싶을 때만** 쓴다.
