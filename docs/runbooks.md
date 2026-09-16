# 운영 런북

**읽는 사람**: 이미 구축된 환경을 운영하는 사람.

환경을 **구축하고 철거하는** 절차는 hub는 [`hub-lifecycle.md`](hub-lifecycle.md),
spoke는 [`spoke-lifecycle.md`](spoke-lifecycle.md)가 소유한다. 아래는 hub 기준이다. dev는
workbench·클러스터 이름과 SSH 키 파일명(`workbench_dev_ed25519`)만 다르고, ArgoCD 관련
절(2·3·5)은 hub에만 해당한다(dev 자신에는 ArgoCD가 없다. hub ArgoCD가 원격 클러스터로 관리한다).

---

## 1. 클러스터에 접근하기

AKS API 서버가 private이므로 노트북에서 `kubectl`이 직접 닿지 않는다. workbench를 경유한다.
workbench는 공인 IP를 갖지만 NSG가 `ssh_ingress_cidrs`에서 오는 22번만 허용하고 나머지
인바운드는 전부 거부한다.

```bash
ssh -i ~/.ssh/workbench_ed25519 azureuser@<workbench 공인 IP>
```

workbench에는 kubeconfig가 이미 있다(cloud-init이 VM의 managed identity로
`az aks get-credentials` + `kubelogin convert-kubeconfig -l msi`를 부팅 때 한 번 실행하고
`admin_username` 홈에 복사한다). `KUBECONFIG`를 설정할 필요가 없고 `sudo`도 필요 없다.

```bash
kubectl get nodes
k get po -A          # alias k 가 전역 프로파일에 있다
```

공인 IP를 모르면(VM이 재생성되면 바뀔 수 있다):

```bash
az vm show -d -g rg-demo-hub-krc-workload-01 -n vm-demo-hub-krc-workbench-01 \
  --query publicIps -o tsv
```

workbench 없이 급히 명령 하나만 던져야 하면 `az aks command invoke`가 브레이크글래스다.

```bash
az aks command invoke -g <rg> -n <cluster> --command "kubectl get nodes -o wide"
```

> `az aks command invoke`로 비밀·자격증명을 조회하지 않는다. 출력이 ARM 경유로 저장되어
> `az aks command result`로 다시 꺼낼 수 있다. 값을 봐야 하면 **대화형 SSH 세션**에서
> 사람이 직접 읽는다.

---

## 2. ArgoCD 웹 UI 접속: 2홉

ArgoCD `Service`는 `ClusterIP`다. 노출을 만들지 않고 기존 SSH 채널 위에 스트림만 얹는다.
평소에는 `argocd-tunnel-connect` 스킬(`.claude/skills/`, 멱등·자동 재연결)을 쓴다. 아래는
그 스킬이 하는 일을 손으로 하는 형태다.

```bash
IP=$(az vm show -d -g rg-demo-hub-krc-workload-01 -n vm-demo-hub-krc-workbench-01 --query publicIps -o tsv)

# 1홉: workbench 안에서 port-forward (sudo 불필요)
ssh -i ~/.ssh/workbench_ed25519 azureuser@$IP \
  '(setsid nohup kubectl -n argocd port-forward svc/argocd-server 8080:443 --address 127.0.0.1 \
    > ~/argocd-portforward.log 2>&1 < /dev/null &)'

# 2홉: 로컬 SSH 포트 포워딩
ssh -i ~/.ssh/workbench_ed25519 -N -L 18080:127.0.0.1:8080 azureuser@$IP
```

브라우저에서 **https://localhost:18080**. 자체 서명 인증서 경고는 통과한다(TLS를 끄지 않는
것이 의도된 설계다). 로컬 포트를 `8080`이 아닌 `18080`으로 둔 이유는 `eks-reference-infra`의
같은 터널이 `8080`을 쓰는 환경과 충돌하지 않기 위해서다.

| 증상 | 원인 | 대응 |
|------|------|------|
| 갑자기 끊긴다 | 2홉 SSH 세션이 끊겼다(VPN·네트워크 전환) | 2홉만 다시 실행한다. 1홉은 살아 있다 |
| 재생성 후 안 된다 | 1홉이 사라졌고 공인 IP가 바뀌었을 수 있다 | IP를 다시 조회하고 1홉부터 다시 |
| SSH 자체가 타임아웃 | 이 머신의 공인 IP가 `ssh_ingress_cidrs` 밖이다 | `live/hub/workbench`의 CIDR을 갱신해 apply |

두 홉이 필요한 이유가 서로 다르다. 안쪽은 **`ClusterIP`가 가상 IP**라서, 실재하는 주소가
아니라 각 **노드**의 kube-proxy가 DNAT할 뿐이고, 노드가 아닌 workbench엔 그 규칙이 없다.
바깥쪽은 **workbench 인바운드가 화이트리스트 SSH뿐**이라서다.

---

## 3. ArgoCD 관리자 비밀번호 교체

seed 직후 **완료 조건**이다. 선택 항목이 아니다. workbench에서 실행한다(`argocd` CLI가
cloud-init으로 설치돼 있다).

```bash
export ARGOCD_OPTS='--port-forward --port-forward-namespace argocd --insecure'

kubectl -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d; echo      # 대화형 세션에서만

argocd login --username admin                            # 프롬프트
argocd account update-password 2>/tmp/argocd-pw.err
kubectl -n argocd delete secret argocd-initial-admin-secret
```

| 주의 | 내용 |
|------|------|
| `--core`는 쓸 수 없다 | argocd-server를 우회해 **세션 토큰이 없다**. 신원이 필요한 작업은 `--port-forward` |
| `--insecure`의 뜻 | **클라이언트** 인증서 검증 생략이다. 서버 TLS를 끄는 것이 아니다 |
| `broken pipe` 로그 | 포워더가 CLI 안에서 돌아 stderr로 섞인다. **실패가 아니다**(`2>`로 분리한다) |
| 새 비밀번호 | `^.{8,32}$`를 만족해야 한다 |

교체 확인:

```bash
kubectl -n argocd get secret argocd-secret \
  -o jsonpath='{.data.admin\.passwordMtime}' | base64 -d; echo
kubectl -n argocd get secret argocd-initial-admin-secret     # NotFound 여야 한다
```

> 이 patch는 `selfHeal`에 되돌려지지 않는다. 차트가 `argocd-secret`을 `data` 없이 렌더하므로
> 런타임에 채워진 `admin.password`는 ArgoCD의 소유 필드가 아니다.

---

## 4. AKS 업그레이드

### 하드 제약

- **컨트롤플레인 마이너는 1단계씩만.** `1.35 -> 1.37` 직행은 불가하다. 두 번 돈다(LTS 채널 제외).
- **컨트롤플레인이 항상 먼저다.** 노드 풀 버전은 컨트롤플레인보다 높을 수 없고, 최대
  **3마이너**까지 뒤처질 수 있다. EKS와 순서가 반대다(EKS는 노드를 먼저 맞춘다).
- 이 repo는 `automatic_upgrade_channel`을 쓰지 않는다(모듈이 노출하지 않아 `none`).
  버전은 **사람이 올리기 전까지 절대 움직이지 않는다.**

### 지금 클러스터가 어느 버전인지

`live/*/aks/main.tf`는 `kubernetes_version`을 넘기지 않는다. 그러면 provider가 **생성 시점의
권장 버전**을 고르고 이후 자동 업그레이드는 하지 않는다. 즉 코드에 버전이 없으니 실물을 본다.

```bash
az aks show -g <rg> -n <cluster> \
  --query '{cp:currentKubernetesVersion, pools:agentPoolProfiles[].{name:name, ver:currentOrchestratorVersion}}'
az aks get-upgrades -g <rg> -n <cluster> -o table     # 갈 수 있는 버전 목록
```

### apply를 둘로 나눈다

| 단계 | 무엇을 | 누가 |
|------|--------|------|
| 사전 | deprecated API 스캔(`kubent`, workbench에서) + 컴퓨트 쿼터 확인 | 사람 |
| **apply 1** | `module "aks_cluster"`에 `kubernetes_version = "<+1 마이너>"` 추가 → 워크플로 apply | IaC(컨트롤플레인만) |
| **apply 2** | 시스템 노드 풀 업그레이드 | `az aks nodepool upgrade`(IaC 밖) |
| (자동) | NAP(Karpenter) 노드 | 컨트롤플레인 버전을 자동 추종한다 |

apply 1이 컨트롤플레인만 올리는 이유는 provider 동작이다: `kubernetes_version` 변경 시
클러스터의 `kubernetesVersion`만 바꿔 PUT하고, 기본 노드 풀의 `orchestratorVersion`은 기존
값 그대로 보낸다. 모듈이 `orchestrator_version`을 노출하지 않으므로 시스템 풀을 올릴 IaC
레버가 없다. 그래서 apply 2는 CLI다.

```bash
az aks nodepool upgrade -g <rg> --cluster-name <cluster> -n <system pool> \
  --kubernetes-version <apply 1과 같은 값>
```

`orchestrator_version`은 state에 Computed로 들어오므로 CLI로 올려도 다음 plan에 drift가
생기지 않는다. apply 후 위 `az aks show`로 `cp`와 `pools[].ver`가 같은지 확인한다.

**한 번에 여러 마이너를 코드에 적지 않는다.** `kubernetes_version`을 두 단계 올려 적으면
plan은 통과하고 apply에서 AKS가 거부한다. 마이너마다 apply 1·2를 한 바퀴씩 돈다.

> 🔑 `kubernetes_version`은 한 번 코드에 적으면 그 뒤로는 그 값이 SSOT다. 처음 적을 때
> 현재 실물 버전(`currentKubernetesVersion`)보다 낮게 적으면 다운그레이드 시도로 실패한다.

---

## 5. GitOps 상태 확인

```bash
kubectl -n argocd get applications \
  -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status
```

| 상태 | 뜻 |
|------|-----|
| `Synced` / `Healthy` | 정상 |
| `OutOfSync`가 **고착** | 대개 CRD 스키마 defaulting. 해당 Application에 `ServerSideDiff=true`를 켠다 |
| `Progressing`이 오래 | 파드 이벤트를 본다. 대개 이미지 pull 또는 리소스 부족 |

root Application이 저장소를 실제로 읽었는지는 **revision으로** 판정한다:

```bash
kubectl -n argocd get application root-app -o jsonpath='{.status.sync.revision}{"\n"}'
```

값이 `main`이면 아직 **설정값**이다. **실제 커밋 SHA여야** pull에 성공한 것이다.
(`root-app`은 single-source라 `revision` 단수 필드다. multi-source Application만
`revisions` 배열을 쓴다.)

dev 클러스터의 Application도 **hub의 ArgoCD에서** 같은 명령으로 본다. dev 쪽 등록
Secret(`argocd.argoproj.io/secret-type: cluster`)이 살아 있는지가 먼저다:

```bash
kubectl -n argocd get secret -l argocd.argoproj.io/secret-type=cluster
```

---

## 6. workbench 교체

`custom_data`(cloud-init)는 **부팅 때만 돌고 ForceNew다.** 그래서 부팅 당시 조건이 틀렸던
VM은 `apply`로 고쳐지지 않고 **교체해야** 코드가 상태를 되찾는다(예: role assignment 전파
전에 떠서 kubeconfig가 없는 경우. 이 레이스 자체는 `time_sleep.role_propagation`이 막지만
IMDS 타임아웃 같은 다른 부팅 레이스는 남아 있다).

워크플로에 `replace` 입력이 없다. 루트 전체를 destroy → apply한다(VM·NIC·공인 IP·NSG·
UAMI·role assignment가 전부 이 루트 소유라 잃는 것이 없다).

```bash
gh workflow run deploy-hub-workbench.yml --ref main \
  -f action=destroy -f confirm='destroy live/hub/workbench'
gh workflow run deploy-hub-workbench.yml --ref main -f action=apply
```

교체 후 kubeconfig · 도구 · 프로파일은 cloud-init이 다시 만든다. **다시 서지 않는 것은
port-forward뿐이다.** 공인 IP도 바뀔 수 있으니 2절을 IP 조회부터 다시 한다.

교체하기 전에 먼저 `cloud-init status`가 `done`인지 본다. kubeconfig만 없는 경우는
재생성 없이 복구되는 경로가 있다(`hub-lifecycle.md` 「자주 막히는 지점」의 `localhost:8080`
연결 거부 행).

모듈 태그(`ref=aks-workbench-v*`)를 올리는 것만으로도 `custom_data`가 바뀌어 VM이
재생성된다. 의도한 교체가 아니면 plan의 `must be replaced`를 승인 전에 읽는다.

---

## 7. 배포 워크플로가 실패했을 때

### `tofu init`이 모듈·provider를 못 받는다

```
fatal: unable to access 'https://github.com/...': ...
```

**일시적 장애다.** 같은 run 안에서 다른 모듈은 받아지고, 재실행하면 통과한다.

```bash
gh run rerun <run-id> --failed
```

> 🔴 **새로 `workflow run`을 누르지 않는다.** dispatch는 plan을 처음부터 다시 돌려
> **승인한 것과 다른 계획**을 만든다. `--failed`는 같은 run의 저장된 plan을 그대로 쓴다.
> 실패한 것이 plan job이면 어느 쪽이든 같지만, **apply job이면 이 구분이 승인 게이트 그 자체다.**

### 인프라가 없는 상태에서 push CI가 실패한다

전부 철거된 상태에서는 `main` push마다 도는 plan이 networking 2개만 성공하고 나머지는
`data` 조회(`aks-node` 서브넷·AKS 클러스터)가 not found로 실패한다. 순서가 있다는 신호이지
고장이 아니다. 재구축은 lifecycle 문서 순서를 따른다.

### state lock이 풀리지 않는다

apply가 중간에 죽으면 blob lease가 남는다. `hub-lifecycle.md` 「자주 막히는 지점」의
lease break 행을 따른다.

---

## 8. 자주 쓰는 조회

```bash
# kubeconfig 재생성 (workbench에서, VM의 managed identity로)
sudo az login --identity --resource-id <workbench UAMI ID>
sudo az aks get-credentials -g <rg> -n <cluster> --overwrite-existing
sudo kubelogin convert-kubeconfig -l msi --client-id <workbench UAMI client ID> \
  --kubeconfig /root/.kube/config
sudo cp /root/.kube/config ~/.kube/config && sudo chown $USER ~/.kube/config

# 노드 현황
kubectl get nodes -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone

# NAP(Karpenter)가 만든 노드만 / 시스템 풀만
kubectl get nodes -l karpenter.sh/nodepool
kubectl get nodes -l kubernetes.azure.com/mode=system

# NAP가 지금 무엇을 띄우고 있나
kubectl get nodeclaims
kubectl get nodepool,aksnodeclass

# node resource group(MC_*) 안의 IaC 밖 자원
NODE_RG=$(az aks show -g <rg> -n <cluster> --query nodeResourceGroup -o tsv)
az resource list --resource-group "$NODE_RG" -o table
```

> `kubectl -o jsonpath`는 map 순회를 지원하지 않는다. 필요하면 `-o go-template`을 쓴다.

---

## 9. 노드 배치: 시스템 풀과 NAP

이 repo의 분리는 두 층이다.

| 층 | 무엇이 | 누가 만드나 | 크기 |
|----|--------|-----------|------|
| 시스템 풀(기본 풀) | AKS addon(coredns·metrics-server·CSI 등) | `live/*/aks` `system_node_pool` | 고정 2대, `auto_scaling_enabled = false` |
| NAP(Karpenter) 노드 | 나머지 전부 | `NodePool`·`AKSNodeClass` CR(`aks-platform-gitops` `addons/catalog/karpenter.yaml`) | pending 파드에 따라 |

**시스템 풀에 taint가 없다.** 모듈이 기본 풀의 taint(`only_critical_addons_enabled`)를
노출하지 않는다(추가 풀의 `node_taints`만 있다). 그래서 EKS 원본의 "taint로 밀어내고
nodeSelector로 끌어당긴다" 전략은 여기서 **구현되어 있지 않다**: app 파드가 시스템 풀에
여유가 있으면 거기 먼저 앉고, 없을 때만 NAP가 노드를 띄운다. 시스템 풀이 2대 고정이라
실질적으로 대부분의 app 파드는 NAP 노드로 간다.

이 상태가 문제가 되는 경우는 하나다: 시스템 풀에 앉은 app 파드가 addon(coredns 등)의
자리를 잠식해 addon이 `Pending`이 되는 것. 확인:

```bash
kubectl get pods -A -o wide --field-selector spec.nodeName=<시스템 노드 이름>
```

kube-system 밖의 파드가 많이 보이면 taint 도입을 검토한다. 그 변경은 모듈 계약
(`iac-module-library` `modules/azure/aks-cluster`)에 기본 풀 taint 변수를 추가하는 일이라
이 repo 혼자서는 못 한다. NAP `NodePool`에 taint를 두지 않는 것은 EKS 원본과 같은
이유로 의도적이다: 모든 app Deployment가 toleration을 알아야 하는 마찰만 생긴다.

NAP가 시스템 풀 파드 때문에 불필요한 노드를 만들지 않는지는 `kubectl get nodeclaims`로
본다. 시스템 풀에 taint가 없으므로 이 방향의 오작동은 구조상 생기지 않는다(addon 파드는
어느 노드든 앉을 수 있다).
