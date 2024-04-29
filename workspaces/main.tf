variable "my_org" {}
variable "my_aws_role" {}
variable "my_tfc_token" {}

provider "tfe" {
}

resource "tfe_project" "three-tier-app-demo" {
  name         = "three-tier-app-demo"
  organization = var.my_org
}

resource "tfe_workspace" "docker" {
  description       = "docker registry"
  name              = "docker"
  organization      = "angryhippo"
  project_id        = tfe_project.three-tier-app-demo.id
  terraform_version = "latest"
}

resource "tfe_workspace" "infra" {
  description       = "the infrastructure"
  name              = "infra"
  organization      = "angryhippo"
  project_id        = tfe_project.three-tier-app-demo.id
  terraform_version = "latest"
}

resource "tfe_workspace" "kubernetes" {
  description       = "k8s"
  name              = "kubernetes"
  organization      = "angryhippo"
  project_id        = tfe_project.three-tier-app-demo.id
  terraform_version = "latest"
}

resource "tfe_variable" "docker_aws_role_arn" {
  key          = "aws_role_arn"
  value        = var.my_aws_role
  category     = "terraform"
  workspace_id = tfe_workspace.docker.id
  description  = "role to assume for terraform"
}

resource "tfe_variable" "infra_aws_role_arn" {
  key          = "aws_role_arn"
  value        = var.my_aws_role
  category     = "terraform"
  workspace_id = tfe_workspace.infra.id
  description  = "role to assume for terraform"
}

resource "tfe_variable" "kubernetes_aws_role_arn" {
  key          = "aws_role_arn"
  value        = var.my_aws_role
  category     = "terraform"
  workspace_id = tfe_workspace.kubernetes.id
  description  = "role to assume for terraform"
}

resource "tfe_variable" "kubernetes_tfc_org" {
  key          = "TFC_ORG"
  value        = var.my_org
  category     = "terraform"
  workspace_id = tfe_workspace.kubernetes.id
  description  = "tfc org name"
}

resource "tfe_variable" "kubernetes_tfc_token" {
  key          = "TFE_TOKEN"
  value        = var.my_org
  category     = "env"
  sensitive    = true
  workspace_id = tfe_workspace.kubernetes.id
  description  = "tfe token"
}
