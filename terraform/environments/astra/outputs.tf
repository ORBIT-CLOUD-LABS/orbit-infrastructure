output "network_name" {
  description = "ASTRA libvirt network name."
  value       = module.network.name
}

output "network_id" {
  description = "ASTRA libvirt network UUID."
  value       = module.network.id
}

output "storage_pool_name" {
  description = "ASTRA libvirt storage pool name."
  value       = libvirt_pool.astra.name
}

output "vm_ips" {
  description = "Reserved IPv4 addresses for ASTRA VMs."
  value       = module.vms.vm_ips
}

output "ansible_inventory_path" {
  description = "Path of the generated Ansible inventory."
  value       = module.ansible_inventory.path
}
