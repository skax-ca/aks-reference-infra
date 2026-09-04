# 배포 루트는 **상한을 건다**. 모듈은 하한만 선언하고(azurerm >= 5.0), 상한은 루트가
# .terraform.lock.hcl 과 함께 통제한다 — 이 규약은 모듈 repo의 docs/가 소유한다.
terraform {
  # 하한 1.12.0 은 모듈이 요구하는 값 그대로다(modules/azure/aks-workbench/versions.tf).
  required_version = ">= 1.12.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
  }
}
