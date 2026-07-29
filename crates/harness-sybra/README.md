# harness-sybra

`harness-sybra` is a standalone loopback compatibility service for the Sybra browser UI. It serves public root assets, protects RPC and event routes with a browser-edge credential, and forwards protected traffic to a numeric-loopback Sybra upstream with a separate private credential.

Create two different regular token files containing at least 32 visible ASCII characters each, with owner-only permissions such as `0600`. The browser token may appear in an EventSource `token` query parameter at the local edge; the gateway removes that parameter and sends the distinct upstream token only in the upstream `Authorization` header.

Run the service from the repository root:

```bash
mise run sybra:dev -- --listen 127.0.0.1:8081 --upstream http://127.0.0.1:8080 --browser-token-file /path/to/browser-token --upstream-token-file /path/to/upstream-token
```

Port zero is supported for test and discovery workflows. The service validates the actual bound address before serving and refuses a listener that resolves to its configured upstream.
