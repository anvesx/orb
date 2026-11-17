"""OpenTelemetry traces, metrics and the orb logs, sent to New Relic over OTLP/HTTP.

Nothing is set up or sent unless NEW_RELIC_LICENSE_KEY is set. The person's words and the replies are sent only with
ORB_LOG_TEXT=1, the rule of the log files.
"""
from __future__ import annotations

import asyncio
import logging
import os
import time
from typing import AsyncIterator

from orb_core.agent import Event

KEY = "NEW_RELIC_LICENSE_KEY"
ENDPOINT = "https://otlp.nr-data.net"

_providers: list = []


def text_allowed() -> bool:
    return os.environ.get("ORB_LOG_TEXT", "").strip().lower() in ("1", "true", "yes", "on")


def start(service: str):
    """Returns the tracer provider, or None when the key is not set."""
    key = os.environ.get(KEY, "").strip()
    if not key:
        return None
    if _providers:
        return _providers[0]
    from opentelemetry import metrics, trace
    from opentelemetry.exporter.otlp.proto.http._log_exporter import OTLPLogExporter
    from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
    from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
    from opentelemetry.sdk._logs import LoggerProvider, LoggingHandler
    from opentelemetry.sdk._logs.export import BatchLogRecordProcessor
    from opentelemetry.sdk.metrics import MeterProvider
    from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
    from opentelemetry.sdk.resources import Resource
    from opentelemetry.sdk.trace import TracerProvider
    from opentelemetry.sdk.trace.export import BatchSpanProcessor

    base = (os.environ.get("OTEL_EXPORTER_OTLP_ENDPOINT", "").strip() or ENDPOINT).rstrip("/")
    headers = {"api-key": key}
    resource = Resource.create({"service.name": service})
    tracer = TracerProvider(resource=resource)
    tracer.add_span_processor(BatchSpanProcessor(OTLPSpanExporter(endpoint=f"{base}/v1/traces", headers=headers)))
    meter = MeterProvider(resource=resource, metric_readers=[
        PeriodicExportingMetricReader(OTLPMetricExporter(endpoint=f"{base}/v1/metrics", headers=headers))])
    logs = LoggerProvider(resource=resource)
    logs.add_log_record_processor(BatchLogRecordProcessor(OTLPLogExporter(endpoint=f"{base}/v1/logs", headers=headers)))
    trace.set_tracer_provider(tracer)
    metrics.set_meter_provider(meter)
    # the logger provider stays private: LiveKit Agents adopts a global one and adds its own root handler to it, which
    # sent every orb line twice, and orb's lines to LiveKit Cloud
    logging.getLogger("orb").addHandler(LoggingHandler(logger_provider=logs))
    others = LoggingHandler(level=logging.WARNING, logger_provider=logs)
    others.addFilter(lambda r: r.name != "orb" and not r.name.startswith("orb."))
    logging.getLogger().addHandler(others)
    _providers[:] = [tracer, meter, logs]
    return tracer


def flush() -> None:
    for p in _providers:
        p.force_flush(timeout_millis=5000)


async def traced(events: AsyncIterator[Event], sid: str, channel: str, text: str,
                 provider=None) -> AsyncIterator[Event]:
    """Passes the events of one turn on unchanged and records them as an `orb.turn` span, with `jev.read`, `llm` and
    `jev.read_ai` child spans placed by the turn's timing."""
    provider = provider or (_providers[0] if _providers else None)
    if provider is None:
        async for ev in events:
            yield ev
        return
    from opentelemetry import trace
    from opentelemetry.trace import Status, StatusCode

    tracer = provider.get_tracer("orb")
    words = text_allowed()
    span = tracer.start_span("orb.turn", attributes={"orb.session": sid, "orb.channel": channel})
    parent = trace.set_span_in_context(span)
    if words:
        span.set_attribute("orb.text", text)
    read_end = reply_at = None
    try:
        async for ev in events:
            now = time.time_ns()
            data = ev.data if isinstance(ev.data, dict) else {}
            if ev.type == "read":
                read_end = now
            elif ev.type == "decision":
                for k in ("persona", "debt", "kind", "stage"):
                    if data.get(k) is not None:
                        span.set_attribute(f"orb.{k}", str(data[k]))
                if words and data.get("note"):
                    span.set_attribute("orb.note", data["note"])
            elif ev.type == "reply":
                timing = data.get("timing") or {}
                for k, v in timing.items():
                    if isinstance(v, (int, float)):
                        span.set_attribute(f"orb.timing.{k}", v)
                if read_end is not None and isinstance(timing.get("read_human"), (int, float)):
                    tracer.start_span("jev.read", context=parent,
                                      start_time=read_end - int(timing["read_human"] * 1e9)).end(end_time=read_end)
                if isinstance(timing.get("llm_total"), (int, float)):
                    llm = tracer.start_span("llm", context=parent, start_time=now - int(timing["llm_total"] * 1e9))
                    if timing.get("llm_first_token") is not None:
                        llm.set_attribute("orb.first_token", timing["llm_first_token"])
                    llm.end(end_time=now)
                reply_at = now
                span.set_attribute("orb.reply_chars", len(data.get("text") or ""))
                if words:
                    span.set_attribute("orb.reply", data.get("text") or "")
            elif ev.type == "check":
                if reply_at is not None:
                    tracer.start_span("jev.read_ai", context=parent, start_time=reply_at).end(end_time=now)
                if data.get("done") is not None:
                    span.set_attribute("orb.check_done", bool(data["done"]))
            elif ev.type == "error":
                span.set_status(Status(StatusCode.ERROR, str(ev.data) if words else "error"))
            yield ev
    except (GeneratorExit, asyncio.CancelledError):
        span.set_attribute("orb.cancelled", True)
        raise
    except Exception as e:
        span.set_status(Status(StatusCode.ERROR, f"{type(e).__name__}: {e}" if words else type(e).__name__))
        raise
    finally:
        span.end()
