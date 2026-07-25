#!/usr/bin/env python3
"""Shared build-concurrency pool for concurrent agent sessions.

One pool per repository. Cargo draws from it directly by speaking the GNU make
jobserver protocol over a FIFO, so a build that starts alone can hand cores back
as other builds arrive. Runners that cannot speak that protocol - nextest above
all - draw from the same budget through a Unix socket, where a grant lives
exactly as long as the client's connection.

The socket exists because a FIFO token is anonymous: nothing links it to the
process holding it, so a killed client drains the pool permanently. That is why
the published system-wide jobservers reach for CUSE, which macOS does not have.
A socket grant needs no cooperation to come back - the kernel closes the fd when
the client dies and the supervisor reclaims it.
"""

from __future__ import annotations

import argparse
import contextlib
import errno
import fcntl
import hashlib
import os
import selectors
import signal
import socket
import stat
import subprocess
import sys
import threading
import time

TOKEN = b"+"
IDLE_EXIT_SECONDS = 3600
POLL_SECONDS = 5.0
# AF_UNIX paths are capped near 104 bytes on macOS, so the pool directory has to
# stay short enough that the socket underneath it still fits.
MAX_SOCKET_PATH = 100


def pool_dir(repo_root: str) -> str:
    user = "".join(c if c.isalnum() or c in "._-" else "-" for c in os.environ.get("USER", "user"))
    digest = hashlib.sha256(repo_root.encode()).hexdigest()[:16]
    return f"/tmp/harness-jobserver-{user}/{digest}"


def prepare_private_dir(path: str) -> None:
    """Create `path` 0700 and owned by us, refusing anything already unsafe.

    A plain makedirs adopts a pre-existing directory whatever its owner, and the
    pool path is a deterministic hash of a guessable repository path.
    """
    parent = os.path.dirname(path)
    if parent and not os.path.isdir(parent):
        prepare_private_dir(parent)
    with contextlib.suppress(FileExistsError):
        os.mkdir(path, 0o700)
    info = os.lstat(path)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise RuntimeError(f"pool path is not a real directory: {path}")
    if info.st_uid != os.getuid():
        raise RuntimeError(f"pool path is owned by another user: {path}")
    if info.st_mode & 0o077:
        os.chmod(path, 0o700)


class Pool:
    """Owns the token budget behind both the FIFO and the socket."""

    def __init__(self, directory: str, budget: int):
        self.dir = directory
        self.budget = budget
        self.fifo_path = os.path.join(directory, "fifo")
        self.sock_path = os.path.join(directory, "sock")
        self.lock = threading.Lock()
        self.granted = 0
        self.last_activity = time.monotonic()

        if not os.path.exists(self.fifo_path):
            with contextlib.suppress(FileExistsError):
                os.mkfifo(self.fifo_path, 0o600)
        # O_RDWR keeps a permanent writer attached, without which the FIFO would
        # report EOF and discard its buffered tokens the moment cargo detaches.
        self.fifo_fd = os.open(self.fifo_path, os.O_RDWR | os.O_NONBLOCK)
        self._refill_to(budget)

    def _drain(self) -> int:
        count = 0
        while True:
            try:
                chunk = os.read(self.fifo_fd, 4096)
            except BlockingIOError:
                return count
            except OSError as exc:
                if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    return count
                raise
            if not chunk:
                return count
            count += len(chunk)

    def _refill_to(self, target: int) -> None:
        present = self._drain()
        write = max(0, min(target, self.budget))
        if write:
            os.write(self.fifo_fd, TOKEN * write)
        del present

    def acquire(self, want: int) -> int:
        """Take up to `want` tokens out of the FIFO for a socket client."""
        with self.lock:
            got = 0
            while got < want:
                try:
                    chunk = os.read(self.fifo_fd, want - got)
                except (BlockingIOError, OSError):
                    break
                if not chunk:
                    break
                got += len(chunk)
            self.granted += got
            self.last_activity = time.monotonic()
            return got

    def release(self, count: int) -> None:
        with self.lock:
            count = min(count, self.granted)
            if count > 0:
                os.write(self.fifo_fd, TOKEN * count)
                self.granted -= count
            self.last_activity = time.monotonic()

    def idle_and_whole(self) -> bool:
        """True when nothing is granted and every token is back in the FIFO."""
        with self.lock:
            if self.granted:
                return False
            held = self._drain()
            if held:
                os.write(self.fifo_fd, TOKEN * held)
            return held >= self.budget


def serve(pool: Pool, stop: threading.Event) -> None:
    if os.path.exists(pool.sock_path):
        os.unlink(pool.sock_path)
    server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    server.bind(pool.sock_path)
    os.chmod(pool.sock_path, 0o600)
    server.listen(128)
    server.setblocking(False)

    selector = selectors.DefaultSelector()
    selector.register(server, selectors.EVENT_READ, None)
    holdings: dict[socket.socket, int] = {}

    def drop(conn: socket.socket) -> None:
        selector.unregister(conn)
        pool.release(holdings.pop(conn, 0))
        with contextlib.suppress(OSError):
            conn.close()

    while not stop.is_set():
        for key, _ in selector.select(timeout=POLL_SECONDS):
            if key.fileobj is server:
                conn, _ = server.accept()
                conn.setblocking(True)
                holdings[conn] = 0
                selector.register(conn, selectors.EVENT_READ, None)
                continue

            conn = key.fileobj
            try:
                line = conn.recv(64)
            except OSError:
                line = b""
            if not line:
                # EOF covers a clean close and a SIGKILLed client alike.
                drop(conn)
                continue
            try:
                verb, _, raw = line.decode().strip().partition(" ")
                want = max(0, int(raw or "0"))
            except ValueError:
                drop(conn)
                continue
            if verb != "ACQUIRE":
                drop(conn)
                continue
            granted = pool.acquire(want)
            holdings[conn] += granted
            with contextlib.suppress(OSError):
                conn.sendall(f"GRANTED {granted}\n".encode())

        # Deadline first: idle_and_whole drains the FIFO to count it, and doing
        # that every poll would briefly hold every token outside the pipe for no
        # reason. Only pay it once the supervisor is already a candidate to exit.
        if time.monotonic() - pool.last_activity > IDLE_EXIT_SECONDS and pool.idle_and_whole():
            break

    for conn in list(holdings):
        drop(conn)
    with contextlib.suppress(OSError):
        server.close()
    with contextlib.suppress(OSError):
        os.unlink(pool.sock_path)


def supervise(repo_root: str, budget: int) -> int:
    directory = pool_dir(repo_root)
    prepare_private_dir(directory)
    lock_fd = os.open(os.path.join(directory, "lock"), os.O_CREAT | os.O_RDWR, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0  # another supervisor owns this pool

    os.write(lock_fd, f"{os.getpid()}\n".encode())
    pool = Pool(directory, budget)
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    serve(pool, stop)
    return 0


def ensure(repo_root: str, budget: int, timeout: float = 5.0) -> tuple[str, int] | None:
    """Start the supervisor if absent and return (fifo_path, budget)."""
    directory = pool_dir(repo_root)
    if len(os.path.join(directory, "sock")) > MAX_SOCKET_PATH:
        return None
    prepare_private_dir(directory)
    sock_path = os.path.join(directory, "sock")
    fifo_path = os.path.join(directory, "fifo")

    if not _connectable(sock_path):
        subprocess.Popen(
            [sys.executable, os.path.abspath(__file__), "supervise",
             "--repo-root", repo_root, "--budget", str(budget)],
            start_new_session=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline and not _connectable(sock_path):
            time.sleep(0.05)

    if not _connectable(sock_path) or not os.path.exists(fifo_path):
        return None
    return fifo_path, budget


def _connectable(sock_path: str) -> bool:
    if not os.path.exists(sock_path):
        return False
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        conn.settimeout(1.0)
        conn.connect(sock_path)
        return True
    except OSError:
        return False
    finally:
        conn.close()


def run_with_tokens(repo_root: str, want: int, env_var: str, floor: int, argv: list[str]) -> int:
    """Hold a token block for the lifetime of `argv`, exporting the count."""
    directory = pool_dir(repo_root)
    sock_path = os.path.join(directory, "sock")
    env = dict(os.environ)
    conn = None
    granted = 0

    if _connectable(sock_path):
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            conn.connect(sock_path)
            conn.sendall(f"ACQUIRE {want}\n".encode())
            reply = conn.recv(64).decode().strip()
            if reply.startswith("GRANTED"):
                granted = int(reply.split()[1])
        except (OSError, ValueError, IndexError):
            with contextlib.suppress(OSError):
                conn.close()
            conn = None

    if env_var:
        # The implicit slot: this process may always run one unit of work
        # without holding a token, so the usable width is one above the grant.
        env[env_var] = str(max(floor, granted + 1))
    try:
        return subprocess.call(argv, env=env)
    finally:
        if conn is not None:
            with contextlib.suppress(OSError):
                conn.close()


def main() -> int:
    parser = argparse.ArgumentParser(prog="harness-jobserver")
    sub = parser.add_subparsers(dest="mode", required=True)

    p_sup = sub.add_parser("supervise")
    p_sup.add_argument("--repo-root", required=True)
    p_sup.add_argument("--budget", type=int, required=True)

    p_ens = sub.add_parser("ensure")
    p_ens.add_argument("--repo-root", required=True)
    p_ens.add_argument("--budget", type=int, required=True)

    p_run = sub.add_parser("run")
    p_run.add_argument("--repo-root", required=True)
    p_run.add_argument("--max", type=int, required=True)
    p_run.add_argument("--env", default="")
    p_run.add_argument("--floor", type=int, default=2)
    p_run.add_argument("command", nargs=argparse.REMAINDER)

    args = parser.parse_args()
    if args.mode == "supervise":
        return supervise(args.repo_root, args.budget)
    if args.mode == "ensure":
        result = ensure(args.repo_root, args.budget)
        if result is None:
            return 1
        fifo_path, budget = result
        print(f"MAKEFLAGS=-j{budget} --jobserver-auth=fifo:{fifo_path}")
        return 0
    command = [a for a in args.command if a != "--"]
    if not command:
        parser.error("run requires a command")
    return run_with_tokens(args.repo_root, args.max, args.env, args.floor, command)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError) as exc:
        print(f"harness-jobserver: {exc}", file=sys.stderr)
        sys.exit(1)
