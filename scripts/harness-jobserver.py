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
# A request is one short line; anything longer is a client that will never
# terminate its line, so cap what we buffer for it.
MAX_REQUEST_BYTES = 256
# Ceiling on the grant handshake. It is local IPC, so anything slower than this
# means the supervisor is wedged and the command should just run without a grant.
HANDSHAKE_TIMEOUT = 5.0


def pool_dir(repo_root: str) -> str:
    # Keyed on the uid rather than $USER, because that is what the ownership
    # check enforces and because $USER is caller-controlled: a daemon-spawned
    # build that inherits no $USER would otherwise get a second pool of its own
    # and the same machine would hand out the budget twice.
    digest = hashlib.sha256(repo_root.encode()).hexdigest()[:16]
    return f"/tmp/harness-jobserver-{os.getuid()}/{digest}"


def prepare_private_dir(path: str) -> None:
    """Create one level 0700 and owned by us, refusing anything already unsafe.

    A plain makedirs adopts a pre-existing directory whatever its owner, and the
    pool path is a deterministic hash of a guessable repository path.
    """
    with contextlib.suppress(FileExistsError):
        os.mkdir(path, 0o700)
    info = os.lstat(path)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise RuntimeError(f"pool path is not a real directory: {path}")
    if info.st_uid != os.getuid():
        raise RuntimeError(f"pool path is owned by another user: {path}")
    if info.st_mode & 0o077:
        os.chmod(path, 0o700)


def prepare_pool_dir(directory: str) -> None:
    """Validate every level we own, not just the leaf.

    Checking only the leaf left the parent unguarded, and os.path.isdir follows
    symlinks, so a pre-planted `/tmp/harness-jobserver-<uid>` was adopted
    silently and the whole pool landed inside someone else's directory.
    """
    prepare_private_dir(os.path.dirname(directory))
    prepare_private_dir(directory)


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

        self._ensure_fifo()
        # O_RDWR keeps a permanent writer attached, without which the FIFO would
        # report EOF and discard its buffered tokens the moment cargo detaches.
        self.fifo_fd = os.open(self.fifo_path, os.O_RDWR | os.O_NONBLOCK)
        self._refill_to(budget)

    def _ensure_fifo(self) -> None:
        """Replace whatever sits at the FIFO path if it is not a FIFO.

        os.open succeeds on a regular file, and a file has one shared offset, so
        the refill lands past the read position and every later acquire sees an
        empty pool - the silent floor-width failure again. A symlink is worse:
        the tokens get written into whatever it points at.
        """
        with contextlib.suppress(FileNotFoundError):
            if not stat.S_ISFIFO(os.lstat(self.fifo_path).st_mode):
                os.unlink(self.fifo_path)
        with contextlib.suppress(FileExistsError):
            os.mkfifo(self.fifo_path, 0o600)

    def _read_tokens(self, limit: int | None) -> int:
        """Take up to `limit` tokens, or every one present when None.

        Only a would-block means the pipe is empty. Treating any other OSError
        that way turns a bad fd into a permanent zero-token grant that reports
        itself as an idle pool, and the sole symptom is every runner silently
        dropping to its floor width.
        """
        got = 0
        while limit is None or got < limit:
            try:
                chunk = os.read(self.fifo_fd, 4096 if limit is None else limit - got)
            except OSError as exc:
                if exc.errno in (errno.EAGAIN, errno.EWOULDBLOCK):
                    return got
                raise
            if not chunk:
                return got
            got += len(chunk)
        return got

    def _drain(self) -> int:
        return self._read_tokens(None)

    def _refill_to(self, target: int) -> None:
        present = self._drain()
        write = max(0, min(target, self.budget))
        if write:
            os.write(self.fifo_fd, TOKEN * write)
        del present

    def acquire(self, want: int) -> int:
        """Take up to `want` tokens out of the FIFO for a socket client."""
        with self.lock:
            got = self._read_tokens(want)
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
        """True when nothing is granted and every token is back in the FIFO.

        A True keeps the tokens drained, because the caller answers it by
        exiting. Putting them back first leaves a window where a build attaches,
        takes some, and is still holding them when the next supervisor refills
        the FIFO to a full budget - the one way this design can oversubscribe.
        An empty FIFO only costs that build its tokens, and cargo answers an
        empty pool by building serially on its implicit slot.
        """
        with self.lock:
            if self.granted:
                return False
            held = self._drain()
            if held >= self.budget:
                return True
            if held:
                os.write(self.fifo_fd, TOKEN * held)
            return False


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
    pending: dict[socket.socket, bytes] = {}

    def drop(conn: socket.socket) -> None:
        selector.unregister(conn)
        pending.pop(conn, None)
        pool.release(holdings.pop(conn, 0))
        with contextlib.suppress(OSError):
            conn.close()

    while not stop.is_set():
        for key, _ in selector.select(timeout=POLL_SECONDS):
            if key.fileobj is server:
                conn, _ = server.accept()
                conn.setblocking(True)
                holdings[conn] = 0
                pending[conn] = b""
                selector.register(conn, selectors.EVENT_READ, None)
                continue

            conn = key.fileobj
            try:
                chunk = conn.recv(64)
            except OSError:
                chunk = b""
            if not chunk:
                # EOF covers a clean close and a SIGKILLed client alike.
                drop(conn)
                continue

            # A stream socket keeps no message boundaries, so a request can
            # arrive split. Parsing whatever one recv returned would reject a
            # valid ACQUIRE and hand the client a silent zero-width grant.
            buffered = pending[conn] + chunk
            if b"\n" not in buffered:
                if len(buffered) > MAX_REQUEST_BYTES:
                    drop(conn)
                else:
                    pending[conn] = buffered
                continue
            raw_line, _, rest = buffered.partition(b"\n")
            pending[conn] = rest

            try:
                verb, _, raw = raw_line.decode().strip().partition(" ")
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
    prepare_pool_dir(directory)
    lock_fd = os.open(os.path.join(directory, "lock"),
                      os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        return 0  # another supervisor owns this pool

    # Truncate first: a longer pid from the previous supervisor would otherwise
    # leave its tail behind this one and the file would read as two pids.
    os.ftruncate(lock_fd, 0)
    os.write(lock_fd, f"{os.getpid()}\n".encode())
    # Written before the socket opens, so anything that reaches a live socket
    # is guaranteed to find the budget that belongs to it.
    _write_budget(directory, budget)
    pool = Pool(directory, budget)
    stop = threading.Event()
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *_: stop.set())
    serve(pool, stop)
    return 0


def _write_budget(directory: str, budget: int) -> None:
    path = os.path.join(directory, "budget")
    temporary = f"{path}.tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(f"{budget}\n")
    os.replace(temporary, path)


def _read_budget(directory: str, fallback: int) -> int:
    """The budget the running supervisor actually filled the FIFO with.

    Only meaningful once the socket answers, which is the proof a supervisor is
    alive and therefore that this file is its own rather than a dead one's.
    """
    try:
        with open(os.path.join(directory, "budget"), encoding="utf-8") as handle:
            value = int(handle.read().strip())
    except (OSError, ValueError):
        return fallback
    return value if value > 0 else fallback


def _startup_timeout() -> float:
    # A loaded host can take seconds just to get the interpreter up, and timing
    # out here silently demotes the whole build to the static reserve.
    try:
        return max(1.0, float(os.environ.get("HARNESS_JOBSERVER_TIMEOUT", "15")))
    except ValueError:
        return 15.0


def ensure(repo_root: str, budget: int, timeout: float | None = None) -> tuple[str, int] | None:
    """Start the supervisor if absent and return (fifo_path, running budget)."""
    if timeout is None:
        timeout = _startup_timeout()
    directory = pool_dir(repo_root)
    if len(os.path.join(directory, "sock")) > MAX_SOCKET_PATH:
        return None
    prepare_pool_dir(directory)
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
    # An already-running supervisor owns the width, and it need not be the one
    # this caller asked for; reporting the request would advertise a pool that
    # was never filled that way.
    return fifo_path, _read_budget(directory, budget)


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
            # A supervisor that accepts and then stalls would otherwise hang the
            # wrapper before the child ever starts. Losing the grant and falling
            # back to the floor is always better than not running the command.
            conn.settimeout(HANDSHAKE_TIMEOUT)
            conn.connect(sock_path)
            conn.sendall(f"ACQUIRE {want}\n".encode())
            # Same stream-boundary problem in reverse: read until the newline
            # rather than trusting one recv to hold the whole reply.
            buffered = b""
            while b"\n" not in buffered and len(buffered) <= MAX_REQUEST_BYTES:
                chunk = conn.recv(64)
                if not chunk:
                    break
                buffered += chunk
            reply = buffered.partition(b"\n")[0].decode().strip()
            if reply.startswith("GRANTED"):
                granted = int(reply.split()[1])
            # The connection is only held from here on, and holding it is what
            # keeps the grant alive, so the deadline must not outlive the child.
            conn.settimeout(None)
        except (OSError, ValueError, IndexError):
            with contextlib.suppress(OSError):
                conn.close()
            conn = None

    if env_var:
        # The implicit slot: this process may always run one unit of work
        # without holding a token, so the usable width is one above the grant.
        env[env_var] = str(max(floor, granted + 1))
    try:
        status = subprocess.call(argv, env=env)
        # subprocess reports a signal death as a negative number. Returning it
        # from a shell wrapper wraps it to 256-n, so an OOM-killed cargo showed
        # up as 247 instead of the 137 an unwrapped run reports, and the caller
        # decoded it as some nonexistent signal 119.
        if status < 0:
            status = 128 - status
        return status
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
    # Strip only the separator argparse needs to end REMAINDER. Any further one
    # belongs to the command being wrapped: a runner forwarding its own flags
    # past a second separator has to receive that separator intact.
    command = list(args.command)
    if command and command[0] == "--":
        command = command[1:]
    if not command:
        parser.error("run requires a command")
    return run_with_tokens(args.repo_root, args.max, args.env, args.floor, command)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        # Ctrl+C is ordinary teardown here, not a wrapper defect worth a
        # traceback on top of whatever the child already printed.
        sys.exit(130)
    except (RuntimeError, OSError) as exc:
        print(f"harness-jobserver: {exc}", file=sys.stderr)
        sys.exit(1)
