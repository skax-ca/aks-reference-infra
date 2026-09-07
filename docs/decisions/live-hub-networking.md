# live/hub/networking 스캐폴딩 계획

status: approved
작성일: 2026-08-27

## 요구사항 요약

Phase 1 첫 번째 배포 루트. `iac-module-library`의 `modules/azure/vnet`을 실제로 처음 소비한다.
hub 구독에 vnet 1개를 세우고, 사용자 확정에 따라 AKS(Phase 2) 자리까지 미리 확보하는
엔터프라이즈급 서브넷 구성을 갖춘다. TGW 대응인 Virtual WAN 연결은 `live/hub/vwan`(별도
state, 이번 스코프 밖)이 담당한다.

사용자 확정 사항(이번 세션 질의):
- 서브넷 범위: AKS 자리까지 미리 확보(최소 구성 아님)
- CIDR: hub와 spoke(dev)만 겹치지 않으면 됨(기존 Azure 대역과의 충돌 우려 없음)
- 서브넷 구성은 vpc(AWS 원본)와 마찬가지로 엔터프라이즈 환경 수준으로 짠다

## 확인된 계약·상수 (재조사 불필요)

- `modules/azure/vnet` 필수 입력: `naming{workload,env,region_code}`, `resource_group_name`,
  `location`, `address_space`. `subnet_groups`는 map(그룹키 → `address_prefixes` 등).
  NAT Gateway는 `nat_routed=true`인 그룹이 1개 이상일 때만 생성됨(조건부, 소비자가 분기 안 짜도 됨).
  예약 서브넷(AzureBastionSubnet 등)은 모듈이 만들지 않음 - 이번 계획에서도 만들지 않는다(아래
  「의도적으로 다루지 않는 것」 참고).
- 모듈 `versions.tf`: `terraform >= 1.12.0`, `azurerm >= 5.0`(하한만). 루트가 상한을 건다(AWS
  원본 규약과 동일, `~> 5.0`).
- bootstrap 확정 토큰(`bootstrap/config.sh` 확인): `WORKLOAD=demo`, `REGION_CODE=krc`,
  `REGION=koreacentral`. hub의 `env` 토큰은 `hub`. 워크로드 RG 이름
  `rg-demo-hub-krc-workload-01`(사람이 선생성, CI 미관여, 이 root가 `resource_group_name`으로 참조).
- CI 인증(bootstrap 확정): GitHub OIDC(FIC) 단일 경로, 정적 자격증명 없음. GitHub repo 변수
  `AZURE_CLIENT_ID`·`AZURE_TENANT_ID`·`AZURE_SUBSCRIPTION_ID` 3종만 존재(`azurerm` provider가
  `ARM_*` 환경변수로 그대로 읽는 이름과 자연히 대응됨 - 별도 TF 변수 매핑 불필요).
- state backend(bootstrap 확정): `azurerm` backend, Storage Account 이름은 git에 없음(로컬
  `backend.hcl`, gitignore됨), 컨테이너 `tfstate` 1개 재사용, `use_azuread_auth = true`.

## 설계 결정

### 1. 파일 구성 - AWS 원본과 동일한 스켈레톤, 내용은 Azure로 치환

```
live/hub/networking/
  main.tf          module "vnet" 블록 + CIDR 계산 locals
  variables.tf      workload/env/region_code/subscription_id/tenant_id/client_id 등
  outputs.tf        하류(Phase 2 AKS) 참조용 앵커
  versions.tf       terraform/azurerm 버전 고정(루트가 상한)
  providers.tf       azurerm provider 배선
  backend.tf         빈 backend "azurerm" {} 블록(partial config)
  backend.hcl.example  실제 backend.hcl(gitignore)의 형태를 보여주는 예시(값은 placeholder)
```

AWS 원본에는 없던 `backend.hcl.example`을 추가한다 - AWS는 버킷명 형태가 자유로워 예시가 굳이
필요 없었지만, Azure Storage Account 이름은 물리 제약(소문자+숫자, 3~24자)이 있어 형태를
보여주는 예시가 실수를 줄인다.

### 2. CIDR 설계

hub vnet: `10.60.0.0/16` 단일 블록. spoke(dev)는 이번 스코프에서 만들지 않지만
`10.61.0.0/16`을 예약해 문서에 남긴다(다음 세션 `live/dev/networking` 착수 시 재조사 없이 바로
씀). AWS 원본처럼 실제 계정 내 기존 대역을 전수 조회하지 않는다 - 사용자가 "hub·spoke만 안
겹치면 된다"고 확정했기 때문(기존 Azure 대역과의 충돌 우려가 없는 상태).

⚠️ AWS 원본과 달리 duplicate-CIDR 대역(RFC 6598, 100.64.0.0/16)을 별도로 두지 않는다. AWS는
EKS Pod가 VPC 안의 실제 ENI IP를 쓰는 모델이라 계정마다 겹쳐도 되는 대역이 필요했다. AKS는
아직 모듈이 없어 어떤 CNI 모드(Azure CNI Overlay vs 기존 CNI)를 쓸지 확정되지 않았고, Overlay를
쓰면 Pod IP는애초에 vnet 서브넷에 속하지 않는다(별도 오버레이 대역, AKS 리소스 인자로 지정 -
vnet 서브넷과 무관). 그래서 지금 Pod용 서브넷을 예약하지 않는다 - Phase 2에서 AKS 모듈이
CNI 모드를 정할 때 필요하면 그때 만든다(아래 서브넷 그룹 절 참고).

### 3. 서브넷 그룹 설계 - AWS 8종을 Azure 관용구로 재해석(1:1 포팅 아님)

AWS 원본의 `pub-uniq`·`elb-uniq`·`vm-uniq`·`node-uniq`·`pod-dup`·`db-uniq`·`data-uniq`·
`ep-uniq`·`tgw-uniq` 9종을 그대로 옮기지 않는다. 이유:

- `tgw-uniq`(TGW attachment 전용 서브넷)는 Azure에 대응 개념이 없다 - Virtual WAN Hub
  연결은 vnet 전체 단위로 peering되고 특정 서브넷을 요구하지 않는다(전통적 VPN Gateway의
  `GatewaySubnet`과 다른 점). `live/hub/vwan`에서 vnet ID만 참조하면 된다.
- `ep-uniq`(VPC Interface Endpoint 전용)·`db-uniq`(RDS)·`data-uniq`(MSK/OpenSearch/Redis)는
  AWS에서 "관리형 서비스가 실제로 서브넷 안에 ENI를 만든다"는 전제가 같아서 셋으로 나눴다.
  Azure의 대응 패턴(Private Endpoint)은 서비스 종류와 무관하게 같은 서브넷을 공유해도 무방한
  경우가 많아(모듈 repo에 Azure PaaS용 서비스 모듈이 아직 없어 정확한 요구를 알 수 없음) 셋을
  하나(`pe`)로 합친다. 이후 특정 서비스가 전용 서브넷(위임이 필요한 delegated subnet 등)을
  요구하면 그때 분리한다 - 지금 쪼개봐야 근거가 없다.

최종 그룹(엔터프라이즈 스코프 유지, AWS 대비 5종으로 압축):

| 키 | 역할(AWS 대응) | CIDR | nat_routed | nsg_enabled | route_table_enabled |
|---|---|---|---|---|---|
| `pub` | `pub-uniq`(인터넷 대면 LB/App Gateway) | `10.60.0.0/24` | false | true | false |
| `ilb` | `elb-uniq`(내부 LB/ArgoCD ingress) | `10.60.1.0/24` | false | true | true |
| `vm` | `vm-uniq`(관리·workbench VM) | `10.60.2.0/24` | true | true | false |
| `pe` | `ep-uniq`+`db-uniq`+`data-uniq` 통합(PaaS Private Endpoint) | `10.60.3.0/24` | false | true | false |
| `aks-node` | `node-uniq`(AKS 노드, Phase 2 자리 확보) | `10.60.16.0/20` | true | true | false |

`10.60.4.0/24`~`10.60.15.0/24`, `10.60.32.0/19` 이후는 미할당으로 남긴다(향후 Pod 서브넷·
AzureFirewallSubnet 등 필요 시 재조사 없이 바로 씀).

⚠️ `aks-node`는 `/20`(4096개 IP)으로 넉넉히 잡았다 - Azure CNI Overlay라면 노드 수만큼만
쓰이므로 과잉이고, 기존 CNI(Pod가 노드 서브넷 IP를 직접 씀)라면 오히려 부족할 수 있다.
Phase 2에서 AKS 모듈의 CNI 모드가 정해지면 이 크기를 재검토해야 한다 - 지금은 "존재는
하되 크기는 잠정적"이라는 상태로 둔다.

`ilb`만 `route_table_enabled = true`인 이유: AWS 원본의 `elb-uniq`가 같은 역할이었고(온프레미스
→ 내부 LB 왕복 경로를 위한 운영 라우트 앵커), vWAN 연결 후 hub↔spoke 라우트를 얹을 자리가
필요하기 때문이다. 나머지 그룹은 지금 운영 라우트를 얹을 계획이 없어 켜지 않는다(불필요한
빈 리소스를 만들지 않는다).

### 4. NAT Gateway

`nat_gateway_enabled`는 기본값(true) 그대로 둔다 - `vm`·`aks-node` 두 그룹이
`nat_routed = true`라 자동으로 생성된다. SKU도 기본값(`Standard`, GA) 유지 - `StandardV2`는
프리뷰라 채택하지 않는다(모듈 README 경고 그대로).

### 5. deletion_protection

`true`로 켠다. hub는 "구독 하나의 단일 고정 거처"(`CLAUDE.md` 2절)라 AWS 원본이 문서화한
"실수 삭제 최후 방어선" 의도와 같다. 파기가 필요하면 `deletion_protection = false`로 먼저
apply한 뒤 destroy하는 2단계 절차를 문서화한다(AWS 원본과 동일한 패턴).

### 6. provider 인증 배선 - AWS의 2단 Role 체인과 근본적으로 다르다

AWS `providers.tf`는 `assume_role` 블록으로 OIDC 2단 체인의 2단째를 명시했다. 이 repo의
bootstrap 설계는 그 체인이 없다(CI 신원이 직접 RG 스코프 커스텀 역할을 가짐, `CLAUDE.md` 4절).
`azurerm` provider는 `ARM_CLIENT_ID`·`ARM_TENANT_ID`·`ARM_SUBSCRIPTION_ID`·`ARM_USE_OIDC` 환경
변수를 **자동으로 읽으므로**, `providers.tf`에 AWS의 `assume_role` 같은 명시적 인증 블록이
필요 없다 - `provider "azurerm" { subscription_id = var.subscription_id; features {} }` 수준의
최소 배선으로 충분하다. `subscription_id`만 변수로 명시해 구독 오인 apply를 방지한다(AWS의
"계정 식별 정보는 git에 없다" 규약과 동일하게 기본값 없이 `TF_VAR_subscription_id`로 주입).

⚠️ **사용자 확정(이번 세션): CI만 허용하도록 방어를 추가한다.** AWS는 실행 Role의 신뢰 정책이
입구 Role 하나만 허용해 개인 IAM user로는 물리적으로 assume이 안 됐다. 이 repo의 bootstrap
신원은 그런 체인 자체가 없어 최소 배선만으로는 개인 `az login`으로도 로컬 apply가 그대로
성립해버린다 - AWS와 달리 로컬 plan/apply가 물리적으로 막히지 않는 차이를 사용자에게 알린 뒤,
AWS와 같은 수준의 방어를 이 repo도 갖추기로 확정했다.

`providers.tf`에 다음 가드를 추가한다:

```hcl
variable "require_oidc" {
  description = <<-EOT
    true면 ARM_USE_OIDC 환경변수가 "true"가 아닐 때 plan/apply 자체를 막는다(로컬 az login
    인증 경로 차단). GitHub Actions(OIDC) 실행에서는 azure/login 액션이 ARM_USE_OIDC=true를
    설정하므로 자동으로 통과한다. 로컬 검증(6절 검증 단계)이 필요한 드문 경우에만
    -var="require_oidc=false"로 명시적으로 낮춘다 - 기본값은 항상 켜져 있어야 한다.
  EOT
  type        = bool
  default     = true
  nullable    = false
}

resource "terraform_data" "require_oidc_guard" {
  lifecycle {
    precondition {
      condition     = !var.require_oidc || nonsensitive(getenv("ARM_USE_OIDC")) == "true"
      error_message = "ARM_USE_OIDC=true가 아닌 인증 경로(로컬 az login 등)로는 apply할 수 없다. CI(GitHub Actions OIDC)에서 실행하거나, 의도적 로컬 검증이면 -var=\"require_oidc=false\"를 명시한다."
    }
  }
}
```

⚠️ **추가 기록(2026-08-27, hub CI 최초 plan 실측)**: 위 `getenv("ARM_USE_OIDC")`는 실제로
동작하지 않는다 - Terraform/OpenTofu 언어에는 그런 함수가 없다("Call to unknown function"으로
plan이 실패했다). 실제 구현은 `var.ci_run`(CI 워크플로만 `TF_VAR_ci_run=true`로 설정)을
대신 검사하도록 고쳤다. 코드(`live/hub/networking/providers.tf`·`variables.tf`)가 SSOT이고
위 스니펫은 원래 설계 의도만 남긴다.

`terraform_data`(provider 없는 내장 리소스)의 `precondition`을 쓴 이유: 이 repo가 쓰는 provider는
`azurerm` 하나뿐이고, 이 검사 자체는 어떤 클라우드 API도 부르지 않는 순수 환경변수 검사라 별도
provider(`null`/`terraform`)를 추가로 선언할 이유가 없다. AWS의 신뢰 정책 기반 물리적 차단과
정확히 같은 강도는 아니다(코드 검사라 우회 가능은 하다) - 그러나 AWS 원본 자체도 `README.md`에
"로컬에서 가능한 것은 init -backend=false와 validate까지"라고 절차로 명시했을 뿐 마찬가지로
코드가 강제한 것은 신뢰 정책(AWS 고유 기능)이었다는 점에서, 이 repo는 신뢰 정책의 대응 기능이
없는 대신 plan 단계에서 명시적으로 막는 것으로 같은 의도를 구현한다.

### 7. 거버넌스 태그

모듈 README가 확인해준 대로 `azurerm`은 provider 레벨 `default_tags` 인자가 없다. AWS
`providers.tf`의 `default_tags` 블록 같은 자리가 없으므로, `main.tf`의 `module "vnet"` 블록에
`tags = { Environment = var.env, Workload = var.workload, RegionCode = var.region_code,
ManagedBy = "opentofu", Repository = var.repository }`로 명시 전달한다(AWS와 태그 키 이름은
맞추고, 전달 경로만 다르다).

### 8. backend

`backend.tf`는 AWS와 동일하게 빈 partial config:
```hcl
terraform {
  backend "azurerm" {}
}
```
key 네이밍은 AWS 패턴을 그대로 따른다 - `hub/networking.tfstate`. 컨테이너는 bootstrap이 만든
`tfstate` 1개를 재사용(다른 이름으로 새로 만들지 않는다 - 재사용 금지 규약은 "같은 이름 삭제 후
재생성"에만 해당, container 자체의 계속 재사용은 의도된 설계다).

## 의도적으로 다루지 않는 것 (스코프 밖, 이유 명시)

- **예약 이름 서브넷**(`AzureBastionSubnet`·`GatewaySubnet`·`AzureFirewallSubnet`): Bastion·
  Firewall·전통 VPN Gateway 배포 여부가 `CLAUDE.md`에 확정된 바 없다. vWAN 기반 설계는애초에
  `GatewaySubnet`을 요구하지 않는다(3절 참고). 필요해지면 그때 별도 planning 대상.
- **Virtual WAN 연결**: `live/hub/vwan` 별도 state, 별도 작업.
- **live/dev/networking**: 이번 세션은 hub만. CIDR만 예약(`10.61.0.0/16`), 실제 코드는 다음
  작업.
- **GitHub Actions 워크플로 파일**: `.github/workflows/*.yml`이 이 repo에 아직 없다(확인 완료).
  이 root의 CI 배선(원격 backend-config 주입 등)은 워크플로 신설과 함께 별도로 다룬다.

## 구현 단계

1. `live/hub/networking/versions.tf` - `terraform >= 1.12.0`, `azurerm ~> 5.0`
2. `live/hub/networking/variables.tf` - `workload`(기본값 `demo`)·`env`(기본값 `hub`)·
   `region_code`(기본값 `krc`)·`location`(기본값 `koreacentral`)·`repository`(기본값
   `skax-ca/aks-reference-infra`, 실제 GitHub org/repo 확정 전 placeholder - `CLAUDE.md` 1절
   확인 필요)·`subscription_id`(기본값 없음)
3. `live/hub/networking/providers.tf` - 최소 `azurerm` provider 블록 + `require_oidc` 변수 +
   `terraform_data.require_oidc_guard`(위 6절)
4. `live/hub/networking/main.tf` - CIDR locals + `module "vnet"` 블록(위 2~7절 값 그대로)
5. `live/hub/networking/outputs.tf` - `vnet_id`·`address_space`·`subnet_ids_by_group`·
   `nat_gateway_id` 등 모듈 출력 재노출(AWS `outputs.tf`와 같은 목적 - "계약이 살아있다"의 증거)
6. `live/hub/networking/backend.tf` - 빈 partial config
7. `live/hub/networking/backend.hcl.example` - 형태만 보여주는 예시(실제 Storage Account 이름
   없이 `st<workload><env><8자리hex>` placeholder)
8. 문서 갱신: `CLAUDE.md` 5절 저장소 구조 표의 `live/hub/networking/` 행을 "생성됨"으로,
   6절 다음 세션 할 일에 이번 작업 완료 반영

## 사용자 확정 사항 (승인 완료, 2026-08-27)

- **로컬 apply 방어**: CI(OIDC)만 허용하도록 `require_oidc` 가드를 추가한다(위 6절
  `terraform_data.require_oidc_guard`). 확정 완료.
- **`repository` 변수 기본값**: placeholder(`skax-ca/aks-reference-infra`) 유지. GitHub repo
  생성 시점에 실제 값으로 고친다. 확정 완료.
- **실행 승인**: execute로 바로 구현 진행. 확정 완료.

## 검증 단계

1. `tofu init -backend=false` + `tofu validate` - 로컬에서 backend 없이 문법·타입 검증
   (AWS 원본 README가 명시한 "로컬에서 가능한 것은 init -backend=false와 validate까지" 패턴을
   그대로 따른다 - 이 repo는 로컬 apply를 막지 않기로 했지만(6절), 최초 검증은 굳이 실제
   backend를 안 걸어도 되는 이 방식으로 충분하다)
2. `tofu init -backend-config=backend.hcl` - 사용자가 준비한 로컬 backend.hcl로 실제 init
3. `tofu plan` - 사람이 직접 실행, add-only(신규 vnet이므로 전부 create)인지 확인
4. `tofu apply` 1회차 - 사람이 직접 승인 후 실행
5. `tofu plan` 2회차 - No changes 확인(멱등성, AWS 원본이 자동 태거 방어에서 쓴 것과 같은
   판정 기준)
