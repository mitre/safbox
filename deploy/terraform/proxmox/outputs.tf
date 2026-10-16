output "vm_id" {
  description = "VM ID of the SAFBox."
  value       = local.vm.vm_id
}

output "address" {
  description = "IPv4 address of the SAFBox, as its guest agent reports it."
  value       = local.address
}

output "ssh" {
  description = "Command that logs in as the cloud-init user (first boot may still be starting the services; safbox services shows them)."
  value       = local.address == null ? null : "ssh ${var.ci_user}@${local.address}"
}

output "landing_page" {
  description = "The SAFBox landing page: each service's status and a link to it."
  value       = local.address == null ? null : "https://${local.address}/"
}
