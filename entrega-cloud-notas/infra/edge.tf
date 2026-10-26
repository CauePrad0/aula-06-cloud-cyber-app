# ---------------------------------------------------------------------------
# Application Load Balancer (subnets públicas) -> target group (tasks, porta 8080)
# ---------------------------------------------------------------------------
resource "aws_lb" "this" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  depends_on = [aws_internet_gateway.this]
}

resource "aws_lb_target_group" "app" {
  name                 = "${var.project}-tg"
  port                 = 8080
  protocol             = "HTTP"
  target_type          = "ip" # obrigatório p/ Fargate (awsvpc)
  vpc_id               = aws_vpc.this.id
  deregistration_delay = 30

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

# Sem domínio: listener HTTP 80 (o HTTPS fica entre usuário e CloudFront)
resource "aws_lb_listener" "http" {
  count             = local.use_domain ? 0 : 1
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# Com domínio: listener HTTPS 443 com certificado ACM
resource "aws_lb_listener" "https" {
  count             = local.use_domain ? 1 : 0
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.this[0].certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

# ---------------------------------------------------------------------------
# ACM + Route 53 (só quando var.domain_name foi informado)
# 1 certificado cobre o domínio e *.domínio (app.<d> no CloudFront, origin.<d> no ALB).
# Como CloudFront exige certificado em us-east-1 e a região é us-east-1, serve p/ os dois.
# ---------------------------------------------------------------------------
data "aws_route53_zone" "this" {
  count        = local.use_domain ? 1 : 0
  name         = var.domain_name
  private_zone = false
}

resource "aws_acm_certificate" "this" {
  count                     = local.use_domain ? 1 : 0
  domain_name               = var.domain_name
  subject_alternative_names = ["*.${var.domain_name}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_route53_record" "cert_validation" {
  for_each = local.use_domain ? {
    for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id         = data.aws_route53_zone.this[0].zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true # domínio e wildcard compartilham o mesmo registro
}

resource "aws_acm_certificate_validation" "this" {
  count                   = local.use_domain ? 1 : 0
  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# origin.<domínio> -> ALB
resource "aws_route53_record" "origin" {
  count   = local.use_domain ? 1 : 0
  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = local.origin_fqdn
  type    = "A"

  alias {
    name                   = aws_lb.this.dns_name
    zone_id                = aws_lb.this.zone_id
    evaluate_target_health = true
  }
}

# app.<domínio> -> CloudFront
resource "aws_route53_record" "app" {
  count   = local.use_domain ? 1 : 0
  zone_id = data.aws_route53_zone.this[0].zone_id
  name    = local.app_fqdn
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}

# ---------------------------------------------------------------------------
# CloudFront: porta de entrada HTTPS; encaminha tudo ao ALB sem cache
# (app dinâmica: POST /notas e a lista precisam chegar sempre à aplicação)
# ---------------------------------------------------------------------------
resource "aws_cloudfront_distribution" "this" {
  enabled     = true
  comment     = "${var.project}-da-nuvem"
  price_class = "PriceClass_100"
  aliases     = local.use_domain ? [local.app_fqdn] : []

  origin {
    origin_id   = "alb"
    domain_name = local.use_domain ? local.origin_fqdn : aws_lb.this.dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = local.use_domain ? "https-only" : "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  default_cache_behavior {
    target_origin_id       = "alb"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods         = ["GET", "HEAD"]

    cache_policy_id          = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # Managed-CachingDisabled
    origin_request_policy_id = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # Managed-AllViewerExceptHostHeader
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = local.use_domain ? null : true
    acm_certificate_arn            = local.use_domain ? aws_acm_certificate_validation.this[0].certificate_arn : null
    ssl_support_method             = local.use_domain ? "sni-only" : null
    minimum_protocol_version       = local.use_domain ? "TLSv1.2_2021" : null
  }
}
