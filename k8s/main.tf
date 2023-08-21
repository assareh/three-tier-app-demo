variable "TFC_ORG" {}

variable "aws_role_arn" {
  description = "Amazon Resource Name of the role to be assumed (this was created in the producer workspace)"
}

variable "TFC_RUN_ID" {
  type        = string
  description = "Terraform Cloud automatically injects a unique identifier for this run."
  default     = "terraform"
}

data "tfe_outputs" "infra" {
  organization = var.TFC_ORG
  workspace    = "infra"
}

data "tfe_outputs" "docker" {
  organization = var.TFC_ORG
  workspace    = "docker"
}

provider "aws" {
  region = data.tfe_outputs.infra.values.region

  assume_role {
    role_arn     = var.aws_role_arn
    session_name = var.TFC_RUN_ID
  }
}

data "aws_caller_identity" "current" {}

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

resource "kubernetes_deployment" "tasky" {
  metadata {
    name = "tasky-deployment"
    labels = {
      app = "tasky"
    }
  }

  spec {
    replicas = 2

    selector {
      match_labels = {
        app = "tasky"
      }
    }

    template {
      metadata {
        labels = {
          app = "tasky"
        }
      }

      spec {
        container {
          image = data.tfe_outputs.docker.values.container_registry_url
          name  = "tasky"
          env {
            name  = "MONGODB_URI"
            value = "mongodb://${data.tfe_outputs.infra.values.mongodb_username}:${data.tfe_outputs.infra.values.mongodb_password}@${data.tfe_outputs.infra.values.db_instance_private_ip}:27017"
          }
          env {
            name  = "SECRET_KEY"
            value = "secret123"
          }
          port {
            container_port = 8080
          }
        }
      }
    }
  }
}

resource "kubernetes_service_account" "tasky" {
  metadata {
    name = "tasky"
  }
}

resource "kubernetes_service" "tasky" {
  metadata {
    name = "tasky-service-loadbalancer"
  }
  spec {
    selector = {
      app = "tasky"
    }
    port {
      port        = 80
      target_port = 8080
    }

    type = "LoadBalancer"
  }
}

data "kubernetes_service" "tasky" {
  metadata {
    name = "tasky-service-loadbalancer"
  }
}

resource "kubernetes_cluster_role_binding" "admin" {
  metadata {
    name = "tasky"
  }
  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "ClusterRole"
    name      = "cluster-admin"
  }
  subject {
    kind      = "ServiceAccount"
    name      = "tasky"
    namespace = "default"
  }
}

output "caller" {
  value = data.aws_caller_identity.current.arn
}

output "lb_address" {
  value = try(data.kubernetes_service.tasky.status.0.load_balancer.0.ingress.0.hostname, "")
  depends_on = [
    data.kubernetes_service.tasky
  ]
}
# add a check
