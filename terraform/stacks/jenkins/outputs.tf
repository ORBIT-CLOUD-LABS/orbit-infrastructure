output "jenkins_name" {
  description = "Jenkins VM name."
  value       = var.jenkins.name
}

output "jenkins_ip" {
  description = "Static IPv4 address of the Jenkins VM."
  value       = module.jenkins.vm_ips[var.jenkins.name]
}
