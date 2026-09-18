# hub 구독 생애주기: 구축과 철거

**읽는 사람**: hub 구독의 인프라를 구축하거나 철거하는 사람.

레퍼런스 구현은 이 저장소의 `bootstrap/`·`live/hub/`에 있다. spoke(dev)는 `spoke-lifecycle.md`를 본다(hub가 먼저 구축되어 있어야 spoke를 구축할 수 있다, 크로스 구독 vWAN 연결이 hub 쪽에서 스포크를 끌어당기는 구조라서다).

---

## 구축

### 0. 준비물

| 항목 | 확인 |
|------|------|
| Azure 구독 + Owner 또는 User Access Administrator 권한 | `az account show` |
| GitHub org + 저장소 생성 권한 | |
| 로컬 도구 | `tofu`(1.12.5) · `az` · `gh` · `jq` |
| `iac-module-library`가 private이면 | 배포 저장소가 클론할 GitHub App이 필요하다(`MODULE_READER_CLIENT_ID`) |

```bash
brew install opentofu azure-cli gh jq
```

### 1. 착수 전에 확정할 값

**되돌릴 수 없는 것들이다.**

| 값 | 예 | 왜 되돌릴 수 없나 |
|----|-----|------------------|
| `workload` 코드 | `demo` | 모든 리소스 이름에 들어간다 |
| 리전 | `koreacentral`(`krc`) | 전면 재구축 |
| hub VNet CIDR | `10.60.0.0/16` | VNet 재생성(`deletion_protection` 해제 필요, 11절) |
| AKS `cni_mode`·`pod_cidr` | `overlay`·`10.244.0.0/16` | `network_profile` 블록 전체가 ForceNew(클러스터 재생성) |
| AKS `private_cluster_enabled` | `true` | Portal 그래픽 뷰 접근이 원천 차단된다(우회는 workbench 또는 `az aks command invoke`뿐) |
| hub·dev를 어디 둘지(같은 구독/분리 구독) | 분리 구독 | 크로스 구독 vWAN 권한(`peer/action`) 재설계 |

### 2. 배포 저장소 만들기

```bash
gh repo create <org>/<project>-infra --private
```

```
bootstrap/                 state Storage Account · App Registration · 커스텀 역할   (IaC 밖)
live/hub/networking/       VNet
live/hub/vwan/             Virtual WAN(networking과 분리된 state)
live/hub/aks/              AKS 클러스터
live/hub/workbench/        CLI 전용 운영 VM
.github/workflows/         배포 루트마다 워크플로 하나
```

루트마다 **state를 분리**한다. 결합은 `terraform_remote_state`가 아니라 **Name·태그 기반 `data` 조회**로만 한다. 크로스 구독(4절의 dev VNet 자동 발견)도 예외가 아니다 - 두 번째 provider(별칭)로 대상 구독을 향해 같은 태그 기반 조회를 한다.

### 3. 부트스트랩: state Storage Account · App Registration · 커스텀 역할

```bash
export EXPECTED_SUBSCRIPTION=<GUID>   # 필수. 기본값이 없다
export EXPECTED_TENANT=<GUID>         # 필수. 기본값이 없다

cd bootstrap
./bootstrap.sh      # 생성·수렴 (BOOTSTRAP_TARGET 기본 hub)
./verify.sh         # drift 확인만
```

기대 상태(SSOT)는 `../bootstrap/README.md`가 가진다: 값을 여기 다시 적지 않는다. `config.sh`는 그 코드 측면이다.

CI 신원은 **구독 전체 스코프의 `Owner` 등가**를 갖는다. 방어선은 권한 크기가 아니라 FIC(Federated Identity Credential) `subject`를 이 repo·`main` 브랜치 하나로 좁히는 것뿐이다. CLAUDE.md의 ⛔ 항목을 반드시 먼저 읽는다.

Storage Account명은 **git에 넣지 않는다.** GitHub repo 변수 `HUB_TF_STATE_ACCOUNT`와 로컬 `backend.hcl`(각 root의 `backend.hcl.example`을 복사)에만 둔다. GitHub repo 변수는 최소 `AZURE_HUB_CLIENT_ID`·`AZURE_TENANT_ID`·`AZURE_HUB_SUBSCRIPTION_ID`·`HUB_TF_STATE_ACCOUNT`가 필요하다(bootstrap.sh 출력을 그대로 등록).

### 4. 네트워킹과 vWAN (L1)

`live/hub/vwan`은 `live/hub/networking`과 **분리된 state**다. vWAN의 `azurerm_virtual_hub_connection.hub`가 `data.azurerm_virtual_network`로 hub VNet을 Name 기반 조회하므로, **networking을 먼저 apply해야 한다.** 순서가 자유롭지 않다.

```bash
cp live/hub/networking/backend.hcl.example live/hub/networking/backend.hcl
# storage_account_name을 bootstrap.sh 출력값으로 채운다(값은 git에 남기지 않는다)
tofu -chdir=live/hub/networking init -backend-config=backend.hcl
tofu -chdir=live/hub/networking validate
```

> 🔴 **로컬에서 `plan`·`apply`는 성립하지 않는다.** `require_oidc`/`var.ci_run` 가드가 `var.ci_run != true`이면 즉시 실패시킨다. **로컬은 `init`+`validate`까지**이고, 그 위는 전부 워크플로가 한다.

```bash
gh workflow run deploy-hub-network.yml --ref main -f action=apply
```

같은 방식으로 `live/hub/vwan`을 초기화한다(`key = "hub/vwan.tfstate"`). 스포크(dev) VNet은
`azurerm_resources`(태그 `Workload` 기준, `Environment` 값이 연결 키)로 **자동 발견**한다
(bootstrap.sh `BOOTSTRAP_TARGET=spoke`가 부여하는 `virtualNetworks/read`+`peer/action`
2액션만 있으면 된다). dev가 아직 없으면 이 data
source는 빈 리스트를 반환해 스포크 연결 0개로 정상 apply된다 - **hub를 spoke 없이 통째로
먼저 지어도 된다.**

```bash
gh workflow run deploy-hub-vwan.yml --ref main -f action=apply
```

> **networking apply 전까지 vwan 워크플로의 plan은 실패한다**(hub VNet을 못 찾는다), 순서가 있다는 신호이지 고장이 아니다.

🔑 **dev(spoke)가 나중에 생기면 이 워크플로를 한 번 더 apply한다.** AWS 원본
(`eks-reference-infra` `docs/spoke-lifecycle.md`)의 "hub networking → hub eks → spoke
networking → spoke eks → **hub networking 재적용**"과 정확히 같은 패턴이다 - hub는 spoke
존재 여부와 무관하게 완결적으로 지을 수 있고, dev networking이 그 뒤에 생기면 hub vwan을
한 번 더 apply해야 그 연결이 채워진다. 스포크가 여러 개(qa 등)로 늘어나도 태그만 맞으면
코드 변경 없이 같은 재적용으로 전부 잡힌다.

### 5. AKS 클러스터 (L2)

같은 방식으로 `live/hub/aks`를 초기화한다(`key = "hub/aks.tfstate"`). 이 root는 `data.azurerm_subnet`으로 `aks-node` 서브넷을 Name 기반 조회하므로 networking이 먼저 있어야 한다. vWAN과는 직접 의존이 없지만, 관례상 networking → vwan → aks 순서로 진행한다.

identity·role assignment는 **이 root가 Terraform으로 직접 만든다**(bootstrap이 아니다. CI가 구독 전체 Owner 등가라 그 구조적 제약이 없다). `aks-cluster` 모듈 자체는 identity도 role assignment도 만들지 않는 경계 원칙을 유지한다.

hub ArgoCD의 Workload Identity(GitOps 크로스 클러스터 인증용 UAMI+FIC)도 이 root가 만든다. FIC의 issuer가 *이 클러스터 자신의* OIDC issuer URL에 묶여야 해서다. 다른 root(vwan 등)에서 이 클러스터를 `data`로 재조회해 만들면 networking→vwan→aks 순서의 from-scratch 구축에서 AKS가 아직 없어 실패한다.

⚠️ **hub를 재구축하면 이 UAMI도 새로 발급된다.** 스포크마다 `live/<env>/aks`를 다시 apply해 role assignment를 새 principal로 옮기고, `aks-platform-gitops`의 cluster Secret에 적힌 client ID를 갱신한다(`spoke-lifecycle.md` 재배포 절).

```bash
gh workflow run deploy-hub-aks.yml --ref main -f action=apply
```

> 🔴 **`cni_mode`·`pod_cidr`·`private_cluster_enabled`는 `network_profile` 블록 전체가 ForceNew라 첫 apply가 사실상 최종 선택이다.** 1절에서 값을 미리 확정해 둔다.

🔑 **node resource group(`MC_*`)에 우리 Terraform이 만든 적 없는 리소스가 자동으로 생긴다.** apply 직후 확인 방법:

```bash
NODE_RG=$(az aks show -g <rg> -n <cluster> --query nodeResourceGroup -o tsv)
az resource list --resource-group "$NODE_RG" -o table
```

이 저장소 hub 클러스터 기준 내용물: VMSS(노드 컴퓨트, 가장 큰 비용 항목)·`kubernetes-internal`(내부 LB, 7절 Gateway가 붙는 바로 그 LB)·NSG(AKS 자체 생성분 - `live/hub/networking`이 서브넷 레벨에 만드는 NSG와는 별개 리소스)·API 서버 Private Endpoint+NIC·private DNS zone+VNet link(`private_cluster_enabled=true`라 생김)·managed identity 2종(kubelet용·App Routing workload identity). 전부 클러스터 태그(`Workload`·`Environment`)를 물려받지만:

- **IAM**: 워크로드 RG 하나에만 스코프된 역할로는 이 RG 안을 Azure RBAC로 못 본다(K8s RBAC와 별개 축) - CI 신원을 구독 전체 Owner로 둔 이유 중 하나가 정확히 이 제약이다(0절, `bootstrap/config.sh` 관련 주석 참고).
- **비용**: 리소스 그룹별 Cost Analysis에서 hub 비용이 두 RG로 쪼개져 보인다. 태그 기준 조회로 우회한다.
- **라이프사이클**: 10절 표의 `MC_*` 행 참고 - destroy 시 "대개" 자동 정리되지만 IaC 밖 자원이 남아있으면 지연된다.

Container Insights(`omsagent` addon)를 켜면 Log Analytics workspace도 이 RG가 아닌 별도 위치(기본값 `DefaultResourceGroup-<region>`)에 또 생긴다 - 지금은 addon이 꺼져 있어 해당 없음(`az aks show --query addonProfiles.omsagent`로 확인).

### 6. workbench: private 클러스터의 유일한 일상 접근 지점 (L2.5)

같은 방식으로 `live/hub/workbench`를 초기화한다(`key = "hub/workbench.tfstate"`). 이 root는 `data.azurerm_kubernetes_cluster`로 AKS 클러스터를 Name 기반 조회하므로 **아래가 먼저 있어야 한다**: AKS 클러스터. identity·role assignment는 aks와 같은 패턴으로 이 root가 직접 만든다.

```hcl
# GitHub repo 변수로 주입, git에 값을 남기지 않는다
AZURE_HUB_WORKBENCH_SSH_CIDRS       # SSH 인바운드 허용 CIDR
AZURE_HUB_WORKBENCH_ADMIN_OBJECT_ID # sudo 가능한 Entra 계정(Administrator Login)
```

```bash
gh workflow run deploy-hub-workbench.yml --ref main -f action=apply
```

apply 후 접근을 확인한다(private key는 `~/.ssh/`에만 존재, `.pub`만 커밋):

```bash
ssh -i ~/.ssh/workbench_ed25519 azureuser@<workbench 공인 IP>
kubectl get nodes            # sudo 없이 동작해야 한다
```

콘솔 접속은 `argocd-tunnel-connect` 스킬(2단 SSH 터널)을 쓴다. Azure Portal 그래픽 뷰는 private cluster 특성상 원천적으로 안 되고, 관리형 우회는 Portal 내장 `Run command` 또는 `az aks command invoke`뿐이다(workbench보다 약하다. kubectl 직접 실행이 아니라 명령 하나씩 던지는 방식이다).

### 7. GitOps 씨딩 (L3)

hub만 자기 `argocd-seed.sh`를 돈다.

```bash
gh repo create <org>/<project>-platform-gitops --public
```

`eks-platform-gitops`의 레이아웃을 그대로 본뜬다(self-managed ArgoCD + App-of-Apps). **이 저장소에 `.tf`를 두지 않는다.** Terraform은 identity·federated credential·role assignment까지만 만들고(위 5절의 hub ArgoCD workload identity), helm 설치·CR은 전부 GitOps 소관이다. public이어야 한다: ArgoCD가 repository Secret 없이 익명으로 읽고, workbench도 자격증명 없이 클론한다. private이면 seed의 preflight가 익명 `ls-remote`에서 멈춘다.

`argocd-seed.sh`는 `<project>-platform-gitops`의 `bootstrap/`에 있다(이 저장소의 `bootstrap/`과는 다른 디렉토리 - 혼동 주의). workbench에는 **자격증명이 미리 심어져 있지 않다**(cloud-init이 credential을 VM 상태에 남기지 않는 설계). 저장소가 public이라 그 상태로 클론이 된다:

```bash
# workbench에서 실행한다
export GITOPS_REPO_DIR=$HOME/<project>-platform-gitops
export CLUSTER_DIR=clusters/hub/<cluster-name>
git clone https://github.com/<org>/<project>-platform-gitops.git "$GITOPS_REPO_DIR"
cd "$GITOPS_REPO_DIR/bootstrap"
./argocd-seed.sh --dry-run
./argocd-seed.sh               # root Application까지 - argocd-app.yaml은 root-app의
                                # 재귀 스캔으로 자동 흡수되어 별도 단계가 없다
argocd app diff argocd --core  # 출력 없음·exit 0이 기대값(무해한 diff도 없어야 한다)
```

스크립트는 매니페스트를 **생성하지 않는다.** GitOps 저장소에 커밋된 파일을 그대로 apply한다.

**완료 조건: 초기 admin 비밀번호 교체**는 선택이 아니다. 교체 후 `argocd-initial-admin-secret`을 삭제한다. 절차는 `runbooks.md` 「ArgoCD 관리자 비밀번호 교체」가 소유한다.

### 8. 완료 판정

| # | 확인 | 명령 |
|---|------|------|
| 1 | 부트스트랩 drift 없음 | `./bootstrap/verify.sh` |
| 2 | 노드가 Ready | `az aks command invoke -g <rg> -n <cluster> --command "kubectl get nodes -o wide"` (또는 workbench에서 직접) |
| 3 | `network_profile`이 요청대로 적용 | `az aks show -g <rg> -n <cluster> --query networkProfile` |
| 4 | root Application이 커밋 SHA를 읽음 | `kubectl -n argocd get application root-app -o jsonpath='{.status.sync.revision}'`(`root-app`은 single-source라 `revision` 단수 필드다. `revisions` 배열은 multi-source Application만 쓴다) |
| 5 | 전 Application이 `Synced`/`Healthy` | `kubectl -n argocd get applications` |
| 6 | 초기 비밀번호 Secret 삭제됨 | `kubectl -n argocd get secret argocd-initial-admin-secret` → NotFound |
| 7 | CI 재-plan 수렴 | 각 root에서 `No changes` |

5번은 **두 열을 따로 본다**: `Synced`는 "Git이 요구한 것을 적용했다"일 뿐이고, 그 요구 자체가 틀렸으면 여전히 `Synced`다.

---

## 철거

### 9. 시작 전에: 공용 구독이면 특히 읽는다

**삭제는 이 자산에서 가장 위험한 작업이다.**

```bash
az resource list --query "length([])"
az aks list --query "length([])"
```

여러 개가 나오면 공용 구독이다. **이름을 눈으로 보고 지우지 않는다**: 이후 모든 수동 정리는 반드시 태그(`Workload`·`Environment`)로 특정한다.

```bash
az resource list --tag Workload=demo --tag Environment=hub
```

### 10. 삭제는 생성의 역순이 아니다

`tofu destroy`는 **IaC가 만들지 않은 것을 모른다.**

| 무엇이 남는가 | 누가 만들었나 | tofu가 아는가 |
|--------------|-------------|--------------|
| NAP(Karpenter) 노드 VM/VMSS | NAP 컨트롤러 | ❌ |
| Application Gateway for Containers 리소스 | AGFC ALB Controller | ❌ |
| Managed Disk(PVC) | CSI 드라이버 | ❌ |
| LoadBalancer 타입 Service + Public IP | Azure LB(cloud provider) | ❌ |
| CRD | helm 차트(`crds.keep`류) | ❌ |
| `MC_*`(node) 리소스 그룹 | AKS 자신 | 클러스터 삭제 시 Azure가 자동 정리(대개, 12절 참고) |

**이것들을 먼저 치우지 않으면**: NAP 노드는 계속 과금되고, AGFC 리소스는 `MC_*` RG 삭제를 지연시킬 수 있다.

0단계 삭제 보호 해제 → 1단계 클러스터 안에서 IaC 밖 자원 선처리 → 2단계 L2 destroy (workbench·aks) → 3단계 L1 destroy(vwan·networking 순) → 4단계 잔존물 검증(destroy의 "성공" 보고를 믿지 않는다).

### 11. 0단계: 삭제 보호 해제

VNet은 `deletion_protection`이 **모듈 변수**다.

```hcl
# live/hub/networking/main.tf
module "vnet" { deletion_protection = false ... }
```

vWAN은 다르다. `azurerm_virtual_wan`·`azurerm_virtual_hub` 둘 다 `lifecycle { prevent_destroy = true }`가 **하드코딩**돼 있다. 변수로 못 끈다. 코드를 직접 고쳐야 한다.

```hcl
# live/hub/vwan/main.tf, 두 리소스 모두
lifecycle {
  prevent_destroy = false
}
```

```bash
gh workflow run deploy-hub-network.yml --ref main -f action=apply
gh workflow run deploy-hub-vwan.yml    --ref main -f action=apply
```

⛔ **이 커밋을 되돌리는 것까지가 이 단계다.** 재구축한 뒤에는 `true`로 복원한다.

> 🔴 **VNet과 vWAN은 이 단계에서 다르게 반응한다.** VNet의 `deletion_protection`은 `prevent_destroy`(lifecycle 메타 인자)로 번역될 뿐 Azure 쪽 실제 속성이 아니다. `false`로 apply해도 `No changes.`가 정상이다. AKS는 `deletion_protection`이 이미 `false`라 이 단계가 필요 없다.

### 12. 1단계: IaC 밖 자원 선처리

workbench에서 실행한다.

**먼저 ArgoCD 컨트롤러를 멈춘다.** 살아 있으면 아래 ②③④를 지우는 족족 되살린다.

```bash
# ① 컨트롤러 정지
kubectl -n argocd scale statefulset argocd-application-controller --replicas=0
kubectl -n argocd scale deployment  argocd-applicationset-controller --replicas=0

# ② LoadBalancer 타입 Service / AGFC가 만든 리소스
kubectl delete gateway --all -A
kubectl delete ingress --all -A
kubectl delete svc -A --field-selector spec.type=LoadBalancer

# ③ PVC
kubectl delete pvc --all -A

# ④ NAP(Karpenter) NodePool
kubectl delete nodepool --all
kubectl delete aksnodeclass --all
```

**순서가 중요하다.** ①을 건너뛰면 ArgoCD가 ②③④를 되살린다. ④를 건너뛰고 클러스터를 지우면 NAP 컨트롤러가 먼저 죽어 노드가 고아가 된다.

확인: **지운 직후가 아니라 30초쯤 뒤에 본다.**

```bash
kubectl get nodes
kubectl get nodepool -A
az network lb list --query "[?contains(name, 'kubernetes')]"
```

### 13. 2단계 · 3단계: destroy(workbench → aks → vwan → networking)

🔴 **파기도 워크플로로 한다.** 로컬 사용자가 구독 관리자여도 CI 신원이 아니면 `var.ci_run` 가드가 apply/destroy를 막는다.

```bash
gh workflow run deploy-hub-workbench.yml --ref main \
  -f action=destroy -f confirm='destroy live/hub/workbench'

gh workflow run deploy-hub-aks.yml --ref main \
  -f action=destroy -f confirm='destroy live/hub/aks'

gh workflow run deploy-hub-vwan.yml --ref main \
  -f action=destroy -f confirm='destroy live/hub/vwan'

gh workflow run deploy-hub-network.yml --ref main \
  -f action=destroy -f confirm='destroy live/hub/networking'
```

`confirm`에 루트 이름을 손으로 정확히 적어야 한다. **vwan은 networking보다 먼저 지운다.** vwan의 hub 연결(`azurerm_virtual_hub_connection.hub`)이 networking의 VNet ID를 참조하므로, VNet을 먼저 지우면 vwan destroy가 존재하지 않는 리소스를 찾다 실패한다.

> 🔴 **"읽고 누른다"의 "누른다"는 이미 지나간 뒤다.** `plan` job이 끝나자마자 `apply` job이 자동으로 이어진다: 진짜 승인 지점은 **dispatch 자체를 누르기 전**이다. `confirm` 문자열은 잘못된 루트를 파괴하는 사고만 막지 예상 밖 자원은 못 막는다. dispatch 전에 14절의 `teardown-verify.sh`로 태그 기준 현황을 먼저 본다(철거 전에 돌리면 현황 목록으로 쓸 수 있다).

```bash
az aks list --query "[?tags.Workload=='demo' && tags.Environment=='hub']"
```

### 14. 4단계: 잔존물 검증

```bash
WORKLOAD=demo ENVIRONMENT=hub EXPECTED_SUBSCRIPTION=<hub 구독 GUID> ./scripts/teardown-verify.sh
```

read-only다. 태그(`Workload`·`Environment`)로 좁혀 비용이 계속 나는 것부터 순서대로 본다:
NAT Gateway → VM(NAP 고아 노드) → VMSS → Managed Disk(`Unattached`) → Public IP(미연결) →
Load Balancer → AKS → NIC(미연결, VNet 삭제를 막는다) → VNet → `MC_*` RG → Log Analytics →
태그가 붙은 나머지 전부. state Storage Account는 bootstrap 소유라 잔존물로 세지 않고 따로
표시한다. exit 0이면 잔존물 없음, 1이면 있음, 2면 판정 불가(구독 불일치·조회 실패. "0건이라
통과"로 둔갑시키지 않는다).

⚠️ 태그가 없는 자원은 이 스크립트가 찾지 못한다. `az resource list --resource-group <rg>`로
워크로드 RG 안을 한 번 더 본다.

🔴 **`tofu destroy`가 성공해도 `MC_*` 리소스 그룹이 지연 삭제되거나 남을 수 있다.** AGFC가 만든 Application Gateway for Containers 리소스가 그 RG 안에 있으면 삭제가 지연된다. 12절의 IaC 밖 자원 선처리를 건너뛰었다는 신호다.

### 15. 부분 삭제

**GitOps만 철거**: 클러스터는 두고 ArgoCD만 뺀다. Git에서 매니페스트를 지우고 ArgoCD가 반영한 뒤 제거한다(컨트롤러를 먼저 죽이지 않는다, Git과 클러스터가 조용히 갈라진다).

```bash
helm -n argocd uninstall argocd
kubectl delete ns argocd
```

CRD는 남는다.

**노드만 줄이기 / 야간 정지(비용 절감)**: AKS 컨트롤 플레인은 끌 수 없다. 노드만 줄이거나 workbench를 멈춘다.

```bash
kubectl scale deployment --all --replicas=0 -n <ns>
kubectl delete nodepool <name>                        # NAP, 또는 --all
az vm deallocate --ids <workbench-vm-id>
```

시스템 노드 풀은 `system_node_pool`의 `node_count`를 줄여 apply한다 (`auto_scaling_enabled=false`라 수동 조정이다).

### 16. 되돌릴 수 없는 것

| 지우면 | 무엇을 잃나 |
|--------|------------|
| state Storage Account | state 전체. 남은 자원을 IaC로 회수할 방법이 사라진다 |
| Log Analytics workspace | 감사 로그. 보존 요건이 있으면 먼저 export |
| Managed Disk | 데이터. 스냅샷을 먼저 뜬다 |
| App Registration(FIC) | CI가 즉시 멈춘다. 다른 저장소가 같은 App을 쓸 수 있다면 함께 멈춘다 |

**state Storage Account는 가장 마지막에 지운다.** blob versioning + soft delete 30일이 켜져 있어 일반 삭제로는 지워지지 않는다.

### 17. 자주 막히는 지점

| 증상 | 원인 | 대응 |
|------|------|------|
| VNet destroy가 몇 분째 멈춰 있다 | NIC가 남아 있다 | `az network nic list`로 소유자 확인, aks/workbench가 완전히 사라졌는지 먼저 확인 |
| vwan destroy가 "연결 리소스 참조" 오류로 실패 | networking을 vwan보다 먼저 지웠다 | 13절 순서(vwan 먼저)를 지킨다 |
| `prevent_destroy`로 plan이 실패한다 | 삭제 보호 | 11절: 코드를 고쳐 apply한다 |
| destroy 후에도 노드가 살아 있다 | NAP 고아 | NodePool/AKSNodeClass를 먼저 지웠어야 한다(12절) |
| 클러스터를 지웠는데 `MC_*` RG가 남았다 | IaC 밖 자원이 먼저 안 죽었다(12절) | 태그로 특정해 수동 삭제 |
| workbench SSH 접속 직후 `kubectl`이 `localhost:8080` 연결 거부 | cloud-init의 `az login --identity`가 부팅 초기 IMDS 타임아웃으로 실패(apt-daily·kubelogin $HOME과 같은 부팅 레이스 계열) | `cloud-init status`로 `done` 확인 후 `sudo az login --identity --resource-id <workbench UAMI ID>` 재시도(보통 즉시 성공) → `sudo az aks get-credentials ...` → `admin_username` 홈에 `/root/.kube/config` 복사 |
| state lock이 풀리지 않는다 | apply가 중단됐다 | Storage Account의 blob lease를 확인 후 `az storage blob lease break`로 해제 |
| 로컬 destroy가 `var.ci_run` 가드로 막힌다 | `require_oidc` 조건 | 로컬 경로는 없다: 워크플로로 파기한다 |
| 지운 리소스가 되살아난다 | ArgoCD 컨트롤러가 살아 있다 | 12절: `patch`가 아니라 컨트롤러를 `scale 0` |
| `tofu init`이 provider 다운로드에서 실패 | runner-registry 간 일시적 네트워크 지연 | 새 dispatch가 아니라 `gh run rerun <run-id> --failed`(`CLAUDE.md` 참고) |
