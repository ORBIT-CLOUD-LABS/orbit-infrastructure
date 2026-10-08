module "jenkins" {
  source = "../../modules/libvirt-vm"

  pool_name    = var.pool_name
  network_name = var.network_name

  # 업무 스택의 base 볼륨과 backing file을 공유하지 않도록 전용 이름을 사용한다.
  base_volume_name    = "jenkins-ubuntu-24.04-server-cloudimg-amd64-20260926.qcow2"
  base_image_url      = "https://cloud-images.ubuntu.com/releases/server/24.04/release-20260926/ubuntu-24.04-server-cloudimg-amd64.img"
  base_image_sha256   = "6a81c37564db9b1ee84e141922625e1d7c5b389b99bb3c572e0243607d5bb4d2"
  ssh_authorized_keys = var.ssh_authorized_keys

  # 업무 스택의 DHCP 예약에 의존하지 않도록 cloud-init으로 IP를 고정한다.
  static_ipv4 = {
    prefix_length = var.jenkins.prefix_length
    gateway       = var.jenkins.gateway
    nameservers   = var.jenkins.nameservers
  }

  vms = {
    (var.jenkins.name) = {
      vcpu          = var.jenkins.vcpu
      memory_mib    = var.jenkins.memory_mib
      os_disk_gib   = var.jenkins.os_disk_gib
      data_disk_gib = null
      mac           = var.jenkins.mac
      ip            = var.jenkins.ip
    }
  }
}
