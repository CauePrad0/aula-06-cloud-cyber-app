# ---------------------------------------------------------------------------
# VPC 10.0.0.0/16, 2 AZs, 3 camadas de subnets (igual ao diagrama da apostila)
#   pública  -> ALB e NAT Gateway
#   app      -> tasks Fargate (saem para a internet via NAT p/ puxar ECR etc.)
#   dados    -> Aurora (sem rota para a internet)
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${var.project}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project}-igw" }
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.azs[count.index]
  cidr_block              = "10.0.${count.index + 1}.0/24"
  map_public_ip_on_launch = false
  tags                    = { Name = "${var.project}-publica-${count.index == 0 ? "a" : "b"}" }
}

resource "aws_subnet" "app" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = "10.0.${count.index + 11}.0/24"
  tags              = { Name = "${var.project}-app-${count.index == 0 ? "a" : "b"}" }
}

resource "aws_subnet" "data" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  availability_zone = local.azs[count.index]
  cidr_block        = "10.0.${count.index + 21}.0/24"
  tags              = { Name = "${var.project}-dados-${count.index == 0 ? "a" : "b"}" }
}

# --- Saída para a internet das subnets privadas de app: 1 NAT Gateway --------
# (barato p/ demo; em produção seria 1 por AZ. Alternativa: VPC Endpoints.)
resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${var.project}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${var.project}-nat" }
  depends_on    = [aws_internet_gateway.this]
}

# --- Tabelas de rotas ---------------------------------------------------------
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project}-rt-publica" }

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
}

resource "aws_route_table" "app" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project}-rt-app" }

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }
}

# Dados: só a rota local da VPC (nenhuma saída para a internet)
resource "aws_route_table" "data" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${var.project}-rt-dados" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "app" {
  count          = 2
  subnet_id      = aws_subnet.app[count.index].id
  route_table_id = aws_route_table.app.id
}

resource "aws_route_table_association" "data" {
  count          = 2
  subnet_id      = aws_subnet.data[count.index].id
  route_table_id = aws_route_table.data.id
}

# ---------------------------------------------------------------------------
# Security Groups: cada camada só aceita tráfego da camada de cima
#   CloudFront -> sg-alb -> sg-app -> sg-db
# ---------------------------------------------------------------------------

# Lista de IPs de origem do CloudFront (mantida pela AWS)
data "aws_ec2_managed_prefix_list" "cloudfront" {
  name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "alb" {
  name        = "${var.project}-sg-alb"
  description = "ALB: aceita apenas o CloudFront"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.project}-sg-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_from_cloudfront" {
  security_group_id = aws_security_group.alb.id
  description       = "CloudFront para ALB"
  prefix_list_id    = data.aws_ec2_managed_prefix_list.cloudfront.id
  ip_protocol       = "tcp"
  from_port         = local.listener_port
  to_port           = local.listener_port
}

resource "aws_vpc_security_group_egress_rule" "alb_to_app" {
  security_group_id            = aws_security_group.alb.id
  description                  = "ALB para tasks"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_security_group" "app" {
  name        = "${var.project}-sg-app"
  description = "Tasks Fargate: aceita apenas o ALB"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.project}-sg-app" }
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  description                  = "ALB para app (8080)"
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

# Saída das tasks: NAT (ECR, Secrets Manager, CloudWatch, SSM) e Aurora
resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  description       = "Saida das tasks"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "db" {
  name        = "${var.project}-sg-db"
  description = "Aurora: aceita apenas as tasks"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "${var.project}-sg-db" }
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  description                  = "app para PostgreSQL (5432)"
  referenced_security_group_id = aws_security_group.app.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}
