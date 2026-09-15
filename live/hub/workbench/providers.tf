# provider 설정 + CI 전용 인증 가드.
#
# live/hub/aks/providers.tf와 같은 근거(같은 hub 구독, 같은 CI 신원)다. 이 root
# 고유의 변경 사유가 없어 그대로 복제한다.

provider "azurerm" {
  subscription_id = var.subscription_id

  # azurerm v5의 기본값은 이 배포와 무관한 "핵심" 프로바이더까지 plan 시작 시 등록하려
  # 시도하고, 그 등록이 끝날 때까지 plan이 몇 분씩 멈춘다. "none"으로 꺼서 그 지연을 없앤다.
  resource_provider_registrations = "none"

  features {}
}

# ── CI 전용 인증 가드 ─────────────────────────────────────────────────────────
#
# live/hub/aks/providers.tf와 동일한 가드다. 로컬 az login으로도 apply가 성립해버리는 것을
# 막는다. terraform_data(provider 없는 내장 리소스)를 쓰는 이유도 동일(순수 변수 값 검사).
resource "terraform_data" "require_oidc_guard" {
  lifecycle {
    precondition {
      condition     = !var.require_oidc || var.ci_run
      error_message = "CI(GitHub Actions) 경로가 아니면 apply할 수 없다(var.ci_run이 설정되지 않음). 의도적 로컬 검증이면 -var=\"require_oidc=false\"를 명시한다."
    }
  }
}
