provider "aws" {
  region = "us-west-2"
}

resource "aws_ecr_repository" "this" {
  name                 = "tasky"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }
}

output "container_registry_url" {
  description = "URL of container registry"
  value       = aws_ecr_repository.this.repository_url
}
