#!/usr/bin/env python3
"""Verify that a live GitHub issue renders the intended markdown correctly."""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from html.parser import HTMLParser
from pathlib import Path
from typing import NoReturn

from title_rules import validate_title

ISSUE_URL_RE = re.compile(r"^https://github\.com/(?P<repo>[^/]+/[^/]+)/issues/(?P<number>\d+)$")
IMAGE_RE = re.compile(r"!\[[^\]]*]\(([^)]+)\)")
TASK_RE = re.compile(r"(?m)^- \[[ xX]\] ")
FENCED_BLOCK_RE = re.compile(r"```.*?```", re.DOTALL)
INLINE_CODE_RE = re.compile(r"(?<!`)`([^`\n]+)`(?!`)")
ISSUE_REF_RE = re.compile(r"(?<![\w`])#([1-9]\d*)\b")


class RenderParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.code_texts: list[str] = []
        self.links: list[str] = []
        self.image_urls: list[str] = []
        self.checkbox_count = 0
        self._in_code = False
        self._current_code: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "code":
            self._in_code = True
            self._current_code = []
        elif tag == "img":
            candidate = attributes.get("data-canonical-src") or attributes.get("src")
            if candidate:
                self.image_urls.append(candidate)
        elif tag == "input" and attributes.get("type") == "checkbox":
            self.checkbox_count += 1
        elif tag == "a":
            href = attributes.get("href")
            if href:
                self.links.append(href)

    def handle_endtag(self, tag: str) -> None:
        if tag == "code" and self._in_code:
            text = normalize_space("".join(self._current_code))
            if text:
                self.code_texts.append(text)
            self._in_code = False
            self._current_code = []

    def handle_data(self, data: str) -> None:
        if self._in_code:
            self._current_code.append(data)


def die(message: str) -> NoReturn:
    raise SystemExit(f"error: {message}")


def run(cmd: list[str]) -> str:
    completed = subprocess.run(cmd, capture_output=True, text=True, check=False)
    if completed.returncode != 0:
        stderr = completed.stderr.strip()
        stdout = completed.stdout.strip()
        detail = stderr or stdout or f"exit {completed.returncode}"
        die(f"command failed: {' '.join(cmd)}\n{detail}")
    return completed.stdout


def resolve_repo(repo: str | None) -> str:
    if repo:
        return repo
    return run(["gh", "repo", "view", "--json", "nameWithOwner", "--jq", ".nameWithOwner"]).strip()


def parse_issue_ref(issue: str, repo_override: str | None) -> tuple[str, int]:
    match = ISSUE_URL_RE.match(issue)
    if match:
        return match.group("repo"), int(match.group("number"))
    if issue.isdigit():
        return resolve_repo(repo_override), int(issue)
    die(f"invalid issue reference: {issue}")


def normalize_markdown(text: str) -> str:
    return text.replace("\r\n", "\n").rstrip("\n")


def normalize_space(text: str) -> str:
    return " ".join(text.split())


def dedupe(items: list[str]) -> list[str]:
    seen: set[str] = set()
    ordered: list[str] = []
    for item in items:
        if item not in seen:
            ordered.append(item)
            seen.add(item)
    return ordered


def strip_code_regions(text: str) -> str:
    text = FENCED_BLOCK_RE.sub("", text)
    return INLINE_CODE_RE.sub("", text)


def term_only_in_fenced_blocks(term: str, body: str) -> bool:
    """Return True if the term appears in the body but only inside fenced code blocks.

    Fenced blocks are inherently code-formatted and cannot lose their
    backtick wrapping, so verifying them against rendered <code> tags
    produces false positives.
    """
    if term not in body:
        return False
    body_without_fences = FENCED_BLOCK_RE.sub("", body)
    return term not in body_without_fences


def load_terms(path: str | None) -> list[str]:
    if path is None:
        return []
    file_path = Path(path)
    if not file_path.is_file():
        die(f"expected-code file not found: {path}")
    return [line.strip() for line in file_path.read_text().splitlines() if line.strip()]


def load_title(path: str | None) -> str | None:
    if path is None:
        return None
    file_path = Path(path)
    if not file_path.is_file():
        die(f"expected-title file not found: {path}")
    return file_path.read_text(encoding="utf-8").rstrip("\r\n")


def fetch_issue(repo: str, number: int) -> dict:
    output = run(
        [
            "gh",
            "api",
            "-H",
            "Accept: application/vnd.github.full+json",
            f"repos/{repo}/issues/{number}",
        ]
    )
    return json.loads(output)


def check_url(url: str) -> int:
    request = urllib.request.Request(url, method="GET")
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            return response.getcode()
    except urllib.error.HTTPError as exc:
        return exc.code
    except urllib.error.URLError:
        return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify rendered markdown for a live GitHub issue.")
    parser.add_argument("--issue", required=True, help="issue number or full issue URL")
    parser.add_argument("--repo", help="owner/name repository override when issue is numeric")
    parser.add_argument("--body-file", help="approved markdown body to compare against the live issue")
    expected_title_group = parser.add_mutually_exclusive_group()
    expected_title_group.add_argument("--expected-title", help="approved issue title")
    expected_title_group.add_argument("--expected-title-file", help="path to a file containing the approved issue title")
    parser.add_argument("--expected-code", action="append", default=[], help="code term that must render inside <code>")
    parser.add_argument("--expected-code-file", help="path to a file containing one expected code term per line")
    parser.add_argument("--no-derive-inline-code", action="store_true", help="do not derive expected code terms from inline code in --body-file")
    parser.add_argument("--check-issue-links", action="store_true", help="verify that #123 references render as links in the live HTML")
    args = parser.parse_args()

    repo, number = parse_issue_ref(args.issue, args.repo)
    issue = fetch_issue(repo, number)
    live_body = issue.get("body") or ""
    live_html = issue.get("body_html") or ""
    live_title = issue.get("title") or ""
    expected_title = args.expected_title if args.expected_title is not None else load_title(args.expected_title_file)

    parser_state = RenderParser()
    parser_state.feed(live_html)

    expected_body = live_body
    if args.body_file:
        body_path = Path(args.body_file)
        if not body_path.is_file():
            die(f"body file not found: {args.body_file}")
        expected_body = body_path.read_text()

    expected_code_terms = list(args.expected_code)
    expected_code_terms.extend(load_terms(args.expected_code_file))
    if args.body_file and not args.no_derive_inline_code:
        body_without_fences = FENCED_BLOCK_RE.sub("", expected_body)
        expected_code_terms.extend(INLINE_CODE_RE.findall(body_without_fences))
    expected_code_terms = dedupe([term for term in expected_code_terms if term.strip()])
    if args.body_file:
        expected_code_terms = [
            term for term in expected_code_terms
            if not term_only_in_fenced_blocks(term, expected_body)
        ]

    expected_images = IMAGE_RE.findall(expected_body)
    expected_task_count = len(TASK_RE.findall(expected_body))
    title_validation = validate_title(live_title)

    failures: list[str] = []
    checks: dict[str, object] = {
        "repo": repo,
        "issue_number": number,
        "issue_url": issue.get("html_url"),
        "live_title": live_title,
        "expected_title": expected_title,
        "title_matches_expected": None,
        "title_validation": title_validation.as_dict(),
        "live_body_matches_body_file": None,
        "expected_image_count": len(expected_images),
        "rendered_image_count": len(parser_state.image_urls),
        "expected_task_count": expected_task_count,
        "rendered_checkbox_count": parser_state.checkbox_count,
        "expected_code_terms": expected_code_terms,
        "missing_code_terms": [],
        "unreachable_image_urls": [],
        "missing_issue_links": [],
    }

    if not title_validation.ok:
        failures.append("live issue title is not a valid semantic `type(scope): description` title")

    if expected_title is not None:
        title_matches = live_title == expected_title
        checks["title_matches_expected"] = title_matches
        if not title_matches:
            failures.append("live issue title does not match the approved title")

    if args.body_file:
        body_matches = normalize_markdown(expected_body) == normalize_markdown(live_body)
        checks["live_body_matches_body_file"] = body_matches
        if not body_matches:
            failures.append("live issue body does not match the approved body file")

    if expected_images and len(parser_state.image_urls) < len(expected_images):
        failures.append(
            f"rendered HTML has {len(parser_state.image_urls)} image tag(s) but the issue body expects {len(expected_images)} image(s)"
        )

    unreachable_images: list[str] = []
    for image_url in expected_images:
        status = check_url(image_url)
        if status != 200:
            unreachable_images.append(f"{image_url} (HTTP {status})")
    if unreachable_images:
        checks["unreachable_image_urls"] = unreachable_images
        failures.append("one or more embedded image URLs are not reachable")

    rendered_code_list = [normalize_space(code_text) for code_text in parser_state.code_texts]
    rendered_code_set = set(rendered_code_list)

    def term_rendered(term: str) -> bool:
        normalized = normalize_space(term)
        if normalized in rendered_code_set:
            return True
        return any(normalized in code_text for code_text in rendered_code_list)

    missing_code_terms = [term for term in expected_code_terms if not term_rendered(term)]
    checks["missing_code_terms"] = missing_code_terms
    if missing_code_terms:
        failures.append("one or more expected code terms are not rendered inside code tags")

    if expected_task_count != parser_state.checkbox_count:
        failures.append(
            f"rendered checkbox count {parser_state.checkbox_count} does not match expected task count {expected_task_count}"
        )

    if args.check_issue_links:
        stripped_body = strip_code_regions(expected_body)
        expected_links = dedupe(ISSUE_REF_RE.findall(stripped_body))
        missing_issue_links: list[str] = []
        for ref in expected_links:
            issue_path = f"/{repo}/issues/{ref}"
            pull_path = f"/{repo}/pull/{ref}"
            if issue_path not in parser_state.links and pull_path not in parser_state.links:
                missing_issue_links.append(f"#{ref}")
        checks["missing_issue_links"] = missing_issue_links
        if missing_issue_links:
            failures.append("one or more #issue references did not render as links")

    result = {
        "ok": not failures,
        "checks": checks,
        "failures": failures,
    }
    print(json.dumps(result, indent=2))
    return 0 if not failures else 1


if __name__ == "__main__":
    sys.exit(main())
