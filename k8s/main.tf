variable "TFC_ORG" {}

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

output "lb_address" {
  value = try(data.kubernetes_service.tasky.status.0.load_balancer.0.ingress.0.hostname, "")
  depends_on = [
    data.kubernetes_service.tasky
  ]
}
