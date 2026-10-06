output "vm_ips" {
  description = "Reserved IPv4 addresses keyed by VM name."
  value = {
    for name, vm in var.vms : name => vm.ip
  }
}
