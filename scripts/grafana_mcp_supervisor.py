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


def grafana_mcp_token_path() -> pathlib.Path:
    return resolve_config_root() / "harness" / "observability" / "grafana-mcp.token"


def read_message(stream: BinaryIO) -> dict[str, Any] | None:
    content_length: int | None = None
    while True:
        line = stream.readline()
        if line == b"":
            return None
        if line in (b"\r\n", b"\n"):
            break
        header = line.decode("utf-8").strip()
        if header.lower().startswith("content-length:"):
            content_length = int(header.split(":", 1)[1].strip())
    if content_length is None:
        raise RuntimeError("missing Content-Length header")
    body = stream.read(content_length)
    if len(body) != content_length:
        return None
    return json.loads(body.decode("utf-8"))


def write_message(stream: BinaryIO, payload: dict[str, Any]) -> None:
    body = json.dumps(payload, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    stream.write(f"Content-Length: {len(body)}\r\n\r\n".encode("ascii"))
    stream.write(body)
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
        self.fingerprint = self.compute_fingerprint()
        self.initialize_request: dict[str, Any] | None = None
        self.initialized_notification: dict[str, Any] | None = None
        self.monitor_thread = threading.Thread(target=self.monitor_loop, daemon=True)

    def compute_fingerprint(self) -> bytes | None:
        config_path = runtime_shared_config_path()
        if not config_path.exists():
            return None
        config_bytes = config_path.read_bytes()
        token_path = grafana_mcp_token_path()
        if token_path.exists():
            token_bytes = token_path.read_bytes()
        else:
            token_bytes = b""
        return config_bytes + b"\0" + token_bytes

    def start_child_locked(self) -> ChildState:
        previous_fingerprint = self.compute_fingerprint()
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

    def stop_child_locked(self) -> None:
        child_state = self.child_state
        self.child_state = None
        if child_state is None:
            return
        process = child_state.process
        if process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)

    def restart_child(self) -> None:
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
            write_message(stdin, payload)

    def forward_child_stdout(self, child_state: ChildState) -> None:
        stdout = child_state.process.stdout
        if stdout is None:
            return
        try:
            while self.running:
                message = read_message(stdout)
                if message is None:
                    return
                if child_state.swallow_initialize_id is not None:
                    if message.get("id") == child_state.swallow_initialize_id:
                        child_state.swallow_initialize_id = None
                        child_state.ready_event.set()
                    continue
                with self.client_stdout_lock:
                    write_message(sys.stdout.buffer, message)
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
            if fingerprint != known_fingerprint or child_exited:
                self.restart_child()

    def run(self) -> int:
        signal.signal(signal.SIGTERM, self.handle_signal)
        signal.signal(signal.SIGINT, self.handle_signal)
        try:
            if self.compute_fingerprint() is not None:
                self.restart_child()
            self.monitor_thread.start()
            while True:
                message = read_message(sys.stdin.buffer)
                if message is None:
                    return 0
                method = message.get("method")
                if method == "initialize" and "id" in message:
                    self.initialize_request = message
                elif method == "notifications/initialized":
                    self.initialized_notification = message
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
