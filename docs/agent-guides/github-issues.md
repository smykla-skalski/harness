# GitHub issues

How to write and file issues in this repo. An issue is a contract between whoever understands the problem and whoever will change the code. It has to be complete enough that the implementer never needs to interrupt the author, and specific enough that "done" is verifiable by someone who was not in the room.

Research the codebase thoroughly before drafting, then keep almost all of that research out of the issue. Knowing the internals is what makes the scope and the slicing right; writing them down is what makes the issue rot.

## Title

Use `type(scope): summary` with the same types as commits: `feat`, `fix`, `refactor`, `chore`, `docs`, `style`, `test`, or `perf`. Keep it imperative and under 70 characters. PRs squash-merge, so an issue title routinely becomes the commit title on `main`.

Umbrella issues prefix the title with `☂️ `, for example `☂️ feat(monitor): connect to multiple daemons at once`. Children carry no emoji, so the umbrella is the only entry that stands out in a list view.

## Body

Three sections at most for an ordinary issue. Bug reports swap the second section for three of their own, set out below. An umbrella keeps the ordinary body and adds no section of its own; it links its children as native sub-issues instead.

`## Problem` comes first: two to four sentences of prose, active voice, present tense. State the user-visible impact and why it matters. No solution belongs in this section. If the reader cannot tell what goes wrong today, the issue is not ready.

`## Expected outcome` comes second: three to six bullets, every one testable by someone who never read the issue, describing observable behavior only. "Tab moves focus in reading order in every view" passes. "Call `.focusSection()` in the sidebar" does not. Prefer outcomes that name the failure they prevent, since those survive a rewrite of the implementation.

`## Out of scope` comes third, and only when scope drift is genuinely likely. Otherwise cut it. Use it to record adjacent work that a reader would reasonably assume is included, and to point at the issue that does cover it.

Target under 200 words. A draft that needs more is more than one issue.

## Bug reports

Bugs replace `## Expected outcome` with three sections: `## Steps to reproduce` as a numbered list, `## Expected behavior`, and `## Actual behavior`. A bug without a reproduction is a research task and should be titled as one.

## Umbrellas and children

Use an umbrella when a goal needs several issues that each stand alone. Three or more children justifies one; two is a dependency, not a group, and an umbrella over it is ceremony.

The umbrella body follows the same three sections and adds no child-issue section. Attach each child as a native GitHub sub-issue instead: GitHub then renders the child list, its progress, and a two-way link on both issues, so a hand-written checklist only duplicates state that goes stale. Each child must be independently valuable and reviewable on its own.

A child does not name its umbrella in its body, because the sub-issue link already shows that relationship on both sides. Issues that depend on each other without an umbrella still use `Depends on #<issue>`, which GitHub does not model natively.

Create the umbrella and children first, read the child numbers back from the create output, then attach each child in the order it needs to land, since GitHub preserves that order. The attach endpoint keys on the child's database id rather than its issue number:

```bash
gh api --method POST repos/<owner>/<repo>/issues/<umbrella-number>/sub_issues \
  -F sub_issue_id="$(gh api repos/<owner>/<repo>/issues/<child-number> --jq '.id')"
```

## What never goes in an issue

- File paths, type names, function names, line numbers
- Checklists that enumerate the implementation
- Instructions to run a particular skill, command, or review workflow
- Anything the implementer can read from the repo themselves
- The same point restated in a second section

These read as helpful and are not. They tell the implementer what to type instead of what to achieve, remove their ability to find a better approach, and go stale the moment something is renamed.

## Language

Write plainly. Active voice, positive form, concrete over abstract, and no needless words. One idea per bullet. Bullets take no trailing period; prose sentences do. Use straight quotes, sentence case headings, and regular hyphens rather than em dashes.

Avoid the vocabulary that signals generated text: `crucial`, `key` as an adjective, `pivotal`, `seamless`, `robust`, `leverage`, `enhance`, `underscore`, `showcase`, `delve`, `landscape` and `tapestry` used abstractly. Avoid inline-header bullets of the form `**Header:** description`, forced groups of three, and significance inflation such as "marks a shift" or "serves as a testament".

Name the same thing the same way every time. Synonym cycling makes an issue read as though it covers more ground than it does.

## Before and after filing

Confirm scope forks with the user before filing when the answer would change which issues exist, how the work slices, or what the model is. Do not confirm choices that have an obvious default; take the default and say so.

Apply `kind/enhancement` or `kind/bug` to every issue. Add `area/api` when the change alters a contract between the daemon and its clients, including the wire protocol, the command line, and the tool interfaces.

Read created issue numbers back from the command output rather than assuming them, and verify the umbrella's sub-issues list after attaching the children.
