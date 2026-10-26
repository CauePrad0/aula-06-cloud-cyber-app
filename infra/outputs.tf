output "site_url" {
  description = "Endereço público da aplicação (CloudFront)."
  value       = local.use_domain ? "https://${local.app_fqdn}" : "https://${aws_cloudfront_distribution.this.domain_name}"
}

output "ecr_repository_url" {
  value = aws_ecr_repository.app.repository_url
}

output "ecs_cluster" {
  value = aws_ecs_cluster.this.name
}

output "ecs_service" {
  value = aws_ecs_service.app.name
}

output "aurora_endpoint" {
  value = aws_rds_cluster.this.endpoint
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "region" {
  value = var.region
}
