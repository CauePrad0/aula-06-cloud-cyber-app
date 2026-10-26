#!/usr/bin/env bash
# deploy.sh — sobe tudo na ordem certa.
#
# Por que em 2 fases? O ECS Service precisa que a imagem JÁ exista no ECR.
#   Fase 1: cria só o repositório ECR
#   Fase 2: builda e envia a imagem
#   Fase 3: cria o resto (rede, Aurora, ECS, ALB, CloudFront)
#
# Pré-requisitos: aws cli logado (aws configure / aws sso login), docker, terraform.
# Com domínio:   TF_VAR_domain_name=meugrupo.click ./scripts/deploy.sh
# Sem domínio:   ./scripts/deploy.sh
set -euo pipefail

RAIZ="$(cd "$(dirname "$0")/.." && pwd)"
cd "$RAIZ/infra"

echo "==> Fase 1/3: criando o repositório ECR"
terraform init -input=false
terraform apply -input=false -auto-approve -target=aws_ecr_repository.app

REPO_URL="$(terraform output -raw ecr_repository_url)"
REGIAO="$(terraform output -raw region 2>/dev/null || echo us-east-1)"
REGISTRO="${REPO_URL%%/*}"

echo "==> Fase 2/3: build e push da imagem para $REPO_URL"
aws ecr get-login-password --region "$REGIAO" | docker login --username AWS --password-stdin "$REGISTRO"
# --platform linux/amd64: o Fargate da task definition é x86_64 (importante em Mac com chip M)
docker build --platform linux/amd64 -t "$REPO_URL:latest" "$RAIZ"
docker push "$REPO_URL:latest"

echo "==> Fase 3/3: criando o restante da infraestrutura (o terraform vai pedir confirmação)"
terraform apply

echo
echo "Pronto. Endereço da aplicação:"
terraform output -raw site_url
echo
echo "Obs.: o CloudFront leva ~5-10 min para ficar 'Deployed' e as tasks ~2-3 min para ficarem healthy."
