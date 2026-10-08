variable "output_path" {
  type        = string
  description = "Destination path of the generated Ansible INI inventory."
}

variable "hosts" {
  type        = map(string)
  description = "IPv4 addresses keyed by inventory hostname."
}

variable "groups" {
  type        = map(list(string))
  description = "Inventory hostnames keyed by Ansible group name."

  validation {
    condition = alltrue([
      for members in values(var.groups) : alltrue([
        for name in members : contains(keys(var.hosts), name)
      ])
    ])
    error_message = "Every group member must be defined in hosts."
  }
}

variable "group_children" {
  type        = map(list(string))
  description = "Child group names keyed by parent Ansible group name."
  default     = {}

  validation {
    condition = alltrue([
      for children in values(var.group_children) : alltrue([
        for child in children : contains(keys(var.groups), child)
      ])
    ])
    error_message = "Every child group must be defined in groups."
  }
}

variable "ansible_user" {
  type        = string
  description = "SSH user Ansible uses to connect to every host."
}
