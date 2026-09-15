# ⛔ 이 블록은 비어 있어야 한다. partial backend configuration이다.
#
# Storage Account 명이 git 에 존재하지 않는 것이 요구사항이다(bootstrap/README.md "기대 상태"
# 절. 이름의 소재는 git 이 아니라 GitHub repo 변수 또는 로컬 backend.hcl).
#
# 주입 경로 (둘 다 git 밖):
#   CI    : GitHub repo 변수 → tofu init -backend-config="storage_account_name=${{ vars.HUB_TF_STATE_ACCOUNT }}" ...
#   로컬  : gitignore 된 backend.hcl → tofu init -backend-config=backend.hcl (형태는 backend.hcl.example 참고)
#
# ⚠️ `storage_account_name = "..."` 를 여기 추가하면 그 순간 위 요구사항이 무너진다. init 실패는
#    버그가 아니라 -backend-config 를 빠뜨렸다는 신호다.
terraform {
  backend "azurerm" {}
}
