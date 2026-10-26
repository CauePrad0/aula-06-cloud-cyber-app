#!/usr/bin/env bash
# select-notas.sh — EVIDÊNCIA DO BANCO: roda um SELECT na tabela "notas" a partir
# de DENTRO do container Fargate (o Aurora está em subnet privada, então não dá
# para acessar do seu computador).
#
# Usa o ECS Exec. Requer o "Session Manager plugin" instalado junto do AWS CLI
# (https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
# ou rode a partir do AWS CloudShell.
#
# Antes: abra o site, crie 2-3 notas, e só então rode este script.
set -euo pipefail

cd "$(cd "$(dirname "$0")/.." && pwd)/infra"
CLUSTER="$(terraform output -raw ecs_cluster)"
SERVICO="$(terraform output -raw ecs_service)"
REGIAO="$(terraform output -raw region)"

TASK="$(aws ecs list-tasks --region "$REGIAO" --cluster "$CLUSTER" --service-name "$SERVICO" \
        --desired-status RUNNING --query 'taskArns[0]' --output text)"
echo "Task: $TASK"

# O python do container já tem psycopg2 e as variáveis DB_* — não precisa instalar psql.
# O código vai em base64 só para evitar problemas de aspas na linha de comando.
CODIGO='
import os, psycopg2
c = psycopg2.connect(host=os.environ["DB_HOST"], dbname=os.environ["DB_NAME"],
                     user=os.environ["DB_USER"], password=os.environ["DB_PASSWORD"])
cur = c.cursor()
sql = "SELECT id, texto, criada_em FROM notas ORDER BY id DESC;"
print("DB_HOST =", os.environ["DB_HOST"])
print(sql)
cur.execute(sql)
for linha in cur.fetchall():
    print(linha)
'
B64="$(printf '%s' "$CODIGO" | base64 | tr -d '\n')"

aws ecs execute-command --region "$REGIAO" --cluster "$CLUSTER" --task "$TASK" \
  --container app --interactive \
  --command "/bin/sh -c 'echo $B64 | base64 -d | python'"
