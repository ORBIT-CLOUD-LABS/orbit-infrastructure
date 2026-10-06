output "id" {
  description = "libvirt network UUID."
  value       = libvirt_network.this.id
}

output "name" {
  description = "libvirt network name."
  value       = libvirt_network.this.name
}
