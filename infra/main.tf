terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.80, < 7.0"
    }
  }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Projeto = var.project
      Origem  = "atividade-cloud-cesar"
    }
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Com domínio: ACM + HTTPS entre CloudFront e ALB.
  # Sem domínio: CloudFront (HTTPS do *.cloudfront.net) -> ALB em HTTP/80.
  use_domain    = var.domain_name != ""
  listener_port = local.use_domain ? 443 : 80
  app_fqdn      = "app.${var.domain_name}"    # o que o usuário digita (CloudFront)
  origin_fqdn   = "origin.${var.domain_name}" # nome do ALB (precisa bater com o certificado)
}
