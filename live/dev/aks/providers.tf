# provider 설정 + CI 전용 인증 가드.
#
# ⚠️ AWS 원본의 assume_role(OIDC 2단 체인 2단째) 같은 블록이 여기 없다. 이 repo의 CI
#    신원은 그 체인 없이 구독 권한을 직접 갖는다. azurerm provider는 ARM_CLIENT_ID·
#    ARM_TENANT_ID·ARM_SUBSCRIPTION_ID·ARM_USE_OIDC 환경변수를 자동으로 읽으므로 이
#    블록에 별도 인증 배선이 필요 없다.

provider "azapi" {
  # azurerm과 동일하게 ARM_CLIENT_ID·ARM_TENANT_ID·ARM_SUBSCRIPTION_ID·ARM_USE_OIDC
  # 환경변수를 자동으로 읽는다(registry.terraform.io/providers/Azure/azapi 공식
  # 문서 확인). 별도 인증 배선이 필요 없다. subscription_id만 다른 provider와
  # 동일하게 명시한다.
  subscription_id = var.subscription_id
}

provider "azurerm" {
  subscription_id = var.subscription_id

  # azurerm v5의 기본값은 이 배포와 무관한 "핵심" 프로바이더까지 plan 시작 시 등록하려
  # 시도하고, 그 등록이 끝날 때까지 plan이 몇 분씩 멈춘다. "none"으로 꺼서 그 지연을 없앤다.
  #
  # ⚠️ 이 root가 요구하는 RP(Microsoft.ContainerService·Compute·ManagedIdentity)는
  #    bootstrap.sh의 ensure_aks_resource_providers가 hub·spoke 공통으로 등록한다. 미등록
  #    상태라면 apply가 CI 스스로 복구할 수 없는 실패로 막히는 것이 정상 동작이다. "none"을
  #    되돌려서 풀 문제가 아니다.
  resource_provider_registrations = "none"

  features {}
}

# hub 구독을 향한 두 번째 provider(별칭). 이 root가 hub ArgoCD UAMI를 태그 기반으로
# 스스로 발견해, 자기 자신의 AKS 리소스에 role assignment를 직접 만들기 위함이다(hub가
# 스포크를 발견해 hub state 안에 만드는 방향은 쓰지 않는다. 근거는 main.tf의 해당 절).
# ARM_CLIENT_ID·ARM_TENANT_ID·ARM_USE_OIDC는 env에서 그대로 물려받고(위 기본 provider와
# 같은 dev CI 신원), subscription_id만 hub로 바꾼다. 이 신원은 bootstrap.sh
# (BOOTSTRAP_TARGET=spoke)가 hub 워크로드 리소스 그룹 스코프로 준 hub-peer 역할
# (UAMI read + RG read)을 갖는다. 같은 테넌트의 다른 구독이라 별도 federated credential·
# assume 체인이 필요 없다(live/hub/vwan/providers.tf의 alias="dev" 블록과 대칭).
provider "azurerm" {
  alias = "hub"

  subscription_id                 = var.hub_subscription_id
  resource_provider_registrations = "none"

  features {}
}

# ── CI 전용 인증 가드 ─────────────────────────────────────────────────────────
#
# AWS 원본은 실행 Role의 신뢰 정책이 GitHub Actions OIDC 하나만 허용해 로컬 plan/apply가
# 물리적으로 막혀 있다(개인 IAM user로는 assume 자체가 안 된다). 이 repo의 CI 신원은
# 그런 체인이 없어 provider 최소 배선만으로는 개인 az login으로도 로컬 apply가 그대로
# 성립해버린다. 그 차이를 메우는 것이 이 가드다.
#
# ⚠️ 인증 방식(ARM_USE_OIDC 등 환경변수)을 이 조건에서 직접 읽지 않는다. Terraform/
# OpenTofu 언어에는 임의 환경변수를 읽는 함수가 없다(getenv를 부르면 "Call to unknown
# function"으로 실패한다). 대신 CI 워크플로만 명시적으로 심어주는 var.ci_run으로 우회한다.
#
# ⚠️ 이 가드는 apply만 막는다. precondition은 파괴 대상 리소스에 평가되지 않아 로컬
# destroy는 막지 못한다. 로컬 destroy의 실제 방어선은 state 백엔드 RBAC다
# (allowSharedKeyAccess=false + Blob 데이터 역할이 CI SP 전용).
#
# terraform_data(provider 없는 내장 리소스)를 쓴 이유: 이 검사는 어떤 클라우드 API도 부르지
# 않는 순수 변수 값 검사라, 별도 provider(null/terraform)를 추가로 선언할 이유가 없다.
resource "terraform_data" "require_oidc_guard" {
  lifecycle {
    precondition {
      condition     = !var.require_oidc || var.ci_run
      error_message = "CI(GitHub Actions) 경로가 아니면 apply할 수 없다(var.ci_run이 설정되지 않음). 의도적 로컬 검증이면 -var=\"require_oidc=false\"를 명시한다."
    }
  }
}
