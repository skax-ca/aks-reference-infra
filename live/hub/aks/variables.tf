# 이 루트의 변수는 두 종류다. 섞어 두면 "왜 이건 코드에 있고 저건 없나"가 흐려진다.
#
#   ① 코드에 기본값이 있는 것: 노출돼도 무해하고, 고객사가 바꿀 토큰이다(workload·env·region)
#   ② 기본값이 **없는** 것: 구독 식별 정보이거나 bootstrap 산출물이라 git 에 두지 않는다.
#                                CI 는 repo 변수, 로컬은 TF_VAR_* 환경변수로 주입한다
#
# live/hub/vwan/variables.tf와 동일 구조다(같은 hub 구독의 다른 state root).

variable "workload" {
  description = <<-EOT
    워크로드 코드. 거버넌스 태그 Workload 의 값이자 리소스 naming 토큰이다.
    bootstrap/config.sh 의 WORKLOAD 와 정확히 같은 값이어야 한다.
  EOT
  type        = string
  default     = "demo"
  nullable    = false
}

variable "env" {
  description = "환경 코드. 이 루트는 env=\"hub\"로 논리적 환경을 가른다(live/hub/networking과 동일)."
  type        = string
  default     = "hub"
  nullable    = false
}

variable "region_code" {
  description = "Name 태그·naming 토큰에 쓰는 리전 약어. bootstrap/config.sh 의 REGION_CODE 와 같다."
  type        = string
  default     = "krc"
  nullable    = false
}

variable "location" {
  description = "Azure 리전. region_code 와 짝이 맞아야 한다(krc ↔ koreacentral)."
  type        = string
  default     = "koreacentral"
  nullable    = false
}

variable "repository" {
  description = "거버넌스 태그 Repository 값. 리소스에서 이 repo 로 역추적하는 경로다."
  type        = string
  default     = "skax-ca/aks-reference-infra"
  nullable    = false
}

variable "subscription_id" {
  description = <<-EOT
    apply 대상 Azure 구독 ID(hub). live/hub/networking·live/hub/vwan과 같은 구독이다.

    ⛔ 기본값을 두지 않는다. 구독 식별 정보라 git 에 두지 않는다. 주입 경로는 둘 다 git 밖이다:
       CI   : GitHub repo 변수 AZURE_HUB_SUBSCRIPTION_ID → ARM_SUBSCRIPTION_ID
       로컬 : export TF_VAR_subscription_id=...
  EOT
  type        = string
  nullable    = false
}

variable "require_oidc" {
  description = <<-EOT
    true면 var.ci_run이 true가 아닐 때 plan/apply 자체를 막는다(로컬 az login 인증 경로
    차단). live/hub/networking/variables.tf와 동일 근거다. Terraform/OpenTofu 언어에는
    getenv 같은 함수가 없어 var.ci_run으로 우회한다.
  EOT
  type        = bool
  default     = true
  nullable    = false
}

variable "ci_run" {
  description = "CI 워크플로가 TF_VAR_ci_run=true로만 설정하는 신호값. 로컬 실행에서는 항상 false."
  type        = bool
  default     = false
  nullable    = false
}

# aks_identity_id 변수는 두지 않는다. CI 신원(App Registration)이 구독 전체 Owner
# 등가라 이 root가 자기 identity를 azurerm_user_assigned_identity로 직접 만든다(main.tf
# 참고). bootstrap이 만든 identity를 변수로 넘겨받지 않는다.
