module "ansible_inventory" {
  source = "../../modules/ansible-inventory"

  output_path  = var.ansible_inventory_path
  ansible_user = "orbit"
  hosts        = module.vms.vm_ips

  groups = {
    control_plane = ["astra-control-plane"]
    workers       = ["astra-worker-1", "astra-worker-2", "astra-worker-3"]
    jenkins       = ["astra-jenkins"]
    nfs           = ["astra-nfs"]
    vehicle_db    = ["astra-vehicle-db"]
    monitoring    = ["astra-monitoring"]
  }

  group_children = {
    k8s = ["control_plane", "workers"]
  }
}
