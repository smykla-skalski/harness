# GitHub Task Issue Guidelines

## Small-task quality bar

Publish one issue only when the work is small enough to stay coherent and finishable without becoming an umbrella ticket.

- Keep one primary problem or one primary outcome per issue.
- Keep the issue scoped to one code area or one tightly related behavior.
- Prefer one clear implementation path over a grab bag of ideas.
- If the title naturally needs an "and", reconsider whether the work should be split.
- If the issue body needs separate phases, multiple owners, or unrelated acceptance criteria, split it.

In this repository, check `.github/ISSUE_TEMPLATE/bug_report.yml` and `CONTRIBUTING.md` before finalizing the draft. Reuse the existing bug shape and label conventions when the issue is clearly a bug.

## Draft template

Use this structure unless the repository already has a more specific template for the issue type:

```md
## Summary
One short paragraph explaining the task and why it matters.

## Problem
Describe the current behavior, gap, or maintenance problem.

## Scope
- State what should change.
- Keep the list tight.

## Acceptance criteria
- Write observable, testable outcomes.
- Use backticks for commands, flags, file paths, symbols, and config keys.

## Evidence
- Link to files, commands, logs, PRs, issue templates, or other repo context.

## Screenshots
One sentence before each screenshot explaining what the reader should see.

## Out of scope
- Name nearby work that should not be pulled into this task.
```

## Title rules

- Use the same semantic title format as repo commit and PR titles from `CONTRIBUTING.md`: `type(scope): description`.
- Scope is mandatory and must stay lowercase. Use a narrow path-like scope such as `workflow/create`, `monitor/preferences`, or `hooks/tool-result`.
- Use one of these types: `feat`, `fix`, `docs`, `style`, `refactor`, `test`, `chore`, `ci`, `build`, `perf`.
- Lead the description with the concrete result, not a vague aspiration.
- Avoid fluff, hype, and roadmap language.
- Prefer concise titles that a reviewer can classify quickly.

Good patterns:

- ``fix(workflow/create): preserve proposal validation errors in summary``
- ``fix(monitor/preferences): keep launch-agent removal behind confirmation``
- ``fix(hooks/tool-result): report failing post-tool audits with command context``

Bad patterns:

- ``workflow/create: preserve proposal validation errors in summary`` - missing semantic type and scoped parentheses
- ``fix: preserve proposal validation errors in summary`` - missing mandatory scope
- ``feat(test): add helper`` - wrong type for test-only work

## Screenshot rules

- Use screenshots only when they help explain the issue faster than prose alone.
- Put each screenshot next to the section it supports.
- Add alt text that describes the visible state, not just "screenshot".
- Do not leave local file paths in the body. For local files, run `scripts/upload-image.sh <file>...` and embed the returned markdown so the body contains real GitHub-hosted image URLs.
- Verify the screenshot still loads on the rendered issue page after creation.

## Humanize requirement

The issue body must go through an explicit `humanize` skill invocation before publication.

- Save the draft to a file.
- In Codex, run `$humanize <draft-path>` on that file.
- In slash-command runtimes, run `/humanize <draft-path>` on that file.
- Manual cleanup or a claim that the text was "already humanized" does not count.
- Re-check the result for technical accuracy after the rewrite.
- Save the title to a second file and validate it with `scripts/publish-issue.py validate-title --title-file ...` before approval or publication.
- Save the render checklist to a second file with one expected code term per line.

## Approval contract

Use an AskUserQuestion-style gate when the runtime supports it.

- Option 1: `Create issue`
  Publish the current draft as-is.
- Option 2: `Request changes`
  Do not publish. Ask the user what should be changed or added.

If the runtime does not provide `AskUserQuestion`, stop and ask the user directly in the same two-step shape before publishing.

## Render checklist

Keep a short private checklist of the terms that must render as code on the final page.

Typical render targets:

- commands such as `mise run check`
- file paths such as `src/workflow/create.rs`
- binary names such as `gh`
- flags such as `--json`
- hook names such as `tool-guard`

After the issue is created, verify the rendered page:

- the title still matches the approved title and passes semantic validation
- screenshots are visible
- render targets appear as inline code or fenced code
- raw backticks are not visible around those terms
- lists, checkboxes, and links render correctly

Use `scripts/verify-issue-render.py --issue ... --expected-title-file ... --body-file ... --expected-code-file ...` for this check. If it fails, patch the live issue body and run it again.
