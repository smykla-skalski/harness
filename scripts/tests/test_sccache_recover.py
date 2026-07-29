from __future__ import annotations

import importlib.util
import os
import shutil
import signal
import socket
import subprocess
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "sccache-recover.py"


def load_script():
    spec = importlib.util.spec_from_file_location("sccache_recover", SCRIPT)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load {SCRIPT}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


recover = load_script()


class SccacheRecoverTests(unittest.TestCase):
    def test_recovery_stops_only_its_deleted_socket_sccache(self) -> None:
        sccache = shutil.which("sccache")
        if sccache is None:
            self.skipTest("production sccache is unavailable")
        version = subprocess.run(
            (sccache, "--version"),
            check=False,
            capture_output=True,
            text=True,
        )
        if version.returncode != 0:
            self.skipTest("production sccache is unusable")
        with tempfile.TemporaryDirectory(prefix="hst.", dir="/tmp") as directory:
            sandbox = Path(directory)
            socket_directory = sandbox / "harness-sccache"
            cache_directory = sandbox / "cache"
            socket_directory.mkdir()
            cache_directory.mkdir()
            orphan_socket = socket_directory / "orphan.sock"
            environment = {
                **os.environ,
                "HOME": str(sandbox),
                "SCCACHE_DIR": str(cache_directory),
                "SCCACHE_CACHE_SIZE": "1G",
                "SCCACHE_IDLE_TIMEOUT": "600",
                "SCCACHE_SERVER_UDS": str(orphan_socket),
            }
            owned_pids: tuple[int, ...] = ()
            started = subprocess.run(
                (sccache, "--start-server"),
                check=False,
                capture_output=True,
                env=environment,
                text=True,
            )
            self.assertEqual(started.returncode, 0, started.stderr)
            state, pid = recover._peer_pid(str(orphan_socket))
            owned_pids = tuple(recover.socket_owners_under(sandbox))
            self.assertEqual(state, "live")
            self.assertIsNotNone(pid)
            orphan_socket.unlink()
            try:
                owners = recover._owners(socket_directory / "configured.sock")
                owned = next(owner for owner in owners if owner.pid == pid)
                self.assertEqual(owned.action, "stop-orphan")
                self.assertEqual(recover._terminate(owned), "stopped")
            finally:
                for owned_pid in owned_pids:
                    try:
                        os.kill(owned_pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_peer_pid_tracks_live_process_and_deleted_socket(self) -> None:
        with self.subTest(state="live"):
            socket_path = Path(os.environ["TMPDIR"]) / "recovery-peer.sock"
            ready_read, ready_write = os.pipe()
            pid = os.fork()
            if pid == 0:
                os.close(ready_read)
                listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                listener.bind(str(socket_path))
                listener.listen(1)
                os.write(ready_write, b"1")
                signal.pause()
                os._exit(0)
            os.close(ready_write)
            try:
                self.assertEqual(os.read(ready_read, 1), b"1")
                self.assertEqual(recover._peer_pid(str(socket_path)), ("live", pid))
                socket_path.unlink()
                self.assertEqual(
                    recover._peer_pid(str(socket_path)),
                    ("absent", None),
                )
            finally:
                os.close(ready_read)
                try:
                    os.kill(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                os.waitpid(pid, 0)

    def test_linux_peer_credentials_identify_the_server(self) -> None:
        class FakeSocket:
            def settimeout(self, _timeout: float) -> None:
                pass

            def connect(self, _path: str) -> None:
                pass

            def getsockopt(self, level: int, option: int, size: int) -> bytes:
                self.assertion = (level, option, size)
                return struct.pack("3i", 321, 501, 20)

            def close(self) -> None:
                pass

        fake = FakeSocket()
        with (
            patch.object(recover.sys, "platform", "linux"),
            patch.object(recover.socket, "socket", return_value=fake),
        ):
            self.assertEqual(recover._peer_pid("/tmp/repo.sock"), ("live", 321))
        self.assertEqual(
            fake.assertion,
            (socket.SOL_SOCKET, recover.SO_PEERCRED, struct.calcsize("3i")),
        )

    def test_server_command_excludes_compiler_clients(self) -> None:
        self.assertTrue(recover.is_sccache_server_command("/opt/tools/sccache"))
        self.assertFalse(
            recover.is_sccache_server_command(
                "/opt/tools/sccache /usr/bin/rustc --crate-name x"
            )
        )
        self.assertFalse(recover.is_sccache_server_command("/usr/bin/rustc"))

    def test_terminate_fails_closed_when_identity_or_ownership_changes(self) -> None:
        owner = recover.Owner(
            123,
            ("/tmp/harness-sccache/orphan.sock",),
            "/tools/sccache",
            "stop-orphan",
        )
        with (
            patch.object(recover, "process_command", return_value="/tools/rustc"),
            patch.object(recover.os, "kill") as kill,
        ):
            self.assertEqual(recover._terminate(owner), "identity-changed")
            kill.assert_not_called()
        with (
            patch.object(recover, "process_command", return_value="/tools/sccache"),
            patch.object(recover, "pids_for_socket", return_value=()),
            patch.object(recover.os, "kill") as kill,
        ):
            self.assertEqual(recover._terminate(owner), "ownership-lost")
            kill.assert_not_called()

    def test_terminate_waits_on_process_exit_without_polling(self) -> None:
        ready_read, ready_write = os.pipe()
        pid = os.fork()
        if pid == 0:
            os.close(ready_read)
            os.write(ready_write, b"1")
            signal.pause()
            os._exit(0)
        os.close(ready_write)
        try:
            self.assertEqual(os.read(ready_read, 1), b"1")
            owner = recover.Owner(
                pid,
                ("/tmp/harness-sccache/orphan.sock",),
                "/tools/sccache",
                "",
            )
            with (
                patch.object(recover, "process_command", return_value="/tools/sccache"),
                patch.object(recover, "pids_for_socket", return_value=(pid,)),
            ):
                self.assertEqual(recover._terminate(owner), "stopped")
        finally:
            os.close(ready_read)
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)

    def test_planner_preserves_live_and_unknown_servers(self) -> None:
        configured = Path("/tmp/harness-sccache/repo.sock")
        inventory = {
            41: (f"{configured} type=STREAM",),
            42: ("/tmp/harness-sccache/orphan.sock (deleted)",),
            43: ("/tmp/harness-sccache/unknown.sock",),
            44: ("/tmp/harness-sccache/client.sock",),
        }
        peers = {
            str(configured): ("live", 41),
            "/tmp/harness-sccache/orphan.sock": ("absent", None),
            "/tmp/harness-sccache/unknown.sock": ("unknown", None),
            "/tmp/harness-sccache/client.sock": ("live", 99),
        }
        commands = {
            41: "/tools/sccache",
            42: "/tools/sccache",
            43: "/tools/sccache",
            44: "/tools/sccache /usr/bin/rustc",
        }
        with (
            patch.object(recover, "socket_owners_under", return_value=inventory),
            patch.object(recover, "_peer_pid", side_effect=lambda path: peers[path]),
            patch.object(
                recover,
                "process_command",
                side_effect=lambda pid: commands[pid],
            ),
        ):
            owners = recover._owners(configured)

        self.assertEqual(
            {owner.pid: owner.action for owner in owners},
            {
                41: "keep-live",
                42: "stop-orphan",
                43: "keep-unknown",
                44: "keep-client",
            },
        )


if __name__ == "__main__":
    unittest.main()
