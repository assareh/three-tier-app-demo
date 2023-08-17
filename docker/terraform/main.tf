provider "aws" {
  region = var.region

  assume_role {
    role_arn     = var.aws_role_arn
    session_name = var.TFC_RUN_ID
  }
}

variable "aws_role_arn" {
  description = "Amazon Resource Name of the role to be assumed (this was created in the producer workspace)"
}

variable "region" {
  description = "The region where the resources are created."
  default     = "us-west-2"
}

variable "TFC_RUN_ID" {
  type        = string
  description = "Terraform Cloud automatically injects a unique identifier for this run."
  default     = "terraform"
}

data "aws_caller_identity" "current" {}

resource "aws_ecr_repository" "this" {
  name                 = "tasky"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

output "caller" {
  value = data.aws_caller_identity.current.arn
}

output "container_registry_url" {
  description = "URL of container registry"
  value       = aws_ecr_repository.this.repository_url
}
