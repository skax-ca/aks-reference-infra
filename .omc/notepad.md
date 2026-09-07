# Notepad
<!-- Auto-managed by OMC. Manual edits preserved in MANUAL section. -->

## Priority Context
<!-- ALWAYS loaded. Keep under 500 chars. Critical discoveries only. -->
2026-09-07(18차) - AGFC를 AKS App Routing(Gateway API/Istio)으로 전면 교체: aks-reference-infra(PR#16-18 머지)·aks-platform-gitops(main)·iac-module-library(aks-cluster-v0.7.0, web_app_routing 변수 신설) 3개 repo 걸침. Terraform drift(azurerm vs azapi) 실측 해소, apply 성공. 🔴 미해결: ARM은 Succeeded인데 istiod Deployment가 클러스터에 전혀 안 뜸(GatewayClass도 없음) — 재조정·프리뷰플래그등록·disable재enable 전부 시도, 원인 미상(private cluster 의심). PR #15(OMC decouple) 아직 미머지. 이월: ArgoCD 초기비번 교체, dev NAP.

## Working Memory
<!-- Session notes. Auto-pruned after 7 days. -->
### 2026-09-07(18차 세션) - AGFC → AKS App Routing(Gateway API/Istio) 전면 교체, 3개 repo 동시 작업

**출발점**: 17차가 미룬 두 갈래(브랜치 push/PR 여부, hub 철거→재구축 검증 범위) 중
1번(PR #15 push+PR)만 처리하고, 2번(철거→재구축)은 범위를 정하려던 참에 사용자가
"Gateway API를 eks-reference-infra 최신 이력에 맞게 도입해달라"는 별개 요청으로
전환 — 이 세션 전체가 그 요청으로 흘러갔다(2번 항목은 이번에도 착수 못 함).

**1. AGFC(Application Gateway for Containers) 폐기 결정**: Gateway API 도입 조사 중,
AGFC는 frontend가 공인 FQDN만 지원하고 private/internal 옵션이 없다는 걸 Microsoft
공식 문서로 확정(이 저장소의 "hub는 전부 private" 원칙과 정면 충돌) — 대안 3개
비교(Cilium Gateway API 관리형 미지원으로 탈락 · Envoy Gateway 자체설치 · AKS App
Routing 관리형) 끝에 "AKS는 관리형 서비스를 적극 지원·활용한다"는 사용자 판단으로
App Routing 채택.

**2. azurerm이 아직 안 만든 필드 — azapi로 메움, 그리고 그게 만든 새 드리프트**:
App Routing의 Gateway API/Istio 필드(`ingressProfile.gatewayAPI`·
`webAppRouting.gatewayAPIImplementations`)를 azurerm 프로바이더가 아직 노출 안
함(hashicorp/terraform-provider-azurerm#22392) — `azapi_update_resource`로 얹었다
(Microsoft 공식 가이드가 명시한 azurerm+azapi 공존 패턴). 그런데 azurerm 자신의
`aks-cluster` 모듈이 `web_app_routing` 블록을 전혀 모르니, 매 apply마다 그 블록을
지우려는 새 drift가 생겼다(실측: 첫 apply 후 수렴 검증이 "No changes"가 아니었음).
**근본 해결**: `iac-module-library`에 `web_app_routing` passthrough 변수를 신설
(aks-cluster-v0.7.0, PR #47 — 설계 우선 규칙에 따라 변수 자체 설명에 근거를 남기고
`docs/decisions.md` 별도 ADR은 스킵, enable_keda와 같은 선례). 모듈 버전을 올리고
`web_app_routing = { default_nginx_controller = "None" }`을 명시하자 azurerm 쪽
diff가 완전히 사라지고 azapi는 자기 몫(gatewayAPI·gatewayAPIImplementations)만
남았다 — 재-plan이 진짜 "No changes"로 수렴함을 실측 확인.

**3. GitOps 쪽에서 자기 자신을 두 번 저격**: `aks-platform-gitops`에서
`+argocd:skip-file-rendering` 마커를 평문 Directory 소스 파일에 붙였다가 그
Application 자신이 렌더링을 못 하는 사고, 그 사고를 문서화하던 주석에 마커
문자열을 그대로 적어 `addons/baseline/gateway.yaml` 자신이 root-app 스캔에서
빠져 ApplicationSet 전체가 pruned되는 사고 — 둘 다 `root-app.yaml` 자신이 이미
경고해 둔 "마커를 설명하는 주석도 마커다" 함정을 직접 재현한 것. 둘 다 즉시
재현·수정(helm 차트로 감싸기 / 문자열을 풀어쓰기).

**4. 실제 apply까지 마쳤으나 마지막 한 조각이 안 풀림**: AGFC 잔존물(identity·
federated credential·role assignment 2개·RP 등록 2개)은 전부 정리 완료, CI
apply도 성공("Apply complete"), drift도 최종적으로 "No changes"까지 수렴했다.
**그런데 실제 클러스터 안에서 istiod Deployment가 단 한 번도 안 뜬다** —
`aks-istio-system` 네임스페이스에 PDB·HPA 껍데기만 생기고 실제 파드가 없다.
ARM Activity Log는 매번 "Succeeded"만 찍는 침묵 실패. 시도한 것: `az aks update`
재조정 트리거, `ManagedGatewayAPIPreview`·`AppRoutingIstioGatewayAPIPreview`
프리뷰 플래그 구독 등록(둘 다 원래 `NotRegistered`였다 — GA 이후엔 필요 없다는
공식 문서와 배치되지만 이 구독엔 아직 반영 안 됐을 가능성 의심했음), 공식 GA
CLI(`az aks approuting gateway istio enable`), disable→재enable 사이클까지 —
전부 ARM 레벨에서는 성공하지만 K8s 쪽 reconciliation이 안 움직인다. Kubernetes
버전(1.35.7)·CRD bundle(v1.4.1/standard, 정확히 일치)은 확인 결과 문제 없음 —
private cluster 조합이 이 신규 GA 기능(2026-04 GA)의 검증 범위를 벗어났을
가능성을 의심하나 확정 못 함. **다음 세션 최우선**: 이 문제 계속 조사 또는 Azure
지원팀 문의.

**부수 작업**: `argocd-tunnel-connect` 기본 포트를 8080→18080으로 변경(로컬에서
`eks-reference-infra`와 포트 충돌, main 직접 커밋). ArgoCD 초기 admin 비밀번호를
사용자에게 조회해 전달함(교체는 아직 안 함 — 이월 유지).

**커밋/PR**: aks-reference-infra #16·#17·#18(전부 머지) + 316af4b(포트, main
직접). aks-platform-gitops 3커밋(main 직접, 이 repo는 애초에 PR 안 씀).
iac-module-library #47(머지) + `aks-cluster-v0.7.0` 태그. **PR #15(OMC decouple,
aks-reference-infra)는 여전히 미머지** — 17차부터 이월.

**세션 중 실측 교훈 하나**: `.trivyignore.yaml`의 `paths`는 저장소 루트 기준
상대경로라, 모듈 서브디렉토리만 콕 집어 `trivy config`를 돌리면 이미 예외
처리된 항목도 다시 걸린다(경로 불일치) — 반드시 CI와 동일하게 루트에서 스캔할 것.

### 2026-09-07(14차 세션) - AWS 대비 addon 공백 전부 해소(ALBC 버그 수정·Karpenter/KEDA/Kyverno)

13차가 남긴 두 미결(초기 admin 비번 확인·alb-controller/loadbalancer sync 실패)을
들고 시작했으나, 실제로는 훨씬 넓은 범위로 확장됐다 — "AWS 대비 빠진 addon이
뭔지 확인해달라"는 요청이 Karpenter→NAP·KEDA·Kyverno 세 addon의 실제 구현으로
이어졌다. 초기 admin 비번 확인은 여전히 미완(사용자 대기)이다.

**1. argocd-tunnel-connect/-disconnect 스킬 신설**: eks-reference-infra의 동명
스킬을 대조 포팅 — SSM 대신 SSH 기반(이 프로젝트의 "SSH가 일상 경로" 결정,
12차 세션). 실측으로 SSH 특유의 버그 발견: `pkill -f "kubectl port-forward..."`가
그 pkill을 실행 중인 셸 자신의 커맨드라인도 매칭해 자기 자신을 죽이는 self-kill
버그(AWS SSM은 명령을 스크립트 파일로 실행해 이 문제가 없음) — `$$` 제외로 해결.
상태 파일 위치는 사용자 지적으로 `.omc/state/`(OMC 워크트리 생명주기에 묶임) 대신
`.claude/skills/argocd-tunnel-connect/.state/`로 결정 — **사용자가 이 세션에서
"`.omc`는 향후 모든 참조를 끊어낼 계획"이라고 명시**(어시스턴트 자체 메모리에도
project_omc_phaseout.md로 기록됨, 새 상태/도구는 `.omc/` 밖에 둘 것).

**2. alb-controller sync 실패 근본 원인 규명·수정**: `.status.resources`에
Namespace가 결측된 걸 발견 → 차트 소스(`templates/common.yaml`)의
`{{- if not (eq .Release.Namespace .Values.albController.namespace) }}` 조건이
원인 — ArgoCD가 destination.namespace를 Release.Namespace로 그대로 넘기는데 그
값이 albController.namespace와 같아 조건이 거짓이 됨. Microsoft 공식 Helm
퀵스타트도 이 둘을 다르게 두는 게 전제였음을 확인. ArgoCD 공식 문서의
`CreateNamespace=true`(차트 렌더 여부 무관하게 destination.namespace를 직접
생성)로 해결. `aks-platform-gitops` 커밋 3615692. platform.yaml의 잘못된
whitelist 주석("차트가 Namespace를 직접 렌더한다")도 정정.

**3. Karpenter→NAP + KEDA — addon parity 리서치가 뒤집은 것**: 처음에 "KEDA도
GitOps 포팅 대상"이라고 답했다가 정정 — 공식 문서(aks/keda-about) 확인 결과
KEDA도 cluster-autoscaler처럼 **완전 관리형 add-on**(`workload_autoscaler_profile.
keda_enabled`)이었다. Karpenter는 절반만 관리형 — NAP 컨트롤러는 Azure가
관리하지만(`node_provisioning_profile.mode=Auto`) NodePool/AKSNodeClass CR은
공식 문서가 명시("you create and manage")한 대로 여전히 사람 몫. 최종 정리:
ALBC(GitOps 전량)·Karpenter(컨트롤러 관리형+CR GitOps)·cluster-autoscaler·
KEDA(둘 다 완전 관리형)·Kyverno(GitOps 전량, 관리형 대응 없음).

**실행(hub 클러스터, 전부 실측 검증 완료)**:
- `enable_karpenter=true`(PR #11) — `node_provisioning_profile.mode`는 azurerm
  공식 문서 확인 결과 ForceNew 아님(in-place). `defaultNodePools`가 이미
  `"None"`으로 하드코딩돼 있어(모듈이 애초에 그렇게 설계) Azure 자체 default
  NodePool과의 충돌 우려가 기우였음.
- `aks-platform-gitops`에 `addons/catalog/karpenter.yaml`(NodePool
  `general-purpose`+AKSNodeClass, cilium startupTaint 포함 — hub가
  network_data_plane=cilium이라 업스트림 공식 예제의 cilium 전용 설정이 그대로
  필요) — opt-in(`addon-karpenter: enabled` 라벨, AWS의 baseline과 다름 — dev는
  아직 NAP 안 켜서).
- `enable_keda=true` — `iac-module-library`에 `enable_keda` 변수 자체가
  없어서(facade가 그 인자를 안 넘기던 상태) 모듈에 신설 후 v0.6.0 태그, 이후
  live/hub/aks에 적용(PR #12). `az aks show`로 `workloadAutoScalerProfile.keda.
  enabled=true` 확인.

**4. workbench 부트스트랩 비교(사용자 요청) → 버그 2건 발견·수정**:
eks-reference-infra의 user-data.sh.tftpl과 대조해 aks-workbench의
cloud-init.sh.tftpl에 `/etc/profile.d` 로그인 프로파일 블록 자체가 없어 k
alias·kubectl completion·KREW_ROOT PATH가 전혀 안 잡혀 있던 걸 발견 →
모듈에 그 블록 신설(v0.4.0) → live/hub/workbench 적용(PR #13, VM 재생성) →
실측 중 krew install이 "unknown flag: --krew-root"로 실패하는 **별개의
잠재 버그**(v0.3.0부터 있었으나 이 root가 krew_version을 처음 넘긴 오늘에야
발현) 발견 → 공식 krew 설치 문서 확인 후 플래그 제거(v0.5.0) → live/hub/workbench
재적용(PR #14, VM 재재생성) → SSH 재접속해 k alias·krew 플러그인 6종·nv alias
전부 정상 동작 실측 확인. VM 재생성마다 known_hosts 갱신 필요(`ssh-keygen -R`)를
반복 실측.

**5. Kyverno 포팅**: AWS의 3-ApplicationSet 구조(컨트롤러·PSS 정책·커스텀 정책)를
그대로 포팅하되 3가지를 다르게 감 — (1) 차트 3.8.2로 고정(최신 3.9.0의
kyverno-policies가 policies.kyverno.io/v1beta1 ValidatingPolicy 신규 포맷으로
렌더함을 helm template 실측으로 발견, AWS와 같은 ClusterPolicy 포맷 유지가 이
시점엔 안전) (2) workload-class taint tolerations 오버라이드 없음(hub 시스템
노드풀에 taint 없음을 `az aks show`로 실측) (3) 커스텀 정책
(`require-nodepool-resources`)은 순수 Pod spec 검증이라 그대로 포팅. egress
canary(kyverno.github.io·reg.kyverno.io·ghcr.io 전부 도달 확인), alb-controller
컨테이너 전체가 이미 resources 선언돼 있어 Enforce와 충돌 없음도 사전 확인.
배포 후 실제로 resources 없는 파드 생성 시도 → 차단 확인, 있는 파드 → 통과 확인
(첫 테스트는 kubectl 컨텍스트가 argocd 네임스페이스로 고정돼 있어 정책 제외 대상에
잘못 생성한 오탐이었음 — 재시도로 정정).

**최종 상태**: hub 클러스터의 ArgoCD Application 8개 전부 Synced/Healthy
(argocd·root-app·alb-controller·alb-loadbalancer·karpenter-nodepool·kyverno·
kyverno-policies·kyverno-custom-policies).

**PR/태그**: aks-reference-infra #11·#12·#13·#14(전부 머지). iac-module-library
`aks-cluster-v0.6.0`(enable_keda 신설)·`aks-workbench-v0.4.0`(로그인 프로파일)·
`aks-workbench-v0.5.0`(krew 버그 수정). aks-platform-gitops 커밋 3615692(alb
Namespace fix)·8794abd(karpenter-nodepool)·cff4540(kyverno).

**다음 세션**: (1) 13차부터 이월된 미결 — ArgoCD 초기 admin 비번 교체 확인 후
`argocd-initial-admin-secret` 삭제 (2) dev 클러스터에도 Karpenter/NAP 적용할지
결정 필요(현재 hub만 옵트인) (3) `.omc` 참조를 프로젝트 전체에서 끊어내는 마이그
레이션(사용자가 이번 세션에 방향만 선언, 구체 계획은 아직 없음) — 언제 착수할지는
사용자 결정 대기.

### 2026-09-04(13차 세션) - aks-platform-gitops argocd-seed.sh 완전 실행, GitOps 계층 실제 가동

12차 세션이 남긴 workbench 완료 조건 해소 후, 남은 GitOps seed 절차를 순서대로 실행했다.

**세션 도중 삽입된 별개 요청 처리**: 진행 중간 사용자가 iac-module-library PR #45(3차
code-review stall 의심) 상태 확인을 요청 - notepad에 이미 "완료"로 기록된 것과 겹쳐
`ListAgents`·`gh pr view`로 실측 재확인한 결과 peer 세션(`iac-module-library-89`)이
이미 전부 처리한 뒤였다(PR #45 머지, v0.3.0 태그, aks-reference-infra PR #9·#10 머지,
sudo 없는 kubectl 재검증까지). 노트패드가 "완료"라고 적어놨어도 실행 전 `gh` API로
직접 재확인한 게 중복 작업(재머지·재태그)을 막았다.

**1. GitHub App 설치 범위 확장**: `gh` CLI 토큰(OAuth App 토큰, `gho_` 접두사)으로
`PUT /user/installations/{id}/repositories/{id}` API를 시도했으나 org admin 권한이
있어도 403("permission to modify this app")으로 거부됨 - GitHub 공식 문서가 요구하는
"classic PAT"가 아니라서로 추정. 결국 사용자가 웹 UI(`github.com/organizations/skax-ca/
settings/installations`)에서 직접 추가. 이후 workbench에서의 App 인증 clone 성공으로
간접 검증됨.

**2. private key 취급 원칙 재확인**: AWS 자매 프로젝트(`iac-module-library`
notepad-manual.md의 D-WORKBENCH-REPO 기록)가 확립한 "private key는 클러스터에 닿는
위치에서 대화형으로만, 원격 명령 파라미터에 평문 노출 금지" 원칙을 그대로 적용 - key를
`scp`로 workbench에 전달 → JWT 서명(openssl, RS256)으로 설치 토큰 발급 → 그 토큰으로
clone → remote URL에서 토큰 제거 → key `shred -u`로 파기, 이 흐름을 반복 사용(clone
1회, seed 2단계 1회).

**3. seed 5단계 순서 설계를 그대로 따름**: `argocd-app.yaml` 자체 주석이 요구한 대로
automated 없는 임시본을 먼저 apply → `argocd app diff --core`로 diff 확인 →
CRD 3종만 수천 줄짜리 "전체 추가"로 보였으나 `helm template`로 직접 raw 구조 비교한
결과 실질 내용은 동일함을 확인(--core 모드의 cluster-scoped 리소스 live-state 조회
한계로 추정, 실제 drift 아님) → 나머지 37개 리소스는 tracking-id 한 줄 차이뿐임을
확인 → root-app apply(5단계, 자기 흡수) 진행.

**4. 실행 중 발견한 실제 버그**: `platform` AppProject의 `clusterResourceWhitelist`에
`CustomResourceDefinition`이 없어 ArgoCD 자기관리 sync가 `InvalidSpecError`로 무한
재시도됐다(사전 diff 검증에선 안 드러난 종류 - AppProject 권한은 diff가 아니라 실제
sync 시점에만 걸린다). `aks-platform-gitops` 커밋 `10d3ae7`로 수정・push, root-app
강제 sync로 즉시 반영 확인 후 `argocd` 앱도 Synced Healthy로 수렴(revision은 multi-source
앱이라 `.status.sync.revision`이 아니라 `.status.sync.revisions`(배열)에 있었음 - 실측
전엔 빈 값이라 "아직 sync 안 됨"으로 오판할 뻔함).

**5. 부수 실측 2건**: (1) 비대화형 SSH 원격 명령에서 `disown`은 job control 부재로
실패한다(exit 255, 무출력) - 서브셸 백그라운드(`(cmd &)`)로 대체해 해결. (2) argocd
CLI `--core` 모드는 kubectl 컨텍스트의 기본 namespace가 비어있으면 `argocd-cm`을
엉뚱한 namespace에서 찾아 `configmap not found`로 실패 - `kubectl config set-context
--current --namespace=argocd`로 해결.

**6. 웹 콘솔 접속 구성**: private 클러스터라 2단 SSH 터널(workbench 안 `kubectl
port-forward` + 로컬 Mac→workbench SSH `-L`)로 `https://localhost:8080` 접속 가능하게
구성, 초기 admin 비밀번호 확인함. **완료 조건 미이행**: 사용자가 로그인·비밀번호 교체
확인 전이라 `argocd-initial-admin-secret` 삭제는 아직 안 함 - 다음 세션(또는 이 세션
후속)에서 확인 후 처리할 것.

**미해결로 남긴 별개 이슈**: `alb-controller`·`alb-loadbalancer`(AGFC addon) 두
Application이 `namespaces "azure-alb-system" not found`로 5회 이상 재시도 실패 중 -
automated(prune+selfHeal)는 켜져 있으나 namespace 생성 순서 문제로 추정(차트의 리소스
순서 또는 sync-wave 미설정), 오늘 argocd-seed 작업과는 별개 범위라 조사만 하고
넘어감. 다음 세션 후보.

### 2026-09-04(12차 세션, 11차 gitops 세션과 동시 진행) - live/hub/workbench 완전 배포·검증 완료

PR #7로 초기 배포(aks-workbench-v0.1.0) 후 실제 SSH·kubectl 접속을 검증하며 버그
3건을 순차 발견·수정했다.

**버그 1 — 서브넷 레벨 NSG 누락(PR #8)**: `aks-workbench` 모듈의 NIC 레벨 NSG(AllowSsh)만
확인했는데, `live/hub/networking`이 `vm` 서브넷에 이미 만들어 둔 서브넷 레벨 NSG는
`vnet` 모듈 설계상("룰은 이 모듈이 만들지 않는다") 커스텀 규칙이 0개였다 — 인터넷發
인바운드가 플랫폼 기본 DenyAllInBound(65500)에 먼저 막혀 SSH가 전부 타임아웃.
`data.azurerm_network_security_group`으로 그 서브넷 NSG를 조회해 별도 규칙을 얹어
해결(우선순위 100-199 예약).

**버그 2 — az CLI 설치 실패(iac-module-library PR #44, aks-workbench-v0.2.0)**: cloud-init
로그 실측 결과 `apt-get install azure-cli`가 dpkg lock 경합으로 실패(부팅 초반
unattended-upgrades 등과 충돌), 뒤이은 `az login`·`az aks get-credentials`까지 연쇄
실패(스크립트에 `set -e` 없어 조용히 넘어감). apt-get의 `-o DPkg::Lock::Timeout=600`
옵션으로 해결(최초 180초는 code-review로 부족함이 드러나 상향).

**버그 3 — kubeconfig 위치(iac-module-library PR #45, aks-workbench-v0.3.0)**: `az aks
get-credentials`가 root(cloud-init)로 실행돼 kubeconfig가 `/root/.kube/config`에만
생기고 로그인 계정(`admin_username`)엔 없어 `sudo` 없이 kubectl 불가. 이 수정 과정에서
code-review 3라운드가 실제 보안 회귀 2건을 잡아냈다 — (1) 1차 시도(world-readable 전역
파일 + `/etc/profile.d`)는 `Virtual Machine User Login`(비-sudo)만 받은 사람도 AKS
접근권을 얻게 함 (2) 2차 시도(AWS workbench 모듈의 `/etc/skel` 패턴 이식)도 같은 문제
재발 — AWS는 SSM 접근이 IAM 하나로만 통제돼 skel이 안전하지만 Azure는 이 모듈 자신이
Administrator/User Login 2단계를 문서화해 뒀다는 걸 놓쳤다. 최종적으로 자동 배포
대상을 `admin_username` 하나로 좁히고(Entra SSH 계정엔 아무것도 자동으로 안 줌),
`admin_username` 셸 injection 방지 validation도 추가. `kubelogin` 바이너리가 애초에
설치 안 되던 기존 버그도 같이 수정(`kubelogin_version` 변수 신설).

**PR/태그 전체**: aks-reference-infra #7·#8·#9·#10, iac-module-library #44(→
`aks-workbench-v0.2.0`)·#45(→ `aks-workbench-v0.3.0`). 전부 `/code-review` 통과 후
머지(PR #45는 3라운드, 3차는 병렬 리뷰 에이전트가 5분+ 정지해 `TaskStop`으로 중단 후
직접 라인 단위 재검토로 대체).

**최종 검증**: `ssh -i ~/.ssh/workbench_ed25519 azureuser@52.141.7.48`로 접속,
`kubectl get nodes`(sudo 없이) → hub AKS 노드 2대 Ready, `az`(2.88.0)·`helm`(v4.2.4)·
`argocd`(v3.5.2) 전부 정상. private key는 `~/.ssh/`에만 존재, `.pub`만 repo 커밋
(`.gitignore`에 `workbench_ed25519` 명시 제외).

**다음 세션**: aks-platform-gitops의 `argocd-seed.sh` 실행(workbench 완료로 그 세션이
대기하던 조건 해소) — `--dry-run` → `--to` → `argocd app diff` 순으로 확인.

### 2026-09-04(11차 세션) - egress canary 검증 + aks-platform-gitops self-managed ArgoCD 매니페스트 작성

**egress canary(계획서 5절 검증 5번)**: `az aks command invoke`로 private hub 클러스터에
임시 파드(`mcr.microsoft.com/azure-cli`)를 띄워 `curl https://mcr.microsoft.com/v2/` 실행 -
`http_code=200`, `time_total=0.1s`로 NAT Gateway 경유 egress 확인, 파드는 `--rm`으로 자동
정리. `.omc/plans/aks-platform-gitops-scaffold.md` 5절에 반영(로컬 전용, git 밖).

**Follow-up 1(ArgoCD 자기관리) 착수 전 사용자 확인 2건**: (1) GitHub App - 기존
`skax-ca-gitops-reader`(eks-platform-gitops용, 2026-08-07 발급) 재사용 확정, 신규 발급
안 함 - 설치 범위에 이 repo 추가는 남은 작업. (2) 이번 세션 범위 - workbench(다른 세션이
`live/hub/workbench`에서 진행 중, 미완료)가 없어 seed **실행**은 불가 → 매니페스트 준비까지만.

**작성(aks-platform-gitops repo, 커밋 `acc9608`, push 완료)**: AWS 원본 `eks-platform-gitops`의
`bootstrap/argocd-app.yaml`·`argocd-values.yaml`·`root-app.yaml`·`argocd-seed.sh`(module-library
커밋 `0d342a0` vendoring)를 1:1 대조해 포팅, `projects/platform.yaml`·
`clusters/hub/aks-demo-hub-krc-main-01/cluster-secret.yaml`·`addons/baseline/alb-controller.yaml`
(ApplicationSet 2종: 컨트롤러+CR)·`addons/alb-controller/loadbalancer/`(로컬 helm 차트) 신규
작성. 전체 YAML 구문 검증 + `helm template` 렌더 검증 통과.

**계획 대비 실측으로 바뀐 것 2건**: (1) `albSubnetId`를 cluster Secret 라벨에 넣으려던 계획
(1-1절 "실측 필요"로 유보된 항목)이 실제로 깨짐 - 실측 서브넷 리소스 ID가 191자(한도 63자)
+ `/` 포함(라벨 값 비허용 문자)이라 K8s 라벨 값 제약 위반, `clusters/hub/*/values.yaml` +
`alb-loadbalancer` ApplicationSet의 matrix generator(cluster+git files)로 전환 - 단 이
generator는 이름 기준 join이 아니라 Cartesian product라 **클러스터 2개 이상이 되면 재검증
필수**(파일에 명시). (2) AWS 원본의 `workload-class=system` taint 우회 tolerations를
`argocd-values.yaml`에 이식하지 않음 - `az aks show`로 hub 노드풀(`npsystem`)에 taint가
없음을 실측 확인 후 판단(맹목적 1:1 포팅이 아니라 검증 후 차이를 명시).

**세션 중 발견 - 공유 체크아웃 위험 재현**: 세션 종료 시점에 `aks-reference-infra` 로컬
브랜치가 `main`이 아니라 `fix/live-hub-workbench-subnet-nsg`로 바뀌어 있었다(10차 세션이
이미 경고한 위험의 실제 재발). 최근 커밋(`bce7acd`)이 4분 전이라 옆 세션이 활성 중으로
판단 - 그 브랜치를 건드리지 않고, `git worktree add`로 임시 별도 경로에 `main`을 체크아웃해
이 notepad 갱신만 안전하게 커밋·push함(사용자 확인 후 결정). aks-platform-gitops는 이
로컬 디렉토리와 별개라 이 위험과 무관, `main` 직접 커밋(사용자 결정, 이 repo는 아직 CI
게이트 없음).

**다음 세션**: (1) `live/hub/workbench` 완료 대기 (2) GitHub App(`skax-ca-gitops-reader`)
설치 범위에 `aks-platform-gitops` repo 추가 (3) workbench 준비 후 `argocd-seed.sh
--dry-run` → `--to 4` 실행 → `argocd app diff argocd --core`로 diff 실측 확인 후에만
`bootstrap/argocd-app.yaml`의 `automated` 블록 최종 확정(AWS 원본과 동일 순서).
### 2026-09-04(10차 세션) - aks-platform-gitops 착수: GitOps 엔진·Ingress addon 설계 확정 + hub 실배포

**설계 리서치(6+라운드, 전부 공식문서 기반)**: GitOps 엔진은 self-managed ArgoCD 확정
(관리형 확장은 Public Preview, Flux는 AppProject 가드레일 부재). Ingress(ALBC 대응)는
AGIC→AGFC→App Routing(Istio)→azurerm 미지원 발견→self-managed Helm 재검토(AGIC·AGFC
둘 다 helm 경로 있음, Istio는 Cilium ConfigMap 충돌 위험)→최종 AGFC self-managed Helm
확정, WAF 가이드·Architecture Center 교차 확인. 배포 전략은 Managed(BYO 아님) - ALBC가
Terraform으로 ALB를 안 만들고 컨트롤러가 동적 생성하는 선례 + 계층 분리 원칙(Terraform이
GitOps가 나중에 선언할 Gateway/HTTPRoute 내용을 몰라도 되게). 설계 전문은
`.omc/plans/aks-platform-gitops-addon-selection.md`·`aks-platform-gitops-scaffold.md`
(둘 다 로컬 전용, `.gitignore`가 `/.omc/plans/`를 화이트리스트하지 않음 - notepad.md·
project-memory.json만 git 추적 대상, 다음 세션도 같은 머신이 아니면 이 두 파일 못 봄).

**RALPLAN**: 1차 Architect+Critic 검토에서 Critic REJECT - 위임 서브넷·역할 3종 중 2종
누락(Reader만 상정), `ApplicationLoadBalancer` CR 소유 파일 부재, IAM 배치가 옛 방어선
위반 소지로 열린 질문 방치. v2로 전면 개정해 반영, 2차 재검토는 생략(canary 실측으로
대체 - `helm template` dry-run + 공식 API 스펙 문서로 clusterResourceWhitelist·CR
스키마(`spec.associations`는 `[]string`, namespace-scoped) 확정).

**실행**: `skax-ca/aks-platform-gitops` repo 신설(디렉토리 뼈대+README). 세션 도중
CLAUDE.md에 커밋되지 않은 자격증명 모델 전환(구독 Owner)을 발견 → 확인 결과 이미
hub·dev 재부트스트랩까지 완료된 상태(다른 세션이 병행 작업 중이었음, 커밋 `05f86f4`) -
bootstrap 2-phase 없이 IAM 리소스를 바로 Terraform으로. 그 사이 또 다른 동시 세션이
PR #4(AKS 컨트롤 플레인 identity Terraform 이관)를 머지 - 그 패턴(`skip_service_
principal_aad_check`)을 그대로 재사용.

**배포**: `live/hub/networking`에 `alb` 위임 서브넷(10.60.4.0/24,
`Microsoft.ServiceNetworking/trafficControllers`, PR #5) → 머지·apply·수렴 확인.
`live/hub/aks`에 ALB controller identity·federated credential·role assignment
2종(Configuration Manager+Network Contributor, Reader는 공식 quickstart 문서 재확인
결과 불필요로 정정)·provider 등록 2종(`Microsoft.ServiceNetworking`·
`Microsoft.NetworkFunction`, 신규 구독-Owner 모델에서 처음 성공 확인)·
`workload_identity_enabled=true`(in-place, ForceNew 아님을 provider 소스로 사전
확인) 추가(PR #6) → 머지·apply·수렴 확인. 둘 다 파괴 없음.

**사고 처리**: 두 커밋이 실수로 `main`에 직접 들어감(CLAUDE.md 5절 위반) - push 전이라
브랜치로 옮겨 안전하게 정정. `azurerm_federated_identity_credential` 스키마를
`parent_id`/`resource_group_name`으로 잘못 추정(v5는 `user_assigned_identity_id`
하나) - validate 에러로 즉시 발견·수정. 세션 종료 시점에 로컬 체크아웃이 옆 세션의
`feat/live-hub-workbench` 브랜치로 바뀌어 있음을 발견 - 이 환경이 세션 간 워크트리를
분리하지 않고 같은 로컬 디렉토리를 공유한다는 사실을 이때 처음 확인(사용자 확인 후
main으로 안전 전환).

**다음 세션**: 5절 검증 잔여 - mcr.microsoft.com egress canary, Follow-up 1(ArgoCD
자기관리 매니페스트+GitHub App repository Secret), 그 다음 실제 GitOps 매니페스트
작성(root-app.yaml·platform.yaml·cluster-secret.yaml·alb-controller.yaml,
`.omc/plans/aks-platform-gitops-scaffold.md` 1절 스케치 기반). `live/hub/workbench`도
동시 진행 중(다른 세션, `aks-workbench-v0.1.0` 소비) - 8·9차 세션 미결 항목이었던
workbench 방향 결정이 실제로 진행되고 있음.
### 2026-09-04(9차 세션) - CI 신원 권한 모델 전면 재검토(RG→구독 Owner) + AKS identity Terraform 이관

workbench 착수 준비 중 사용자가 "bootstrap/Terraform 분리는 AWS 패턴의 형태만 빌린 안티패턴
아니냐"고 문제제기 → AWS 원본(`eks-reference-infra`) 실측 확인: 실행 Role이 이미
`AdministratorAccess`였고, 방어선은 권한 크기가 아니라 FIC subject 하나로 좁힌 도달
경로였다. Azure ABAC 조건부 위임(role assignment write에 RoleDefinitionId 허용목록
조건)도 조사했으나 최종 결정은 AWS와 문자 그대로 대칭(구독 전체 Owner) — 사용자 명시
선택.

**실행**: hub·dev 양쪽 실제 재부트스트랩 완료(3-1·3-2 통과). 과정에서 az CLI
create/update 스키마 불일치(`roleName` vs `name`)·bash `IFS='|' read <<<"$(fn)"`
접두사 할당 누수·`AssignableScopes` 변경 직후 ARM 전파 지연, 총 3건의 실측 버그
발견·수정(상세는 project-memory.json architecture 항목·`.omc/plans/
bootstrap-credential-design.md`).

**사고 1건**: "워크로드 역할이 이미 state RG·컨테이너를 포괄한다"고 오판해
state-data 역할(blob data-plane)을 삭제했다가, `Owner`도 `dataActions:[]`임을
`az role definition list`로 실측 확인해 같은 날 정정·재도입. 교훈: control-plane
권한이 아무리 넓어도 blob data-plane 접근은 별개 축.

**AKS identity 이관**: 사용자가 `id-demo-hub-krc-aks-01`을 왜 bootstrap이 만드는지
질문 → CI가 이제 구독 전체 Owner라 그 구조적 제약이 사라졌음을 확인 → 사용자 결정으로
`live/hub/aks` destroy → bootstrap의 구식 identity·role assignment 정리 →
`azurerm_user_assigned_identity`·`azurerm_role_assignment`를 Terraform 리소스로
신설(PR #4) → 재배포 → 노드 2대 Ready 실물 확인. 서브넷 스코프(MS 공식 BYO-VNet
최소 권고)는 변경 없음.

**커밋**: `05f86f4`·`7d838ea`·`14fe30d`(main 직접, bootstrap/*.sh·README) + PR #4
`b7d6225`(브랜치→머지, live/hub/aks·workflow — CLAUDE.md 5절 `.tf`/workflows 규칙).
`.omc/plans/bootstrap-credential-design.md`(로컬 전용, git 밖)에 이번 재검토 전문
기록.

**다음 세션**: `live/hub/workbench` 착수 — `aks-workbench-v0.1.0`(SSH가 일상 경로,
Run Command가 브레이크글래스, ②CLI 전용 workbench 설계) 소비, identity·role
assignment 처음부터 Terraform으로.
### 2026-09-03(8차 세션) - Private cluster Portal 접근 조사 + workbench 설계 갈림길 확인 + 엔터프라이즈 규제 리서치

사용자가 Azure Portal에서 K8s 리소스가 안 보이는 문제로 시작(private cluster 경고 메시지).
`live/hub/aks/main.tf:108`의 `private_cluster_enabled=true`가 원인이고, 의도된 설계임을
`.omc/plans/live-hub-aks.md` 3-6절로 확인 — 검증 경로는 `az aks command invoke`/Portal
내장 `Run command`.

**AWS EKS와의 비교 조사(사용자가 "AWS는 access entries만으로 콘솔 조회된다"고 반박,
공식문서로 재검증 요청)**: 결정적 차이를 확인함. EKS 콘솔 Resources 탭은 AWS 관리형
백엔드 `eks-proxy`(`com.amazonaws.region-code.eks-proxy`)가 사용자 브라우저 대신 K8s API를
호출하는 구조(`docs.aws.amazon.com/eks/latest/userguide/vpc-interface-endpoints.html`:
"backs cluster resource views in AWS consoles... not called directly by your applications")라,
private cluster(`endpointPublicAccess=false`)여도 IAM 권한(`eks:AccessKubernetesApi`)+access
entries만 있으면 그래픽 뷰가 그대로 동작한다. Azure AKS는 이 계층이 없다
(`learn.microsoft.com/azure/aks/access-private-cluster`: "you must access the Azure portal
from a network that can reach the subnet") — 유일한 관리형 우회는 `Run command`(kubectl
한 줄 실행기, 그래픽 브라우징 아님)뿐. 이전 턴에서 "AWS도 private면 똑같이 막힌다"고
추측성으로 답했던 것은 부정확했음을 정정함.

**workbench 설계 갈림길**: 사용자가 "workbench를 VNet 안에 만들고 거기서 Azure 웹콘솔을
띄우면 되냐, ubuntu는 어떻게 설치하냐" 질문 → AWS `workbench` 모듈(iac-module-library
`modules/aws/workbench/README.md`: "private 클러스터 운영 지점(SSM 전용, 인바운드 0)",
GUI 없이 kubectl/helm/argocd CLI만 부팅 시 설치)의 철학과 "Portal 그래픽 뷰를 보고
싶다"는 요구가 상충함을 확인. 3가지 경로 제시: ①현행 유지(Run command, 신규 인프라 0)
②CLI 전용 workbench(AWS SSM 패턴 대응 — Azure AD SSH/Bastion 터널, 실제 kubeconfig로
kubectl 직접 사용, command invoke보다 강력, Ubuntu Server로 충분) ③GUI 데스크톱
workbench(Ubuntu Desktop+xfce4+Firefox + Azure Bastion Standard SKU 전용 서브넷, 상시
과금, AWS 원본 철학과 이질적). `live/hub/networking`의 `vm` 서브넷(10.60.2.0/24)이 이미
이 용도로 예약돼 있고, aks-cluster 모듈이 `private_dns_zone_id`를 지정하지 않아 Azure
기본값(`System`)이 적용돼 private DNS zone이 hub VNet 전체에 자동 연결돼 있음을 확인 —
`vm` 서브넷에서 별도 피어링 없이 바로 AKS API 도달 가능. 사용자는 "고민만 하는 단계"라며
미결정, 다음 세션으로 넘김.

**엔터프라이즈/규제 리서치**: 사용자가 "private 유지가 금융·산기법 제조업 모범사례가
맞냐" 질문 → Microsoft 공식 문서(`secure-baseline-aks`)는 업종 무관 프로덕션 베이스라인
권고. 금융권은 전자금융감독규정 제15조가 원칙적으로 물리적 망분리 요구, 최근 SaaS 예외
생겼으나 고유식별정보/개인신용정보 처리 시 예외 미적용(원칙 그대로 적용) — 단 "K8s API
서버는 private이어야 한다"는 문구를 조문에서 직접 찾지 못해 추론임을 사용자에게 명시,
법무 확인 필요 언급함. 국가핵심기술 보유 제조업(산기법)은 2025 공식 안내서가 "네트워크
분리"를 명시 요구하나, 이 요건은 국가핵심기술 보유기관에만 한정 적용됨(모든 산기법 대상
제조업이 아님) — 이 구분을 사용자에게 정정 설명함.

**다음 세션**: workbench 방향(①/②/③) 결정되면 CLAUDE.md 절차대로 `.omc/plans/`에
설계부터 잡을 것. 그 외 미결 항목은 이전 세션과 동일(docs/ 포팅, GitOps 착수 시
Karpenter 재검토 등).
### 2026-09-03(7차 세션) - Phase 2 착수: live/hub/aks 실배포 완료, 모듈 버그 2건 발견·수정

**1. hub·dev VNet secondary CIDR 제거**: `iac-module-library`가 `aks-cluster` 모듈의
`cni_mode` 기본값을 Pod Subnet에서 Overlay로 전환(v0.3.0)한 걸 확인하고, hub
(`100.64.0.0/16`)·dev(`100.65.0.0/16`) VNet의 Pod 전용 secondary CIDR을 실제로
제거·apply(PR #1). Overlay는 VNet 밖 오버레이 대역에서 Pod IP를 받아 이 CIDR 자체가
불필요해졌다 — 실물 확인(`az network vnet show`) 후 진행, 어떤 서브넷도 그 대역을
안 쓰고 있어 in-place 변경(파괴 없음)이었다.

**2. live/hub/aks RALPLAN 2라운드**: `aks-cluster` v0.4.0을 소비하는 신규 배포 루트
설계. 라운드 1에서 Architect가 모듈 자체의 ARM 레벨 버그(overlay+cilium 조합을
ARM이 거부)를 발견 — `iac-module-library`에서 직접 수정해 `aks-cluster-v0.4.0` 태그
발행 후 계획 재작성. 라운드 2에서 Architect(조건부 승인, 3건 지적)·Critic(REVISE,
내부 일관성 결함 다수 — 여러 차례 개정 중 폐기한 근거가 다른 절에 남아있는 문제,
완료 판정 명령 오류 등) 전부 반영해 최종 승인.

**3. team 실행 + 배포 중 두 번째 모듈 버그 발견**: worker-1(bootstrap 확장:
identity·서브넷 스코프 Network Contributor role assignment 조건부·수렴형 설계,
RP 등록, verify.sh `na` 상태 추가)·worker-2(live/hub/aks 신규 root 스캐폴딩) 병렬
실행, 둘 다 고품질로 완료. bootstrap.sh 실행 중 `az identity show`가 반환하는
리소스 ID의 `resourcegroups`(소문자)가 azurerm provider(v5 타입 SDK)의
`resourceGroups` 요구와 안 맞아 첫 apply 실패 → `bootstrap.sh`에 `sed` 정규화 추가로
해결. apply 성공 후 완료 판정 §4-8(재-plan 수렴) 확인 중 두 번째 버그 발견:
`default_node_pool`이 `upgrade_settings`를 선언 안 해 Azure 기본값(`max_surge=10%`)과
매번 어긋나는 perpetual diff(독립 plan 3회 연속 실측, 파괴적이진 않음) —
`iac-module-library`에서 정정해 `aks-cluster-v0.5.0` 발행, 이 root를 올려 재적용 후
완전 수렴(`No changes`) 확인.

**결과**: hub 구독에 `aks-demo-hub-krc-main-01` 클러스터 실제 가동(노드 2대 Ready,
networkProfile이 overlay/cilium/cilium/10.244.0.0/16/userAssignedNATGateway로 의도대로
적용됨을 실측 확인, VMSS 인스턴스 NIC가 `aks-node` 서브넷에 실제로 join). Karpenter는
`enable_karpenter=false`로 시작(GitOps 계층 없어 죽은 설정 방지, 나중에 in-place
전환 가능하도록 `auto_scaling_enabled=false` 전제조건 미리 맞춤). `deletion_protection
=false`는 리스크 수용이 아니라 `network_profile`/`private_cluster_enabled`가 ForceNew라
`true`가 기술적으로 불가능한 상태(GitOps 착수 후 그 축이 확정되면 전환).

**다음 세션**: (1) workbench 후속 계획(Azure에 AWS `workbench` 대응 모듈이 아직
없음, 별도 설계 필요) (2) `aks-platform-gitops` 착수 시 Karpenter·Entra RBAC·
`deletion_protection=true` 재검토 (3) GitOps가 `ilb` 서브넷에 내부 LB를 세울 때
identity role assignment 스코프(현재 `aks-node` 단일 서브넷) 확장 필요 여부 재검토.

### 2026-09-03 09:50
### 2026-09-03(6차 세션) - Phase 1 완료: live/dev/networking apply + 크로스 구독 vWAN 연결 + 문서 정비

**1. live/dev/networking CI 막힘 해소**: 지난 세션에 발견한 dev SP state-data role
assignment의 Storage 데이터플레인 전파 지연(공식 문서 상한 30분, 실측 1시간+)이 원인이었던
`tofu init` 실패를, role assignment 생성 시각(2026-08-28T07:28)과 현재(2026-09-03,
5일+ 경과)를 비교해 자연 해소됐다고 판단 → 재시도로 실제 확인(CI plan/apply 성공, VNet
`vnet-demo-dev-krc-main`, `10.61.0.0/16`+`100.65.0.0/16`, 서브넷 5종). "얼마나 기다렸는가"를
정량화해 재시도 가치를 판단한 사례.

**2. 크로스 구독 vWAN 스포크 연결 권한(5단계) — 설계를 세션 중 개선**: 최초 ralplan
설계(`peer/action`을 dev VNet 리소스 스코프로, 별도 스크립트 `cross-subscription-peer.sh`
실행)를 구현하다가, 사용자가 "bootstrap.sh에 애초에 넣을 수 없나? AWS는 스포크 추가 시
뭘 하나?" 질문 → AWS RAM(계정/OU 단위 공유, 스포크가 자기 계정 전권으로 attachment 생성)과
Azure vWAN(정확한 대응물 없음, hub가 연결 소유하는 반대 방향 유지)의 근본 차이를 확인한 뒤,
스코프를 dev **워크로드 RG**로 완화해 `bootstrap.sh` 6-1절에 통합(별도 스크립트 폐기) —
스포크 부트스트랩 1회 실행만으로 끝나도록 개선. `verify.sh`에 대칭 검사 추가(가드를
`BOOTSTRAP_TARGET=="spoke"`로 일반화, 다음 스포크에도 자동 적용). hub·dev 양쪽 회귀 없음
확인, dev 대상 멱등성 + 음성 테스트 2건(RG 스코프 확장, Contributor 치환) 전부 통과 후
실제 Azure에 적용. `live/hub/vwan` 2차 apply(CI OIDC, 정적 자격증명 전혀 없이)로
`peer/action` 단일 권한 충분함을 실측 확인, `az network vhub get-effective-routes`로
hub·dev 4개 대역 양방향 전파 확인. 설계 변경분은 `.omc/plans/live-hub-vwan-dev-networking.md`
12절 + 5·9절 포인터로 기록. 커밋 `75b28f2`.

**3. project-memory.json 손상 재발 → 근본 해결**: permissions.deny(921bbda) 이후에도
이번 세션 시작 시 techStack/build/conventions/structure가 또 빈 스키마로 손상돼 있었다.
iac-module-library가 이틀 앞서 소스 직접 확인으로 규명한 진짜 원인(OMC SessionStart 훅의
`shouldRescan()`이 24시간 경과 시 무조건 재스캔, permissions.deny는 이 훅 경로를 막지
못함, Terraform/OpenTofu는 detector 인식 목록에 없어 매번 빈 스키마로 귀결)을 그대로
적용: `lastScanned`를 9999999999999(먼 미래 sentinel)로 고정, 손상된 4개 필드 복원.
커밋 `12ae376`.

**4. CLAUDE.md 재작성**: 세션 로그·TODO가 규칙과 뒤섞여 있던 구조를 `eks-reference-infra`와
동일한 8절 구조(위치→구조→실행모델→네이밍→로컬게이트→브랜치규칙→문서규칙→모듈확인습관)로
전면 재작성. docs/·.githooks/·`aks-platform-gitops`가 아직 없다는 사실을 ⏳로 명시.
브랜치·PR 규칙은 원본과 동일 채택(`.tf`·workflows는 브랜치→PR, 지금까지의 main 직접
커밋은 "규칙 확정 전" 예외로 문서화, 사용자 확인 완료). 부수로 저장소 전체에 남아있던
repo명 오기(`iac-reference-infra`→`eks-reference-infra`) 4개 파일 정정. 커밋 `1c32094`.

**다음 세션**: (1) `docs/` 포팅(원본 `eks-reference-infra`에서 기계적 이식, hub/spoke
lifecycle·runbooks) (2) `.githooks/`·`scripts/validate-doc-conventions.py` 포팅
(3) Phase 2(AKS)는 `iac-module-library`에 `aks` 모듈이 올라오면 별도 deepinit/plan
사이클로 착수 — 지금 세션의 ralplan 범위 밖.
### 2026-08-27 05:15
2026-08-27 - deepinit으로 CLAUDE.md·notepad-sync 스킬 초기화(HANDOFF.md 삭제, 내용 병합). ralplan(5라운드, Architect/Critic 교차검증)으로 bootstrap/ 설계 v6 확정: AWS 2단 Role 체인 대신 RG스코프 커스텀 역할 2종+7종 권한0건 불변식. 사용자 확정: hub/dev 별도 구독, 배포는 브랜치정책만(무인자동화 유지), Option C는 보류. ralph(4라운드 리뷰)로 bootstrap/{README,config.sh,bootstrap.sh,verify.sh} 구현, ai-slop-cleaner로 검토이력 주석 정리. 핵심 발견: macOS bash 3.2가 $() 안에서 errexit 미적용 - TOP_PID+kill 시그널 패턴으로 해결(project-memory architecture 노트 참고). 최종 APPROVE, 단 실제 Azure 실행 검증은 미완(자격증명 없는 세션).
### 2026-08-27 06:44
### 2026-08-27 (2차 세션) - bootstrap/ 실제 Azure 검증 + 네이밍 정리

사용자가 Azure 자격증명 확보 후 hub 대상 3-1(멱등성)·3-2(음성 테스트) 실제 실행 요청.

**1라운드 - 실제 검증**: az login 확인(구독 1개뿐, Owner 권한) → hub 대상 bootstrap.sh 첫 실행 중
"Role doesn't exist" 에러로 exit 2 → retry_on_principal_not_found를 retry_on_replication_delay로
개명·확장해 해결 → 재실행 중 멱등성 붕괴(매번 role definition update 발생) 발견 → 존재 확인 후
재조회에 5회 재시도(role_definition_list_retry) 신설해 해결 → 3-1 완전 통과 → verify.sh가 관리
그룹 스코프 검사에서 AuthorizationFailed(테넌트 루트 MG Reader 필요) → 사용자에게 "OIDC 배포에
실제로 필요한가" 질문받고 확인 결과 불필요 → 사용자가 삭제 확정 → verify.sh에서 check_mg_scope_
assignments 전체 제거(7종→6종), README/CLAUDE.md 갱신, 설계 이력 문서(.omc/plans/bootstrap-
credential-design.md)엔 날짜 붙은 추가 기록만 남기고 원문은 보존 → 3-2 음성 테스트(FIC+Storage
drift 주입)까지 hub 대상으로 완전 통과.

**2라운드 - 네이밍 정리**: 사용자가 "todo-" 접두사 원인을 질문 → iac-module-library의 azure.md에
Network 6종뿐이고 RG/Storage Account/App Registration 약어가 없었던 게 원인임을 실측 확인(CAF
표 직접 조회) → App Registration은 ARM 리소스가 아니라 Microsoft Graph 객체라 CAF 표 자체에
없다는 것도 확인 → 사용자가 "약어부터 등록하고 기존 리소스는 삭제 후 재생성하자"고 결정 →
iac-module-library에 rg/st/entapp 3종 등재(entapp는 카탈로그의 첫 non-ARM 등재 사례,
validate-abbreviations.py 통과 확인) → aks-reference-infra의 config.sh 네이밍 함수 교체 →
hub 리소스 전체 삭제(잠금 해제→RG 2개 삭제→App Registration 삭제→역할 정의 2종 삭제) → 새
이름으로 bootstrap.sh 재실행 중 세 번째 버그 발견(RoleDefinitionWithSameNameExists, 최초
존재 확인 조회도 재시도 없었던 게 원인) → role_definition_list_retry를 최초 조회에도 적용 +
role assignment 조회를 roleDefinitionName에서 roleDefinitionId로 교체(join 지연 문제) →
3-1·3-2 처음부터 재통과 확인.

**커밋**: aks-reference-infra 6f088b8(CLAUDE.md·bootstrap/*, 5파일). iac-module-library는
사용자가 직접 커밋(azure.md). 둘 다 원격 없음/이미 push까지 사용자가 처리해 이 세션에서는
push 불필요.

**미결**: dev(spoke) 인스턴스 미검증(구독 1개뿐), 크로스 구독 vWAN 권한 스코프 미확정,
Option C 보류. 다음 세션은 vWAN 스코프 확정 또는 Phase 1 networking plan→execute.
### 2026-08-27 08:33
### 2026-08-27(3차 세션) - live/hub/networking 실제 배포 + CI 신설

plan → execute 절차로 live/hub/networking 스캐폴딩(vnet 모듈 최초 소비, 서브넷 5종
pub/ilb/vm/pe/aks-node) 완료 후 사용자가 "네가 직접 해줘"라고 요청 - 로컬 apply는
require_oidc 가드가 막도록 이미 설계돼 있어, CI(GitHub Actions OIDC) 구축부터 진행하기로
사용자와 합의.

GitHub repo skax-ca/aks-reference-infra(private) 생성, push, bootstrap.sh 재실행으로
FIC subject를 실제 repo로 갱신 → verify.sh drift 없음 확인 → GitHub repo 변수 5종 설정
→ MODULE_READER_KEY(GitHub App private key)는 API로 복사 불가해 막혔다가 사용자가
"홈 디렉토리 뒤져봐"라고 지시, ~/.config/gh-apps/skax-ca-module-reader.pem에서 발견해
등록 → .github/workflows/deploy-hub-network.yml 작성(AWS 원본 패턴을 단일신원 OIDC로
재구성).

첫 dispatch부터 세 차례 연속 실패: (1) FIC subject 형식이 GitHub의 실제 sub 클레임과
안 맞음(org@id/repo@id 필요, AADSTS700213) - bootstrap/config.sh 수정 + 재부트스트랩으로
해결 (2) azurerm 기본 프로바이더 자동등록이 CI 권한 밖이라 9분 넘게 무응답 - 사용자가
"이렇게 오래 걸릴 이유 없다"며 직접 조사 요청, resource_provider_registrations="none"으로
해결 (3) providers.tf의 require_oidc_guard가 쓴 getenv()가 존재하지 않는 함수 - var.ci_run
방식으로 재설계. 이 과정에서 cancel한 run이 state blob lease를 orphan 상태로 두 번 남겨
(사용자가 "리모트에서 lock 잡힌거 아냐"라고 먼저 의심, 정확했음) 임시로 개인 계정에
Storage Blob Data Reader/Contributor를 부여해 lease break로 해제, 작업 후 전부 회수.

최종 dispatch: plan(Plan: 24 to add, 0 change, 0 destroy) → apply 성공 → 재-plan 수렴
검증 통과. az network vnet show로 실물 확인(vnet-demo-hub-krc-main, 10.60.0.0/16, 서브넷
5개). CLAUDE.md 0·5·6절을 실제 배포 완료 상태로 갱신. verify.sh 최종 재확인 drift 없음.

커밋: aks-reference-infra 7d71c51까지(총 6개 커밋: 스캐폴딩, CI 배선, FIC 수정,
provider registration 수정, getenv 수정, CLAUDE.md 갱신). 전부 push 완료.

다음 세션: live/hub/vwan 신설 또는 dev 구독 확보 후 live/dev/networking.
### 2026-08-28 00:34
### 2026-08-28(4차 세션) - AWS 원본 대조 검토 + Pod 네트워킹 secondary CIDR 적용

사용자가 live/hub/networking의 세 가지 설계를 질문: (1) secondary CIDR 미사용 이유
(2) 서브넷 네이밍이 Azure 모범사례에 맞는지 (3) Azure 콘솔에서 라우팅 테이블이 1개만
보이는 이유. 코드(main.tf)와 vnet 모듈 소스, Azure 공식 문서(CAF 약어표·hub-spoke
레퍼런스 아키텍처)를 대조해 세 항목 모두 의도된 설계이고 버그가 아님을 확인.

사용자가 eks-reference-infra(AWS 원본)와 직접 비교해달라고 요청 — AWS는 secondary
CIDR을 적극 활용(primary 소형 인프라 / uniq 라우팅가능 워크로드 / dup=100.64.0.0/16
RFC6598 비라우팅 pod)하고 라우팅 테이블도 전 서브넷에 명시적으로 붙인다는 점을 근거로
Azure도 동일하게 가야 하는지 질문. eks-reference-infra/live/hub/networking/main.tf,
iac-module-library의 aws/vpc 모듈, docs/decisions.md(VPC Peering 대신 TGW를 택한
이유 = dup CIDR 재사용)를 직접 확인. 결론: CIDR 3계층 원칙은 가져올 가치가 있지만
Azure의 pod 격리 메커니즘(CNI 모드)이 다르므로 구현은 특화해야 하고, 라우팅 테이블은
AWS 관행(전부 명시적 생성)을 그대로 가져오면 역효과 — Azure는 시스템 기본 라우트가
자동 적용돼 UDR은 오버라이드가 필요한 지점에만 옵트인으로 붙이는 게 맞음(Microsoft
Learn 공식 문서 virtual-networks-udr-overview로 확인). 라우팅 테이블 설계는 변경 없음.

사용자가 "AWS는 VPC CNI(underlay)를 권장하는데 Azure가 Overlay를 권장하는 이유가
같은 맥락(성능/트레이스)인지, 아주 중요한 결정사항"이라며 재검토 요청. AWS EKS Best
Practices 공식 문서와 Microsoft Learn(Azure CNI Overlay/Pod Subnet 개념 문서) 대조
결과: Azure CNI Overlay는 캡슐화가 없어 성능은 flat과 동급(사용자 우려는 기우)이지만,
클러스터 밖으로 나가는 Pod 트래픽이 노드 IP로 SNAT돼 NSG 플로우 로그·Network Watcher
에서 Pod 단위 가시성이 사라지는 트레이드오프가 실재함을 확인 — 이건 AWS VPC CNI
(underlay, SNAT 없음)의 네이티브 가시성 철학과 어긋남. 최초 제안(Overlay 기본값)을
스스로 뒤집고 flat(Pod Subnet)으로 정정.

사용자가 "secondary CIDR로 AWS와 동일하게 구성하는 걸 기본으로 반영해달라"고 요청 →
지금 hub VNet에 실제 적용할지 문서화만 할지 AskUserQuestion으로 확인 → "지금 실제
추가" 선택. main.tf에 cidr_pod_dup="100.64.0.0/16" locals 추가, address_space에
secondary로 배선, aks-node 서브넷 주석 갱신(노드 전용, Pod는 secondary CIDR 소관).
CLAUDE.md 3절에 Phase 2 CNI 기본값 결정(flat, Overlay 배제) 확정 기록. commit 0100235
push → CI plan(0 add/1 change/0 destroy, azurerm_virtual_network in-place update만) →
workflow_dispatch apply → 수렴 검증 통과 → az network vnet show로 실물 확인
(addressSpace: 10.60.0.0/16, 100.64.0.0/16). Pod 전용 서브넷 자체는 미생성(Phase 2
AKS 모듈 없어 소비자 없음 — 의도적으로 남겨둠).

다음 세션: live/hub/vwan 착수 시 cidr_pod_dup을 vWAN 허브 라우팅 테이블 전파에서
제외하는 조치 필요(AWS TGW 선택적 라우팅과 동일 논리, main.tf 주석 참고). 또는 dev
구독 확보 후 live/dev/networking.

## MANUAL
<!-- User content. Never auto-pruned. -->
