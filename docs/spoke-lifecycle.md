# spoke(dev) 구독 생애주기: 구축과 철거

**읽는 사람**: spoke(dev)의 인프라를 구축하거나 철거하는 사람.

> ⚠️ **hub가 먼저 구축되어 있어야 한다.** spoke의 vWAN 연결은 hub 쪽(`live/hub/vwan`)이
> 태그 기반으로 자동 발견해 소유한다 - `hub-lifecycle.md`부터 본다.
> **검증 상태**: hub-lifecycle.md와 같은 방식(먼저 쓰고 실제 철거→재구축으로 검증)으로
> 작성했다. 0~5·7~15절은 이 저장소의 실제 배포 이력(아래 각 절 근거)에 기반한다.
> **6절(GitOps 등록)은 아직 실검증 전이다** - 이 저장소에 원격 클러스터를 self-managed
> ArgoCD에 등록한 전례가 하나도 없어(hub는 자기 자신을 등록하는 것이라 다른 문제다)
> 이번 spoke 철거→재구축 실검증에서 함께 채운다.

레퍼런스 구현은 이 저장소의 `bootstrap/`·`live/dev/`에 있다.

---

## 구축

### 0. 준비물

hub와 같다: `tofu`(1.12.5)·`az`·`gh`·`jq`. hub를 구축할 때 이미 설치했다면 이 절은
건너뛴다.

### 1. 착수 전에 확정할 값: hub와 다른 것만

| 값 | 예 | 왜 되돌릴 수 없나 |
|----|-----|------------------|
| `SPOKE_ENV` | `dev` | 부트스트랩 자원 이름 전체(Storage Account·App Registration·역할)에 들어간다 |
| 구독 | dev 전용 구독(hub와 분리) | 구독 자체는 안 바뀐다(옮기려면 재부트스트랩) |
| dev VNet CIDR | `10.61.0.0/16` | VNet 재생성(`deletion_protection` 해제 필요, 9절) |
| 클러스터 이름 | `aks-demo-dev-krc-main-01` | 클러스터 재생성 |

hub와 공통인 값(`workload` 코드·리전·AKS `cni_mode`/`pod_cidr`/`private_cluster_enabled`)은
`hub-lifecycle.md`와 같은 값을 그대로 승계한다(`live/dev/aks/main.tf` 헤더 주석: "hub를
템플릿으로 복제한 두 번째 인스턴스, 기능 범위를 hub와 완전히 동일하게 승계"). 같은 배포
저장소 안의 다른 env이므로 `workload` 코드는 반드시 hub와 동일해야 한다.

### 2. 배포 저장소: hub와 같은 repo, 새 env 하나

```
live/dev/networking/       hub와 같은 repo에 env만 새로 추가
live/dev/aks/
live/dev/workbench/
```

`bootstrap/`·`.github/workflows/`는 hub를 구축할 때 이미 있다. 새로 만들지 않는다.

### 3. 부트스트랩: `BOOTSTRAP_TARGET=spoke SPOKE_ENV=dev`

```bash
export EXPECTED_SUBSCRIPTION=<dev 구독 GUID>   # 필수. 기본값이 없다
export EXPECTED_TENANT=<GUID>                  # 필수. 기본값이 없다

cd bootstrap
BOOTSTRAP_TARGET=spoke SPOKE_ENV=dev ./bootstrap.sh
BOOTSTRAP_TARGET=spoke SPOKE_ENV=dev ./verify.sh
```

기대 상태(SSOT)는 `../bootstrap/README.md`가 가진다. **`az account show`의 활성 구독이
dev와 일치해야 한다** - `az account set --subscription <dev GUID>`로 먼저 전환한다.
기본 활성 구독이 hub면 스크립트가 즉시 구독 불일치로 중단한다(공용 테넌트에서 hub를
잘못 건드리는 사고 방지).

이 실행이 hub CI 신원에게 dev 워크로드 RG 스코프로 `aks-ref-bootstrap-spoke-peer-dev`
역할(`peer/action`+`virtualNetworks/read`)을 부여한다 - **4절의 vWAN 자동 연결이
성립하는 전제조건이다.**

### 4. 네트워크 (L1): dev는 vWAN 쪽에서 할 일이 없다

같은 방식으로 `live/dev/networking`을 초기화한다(`key = "dev/networking.tfstate"`).

```bash
gh workflow run deploy-dev-network.yml --ref main -f action=apply
```

🔑 **AWS 원본과 소유 방향이 다르다.** AWS(`eks-reference-infra`)는 spoke가 RAM 초대를
수락하고 자기 계정 권한으로 TGW attachment를 직접 만든다(AWS 원본 `spoke-lifecycle.md`). Azure
vWAN에는 RAM의 정확한 대응물이 없어 이 저장소는 **hub가 연결을 소유하는 반대 방향**을
택했다(`bootstrap/README.md` "크로스 구독 연결" 절 - 스포크 CI에 hub 컨트롤 플레인
쓰기 권한을 주는 것보다 hub SP에 스포크 읽기 권한 2액션을 주는 쪽이 더 안전하다고 판단).
그 결과 **이 root는 vWAN을 전혀 모른다**(`live/dev/networking/main.tf`: "이 root는 dev
VNet만 만들고 vWAN을 전혀 모른다") - dev 쪽에서 apply·확인할 게 없다.

> 🔑 **hub→dev 연결은 dev networking apply만으로 안 끝날 수 있다.** hub의 vwan이
> dev networking보다 먼저 서 있었다면(예: hub 단독 재구축 직후) `azurerm_resources`
> 태그 조회가 그 시점엔 빈 리스트였을 것이다 - **hub vwan을 한 번 더 apply**해야
> 연결이 채워진다(AWS 원본의 "hub networking 재적용"과 대칭, `hub-lifecycle.md` 참고).
> dev가 hub보다 먼저 있었다면(이 문서의 통상 순서) 이 재적용은 필요 없다 -
> hub vwan의 최초(또는 재구축) apply 안에서 dev 스포크 연결까지 한 번에 생긴다.

### 5. AKS와 workbench (L2)

같은 방식으로 `live/dev/aks`를 초기화한다(`key = "dev/aks.tfstate"`). hub의 모든 기능
(Karpenter/NAP·KEDA·App Routing Gateway API/Istio)을 처음부터 켠 채 승계한다 -
`enable_karpenter=true`(15차 세션 결정: dev는 hub처럼 나중에 켜는 지뢰를 처음부터
피해간다), `system_node_pool.auto_scaling_enabled=false`. 모듈 ref는 hub와 같은 태그
(`aks-cluster-v0.7.0`)로 고정한다 - hub에서 실측 검증된 설계라는 승계 근거를 유지하기
위해서다.

```bash
gh workflow run deploy-dev-aks.yml --ref main -f action=apply
```

> 🔴 **`cni_mode`·`pod_cidr`·`private_cluster_enabled`는 `network_profile` 블록 전체가
> ForceNew라 첫 apply가 사실상 최종 선택이다.** hub와 동일 값을 그대로 쓰므로 1절에서
> 이미 확정돼 있다.

같은 방식으로 `live/dev/workbench`를 초기화한다(`key = "dev/workbench.tfstate"`,
2026-09-08 신설). `live/hub/workbench`를 템플릿으로 그대로 복제한다 - 모듈 ref
(`aks-workbench-v0.5.0`)·도구 핀(az·kubectl·helm·argocd·krew)까지 hub와 동일하다.
env=dev로 갈리는 축만 치환한다: backend key(`dev/workbench.tfstate`)·tfstate RG
(`rg-demo-dev-krc-tfstate-01`)·Storage Account 참조(`DEV_TF_STATE_ACCOUNT`)·CI 신원
(`AZURE_DEV_CLIENT_ID`·`AZURE_DEV_SUBSCRIPTION_ID`)·workbench 변수(`AZURE_DEV_WORKBENCH_
SSH_CIDRS`·`AZURE_DEV_WORKBENCH_ADMIN_OBJECT_ID`).

```bash
gh workflow run deploy-dev-workbench.yml --ref main -f action=apply
```

⏳ **이 root는 2026-09-08 막 신설됐고 첫 apply가 아직 실패 상태다(디버깅 중).** dev에
자체 workbench를 둘지(이 문서 초안 시점의 결정) 여부 자체가 `live/dev/aks/main.tf`의
기존 주석("dev에는 hub의 workbench 같은 운영 VM이 없다")과 상충한다 - 그 주석은 이번
workbench 신설로 낡았다. 이 절은 실제 apply가 성공하고 SSH 접근이 검증된 뒤 gotcha를
채워 넣는다(hub workbench가 PR #7~#10 3라운드 버그 수정을 거친 것과 같은 과정을 거칠
가능성이 높다 - `hub-lifecycle.md`가 지금 형태를 갖추기까지의 경로 참고).

apply 후 접근을 확인한다(private key는 `~/.ssh/`에만 존재, `.pub`만 커밋):

```bash
ssh -i ~/.ssh/workbench_ed25519 azureuser@<dev workbench 공인 IP>
kubectl get nodes            # sudo 없이 동작해야 한다
```

### 6. GitOps 등록: hub ArgoCD에 원격 클러스터로 등록

⏳ **이 절은 아직 미확정이다.** hub의 `cluster-secret.yaml`(`aks-platform-gitops/clusters/
hub/aks-demo-hub-krc-main-01/cluster-secret.yaml`)은 `server: https://kubernetes.default.svc`
(self-managed ArgoCD가 **자기 자신이 도는 클러스터**를 가리키는 매직 URL)를 쓴다 - 이건
등록이 아니라 라벨링이 목적이다(ArgoCD가 내장 `in-cluster` 항목에 이미 닿아 있다). dev는
**원격** 클러스터라 이 패턴이 그대로 통하지 않는다 - 실제 API endpoint·인증 수단이
필요한데, 이 저장소엔 그 전례가 하나도 없다.

AWS 원본(`spoke-lifecycle.md`)은 `cross-account-trust-role`(IAM Role, hub의 IRSA
Principal을 trust) + EKS API endpoint + CA 인증서로 이 문제를 푼다. Azure에서 이에
대응하는 인증 수단(Entra Workload Identity federated credential로 hub의 ArgoCD pod
identity가 dev AKS의 Kubernetes RBAC에 접근하게 하는 방식이 유력한 후보이나 미검증 -
아니면 dev AKS가 발급하는 ServiceAccount 토큰을 hub의 repository Secret과 같은 방식으로
kubeconfig에 담는 더 단순한 경로일 수도 있다)은 이번 spoke 철거→재구축 실검증에서
실제로 시도하며 확정한다. 확정되면 이 절이 AWS 원본의 대응 표(등록 필드 목록)에
대응하는 내용으로 채워진다.

### 7. 완료 판정

`hub-lifecycle.md`와 같은 7항목을 이 dev 클러스터 기준으로 확인한다. 4번(root
Application이 커밋 SHA를 읽음)·5번(Application `Synced`/`Healthy`)은 **hub의 ArgoCD에서**
확인한다 - dev 자신에는 ArgoCD가 없다(self-managed 컨트롤 플레인은 hub에만 존재).

---

## 철거

### 8. 시작 전에: 공용 구독이면 특히 읽는다

`hub-lifecycle.md`와 동일한 원칙(태그로 특정, 이름으로 지우지 않는다)이 dev 구독에도
그대로 적용된다.

```bash
az resource list --query "length([])"
az aks list --query "length([])"
az resource list --tag Workload=demo --tag Environment=dev
```

### 9. 0단계: 삭제 보호 해제

`hub-lifecycle.md`와 같은 2단계 apply 패턴이다.

```hcl
# live/dev/networking/main.tf
module "vnet" { deletion_protection = false ... }
```

```bash
gh workflow run deploy-dev-network.yml --ref main -f action=apply
```

AKS는 `deletion_protection`이 이미 `false`라 이 단계가 필요 없다(`hub-lifecycle.md`와 동일 근거).
⛔ 재구축한 뒤에는 `true`로 복원한다.

### 10. 1단계: IaC 밖 자원 선처리 (컨트롤러 정지 대상이 hub다)

⚠️ **`hub-lifecycle.md`와 다르다.** dev는 자체 ArgoCD가 없으므로 "컨트롤러를 scale
0"할 대상이 dev 안에 없다. hub의 ApplicationSet이 이 dev 클러스터를 계속 fan-out 대상으로
보는 한, dev 안의 LB·PVC·NodePool을 지워도 hub가 되살린다(대상만 원격일 뿐 hub와
같은 메커니즘).

🔴 **`cluster-secret.yaml`을 한 번에 통째로 지우지 않는다.** AWS 원본 `spoke-lifecycle.md`가
이미 겪은 문제와 원리가 같다 - 이 Secret은 두 역할을 겸한다: ①ArgoCD가 이
클러스터에 접속할 자격증명, ②ApplicationSet cluster generator가 fan-out 대상으로 판단하는
라벨. 통째로 지우면 ArgoCD가 접속 방법 자체를 잃어 cascade delete가 불가능해지고, 실제
Deployment·NodePool·ClusterPolicy는 dev 클러스터에 orphan으로 남는다. 6절이 확정되면 이
절도 AWS 원본의 ①~⑥ 단계별 절차(라벨만 먼저 제거 → hub root-app 반영 확인 → dev에서
addon 파드 소멸 확인 → 이후에만 Secret 전체 삭제)를 이 저장소의 실제 필드명으로 채운다.

이후 `hub-lifecycle.md`와 같은 방식으로 workbench(5절에서 신설)에서 실행한다(①ArgoCD 컨트롤러
정지는 hub 쪽 - 여기 해당 없음 ②Gateway/Ingress/LoadBalancer Service ③PVC ④NAP
NodePool/AKSNodeClass).

### 11. 2단계 · 3단계: destroy(workbench → aks → networking)

`hub-lifecycle.md`와 같은 패턴, 워크플로 이름과 `confirm` 문자열만 다르다. dev에는 vwan root가
없으므로(4절 - hub가 소유) hub의 vwan destroy 순서 고민이 없다.

```bash
gh workflow run deploy-dev-workbench.yml --ref main \
  -f action=destroy -f confirm='destroy live/dev/workbench'

gh workflow run deploy-dev-aks.yml --ref main \
  -f action=destroy -f confirm='destroy live/dev/aks'

gh workflow run deploy-dev-network.yml --ref main \
  -f action=destroy -f confirm='destroy live/dev/networking'
```

### 12. 4단계: 잔존물 검증

`hub-lifecycle.md`와 같은 8개 항목을 dev 구독 기준으로 확인한다(NAT Gateway·VM/VMSS·Managed
Disk·Public IP·LB·AKS·NIC·Log Analytics).

```bash
az network nat gateway list --query "[?tags.Environment=='dev']"
az vmss list --query "[?tags.Environment=='dev']"
az disk list --query "[?diskState=='Unattached' && tags.Environment=='dev']"
az network public-ip list --query "[?ipConfiguration==null && tags.Environment=='dev']"
az resource list --tag Workload=demo --tag Environment=dev
```

### 13. dev 단독 teardown 시 hub vWAN 잔존 연결

**hub가 destroy된 경우**는 다르다: hub networking·vwan을 destroy하면 vWAN·vHub·연결이
전부 사라진다. dev를 먼저 재생성해도 hub vwan을 다시 세우기 전까진 아무 연결도 없다 -
통상 순서(hub networking → hub vwan → dev networking → **hub vwan 재적용**, 4절 참고)를
그대로 반복하면 된다.

dev만 단독으로 destroy하고 hub는 그대로 두는 경우: hub vwan의 `azurerm_virtual_hub_
connection.spoke["dev"]`는 **살아있는 데이터소스**(`azurerm_resources` 태그 조회)로 개수가
결정되는 `for_each` 기반이다(4절 참고). dev VNet이 destroy로 사라지면:

- Azure는 그 연결을 즉시 지우지 않는다. hub의 Terraform state는 dev VNet이 사라진 걸
  스스로 알아채지 못한다 - `for_each`가 참조하는 데이터소스가 그 VNet을 더 이상 반환하지
  않게 됐을 뿐이라, **다음 hub vwan plan/apply를 실제로 돌려야** 그 연결이 destroy
  대상으로 잡히고 정리된다. **코드 수정은 필요 없다.**
- hub를 재적용하지 않고 방치해도 즉시 에러는 안 난다. 다만 Azure 쪽에 대상 없는 연결
  객체가 남아있는 상태이므로, 다음 dev가 재배포되기 전에 정리하는 걸 권장한다.

이 메커니즘은 AWS 원본 `spoke-lifecycle.md`의 "spoke attachment 소멸 시 blackhole
라우트로 전환, 다음 hub apply가 정리"와 원리가 같다 - 다만 Azure는 라우트가 아니라
연결 리소스 자체가 대상이라는 차이가 있다.

### 14. 재배포 시 GitOps 재등록

dev AKS를 destroy 후 재생성하면 클러스터 이름이 같아도 API endpoint·CA 인증서는 **반드시
새로 발급**된다. 6절이 확정되면, 재배포 시 `cluster-secret.yaml`의 `server`·`caData`만
갱신하고 `addon-*` 라벨은 그대로 유지해야 한다(AWS 원본 `spoke-lifecycle.md`와 동일
함정 - 빠뜨리면 addon 구독이 조용히 빠진 채 재배포된다).

### 15. 되돌릴 수 없는 것 / 자주 막히는 지점

`hub-lifecycle.md`와 같은 항목이 dev에도 적용된다(state Storage Account 최후 삭제, Log
Analytics workspace, prevent_destroy 코드 정정 필요 등). dev 고유 항목:

| 증상 | 원인 | 대응 |
|------|------|------|
| hub vwan plan에 dev 스포크 연결이 안 보인다 | dev networking이 아직 없거나 태그가 안 맞음 | `az resource list --tag Workload=demo --tag Environment=dev --resource-type Microsoft.Network/virtualNetworks`로 실물·태그 직접 확인 |
| dev bootstrap.sh가 구독 불일치로 즉시 중단 | `az account show`가 hub를 가리킴 | `az account set --subscription <dev GUID>` 먼저 실행(3절) |
| dev workbench SSH 타임아웃 | hub workbench와 같은 서브넷 레벨 NSG 함정 가능성 | `hub-lifecycle.md`에는 없는 절 - hub 12차 세션의 "서브넷 레벨 NSG 누락" 패턴이 dev에도 재현되는지 첫 apply 후 확인 |
