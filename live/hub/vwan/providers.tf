# provider 설정 + CI 전용 인증 가드.
#
# ⚠️ AWS 원본의 assume_role(OIDC 2단 체인 2단째) 같은 블록이 여기 없다 — 이 repo의 bootstrap
#    신원은 그 체인 자체가 없다(CI 신원이 직접 RG 스코프 커스텀 역할을 가짐, CLAUDE.md 4절).
#    azurerm provider는 ARM_CLIENT_ID·ARM_TENANT_ID·ARM_SUBSCRIPTION_ID·ARM_USE_OIDC 환경변수를
#    자동으로 읽으므로 이 블록에 별도 인증 배선이 필요 없다.

provider "azurerm" {
  subscription_id = var.subscription_id

  # azurerm v5의 기본값은 계정에 없는 "핵심" 프로바이더 집합(Microsoft.Cache·
  # Microsoft.ServiceBus 등, 이 배포와 무관한 것 포함)을 plan 시작 시 자동 등록하려
  # 시도한다. bootstrap의 CI 신원은 워크로드 RG 스코프 커스텀 역할만 가져(CLAUDE.md 4절)
  # 구독 스코프 등록 권한(*/register/action)이 없다 — 실측 확인(2026-08-27, 첫 hub CI plan이
  # 이 자동 등록 시도로 9분 넘게 멈춰 있었다. az provider list로 Microsoft.Cache·
  # Microsoft.ServiceBus가 NotRegistered임을 직접 확인). "none"으로 꺼서 이 배포가 실제로
  # 쓰는 Microsoft.Network만 조회하게 한다 — 이미 등록돼 있어 문제가 없다.
  resource_provider_registrations = "none"

  features {}
}

# 2026-09-08 신설 — dev 구독을 향한 두 번째 provider(별칭). ARM_CLIENT_ID·
# ARM_TENANT_ID·ARM_USE_OIDC는 env에서 그대로 물려받고(위 기본 provider와 같은
# hub CI 신원), subscription_id만 dev로 바꾼다. 이 신원은 bootstrap.sh
# (BOOTSTRAP_TARGET=spoke)가 dev 워크로드 RG 스코프로 준 spoke-peer 역할
# (peer/action + virtualNetworks/read, 2026-09-08 read 추가)을 이미 갖고 있다 —
# 같은 테넌트의 다른 구독이라 별도 federated credential·assume 체인이 필요 없다
# (AWS 원본의 cross-account trust 같은 게 필요 없는 이유, virtual-wan-faq: 같은
# 테넌트 간 연결은 RBAC만으로 성립하는 1급 시나리오).
provider "azurerm" {
  alias = "dev"

  subscription_id                 = var.dev_subscription_id
  resource_provider_registrations = "none"

  features {}
}

# ── CI 전용 인증 가드 ─────────────────────────────────────────────────────────
#
# AWS 원본은 실행 Role의 신뢰 정책이 GitHub Actions OIDC 하나만 허용해 로컬 plan/apply가
# 물리적으로 막혀 있었다(개인 IAM user로는 assume 자체가 안 됨). 이 repo의 bootstrap 신원은
# 그런 체인이 없어 provider 최소 배선만으로는 개인 az login으로도 로컬 apply가 그대로
# 성립해버린다 — 그 차이를 메우는 것이 이 가드다.
#
# ⚠️ 인증 방식(ARM_USE_OIDC 등 환경변수)을 이 조건에서 직접 읽지 않는다. Terraform/
# OpenTofu 언어에는 임의 환경변수를 읽는 함수가 없다(getenv 같은 함수는 존재하지 않는다 —
# 최초 설계가 이를 오인해 "Call to unknown function"으로 실패, 2026-08-27 hub CI 최초
# plan에서 실측). 대신 CI 워크플로만 명시적으로 심어주는 var.ci_run으로 우회한다.
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
