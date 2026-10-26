#!/usr/bin/env bash
# limpar-orfaos.sh — apaga os recursos "notas-*" que um terraform apply interrompido
# deixou na conta SEM state (por isso o terraform destroy nao os enxerga).
#
# Apaga SOMENTE o que o nosso Terraform cria:
#   VPC com a tag Name=notas-vpc (e tudo dentro dela), ALB notas-alb, target group notas-tg,
#   cluster ECS notas-cluster, ECR notas-da-nuvem, roles IAM notas-ecs-*, log group
#   /ecs/notas-da-nuvem, subnet group notas-db-subnets, Aurora notas-aurora (se existir)
#   e a distribuicao CloudFront com comentario "notas-da-nuvem".
#
# Nao testei contra a sua conta: ele mostra o que vai fazer e pede para digitar APAGAR.
# Itens que nao existem sao simplesmente pulados.
#
# Uso (no CloudShell, regiao us-east-1):  ./scripts/limpar-orfaos.sh
set -uo pipefail
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"
R="$AWS_DEFAULT_REGION"

passo() { echo; echo "==> $*"; }
run() { # roda um comando; mostra ok ou o aviso, nunca interrompe o script
  local out
  if out=$("$@" 2>&1); then echo "  ok: $1 $2 $3"; else echo "  aviso ($1 $2 $3): ${out##*$'\n'}"; fi
}

command -v jq >/dev/null || { echo "jq nao encontrado (o CloudShell normalmente tem)."; exit 1; }

CONTA="$(aws sts get-caller-identity --query Account --output text)"
VPC="$(aws ec2 describe-vpcs --filters Name=tag:Name,Values=notas-vpc --query 'Vpcs[0].VpcId' --output text 2>/dev/null)"
[[ "$VPC" == "None" ]] && VPC=""
CF_IDS="$(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='notas-da-nuvem'].Id" --output text 2>/dev/null)"
[[ "$CF_IDS" == "None" ]] && CF_IDS=""

echo "Conta: $CONTA   Regiao: $R"
echo "VPC notas-vpc: ${VPC:-(nao encontrada)}"
echo "CloudFront notas-da-nuvem: ${CF_IDS:-(nenhum)}"
echo
echo "Vou apagar os recursos notas-* listados no cabecalho deste script."
read -rp "Digite APAGAR para continuar: " OK
[[ "$OK" == "APAGAR" ]] || { echo "Cancelado."; exit 0; }

# 1) CloudFront: so desabilita agora (a remocao final espera ele ficar 'Deployed')
passo "CloudFront: desabilitando"
for id in $CF_IDS; do
  aws cloudfront get-distribution-config --id "$id" > /tmp/cf.json
  etag="$(jq -r .ETag /tmp/cf.json)"
  jq '.DistributionConfig | .Enabled=false' /tmp/cf.json > /tmp/cf-cfg.json
  run aws cloudfront update-distribution --id "$id" --if-match "$etag" --distribution-config file:///tmp/cf-cfg.json
done

# 2) ECS
passo "ECS: servico, cluster e task definitions"
run aws ecs delete-service --cluster notas-cluster --service notas-service --force
run aws ecs delete-cluster --cluster notas-cluster
for td in $(aws ecs list-task-definitions --family-prefix notas-da-nuvem --query 'taskDefinitionArns[]' --output text 2>/dev/null); do
  run aws ecs deregister-task-definition --task-definition "$td"
done

# 3) Load balancer e target group
passo "ALB e target group"
LB="$(aws elbv2 describe-load-balancers --names notas-alb --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)"
if [[ -n "$LB" && "$LB" != "None" ]]; then
  run aws elbv2 delete-load-balancer --load-balancer-arn "$LB"
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$LB" 2>/dev/null
fi
TG="$(aws elbv2 describe-target-groups --names notas-tg --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)"
[[ -n "$TG" && "$TG" != "None" ]] && run aws elbv2 delete-target-group --target-group-arn "$TG"

# 4) Banco
passo "Aurora (caso tenha sido criado) e subnet group"
run aws rds delete-db-instance --db-instance-identifier notas-aurora-writer --skip-final-snapshot
run aws rds delete-db-cluster --db-cluster-identifier notas-aurora --skip-final-snapshot
aws rds wait db-cluster-deleted --db-cluster-identifier notas-aurora 2>/dev/null
run aws rds delete-db-subnet-group --db-subnet-group-name notas-db-subnets

# 5) Rede
if [[ -n "$VPC" ]]; then
  passo "NAT Gateway e Elastic IP"
  for nat in $(aws ec2 describe-nat-gateways --filter Name=vpc-id,Values="$VPC" Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId' --output text); do
    run aws ec2 delete-nat-gateway --nat-gateway-id "$nat"
    aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$nat" 2>/dev/null
  done
  for alloc in $(aws ec2 describe-addresses --filters Name=tag:Name,Values=notas-nat-eip --query 'Addresses[].AllocationId' --output text); do
    run aws ec2 release-address --allocation-id "$alloc"
  done

  passo "Internet Gateway"
  for igw in $(aws ec2 describe-internet-gateways --filters Name=attachment.vpc-id,Values="$VPC" --query 'InternetGateways[].InternetGatewayId' --output text); do
    run aws ec2 detach-internet-gateway --internet-gateway-id "$igw" --vpc-id "$VPC"
    run aws ec2 delete-internet-gateway --internet-gateway-id "$igw"
  done

  passo "Subnets e tabelas de rotas"
  for sn in $(aws ec2 describe-subnets --filters Name=vpc-id,Values="$VPC" --query 'Subnets[].SubnetId' --output text); do
    run aws ec2 delete-subnet --subnet-id "$sn"
  done
  for rt in $(aws ec2 describe-route-tables --filters Name=vpc-id,Values="$VPC" --query 'RouteTables[?length(Associations[?Main==`true`])==`0`].RouteTableId' --output text); do
    run aws ec2 delete-route-table --route-table-id "$rt"
  done

  passo "Security Groups"
  SGS="$(aws ec2 describe-security-groups --filters Name=vpc-id,Values="$VPC" --query 'SecurityGroups[?GroupName!=`default`].GroupId' --output text)"
  for sg in $SGS; do # primeiro remove as regras (um SG referencia o outro)
    aws ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].IpPermissions' > /tmp/in.json
    aws ec2 describe-security-groups --group-ids "$sg" --query 'SecurityGroups[0].IpPermissionsEgress' > /tmp/out.json
    [[ "$(jq length /tmp/in.json)" -gt 0 ]] && run aws ec2 revoke-security-group-ingress --group-id "$sg" --ip-permissions file:///tmp/in.json
    [[ "$(jq length /tmp/out.json)" -gt 0 ]] && run aws ec2 revoke-security-group-egress --group-id "$sg" --ip-permissions file:///tmp/out.json
  done
  for sg in $SGS; do run aws ec2 delete-security-group --group-id "$sg"; done

  passo "VPC"
  run aws ec2 delete-vpc --vpc-id "$VPC"
fi

# 6) ECR, IAM, logs
passo "ECR, roles IAM e log group"
run aws ecr delete-repository --repository-name notas-da-nuvem --force
for role in notas-ecs-execution notas-ecs-task; do
  for p in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text 2>/dev/null); do
    run aws iam detach-role-policy --role-name "$role" --policy-arn "$p"
  done
  for p in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text 2>/dev/null); do
    run aws iam delete-role-policy --role-name "$role" --policy-name "$p"
  done
  run aws iam delete-role --role-name "$role"
done
run aws logs delete-log-group --log-group-name /ecs/notas-da-nuvem

# 7) CloudFront: espera ficar 'Deployed' (desabilitado) e remove
passo "CloudFront: aguardando desabilitar para remover (pode levar 10 a 15 minutos)"
for id in $CF_IDS; do
  aws cloudfront wait distribution-deployed --id "$id" 2>/dev/null
  etag="$(aws cloudfront get-distribution-config --id "$id" --query ETag --output text)"
  run aws cloudfront delete-distribution --id "$id" --if-match "$etag"
done

passo "Conferencia final (tudo deve estar vazio)"
echo "VPC notas-vpc:   $(aws ec2 describe-vpcs --filters Name=tag:Name,Values=notas-vpc --query 'Vpcs[].VpcId' --output text)"
echo "NAT ativos:      $(aws ec2 describe-nat-gateways --filter Name=state,Values=available,pending --query 'NatGateways[].NatGatewayId' --output text)"
echo "Load balancers:  $(aws elbv2 describe-load-balancers --query 'LoadBalancers[].LoadBalancerName' --output text 2>/dev/null)"
echo "ECR:             $(aws ecr describe-repositories --query 'repositories[].repositoryName' --output text 2>/dev/null)"
echo "Elastic IPs:     $(aws ec2 describe-addresses --query 'Addresses[].PublicIp' --output text)"
echo "CloudFront:      $(aws cloudfront list-distributions --query "DistributionList.Items[?Comment=='notas-da-nuvem'].Id" --output text 2>/dev/null)"
echo
echo "Se algo ainda aparecer acima, apague-o no console ou me mande a saida deste script."
