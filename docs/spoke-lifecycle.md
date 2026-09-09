# spoke(dev) 구독 생애주기: 구축과 철거

**읽는 사람**: spoke(dev)의 인프라를 구축하거나 철거하는 사람.

> ⚠️ **hub가 먼저 구축되어 있어야 한다.** spoke의 vWAN 연결은 hub 쪽(`live/hub/vwan`)이
> 태그 기반으로 자동 발견해 소유한다 - `hub-lifecycle.md`부터 본다.
> **검증 상태**: hub-lifecycle.md와 같은 방식(먼저 쓰고 실제 배포·등록으로 검증)으로
> 작성했다. 전 절이 이 저장소의 실제 배포 이력(아래 각 절 근거)에 기반한다.
> **6절(GitOps 등록)은 2026-09-09 실제 dev 클러스터로 완주해 검증했다**
> (`aks-platform-gitops` 커밋 `a2f4707`) - hub→dev Application 5개가 Synced/Healthy로
> 수렴함을 실측 확인했다. 아직 실제 철거→재구축까지 거친 것은 아니라, 14절(재배포 시
> 재등록)의 절차 자체는 여전히 미검증이다.

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
피해간다), `system_node_pool.auto_scaling_enabled=false`. 모듈 ref는 최초 스캐폴딩
시점엔 hub와 같은 태그였으나, 6절의 GitOps 등록 과정에서 `private_cluster_public_
fqdn_enabled`가 필요해져 `aks-cluster-v0.9.0`으로 dev가 먼저 올라갔다(hub는 아직
`v0.7.0`) - "hub 선행·dev 승계"가 항상 성립하는 건 아니고, dev 쪽 필요가 먼저
생기면 dev가 앞서갈 수 있다는 사례다.

```bash
gh workflow run deploy-dev-aks.yml --ref main -f action=apply
```

> 🔴 **`cni_mode`·`pod_cidr`·`private_cluster_enabled`는 `network_profile` 블록 전체가
> ForceNew라 첫 apply가 사실상 최종 선택이다.** hub와 동일 값을 그대로 쓰므로 1절에서
> 이미 확정돼 있다.

같은 방식으로 `live/dev/workbench`를 초기화한다(`key = "dev/workbench.tfstate"`,
2026-09-08 신설). `live/hub/workbench`를 템플릿으로 그대로 복제한다 - 도구 핀(az·
kubectl·helm·argocd·krew)은 hub와 동일하지만, 모듈 ref는 hub와 **다르다**
(`aks-workbench-v0.7.0` - hub는 아직 `v0.5.0`). env=dev로 갈리는 축은 backend
key(`dev/workbench.tfstate`)·tfstate RG(`rg-demo-dev-krc-tfstate-01`)·Storage
Account 참조(`DEV_TF_STATE_ACCOUNT`)·CI 신원(`AZURE_DEV_CLIENT_ID`·
`AZURE_DEV_SUBSCRIPTION_ID`)·workbench 변수(`AZURE_DEV_WORKBENCH_SSH_CIDRS`·
`AZURE_DEV_WORKBENCH_ADMIN_OBJECT_ID`).

```bash
gh workflow run deploy-dev-workbench.yml --ref main -f action=apply
```

✅ **첫 apply는 실패했으나(2026-09-08) 근본 원인 2건을 규명·수정해 완주했다**(2026-09-09,
22차 세션). dev가 이 저장소에서 이 코드 경로(cloud-init의 kubelogin 변환 분기)를 처음
실행한 케이스였다: (1) `apt-daily-upgrade.timer`가 부팅 15초 만에 자체 `apt-get update`로
lists lock을 잡아 cloud-init의 azure-cli 설치용 `apt-get update`와 경합 - 타이머·서비스를
stop→kill→mask해 경쟁자 자체를 제거(`aks-workbench-v0.6.0`). (2) cloud-init이 root로
실행될 때 `$HOME`이 `/`로 잡혀(`/root` 아님) `kubelogin convert-kubeconfig`가 존재하지
않는 `/.kube/config`를 대상으로 삼고 조용히 성공(exit 0)해버리는 버그 - `--kubeconfig
/root/.kube/config` 명시로 해결(`aks-workbench-v0.7.0`). 두 버그 다 레이스 컨디션이라
hub workbench(`v0.5.0`)에서는 우연히 안 터졌다 - **hub workbench를 다음에 재배포할 때는
반드시 `v0.7.0`으로 올려야 한다**(잠재 버그 2건 그대로 남아있음, `live/hub/workbench/main.tf`
갱신 미착수). `live/dev/aks/main.tf`의 기존 주석("dev에는 hub의 workbench 같은 운영
VM이 없다")은 이 workbench 신설로 낡았다 - 아직 그 주석 자체를 정정하지 않았다.

apply 후 접근을 확인한다(private key는 `~/.ssh/`에만 존재, `.pub`만 커밋):

```bash
ssh -i ~/.ssh/workbench_ed25519 azureuser@<dev workbench 공인 IP>
kubectl get nodes            # sudo 없이 동작해야 한다
```

### 6. GitOps 등록: hub ArgoCD에 원격 클러스터로 등록

hub의 `cluster-secret.yaml`(`aks-platform-gitops/clusters/hub/aks-demo-hub-krc-main-01/
cluster-secret.yaml`)은 `server: https://kubernetes.default.svc`(self-managed ArgoCD가
**자기 자신이 도는 클러스터**를 가리키는 매직 URL)를 쓴다 - 이건 등록이 아니라 라벨링이
목적이다(ArgoCD가 내장 `in-cluster` 항목에 이미 닿아 있다). dev는 **원격** 클러스터라 이
패턴이 그대로 통하지 않는다 - 실제 API endpoint·인증 수단이 필요하다.

AWS 원본(`spoke-lifecycle.md`)은 `cross-account-trust-role`(IAM Role, hub의 IRSA
Principal을 trust) + EKS API endpoint + CA 인증서로 이 문제를 푼다. Azure는
`cross-account-trust-role`에 대응하는 "신뢰 전용" 리소스를 spoke 쪽에 따로 만들지
**않는다** - Azure RBAC 역할 할당은 tenant 전역 ARM 오퍼레이션이라(`entra-id-
authorization` 공식 문서: role assignment의 assignee는 어느 구독 소속이든 상관없다)
그런 게 애초에 필요 없다. 대신 **인증(신원 증명)**과 **인가(API 접근 권한)**를 두
루트로 나눈다 - 자세한 설계 경위·검토 라운드는 `.omc/plans/dev-gitops-registration.md`
(로컬 전용, git 밖) 참고, 아래는 실제 완주해 실측 검증된 결과만 요약한다:

**인증(1회성, spoke가 몇 개든 hub 쪽에 한 번만)**: `live/hub/vwan`에 hub 전용
User-assigned Identity(`id-demo-hub-krc-argocd-01`)와 Federated Identity Credential
2개(`argocd-application-controller`·`argocd-server` - 두 ArgoCD SA 모두, `server`도
`argocd app diff`·UI 경로에서 원격 클러스터 API를 호출하기 때문)를 만든다. issuer는
hub AKS의 OIDC issuer URL, `aks-platform-gitops`의 `bootstrap/argocd-values.yaml`에
이 SA들의 workload identity 라벨·애노테이션을 배선해야 실제로 토큰 파일이 파드에
주입된다(누락하면 인증 자체가 조용히 실패).

**인가(spoke마다 1개 role assignment)**: 같은 `live/hub/vwan`이 태그 기반
`azurerm_resources`로 spoke AKS 리소스를 자동 발견해(provider `azurerm.dev`,
`Microsoft.ContainerService/managedClusters`, `Workload` 태그만 필터) 위 UAMI에
`Azure Kubernetes Service RBAC Cluster Admin` role assignment를 리소스 ID 스코프로
부여한다(`skip_service_principal_aad_check = true` - principal이 dev 구독 소속이라
필요). **결과적으로 AWS 대비 실제 delta는 "2개 리소스(trust Role + access entry) →
1개 리소스(role assignment)"**다("0개"가 아니다 - assignment 자체는 대상 구독 ARM에
저장된다). 새 spoke를 추가할 때 이 루트를 다시 만질 필요는 없다 - 새 AKS가 같은
`Workload` 태그를 달고 있으면 `live/hub/vwan` 재적용만으로 role assignment가 자동
생긴다(2026-09-09 `spoke_connections`/`spoke_aks_ids` 그룹핑 키를 `r.tags["Environment"]`
로 통일해 이 자동화가 실제로 다중 스포크에서 동작함을 확인, PR #32).

`<project>-platform-gitops`에 `clusters/<env>/<cluster-name>/cluster-secret.yaml`을
추가한다(실물: `clusters/dev/aks-demo-dev-krc-main-01/cluster-secret.yaml`):

| 필드 | 값 | 확인 방법 |
|---|---|---|
| `metadata.labels.environment` | `<SPOKE_ENV>`(예: `dev`) | baseline ApplicationSet(`gateway.yaml`·`kyverno.yaml`)의 cluster generator가 이 키의 **존재만** 검사 |
| `metadata.labels.tier`·`region` | 분류용 | selector에 안 쓰임, 값 자체는 자유 |
| `addon-<name>: enabled` 라벨 | opt-in 카탈로그 구독 | 필요한 addon만(예: `addon-karpenter: enabled` - `live/<env>/aks`가 `enable_karpenter=true`인 경우) |
| `stringData.server` | AKS **public FQDN**(`https://<fqdn>:443`) | `az aks show -n <cluster> -g <rg> --query fqdn` - ⚠️ **`privateFqdn`이 아니다.** hub는 자신의 VNet 밖(공인 인터넷 경로)에서 이 이름을 조회하므로 `privateFqdn`(zone-scoped)은 도달 불가 |
| `stringData.project` | `platform` | `projects/platform.yaml`의 AppProject 이름과 반드시 일치(project-scoped cluster) |
| `stringData.config.execProviderConfig` | `argocd-k8s-auth azure` + `AAD_LOGIN_METHOD=workloadidentity` + 위 hub UAMI의 `client_id`·tenant `id` | ⚠️ `kubelogin`이 아니다 - ArgoCD 컨테이너 이미지엔 없다, ArgoCD 자신이 번들하는 `argocd-k8s-auth`가 AWS의 `awsAuthConfig.roleARN`에 대응하는 자리다 |
| `stringData.config.tlsClientConfig.caData` | 대상 AKS API 서버 CA(base64) | `az aks get-credentials`가 로컬에 쓴 kubeconfig의 `certificate-authority-data`를 그대로 옮긴다(정적 시크릿 아님 - CA 인증서는 공개 정보) |

⚠️ **AWS 원본과 달리 `projects/platform.yaml`의 AppProject `destinations`를 반드시
편집한다.** AWS는 region 단위 glob으로 spoke EKS API endpoint 전체를 미리 허용해뒀지만,
이 저장소는 그런 glob을 두지 않았다 - 클러스터마다 정확한 FQDN을 `destinations`에
추가해야 한다(빠뜨리면 AppProject 거부로 팬아웃된 Application이 전부 `InvalidSpecError`로
죽는다). 새 spoke를 추가할 때마다 이 파일도 같이 고쳐야 하는 게 이 저장소의 선택이다 -
region glob을 두지 않은 이유는 아직 별도로 문서화하지 않았다(open item).

**DNS 관련 별도 리소스가 필요 없다** - AKS의 private cluster는 기본적으로 클러스터
자신의 VNet에 링크된 private DNS zone에서만 FQDN이 풀린다(자칫 hub↔dev 사이에
`azurerm_private_dns_zone_virtual_network_link`나 Private DNS Zone Contributor
role assignment 같은 DNS 배선이 필요해 보이지만, **AWS EKS의 private-only 엔드포인트가
이미 일반 공개 DNS로 private IP를 직접 반환하는 것과 동일한 메커니즘**을 azurerm
provider의 `private_cluster_public_fqdn_enabled`(`ForceNew` 아님, in-place 적용
가능)로 얻을 수 있다 - 이 필드를 켜면 hub는 vWAN으로 이미 있는 IP 라우팅만으로
`stringData.server`에 접근 가능해진다(실측: 로컬 Mac의 일반 ISP DNS로 dev AKS FQDN을
조회해 private IP를 직접 반환함을 확인). `iac-module-library`의 `aks-cluster` 모듈은
`v0.9.0`부터 이 필드를 passthrough로 노출한다 - 새 spoke를 만들 때 `live/<env>/aks`에
`private_cluster_public_fqdn_enabled = true`를 반드시 설정한다(설정하지 않으면
`stringData.server`에 쓸 FQDN 자체가 없다).

root-app이 이 커밋을 pull하면(또는 `argocd.argoproj.io/refresh: hard` 애노테이션으로
강제 refresh하면 기본 폴링 주기를 기다리지 않고 즉시) baseline/opt-in ApplicationSet이
이 클러스터를 fan-out 대상에 자동 추가한다. **재배포 시 재등록**은 14절.

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
새로 발급**된다. 재배포 시 `cluster-secret.yaml`의 `server`·`caData`만 갱신하고
`addon-*` 라벨은 그대로 유지해야 한다(AWS 원본 `spoke-lifecycle.md`와 동일 함정 -
빠뜨리면 addon 구독이 조용히 빠진 채 재배포된다). ⚠️ 이 저장소는 아직 실제
철거→재구축까지 거친 적이 없다 - 이 절 자체는 6절과 달리 미검증이다.

### 15. 되돌릴 수 없는 것 / 자주 막히는 지점

`hub-lifecycle.md`와 같은 항목이 dev에도 적용된다(state Storage Account 최후 삭제, Log
Analytics workspace, prevent_destroy 코드 정정 필요 등). dev 고유 항목:

| 증상 | 원인 | 대응 |
|------|------|------|
| hub vwan plan에 dev 스포크 연결이 안 보인다 | dev networking이 아직 없거나 태그가 안 맞음 | `az resource list --tag Workload=demo --tag Environment=dev --resource-type Microsoft.Network/virtualNetworks`로 실물·태그 직접 확인 |
| dev bootstrap.sh가 구독 불일치로 즉시 중단 | `az account show`가 hub를 가리킴 | `az account set --subscription <dev GUID>` 먼저 실행(3절) |
| dev workbench SSH 타임아웃 | hub workbench와 같은 서브넷 레벨 NSG 함정 가능성 | `hub-lifecycle.md`에는 없는 절 - hub 12차 세션의 "서브넷 레벨 NSG 누락" 패턴이 dev에도 재현되는지 첫 apply 후 확인 |
