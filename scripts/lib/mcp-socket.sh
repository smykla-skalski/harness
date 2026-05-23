#!/usr/bin/env bash

mcp_probe_socket() {
  local socket_path="$1"
  python3 - "$socket_path" <<'PY'
import json
import os
import socket
import sys

path = sys.argv[1]
token = os.environ.get("HARNESS_MONITOR_MCP_TOKEN")
if not token:
    token_path = os.environ.get("HARNESS_MONITOR_MCP_TOKEN_FILE")
    if not token_path:
        token_path = os.path.join(os.path.dirname(path), "mcp.token")
    try:
        with open(token_path, encoding="utf-8") as handle:
            token = handle.read().strip()
    except FileNotFoundError:
        token = None

request_payload = {"id": 1, "op": "ping"}
if token:
    request_payload["token"] = token
request = json.dumps(request_payload, separators=(",", ":")).encode("utf-8") + b"\n"
sock = None

try:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(1.0)
    sock.connect(path)
    sock.sendall(request)
    response = b""
    while not response.endswith(b"\n"):
        chunk = sock.recv(65536)
        if not chunk:
            raise RuntimeError("registry closed connection before ping response")
        response += chunk
except Exception as error:
    print(error, file=sys.stderr)
    sys.exit(1)
finally:
    if sock is not None:
        sock.close()

try:
    payload = json.loads(response.decode("utf-8"))
except Exception as error:
    print(f"invalid registry ping response: {error}", file=sys.stderr)
    sys.exit(1)

result = payload.get("result")
if payload.get("id") != 1 or payload.get("ok") is not True or not isinstance(result, dict):
    print(f"unexpected registry ping response: {payload!r}", file=sys.stderr)
    sys.exit(1)
if result.get("protocolVersion") != 1:
    print(f"unexpected registry protocol version: {result!r}", file=sys.stderr)
    sys.exit(1)
PY
}
