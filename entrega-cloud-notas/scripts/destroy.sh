#!/usr/bin/env bash
# destroy.sh — DESLIGA TUDO para parar a cobrança. Rode assim que terminar os prints.
# O CloudFront demora ~10-15 min para ser removido; é normal.
set -euo pipefail

cd "$(cd "$(dirname "$0")/.." && pwd)/infra"
REGIAO="$(terraform output -raw region 2>/dev/null || echo us-east-1)"

terraform destroy

echo
echo "==> Conferindo se sobrou algo cobrando (região $REGIAO):"
echo "-- NAT Gateways ativos:"
aws ec2 describe-nat-gateways --region "$REGIAO" --filter Name=state,Values=available,pending \
  --query 'NatGateways[].NatGatewayId' --output text
echo "-- Load balancers:"
aws elbv2 describe-load-balancers --region "$REGIAO" --query 'LoadBalancers[].LoadBalancerName' --output text
echo "-- Clusters Aurora:"
aws rds describe-db-clusters --region "$REGIAO" --query 'DBClusters[].DBClusterIdentifier' --output text
echo "-- Elastic IPs soltos:"
aws ec2 describe-addresses --region "$REGIAO" --query 'Addresses[].PublicIp' --output text
echo
echo "Todas as listas acima devem estar vazias. Confira também o Billing no dia seguinte."
