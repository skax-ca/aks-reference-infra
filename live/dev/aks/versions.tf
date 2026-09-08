# 배포 루트는 **상한을 건다**. 모듈은 하한만 선언하고(azurerm >= 5.0), 상한은 루트가
# .terraform.lock.hcl 과 함께 통제한다 — 이 규약은 모듈 repo의 docs/가 소유한다.
terraform {
  # 하한 1.12.0 은 모듈이 요구하는 값 그대로다(modules/azure/aks-cluster/versions.tf).
  required_version = ">= 1.12.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 5.0"
    }
    # azurerm이 아직 노출하지 않는 ingressProfile 필드(App Routing Gateway API/Istio)를
    # azurerm 관리 클러스터 위에 얹기 위해서만 쓴다 — azapi-primary 전환이 아니다
    # (main.tf의 azapi_update_resource 헤더 주석 참고, Microsoft 공식 가이드가 이
    # 조합을 정식 권장한다).
    azapi = {
      source  = "Azure/azapi"
      version = "~> 2.0"
    }
  }
}
