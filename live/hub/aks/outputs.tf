# 후속 계획(workbench·aks-platform-gitops)이 참조할 앵커를 노출한다.
#
# ⚠️ 모듈의 출력은 null-safe 다 — cluster_enabled = false 로 파기하면 스칼라는 null 이
#    된다. 참조 대상이 사라진 뒤에도 소비자 plan 이 통과해야 파기가 성립하기 때문이다.

output "cluster_id" {
  description = "AKS 클러스터 리소스 ID."
  value       = module.aks_cluster.cluster_id
}

output "cluster_name" {
  description = "AKS 클러스터 이름. az aks show·az aks command invoke 의 -n 인자로 쓴다."
  value       = module.aks_cluster.cluster_name
}

output "oidc_issuer_url" {
  description = <<-EOT
    OIDC issuer URL. Workload Identity Federation 배선의 원시 재료다 — 모듈은
    federated identity credential 을 만들지 않는다. workload_identity_enabled 값과
    무관하게 항상 나가므로, 나중에 켤 때 클러스터 재생성이 필요 없다.
  EOT
  value       = module.aks_cluster.oidc_issuer_url
}

output "node_resource_group" {
  description = <<-EOT
    AKS 가 노드 리소스(VMSS·NIC 등)를 자동 생성하는 리소스 그룹 이름. 노드가 실제로
    aks-node 서브넷에 join 했는지 확인할 때 진입점이다(docs/decisions/live-hub-aks.md 완료 판정 #6).
  EOT
  value       = module.aks_cluster.node_resource_group
}
