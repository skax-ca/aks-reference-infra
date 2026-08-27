# provider 설정 + CI 전용 인증 가드.
#
# ⚠️ AWS 원본의 assume_role(OIDC 2단 체인 2단째) 같은 블록이 여기 없다 — 이 repo의 bootstrap
#    신원은 그 체인 자체가 없다(CI 신원이 직접 RG 스코프 커스텀 역할을 가짐, CLAUDE.md 4절).
#    azurerm provider는 ARM_CLIENT_ID·ARM_TENANT_ID·ARM_SUBSCRIPTION_ID·ARM_USE_OIDC 환경변수를
#    자동으로 읽으므로 이 블록에 별도 인증 배선이 필요 없다.

provider "azurerm" {
  subscription_id = var.subscription_id

  features {}
}

# ── CI 전용 인증 가드 ─────────────────────────────────────────────────────────
#
# AWS 원본은 실행 Role의 신뢰 정책이 GitHub Actions OIDC 하나만 허용해 로컬 plan/apply가
# 물리적으로 막혀 있었다(개인 IAM user로는 assume 자체가 안 됨). 이 repo의 bootstrap 신원은
# 그런 체인이 없어 provider 최소 배선만으로는 개인 az login으로도 로컬 apply가 그대로
# 성립해버린다 — 그 차이를 메우는 것이 이 가드다.
#
# terraform_data(provider 없는 내장 리소스)를 쓴 이유: 이 검사는 어떤 클라우드 API도 부르지
# 않는 순수 환경변수 검사라, 별도 provider(null/terraform)를 추가로 선언할 이유가 없다.
resource "terraform_data" "require_oidc_guard" {
  lifecycle {
    precondition {
      condition     = !var.require_oidc || nonsensitive(getenv("ARM_USE_OIDC")) == "true"
      error_message = "ARM_USE_OIDC=true가 아닌 인증 경로(로컬 az login 등)로는 apply할 수 없다. CI(GitHub Actions OIDC)에서 실행하거나, 의도적 로컬 검증이면 -var=\"require_oidc=false\"를 명시한다."
    }
  }
}
