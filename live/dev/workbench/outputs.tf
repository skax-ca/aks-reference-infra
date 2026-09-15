# 운영자가 SSH 접속에 바로 쓸 앵커를 노출한다.
#
# ⚠️ 모듈의 출력은 null-safe 다. workbench_enabled=false로 파기하면 스칼라는 null이 된다.

output "workbench_private_ip" {
  description = "workbench VM의 사설 IP."
  value       = module.aks_workbench.workbench_private_ip
}

output "workbench_public_ip" {
  description = "workbench VM의 공용 IP. az ssh vm 또는 ssh -i ~/.ssh/workbench_dev_ed25519로 접속할 때 쓴다."
  value       = module.aks_workbench.workbench_public_ip
}

output "workbench_vm_id" {
  description = "workbench VM의 리소스 ID."
  value       = module.aks_workbench.workbench_vm_id
}
