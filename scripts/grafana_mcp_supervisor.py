#!/usr/bin/env python3
from __future__ import annotations

import json
import os
import pathlib
import signal
import subprocess
import sys
import threading
import time
from typing import Any, BinaryIO


ROOT = pathlib.Path(__file__).resolve().parent.parent
CHILD_COMMAND = [str(ROOT / "scripts" / "observability.sh"), "--launch-grafana-mcp-child"]
POLL_INTERVAL_SECONDS = 0.5
READY_TIMEOUT_SECONDS = 30.0
FINGERPRINT_SETTLE_SECONDS = 0.5
TRACE_PATH_ENV = "HARNESS_GRAFANA_MCP_TRACE"
CLIENT_TRANSPORT_FRAMED = "framed"
CLIENT_TRANSPORT_LINE = "line"
HARNESS_MONITOR_APP_GROUP_ID_DEFAULT = os.environ.get(
    "HARNESS_MONITOR_APP_GROUP_ID_DEFAULT",
    "Q498EB36N4.io.harnessmonitor",
)


def trace(message: str, payload: dict[str, Any] | None = None) -> None:
    trace_path = os.environ.get(TRACE_PATH_ENV)
    if not trace_path:
        return
    line = f"{time.time():.6f} {message}"
    if payload is not None:
        line += f" {json.dumps(payload, separators=(',', ':'), ensure_ascii=True)}"
    with open(trace_path, "a", encoding="utf-8") as handle:
        handle.write(line + "\n")


def resolve_data_root() -> pathlib.Path:
    xdg_data_home = os.environ.get("XDG_DATA_HOME")
    if xdg_data_home:
        return pathlib.Path(xdg_data_home)
    if sys.platform == "darwin":
        return pathlib.Path.home() / "Library" / "Application Support"
    return pathlib.Path.home() / ".local" / "share"


def resolve_config_root() -> pathlib.Path:
    xdg_config_home = os.environ.get("XDG_CONFIG_HOME")
    if xdg_config_home:
        return pathlib.Path(xdg_config_home)
    return pathlib.Path.home() / ".config"


def runtime_shared_config_path() -> pathlib.Path:
    return resolve_data_root() / "harness" / "observability" / "config.json"


def resolve_monitor_data_root() -> pathlib.Path:
    daemon_data_home = os.environ.get("HARNESS_DAEMON_DATA_HOME", "").strip()
    if daemon_data_home:
        return pathlib.Path(daemon_data_home)
    xdg_data_home = os.environ.get("XDG_DATA_HOME", "").strip()
    if xdg_data_home:
        return pathlib.Path(xdg_data_home)
    app_group_id = os.environ.get("HARNESS_APP_GROUP_ID", "").strip()
    if sys.platform == "darwin":
        if not app_group_id:
            app_group_id = HARNESS_MONITOR_APP_GROUP_ID_DEFAULT
        return pathlib.Path.home() / "Library" / "Group Containers" / app_group_id
    return resolve_data_root()


def monitor_shared_config_path() -> pathlib.Path:
    return resolve_monitor_data_root() / "harness" / "observability" / "config.json"


def shared_config_candidates() -> list[pathlib.Path]:
    runtime_path = runtime_shared_config_path()
    monitor_path = monitor_shared_config_path()
    if monitor_path == runtime_path:
        return [runtime_path]
    return [runtime_path, monitor_path]


def grafana_mcp_token_path() -> pathlib.Path:
    return resolve_config_root() / "harness" / "observability" / "grafana-mcp.token"


def read_client_message(stream: BinaryIO) -> tuple[dict[str, Any] | None, str | None]:
    first_line = stream.readline()
    if first_line == b"":
        return None, None
    while first_line in (b"\r\n", b"\n"):
        first_line = stream.readline()
        if first_line == b"":
            return None, None

    if first_line.lstrip().startswith(b"{"):
        payload = json.loads(first_line.decode("utf-8"))
        trace("client->supervisor", payload)
        return payload, CLIENT_TRANSPORT_LINE

    content_length: int | None = None
    line = first_line
    while True:
        if line in (b"\r\n", b"\n"):
            break
        header = line.decode("utf-8").strip()
        if header.lower().startswith("content-length:"):
            content_length = int(header.split(":", 1)[1].strip())
        line = stream.readline()
        if line == b"":
            return None, None
    if content_length is None:
        raise RuntimeError("missing Content-Length header")
    body = stream.read(content_length)
    if len(body) != content_length:
        return None, None
    payload = json.loads(body.decode("utf-8"))
    trace("client->supervisor", payload)
    return payload, CLIENT_TRANSPORT_FRAMED


def write_client_message(
    stream: BinaryIO,
    payload: dict[str, Any],
    transport: str | None,
) -> None:
    trace("supervisor->client", payload)
    if transport == CLIENT_TRANSPORT_LINE:
        body = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
        stream.write(body + b"\n")
        stream.flush()
        return
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    stream.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii"))
    stream.write(body)
    stream.flush()


def read_child_message(stream: BinaryIO) -> dict[str, Any] | None:
    # grafana/mcp-grafana currently uses newline-delimited JSON-RPC on stdio,
    # while Codex expects MCP's Content-Length framing.
    while True:
        line = stream.readline()
        if line == b"":
            return None
        stripped = line.strip()
        if not stripped:
            continue
        payload = json.loads(stripped.decode("utf-8"))
        trace("child->supervisor", payload)
        return payload


def write_child_message(stream: BinaryIO, payload: dict[str, Any]) -> None:
    trace("supervisor->child", payload)
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    stream.write(body + b"\n")
    stream.flush()


class ChildState:
    def __init__(self, process: subprocess.Popen[bytes]) -> None:
        self.process = process
        self.ready_event = threading.Event()
        self.write_lock = threading.Lock()
        self.swallow_initialize_id: Any = None


class Supervisor:
    def __init__(self, child_args: list[str]) -> None:
        self.child_args = child_args
        self.state_lock = threading.RLock()
        self.client_stdout_lock = threading.Lock()
        self.running = True
        self.child_state: ChildState | None = None
        self.client_transport: str | None = None
        self.fingerprint = self.compute_fingerprint()
        self.initialize_request: dict[str, Any] | None = None
        self.initialized_notification: dict[str, Any] | None = None
        self.monitor_thread = threading.Thread(target=self.monitor_loop, daemon=True)

    def compute_fingerprint(self) -> bytes | None:
        config_bytes: bytes | None = None
        for config_path in shared_config_candidates():
            if config_path.exists():
                config_bytes = config_path.read_bytes()
                break
        if config_bytes is None:
            return None
        token_path = grafana_mcp_token_path()
        if token_path.exists():
            token_bytes = token_path.read_bytes()
        else:
            token_bytes = b""
        return config_bytes + b"\0" + token_bytes

    def start_child_locked(self) -> ChildState:
        previous_fingerprint = self.compute_fingerprint()
        trace("start-child", {"args": self.child_args})
        process = subprocess.Popen(
            CHILD_COMMAND + self.child_args,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        child_state = ChildState(process)
        self.child_state = child_state
        threading.Thread(
            target=self.forward_child_stdout,
            args=(child_state,),
            daemon=True,
        ).start()
        threading.Thread(
            target=self.forward_child_stderr,
            args=(child_state,),
            daemon=True,
        ).start()
        if self.initialize_request is None:
            child_state.ready_event.set()
        else:
            child_state.swallow_initialize_id = self.initialize_request.get("id")
            self.write_to_child_locked(child_state, self.initialize_request)
            if self.initialized_notification is not None:
                self.write_to_child_locked(child_state, self.initialized_notification)
        self.fingerprint = self.await_child_fingerprint(previous_fingerprint, child_state)
        return child_state

    def await_child_fingerprint(
        self,
        previous_fingerprint: bytes | None,
        child_state: ChildState,
    ) -> bytes | None:
        deadline = time.monotonic() + 1.5
        current_fingerprint = self.compute_fingerprint()
        while (
            current_fingerprint == previous_fingerprint
            and child_state.process.poll() is None
            and time.monotonic() < deadline
        ):
            time.sleep(0.05)
            current_fingerprint = self.compute_fingerprint()
        return current_fingerprint

    def await_stable_fingerprint(self, initial_fingerprint: bytes | None) -> bytes | None:
        stable_fingerprint = initial_fingerprint
        deadline = time.monotonic() + FINGERPRINT_SETTLE_SECONDS
        while self.running and time.monotonic() < deadline:
            time.sleep(0.05)
            current_fingerprint = self.compute_fingerprint()
            if current_fingerprint != stable_fingerprint:
                stable_fingerprint = current_fingerprint
                deadline = time.monotonic() + FINGERPRINT_SETTLE_SECONDS
        return stable_fingerprint

    def stop_child_locked(self) -> None:
        child_state = self.child_state
        self.child_state = None
        if child_state is None:
            return
        process = child_state.process
        trace("stop-child", {"pid": process.pid, "returncode": process.poll()})
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    def restart_child(self) -> None:
        trace("restart-child")
        with self.state_lock:
            self.stop_child_locked()
            if not self.running:
                return
            if self.compute_fingerprint() is None:
                self.fingerprint = None
                return
            self.start_child_locked()

    def ensure_child_ready(self) -> ChildState:
        with self.state_lock:
            child_state = self.child_state
            if child_state is None or child_state.process.poll() is not None:
                child_state = self.start_child_locked()
        if not child_state.ready_event.wait(timeout=READY_TIMEOUT_SECONDS):
            trace("child-ready-timeout", {"pid": child_state.process.pid})
            self.restart_child()
            with self.state_lock:
                child_state = self.child_state
            if child_state is None or not child_state.ready_event.wait(timeout=READY_TIMEOUT_SECONDS):
                raise RuntimeError("timed out waiting for Grafana MCP child readiness")
        return child_state

    def write_to_child_locked(self, child_state: ChildState, payload: dict[str, Any]) -> None:
        stdin = child_state.process.stdin
        if stdin is None:
            raise RuntimeError("Grafana MCP child stdin is unavailable")
        with child_state.write_lock:
            write_child_message(stdin, payload)

    def forward_child_stdout(self, child_state: ChildState) -> None:
        stdout = child_state.process.stdout
        if stdout is None:
            return
        try:
            while self.running:
                message = read_child_message(stdout)
                if message is None:
                    return
                if child_state.swallow_initialize_id is not None:
                    if message.get("id") == child_state.swallow_initialize_id:
                        trace("swallow-initialize-response", message)
                        child_state.swallow_initialize_id = None
                        child_state.ready_event.set()
                        with self.state_lock:
                            self.fingerprint = self.compute_fingerprint()
                    continue
                with self.state_lock:
                    client_transport = self.client_transport
                with self.client_stdout_lock:
                    write_client_message(sys.stdout.buffer, message, client_transport)
        finally:
            with self.state_lock:
                if self.child_state is child_state:
                    self.child_state = None

    def forward_child_stderr(self, child_state: ChildState) -> None:
        stderr = child_state.process.stderr
        if stderr is None:
            return
        for chunk in iter(lambda: stderr.readline(), b""):
            if not self.running:
                return
            if self.child_state is not child_state:
                return
            sys.stderr.buffer.write(chunk)
            sys.stderr.buffer.flush()

    def monitor_loop(self) -> None:
        while self.running:
            time.sleep(POLL_INTERVAL_SECONDS)
            fingerprint = self.compute_fingerprint()
            with self.state_lock:
                child_state = self.child_state
                known_fingerprint = self.fingerprint
            child_exited = child_state is not None and child_state.process.poll() is not None
            if fingerprint != known_fingerprint:
                fingerprint = self.await_stable_fingerprint(fingerprint)
                with self.state_lock:
                    known_fingerprint = self.fingerprint
                if fingerprint != known_fingerprint:
                    trace("fingerprint-changed", {"known": known_fingerprint is not None, "current": fingerprint is not None})
                    self.restart_child()
                    continue
            if child_exited:
                self.restart_child()

    def run(self) -> int:
        signal.signal(signal.SIGTERM, self.handle_signal)
        signal.signal(signal.SIGINT, self.handle_signal)
        try:
            self.monitor_thread.start()
            while True:
                trace("await-client-message")
                message, client_transport = read_client_message(sys.stdin.buffer)
                if message is None:
                    trace("client-eof")
                    return 0
                with self.state_lock:
                    if self.client_transport is None:
                        self.client_transport = client_transport
                        trace("record-client-transport", {"transport": client_transport})
                method = message.get("method")
                if method == "initialize" and "id" in message:
                    self.initialize_request = message
                    trace("record-initialize-request", message)
                elif method == "notifications/initialized":
                    self.initialized_notification = message
                    trace("record-initialized-notification", message)
                child_state = self.ensure_child_ready()
                try:
                    self.write_to_child_locked(child_state, message)
                except (BrokenPipeError, OSError):
                    self.restart_child()
                    child_state = self.ensure_child_ready()
                    self.write_to_child_locked(child_state, message)
        finally:
            self.running = False
            with self.state_lock:
                self.stop_child_locked()

    def handle_signal(self, signum: int, _frame: Any) -> None:
        self.running = False
        with self.state_lock:
            self.stop_child_locked()
        raise SystemExit(128 + signum)


def main() -> int:
    return Supervisor(sys.argv[1:]).run()


if __name__ == "__main__":
    raise SystemExit(main())
