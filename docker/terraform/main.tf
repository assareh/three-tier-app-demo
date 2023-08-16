provider "aws" {
  region = "us-west-2"
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
