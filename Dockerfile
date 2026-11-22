FROM public.ecr.aws/docker/library/python:3.12-slim
ENV PYTHONUNBUFFERED=1
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt \
      opentelemetry-distro opentelemetry-exporter-otlp \
 && opentelemetry-bootstrap -a install
COPY app.py .
COPY templates/ templates/
RUN useradd --system --uid 10001 --no-create-home app
USER 10001
EXPOSE 8080
CMD ["opentelemetry-instrument", "python", "app.py"]
