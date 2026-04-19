import { Socket, createConnection } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";

import {
  DEFAULT_APP_GROUP,
  SOCKET_FILENAME,
  type RegistryRequest,
  type RegistryResponse,
} from "./protocol.js";

export interface RegistryClientOptions {
  socketPath?: string;
  connectTimeoutMs?: number;
  requestTimeoutMs?: number;
}

export class RegistryUnavailableError extends Error {
  constructor(socketPath: string, cause: unknown) {
    const reason = cause instanceof Error ? cause.message : String(cause);
    super(
      `Harness Monitor accessibility socket unavailable at ${socketPath}: ${reason}. ` +
        `Launch Harness Monitor.app and ensure the MCP listener task is running.`,
    );
    this.name = "RegistryUnavailableError";
  }
}

export class RegistryRequestError extends Error {
  constructor(
    readonly code: string,
    message: string,
  ) {
    super(message);
    this.name = "RegistryRequestError";
  }
}

export function defaultSocketPath(appGroup = DEFAULT_APP_GROUP): string {
  const override = process.env.HARNESS_MONITOR_MCP_SOCKET;
  if (override && override.length > 0) {
    return override;
  }
  return join(homedir(), "Library", "Group Containers", appGroup, SOCKET_FILENAME);
}

type Pending = {
  resolve: (value: unknown) => void;
  reject: (err: Error) => void;
  timer: NodeJS.Timeout;
};

export class RegistryClient {
  readonly socketPath: string;
  private readonly connectTimeoutMs: number;
  private readonly requestTimeoutMs: number;
  private socket: Socket | null = null;
  private nextId = 1;
  private pending = new Map<number, Pending>();
  private buffer = "";
  private connecting: Promise<Socket> | null = null;

  constructor(options: RegistryClientOptions = {}) {
    this.socketPath = options.socketPath ?? defaultSocketPath();
    this.connectTimeoutMs = options.connectTimeoutMs ?? 3000;
    this.requestTimeoutMs = options.requestTimeoutMs ?? 5000;
  }

  async request<T>(op: RegistryRequest): Promise<T> {
    const socket = await this.ensureConnected();
    const id = op.id;
    const line = JSON.stringify({ ...op, id }) + "\n";
    return new Promise<T>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new RegistryRequestError("timeout", `Request ${op.op} timed out`));
      }, this.requestTimeoutMs);
      this.pending.set(id, {
        resolve: resolve as (value: unknown) => void,
        reject,
        timer,
      });
      socket.write(line, (err) => {
        if (err) {
          this.pending.delete(id);
          clearTimeout(timer);
          reject(err);
        }
      });
    });
  }

  nextRequestId(): number {
    return this.nextId++;
  }

  close(): void {
    this.socket?.destroy();
    this.socket = null;
    for (const [id, pending] of this.pending) {
      clearTimeout(pending.timer);
      pending.reject(new RegistryRequestError("closed", "Client closed"));
      this.pending.delete(id);
    }
  }

  private async ensureConnected(): Promise<Socket> {
    if (this.socket && !this.socket.destroyed) {
      return this.socket;
    }
    if (!this.connecting) {
      this.connecting = this.connect();
    }
    try {
      return await this.connecting;
    } finally {
      this.connecting = null;
    }
  }

  private connect(): Promise<Socket> {
    return new Promise<Socket>((resolve, reject) => {
      const socket = createConnection(this.socketPath);
      const timer = setTimeout(() => {
        socket.destroy(new Error("connect timeout"));
      }, this.connectTimeoutMs);
      socket.once("connect", () => {
        clearTimeout(timer);
        socket.setNoDelay(true);
        this.socket = socket;
        socket.on("data", (chunk) => this.handleData(chunk));
        socket.on("close", () => this.handleClose());
        socket.on("error", (err) => this.handleError(err));
        resolve(socket);
      });
      socket.once("error", (err) => {
        clearTimeout(timer);
        reject(new RegistryUnavailableError(this.socketPath, err));
      });
    });
  }

  private handleData(chunk: Buffer): void {
    this.buffer += chunk.toString("utf8");
    let newlineIndex = this.buffer.indexOf("\n");
    while (newlineIndex !== -1) {
      const line = this.buffer.slice(0, newlineIndex);
      this.buffer = this.buffer.slice(newlineIndex + 1);
      if (line.length > 0) {
        this.handleLine(line);
      }
      newlineIndex = this.buffer.indexOf("\n");
    }
  }

  private handleLine(line: string): void {
    let parsed: RegistryResponse;
    try {
      parsed = JSON.parse(line) as RegistryResponse;
    } catch {
      return;
    }
    const pending = this.pending.get(parsed.id);
    if (!pending) {
      return;
    }
    this.pending.delete(parsed.id);
    clearTimeout(pending.timer);
    if (parsed.ok) {
      pending.resolve(parsed.result);
    } else {
      pending.reject(new RegistryRequestError(parsed.error.code, parsed.error.message));
    }
  }

  private handleClose(): void {
    this.socket = null;
    for (const [id, pending] of this.pending) {
      clearTimeout(pending.timer);
      pending.reject(new RegistryRequestError("closed", "Socket closed"));
      this.pending.delete(id);
    }
  }

  private handleError(_err: Error): void {
    // Errors surface through connect/request rejections; swallow here to avoid crash.
  }
}
