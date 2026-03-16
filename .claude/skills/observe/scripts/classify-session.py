#!/usr/bin/env python3
"""Classify events from a Claude Code session JSONL log.

Reads incrementally, identifies issues, outputs structured JSON reports.
Supports one-shot scan and continuous watch modes.

Usage:
    classify-session.py <session-id> [options]

Options:
    --from-line N        Start from line N (default: 0)
    --watch              Poll for new events instead of one-shot
    --poll-interval S    Seconds between polls in watch mode (default: 3)
    --timeout S          Exit watch after S seconds with no new events (default: 90)
    --project-hint DIR   Narrow session search to this project dir name
"""

import argparse
import json
import re
import sys
import time
from dataclasses import asdict, dataclass, field
from pathlib import Path
from typing import Optional

CLAUDE_DIR = Path.home() / ".claude" / "projects"


# ---------------------------------------------------------------------------
# Data types
# ---------------------------------------------------------------------------

@dataclass
class Issue:
    line: int
    category: str
    severity: str
    summary: str
    details: str
    source_role: str
    fixable: bool
    fix_target: Optional[str] = None
    fix_hint: Optional[str] = None


@dataclass
class ScanState:
    """Mutable state carried across lines during a scan."""
    # Track which tool_use produced each tool_result
    last_tool_uses: dict[str, dict] = field(default_factory=dict)  # tool_use_id -> block
    # Track file edit churn
    edit_counts: dict[str, int] = field(default_factory=dict)
    # Dedup: (category, summary_prefix) -> line
    seen_issues: set = field(default_factory=set)
    # Session start timestamp (from first event)
    session_start_ts: Optional[str] = None


# ---------------------------------------------------------------------------
# Session lookup
# ---------------------------------------------------------------------------

def find_session(session_id: str, project_hint: str | None = None) -> Path | None:
    candidates = []
    for project_dir in CLAUDE_DIR.iterdir():
        if not project_dir.is_dir():
            continue
        if project_hint and project_hint not in project_dir.name:
            continue
        candidate = project_dir / f"{session_id}.jsonl"
        if candidate.exists():
            candidates.append(candidate)
    if len(candidates) == 1:
        return candidates[0]
    if len(candidates) > 1:
        for c in candidates:
            if project_hint and project_hint in str(c):
                return c
        return candidates[0]
    return None


# ---------------------------------------------------------------------------
# Text extraction helpers
# ---------------------------------------------------------------------------

def tool_result_text(block: dict) -> str:
    rc = block.get("content", "")
    if isinstance(rc, list):
        parts = []
        for rb in rc:
            if isinstance(rb, dict) and rb.get("type") == "text":
                parts.append(rb.get("text", ""))
        return "\n".join(parts)
    return str(rc) if rc else ""


def is_file_content(text: str) -> bool:
    """Heuristic: text from Read tool has line-numbered format (spaces+digits+arrow)."""
    lines = text.split("\n")[:5]
    numbered = sum(1 for ln in lines if re.match(r"^\s+\d+\u2192", ln))
    return numbered >= 2  # 2+ numbered lines = Read tool output


def is_help_output(text: str) -> bool:
    """Detect harness --help output (success, not error)."""
    lower = text.lower().strip()
    return (lower.startswith("kuma test harness") or
            (lower.startswith("usage: harness") and "error:" not in lower) or
            lower.startswith("handle session start hook\n\nusage:"))


def is_compaction_summary(text: str) -> bool:
    """Detect compaction context injection."""
    return "this session is being continued from a previous conversation" in text.lower()


def is_skill_injection(text: str) -> bool:
    """Detect skill content injected by Claude Code when a skill is loaded."""
    return text.strip().startswith("Base directory for this skill:")


# ---------------------------------------------------------------------------
# Pattern detectors
# ---------------------------------------------------------------------------

KSA_CODES = [f"KSA{i:03d}" for i in range(1, 20)]

CLI_ERROR_PATTERNS = [
    "harness: error:",
    "unrecognized arguments",
    "invalid choice:",
    "the following arguments are required:",
    "harness: unable to resolve",
]

TOOL_ERROR_PATTERNS = [
    "file has not been read yet",
    "file has been modified since read",
    "tool_use_error",
]

BUILD_ERROR_PATTERNS = [
    "error[e",              # rustc error codes like error[E0308]
    "could not compile",    # cargo build failure
    "missing_panics_doc",   # clippy pedantic lint
    "mismatched types",     # type error
    "cannot find value",    # missing import/variable
    "unresolved import",    # missing use statement
]

WORKFLOW_ERROR_PATTERNS = [
    "missing active suite", "missing suite:",
    "approval state is missing", "approval state invalid",
    "runner flow required",
]

USER_FRUSTRATION_SIGNALS = [
    "don't guess", "stop guessing", "i already told you",
    "why did you", "this is wrong", "read it again",
    "i said", "that's not what i", "no not that",
    "do a solid investigation",
]


def check_text_for_issues(
    line_num: int, role: str, text: str,
    source_tool: Optional[str] = None,
    state: Optional[ScanState] = None,
) -> list[Issue]:
    """Classify text content. source_tool is the tool that produced this text
    (e.g., 'Bash', 'Read', 'Edit') - None for assistant/human text blocks."""
    issues = []
    lower = text.lower()
    matched_categories = set()

    # Skip file content being read - it's documentation, not runtime errors
    if source_tool == "Read" or is_file_content(text):
        return issues

    # Skip help output, compaction summaries, and skill injections
    if is_help_output(text) or is_compaction_summary(text) or is_skill_injection(text):
        return issues

    # --- Hook denials (from actual hook output) ---
    if "denied this tool" in lower or "blocked by hook" in lower:
        issues.append(Issue(
            line=line_num, category="hook_failure", severity="medium",
            summary="Hook denied a tool call",
            details=text, source_role=role, fixable=False,
        ))
        matched_categories.add("hook_failure")

    # KSA codes - only from Bash output (hook execution), not from reading files
    # Require source_tool == "Bash" exactly - None means text/human injection (skill loading)
    if source_tool == "Bash":
        for code in KSA_CODES:
            if code.lower() in lower:
                issues.append(Issue(
                    line=line_num, category="hook_failure", severity="medium",
                    summary=f"Harness hook code {code} triggered",
                    details=text, source_role=role, fixable=True,
                    fix_hint=f"Check hook logic for {code}",
                ))
                matched_categories.add("hook_failure")
                break

    # --- CLI errors (only from Bash tool results with actual harness errors) ---
    if source_tool == "Bash" and "harness" in lower:
        for pat in CLI_ERROR_PATTERNS:
            if pat.lower() in lower:
                issues.append(Issue(
                    line=line_num, category="cli_error", severity="medium",
                    summary=f"Harness CLI error: {pat}",
                    details=text, source_role=role, fixable=True,
                    fix_target="src/cli.rs",
                ))
                matched_categories.add("cli_error")
                break

    # --- Tool errors ---
    for pat in TOOL_ERROR_PATTERNS:
        if pat.lower() in lower:
            issues.append(Issue(
                line=line_num, category="tool_error", severity="low",
                summary=f"Tool usage error: {pat}",
                details=text, source_role=role, fixable=False,
                fix_hint="Model behavior - read before edit",
            ))
            matched_categories.add("tool_error")
            break

    # --- Build errors (only from Bash output, not from reading source) ---
    if "cli_error" not in matched_categories and source_tool == "Bash":
        for pat in BUILD_ERROR_PATTERNS:
            if pat.lower() in lower:
                issues.append(Issue(
                    line=line_num, category="build_error", severity="critical",
                    summary="Build or lint failure",
                    details=text, source_role=role, fixable=True,
                    fix_hint="Fix the Rust code causing the failure",
                ))
                matched_categories.add("build_error")
                break

    # --- Workflow state errors (only from Bash output) ---
    if source_tool == "Bash":
        for pat in WORKFLOW_ERROR_PATTERNS:
            if pat.lower() in lower:
                issues.append(Issue(
                    line=line_num, category="workflow_error", severity="medium",
                    summary=f"Workflow state error: {pat}",
                    details=text, source_role=role, fixable=True,
                    fix_hint="Check workflow state machine logic",
                ))
                break

    # --- Harness command failures (preflight, apply, validate) ---
    # These indicate the authored suite produced bad manifests - a skill bug
    if source_tool == "Bash":
        is_harness_op = any(kw in lower for kw in [
            "preflight:", "harness preflight", "harness apply", "harness validate",
            "manifest validation", "apply failed", "validate failed",
            "admission webhook", "denied the request", "missing file: manifests/",
        ])
        exit_match = re.search(r"exit code (\d+)", lower)
        if not exit_match:
            exit_match = re.search(r"exit: (\d+)", lower)
        if exit_match:
            code = int(exit_match.group(1))
            if code != 0 and "build_error" not in matched_categories and "cli_error" not in matched_categories:
                is_harness_cmd = "harness" in lower and "authoring" in lower
                if is_harness_op:
                    issues.append(Issue(
                        line=line_num, category="skill_behavior", severity="medium",
                        summary=f"Authored manifest failed at runtime (exit {code})",
                        details=text, source_role=role, fixable=True,
                        fix_target="skills/new/SKILL.md",
                        fix_hint="suite:new produced manifests that fail preflight/apply/validate - check authoring validation",
                    ))
                elif is_harness_cmd:
                    issues.append(Issue(
                        line=line_num, category="workflow_error", severity="medium",
                        summary=f"Harness authoring command failed (exit {code})",
                        details=text, source_role=role, fixable=True,
                        fix_hint="Harness authoring command returned non-zero - check payload or arguments",
                    ))
                elif code != 1:
                    issues.append(Issue(
                        line=line_num, category="subagent_issue", severity="low",
                        summary=f"Non-zero exit code {code}",
                        details=text, source_role=role, fixable=False,
                        fix_hint=f"Command exited with code {code}",
                    ))

    # --- Pod/container failures from authored manifests ---
    if source_tool == "Bash":
        pod_failure_signals = [
            "crashloopbackoff", "imagepullbackoff", "errimagepull",
            "createcontainererror", "has been deprecated",
            "decoding failed", "cannot unmarshal the configuration",
        ]
        if any(sig in lower for sig in pod_failure_signals):
            issues.append(Issue(
                line=line_num, category="skill_behavior", severity="critical",
                summary="Authored manifest caused runtime failure",
                details=text, source_role=role, fixable=True,
                fix_target="skills/new/SKILL.md",
                fix_hint="suite:new produced a manifest with outdated or invalid config",
            ))

    # --- OAuth/auth flow triggered (cluster access attempt) ---
    if source_tool == "Bash":
        auth_signals = [
            "if browser window does not open automatically",
            "opening browser for authentication",
            "oauth2", "oidc", "gcloud auth",
            "az login", "aws sso login",
        ]
        if any(sig in lower for sig in auth_signals):
            issues.append(Issue(
                line=line_num, category="unexpected_behavior", severity="critical",
                summary="OAuth/auth flow triggered - command tried to reach a real cluster",
                details=text, source_role=role, fixable=True,
                fix_hint="Command attempted cluster auth. Block the binary in guard-bash or use local-only validation",
            ))

    # --- kubectl-validate usage (should use harness authoring-validate) ---
    if source_tool == "Bash" and "kubectl-validate" in lower:
        issues.append(Issue(
            line=line_num, category="skill_behavior", severity="critical",
            summary="kubectl-validate used directly instead of harness authoring-validate",
            details=text, source_role=role, fixable=True,
            fix_target="skills/new/SKILL.md",
            fix_hint="Use harness authoring-validate, not kubectl-validate. kubectl-validate can reach real clusters.",
        ))

    # --- Alias interference (cp -> rsync) ---
    if source_tool == "Bash" and "rsync" in lower:
        issues.append(Issue(
            line=line_num, category="unexpected_behavior", severity="medium",
            summary="Shell alias interference - rsync in cp output",
            details=text, source_role=role, fixable=False,
            fix_hint="Shell alias resolved cp to rsync - use /bin/cp",
        ))

    # --- Subagent permission failures (from task-notification results) ---
    if role == "user" and source_tool is None:
        permission_signals = [
            "i need bash permission", "i don't have bash permission",
            "i need write permission", "i don't have write permission",
            "permission to run", "could you grant",
            "need you to run this command",
        ]
        if any(sig in lower for sig in permission_signals):
            # Extract agent name from task-notification for unique dedup
            agent_match = re.search(r'Agent "([^"]+)"', text)
            agent_name = agent_match.group(1) if agent_match else "unknown"
            issues.append(Issue(
                line=line_num, category="subagent_issue", severity="medium",
                summary=f"Subagent '{agent_name}' blocked by missing permissions",
                details=text, source_role=role, fixable=True,
                fix_hint="Subagent needs permissionMode dontAsk or mode auto for Bash/Write",
            ))

    # --- Subagent save failures (assistant describing manual recovery) ---
    if role == "assistant" and source_tool is None:
        save_failure_signals = [
            "couldn't save", "could not save", "failed to save",
            "save it manually", "grab its payload", "save manually",
            "couldn't persist", "failed to persist",
            "completed but couldn't", "completed but could not",
            "couldn't write", "could not write",
            "let me save its payload", "let me extract and save",
        ]
        if any(sig in lower for sig in save_failure_signals):
            # Use first 40 chars of text for unique dedup per occurrence
            context = text[:40].replace("\n", " ").strip()
            issues.append(Issue(
                line=line_num, category="subagent_issue", severity="medium",
                summary=f"Subagent manual recovery: {context}",
                details=text, source_role=role, fixable=True,
                fix_hint="Subagent lacks write permissions or hit a harness CLI error during save",
            ))

    # --- Manual payload recovery (assistant grepping subagent output files) ---
    if role == "assistant" and source_tool is None:
        if "grep" in lower and ("output" in lower or "transcript" in lower or "payload" in lower):
            if any(kw in lower for kw in ["found the full payload", "extract and save", "grab its"]):
                issues.append(Issue(
                    line=line_num, category="subagent_issue", severity="medium",
                    summary="Manual payload recovery from subagent output",
                    details=text, source_role=role, fixable=True,
                    fix_hint="Subagent should save its own payload - manual grep recovery is a workflow failure",
                ))

    # --- Payload corruption (data wrapped in tags or escaped) ---
    if source_tool == "Bash":
        if "<json>" in lower or "</json>" in lower:
            issues.append(Issue(
                line=line_num, category="data_integrity", severity="medium",
                summary="Payload wrapped in <json> tags - data corruption from subagent",
                details=text, source_role=role, fixable=True,
                fix_hint="Subagent output contains XML-style tags around JSON - strip before parsing",
            ))

    # --- Python tracebacks in Bash output ---
    if source_tool == "Bash" and "traceback (most recent call last)" in lower:
        issues.append(Issue(
            line=line_num, category="build_error", severity="medium",
            summary="Python traceback in command output",
            details=text, source_role=role, fixable=True,
            fix_hint="Python script failed - check input data or script logic",
        ))

    # --- Suite deviation signals (assistant describing gaps in authored suite) ---
    if role == "assistant" and source_tool is None:
        deviation_signals = [
            "deviation from the suite", "only exist on",
            "should i apply baselines", "not applied to zone",
            "baselines to zone clusters", "missing from zone",
        ]
        if any(sig in lower for sig in deviation_signals):
            issues.append(Issue(
                line=line_num, category="skill_behavior", severity="critical",
                summary="Suite deviation - baselines/manifests not distributed to all required clusters",
                details=text, source_role=role, fixable=True,
                fix_target="skills/new/SKILL.md",
                fix_hint="suite:new must distribute baselines to all clusters in multi-zone profiles",
            ))

    # --- User frustration signals (only from actual human text, not tool results) ---
    # Require source_tool is None (human-typed text, not injected content)
    # and text must be short enough to be a real user message (not skill/system injection)
    # 2000 chars: longer text is likely system/skill injection, not typed by the user
    if role == "user" and source_tool is None and len(text) < 2000:
        excl_count = text.count("!")
        has_signal = any(sig in lower for sig in USER_FRUSTRATION_SIGNALS)
        # 4+ exclamation marks alone = frustration; 1+ with a signal phrase = confirmed
        if (excl_count >= 4) or (has_signal and excl_count >= 1) or has_signal:
            issues.append(Issue(
                line=line_num, category="user_frustration", severity="medium",
                summary="User frustration signal detected",
                details=text, source_role=role, fixable=False,
                fix_hint="Review what happened before this - likely a UX issue",
            ))

    return issues


def check_tool_use_for_issues(
    line_num: int, block: dict, state: Optional[ScanState] = None,
) -> list[Issue]:
    issues = []
    name = block.get("name", "")
    inp = block.get("input", {})

    if name == "Bash":
        cmd = inp.get("command", "")
        # Old skill names - only in actual harness CLI invocations with --skill flag
        # Not in cp/mv/diff/git-commit commands that reference old paths
        if re.search(r"--skill\s+(suite-author|suite-runner)\b", cmd):
            issues.append(Issue(
                line=line_num, category="naming_error", severity="medium",
                summary="Old skill name used in harness command",
                details=f"Command: {cmd}",
                source_role="assistant", fixable=True,
                fix_hint="SKILL.md or model still references old skill names",
            ))
        # Invalid harness arguments
        if "harness" in cmd and "validator-decision" in cmd:
            issues.append(Issue(
                line=line_num, category="cli_error", severity="medium",
                summary="Invalid harness subcommand/argument used",
                details=f"Command: {cmd}",
                source_role="assistant", fixable=True,
                fix_hint="SKILL.md references a non-existent harness kind",
            ))
        # Destructive commands without verification
        if re.search(r"\brm\s+(-\w+\s+)*.*-r", cmd) and "&&" not in cmd:
            issues.append(Issue(
                line=line_num, category="unexpected_behavior", severity="medium",
                summary="Destructive rm -r without chained verification",
                details=f"Command: {cmd}",
                source_role="assistant", fixable=False,
                fix_hint="Should verify target exists and is correct before deleting",
            ))

    if name == "AskUserQuestion":
        qs = inp.get("questions", [])
        for q in qs:
            if not isinstance(q, dict):
                continue
            question = q.get("question", "")
            options = q.get("options", [])
            # suite:run manifest-fix prompt - ALWAYS means authored manifest was wrong
            if "manifest-fix" in question and "how should this failure" in question.lower():
                issues.append(Issue(
                    line=line_num, category="skill_behavior", severity="critical",
                    summary="Manifest fix needed at runtime - authored suite has broken manifest",
                    details=f"Question: {question}",
                    source_role="assistant", fixable=True,
                    fix_target="skills/new/SKILL.md",
                    fix_hint="suite:new produced a manifest that fails at runtime and requires manual correction",
                ))
            # kubectl-validate prompt when already installed
            if "kubectl-validate" in question and "install" in question.lower():
                issues.append(Issue(
                    line=line_num, category="skill_behavior", severity="medium",
                    summary="Validator install prompt when binary may already exist",
                    details=f"Question: {question}",
                    source_role="assistant", fixable=True,
                    fix_target="skills/new/SKILL.md",
                    fix_hint="Step 0 should check if binary exists first",
                ))
            # Runtime deviations from authored suite - means suite:new missed something
            # Skip deviation detection for suite:new authoring workflow questions -
            # these are normal interactive steps, not runtime deviations
            header = q.get("header", "")
            q_lower = question.lower()
            authoring_indicators = [
                "approve current proposal", "confirm", "select which groups",
                "suite:new/prewrite", "suite:new/postwrite",
            ]
            is_authoring_question = any(ind in q_lower for ind in authoring_indicators)
            opt_parts = []
            for o in options:
                if isinstance(o, dict):
                    opt_parts.append(o.get("label", ""))
                    opt_parts.append(o.get("description", ""))
                else:
                    opt_parts.append(str(o))
            all_text = " ".join([header.lower(), q_lower] + [p.lower() for p in opt_parts])
            if not is_authoring_question and any(sig in all_text for sig in [
                "deviation", "only exist on", "should i apply",
                "not found on", "missing on", "baselines to zone",
                "missing from", "not installed", "not applied",
                "needs adjustment", "need to adjust", "ambiguity",
                "records a deviation", "this is a deviation",
            ]):
                issues.append(Issue(
                    line=line_num, category="skill_behavior", severity="critical",
                    summary="Runtime deviation - authored suite needs runtime correction",
                    details=f"Header: {header}, Question: {question}",
                    source_role="assistant", fixable=True,
                    fix_target="skills/new/SKILL.md",
                    fix_hint="suite:new should produce suites that don't require runtime deviations",
                ))
            # Wrong skill cross-reference in options
            for opt in options:
                label = opt.get("label", "") if isinstance(opt, dict) else str(opt)
                if "suite:new" in label.lower() and "suite:run" in question.lower():
                    issues.append(Issue(
                        line=line_num, category="skill_behavior", severity="medium",
                        summary="suite:run offering suite:new as structured choice",
                        details=f"Question: {question}, Option: {label}",
                        source_role="assistant", fixable=True,
                        fix_target="skills/run/SKILL.md",
                        fix_hint="suite:run should not offer suite:new as a structured option",
                    ))

    if name in ("Write", "Edit"):
        path = inp.get("file_path", "")
        if state:
            state.edit_counts[path] = state.edit_counts.get(path, 0) + 1
            count = state.edit_counts[path]
            # Report at 10 and 20 edits to flag churn without spamming on every edit
            if count == 10 or count == 20:
                issues.append(Issue(
                    line=line_num, category="unexpected_behavior", severity="medium",
                    summary=f"File modified {count} times - possible churn",
                    details=f"Path: {path}",
                    source_role="assistant", fixable=False,
                    fix_hint="Repeated modifications suggest trial-and-error",
                ))
        # Wrong SKILL.md name field
        if "SKILL.md" in path:
            content = inp.get("content", "") or inp.get("new_string", "")
            name_match = re.search(r"^name:\s*(\S+)", content, re.MULTILINE)
            if name_match:
                skill_name = name_match.group(1)
                # Short names without colon or slash are likely wrong
                if skill_name in ("new", "run", "observe") and ":" not in skill_name:
                    issues.append(Issue(
                        line=line_num, category="skill_behavior", severity="critical",
                        summary=f"SKILL.md name field uses short name '{skill_name}' instead of fully qualified",
                        details=f"Path: {path}, name: {skill_name}",
                        source_role="assistant", fixable=True,
                        fix_target=path,
                        fix_hint="Name should be fully qualified like 'suite:new' or 'suite:run'",
                    ))

    # Record tool_use for correlating with tool_result
    if state:
        tool_id = block.get("id", "")
        if tool_id:
            state.last_tool_uses[tool_id] = {"name": name, "input": inp}

    return issues


def resolve_source_tool(block: dict, state: Optional[ScanState]) -> Optional[str]:
    """Figure out which tool produced a tool_result block."""
    if not state:
        return None
    tool_id = block.get("tool_use_id", "")
    if tool_id and tool_id in state.last_tool_uses:
        return state.last_tool_uses[tool_id].get("name")
    return None


def dedup_issue(issue: Issue, state: ScanState) -> bool:
    """Return True if this issue is a duplicate that should be skipped."""
    # Truncate to 80 chars for dedup - enough to distinguish issue types, short enough to group variants
    key = (issue.category, issue.summary[:80])
    if key in state.seen_issues:
        return True
    state.seen_issues.add(key)
    return False


def classify_line(line_num: int, raw: str, state: Optional[ScanState] = None) -> list[Issue]:
    try:
        obj = json.loads(raw.strip())
    except json.JSONDecodeError:
        return []

    # Track session start timestamp
    if state and not state.session_start_ts:
        ts = obj.get("timestamp")
        if ts:
            state.session_start_ts = ts

    msg = obj.get("message", {})
    if not isinstance(msg, dict):
        return []

    role = msg.get("role", "")
    content = msg.get("content", [])
    issues = []

    if isinstance(content, list):
        for block in content:
            if not isinstance(block, dict):
                continue
            btype = block.get("type", "")

            if btype == "text":
                text = block.get("text", "")
                if len(text) > 5:  # skip trivial content like "ok" or empty
                    source = None  # assistant/human text blocks have no source tool
                    issues.extend(check_text_for_issues(
                        line_num, role, text, source_tool=source, state=state,
                    ))

            elif btype == "tool_use":
                issues.extend(check_tool_use_for_issues(line_num, block, state=state))

            elif btype == "tool_result":
                text = tool_result_text(block)
                if len(text) > 5:
                    source = resolve_source_tool(block, state)
                    issues.extend(check_text_for_issues(
                        line_num, role, text, source_tool=source, state=state,
                    ))

    elif isinstance(content, str) and len(content) > 5:
        issues.extend(check_text_for_issues(
            line_num, role, content, source_tool=None, state=state,
        ))

    # Dedup
    if state:
        issues = [i for i in issues if not dedup_issue(i, state)]

    return issues


# ---------------------------------------------------------------------------
# Scan modes
# ---------------------------------------------------------------------------

def scan(path: Path, from_line: int = 0) -> tuple[list[Issue], int]:
    """One-shot scan. Returns (issues, last_line_read)."""
    state = ScanState()
    issues = []
    last_line = from_line
    with open(path) as f:
        for i, line in enumerate(f):
            if i < from_line:
                continue
            last_line = i
            issues.extend(classify_line(i, line, state=state))
    return issues, last_line


def watch(path: Path, from_line: int, poll_interval: float, timeout: float,
          output_file: str | None = None,
          details_file: str | None = None) -> tuple[list[Issue], int]:
    """Watch for new events. timeout=0 means run forever.
    If output_file is set, write truncated issues there instead of stdout.
    If details_file is set, also append full untruncated issues there."""
    state = ScanState()
    issues = []
    last_line = from_line
    last_activity = time.time()
    out = None
    det = None
    if output_file:
        out = open(output_file, "a")
    if details_file:
        det = open(details_file, "a")

    def emit(issue: Issue):
        # Full details to details file
        if det:
            det.write(json.dumps(asdict(issue)) + "\n")
            det.flush()
        # Truncated to main output
        d = asdict(issue)
        d["details"] = d["details"][:500]
        line = json.dumps(d)
        if out:
            out.write(line + "\n")
            out.flush()
        else:
            print(line, flush=True)

    try:
        while True:
            try:
                with open(path) as f:
                    for i, line in enumerate(f):
                        if i <= last_line:
                            continue
                        new_issues = classify_line(i, line, state=state)
                        if new_issues:
                            issues.extend(new_issues)
                            for issue in new_issues:
                                emit(issue)
                        last_line = i
                        last_activity = time.time()
            except (OSError, json.JSONDecodeError):
                # File may be mid-write or rotated - retry on next poll cycle
                pass

            if timeout > 0 and time.time() - last_activity > timeout:
                break

            time.sleep(poll_interval)
    finally:
        if out:
            out.close()
        if det:
            det.close()

    return issues, last_line


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def dump_events(path: Path, from_line: int, to_line: int | None,
                text_filter: str | None, roles: str | None) -> None:
    """Raw event dump - replaces inline python scripts for session inspection."""
    role_set = set(roles.split(",")) if roles else None
    with open(path) as f:
        for i, line in enumerate(f):
            if i < from_line:
                continue
            if to_line is not None and i > to_line:
                break
            try:
                obj = json.loads(line.strip())
            except json.JSONDecodeError:
                continue
            msg = obj.get("message", {})
            if not isinstance(msg, dict):
                continue
            role = msg.get("role", "")
            if role_set and role not in role_set:
                continue
            content = msg.get("content", [])
            if isinstance(content, list):
                for block in content:
                    if not isinstance(block, dict):
                        continue
                    btype = block.get("type", "")
                    text = ""
                    label = ""
                    if btype == "text":
                        text = block.get("text", "")
                        label = f"L{i} [{role}] text"
                    elif btype == "tool_use":
                        name = block.get("name", "")
                        inp = block.get("input", {})
                        if name == "Bash":
                            text = inp.get("command", "")
                            label = f"L{i} [{role}] Bash"
                        elif name in ("Read", "Write", "Edit"):
                            text = inp.get("file_path", "")
                            if name == "Edit":
                                text += f"\n  old: {inp.get('old_string', '')[:100]}\n  new: {inp.get('new_string', '')[:100]}"
                            label = f"L{i} [{role}] {name}"
                        elif name == "AskUserQuestion":
                            qs = inp.get("questions", [])
                            parts = []
                            for q in qs:
                                if isinstance(q, dict):
                                    parts.append(f"header={q.get('header','')}, q={q.get('question','')}")
                            text = "; ".join(parts)
                            label = f"L{i} [{role}] AskUser"
                        elif name == "Agent":
                            text = inp.get("description", "")
                            label = f"L{i} [{role}] Agent"
                        else:
                            text = json.dumps(inp)[:300]
                            label = f"L{i} [{role}] {name}"
                    elif btype == "tool_result":
                        text = tool_result_text(block)
                        label = f"L{i} [{role}] result"
                    if not text or len(text) < 5:
                        continue
                    if text_filter and text_filter.lower() not in text.lower():
                        continue
                    print(f"{label}: {text[:500]}")
            elif isinstance(content, str) and len(content) > 5:
                if text_filter and text_filter.lower() not in content.lower():
                    continue
                print(f"L{i} [{role}]: {content[:500]}")


def context_around(path: Path, target_line: int, window: int = 10) -> None:
    """Show events around a specific line - for investigating flagged issues."""
    start = max(0, target_line - window)
    end = target_line + window
    dump_events(path, start, end, text_filter=None, roles=None)


def main():
    parser = argparse.ArgumentParser(description="Classify Claude Code session events")
    parser.add_argument("session_id", help="Session ID to observe")
    parser.add_argument("--from-line", type=int, default=0, help="Start from this line")
    parser.add_argument("--to-line", type=int, default=None, help="Stop at this line (dump/context modes)")
    parser.add_argument("--watch", action="store_true", help="Continuously poll for new events")
    parser.add_argument("--poll-interval", type=float, default=3.0, help="Poll interval in seconds")
    parser.add_argument("--timeout", type=float, default=90.0, help="Exit after N seconds of no activity")
    parser.add_argument("--project-hint", type=str, default=None, help="Project directory name hint")
    parser.add_argument("--json", action="store_true", help="Output as JSON lines")
    parser.add_argument("--summary", action="store_true", help="Print summary at end")
    parser.add_argument("--category", type=str, default=None,
                        help="Filter by category (comma-separated, e.g., 'build_error,cli_error')")
    parser.add_argument("--severity", type=str, default=None,
                        help="Filter by minimum severity: low, medium, critical")
    parser.add_argument("--fixable", action="store_true", help="Only show fixable issues")
    parser.add_argument("--exclude", type=str, default=None,
                        help="Exclude categories (comma-separated)")
    parser.add_argument("--output", type=str, default=None,
                        help="Write issues to this file (watch mode). Enables tailing.")
    parser.add_argument("--details-file", type=str, default=None,
                        help="Write full untruncated issues to this file. Main output stays truncated.")
    parser.add_argument("--dump", action="store_true",
                        help="Raw event dump instead of classification. Use with --filter and --role.")
    parser.add_argument("--context", type=int, default=None, metavar="LINE",
                        help="Show events around LINE (default window: 10). Use --window to adjust.")
    parser.add_argument("--window", type=int, default=10,
                        help="Number of lines before/after for --context (default: 10)")
    parser.add_argument("--filter", type=str, default=None,
                        help="Text filter for --dump mode (case-insensitive substring match)")
    parser.add_argument("--role", type=str, default=None,
                        help="Role filter for --dump mode (comma-separated: user,assistant)")
    args = parser.parse_args()

    path = find_session(args.session_id, args.project_hint)
    if not path:
        print(json.dumps({"error": f"Session {args.session_id} not found"}), file=sys.stderr)
        sys.exit(1)

    # Context mode: show events around a specific line
    if args.context is not None:
        context_around(path, args.context, args.window)
        return

    # Dump mode: raw event stream, no classification
    if args.dump:
        dump_events(path, args.from_line, args.to_line,
                    text_filter=args.filter, roles=args.role)
        return

    print(json.dumps({"status": "started", "session": str(path), "from_line": args.from_line}),
          flush=True)

    if args.watch:
        issues, last_line = watch(path, args.from_line, args.poll_interval, args.timeout,
                                  output_file=args.output,
                                  details_file=args.details_file)
    else:
        issues, last_line = scan(path, args.from_line)

    # Apply filters
    sev_order = {"low": 0, "medium": 1, "critical": 2}
    if args.severity:
        min_sev = sev_order.get(args.severity, 0)
        issues = [i for i in issues if sev_order.get(i.severity, 0) >= min_sev]
    if args.category:
        cats = set(c.strip() for c in args.category.split(","))
        issues = [i for i in issues if i.category in cats]
    if args.exclude:
        excl = set(c.strip() for c in args.exclude.split(","))
        issues = [i for i in issues if i.category not in excl]
    if args.fixable:
        issues = [i for i in issues if i.fixable]

    # Write full untruncated details to a separate file if requested
    if args.details_file and issues:
        with open(args.details_file, "w") as df:
            for issue in issues:
                df.write(json.dumps(asdict(issue)) + "\n")

    # Output (truncated for readability)
    if not args.watch:
        if args.json:
            for issue in issues:
                d = asdict(issue)
                d["details"] = d["details"][:500]
                print(json.dumps(d))
        else:
            for issue in issues:
                sev = issue.severity.upper()
                print(f"[{sev}] L{issue.line} ({issue.category}): {issue.summary}")
                if issue.fix_target:
                    print(f"  fix: {issue.fix_target}")
                if issue.fix_hint:
                    print(f"  hint: {issue.fix_hint}")

    if args.summary:
        by_sev = {}
        by_cat = {}
        for issue in issues:
            by_sev[issue.severity] = by_sev.get(issue.severity, 0) + 1
            by_cat[issue.category] = by_cat.get(issue.category, 0) + 1
        print(json.dumps({
            "status": "done",
            "last_line": last_line,
            "total_issues": len(issues),
            "by_severity": by_sev,
            "by_category": by_cat,
        }))


if __name__ == "__main__":
    main()
