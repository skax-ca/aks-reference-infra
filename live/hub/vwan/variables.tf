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

variable "spoke_connections" {
  description = <<-EOT
    vHub에 연결할 스포크 VNet — 스포크 이름 → VNet 리소스 ID(전체 경로) 맵.

    기본값 `{}` — 스포크 연결 없이 vWAN·vHub·hub 연결만 먼저 세우는 1차 apply를
    지원한다(docs/decisions/live-hub-vwan-dev-networking.md 4-3 착수 순서). dev VNet이
    생기고 크로스 구독 role assignment(4-1)가 걸린 뒤 2차 apply에서
    `{ dev = "<dev VNet 리소스 ID>" }`를 CI 변수로 주입한다.

    ⛔ data source로 조회하지 않고 값을 그대로 받는다 — 조회하려면 dev 구독에
    virtualNetworks/read가 추가로 필요한데, hub CI 신원에게 그 권한까지 주지 않는다
    (크로스 구독 권한은 dev 쪽 peer/action 단일 액션 하나로 충분하다, 계획 문서 4-1).
  EOT
  type        = map(string)
  default     = {}
  nullable    = false
}
