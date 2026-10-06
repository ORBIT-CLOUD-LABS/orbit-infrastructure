output "path" {
  description = "Path of the generated Ansible inventory."
  value       = local_file.this.filename
}
