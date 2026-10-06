variable "name" {
  type        = string
  description = "libvirt virtual network name."
}

variable "bridge_name" {
  type        = string
  description = "Bridge interface created by libvirt."
}

variable "cidr" {
  type        = string
  description = "IPv4 CIDR for the virtual NAT network."

  validation {
    condition     = can(cidrhost(var.cidr, 1))
    error_message = "cidr must be a valid IPv4 or IPv6 CIDR block."
  }
}

variable "dhcp_range_start" {
  type        = string
  description = "First dynamic DHCP address."
}

variable "dhcp_range_end" {
  type        = string
  description = "Last dynamic DHCP address."
}

variable "dhcp_hosts" {
  description = "Static DHCP reservations keyed by VM name."
  type = map(object({
    mac = string
    ip  = string
  }))
}
