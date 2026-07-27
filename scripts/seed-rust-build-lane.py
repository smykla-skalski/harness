#!/usr/bin/env python3
from __future__ import annotations

import argparse
import fcntl
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path


RESULT_SEEDED = "seeded"
RESULT_EXISTS = "exists"
RESULT_NO_DONOR = "no-donor"
RESULT_UNSUPPORTED = "unsupported"
RESULT_FAILED = "failed"

EXIT_UNSUPPORTED = 3
EXIT_NO_DONOR = 4
SEGMENT_PATTERN = re.compile(r"^(?:local|wt-[A-Za-z0-9._-]+)$")
HEARTBEAT_SECONDS = 10

Log = Callable[[str], None]
Clone = Callable[[Path, Path, Log], None]


class CopyOnWriteUnsupported(RuntimeError):
    pass


@dataclass(frozen=True)
class Donor:
    segment: str
    path: Path
    lock_path: Path
    artifact_count: int
    freshness_ns: int


def pid_is_alive(pid: int) -> bool:
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def has_live_lease(lease_dir: Path, segment: str) -> bool:
    for lease_path in lease_dir.glob(f"{segment}-*"):
        if lease_path.is_symlink() or not lease_path.is_file():
            continue
        try:
            pid_text = lease_path.read_text(encoding="utf-8").strip()
            pid = int(pid_text)
        except (OSError, ValueError):
            continue
        if pid > 0 and pid_is_alive(pid):
            return True
    return False


def donor_from_path(path: Path, lease_dir: Path) -> Donor | None:
    if (
        path.is_symlink()
        or not path.is_dir()
        or not SEGMENT_PATTERN.fullmatch(path.name)
        or has_live_lease(lease_dir, path.name)
    ):
        return None

    debug_dir = path / "debug"
    deps_dir = debug_dir / "deps"
    lock_path = debug_dir / ".cargo-build-lock"
    if (
        debug_dir.is_symlink()
        or deps_dir.is_symlink()
        or lock_path.is_symlink()
        or not deps_dir.is_dir()
        or not lock_path.is_file()
    ):
        return None

    try:
        artifact_count = sum(1 for _ in deps_dir.iterdir())
        freshness_ns = deps_dir.stat().st_mtime_ns
        rustc_info = path / ".rustc_info.json"
        if rustc_info.is_file() and not rustc_info.is_symlink():
            freshness_ns = max(freshness_ns, rustc_info.stat().st_mtime_ns)
    except OSError:
        return None
    if artifact_count == 0:
        return None

    return Donor(
        segment=path.name,
        path=path,
        lock_path=lock_path,
        artifact_count=artifact_count,
        freshness_ns=freshness_ns,
    )


def find_donors(target_base: Path, target: Path, lease_dir: Path) -> list[Donor]:
    donors: list[Donor] = []
    try:
        children = target_base.iterdir()
    except OSError:
        return donors

    for child in children:
        if child == target:
            continue
        donor = donor_from_path(child, lease_dir)
        if donor is not None:
            donors.append(donor)

    return sorted(
        donors,
        key=lambda donor: (
            donor.freshness_ns,
            donor.artifact_count,
            donor.segment,
        ),
        reverse=True,
    )


def copy_command(source: Path, destination: Path) -> list[str]:
    if sys.platform == "darwin":
        return ["/bin/cp", "-cR", str(source), str(destination)]
    if sys.platform.startswith("linux"):
        cp = "/bin/cp" if Path("/bin/cp").is_file() else shutil.which("cp")
        if cp is None:
            raise CopyOnWriteUnsupported("cp is unavailable")
        return [cp, "-a", "--reflink=always", str(source), str(destination)]
    raise CopyOnWriteUnsupported(f"host platform {sys.platform} has no COW copier")


def clone_debug_tree(source: Path, destination: Path, log: Log) -> None:
    command = copy_command(source, destination)
    started = time.monotonic()
    with tempfile.TemporaryFile() as stderr_file:
        process = subprocess.Popen(
            command,
            stdout=subprocess.DEVNULL,
            stderr=stderr_file,
        )
        try:
            while True:
                try:
                    return_code = process.wait(timeout=HEARTBEAT_SECONDS)
                    break
                except subprocess.TimeoutExpired:
                    elapsed = int(time.monotonic() - started)
                    log(
                        "cargo-local: still seeding the build lane "
                        f"({elapsed}s elapsed)"
                    )
        except BaseException:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait()
            raise

        stderr_file.seek(0)
        error = stderr_file.read().decode("utf-8", errors="replace").strip()

    if return_code == 0:
        return

    lowered = error.lower()
    unsupported_markers = (
        "not supported",
        "operation not permitted",
        "invalid option",
        "illegal option",
        "clonefile",
        "reflink",
    )
    if any(marker in lowered for marker in unsupported_markers):
        raise CopyOnWriteUnsupported(error or "copy-on-write cloning failed")
    raise RuntimeError(error or f"copy command exited {return_code}")


def validate_layout(
    repo_root_arg: Path,
    target_arg: Path,
    target_segment: str,
) -> tuple[Path, Path, Path]:
    if not SEGMENT_PATTERN.fullmatch(target_segment):
        raise ValueError(f"invalid target segment: {target_segment}")

    repo_root = repo_root_arg.expanduser().resolve(strict=True)
    target_root = repo_root / "target"
    target_base = target_root / "dev"
    control_root = target_root / ".cargo-local"
    lease_dir = control_root / "leases"
    if (
        target_root.is_symlink()
        or target_base.is_symlink()
        or control_root.is_symlink()
        or lease_dir.is_symlink()
    ):
        raise ValueError("target cache roots must not be symlinks")

    target_base.mkdir(parents=True, exist_ok=True)
    expected_target = target_base / target_segment
    supplied_target = target_arg.expanduser().resolve(strict=False)
    if supplied_target != expected_target:
        raise ValueError(
            f"target directory {supplied_target} does not match {expected_target}"
        )
    if supplied_target.is_symlink():
        raise ValueError("target build lane must not be a symlink")

    return target_base, supplied_target, lease_dir


def acquire_lock(lock_path: Path, *, wait: bool, log: Log) -> object | None:
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    if lock_path.parent.is_symlink() or lock_path.is_symlink():
        raise ValueError(f"lock path must not be a symlink: {lock_path}")
    lock_file = lock_path.open("a+b")
    flags = fcntl.LOCK_EX | fcntl.LOCK_NB
    announced_wait = False
    while True:
        try:
            fcntl.flock(lock_file.fileno(), flags)
            return lock_file
        except BlockingIOError:
            if not wait:
                lock_file.close()
                return None
            if not announced_wait:
                log("cargo-local: waiting for another process to seed this build lane")
                announced_wait = True
            time.sleep(1)


def seed_from_donor(
    donor: Donor,
    target_base: Path,
    target: Path,
    *,
    clone: Clone,
    log: Log,
) -> str:
    started = time.monotonic()
    temporary = Path(
        tempfile.mkdtemp(
            prefix=f".{target.name}.seed-",
            dir=target_base,
        )
    )
    try:
        log(
            "cargo-local: seeding fresh Rust build lane from "
            f"{donor.segment} with copy-on-write"
        )
        clone(donor.path / "debug", temporary / "debug", log)
        rustc_info = donor.path / ".rustc_info.json"
        if rustc_info.is_file() and not rustc_info.is_symlink():
            shutil.copy2(rustc_info, temporary / rustc_info.name)

        if target.exists() or target.is_symlink():
            return RESULT_EXISTS
        temporary.rename(target)
        elapsed = time.monotonic() - started
        log(
            "cargo-local: seeded "
            f"{donor.artifact_count} cached artifacts in {elapsed:.1f}s; "
            "Cargo will validate them before reuse"
        )
        return RESULT_SEEDED
    finally:
        if temporary.exists():
            shutil.rmtree(temporary)


def seed_lane(
    repo_root: Path,
    target: Path,
    target_segment: str,
    *,
    clone: Clone = clone_debug_tree,
    log: Log = lambda message: print(message, file=sys.stderr, flush=True),
) -> str:
    target_base, target, lease_dir = validate_layout(
        repo_root,
        target,
        target_segment,
    )
    seed_lock_path = (
        repo_root.resolve(strict=True)
        / "target"
        / ".cargo-local"
        / "seed-locks"
        / f"{target_segment}.lock"
    )
    seed_lock = acquire_lock(seed_lock_path, wait=True, log=log)
    if seed_lock is None:
        return RESULT_FAILED

    try:
        if target.exists():
            return RESULT_EXISTS

        for donor in find_donors(target_base, target, lease_dir):
            donor_lock = acquire_lock(donor.lock_path, wait=False, log=log)
            if donor_lock is None:
                continue
            try:
                if has_live_lease(lease_dir, donor.segment):
                    continue
                try:
                    return seed_from_donor(
                        donor,
                        target_base,
                        target,
                        clone=clone,
                        log=log,
                    )
                except CopyOnWriteUnsupported as error:
                    log(
                        "cargo-local: copy-on-write lane seeding is unavailable "
                        f"({error}); starting cold"
                    )
                    return RESULT_UNSUPPORTED
                except (OSError, RuntimeError) as error:
                    log(
                        "cargo-local: could not seed the fresh build lane "
                        f"({error}); starting cold"
                    )
                    return RESULT_FAILED
            finally:
                donor_lock.close()
        return RESULT_NO_DONOR
    finally:
        seed_lock.close()


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Seed a fresh per-worktree Cargo target lane with COW clones."
    )
    parser.add_argument("--repo-root", required=True, type=Path)
    parser.add_argument("--target-dir", required=True, type=Path)
    parser.add_argument("--target-segment", required=True)
    parser.add_argument(
        "--require-seed",
        action="store_true",
        help="Return a distinct nonzero status when no lane could be seeded.",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    try:
        result = seed_lane(
            args.repo_root,
            args.target_dir,
            args.target_segment,
        )
    except (OSError, ValueError) as error:
        print(f"cargo-local: invalid build-lane seed request: {error}", file=sys.stderr)
        return 2

    if not args.require_seed:
        return 0
    if result == RESULT_UNSUPPORTED:
        return EXIT_UNSUPPORTED
    if result == RESULT_NO_DONOR:
        return EXIT_NO_DONOR
    if result == RESULT_FAILED:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
