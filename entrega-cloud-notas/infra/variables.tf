variable "region" {
  description = "Região AWS (a apostila usa us-east-1)."
  type        = string
  default     = "us-east-1"
}

variable "project" {
  description = "Prefixo usado no nome dos recursos."
  type        = string
  default     = "notas"
}

variable "domain_name" {
  description = <<-EOT
    Domínio registrado no Route 53 (ex: "meugrupo.click"). Se informado, cria
    certificado ACM, HTTPS no ALB e o site fica em app.<domínio>.
    Deixe vazio ("") para usar só o endereço *.cloudfront.net (sem ACM).
  EOT
  type        = string
  default     = ""
}

variable "db_name" {
  type    = string
  default = "notasdb"
}

variable "db_user" {
  type    = string
  default = "notas_app"
}

variable "db_engine_version" {
  description = "Versão do Aurora PostgreSQL. Confira as disponíveis: aws rds describe-db-engine-versions --engine aurora-postgresql --query 'DBEngineVersions[].EngineVersion'"
  type        = string
  default     = "16.6"
}

variable "aurora_min_acu" {
  description = "Capacidade mínima do Aurora Serverless v2 (0 = pausa quando ocioso, mas a 1ª requisição demora ~15s)."
  type        = number
  default     = 0.5
}

variable "aurora_max_acu" {
  type    = number
  default = 2
}

variable "desired_count" {
  description = "Quantas tasks Fargate. 1 basta para a atividade (o diagrama da apostila usa 2)."
  type        = number
  default     = 1
}

variable "image_tag" {
  type    = string
  default = "latest"
}
