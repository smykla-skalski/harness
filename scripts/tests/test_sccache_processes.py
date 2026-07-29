from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))
from scripts.lib import sccache_processes


class SccacheProcessTests(unittest.TestCase):
    def test_pids_for_socket_canonicalizes_tmp_aliases(self) -> None:
        target = Path("/tmp/hst.fixture/owned.sock")
        owners = {41: ("/private/tmp/hst.fixture/owned.sock type=STREAM",)}
        aliases = {
            str(target): "/private/tmp/hst.fixture/owned.sock",
            "/private/tmp/hst.fixture/owned.sock": (
                "/private/tmp/hst.fixture/owned.sock"
            ),
        }
        with (
            patch.object(
                sccache_processes,
                "socket_owners_under",
                return_value=owners,
            ),
            patch.object(
                sccache_processes.os.path,
                "realpath",
                side_effect=lambda path: aliases[str(path)],
            ),
        ):
            pids = sccache_processes.pids_for_socket(target)

        self.assertEqual(pids, (41,))

    def test_path_ownership_canonicalizes_tmp_aliases(self) -> None:
        aliases = {
            "/tmp/hst.fixture": "/private/tmp/hst.fixture",
            "/private/tmp/hst.fixture/owned.sock": (
                "/private/tmp/hst.fixture/owned.sock"
            ),
        }
        with patch.object(
            sccache_processes.os.path,
            "realpath",
            side_effect=lambda path: aliases[str(path)],
        ):
            owned = sccache_processes._path_is_under(
                "/private/tmp/hst.fixture/owned.sock",
                Path("/tmp/hst.fixture"),
            )

        self.assertTrue(owned)

    def test_linux_maps_only_owned_socket_inodes_to_processes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            fixture = Path(directory)
            sandbox = fixture / "sandbox"
            proc = fixture / "proc"
            (proc / "net").mkdir(parents=True)
            (proc / "net" / "unix").write_text(
                "Num RefCount Protocol Flags Type St Inode Path\n"
                f"0: 1 0 0 0001 01 101 {sandbox}/harness-sccache/owned.sock\n"
                "0: 1 0 0 0001 01 202 /tmp/harness-sccache/live.sock\n"
            )
            (proc / "41" / "fd").mkdir(parents=True)
            (proc / "42" / "fd").mkdir(parents=True)
            os.symlink("socket:[101]", proc / "41" / "fd" / "7")
            os.symlink("socket:[202]", proc / "42" / "fd" / "8")

            owners = sccache_processes._linux_socket_owners(sandbox, proc)

        self.assertEqual(
            owners,
            {41: (f"{sandbox}/harness-sccache/owned.sock",)},
        )

    def test_darwin_accepts_lsof_stream_suffix_and_excludes_live_socket(
        self,
    ) -> None:
        sandbox = Path("/tmp/hst.fixture")
        output = (
            "p41\n"
            f"n{sandbox}/harness-sccache/owned.sock type=STREAM\n"
            "p42\n"
            "n/tmp/harness-sccache-user/live.sock type=STREAM\n"
        )
        with patch("subprocess.run") as run:
            run.return_value.returncode = 0
            run.return_value.stdout = output
            owners = sccache_processes._darwin_socket_owners(sandbox)

        self.assertEqual(
            owners,
            {41: (f"{sandbox}/harness-sccache/owned.sock type=STREAM",)},
        )

    def test_darwin_missing_lsof_fails_closed(self) -> None:
        with patch("subprocess.run", side_effect=FileNotFoundError):
            owners = sccache_processes._darwin_socket_owners(Path("/tmp/hst.fixture"))

        self.assertEqual(owners, {})


if __name__ == "__main__":
    unittest.main()
