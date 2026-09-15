# 이 루트의 출력은 두 가지 일을 한다.
#   ① 하류 배포 루트(live/hub/vwan, Phase 2 AKS 등)가 참조할 앵커를 노출한다
#   ② 모듈 출력 계약이 실제로 소비되는지 보인다. map 키 접근까지 해야 계약이 동작함이
#      증명된다(모듈 repo examples/AGENTS.md 와 같은 기준)

output "vnet_id" {
  description = "생성된 VNet ID. live/hub/vwan 이 Virtual WAN Hub 연결에 참조한다."
  value       = module.vnet.vnet_id
}

output "vnet_name" {
  description = "VNet 이름."
  value       = module.vnet.vnet_name
}

output "address_space" {
  description = "VNet 주소 공간."
  value       = module.vnet.address_space
}

output "subnet_ids_by_group" {
  description = "그룹 키 → 서브넷 ID. 키는 이 루트가 넘긴 subnet_groups 키 그대로다."
  value       = module.vnet.subnet_ids_by_group
}

# 소비자가 실제로 하는 일: 자기가 준 키로 되받아 하류 모듈에 넘긴다.
# 모듈이 키를 변형하지 않기 때문에 이 접근이 예측 가능하다.
output "aks_node_subnet_id" {
  description = "Phase 2 AKS 노드를 놓을 서브넷 ID. AKS 배포 루트에 그대로 넘기는 형태다."
  value       = module.vnet.subnet_ids_by_group["aks-node"]
}

# 운영 라우트의 앵커. hub↔spoke 라우트는 live/hub/vwan 연결 후 여기 얹는다.
output "route_table_ids_by_group" {
  description = "그룹 키 → 라우팅 테이블 ID. route_table_enabled = true 인 그룹만 키가 있다."
  value       = module.vnet.route_table_ids_by_group
}

output "nat_gateway_id" {
  description = "NAT Gateway ID. vm·aks-node 그룹이 nat_routed = true 라 생성된다."
  value       = module.vnet.nat_gateway_id
}

output "nsg_ids_by_group" {
  description = "그룹 키 → NSG ID. NSG 룰은 이 root 또는 하류가 azurerm_network_security_rule 로 얹는다."
  value       = module.vnet.nsg_ids_by_group
}
