# 0017 · Observability: OpenTelemetry to New Relic

Date: 2026-11-16 · Status: accepted · Design: docs/design/observability.md

## Decision
- The agent service and the voice worker send traces, metrics and the `orb` logs over OpenTelemetry (OTLP/HTTP) to
  New Relic, only when `NEW_RELIC_LICENSE_KEY` is set. Without it, nothing is set up or sent.
- The voice worker hands the tracer to LiveKit Agents, which traces each call (VAD, STT, LLM, TTS, Gemini realtime,
  tokens). The agent service records each turn as an `orb.turn` span, built from the events the brain already yields.
- The person's text, the reply and the persona note are sent only with `ORB_LOG_TEXT=1`, the rule of the log files.

## Why
A call and a turn can be read on one dashboard instead of in log files. OpenTelemetry is the open standard: another
backend (Langfuse, Grafana) needs another endpoint and key, not code. New Relic's free tier covers a few calls a day,
and a cloud backend costs the 16 GB Mac no memory.

## Rejected
- A local Grafana, Loki and Tempo stack: free, but it takes memory the models need.
- The New Relic Python agent: it is New Relic only; OpenTelemetry is not.
- Spans inside orb-discussion: the brain's events already carry the steps and their timing, so the brain stays as it is.
