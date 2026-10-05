locals {
  cache_dir       = pathexpand("~/.cache/orbit/cloud-images")
  base_image_path = "${local.cache_dir}/ubuntu-24.04-server-cloudimg-amd64-20260926.img"
  generated_dir   = "${path.module}/.generated"
}

resource "terraform_data" "base_image" {
  triggers_replace = [var.base_image_url, var.base_image_sha256]

  provisioner "local-exec" {
    command = "bash '${path.module}/scripts/download-cloud-image.sh' '${var.base_image_url}' '${var.base_image_sha256}' '${local.base_image_path}'"
  }
}

resource "libvirt_volume" "base_image" {
  name = var.base_volume_name
  pool = var.pool_name

  target = {
    format = {
      type = "qcow2"
    }
  }

  create = {
    content = {
      url = local.base_image_path
    }
  }

  depends_on = [terraform_data.base_image]
}

resource "libvirt_volume" "os_disk" {
  for_each = var.vms

  name          = "${each.key}-os.qcow2"
  pool          = var.pool_name
  capacity      = each.value.os_disk_gib
  capacity_unit = "GiB"

  target = {
    format = {
      type = "qcow2"
    }
  }

  backing_store = {
    path = libvirt_volume.base_image.path
    format = {
      type = "qcow2"
    }
  }
}

resource "libvirt_volume" "data_disk" {
  for_each = {
    for name, vm in var.vms : name => vm
    if vm.data_disk_gib != null
  }

  name          = "${each.key}-data.raw"
  pool          = var.pool_name
  capacity      = each.value.data_disk_gib
  capacity_unit = "GiB"

  target = {
    format = {
      type = "raw"
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "local_file" "user_data" {
  for_each = var.vms

  filename        = "${local.generated_dir}/${each.key}/user-data"
  file_permission = "0600"
  content = templatefile("${path.module}/templates/user-data.yaml.tftpl", {
    hostname            = each.key
    ssh_authorized_keys = sort(tolist(var.ssh_authorized_keys))
  })
}

resource "local_file" "meta_data" {
  for_each = var.vms

  filename        = "${local.generated_dir}/${each.key}/meta-data"
  file_permission = "0600"
  content = yamlencode({
    instance-id    = each.key
    local-hostname = each.key
  })
}

resource "terraform_data" "cloud_init" {
  for_each = var.vms

  triggers_replace = [
    local_file.user_data[each.key].content_sha256,
    local_file.meta_data[each.key].content_sha256,
  ]

  provisioner "local-exec" {
    command = "bash '${path.module}/scripts/create-cloud-init-iso.sh' '${local.generated_dir}/${each.key}/cloud-init.iso' '${local_file.user_data[each.key].filename}' '${local_file.meta_data[each.key].filename}'"
  }
}

resource "libvirt_volume" "cloud_init" {
  for_each = var.vms

  name = "${each.key}-cloud-init.iso"
  pool = var.pool_name

  target = {
    format = {
      type = "iso"
    }
  }

  create = {
    content = {
      url = "${local.generated_dir}/${each.key}/cloud-init.iso"
    }
  }

  depends_on = [terraform_data.cloud_init]
}

resource "libvirt_domain" "this" {
  for_each = var.vms

  name        = each.key
  type        = "kvm"
  memory      = each.value.memory_mib
  memory_unit = "MiB"
  vcpu        = each.value.vcpu
  running     = true
  autostart   = true

  cpu = {
    mode = "host-passthrough"
  }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
    boot_devices = [
      {
        dev = "hd"
      }
    ]
  }

  devices = {
    disks = concat(
      [
        {
          driver = {
            name = "qemu"
            type = "qcow2"
          }
          source = {
            file = {
              file = libvirt_volume.os_disk[each.key].path
            }
          }
          target = {
            dev = "vda"
            bus = "virtio"
          }
          serial = "${each.key}-os"
        },
        {
          device    = "cdrom"
          read_only = true
          driver = {
            name = "qemu"
            type = "raw"
          }
          source = {
            file = {
              file = libvirt_volume.cloud_init[each.key].path
            }
          }
          target = {
            dev = "sda"
            bus = "sata"
          }
        },
      ],
      each.value.data_disk_gib == null ? [] : [
        {
          driver = {
            name = "qemu"
            type = "raw"
          }
          source = {
            file = {
              file = libvirt_volume.data_disk[each.key].path
            }
          }
          target = {
            dev = "vdb"
            bus = "virtio"
          }
          serial = "${each.key}-data"
        },
      ],
    )

    interfaces = [
      {
        mac = {
          address = each.value.mac
        }
        model = {
          type = "virtio"
        }
        source = {
          network = {
            network = var.network_name
          }
        }
        wait_for_ip = {
          source  = "lease"
          timeout = 300
        }
      },
    ]
  }
}
