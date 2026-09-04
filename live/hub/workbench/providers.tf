# provider 설정 + CI 전용 인증 가드.
#
# live/hub/aks/providers.tf와 완전히 동일한 근거(같은 hub 구독, 같은 CI 신원) — 이 root
# 고유의 변경 사유가 없어 그대로 복제한다.

provider "azurerm" {
  subscription_id = var.subscription_id

  # live/hub/networking·live/hub/vwan·live/hub/aks와 동일 근거로 자동 등록을 끈다: CI 신원은
  # 이 배포와 무관한 프로바이더까지 plan 시작 시 등록하려 시도해 멈추는 걸 막는다
  # (2026-08-27 hub 첫 CI plan 실측, live/hub/aks/providers.tf 참고).
  resource_provider_registrations = "none"

  features {}
}

# ── CI 전용 인증 가드 ─────────────────────────────────────────────────────────
#
# live/hub/aks/providers.tf와 동일한 가드 — 로컬 az login으로도 apply가 성립해버리는 것을
# 막는다. terraform_data(provider 없는 내장 리소스)를 쓰는 이유도 동일(순수 변수 값 검사).
resource "terraform_data" "require_oidc_guard" {
  lifecycle {
    precondition {
      condition     = !var.require_oidc || var.ci_run
      error_message = "CI(GitHub Actions) 경로가 아니면 apply할 수 없다(var.ci_run이 설정되지 않음). 의도적 로컬 검증이면 -var=\"require_oidc=false\"를 명시한다."
    }
  }
}
