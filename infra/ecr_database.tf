# ---------------------------------------------------------------------------
# ECR: repositório da imagem Docker
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "app" {
  name                 = "${var.project}-da-nuvem"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # permite destruir o repo mesmo com imagens dentro

  image_scanning_configuration {
    scan_on_push = true
  }
}

# ---------------------------------------------------------------------------
# Aurora Serverless v2 (PostgreSQL) em subnets privadas de dados
# A senha NÃO fica no código nem no state: o RDS gera e guarda no Secrets Manager.
# ---------------------------------------------------------------------------
resource "aws_db_subnet_group" "this" {
  name       = "${var.project}-db-subnets"
  subnet_ids = aws_subnet.data[*].id
}

resource "aws_rds_cluster" "this" {
  cluster_identifier = "${var.project}-aurora"
  engine             = "aurora-postgresql"
  engine_mode        = "provisioned" # Serverless v2 usa "provisioned" + classe db.serverless
  engine_version     = var.db_engine_version

  database_name               = var.db_name
  master_username             = var.db_user
  manage_master_user_password = true # senha gerada e guardada no Secrets Manager

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  storage_encrypted      = true

  backup_retention_period = 1
  skip_final_snapshot     = true  # demo: sem snapshot ao destruir
  deletion_protection     = false # demo: permite destruir

  serverlessv2_scaling_configuration {
    min_capacity = var.aurora_min_acu
    max_capacity = var.aurora_max_acu
  }
}

resource "aws_rds_cluster_instance" "writer" {
  identifier          = "${var.project}-aurora-writer"
  cluster_identifier  = aws_rds_cluster.this.id
  instance_class      = "db.serverless"
  engine              = aws_rds_cluster.this.engine
  engine_version      = aws_rds_cluster.this.engine_version
  publicly_accessible = false
}
