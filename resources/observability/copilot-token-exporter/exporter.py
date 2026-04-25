#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import sys
import threading
import time
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import urlopen

TOKEN_QUERY = '{ resource.service.name = "copilot" && span:name = "invoke_agent" }'
TOKEN_METRIC_NAME = "ai_agents_copilot_token_usage_total"
WINDOW_METRIC_NAME = "ai_agents_copilot_token_usage_window"
EXPORTER_PREFIX = "ai_agents_copilot_token_exporter"


def log(message: str) -> None:
    print(message, file=sys.stderr, flush=True)


def scalar_from_otel_value(value: Any) -> Any:
    if not isinstance(value, dict):
        return value

    for key in ("stringValue", "intValue", "doubleValue", "boolValue", "bytesValue"):
        if key in value:
            return value[key]

    if "arrayValue" in value:
        values = value["arrayValue"].get("values", [])
        return [scalar_from_otel_value(item) for item in values]

    if "kvlistValue" in value:
        values = value["kvlistValue"].get("values", [])
        return {
            item.get("key", ""): scalar_from_otel_value(item.get("value", {}))
            for item in values
            if item.get("key")
        }

    return None


def attributes_to_dict(attributes: list[dict[str, Any]] | None) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for attribute in attributes or []:
        key = attribute.get("key")
        if not key:
            continue
        result[key] = scalar_from_otel_value(attribute.get("value", {}))
    return result


def parse_int(value: Any) -> int:
    if value is None:
        return 0
    if isinstance(value, bool):
        return int(value)
    if isinstance(value, int):
        return value
    if isinstance(value, float):
        return int(value)
    if isinstance(value, str):
        stripped = value.strip()
        if not stripped:
            return 0
        try:
            return int(stripped)
        except ValueError:
            return int(float(stripped))
    return 0


def parse_unix_seconds(value: Any) -> int:
    raw = parse_int(value)
    if raw <= 0:
        return 0
    if raw > 10_000_000_000:
        return raw // 1_000_000_000
    return raw


def escape_label_value(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def has_token_usage(attrs: dict[str, Any]) -> bool:
    return any(
        key in attrs
        for key in (
            "gen_ai.usage.input_tokens",
            "gen_ai.usage.output_tokens",
            "gen_ai.usage.cache_read.input_tokens",
        )
    )


def span_model(attrs: dict[str, Any]) -> str | None:
    for key in ("gen_ai.request.model", "gen_ai.response.model"):
        value = attrs.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return None


@dataclass
class SpanSample:
    span_id: str
    name: str
    end_time_seconds: int
    model: str | None
    attrs: dict[str, Any]


@dataclass
class ExporterState:
    counters: dict[str, int] = field(default_factory=dict)
    processed_spans: dict[str, int] = field(default_factory=dict)
    span_records: dict[str, dict[str, Any]] = field(default_factory=dict)
    last_scan_end: int = 0
    last_success_timestamp: float = 0.0
    errors_total: int = 0
    truncated_searches_total: int = 0

    def increment_counter(self, token_type: str, model: str, amount: int) -> None:
        if amount <= 0:
            return
        key = f"{token_type}\n{model}"
        self.counters[key] = self.counters.get(key, 0) + amount

    def counter_items(self) -> list[tuple[str, str, int]]:
        items: list[tuple[str, str, int]] = []
        for key, value in sorted(self.counters.items()):
            token_type, model = key.split("\n", 1)
            items.append((token_type, model, value))
        return items

    def to_json(self) -> dict[str, Any]:
        return {
            "counters": self.counters,
            "processed_spans": self.processed_spans,
            "span_records": self.span_records,
            "last_scan_end": self.last_scan_end,
            "last_success_timestamp": self.last_success_timestamp,
            "errors_total": self.errors_total,
            "truncated_searches_total": self.truncated_searches_total,
        }

    @classmethod
    def from_json(cls, payload: dict[str, Any]) -> "ExporterState":
        if "span_records" not in payload:
            return cls()

        return cls(
            counters={
                str(key): parse_int(value)
                for key, value in payload.get("counters", {}).items()
            },
            processed_spans={
                str(key): parse_int(value)
                for key, value in payload.get("processed_spans", {}).items()
            },
            span_records={
                str(key): {
                    "timestamp": parse_int(value.get("timestamp")),
                    "model": str(value.get("model", "unknown")),
                    "cached_input": parse_int(value.get("cached_input")),
                    "output": parse_int(value.get("output")),
                    "uncached_input": parse_int(value.get("uncached_input")),
                    "uncached_total": parse_int(value.get("uncached_total")),
                }
                for key, value in payload.get("span_records", {}).items()
                if isinstance(value, dict)
            },
            last_scan_end=parse_int(payload.get("last_scan_end")),
            last_success_timestamp=float(payload.get("last_success_timestamp", 0.0)),
            errors_total=parse_int(payload.get("errors_total")),
            truncated_searches_total=parse_int(payload.get("truncated_searches_total")),
        )


class CopilotTokenExporter:
    def __init__(
        self,
        *,
        tempo_url: str,
        poll_interval_seconds: float,
        search_lookback_seconds: int,
        bootstrap_lookback_seconds: int,
        chunk_seconds: int,
        search_limit: int,
        state_path: Path,
        window_seconds: list[int],
    ) -> None:
        self.tempo_url = tempo_url.rstrip("/")
        self.poll_interval_seconds = poll_interval_seconds
        self.search_lookback_seconds = search_lookback_seconds
        self.bootstrap_lookback_seconds = bootstrap_lookback_seconds
        self.chunk_seconds = chunk_seconds
        self.search_limit = search_limit
        self.state_path = state_path
        self.window_seconds = sorted(set(window_seconds))
        self.lock = threading.Lock()
        self.stop_event = threading.Event()
        self.state = self.load_state()

    def load_state(self) -> ExporterState:
        if not self.state_path.exists():
            return ExporterState()

        try:
            payload = json.loads(self.state_path.read_text())
        except (OSError, json.JSONDecodeError) as error:
            log(f"failed to load exporter state from {self.state_path}: {error}")
            return ExporterState()

        return ExporterState.from_json(payload)

    def save_state(self) -> None:
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        tmp_path = self.state_path.with_suffix(".tmp")
        tmp_path.write_text(json.dumps(self.state.to_json(), sort_keys=True))
        tmp_path.replace(self.state_path)

    def get_json(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        query = f"?{urlencode(params)}" if params else ""
        request_url = f"{self.tempo_url}{path}{query}"
        with urlopen(request_url, timeout=60) as response:  # noqa: S310
            return json.loads(response.read().decode("utf-8"))

    def search_trace_ids(self, start_seconds: int, end_seconds: int) -> set[str]:
        params = {
            "q": TOKEN_QUERY,
            "start": start_seconds,
            "end": end_seconds,
            "limit": self.search_limit,
            "spss": 1,
        }
        payload = self.get_json("/api/search", params)
        traces = payload.get("traces", [])
        if len(traces) >= self.search_limit:
            with self.lock:
                self.state.truncated_searches_total += 1
            log(
                "search result hit the configured limit "
                f"({self.search_limit}) between {start_seconds} and {end_seconds}"
            )
        return {str(trace.get("traceID")) for trace in traces if trace.get("traceID")}

    def fetch_trace(self, trace_id: str) -> dict[str, Any]:
        return self.get_json(f"/api/v2/traces/{trace_id}")

    def extract_span_samples(self, trace_payload: dict[str, Any]) -> list[SpanSample]:
        samples: list[SpanSample] = []
        trace = trace_payload.get("trace", {})
        for resource_spans in trace.get("resourceSpans", []):
            for scope_spans in resource_spans.get("scopeSpans", []):
                for span in scope_spans.get("spans", []):
                    attrs = attributes_to_dict(span.get("attributes"))
                    if not has_token_usage(attrs):
                        continue
                    samples.append(
                        SpanSample(
                            span_id=str(span.get("spanId", "")),
                            name=str(span.get("name", "")),
                            end_time_seconds=parse_unix_seconds(span.get("endTimeUnixNano"))
                            or int(time.time()),
                            model=span_model(attrs),
                            attrs=attrs,
                        )
                    )
        return samples

    def select_candidate_spans(self, trace_payload: dict[str, Any]) -> list[SpanSample]:
        samples = self.extract_span_samples(trace_payload)
        detailed_spans = [
            sample
            for sample in samples
            if sample.name != "invoke_agent" and sample.model is not None
        ]
        if detailed_spans:
            return detailed_spans

        modeled_spans = [sample for sample in samples if sample.model is not None]
        if modeled_spans:
            return modeled_spans

        return [sample for sample in samples if sample.name == "invoke_agent"]

    def record_sample(self, trace_id: str, sample: SpanSample) -> None:
        dedupe_key = f"{trace_id}:{sample.span_id}"
        if dedupe_key in self.state.processed_spans:
            return

        input_tokens = parse_int(sample.attrs.get("gen_ai.usage.input_tokens"))
        cache_read_tokens = parse_int(
            sample.attrs.get("gen_ai.usage.cache_read.input_tokens")
        )
        output_tokens = parse_int(sample.attrs.get("gen_ai.usage.output_tokens"))
        if input_tokens == 0 and cache_read_tokens == 0 and output_tokens == 0:
            return

        uncached_input_tokens = max(input_tokens - cache_read_tokens, 0)
        uncached_total_tokens = uncached_input_tokens + output_tokens
        model = sample.model or "unknown"

        self.state.increment_counter("uncached_input", model, uncached_input_tokens)
        self.state.increment_counter("cached_input", model, cache_read_tokens)
        self.state.increment_counter("output", model, output_tokens)
        self.state.increment_counter("uncached_total", model, uncached_total_tokens)
        self.state.processed_spans[dedupe_key] = sample.end_time_seconds
        self.state.span_records[dedupe_key] = {
            "timestamp": sample.end_time_seconds,
            "model": model,
            "cached_input": cache_read_tokens,
            "output": output_tokens,
            "uncached_input": uncached_input_tokens,
            "uncached_total": uncached_total_tokens,
        }

    def prune_processed_spans(self, now_seconds: int) -> None:
        keep_after = now_seconds - max(
            self.bootstrap_lookback_seconds * 2,
            max(self.window_seconds, default=0) * 2,
        )
        self.state.processed_spans = {
            key: value
            for key, value in self.state.processed_spans.items()
            if value >= keep_after
        }
        self.state.span_records = {
            key: value
            for key, value in self.state.span_records.items()
            if parse_int(value.get("timestamp")) >= keep_after
        }

    def window_totals(
        self, state: ExporterState, now_seconds: int
    ) -> list[tuple[int, str, str, int]]:
        totals: dict[tuple[int, str, str], int] = {}
        for window in self.window_seconds:
            keep_after = now_seconds - window
            for record in state.span_records.values():
                if parse_int(record.get("timestamp")) < keep_after:
                    continue
                model = str(record.get("model", "unknown"))
                for token_type in (
                    "cached_input",
                    "output",
                    "uncached_input",
                    "uncached_total",
                ):
                    amount = parse_int(record.get(token_type))
                    if amount <= 0:
                        continue
                    key = (window, token_type, model)
                    totals[key] = totals.get(key, 0) + amount
        return [
            (window, token_type, model, value)
            for (window, token_type, model), value in sorted(totals.items())
        ]

    def poll_once(self) -> None:
        now_seconds = int(time.time())
        with self.lock:
            if self.state.last_scan_end > 0:
                scan_start = max(self.state.last_scan_end - self.search_lookback_seconds, 0)
            else:
                scan_start = max(now_seconds - self.bootstrap_lookback_seconds, 0)
            scan_end = now_seconds

        trace_ids: set[str] = set()
        chunk_start = scan_start
        while chunk_start < scan_end:
            chunk_end = min(chunk_start + self.chunk_seconds, scan_end)
            try:
                trace_ids.update(self.search_trace_ids(chunk_start, chunk_end))
            except (HTTPError, URLError, OSError, json.JSONDecodeError) as error:
                with self.lock:
                    self.state.errors_total += 1
                log(
                    "failed to search copilot traces "
                    f"between {chunk_start} and {chunk_end}: {error}"
                )
            chunk_start = chunk_end

        for trace_id in sorted(trace_ids):
            try:
                trace_payload = self.fetch_trace(trace_id)
                candidates = self.select_candidate_spans(trace_payload)
                with self.lock:
                    for sample in candidates:
                        self.record_sample(trace_id, sample)
            except (HTTPError, URLError, OSError, json.JSONDecodeError) as error:
                with self.lock:
                    self.state.errors_total += 1
                log(f"failed to process copilot trace {trace_id}: {error}")

        with self.lock:
            self.state.last_scan_end = scan_end
            self.state.last_success_timestamp = time.time()
            self.prune_processed_spans(scan_end)
            self.save_state()

    def poll_forever(self) -> None:
        while not self.stop_event.is_set():
            self.poll_once()
            self.stop_event.wait(self.poll_interval_seconds)

    def metrics_text(self) -> str:
        with self.lock:
            state = ExporterState.from_json(self.state.to_json())

        lines = [
            f"# HELP {TOKEN_METRIC_NAME} Copilot token usage derived from Tempo traces, with cached input separated from uncached usage.",
            f"# TYPE {TOKEN_METRIC_NAME} counter",
        ]
        for token_type, model, value in state.counter_items():
            lines.append(
                f'{TOKEN_METRIC_NAME}{{type="{escape_label_value(token_type)}",model="{escape_label_value(model)}"}} {value}'
            )

        lines.extend(
            [
                f"# HELP {WINDOW_METRIC_NAME} Copilot token usage derived from Tempo traces for specific rolling windows.",
                f"# TYPE {WINDOW_METRIC_NAME} gauge",
            ]
        )
        for window, token_type, model, value in self.window_totals(
            state, int(time.time())
        ):
            lines.append(
                f'{WINDOW_METRIC_NAME}{{window="{window}s",type="{escape_label_value(token_type)}",model="{escape_label_value(model)}"}} {value}'
            )

        lines.extend(
            [
                f"# HELP {EXPORTER_PREFIX}_last_success_timestamp_seconds Unix timestamp of the last completed Tempo poll.",
                f"# TYPE {EXPORTER_PREFIX}_last_success_timestamp_seconds gauge",
                f"{EXPORTER_PREFIX}_last_success_timestamp_seconds {state.last_success_timestamp}",
                f"# HELP {EXPORTER_PREFIX}_last_scan_end_seconds Unix timestamp of the newest scan boundary already covered by the exporter.",
                f"# TYPE {EXPORTER_PREFIX}_last_scan_end_seconds gauge",
                f"{EXPORTER_PREFIX}_last_scan_end_seconds {state.last_scan_end}",
                f"# HELP {EXPORTER_PREFIX}_processed_spans Number of processed spans currently retained for deduplication.",
                f"# TYPE {EXPORTER_PREFIX}_processed_spans gauge",
                f"{EXPORTER_PREFIX}_processed_spans {len(state.processed_spans)}",
                f"# HELP {EXPORTER_PREFIX}_errors_total Number of Tempo polling or parsing errors.",
                f"# TYPE {EXPORTER_PREFIX}_errors_total counter",
                f"{EXPORTER_PREFIX}_errors_total {state.errors_total}",
                f"# HELP {EXPORTER_PREFIX}_truncated_searches_total Number of Tempo search windows that hit the configured trace limit.",
                f"# TYPE {EXPORTER_PREFIX}_truncated_searches_total counter",
                f"{EXPORTER_PREFIX}_truncated_searches_total {state.truncated_searches_total}",
                "",
            ]
        )
        return "\n".join(lines)

    def serve(self, listen_host: str, listen_port: int) -> None:
        exporter = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                if self.path in {"/metrics", "/metrics/"}:
                    body = exporter.metrics_text().encode("utf-8")
                    self.send_response(200)
                    self.send_header("Content-Type", "text/plain; version=0.0.4")
                    self.send_header("Content-Length", str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return

                if self.path in {"/healthz", "/healthz/"}:
                    self.send_response(200)
                    self.send_header("Content-Length", "2")
                    self.end_headers()
                    self.wfile.write(b"ok")
                    return

                self.send_response(404)
                self.send_header("Content-Length", "0")
                self.end_headers()

            def log_message(self, format: str, *args: Any) -> None:  # noqa: A003
                return

        poller = threading.Thread(target=self.poll_forever, name="tempo-poller", daemon=True)
        poller.start()
        server = ThreadingHTTPServer((listen_host, listen_port), Handler)
        try:
            server.serve_forever()
        except KeyboardInterrupt:
            pass
        finally:
            self.stop_event.set()
            server.server_close()
            poller.join(timeout=2)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Expose Copilot token counters derived from Tempo traces, including "
            "uncached totals that subtract cache-read input tokens."
        )
    )
    parser.add_argument("--tempo-url", default="http://tempo:3200")
    parser.add_argument("--listen-host", default="0.0.0.0")
    parser.add_argument("--listen-port", default=9561, type=int)
    parser.add_argument("--poll-interval", default=30.0, type=float)
    parser.add_argument("--search-lookback", default=600, type=int)
    parser.add_argument("--bootstrap-lookback", default=86_400, type=int)
    parser.add_argument("--chunk-seconds", default=1800, type=int)
    parser.add_argument("--search-limit", default=1000, type=int)
    parser.add_argument(
        "--window-seconds",
        default="300,900,1800,3600,7200,10800,21600,43200,86400",
    )
    parser.add_argument(
        "--state-path",
        default="/var/lib/copilot-token-exporter/state.json",
        type=Path,
    )
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--print-metrics", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    window_seconds = [
        parse_int(chunk)
        for chunk in str(args.window_seconds).split(",")
        if parse_int(chunk) > 0
    ]
    exporter = CopilotTokenExporter(
        tempo_url=args.tempo_url,
        poll_interval_seconds=args.poll_interval,
        search_lookback_seconds=args.search_lookback,
        bootstrap_lookback_seconds=args.bootstrap_lookback,
        chunk_seconds=args.chunk_seconds,
        search_limit=args.search_limit,
        state_path=args.state_path,
        window_seconds=window_seconds,
    )

    if args.once:
        exporter.poll_once()
        if args.print_metrics:
            print(exporter.metrics_text())
        return 0

    exporter.serve(args.listen_host, args.listen_port)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
