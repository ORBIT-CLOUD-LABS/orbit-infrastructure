variable "libvirt_uri" {
  type        = string
  description = "libvirt connection URI of the physical host that runs Jenkins. The stack is applied manually on that host."
  default     = "qemu:///system"
}

variable "ssh_authorized_keys" {
  type        = set(string)
  description = "SSH public keys installed for the orbit account on the Jenkins VM."

  validation {
    condition     = length(var.ssh_authorized_keys) > 0
    error_message = "At least one SSH public key is required."
  }
}

variable "pool_name" {
  type        = string
  description = "Existing libvirt storage pool for the Jenkins disks."
  default     = "orbit-astra"
}

variable "network_name" {
  type        = string
  description = "Existing libvirt network the Jenkins VM attaches to."
  default     = "orbit-astra-net"
}

variable "jenkins" {
  description = "Jenkins VM resources and static network settings."
  type = object({
    name          = string
    vcpu          = number
    memory_mib    = number
    os_disk_gib   = number
    mac           = string
    ip            = string
    prefix_length = number
    gateway       = string
    nameservers   = list(string)
  })
  default = {
    name          = "astra-jenkins"
    vcpu          = 2
    memory_mib    = 6144
    os_disk_gib   = 35
    mac           = "52:54:00:64:00:04"
    ip            = "192.168.100.104"
    prefix_length = 24
    gateway       = "192.168.100.1"
    nameservers   = ["192.168.100.1"]
  }
}
