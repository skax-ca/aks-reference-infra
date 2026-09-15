# 이 루트의 변수는 두 종류다. 섞어 두면 "왜 이건 코드에 있고 저건 없나"가 흐려진다.
#
#   ① 코드에 기본값이 있는 것: 노출돼도 무해하고, 고객사가 바꿀 토큰이다(workload·env·region)
#   ② 기본값이 **없는** 것: 구독 식별 정보라 git 에 두지 않는다. CI 는 repo 변수
#                                (ARM_SUBSCRIPTION_ID), 로컬은 TF_VAR_* 환경변수로 주입한다

variable "workload" {
  description = <<-EOT
    워크로드 코드. 거버넌스 태그 Workload 의 값이자 모듈 naming 인자의 토큰이다.
    bootstrap/config.sh 의 WORKLOAD 와 정확히 같은 값이어야 한다(rg-<workload>-<env>-krc-
    workload-01 을 이 root 가 resource_group_name 으로 그대로 참조하기 때문).
  EOT
  type        = string
  default     = "demo"
}

variable "env" {
  description = <<-EOT
    환경 코드. 이 루트는 env="hub"로 논리적 환경을 가른다.
    ⚠️ hub 는 team 구독, live/dev(spoke 첫 인스턴스)는 별도 구독이다. 계정도 분리돼 있다.
  EOT
  type        = string
  default     = "hub"
}

variable "region_code" {
  description = "Name 태그·naming 인자에 쓰는 리전 약어. bootstrap/config.sh 의 REGION_CODE 와 같다."
  type        = string
  default     = "krc"
}

variable "location" {
  description = "Azure 리전. region_code 와 짝이 맞아야 한다(krc ↔ koreacentral)."
  type        = string
  default     = "koreacentral"
}

variable "repository" {
  description = <<-EOT
    거버넌스 태그 Repository 값. 리소스에서 이 repo 로 역추적하는 경로다.
    리소스 태그에 그대로 들어가므로 저장소를 옮기면 이 값도 바꾼다.
  EOT
  type        = string
  default     = "skax-ca/aks-reference-infra"
}

variable "subscription_id" {
  description = <<-EOT
    apply 대상 Azure 구독 ID.

    ⛔ 기본값을 두지 않는다. 구독 식별 정보라 git 에 두지 않는다. 주입 경로는 둘 다 git 밖이다:
       CI   : GitHub repo 변수 AZURE_SUBSCRIPTION_ID → ARM_SUBSCRIPTION_ID (azurerm 이 직접 읽음)
       로컬 : export TF_VAR_subscription_id=...

    provider 에 명시로 배선하는 이유는 "잘못된 구독에 apply" 실수를 막기 위해서다. az CLI
    컨텍스트의 기본 구독에 암묵적으로 의존하지 않는다.
  EOT
  type        = string
}

variable "require_oidc" {
  description = <<-EOT
    true면 var.ci_run이 true가 아닐 때 plan/apply 자체를 막는다(로컬 az login 인증 경로
    차단). Terraform/OpenTofu 언어에는 임의 환경변수를 직접 읽는 함수가 없어 인증 방식
    자체를 introspect하지 못하므로, CI 워크플로만 명시적으로 심어주는 변수(var.ci_run)로
    우회한다. 로컬 검증이 필요한 드문 경우에만 -var="require_oidc=false"로 명시적으로
    낮춘다. 기본값은 항상 켜져 있어야 한다.
  EOT
  type        = bool
  default     = true
  nullable    = false
}

variable "ci_run" {
  description = <<-EOT
    CI 워크플로가 TF_VAR_ci_run=true로만 설정하는 신호값. 로컬 실행에서는 항상 false
    (기본값)다. require_oidc 가드가 "이 apply가 CI에서 왔는가"를 판단하는 유일한 근거이니
    로컬에서 이 값을 직접 true로 넘기지 않는다. 가드 자체를 무력화하는 것과 같다.
  EOT
  type        = bool
  default     = false
  nullable    = false
}
