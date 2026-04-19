import { createServer, type Server } from "node:net";
import { mkdtemp, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import assert from "node:assert/strict";

import { RegistryClient, RegistryRequestError, RegistryUnavailableError } from "./ipc.js";

type LineHandler = (line: string, write: (s: string) => void) => void;

async function startStubServer(
  handler: LineHandler,
): Promise<{ socketPath: string; server: Server; dir: string }> {
  const dir = await mkdtemp(join(tmpdir(), "harness-monitor-ipc-test-"));
  const socketPath = join(dir, "test.sock");
  const server = createServer((socket) => {
    let buffer = "";
    socket.on("data", (chunk) => {
      buffer += chunk.toString("utf8");
      let idx = buffer.indexOf("\n");
      while (idx !== -1) {
        const line = buffer.slice(0, idx);
        buffer = buffer.slice(idx + 1);
        handler(line, (s) => socket.write(s));
        idx = buffer.indexOf("\n");
      }
    });
    socket.on("error", () => {});
  });
  await new Promise<void>((resolve) => server.listen(socketPath, resolve));
  return { socketPath, server, dir };
}

test("RegistryClient resolves successful responses", async () => {
  const { socketPath, server, dir } = await startStubServer((line, write) => {
    const req = JSON.parse(line) as { id: number; op: string };
    const response = { id: req.id, ok: true, result: { echoed: req.op } };
    write(JSON.stringify(response) + "\n");
  });
  const client = new RegistryClient({ socketPath, connectTimeoutMs: 500, requestTimeoutMs: 500 });
  try {
    const result = await client.request<{ echoed: string }>({
      id: client.nextRequestId(),
      op: "ping",
    });
    assert.equal(result.echoed, "ping");
  } finally {
    client.close();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await rm(dir, { recursive: true, force: true });
  }
});

test("RegistryClient propagates typed errors", async () => {
  const { socketPath, server, dir } = await startStubServer((line, write) => {
    const req = JSON.parse(line) as { id: number };
    const response = {
      id: req.id,
      ok: false,
      error: { code: "not-found", message: "no such element" },
    };
    write(JSON.stringify(response) + "\n");
  });
  const client = new RegistryClient({ socketPath, connectTimeoutMs: 500, requestTimeoutMs: 500 });
  try {
    await assert.rejects(
      () => client.request({ id: client.nextRequestId(), op: "getElement", identifier: "x" }),
      (err: unknown) =>
        err instanceof RegistryRequestError &&
        err.code === "not-found" &&
        err.message === "no such element",
    );
  } finally {
    client.close();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await rm(dir, { recursive: true, force: true });
  }
});

test("RegistryClient surfaces RegistryUnavailableError when socket is missing", async () => {
  const client = new RegistryClient({
    socketPath: "/tmp/does-not-exist-harness-monitor.sock",
    connectTimeoutMs: 200,
    requestTimeoutMs: 200,
  });
  try {
    await assert.rejects(
      () => client.request({ id: client.nextRequestId(), op: "ping" }),
      (err: unknown) => err instanceof RegistryUnavailableError,
    );
  } finally {
    client.close();
  }
});

test("RegistryClient frames multiple responses on one chunk", async () => {
  const { socketPath, server, dir } = await startStubServer(() => {
    // handled per-request below by writing two responses to one request via a side channel
  });
  let chainedRequestCount = 0;
  server.on("connection", (socket) => {
    socket.on("data", (chunk) => {
      const lines = chunk.toString("utf8").split("\n").filter((l) => l.length > 0);
      for (const line of lines) {
        const req = JSON.parse(line) as { id: number };
        chainedRequestCount += 1;
        socket.write(JSON.stringify({ id: req.id, ok: true, result: { n: req.id } }) + "\n");
      }
    });
  });
  const client = new RegistryClient({ socketPath, connectTimeoutMs: 500, requestTimeoutMs: 500 });
  try {
    const [a, b] = await Promise.all([
      client.request<{ n: number }>({ id: client.nextRequestId(), op: "ping" }),
      client.request<{ n: number }>({ id: client.nextRequestId(), op: "ping" }),
    ]);
    assert.equal(a.n + b.n, 3);
    assert.equal(chainedRequestCount, 2);
  } finally {
    client.close();
    await new Promise<void>((resolve) => server.close(() => resolve()));
    await rm(dir, { recursive: true, force: true });
  }
});
