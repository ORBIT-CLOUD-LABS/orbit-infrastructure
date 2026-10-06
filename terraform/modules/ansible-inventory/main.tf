resource "local_file" "this" {
  filename             = var.output_path
  file_permission      = "0644"
  directory_permission = "0755"
  content = templatefile("${path.module}/templates/hosts.ini.tftpl", {
    hosts          = var.hosts
    groups         = var.groups
    group_children = var.group_children
    ansible_user   = var.ansible_user
  })
}
