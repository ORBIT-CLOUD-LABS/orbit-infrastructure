resource "libvirt_network" "this" {
  name      = var.name
  autostart = true

  bridge = {
    name  = var.bridge_name
    stp   = "on"
    delay = "0"
  }

  forward = {
    mode = "nat"
  }

  dns = {
    enable     = "yes"
    local_only = "yes"
  }

  ips = [{
    address = cidrhost(var.cidr, 1)
    prefix  = tonumber(split("/", var.cidr)[1])
    dhcp = {
      ranges = [{
        start = var.dhcp_range_start
        end   = var.dhcp_range_end
      }]
      hosts = [
        for name, host in var.dhcp_hosts : {
          mac  = host.mac
          name = name
          ip   = host.ip
        }
      ]
    }
  }]
}
