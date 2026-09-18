---
name: aks-argocd-tunnel-connect
description: hub ArgoCD 콘솔(https://localhost:18080, 기본값)에 접속하기 위한 2단 SSH 터널을 연다(로컬 SSH 포트포워딩 → hub workbench(공인 IP) → kubectl port-forward → argocd-server). 사용자가 "argocd 터널 연결", "argocd 콘솔 접속", "argocd UI 보고 싶다"고 할 때 사용한다. 멱등적이다. 이미 정상 연결돼 있으면 아무것도 하지 않는다.
---

# ArgoCD Tunnel Connect

`aks-reference-infra`의 hub workbench(private AKS 클러스터의 유일한 일상 접근 지점,
`live/hub/workbench/main.tf` 참고)를 거쳐 hub ArgoCD 콘솔을
로컬 브라우저에서 열 수 있게 하는 2단 터널을 연다.

```
로컬 브라우저 → https://localhost:<PORT>
             → (ssh -L, 공인 IP + NSG 화이트리스트)
             → hub workbench(VM, vm 서브넷)
             → (kubectl port-forward -n argocd svc/argocd-server, sudo 불필요)
             → hub AKS 클러스터의 argocd-server 파드
```

이 터널은 **읽기 접근 경로일 뿐**이다. 여는 행위 자체는 인프라를 바꾸지 않는다. 다만
콘솔에서 하는 조작(초기 비밀번호 교체 등)은 별개로 신중히 다룬다.

## eks-reference-infra 대응 스킬과의 차이

이 스킬 쌍은 AWS 자매 프로젝트 `eks-reference-infra`의 `eks-argocd-tunnel-connect`/
`-disconnect`를 1:1 대조해 포팅했다. 다만 Azure에는 AWS SSM(Session Manager)의 정확한
대응물이 없고, 이 프로젝트는 이미 workbench 접속 모델을 **SSH가 일상 경로, Run Command가
브레이크글래스**로 확정해 뒀다(`live/hub/workbench/main.tf` 주석 참고).
그래서 1단(로컬↔workbench) 구간을 `aws ssm start-session` 대신 `ssh -L`로 대체했다.
2단(workbench 안 `kubectl port-forward`)은 원본과 동일하다. 인스턴스 탐색 방식도
다르다: AWS는 태그 와일드카드로 매번 검색하지만(재부트스트랩 시 인스턴스 ID가 바뀌므로),
이 저장소는 VM 이름 자체가 네이밍 컨벤션으로 고정돼 있어(`vm-demo-hub-krc-workbench-01`)
이름은 하드코딩하되 **공인 IP는 매번 `az vm show`로 동적 조회**한다(VM이 재생성되면
IP가 바뀔 수 있어서다. 하드코딩 금지 원칙은 AWS와 동일하게 유지).

## 실행

```bash
AZURE_HUB_SUBSCRIPTION_ID=<hub 구독 GUID> bash .claude/skills/aks-argocd-tunnel-connect/scripts/connect.sh [LOCAL_PORT]
```

`AZURE_HUB_SUBSCRIPTION_ID`는 필수다(기본값 없음. `bootstrap/config.sh`의
`EXPECTED_SUBSCRIPTION`과 같은 이유: 구독 식별 정보를 git에 두지 않고, hub/dev를
잘못 섞어 건드리는 사고를 방지한다). `LOCAL_PORT` 생략 시 `18080`(`eks-reference-infra`가
로컬에서 이미 `8080`을 점유하는 환경과 충돌하지 않도록 8080이 아닌 값을 기본값으로 둔다).

출력의 마지막 줄로 결과를 판단한다:

| 출력 | 의미 |
|---|---|
| `ALREADY_CONNECTED port=N pid=N` | 이미 같은 포트로 정상 연결돼 있다. 멱등, 아무것도 안 함 |
| `CONNECTED port=N ip=<공인IP> pid=N` | 새로 연결하고 헬스체크(HTTP 200)까지 확인 |
| `CONNECTED_UNVERIFIED ...` | 터널은 열었지만 아직 응답 확인 전. 몇 초 후 다시 curl 해볼 것 |
| `ERROR: ...` (stderr, exit 1) | 구독 불일치·workbench 미실행·SSH 키 없음·원격 명령 실패 중 하나 |

헬스체크(HTTP 200)를 통과하면 `open`(macOS)으로 기본 브라우저에 `https://localhost:<PORT>`를
바로 띄운다. `ALREADY_CONNECTED`·`CONNECTED` 둘 다 해당(`CONNECTED_UNVERIFIED`는 열지 않는다,
아직 응답 확인 전이라 에러 페이지가 뜰 수 있어서다). 자체 서명 인증서 경고는 정상이므로
사용자에게 "고급 → 이동"으로 진행하라고 안내한다(argocd-values.yaml 주석: TLS를 끄지 않는
게 의도된 설계).

## 멱등성 판단 방식

스크립트가 매번 다음을 확인한다:
1. `.claude/skills/aks-argocd-tunnel-connect/.state/local-watchdog.pid`에 기록된 프로세스가 살아있는가
2. `https://localhost:<PORT>/`가 실제로 HTTP 200을 주는가(터널 전 구간이 살아있어야 통과)

둘 다 참이면 **재연결하지 않는다.** 하나라도 거짓이면(프로세스가 죽었거나, 로컬 SSH 세션은
살아있는데 원격 kubectl port-forward만 끊긴 경우 등) 잔여 프로세스를 정리하고 새로 연다.

## 재연결(watchdog) 2겹

- **원격**: workbench에서 `kubectl port-forward`를 `while true` 루프로 감싸 실행한다.
  argocd-server 파드 재시작 등으로 연결이 끊기면 2초 후 자동 재시도한다(AWS 원본과
  동일 근거). 비대화형 SSH 원격 명령에서 `disown`은 job control 부재로 조용히
  실패한다(exit 255, 무출력).
  그래서 `disown` 대신 서브셸 백그라운드(`(cmd &)`)로 띄워 SSH 세션이 끊겨도 원격
  프로세스가 살아남게 한다.
- **로컬**: `ssh -L` 포트포워딩도 같은 방식으로 감싼다. VPN·네트워크 전환 등으로
  연결이 끊기면 3초 후 자동 재연결한다.

두 watchdog은 서로 독립이다. 한쪽만 끊겨도 그쪽만 재시작되고 다른 쪽은 영향받지 않는다.

## 상태 파일

`.claude/skills/aks-argocd-tunnel-connect/.state/`(git에 커밋되지 않는다, `.gitignore` 참고):
`local-watchdog.pid` · `public-ip.txt` · `local-port.txt` · `local-watchdog.log`.
`aks-argocd-tunnel-disconnect` 스킬이 이 파일들로 무엇을 정리해야 하는지 찾는다. 직접 지우지 않는다.

⚠️ AWS 원본(`eks-reference-infra`)의 대응 스킬은 AI 어시스턴트 도구의 세션 상태
디렉토리를 썼지만, 이 저장소는 스킬 자체 디렉토리 밑에 둔다. 그런 디렉토리는 세션·
워크트리 생명주기에 묶여 있어(워크트리 삭제 시 함께 지워질 수 있음) 이 스크립트가
추적해야 하는 백그라운드 프로세스 PID 파일을 두기에 부적절하다.

## 전제

- `az login` 후 활성 구독이 hub와 일치해야 한다. 스크립트가 `az account show`로 직접
  대조하고, 다르면 즉시 실패한다(`az account set --subscription <ID>` 안내).
- hub workbench VM(`vm-demo-hub-krc-workbench-01`, RG `rg-demo-hub-krc-workload-01`)이
  `VM running` 상태여야 한다.
- SSH 개인키(`~/.ssh/workbench_ed25519`)가 이 머신에 있어야 한다. repo에는 `.pub`만
  커밋돼 있다(`live/hub/workbench/workbench_ed25519.pub`).
- 이 머신의 현재 공인 IP가 `live/hub/workbench`의 `ssh_ingress_cidrs`에 포함돼 있어야
  한다(NSG 화이트리스트, 유동 IP라 바뀌면 해당 root를 갱신·재적용해야 함. 이 스킬의
  범위 밖).
