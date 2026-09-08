# 하류 배포 루트(live/dev/networking의 크로스 구독 role assignment 스코프 확인,
# Phase 2 AKS 등)가 참조할 앵커를 노출한다.

output "virtual_wan_id" {
  description = "생성된 Virtual WAN ID."
  value       = azurerm_virtual_wan.this.id
}

output "virtual_hub_id" {
  description = "생성된 Virtual WAN Hub ID. 스포크 연결(azurerm_virtual_hub_connection)이 참조한다."
  value       = azurerm_virtual_hub.this.id
}

output "virtual_hub_address_prefix" {
  description = "vHub 주소 공간. 생성 후 변경 불가 — 참조만 하고 재계산하지 않는다."
  value       = azurerm_virtual_hub.this.address_prefix
}

output "hub_connection_id" {
  description = "hub VNet ↔ vHub 연결 ID."
  value       = azurerm_virtual_hub_connection.hub.id
}

output "spoke_connection_ids" {
  description = "스포크 이름 → 연결 ID. local.spoke_connections(태그 기반 자동 발견)가 빈 맵이면 빈 맵이다."
  value       = { for k, v in azurerm_virtual_hub_connection.spoke : k => v.id }
}

output "argocd_identity_client_id" {
  description = <<-EOT
    hub ArgoCD Workload Identity의 client ID. `aks-platform-gitops`의
    `bootstrap/argocd-values.yaml`(controller·server ServiceAccount의
    `azure.workload.identity/client-id` 애노테이션)에 수동으로 옮겨 적는다 —
    이 값은 이 root의 state 밖(다른 저장소)이라 자동 배선하지 않는다.
  EOT
  value       = azurerm_user_assigned_identity.argocd.client_id
}

output "argocd_identity_principal_id" {
  description = "hub ArgoCD Workload Identity의 principal ID. dev(spoke) AKS role assignment의 principal_id로 쓴다."
  value       = azurerm_user_assigned_identity.argocd.principal_id
}
