terraform {
  backend "local" {
    path = "/var/lib/orbit/terraform-state/astra/terraform.tfstate"
  }
}
