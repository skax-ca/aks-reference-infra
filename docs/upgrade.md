# AKS 마이너 업그레이드

**읽는 사람**: 이미 구축된 hub·spoke 클러스터의 Kubernetes 마이너 버전을 올리는 사람.

이 문서는 따라 하는 절차다. 순서가 왜 이런지는 `iac-module-library`의
`docs/architectures/gitops-hub-spoke/azure/upgrade.md`가, 클러스터 접근과 GitOps 상태를 읽는 법은
[`runbooks.md`](runbooks.md)가, 승인 게이트와 plan을 읽는 법은 `iac-module-library/CLAUDE.md` 「배포 루트
공통」이 갖는다.

> **검증 상태**: ⏳ 표시가 붙은 줄은 실환경에서 확인하지 않았다. 소요 시간과 끊김은 dev(시스템 노드 2대,
> NAP 노드 2대)와 hub(시스템 노드 3대)를 `1.35.8 → 1.36.4`로 올리며 잰 값이다.

---

## 1. 한눈에 보기

클러스터 하나를 올리는 데 승인 2번, 머지 4번, 약 45분이 든다. dev를 끝까지 올리고 확인한 뒤 hub를 올린다.

| # | 단계 | 저장소 | 적용 | 소요 | 워크로드 |
|---|------|--------|------|------|----------|
| 0 | 사전 점검, 값 기록 | 없음 | 조회만 | 15분 | 영향 없음 |
| 1 | NAP disruption 차단 | `aks-platform-gitops` | 머지 | 5분 | 영향 없음 |
| 2 | 컨트롤플레인 apply | 이 저장소 | 승인 | 5분 | 끊김 없음 |
| 3 | 관리형 addon 확인 | 없음 | 조회만 | 5분 | |
| 4 | 시스템 풀 apply | 이 저장소 | 승인 | 노드 2대 13분, 3대 15분 | 시스템 노드의 파드가 옮겨진다 |
| 5 | NAP disruption 차단 해제 | `aks-platform-gitops` | 머지 | 5분 + 노드당 1분 반 | app 파드가 옮겨진다 |
| 6 | 완료 판정 | 없음 | 조회만 | 5분 | |

- **적용**이 "승인"인 단계는 PR 머지가 plan을 돌리고 environment 승인이 apply를 돌린다. "머지"인 단계는
  머지가 곧 적용이고 hub의 ArgoCD가 5분 안에 반영한다.
- 🔑 **올릴지는 0단계에서 2.7의 기준으로 정한다.** 2단계의 컨트롤플레인은 되돌릴 수 없다. 그 뒤에 되돌릴 수
  있는 것은 시스템 풀뿐이고, 그것은 증상이 났을 때 여는 대응이다(6절).
- 1단계부터 5단계까지는 끊지 않고 이어서 한다. 차단 중에도 스케일 아웃으로 새로 뜨는 NAP 노드는 새 마이너다.

| 환경 | 티어 | 구독 ID를 담은 repo 변수 | 리소스 그룹 | 클러스터 | 고칠 파일 | 워크플로 |
|------|------|--------------------------|-------------|----------|-----------|----------|
| dev | `nonprd` | `AZURE_DEV_SUBSCRIPTION_ID` | `rg-demo-dev-krc-workload-01` | `aks-demo-dev-krc-main-01` | `live/dev/aks/main.tf` | `deploy-dev-aks.yml` |
| hub | `prd` | `AZURE_HUB_SUBSCRIPTION_ID` | `rg-demo-hub-krc-workload-01` | `aks-demo-hub-krc-main-01` | `live/hub/aks/main.tf` | `deploy-hub-aks.yml` |

명령 앞의 주석이 치는 자리다. `# 로컬:`은 내 터미널에서, `# workbench:`는 올릴 클러스터의 workbench에서
친다(접속은 `runbooks.md` 「클러스터에 접근하기」). 로컬 명령은 아래 세 변수를 쓴다. 시작할 때 한 번 정하고,
다른 클러스터로 넘어갈 때 다시 정한다.

```bash
# 로컬: dev를 올릴 때. hub는 표의 hub 줄 값으로 바꾼다
export SUB=$(gh variable get AZURE_DEV_SUBSCRIPTION_ID -R skax-ca/aks-reference-infra)
export RG=rg-demo-dev-krc-workload-01 CLUSTER=aks-demo-dev-krc-main-01
az account set --subscription "$SUB"
```

⚠️ dev와 hub는 구독이 다르다. 구독을 바꾸지 않고 다른 클러스터를 조회하면 `ResourceNotFound`가 난다.
`az aks operation`은 `aks-preview` 확장이 필요하다(`az extension add --name aks-preview --upgrade`).

---

## 2. 시작 전에

### 2.1. 제약

| 제약 | 내용 |
|------|------|
| 마이너는 한 번에 하나 | `1.35 → 1.37` 직행은 안 된다. 이 문서를 두 번 돈다 |
| 컨트롤플레인이 먼저다 | 노드 풀은 컨트롤플레인보다 높을 수 없고 3 마이너까지 뒤처질 수 있다 |
| 컨트롤플레인은 내릴 수 없다 | 값을 낮춘 커밋은 apply에서 실패한다 |
| 시스템 풀 되돌리기는 7일, 한 버전 | 6절 |
| deprecated API 검사 | 지난 12시간에 쓰인 deprecated API가 있으면 AKS가 컨트롤플레인 업그레이드를 거부한다 ⏳ |

### 2.2. 현재 상태와 값 기록

값은 추정하지 않는다. 아래 명령으로 조회해 표를 채우고, 절차는 이 표의 칸 이름으로 값을 부른다.

| 칸 | 값 | 쓰는 단계 |
|----|----|-----------|
| `<k8s>` (패치까지) | | 컨트롤플레인 apply, 시스템 풀 apply |
| `<image>` | | 6절 비교용 |

```bash
# 로컬: 지금 버전과 노드 이미지. cp와 pools[].v가 같은 패치여야 시작할 수 있다
az aks show -g "$RG" -n "$CLUSTER" \
  --query '{cp:currentKubernetesVersion, pools:agentPoolProfiles[].{n:name,v:currentOrchestratorVersion,img:nodeImageVersion}}'

# 로컬: <k8s>. 다음 마이너의 가장 높은 패치를 고른다
az aks get-upgrades -g "$RG" -n "$CLUSTER" --query 'controlPlaneProfile.upgrades[].kubernetesVersion' -o tsv

# workbench: kubectl이 <k8s>의 마이너와 같은지. 다르면 먼저 workbench를 올린다(2.5)
kubectl version
```

### 2.3. 관리형 addon의 변경

AKS가 컨트롤플레인과 함께 올리는 addon(Cilium·CoreDNS·KEDA·App Routing·NAP)은 버전 핀이 없다. 무엇이 바뀌는지는
[Supported Kubernetes versions](https://learn.microsoft.com/en-us/azure/aks/supported-kubernetes-versions)의
「AKS components breaking changes by version」 표에서 `<k8s>` 마이너의 줄을 읽는다. 3단계에서 확인할 대상이다.

### 2.4. 플랫폼 addon 호환성

`aks-platform-gitops`가 버전을 핀하는 것은 Kyverno와 ArgoCD 둘이다. ⛔ 대상 마이너를 지원하지 않으면 여기서 멈추고
그 저장소의 승격 절차로 **양 티어를 먼저** 올린다.

| addon | 확인하는 곳 |
|-------|-------------|
| Kyverno 엔진·정책 | `addons/cluster-addons/values.yaml`의 `versions.kyverno`. 릴리스 노트의 지원 범위 |
| ArgoCD | `bootstrap/argocd-app.yaml`의 `targetRevision`. 차트 `kubeVersion` |

### 2.5. workbench의 `kubectl`

`kubectl`은 API 서버와 한 마이너 차이까지 지원된다. `live/<env>/workbench/main.tf`의 `kubectl_version`을
`<k8s>`의 마이너로 미리 핀해 두면 올리기 전과 뒤 양쪽에서 범위 안이라 이 절차에 workbench 단계가 없다. 핀이
다르면 이 절차 전에 workbench를 apply한다(VM이 교체되고 SSH 세션이 끊긴다).

### 2.6. 워크로드와 용량

```bash
# workbench: ALLOWED DISRUPTIONS가 0인 PDB가 있으면 그 파드가 있는 노드는 비워지지 않는다
kubectl get pdb -A

# 로컬: 시스템 풀 surge 노드 한 대분의 vCPU 여유
az vm list-usage --location koreacentral --query "[?contains(name.value,'standardDSv5Family')]" -o table
```

| 워크로드 | 노드 교체 때 |
|----------|-------------|
| 복제본 2개 이상에 PDB가 있다 | 끊기지 않았다 |
| 복제본이 하나다 | NAP 노드 교체에서 끊기지 않았다. preStop으로 종료를 늦춘 파드다 |
| PDB가 eviction을 전부 막는다 | drain timeout(기본 30분)이 지나면 시스템 풀 apply가 실패한다 ⏳ |

### 2.7. 진행할지 정한다

아래가 전부 "진행"이어야 1단계로 간다. 하나라도 "멈춤"이면 고치고 처음부터 다시 본다.

| 확인 | 진행 | 멈춤 |
|------|------|------|
| 앞 티어 클러스터를 올린 뒤의 대기(hub만) | 사이트의 변경 관리 규칙이 정한 기간이 지났다 | 안 지났다 |
| 클러스터와 시스템 풀의 상태 | 둘 다 `Succeeded` | 그 밖 |
| 진행 중인 AKS 작업 | 클러스터·시스템 풀 모두 종료 상태(`Succeeded`·`Failed`·`Canceled`) | 진행 중. 노드 이미지 자동 업그레이드일 수 있다 |
| 버전 | `cp`와 `pools[].v`가 같은 패치(2.2) | 다르다 |
| deprecated API | 포털 「Diagnose and solve problems → Kubernetes API deprecations」에 대상 마이너의 항목이 없다 | 있다 |
| 플랫폼 addon(2.4) | 대상 마이너를 지원한다 | 지원하지 않는다 |
| `kubectl`(2.5) | 대상 마이너와 같다 | 다르다 |
| PDB와 쿼터(2.6) | 허용 disruption이 0인 PDB가 없고 노드 한 대분의 vCPU가 남는다 | 그 밖 |

```bash
# 로컬: 상태
az aks show -g "$RG" -n "$CLUSTER" --query '{cluster:provisioningState, pools:agentPoolProfiles[].provisioningState}'

# 로컬: 마지막 작업. status가 종료 상태여야 한다
az aks operation show-latest -g "$RG" -n "$CLUSTER" --query '{status:status,start:startTime}'
az aks operation show-latest -g "$RG" -n "$CLUSTER" --nodepool-name npsystem --query '{status:status,start:startTime}'
```

---

## 3. 절차

### 3.1. NAP disruption 차단

- **고칠 곳**: `aks-platform-gitops` `addons/karpenter/nodepool/values.yaml`. **올릴 클러스터의 티어 줄만** 바꾼다.

```yaml
disruptionBlockByTier:
  prd: false
  nonprd: true      # dev를 올리는 동안
```

```bash
# workbench: {"nodes":"0","reasons":["Drifted","Underutilized"]}가 보여야 한다
kubectl get nodepool general-purpose -o jsonpath='{.spec.disruption.budgets}'; echo
```

- **완료 조건**: 올릴 클러스터에 위 줄이 보인다. ⛔ 반대 티어 클러스터에서도 같은 명령을 돌려 `Drifted`를
  막는 줄이 없는지 본다.
- NAP 노드가 지금 없는 클러스터에도 건다. 올리는 도중 스케일 아웃으로 생길 수 있다.

### 3.2. 컨트롤플레인 apply

- **고칠 곳**: `live/<env>/aks/main.tf`의 `module "aks_cluster"`. 시스템 풀의 값은 그대로 둔다.

```hcl
kubernetes_version = "<k8s>"
```

plan에는 `module.aks_cluster.azurerm_kubernetes_cluster.this[0]`의 `kubernetes_version`이 바뀌는
`update in-place` 한 줄만 뜬다. 요약 줄은 `Plan: 0 to add, 1 to change, 0 to destroy`다.

⛔ `orchestrator_version`이 함께 뜨거나 클러스터가 `must be replaced`로 뜨면 승인하지 않는다.

```bash
# 로컬: 진행 중. status가 InProgress에서 Succeeded로 바뀐다
az aks operation show-latest -g "$RG" -n "$CLUSTER" --query '{status:status,start:startTime,error:error}'
```

실측은 4~5분이다. 15분이 지나도 `InProgress`면 7절을 본다.

```bash
# 로컬:
az aks show -g "$RG" -n "$CLUSTER" --query '{cp:currentKubernetesVersion,state:provisioningState}'
```

- **완료 조건**: `cp`가 `<k8s>`이고 `state`가 `Succeeded`다. 노드는 전부 옛 마이너에 남아 있다.
- 이 apply 안에서 AKS가 관리형 addon을 올린다. Cilium DaemonSet이 전 노드에서 다시 뜨고 CoreDNS·KEDA·
  cloud-node-manager·CSI 드라이버가 롤링된다. 그동안 Service 호출은 끊기지 않았다.
- 완료 뒤 5분쯤 지나면 NAP 노드의 NodeClaim에 `Drifted`(`K8sVersionDrift`)가 붙는다. 차단 때문에 교체되지 않는
  것이 정상이다. Karpenter 이벤트에 `No allowed disruptions for disruption reason Drifted due to blocking budget`이
  남는다.

### 3.3. 관리형 addon 확인

```bash
# workbench: Running·Completed가 아닌 파드가 없어야 한다
kubectl get pods -A | grep -vE 'Running|Completed'

# workbench: DNS 해석, Gateway, KEDA 외부 metrics API
kubectl run dnscheck --rm -i --restart=Never --image=busybox:1.36 \
  --overrides='{"spec":{"containers":[{"name":"dnscheck","image":"busybox:1.36","command":["nslookup","kubernetes.default.svc.cluster.local"],"resources":{"requests":{"cpu":"50m","memory":"32Mi"},"limits":{"memory":"32Mi"}}}]}}'
kubectl get gateway -A
kubectl get apiservice v1beta1.external.metrics.k8s.io
```

- **완료 조건**: DNS가 풀리고 Gateway가 `Programmed`이고 metrics API가 `True`다. `runbooks.md` 「GitOps 상태
  확인」의 Application이 전부 `Synced`/`Healthy`다.
- `--overrides`는 Kyverno의 `require-nodepool-resources`가 requests 없는 파드를 거부해서 붙인다.

### 3.4. 시스템 풀 apply

- **고칠 곳**: 같은 파일의 `system_node_pool.kubernetes_version`. 3.2와 같은 값이다.

```hcl
system_node_pool = {
  kubernetes_version = "<k8s>"
}
```

plan에는 `default_node_pool`의 `orchestrator_version`이 바뀌는 `update in-place` 한 줄만 뜬다. 요약 줄은
`Plan: 0 to add, 1 to change, 0 to destroy`다.

```bash
# workbench: 시스템 노드만 바뀌고 NAP 노드는 그대로여야 한다
kubectl get nodes -L karpenter.sh/nodepool -w

# workbench: AKS가 남기는 Surge·Cordon·Drain 이벤트. 1시간 뒤 사라지므로 작업 중에 본다
kubectl get events --field-selector source=upgrader -w

# 로컬: 풀 단위 작업의 상태와 오류
az aks operation show-latest -g "$RG" -n "$CLUSTER" --nodepool-name npsystem --query '{status:status,error:error}'
```

surge 노드 한 대가 새 마이너로 뜨고, 기존 노드가 한 대씩 cordon·drain된 뒤 같은 이름으로 새 마이너가 되어
돌아온다. 노드 한 대에 3분 반쯤 걸리고 마지막에 surge 노드가 빠진다. 한 노드가 10분 넘게
`SchedulingDisabled`에 머물면 drain이 막힌 것이다. 7절을 본다. drain 중에 KEDA의 PDB가 eviction을 잠깐
막는 이벤트(`Eviction blocked by Too Many Requests`)가 남지만 스스로 풀린다.

- **완료 조건**: 시스템 노드가 전부 `<k8s>`이고 `Ready`다. NAP 노드는 옛 마이너에 남아 있다.
- ⚠️ 내부 LB(`externalTrafficPolicy: Cluster`)를 거치는 호출이 이 구간에 드물게 시간 초과된다. 시스템 노드가
  LB 백엔드에서 빠지고 들어오는 순간이다. 측정에서는 약 2만 2천 회 중 3회였고 파드는 움직이지 않았다.

### 3.5. NAP disruption 차단 해제

- **고칠 곳**: 3.1에서 `true`로 바꾼 줄을 `false`로 되돌린다.

```bash
# workbench: NAP 노드가 한 대씩 대상 마이너로 바뀐다
kubectl get nodes -L karpenter.sh/nodepool -w
```

budget이 반영되면 30초 안에 교체가 시작된다. Karpenter가 대체 노드를 먼저 띄우고 기존 노드를 비운다. 노드 10대
이하에서는 한 번에 한 대이고 대당 1분 반쯤 걸린다.

- **완료 조건**: `kubectl get nodes`의 `VERSION`이 전부 `<k8s>`다.
- 🔑 여기서부터는 app 워크로드가 새 마이너의 kubelet에 있다. NAP 노드는 되돌릴 수 없다.

---

## 4. 완료 판정

| 확인 | 명령 | 기대 |
|------|------|------|
| 버전 | 2.2의 `az aks show` | `cp`와 `pools[].v`가 `<k8s>` |
| 노드 | `kubectl get nodes` | 전 노드가 `<k8s>`, `Ready` |
| GitOps | `runbooks.md` 「GitOps 상태 확인」 | 전부 `Synced`/`Healthy` |
| disruption 차단 | 3.1의 조회 | `Drifted`를 막는 줄이 없다 |
| 드리프트 | `gh workflow run deploy-<env>-aks.yml --ref main -f action=plan` | plan job 로그에 `No changes` |

---

## 5. hub를 올릴 때 다른 점

| 항목 | dev | hub |
|------|-----|-----|
| 티어 줄 | `nonprd` | `prd` |
| 시스템 풀 | 2대 | 3대(ArgoCD `redis-ha`가 요구한다) |
| GitOps 반영 | hub의 ArgoCD가 dev에 민다 | hub의 ArgoCD가 자기 클러스터에 건다 |
| 시스템 풀 apply | 플랫폼 컴포넌트가 옮겨진다 | **ArgoCD도 함께 옮겨진다** |

- ⚠️ hub의 시스템 풀 apply 동안 ArgoCD가 노드와 함께 옮겨진다. server·repo-server·applicationset은 복제본 2개에
  PDB가 있어 argocd-server 호출이 끊기지 않았다. 복제본이 하나인 application-controller가 옮겨지는 13초 동안 dev를
  포함한 전 클러스터의 reconcile이 멈췄다가 스스로 이어진다. `argocd`·`root-app`이 잠깐 `Progressing`이 된다.
  ⛔ 그 구간에는 `aks-platform-gitops`에 머지하지 않는다.
- dev와 hub의 `main.tf`를 한 PR에 함께 올리지 않는다. 두 plan이 동시에 떠 순서가 사라진다.
- dev가 `<k8s>`이고 hub가 옛 마이너인 동안 `aks-platform-gitops`의 티어로 가르지 않은 매니페스트는 두 마이너
  모두에서 유효해야 한다. 새 마이너에만 있는 API를 쓰는 변경은 hub까지 끝난 뒤에 머지한다.

---

## 6. 시스템 풀 되돌리기

시스템 풀의 플랫폼 컴포넌트(ArgoCD·Kyverno·관리형 addon)가 새 kubelet·런타임에서 깨졌을 때 연다. 컨트롤플레인,
관리형 addon의 버전, NAP 노드는 되돌아가지 않는다.

| 조건 | 내용 |
|------|------|
| 기한 | 시스템 풀 업그레이드 완료 뒤 7일 |
| 범위 | 직전 버전 하나. 그 버전이 AKS에서 아직 지원 중일 것 |
| 차단 | 3.5 전이면 차단을 그대로 둔다 |

**3.4의 커밋을 revert해 PR로 머지한다.** plan에는 `orchestrator_version`이 내려가는 `update in-place` 한 줄이 뜨고,
AKS가 그 값을 받는다. 올릴 때와 같은 방식으로 교체되고 노드 2대에 12분이 걸렸다.

```bash
# 로컬: 되돌릴 수 있는 버전. 비어 있으면 기한이 지났거나 그 버전이 지원 밖이다
az aks nodepool get-rollback-versions -g "$RG" --cluster-name "$CLUSTER" -n npsystem
```

- **완료 조건**: 2.2의 `pools[].v`가 옛 버전이다. `action=plan`이 `No changes`다.
- 노드 이미지 자동 업그레이드(`nodeOsUpgradeChannel: NodeImage`)가 켜져 있어, 그 사이 새 이미지가 나왔다면 이전
  이미지가 복원되지 않을 수 있다. `<image>`와 비교한다 ⏳.
- revert가 apply에서 거부되면 `az aks nodepool rollback -g "$RG" --cluster-name "$CLUSTER" -n npsystem`을 사람이 로컬에서
  실행하고, 끝난 뒤 revert를 머지해 코드를 실제와 맞춘다 ⏳.

---

## 7. 실패했을 때

먼저 무엇이 실패했는지 읽는다. CI run의 apply job 로그, AKS 작업의 오류, 활동 로그 순이다.

```bash
# 로컬: AKS 작업의 오류(code·subcode·message)
az aks operation show-latest -g "$RG" -n "$CLUSTER" --query '{status:status,error:error}'
az aks operation show-latest -g "$RG" -n "$CLUSTER" --nodepool-name npsystem --query '{status:status,error:error}'

# 로컬: AKS가 받기 전에 거부한 요청은 위에 남지 않는다. 활동 로그를 본다
az monitor activity-log list --resource-id "$(az aks show -g "$RG" -n "$CLUSTER" --query id -o tsv)" \
  --offset 6h --status Failed --query '[].{time:eventTimestamp,op:operationName.localizedValue,msg:properties.statusMessage}'
```

🔑 **다시 할 때는 CI로 한다.** 같은 커밋으로 `gh workflow run deploy-<env>-aks.yml --ref main -f action=apply`를
돌리면 같은 값의 PUT이 나가 멈춘 작업을 이어 가거나 `Failed` 상태를 맞춘다. Microsoft 문서의 `az aks update`·
`az aks nodepool upgrade`로 직접 맞추지 않는다. 적용 경로가 CI 밖에 하나 더 생긴다.

| 오류·증상 | 원인 | 대응 |
|-----------|------|------|
| `OperationNotAllowed`, 다른 작업이 진행 중이라는 메시지 | 노드 이미지 자동 업그레이드 같은 다른 작업이 돌고 있다 | 2.7의 작업 조회가 종료 상태가 될 때까지 기다린 뒤 다시 한다 |
| `UpgradeBlockedOnDeprecatedAPIUsage` | 지난 12시간에 deprecated API를 쓴 클라이언트가 있다 | 2.7의 포털 진단으로 대상을 찾아 고치고 12시간 뒤 다시 한다. `upgrade_override`로 건너뛰지 않는다 ⏳ |
| `UpgradeFailed`·`PodDrainFailure`, 노드가 오래 `SchedulingDisabled` | PDB나 끝나지 않는 파드가 drain을 막는다. drain timeout(기본 30분)이 지나면 작업이 멈춘다 | `kubectl get pdb -A`에서 허용 disruption이 0인 것을 찾아 푼 뒤 다시 한다 ⏳ |
| `QuotaExceeded`·`AllocationFailed`·`SkuNotAvailable` | surge 노드를 띄우지 못했다 | 2.6의 쿼터를 다시 보고 확보한 뒤 다시 한다 |
| `SubnetIsFull` | 노드 서브넷에 surge 노드의 IP가 없다 | 서브넷 여유를 확보한 뒤 다시 한다 |
| 클러스터·풀이 `Failed`로 남았다 | 위 원인 중 하나가 해소되지 않았다 | 원인을 고친 뒤 다시 한다. 같은 오류가 반복되면 그 오류를 다시 읽는다 |
| apply job이 실패했는데 AKS 작업은 `InProgress`다 | CI가 먼저 끝났다. AKS는 작업을 계속한다 | 작업이 종료 상태가 될 때까지 기다린 뒤 `action=plan`으로 코드와 실제를 비교한다 |
| 너무 오래 걸린다 | | `az aks operation-abort -g "$RG" -n "$CLUSTER"`로 멈출 수 있다. 이미 적용된 변경은 되돌아가지 않고, 멈춘 뒤 다시 하면 이어 간다 ⏳ |

### 자주 막히는 지점

| 단계 | 증상 | 원인과 대응 |
|------|------|-------------|
| 컨트롤플레인 apply | plan에 `orchestrator_version`이 함께 뜬다 | 시스템 풀의 값을 함께 바꿨다. Reject하고 커밋을 나눈다 |
| 차단 | 차단 줄이 반대 티어에도 붙었다 | 두 줄을 함께 바꿨다. 반대 티어 줄을 `false`로 되돌린다 |
| 차단 해제 | NAP 노드가 옛 마이너에 남는다 | `kubectl describe nodeclaim`으로 drift 판정과 막는 사유(PDB, `karpenter.sh/do-not-disrupt`)를 읽는다 |
| 전 단계 | 로컬 명령이 `ResourceNotFound`로 끝난다 | 구독이 다르다. 1절의 변수를 그 환경 값으로 다시 정한다 |
| 전 단계 | 승인 게이트가 서지 않고 apply가 `skipped`다 | plan에 변경이 없다. 값이 실제로 바뀌었는지 plan job 로그로 본다 |
| 전 단계 | 머지가 `required status checks`로 거부된다 | PR의 검사가 아직 돌고 있다. `gh pr checks <번호> --watch`로 끝난 것을 보고 머지한다 |
