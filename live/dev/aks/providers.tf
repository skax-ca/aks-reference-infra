# provider 설정 + CI 전용 인증 가드.
#
# ⚠️ AWS 원본의 assume_role(OIDC 2단 체인 2단째) 같은 블록이 여기 없다 — 이 repo의 bootstrap
#    신원은 그 체인 자체가 없다(CI 신원이 직접 RG 스코프 커스텀 역할을 가짐, CLAUDE.md 2절).
#    azurerm provider는 ARM_CLIENT_ID·ARM_TENANT_ID·ARM_SUBSCRIPTION_ID·ARM_USE_OIDC 환경변수를
#    자동으로 읽으므로 이 블록에 별도 인증 배선이 필요 없다.

provider "azapi" {
  # azurerm과 동일하게 ARM_CLIENT_ID·ARM_TENANT_ID·ARM_SUBSCRIPTION_ID·ARM_USE_OIDC
  # 환경변수를 자동으로 읽는다(registry.terraform.io/providers/Azure/azapi 공식
  # 문서 확인) — 별도 인증 배선이 필요 없다. subscription_id만 다른 provider와
  # 동일하게 명시한다.
  subscription_id = var.subscription_id
}

provider "azurerm" {
  subscription_id = var.subscription_id

  # live/dev/networking·live/hub/aks와 동일 근거로 자동 등록을 끈다: azurerm v5의 기본값은
  # 이 배포와 무관한 "핵심" 프로바이더까지 plan 시작 시 등록하려 시도해 멈춘다
  # (2026-08-27 hub 첫 CI plan 실측 — 그 시점 CI 신원은 구독 스코프 등록 권한이
  # 없었다. 지금은 구독 전체 Owner라 권한 자체는 있지만, 무관한 RP를 매 plan마다
  # 훑는 지연 자체가 없어지는 게 이 설정의 실익이다).
  #
  # ⚠️ 이 root가 요구하는 Microsoft.ContainerService는 bootstrap 단계에서 사람이 사전
  #    등록한다(bootstrap/bootstrap.sh의 ensure_container_service_provider — 2026-09-08부로
  #    hub·spoke 공통으로 무조건 실행된다). 미등록 상태라면 apply가 CI 스스로
  #    복구할 수 없는 실패로 막히는 것이 정상 동작이다 — "none"을 되돌려서 풀 문제가 아니다.
  resource_provider_registrations = "none"

  features {}
}

# 2026-09-10 신설 — hub 구독을 향한 두 번째 provider(별칭). hub-argocd-rbac-direction-flip
# plan(.omc/plans/hub-argocd-rbac-direction-flip.md) 2.1절: 이 root가 hub ArgoCD UAMI를
# 태그 기반으로 스스로 발견해, 자기 자신의 AKS 리소스에 role assignment를 직접 만들기
# 위함이다(live/hub/vwan이 스포크를 발견해 hub state 안에 role assignment를 만들던 기존
# 방향의 반전이자 대체, live/hub/vwan/main.tf의 argocd_spoke_aks_access 참고). ARM_CLIENT_ID·
# ARM_TENANT_ID·ARM_USE_OIDC는 env에서 그대로 물려받고(위 기본 provider와 같은 dev CI
# 신원), subscription_id만 hub로 바꾼다. 이 신원은 bootstrap.sh(BOOTSTRAP_TARGET=spoke)가
# hub 워크로드 리소스 그룹 스코프로 줄 hub-peer 역할(UAMI read + RG read, plan 5절)을
# 가정한다 — 같은 테넌트의 다른 구독이라 별도 federated credential·assume 체인이 필요
# 없다(live/hub/vwan/providers.tf의 alias="dev" 블록과 동일 근거, 대칭 패턴).
provider "azurerm" {
  alias = "hub"

  subscription_id                 = var.hub_subscription_id
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
