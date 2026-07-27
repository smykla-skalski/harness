from __future__ import annotations

import fcntl
import importlib.util
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType


REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT_PATH = REPO_ROOT / "scripts" / "seed-rust-build-lane.py"


def load_script() -> ModuleType:
    spec = importlib.util.spec_from_file_location("seed_rust_build_lane", SCRIPT_PATH)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {SCRIPT_PATH}")
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


seed = load_script()


class SeedRustBuildLaneTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.repo_root = Path(self.temporary.name).resolve()
        self.target_base = self.repo_root / "target" / "dev"
        self.target_base.mkdir(parents=True)
        self.clone_sources: list[Path] = []
        self.messages: list[str] = []

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def create_donor(self, segment: str, artifacts: int) -> Path:
        donor = self.target_base / segment
        deps = donor / "debug" / "deps"
        deps.mkdir(parents=True)
        (donor / "debug" / ".cargo-build-lock").touch()
        (donor / ".rustc_info.json").write_text("{}\n", encoding="utf-8")
        for index in range(artifacts):
            (deps / f"artifact-{index}.rlib").write_text(
                f"{segment}-{index}\n",
                encoding="utf-8",
            )
        return donor

    def clone(self, source: Path, destination: Path, _log: object) -> None:
        self.clone_sources.append(source)
        shutil.copytree(source, destination)

    def run_seed(self, segment: str = "wt-destination") -> str:
        return seed.seed_lane(
            self.repo_root,
            self.target_base / segment,
            segment,
            clone=self.clone,
            log=self.messages.append,
        )

    def test_richest_idle_lane_seeds_destination(self) -> None:
        small = self.create_donor("wt-small", artifacts=1)
        richest = self.create_donor("wt-rich", artifacts=4)
        same_time = 1_700_000_000_000_000_000
        for donor in (small, richest):
            os.utime(donor / "debug" / "deps", ns=(same_time, same_time))
            os.utime(donor / ".rustc_info.json", ns=(same_time, same_time))

        result = self.run_seed()

        self.assertEqual(result, seed.RESULT_SEEDED)
        self.assertEqual(self.clone_sources, [richest / "debug"])
        self.assertTrue((self.target_base / "wt-destination" / "debug").is_dir())
        self.assertTrue(
            any("4 cached artifacts" in message for message in self.messages)
        )

    def test_most_recent_lane_wins_over_larger_stale_lane(self) -> None:
        stale = self.create_donor("wt-stale", artifacts=5)
        recent = self.create_donor("wt-recent", artifacts=1)
        stale_time = 1_600_000_000_000_000_000
        os.utime(stale / "debug" / "deps", ns=(stale_time, stale_time))
        os.utime(stale / ".rustc_info.json", ns=(stale_time, stale_time))

        result = self.run_seed()

        self.assertEqual(result, seed.RESULT_SEEDED)
        self.assertEqual(self.clone_sources, [recent / "debug"])

    def test_lane_with_live_lease_is_skipped(self) -> None:
        busy = self.create_donor("wt-busy", artifacts=5)
        idle = self.create_donor("wt-idle", artifacts=1)
        lease_dir = self.repo_root / "target" / ".cargo-local" / "leases"
        lease_dir.mkdir(parents=True)
        (lease_dir / f"{busy.name}-{os.getpid()}").write_text(
            f"{os.getpid()}\n",
            encoding="utf-8",
        )

        result = self.run_seed()

        self.assertEqual(result, seed.RESULT_SEEDED)
        self.assertEqual(self.clone_sources, [idle / "debug"])

    def test_existing_destination_is_never_replaced(self) -> None:
        self.create_donor("wt-donor", artifacts=2)
        destination = self.target_base / "wt-destination"
        destination.mkdir()
        marker = destination / "keep"
        marker.write_text("owned\n", encoding="utf-8")

        result = self.run_seed()

        self.assertEqual(result, seed.RESULT_EXISTS)
        self.assertEqual(self.clone_sources, [])
        self.assertEqual(marker.read_text(encoding="utf-8"), "owned\n")

    def test_cargo_locked_donor_is_skipped(self) -> None:
        idle = self.create_donor("wt-idle", artifacts=1)
        locked = self.create_donor("wt-locked", artifacts=5)
        with (locked / "debug" / ".cargo-build-lock").open("a+b") as lock_file:
            fcntl.flock(lock_file.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_seed()

        self.assertEqual(result, seed.RESULT_SEEDED)
        self.assertEqual(self.clone_sources, [idle / "debug"])

    def test_target_must_match_the_generated_lane(self) -> None:
        outside = self.repo_root / "outside"

        with self.assertRaisesRegex(ValueError, "does not match"):
            seed.seed_lane(
                self.repo_root,
                outside,
                "wt-destination",
                clone=self.clone,
                log=self.messages.append,
            )

        self.assertFalse(outside.exists())

    def test_symlinked_donor_is_ignored(self) -> None:
        real = self.create_donor("wt-real", artifacts=2)
        (self.target_base / "wt-link").symlink_to(real, target_is_directory=True)

        result = self.run_seed()

        self.assertEqual(result, seed.RESULT_SEEDED)
        self.assertEqual(self.clone_sources, [real / "debug"])

    def test_symlinked_control_directory_is_rejected(self) -> None:
        outside = self.repo_root / "outside-control"
        outside.mkdir()
        (self.repo_root / "target" / ".cargo-local").symlink_to(
            outside,
            target_is_directory=True,
        )

        with self.assertRaisesRegex(ValueError, "must not be symlinks"):
            self.run_seed()

    def test_unsupported_copy_leaves_no_partial_lane(self) -> None:
        self.create_donor("wt-donor", artifacts=2)

        def unsupported(_source: Path, _destination: Path, _log: object) -> None:
            raise seed.CopyOnWriteUnsupported("test filesystem")

        result = seed.seed_lane(
            self.repo_root,
            self.target_base / "wt-destination",
            "wt-destination",
            clone=unsupported,
            log=self.messages.append,
        )

        self.assertEqual(result, seed.RESULT_UNSUPPORTED)
        self.assertFalse((self.target_base / "wt-destination").exists())
        self.assertEqual(
            list(self.target_base.glob(".wt-destination.seed-*")),
            [],
        )


if __name__ == "__main__":
    unittest.main()
