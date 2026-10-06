variable "ssh_authorized_keys" {
  type        = set(string)
  description = "SSH public keys installed for the orbit account on every ASTRA VM."

  validation {
    condition     = length(var.ssh_authorized_keys) > 0
    error_message = "At least one SSH public key is required."
  }
}

variable "ansible_inventory_path" {
  type        = string
  description = "Destination path of the generated Ansible inventory, relative to this environment directory."
  default     = "../../../ansible/inventory/lab/hosts.ini"
}
