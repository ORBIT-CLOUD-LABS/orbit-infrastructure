module "network" {
  source = "../../modules/libvirt-network"

  name             = "orbit-astra-net"
  bridge_name      = "virbr100"
  cidr             = "192.168.100.0/24"
  dhcp_range_start = "192.168.100.200"
  dhcp_range_end   = "192.168.100.249"

  # astra-jenkins VM은 stacks/jenkins가 static IP로 관리한다. 예약을 지우면 provider가
  # 네트워크를 재생성해 모든 VM 연결이 끊기므로, 네트워크를 바꿀 때까지 예약을 남겨 둔다.
  dhcp_hosts = {
    astra-jenkins       = { mac = "52:54:00:64:00:04", ip = "192.168.100.100" }
    astra-control-plane = { mac = "52:54:00:64:00:00", ip = "192.168.100.101" }
    astra-worker-1      = { mac = "52:54:00:64:00:01", ip = "192.168.100.102" }
    astra-worker-2      = { mac = "52:54:00:64:00:02", ip = "192.168.100.103" }
    astra-worker-3      = { mac = "52:54:00:64:00:03", ip = "192.168.100.104" }
    astra-nfs           = { mac = "52:54:00:64:00:05", ip = "192.168.100.105" }
    astra-vehicle-db    = { mac = "52:54:00:64:00:06", ip = "192.168.100.106" }
    astra-monitoring    = { mac = "52:54:00:64:00:07", ip = "192.168.100.107" }
  }
}

resource "libvirt_pool" "astra" {
  name = "orbit-astra"
  type = "dir"

  target = {
    path = "/var/lib/libvirt/images/orbit-astra"
  }

  create = {
    build     = true
    start     = true
    autostart = true
  }

  destroy = {
    delete = false
  }
}

module "vms" {
  source = "../../modules/libvirt-vm"

  pool_name           = libvirt_pool.astra.name
  network_name        = module.network.name
  base_image_url      = "https://cloud-images.ubuntu.com/releases/server/24.04/release-20260926/ubuntu-24.04-server-cloudimg-amd64.img"
  base_image_sha256   = "6a81c37564db9b1ee84e141922625e1d7c5b389b99bb3c572e0243607d5bb4d2"
  ssh_authorized_keys = var.ssh_authorized_keys

  vms = {
    astra-control-plane = { vcpu = 2, memory_mib = 4096, os_disk_gib = 25, data_disk_gib = null, mac = "52:54:00:64:00:00", ip = "192.168.100.101" }
    astra-worker-1      = { vcpu = 2, memory_mib = 8192, os_disk_gib = 35, data_disk_gib = null, mac = "52:54:00:64:00:01", ip = "192.168.100.102" }
    astra-worker-2      = { vcpu = 2, memory_mib = 8192, os_disk_gib = 35, data_disk_gib = null, mac = "52:54:00:64:00:02", ip = "192.168.100.103" }
    astra-worker-3      = { vcpu = 2, memory_mib = 8192, os_disk_gib = 35, data_disk_gib = null, mac = "52:54:00:64:00:03", ip = "192.168.100.104" }
    astra-nfs           = { vcpu = 1, memory_mib = 4096, os_disk_gib = 20, data_disk_gib = 45, mac = "52:54:00:64:00:05", ip = "192.168.100.105" }
    astra-vehicle-db    = { vcpu = 1, memory_mib = 4096, os_disk_gib = 20, data_disk_gib = 15, mac = "52:54:00:64:00:06", ip = "192.168.100.106" }
    astra-monitoring    = { vcpu = 2, memory_mib = 8192, os_disk_gib = 25, data_disk_gib = 20, mac = "52:54:00:64:00:07", ip = "192.168.100.107" }
  }
}
