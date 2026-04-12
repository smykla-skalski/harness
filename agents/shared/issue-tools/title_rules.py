#!/usr/bin/env python3
"""Shared semantic title validation for GitHub issues."""

from __future__ import annotations

from dataclasses import dataclass
import re

ALLOWED_TYPES = (
    "feat",
    "fix",
    "docs",
    "style",
    "refactor",
    "test",
    "chore",
    "ci",
    "build",
    "perf",
)

TITLE_EXAMPLE = "fix(workflow/create): preserve proposal validation errors in summary"
_TITLE_RE = re.compile(
    rf"^(?P<issue_type>{'|'.join(ALLOWED_TYPES)})\("
    r"(?P<scope>[a-z0-9]+(?:[/-][a-z0-9]+)*)\): "
    r"(?P<description>\S(?:.*\S)?)$"
)


@dataclass(frozen=True)
class TitleValidationResult:
    title: str
    ok: bool
    errors: tuple[str, ...]
    issue_type: str | None = None
    scope: str | None = None
    description: str | None = None

    def as_dict(self) -> dict[str, object]:
        return {
            "ok": self.ok,
            "title": self.title,
            "type": self.issue_type,
            "scope": self.scope,
            "description": self.description,
            "errors": list(self.errors),
            "allowed_types": list(ALLOWED_TYPES),
            "example": TITLE_EXAMPLE,
        }


def validate_title(raw_title: str) -> TitleValidationResult:
    title = raw_title.rstrip("\r\n")
    stripped = title.strip()
    errors: list[str] = []

    if not stripped:
        errors.append("title must not be empty")
        return TitleValidationResult(title=title, ok=False, errors=tuple(errors))

    if title != stripped:
        errors.append("title must not start or end with whitespace")

    if "\n" in title or "\r" in title:
        errors.append("title must be a single line")

    match = _TITLE_RE.fullmatch(stripped)
    if match is None:
        errors.append("title must match `type(scope): description` with a mandatory lowercase scope")
        errors.append(f"allowed types: {', '.join(ALLOWED_TYPES)}")
        errors.append(f"example: {TITLE_EXAMPLE}")
        return TitleValidationResult(title=title, ok=False, errors=tuple(errors))

    description = match.group("description")
    if description.endswith("."):
        errors.append("description must not end with a period")

    return TitleValidationResult(
        title=stripped,
        ok=not errors,
        errors=tuple(errors),
        issue_type=match.group("issue_type"),
        scope=match.group("scope"),
        description=description,
    )

