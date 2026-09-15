# provider 설정 + CI 전용 인증 가드.
#
# ⚠️ AWS 원본의 assume_role(OIDC 2단 체인 2단째) 같은 블록이 여기 없다. 이 repo의 CI
#    신원은 그 체인 없이 구독 권한을 직접 갖는다. azurerm provider는 ARM_CLIENT_ID·
#    ARM_TENANT_ID·ARM_SUBSCRIPTION_ID·ARM_USE_OIDC 환경변수를 자동으로 읽으므로 이
#    블록에 별도 인증 배선이 필요 없다.

provider "azurerm" {
  subscription_id = var.subscription_id

  # azurerm v5의 기본값은 계정에 없는 "핵심" 프로바이더 집합(Microsoft.Cache·
  # Microsoft.ServiceBus 등, 이 배포와 무관한 것 포함)을 plan 시작 시 자동 등록하려
  # 시도하고, 그 등록이 끝날 때까지 plan이 몇 분씩 멈춘다. "none"으로 꺼서 이 배포가
  # 실제로 쓰는 RP만 조회하게 한다. 이 루트가 요구하는 RP는 bootstrap.sh가 미리 등록한다.
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
