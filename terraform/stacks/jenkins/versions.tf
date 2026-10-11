terraform {
  required_version = ">= 1.16.0, < 2.0.0"

  required_providers {
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.9"
    }

    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}
