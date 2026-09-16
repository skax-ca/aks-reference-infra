# tflint 설정. 컨벤션·provider 오류 정적 검사(로컬 게이트)
# 실행: tflint --init (플러그인 설치, clone마다 1회) → tflint --recursive
#
# ⚠️ 버전 핀을 iac-module-library 와 **같게 유지한다**(azurerm 0.32.0).
# 다르면 같은 코드에서 다른 지적이 나와 "모듈 repo는 통과했는데 여기서 막힌다"가 된다.
# aws ruleset은 넣지 않는다. 이 repo에 aws provider가 없다.

plugin "terraform" {
  enabled = true
  preset  = "recommended" # 미사용 선언·deprecated 문법·네이밍 컨벤션 등
}

plugin "azurerm" {
  enabled = true
  version = "0.32.0" # 정확 핀
  source  = "github.com/terraform-linters/tflint-ruleset-azurerm"
}
