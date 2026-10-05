variable "pool_name" {
  type        = string
  description = "Destination libvirt storage pool name."
}

variable "network_name" {
  type        = string
  description = "Source libvirt network name for VM interfaces."
}

variable "base_image_url" {
  type        = string
  description = "Pinned Ubuntu cloud image URL."
}

variable "base_image_sha256" {
  type        = string
  description = "SHA-256 checksum for the pinned Ubuntu cloud image."

  validation {
    condition     = can(regex("^[0-9a-f]{64}$", var.base_image_sha256))
    error_message = "base_image_sha256 must be a lowercase SHA-256 digest."
  }
}

variable "base_volume_name" {
  type        = string
  description = "libvirt volume name for the shared base image. Use a distinct name per stack to avoid sharing the backing file."
  default     = "ubuntu-24.04-server-cloudimg-amd64-20260926.qcow2"
}

variable "ssh_authorized_keys" {
  type        = set(string)
  description = "SSH public keys for the orbit account."
}

variable "vms" {
  description = "VM resource, disk, MAC and reserved IP definitions."
  type = map(object({
    vcpu          = number
    memory_mib    = number
    os_disk_gib   = number
    data_disk_gib = number
    mac           = string
    ip            = string
  }))
}
