#!/usr/bin/env bash

mcp_probe_socket() {
  local socket_path="$1"
  python3 - "$socket_path" <<'PY'
import json
import socket
import sys

path = sys.argv[1]
request = b'{"id":1,"op":"ping"}\n'
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
