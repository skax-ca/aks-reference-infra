# Notepad
<!-- Auto-managed by OMC. Manual edits preserved in MANUAL section. -->

## Priority Context
<!-- ALWAYS loaded. Keep under 500 chars. Critical discoveries only. -->
## Priority Context

2026-08-28(5차) - dev 구독(af8171fb-...) 확보, spoke 구축 중: Pod CIDR 정정(dev=100.65.0.0/16, hub 유지) 완료, dev bootstrap 완료, live/hub/vwan 배포 완료(vHub 10.62.0.0/22, 스포크 없음). live/dev/networking 코드는 push했으나 CI tofu init이 AuthorizationPermissionMismatch로 막힘 — dev SP state-data role(컨테이너 스코프)이 1시간+ Storage 전파 안 됨(SP 직접 로그인 테스트로 GH Actions 문제 아님 확정, 순수 Azure 지연). 다음: CI 재시도(run 33153826604) 또는 storage-account 스코프로 전파속도 비교 테스트. 이후 5단계(크로스 구독 권한+vWAN 연결).

## Priority Context

2026-08-28(5차 세션) - dev 구독(af8171fb-...) 확보, spoke 구축 진행: (1) Pod CIDR 정책 정정 완료(dev=100.65.0.0/16, hub=100.64.0.0/16 유지, Azure CNI Pod Subnet은 SNAT 없어 dup 재사용 불가) (2) dev bootstrap 완료·검증 통과 (3) live/hub/vwan 배포 완료(vHub 10.62.0.0/22, 스포크 연결 없음) (4) live/dev/networking 코드 작성·push 완료했으나 CI의 tofu init이 AuthorizationPermissionMismatch로 막힘 — dev SP의 state-data role assignment(컨테이너 스코프)가 1시간+ Storage 데이터플레인에 전파 안 됨(SP 직접 로그인 테스트로 GH Actions 문제 아님, 순수 Azure 전파 지연 확정). 다음: 전파 확인 후 CI 재시도(gh run rerun 33153826604 --failed), 또는 storage account 스코프로 임시 재할당해 전파 속도 비교. 그 다음 5단계(크로스 구독 권한+vWAN 스포크 연결).

## Priority Context

aks-reference-infra: bootstrap/ hub 실제 Azure 검증 완료(3-1+3-2, 2026-08-27). ARM eventual-consistency 버그 3건 수정(retry_on_replication_delay, role_definition_list_retry, roleDefinitionId 필터). 불변식(b) 관리그룹 제거(7→6종). 네이밍 약어 rg/st/entapp를 iac-module-library에 등재 후 hub 리소스 재생성(todo- 완전 제거). commit 6f088b8, 원격 없어 push 미해당. 남은 미결: dev(spoke) 검증(구독 1개뿐), 크로스구독 vWAN 권한 스코프, Option C 보류. 다음은 vWAN 스코프 확정 또는 Phase 1 networking plan→execute.

## Working Memory
<!-- Session notes. Auto-pruned after 7 days. -->
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


## 2026-08-27 05:15
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


## 2026-08-27 05:15
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


## 2026-08-27 05:15
2026-08-27 - deepinit으로 CLAUDE.md·notepad-sync 스킬 초기화(HANDOFF.md 삭제, 내용 병합). ralplan(5라운드, Architect/Critic 교차검증)으로 bootstrap/ 설계 v6 확정: AWS 2단 Role 체인 대신 RG스코프 커스텀 역할 2종+7종 권한0건 불변식. 사용자 확정: hub/dev 별도 구독, 배포는 브랜치정책만(무인자동화 유지), Option C는 보류. ralph(4라운드 리뷰)로 bootstrap/{README,config.sh,bootstrap.sh,verify.sh} 구현, ai-slop-cleaner로 검토이력 주석 정리. 핵심 발견: macOS bash 3.2가 $() 안에서 errexit 미적용 - TOP_PID+kill 시그널 패턴으로 해결(project-memory architecture 노트 참고). 최종 APPROVE, 단 실제 Azure 실행 검증은 미완(자격증명 없는 세션).


## MANUAL
<!-- User content. Never auto-pruned. -->

