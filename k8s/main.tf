variable "TFC_ORG" {}
variable "TFC_WORKSPACE" {}

data "tfe_outputs" "infra" {
  organization = var.TFC
  workspace    = var.TFC_WORKSPACE
}

data "aws_eks_cluster" "default" {
  name = data.tfe_outputs.infra.values.cluster_name
}

data "aws_eks_cluster_auth" "default" {
  name = data.tfe_outputs.infra.values.cluster_name
}

provider "kubernetes" {
  host                   = data.aws_eks_cluster.default.endpoint
  cluster_ca_certificate = base64decode(data.aws_eks_cluster.default.certificate_authority[0].data)
  token                  = data.aws_eks_cluster_auth.default.token
}

