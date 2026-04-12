#!/usr/bin/env python3
"""Create or edit GitHub issues through gh with body-file safety."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import NoReturn

from title_rules import validate_title

ISSUE_URL_RE = re.compile(r"^https://github\.com/(?P<repo>[^/]+/[^/]+)/issues/(?P<number>\d+)$")


def die(message: str) -> NoReturn:
    raise SystemExit(f"error: {message}")


def run(cmd: list[str]) -> str:
    completed = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        stderr = completed.stderr.strip()
        stdout = completed.stdout.strip()
        detail = stderr or stdout or f"exit {completed.returncode}"
        die(f"command failed: {' '.join(cmd)}\n{detail}")
    return completed.stdout.strip()


def resolve_repo(repo: str | None) -> str:
    if repo:
        return repo
    return run(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"])


def parse_issue_ref(issue: str, repo_override: str | None) -> tuple[str, int]:
    match = ISSUE_URL_RE.match(issue)
    if match:
        return match.group("repo"), int(match.group("number"))
    if issue.isdigit():
        return resolve_repo(repo_override), int(issue)
    die(f"invalid issue reference: {issue}")


def normalize_labels(raw_labels: list[str]) -> list[str]:
    labels: list[str] = []
    for raw in raw_labels:
        parts = [part.strip() for part in raw.split(",")]
        labels.extend(part for part in parts if part)
    deduped: list[str] = []
    seen: set[str] = set()
    for label in labels:
        if label not in seen:
            deduped.append(label)
            seen.add(label)
    return deduped


def parse_created_issue_url(output: str) -> tuple[str, int]:
    for line in reversed([line.strip() for line in output.splitlines() if line.strip()]):
        match = ISSUE_URL_RE.match(line)
        if match:
            return match.group("repo"), int(match.group("number"))
    die("could not parse created issue URL from gh output")


def issue_view(repo: str, number: int) -> dict:
    output = run(
        [
            "gh",
            "issue",
            "view",
            str(number),
            "--repo",
            repo,
            "--json",
            "number,title,url,labels",
        ]
    )
    data = json.loads(output)
    data["repo"] = repo
    data["labels"] = [label["name"] for label in data.get("labels", [])]
    return data


def ensure_file(path: str | None) -> str | None:
    if path is None:
        return None
    resolved = Path(path)
    if not resolved.is_file():
        die(f"file not found: {path}")
    return str(resolved)


def read_title_file(path: str) -> str:
    resolved = Path(path)
    if not resolved.is_file():
        die(f"title file not found: {path}")
    return resolved.read_text(encoding="utf-8").rstrip("\r\n")


def resolve_title(raw_title: str | None, title_file: str | None) -> str | None:
    if title_file is not None:
        return read_title_file(title_file)
    return raw_title


def validate_title_or_die(title: str) -> dict[str, object]:
    result = validate_title(title)
    if not result.ok:
        details = "\n".join(f"- {error}" for error in result.errors)
        die(f"invalid issue title:\n{details}")
    return result.as_dict()


def cmd_create(args: argparse.Namespace) -> int:
    repo = resolve_repo(args.repo)
    body_file = ensure_file(args.body_file)
    title = resolve_title(args.title, args.title_file)
    if title is None:
        die("create requires a title")
    labels = normalize_labels(args.label)
    title_validation = validate_title_or_die(title)
    command = [
        "gh",
        "issue",
        "create",
        "--repo",
        repo,
        "--title",
        title,
        "--body-file",
        body_file,
    ]
    for label in labels:
        command.extend(["--label", label])

    if args.dry_run:
        print(
            json.dumps(
                {
                    "action": "create",
                    "repo": repo,
                    "command": command,
                    "title_validation": title_validation,
                },
                indent=2,
            )
        )
        return 0

    output = run(command)
    created_repo, number = parse_created_issue_url(output)
    print(json.dumps(issue_view(created_repo, number), indent=2))
    return 0


def cmd_edit(args: argparse.Namespace) -> int:
    repo, number = parse_issue_ref(args.issue, args.repo)
    body_file = ensure_file(args.body_file)
    title = resolve_title(args.title, args.title_file)
    add_labels = normalize_labels(args.add_label)
    remove_labels = normalize_labels(args.remove_label)

    command = ["gh", "issue", "edit", str(number), "--repo", repo]
    title_validation: dict[str, object] | None = None
    if title is not None:
        title_validation = validate_title_or_die(title)
        command.extend(["--title", title])
    if body_file is not None:
        command.extend(["--body-file", body_file])
    for label in add_labels:
        command.extend(["--add-label", label])
    for label in remove_labels:
        command.extend(["--remove-label", label])

    if len(command) == 5:
        die("edit requires at least one change")

    if args.dry_run:
        print(
            json.dumps(
                {
                    "action": "edit",
                    "repo": repo,
                    "issue": number,
                    "command": command,
                    "title_validation": title_validation,
                },
                indent=2,
            )
        )
        return 0

    run(command)
    print(json.dumps(issue_view(repo, number), indent=2))
    return 0


def cmd_validate_title(args: argparse.Namespace) -> int:
    title = resolve_title(args.title, args.title_file)
    if title is None:
        die("validate-title requires a title")
    result = validate_title(title)
    print(json.dumps(result.as_dict(), indent=2))
    return 0 if result.ok else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Create or edit GitHub issues safely with body files.")
    subparsers = parser.add_subparsers(dest="command", required=True)

    create_parser = subparsers.add_parser("create", help="create a new issue")
    create_parser.add_argument("--repo", help="owner/name repository override")
    create_title_group = create_parser.add_mutually_exclusive_group(required=True)
    create_title_group.add_argument("--title", help="issue title")
    create_title_group.add_argument("--title-file", help="path to a file containing the issue title")
    create_parser.add_argument("--body-file", required=True, help="path to markdown body file")
    create_parser.add_argument("--label", action="append", default=[], help="label name, may be repeated or comma-separated")
    create_parser.add_argument("--dry-run", action="store_true", help="print the resolved gh command instead of creating")
    create_parser.set_defaults(func=cmd_create)

    edit_parser = subparsers.add_parser("edit", help="edit an existing issue")
    edit_parser.add_argument("--repo", help="owner/name repository override when issue is numeric")
    edit_parser.add_argument("--issue", required=True, help="issue number or full issue URL")
    edit_title_group = edit_parser.add_mutually_exclusive_group()
    edit_title_group.add_argument("--title", help="new issue title")
    edit_title_group.add_argument("--title-file", help="path to a file containing the new issue title")
    edit_parser.add_argument("--body-file", help="path to markdown body file")
    edit_parser.add_argument("--add-label", action="append", default=[], help="label to add, may be repeated or comma-separated")
    edit_parser.add_argument("--remove-label", action="append", default=[], help="label to remove, may be repeated or comma-separated")
    edit_parser.add_argument("--dry-run", action="store_true", help="print the resolved gh command instead of editing")
    edit_parser.set_defaults(func=cmd_edit)

    validate_parser = subparsers.add_parser("validate-title", help="validate an issue title")
    validate_title_group = validate_parser.add_mutually_exclusive_group(required=True)
    validate_title_group.add_argument("--title", help="issue title")
    validate_title_group.add_argument("--title-file", help="path to a file containing the issue title")
    validate_parser.set_defaults(func=cmd_validate_title)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
