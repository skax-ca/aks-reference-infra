# 이 루트의 변수는 두 종류다. 섞어 두면 "왜 이건 코드에 있고 저건 없나"가 흐려진다.
#
#   ① 코드에 기본값이 있는 것  — 노출돼도 무해하고, 고객사가 바꿀 토큰이다(workload·env·region)
#   ② 기본값이 **없는** 것      — 구독 식별 정보라 git 에 두지 않는다. CI 는 repo 변수
#                                (ARM_HUB_SUBSCRIPTION_ID), 로컬은 TF_VAR_* 환경변수로 주입한다
#
# live/hub/networking/variables.tf와 동일 구조다(같은 hub 구독의 다른 state root).

variable "workload" {
  description = <<-EOT
    워크로드 코드. 거버넌스 태그 Workload 의 값이자 리소스 naming 토큰이다.
    bootstrap/config.sh 의 WORKLOAD 와 정확히 같은 값이어야 한다.
  EOT
  type        = string
  default     = "demo"
}

variable "env" {
  description = "환경 코드. 이 루트는 env=\"hub\"로 논리적 환경을 가른다(live/hub/networking과 동일)."
  type        = string
  default     = "hub"
}

variable "region_code" {
  description = "Name 태그·naming 토큰에 쓰는 리전 약어. bootstrap/config.sh 의 REGION_CODE 와 같다."
  type        = string
  default     = "krc"
}

variable "location" {
  description = "Azure 리전. region_code 와 짝이 맞아야 한다(krc ↔ koreacentral)."
  type        = string
  default     = "koreacentral"
}

variable "repository" {
  description = "거버넌스 태그 Repository 값. 리소스에서 이 repo 로 역추적하는 경로다."
  type        = string
  default     = "skax-ca/aks-reference-infra"
}

variable "subscription_id" {
  description = <<-EOT
    apply 대상 Azure 구독 ID(hub). live/hub/networking과 같은 구독이다.

    ⛔ 기본값을 두지 않는다 — 구독 식별 정보라 git 에 두지 않는다. 주입 경로는 둘 다 git 밖이다:
       CI   : GitHub repo 변수 AZURE_HUB_SUBSCRIPTION_ID → ARM_SUBSCRIPTION_ID
       로컬 : export TF_VAR_subscription_id=...
  EOT
  type        = string
}

variable "require_oidc" {
  description = <<-EOT
    true면 var.ci_run이 true가 아닐 때 plan/apply 자체를 막는다(로컬 az login 인증 경로
    차단). live/hub/networking/variables.tf와 동일 근거 — Terraform/OpenTofu 언어에는
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

variable "dev_subscription_id" {
  description = <<-EOT
    dev(스포크) 구독 ID. live/hub/vwan이 dev VNet을 태그 기반으로 자동 발견할 때
    쓰는 두 번째 provider(azurerm.dev, providers.tf)의 subscription_id다
    (2026-09-08, CI 변수 직접 주입에서 data source 자동 발견으로 전환하며 신설).

    ⛔ 기본값을 두지 않는다 — 구독 식별 정보라 git 에 두지 않는다. 주입 경로:
       CI   : GitHub repo 변수 AZURE_DEV_SUBSCRIPTION_ID → TF_VAR_dev_subscription_id
              (live/dev/networking이 이미 쓰는 것과 같은 값, 재사용이다)
       로컬 : export TF_VAR_dev_subscription_id=...
  EOT
  type        = string
}
