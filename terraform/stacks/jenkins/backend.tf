terraform {
  backend "local" {
    path = "/var/lib/orbit/terraform-state/jenkins/terraform.tfstate"
  }
}
