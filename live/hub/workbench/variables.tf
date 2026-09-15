# 이 루트의 변수는 두 종류다. 섞어 두면 "왜 이건 코드에 있고 저건 없나"가 흐려진다.
#
#   ① 코드에 기본값이 있는 것: 노출돼도 무해하고, 고객사가 바꿀 토큰이다(workload·env·region)
#   ② 기본값이 **없는** 것: 구독 식별 정보·개인 식별자·유동적인 값이라 git 에 두지 않는다.
#                                CI 는 repo 변수, 로컬은 TF_VAR_* 환경변수로 주입한다
#
# live/hub/aks/variables.tf와 동일 구조다(같은 hub 구독의 다른 state root).

variable "workload" {
  description = <<-EOT
    워크로드 코드. 거버넌스 태그 Workload 의 값이자 리소스 naming 토큰이다.
    bootstrap/config.sh 의 WORKLOAD 와 정확히 같은 값이어야 한다.
  EOT
  type        = string
  default     = "demo"
}

variable "env" {
  description = "환경 코드. 이 루트는 env=\"hub\"로 논리적 환경을 가른다(live/hub/aks와 동일)."
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
    apply 대상 Azure 구독 ID(hub). live/hub/networking·live/hub/vwan·live/hub/aks와 같은
    구독이다.

    ⛔ 기본값을 두지 않는다. 구독 식별 정보라 git 에 두지 않는다. 주입 경로는 둘 다 git 밖이다:
       CI   : GitHub repo 변수 AZURE_HUB_SUBSCRIPTION_ID → ARM_SUBSCRIPTION_ID
       로컬 : export TF_VAR_subscription_id=...
  EOT
  type        = string
}

variable "require_oidc" {
  description = <<-EOT
    true면 var.ci_run이 true가 아닐 때 plan/apply 자체를 막는다(로컬 az login 인증 경로
    차단). live/hub/aks/variables.tf와 동일 근거.
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

# ── workbench 고유 변수 ────────────────────────────────────────────────────────

variable "ssh_ingress_cidrs" {
  description = <<-EOT
    SSH(22/tcp) 인바운드를 허용할 CIDR 목록(aks-workbench 모듈로 그대로 전달). 사무실/재택
    공인 IP는 시간에 따라 바뀌므로 subscription_id와 같은 이유로 git에 기본값을 두지 않는다.

    CI   : GitHub repo 변수 AZURE_HUB_WORKBENCH_SSH_CIDRS(JSON 배열 문자열, 예: ["1.2.3.4/32"])
    로컬 : export TF_VAR_ssh_ingress_cidrs='["1.2.3.4/32"]'
  EOT
  type        = list(string)

  validation {
    # 형식만 검증한다(진짜 CIDR인지, 즉 호스트 비트가 0인지는 안 본다). plan 단계에서
    # 잡아야 할 것은 "AllowSsh NSG 규칙이 명백히 깨진 문자열로 만들어지는 사고"이지, 유효한
    # 축소 표기(예: 1.2.3.4/24, 호스트 비트 켜짐)까지 막을 이유는 없다(Azure NSG가 그 값을
    # 그대로 받아들인다).
    condition = alltrue([
      for cidr in var.ssh_ingress_cidrs : can(regex("^\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}\\.\\d{1,3}/\\d{1,2}$", cidr))
    ])
    error_message = "ssh_ingress_cidrs의 각 항목은 IPv4 CIDR 표기(예: \"1.2.3.4/32\")여야 한다."
  }
}

variable "workbench_enabled" {
  description = <<-EOT
    aks-workbench 모듈의 kill switch(파괴 방향)를 그대로 통과시킨다. false면 이 root가
    만드는 identity·role assignment는 남긴 채 VM만 파기한다(모듈 README:
    "AWS workbench와 동일하게 삭제 보호 대상이 아니다, 수시 생성·파기가 정상 운용이다").
  EOT
  type        = bool
  default     = true
  nullable    = false
}

variable "admin_login_principal_id" {
  description = <<-EOT
    Virtual Machine Administrator Login 역할을 받을 Entra 계정(사람)의 objectId
    (`az ad signed-in-user show --query id` 등으로 확인). subscription_id와 같은 이유로
    git에 기본값을 두지 않는다.

    CI   : GitHub repo 변수 AZURE_HUB_WORKBENCH_ADMIN_OBJECT_ID
    로컬 : export TF_VAR_admin_login_principal_id=...
  EOT
  type        = string
}
