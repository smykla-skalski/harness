#!/usr/bin/python3

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import struct
from pathlib import Path
from typing import Any, Iterable


STATE_VERSION = 2


def _first_logical_rule(data: bytes) -> bytes:
    rule = bytearray()
    for raw_line in data.splitlines(keepends=True):
        line = raw_line.rstrip(b"\r\n")
        trailing_backslashes = len(line) - len(line.rstrip(b"\\"))
        if trailing_backslashes % 2 == 1:
            rule.extend(line[:-1])
            rule.extend(b" ")
            continue
        rule.extend(line)
        break
    return bytes(rule)


def _rule_dependencies(rule: bytes) -> bytes:
    escaped = False
    for index, value in enumerate(rule):
        if escaped:
            escaped = False
        elif value == ord("\\"):
            escaped = True
        elif value == ord(":"):
            return rule[index + 1 :]
    raise ValueError("compiler dep-info has no target separator")


def _makefile_tokens(value: bytes) -> list[bytes]:
    tokens: list[bytes] = []
    token = bytearray()
    escaped = False
    for byte in value:
        if escaped:
            token.append(byte)
            escaped = False
        elif byte == ord("\\"):
            escaped = True
        elif byte in (ord(" "), ord("\t")):
            if token:
                tokens.append(bytes(token))
                token.clear()
        else:
            token.append(byte)
    if escaped:
        token.append(ord("\\"))
    if token:
        tokens.append(bytes(token))
    return tokens


def _normalize_path(path: str, repo_root: str) -> str:
    if not os.path.isabs(path):
        path = os.path.join(repo_root, path)
    return os.path.abspath(os.path.normpath(path))


def _is_within(path: str, root: str) -> bool:
    try:
        return os.path.commonpath((path, root)) == root
    except ValueError:
        return False


def _sorted_paths(paths: Iterable[str]) -> list[str]:
    return sorted(set(paths), key=os.fsencode)


def _compiler_inputs(dep_info_path: str, repo_root: str) -> list[str]:
    repo_root = os.path.abspath(repo_root)
    rule = _first_logical_rule(Path(dep_info_path).read_bytes())
    dependencies = _makefile_tokens(_rule_dependencies(rule))
    inputs: list[str] = []
    for raw_path in dependencies:
        path = _normalize_path(os.fsdecode(raw_path), repo_root)
        if not _is_within(path, repo_root):
            continue
        if os.path.lexists(path):
            inputs.append(path)
    return _sorted_paths(inputs)


def _write_manifest(args: argparse.Namespace) -> None:
    inputs = _compiler_inputs(args.dep_info, args.repo_root)
    if not inputs:
        raise ValueError(
            f"compiler dep-info contained no worktree inputs: {args.dep_info}"
        )
    payload = b"".join(os.fsencode(path) + b"\0" for path in inputs)
    Path(args.output).write_bytes(payload)


def _read_manifest(path: str) -> list[str]:
    payload = Path(path).read_bytes()
    if b"\0" in payload:
        entries = payload.split(b"\0")
    else:
        # Upgrade old line-delimited manifests in place on the next rebuild.
        entries = payload.splitlines()
    return [os.fsdecode(entry) for entry in entries if entry]


def _directory_inputs(path: str) -> list[str]:
    inputs = [path]
    for current_root, directory_names, file_names in os.walk(
        path, followlinks=False
    ):
        directory_names.sort(key=os.fsencode)
        file_names.sort(key=os.fsencode)

        traversable_directories: list[str] = []
        for name in directory_names:
            child = os.path.join(current_root, name)
            if os.path.islink(child):
                inputs.append(child)
            else:
                inputs.append(child)
                traversable_directories.append(name)
        directory_names[:] = traversable_directories

        for name in file_names:
            child = os.path.join(current_root, name)
            try:
                child_mode = os.lstat(child).st_mode
            except FileNotFoundError:
                inputs.append(child)
                continue
            if stat.S_ISREG(child_mode) or stat.S_ISLNK(child_mode):
                inputs.append(child)
    return inputs


def _expanded_inputs(paths: Iterable[str], repo_root: str) -> list[str]:
    expanded: list[str] = []
    for raw_path in paths:
        path = _normalize_path(raw_path, repo_root)
        try:
            mode = os.lstat(path).st_mode
        except FileNotFoundError:
            expanded.append(path)
            continue
        if stat.S_ISDIR(mode):
            expanded.extend(_directory_inputs(path))
        else:
            expanded.append(path)
    return _sorted_paths(expanded)


def _source_manifests(source_inputs: Iterable[str], repo_root: str) -> list[str]:
    manifests = [os.path.join(repo_root, "Cargo.toml")]
    for path in source_inputs:
        current = path if os.path.isdir(path) else os.path.dirname(path)
        while _is_within(current, repo_root) and current != repo_root:
            manifest = os.path.join(current, "Cargo.toml")
            if os.path.isfile(manifest):
                manifests.append(manifest)
            current = os.path.dirname(current)
    return _sorted_paths(manifests)


def _metadata(values: Iterable[str]) -> dict[str, str]:
    metadata: dict[str, str] = {}
    for value in values:
        key, separator, metadata_value = value.partition("=")
        if not separator or not key:
            raise ValueError(f"invalid metadata entry: {value!r}")
        metadata[key] = metadata_value
    return metadata


def _update_bytes(digest: Any, value: bytes) -> None:
    digest.update(struct.pack(">Q", len(value)))
    digest.update(value)


def _path_label(path: str, repo_root: str) -> bytes:
    if _is_within(path, repo_root):
        return os.fsencode(os.path.relpath(path, repo_root))
    return os.fsencode(path)


def _hash_input(digest: Any, path: str, repo_root: str) -> None:
    _update_bytes(digest, b"input")
    _update_bytes(digest, _path_label(path, repo_root))
    try:
        path_stat = os.lstat(path)
    except FileNotFoundError:
        _update_bytes(digest, b"missing")
        return

    mode = path_stat.st_mode
    _update_bytes(digest, str(stat.S_IMODE(mode)).encode())
    if stat.S_ISLNK(mode):
        _update_bytes(digest, b"symlink")
        _update_bytes(digest, os.fsencode(os.readlink(path)))
    elif stat.S_ISDIR(mode):
        _update_bytes(digest, b"directory")
    elif stat.S_ISREG(mode):
        _update_bytes(digest, b"file")
        _update_bytes(digest, str(path_stat.st_size).encode())
        with open(path, "rb") as input_file:
            while chunk := input_file.read(1024 * 1024):
                digest.update(chunk)
    else:
        _update_bytes(digest, b"other")


def _record_trace() -> None:
    trace_path = os.environ.get(
        "HARNESS_MONITOR_DAEMON_INPUT_STATE_TRACE_PATH", ""
    )
    if trace_path:
        with open(trace_path, "ab") as trace:
            trace.write(b"state\n")


def _write_state(args: argparse.Namespace) -> None:
    _record_trace()
    repo_root = os.path.abspath(args.repo_root)
    source_inputs = [
        _normalize_path(path, repo_root)
        for path in _read_manifest(args.source_manifest)
    ]
    all_inputs = list(args.global_input)
    all_inputs.extend(source_inputs)
    all_inputs.extend(_source_manifests(source_inputs, repo_root))
    all_inputs.append(os.path.abspath(__file__))
    inputs = _expanded_inputs(all_inputs, repo_root)
    metadata = _metadata(args.metadata)

    digest = hashlib.sha256()
    _update_bytes(
        digest,
        json.dumps(
            metadata, ensure_ascii=True, separators=(",", ":"), sort_keys=True
        ).encode(),
    )
    for path in inputs:
        _hash_input(digest, path, repo_root)

    state = {
        "digest": digest.hexdigest(),
        "input_count": len(inputs),
        "metadata": metadata,
        "version": STATE_VERSION,
    }
    print(
        json.dumps(
            state, ensure_ascii=True, separators=(",", ":"), sort_keys=True
        )
    )


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    manifest = subparsers.add_parser("manifest")
    manifest.add_argument("--dep-info", required=True)
    manifest.add_argument("--repo-root", required=True)
    manifest.add_argument("--output", required=True)
    manifest.set_defaults(handler=_write_manifest)

    state = subparsers.add_parser("state")
    state.add_argument("--repo-root", required=True)
    state.add_argument("--source-manifest", required=True)
    state.add_argument("--global-input", action="append", default=[])
    state.add_argument("--metadata", action="append", default=[])
    state.set_defaults(handler=_write_state)
    return parser


def main() -> None:
    args = _parser().parse_args()
    try:
        args.handler(args)
    except (OSError, ValueError) as error:
        raise SystemExit(f"daemon-input-state: {error}") from error


if __name__ == "__main__":
    main()
