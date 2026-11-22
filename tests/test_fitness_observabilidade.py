"""Fitness function de observabilidade.

Falha o build se um POST /notas deixar de gerar, no mesmo trace,
o span da requisição HTTP e o span do INSERT no banco.
"""
from opentelemetry import trace
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

# Os spans ficam em memória, sem Collector nem Grafana.
exporter = InMemorySpanExporter()
provider = TracerProvider()
provider.add_span_processor(SimpleSpanProcessor(exporter))
trace.set_tracer_provider(provider)

# Instrumentar antes de importar a aplicação, como faz o opentelemetry-instrument.
Psycopg2Instrumentor().instrument(enable_commenter=False)
import app as notas  # noqa: E402

FlaskInstrumentor().instrument_app(notas.app)


def test_post_notas_gera_span_http_e_span_do_insert():
    exporter.clear()
    resposta = notas.app.test_client().post("/notas", data={"texto": "nota do pipeline"})
    assert resposta.status_code in (302, 303)

    spans = exporter.get_finished_spans()
    nomes = [s.name for s in spans]

    http = [s for s in spans if s.kind == trace.SpanKind.SERVER]
    assert http, f"nenhum span HTTP foi gerado: {nomes}"

    insert = [s for s in spans if s.name.upper().startswith("INSERT")]
    assert insert, f"nenhum span do INSERT foi gerado: {nomes}"

    assert insert[0].context.trace_id == http[0].context.trace_id, \
        "o INSERT não está no mesmo trace da requisição"
