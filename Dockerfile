# Imagem da aplicação "Notas da Nuvem" (Flask + gunicorn).
# Build para Fargate x86_64:  docker build --platform linux/amd64 -t notas-da-nuvem .

FROM python:3.12-slim

# Logs sem buffer (aparecem na hora no CloudWatch) e sem .pyc
ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

WORKDIR /app

# Dependências primeiro: se só o código mudar, esta camada vem do cache
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY templates/ templates/

# Não roda como root dentro do container
RUN useradd --create-home appuser
USER appuser

EXPOSE 8080

# 1 worker + threads: o app abre uma conexão por requisição e faz wait_for_db()
# ao importar o módulo; --timeout 120 evita o gunicorn matar o worker enquanto
# ele espera o Aurora (até ~30s).
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "4", "--timeout", "120", "app:app"]
