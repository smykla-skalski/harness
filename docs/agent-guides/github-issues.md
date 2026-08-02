# GitHub issues

How to write and file issues in this repo. An issue is a contract between whoever understands the problem and whoever will change the code. It has to be complete enough that the implementer never needs to interrupt the author, and specific enough that "done" is verifiable by someone who was not in the room.

The implementer is often an autonomous agent that cannot ask a follow-up question and may pick up a child issue with no memory of its siblings. Precision about outcomes and honesty about degrees of freedom matter more here than between two people who can talk.

Research the codebase thoroughly before drafting, then keep almost all of that research out of the issue. Knowing the internals makes the scope and the slicing right. Writing it down makes the issue rot.

PR titles and PR bodies follow `docs/agent-guides/delivery-workflows.md`, not this file.

## Contents

- Title
- Rewriting an off-format title
- Body
- Cover the states the change actually meets
- Guard what already works
- Mark what is fixed and what is free
- The one thing the repo cannot tell them
- Bug reports
- Repository templates
- Splitting work
- Slice vertically, never by layer
- Where to cut
- Order and dependencies
- The post-split check
- Umbrellas and children
- Issue types
- What never goes in an issue
- Length and the readiness gate
- Language
- Improving an existing issue
- Before and after filing

## Title

Use `type(scope): summary` with the same types as commits: `feat`, `fix`, `refactor`, `chore`, `docs`, `style`, `test`, or `perf`. Keep it imperative and present tense, lowercase after the colon, no trailing period, under 70 characters. PRs squash-merge, so an issue title routinely becomes the commit title on `main`.

Name a user-visible capability or a concrete defect and its symptom, not a layer or a bare noun. "feat(monitor): reconnect after the daemon restarts" is a title. "feat(monitor): backend work" names no outcome and "fix(monitor): daemon bug" names no symptom, so neither is one. Lead with the verb and object so the title survives truncation in a list view. Prefer a verb for the observable result (add, remove, stop, prevent, allow) over a layer verb like update, improve, handle, or refactor.

One deliverable per title. A summary that needs "and", "or", or a joining comma is two issues. Resolve the split before writing either body.

Pick the type from the change class, not the diff size or the file extension. `feat` adds a capability a caller could not invoke before, `fix` corrects wrong or broken behavior, `refactor` changes structure with identical observable behavior, `perf` makes correct behavior faster against a metric you can name. Wrong output is `fix`, not `perf`. An unnamed metric means `refactor`, not `perf`. A file that ships as product behavior takes `feat` or `fix` whatever its extension, so a skill or a generated config the runtime consumes is not `docs`.

Use a scope the repo already names, and prefer the narrowest true one. Coin a scope only when nothing fits and the area is durable enough to reuse: one lowercase noun naming a real directory or subsystem, never the kind of change and never filler such as misc, core, logic, or general. If no real area fits, drop the parens and write `type: summary`. Flag any coined scope to the user before filing, since it hardens into a token across future issues and commits.

Umbrella issues prefix the title with `☂️ `, for example `☂️ feat(monitor): connect to multiple daemons at once`. Children carry no emoji, so the umbrella is the only entry that stands out in a list view.

### Rewriting an off-format title

1. State the single deliverable in one sentence. If you cannot, the title is compound, so split it before rewriting anything.
2. Set the type from the change class, not from the old type.
3. Take the scope from the real area touched and reuse the exact token the repo already uses, so the issue and its squash commit share one string.
4. Rewrite the summary as an imperative naming the observable outcome, or the concrete defect and its symptom.
5. Strip a leaked type word, remove a trailing period, lowercase the first word after the colon, and cut adjectives the scope already implies until the line fits the budget.
6. Re-read the rewrite against the original: nothing narrowed, nothing broadened, no second deliverable smuggled back in.

## Body

Three sections at most for an ordinary issue. Bug reports swap the second section for three of their own, set out below. An umbrella keeps the ordinary body and adds no section of its own. It links its children as native sub-issues instead.

`## Problem` comes first: two to four sentences of prose, active voice, present tense. State the user-visible impact and why it matters. No solution belongs in this section, because the moment a proposed fix lands there the implementer stops looking for a better one. If the reader cannot tell what goes wrong today, the issue is not ready.

`## Expected outcome` comes second: three to six bullets, every one testable by someone who never read the issue, describing observable behavior only. "Tab moves focus in reading order in every view" passes. "Call `.focusSection()` in the sidebar" does not, because it names a mechanism rather than a result. Give each bullet one named observation that tells pass from fail. If you cannot say what you would look at to check it, the bullet is not testable yet. Quantify every quality word, since "fast", "simple", "reliable", and "secure" are not outcomes until they carry a threshold and a way to read it. Prefer outcomes that name the failure they prevent, since those survive a rewrite of the implementation.

`## Out of scope` comes third, and only when scope drift is genuinely likely. Otherwise cut it. Use it to record adjacent work a reader would reasonably assume is included, and to point at the issue that does cover it.

### Cover the states the change actually meets

A feature issue most often underspecifies by listing only the happy path. The implementer then builds only that, reports done, and the empty view and the error toast surface later.

Before the outcome list is final, walk the states the change will really hit and add an outcome for each:

- Empty or first run: no data yet, nothing selected, no daemon reachable
- Boundary: zero, one, the maximum, one past the maximum, duplicates
- Invalid or unauthorized input: bad values, missing permission, malformed request
- Each failure the change can raise, stated as what the user or caller sees

Leave out a state that genuinely cannot occur, never one that was inconvenient to write. If the real states need more than six bullets, the issue is more than one issue.

### Guard what already works

Every outcome describes new behavior, so nothing tells the implementer what must stay unchanged. When the change sits next to working behavior a plausible implementation could break, add one outcome asserting it still holds: "existing X still does Y". An agent optimizing only the stated target otherwise trades away an invariant nobody wrote down.

### Mark what is fixed and what is free

A flat list reads as either all-mandatory or all-optional, so the implementer gold-plates a nice-to-have or drops a blocker. When some outcomes are hard requirements and others are defaults a better idea may override, say which in a few words.

### The one thing the repo cannot tell them

Keep repo-derivable research out, because it rots. One class of context is the exception, since the implementer cannot re-derive it by reading the code: an approach already tried and rejected and why, an external constraint or quirk, a coupling that will bite. When such a fact would change how the work is done, put one or two sentences of it in `## Problem` or a short note, and cap it hard so it never becomes a research dump.

Add one line when a decision inside the issue is a one-way door, such as a published version, a wire contract, or a public interface, and tell the implementer to stop and ask rather than guess.

## Bug reports

Bugs keep `## Problem` and replace `## Expected outcome` with three sections: `## Steps to reproduce` as a numbered list, `## Expected behavior`, and `## Actual behavior`.

Start the steps from a clean, named state so they reproduce on a machine not already set up like the reporter's. Record the environment when it is relevant, and say whether this ever worked, since a regression and a never-worked bug send the implementer to different places. When the input does not supply a detail the report needs, ask rather than guess or quietly drop it, because a fabricated repro step sends the implementer down the wrong path. A bug without a reproduction is a research task and should be titled and scoped as one.

`.github/ISSUE_TEMPLATE/bug_report.yml` is a GitHub issue form, so it is a hard contract for bugs filed through it: Description, Steps to Reproduce, Expected Behavior, Actual Behavior, and Environment are all required. Fill every required field to the quality bar above. When a required value is not in the input, do not invent it and do not leave it blank. Put a visible placeholder there, list it as an open item, and hold filing until the user supplies it.

## Repository templates

A template the repo ships wins over the structure in this file wherever the two overlap: its sections, field names, ordering, required headings, and any label or type it sets. Do not replace them with `## Problem` and `## Expected outcome`.

This file still governs everything the template does not fix: observable and testable outcomes, state coverage, no solution in the problem field, the title rules, the splitting rules, and the language rules. A template shapes a single issue and never decides how many issues the work is.

## Splitting work

Split when any of these is true, not when the prose got long:

- The goal has an "and" or an "or" naming two capabilities
- The outcomes are uncountable, or run well past six
- The work mixes concerns, or mixes a feature with a cross-cutting quality change
- An embedded unknown would have to be researched before the work could be estimated
- The change would not fit one reviewable diff

Length is a hint. A two-line issue can hide enormous work, and a long single issue should stay whole.

### Slice vertically, never by layer

Each child delivers one observable behavior through every layer that behavior touches. It does not deliver one layer serving many behaviors. A child named for a layer or a step, such as "add the daemon route", "write the tests", or "build the view", is the usual bad cut: each reads as reviewable in isolation, yet none ships on its own, and the value and integration risk pile onto whichever child lands last.

One question catches it before filing: the moment this child merges, can a user or an operator do or see something they could not before? If the answer is no, re-slice it. A later child is often picked up by a fresh agent, so every child has to leave `main` releasable on its own.

### Where to cut

Reach for these in order, and take the first that yields two genuinely valuable halves.

- Spike: the work is unestimable because of an unknown, so split off a timeboxed research issue first
- Path: ship the main path through a workflow, defer alternate and error paths
- Interface: one entry point at a time, each end to end, such as the CLI before the Monitor
- Data: handle one data type, format, or source first, then the next
- Rules: ship the simple rule set, add the elaborate cases later

When none of those fit, try one of these:

- Split create, read, update, and delete into separate issues
- Ship a thin end-to-end version of a multi-step flow, then deepen individual steps
- Do the simple variant now and the hard one later
- Make it correct first and fast in a following issue, with its own metric

A spike produces knowledge rather than shipped behavior. Timebox it, title and scope it as research, expect to throw its code away, and make its outcome a decision that renders the real issues estimable.

### Order and dependencies

Sequence the thinnest end-to-end slice first, the one that exercises every layer shallowly, so integration risk is retired at the start. Order the rest so `main` stays releasable after each child merges, and where dependencies leave a choice, land the child that retires the most risk rather than the one that is easiest to write. Dependency is the hard constraint and risk is the tiebreaker within it.

Challenge a dependency before recording it. Most "A before B" orderings are artifacts of a horizontal cut, and a false dependency freezes a bad cut into the issue graph. The walking skeleton is the legitimate case, because its siblings genuinely extend the thin path it lays down. The test is whether the thing depended on ships user-visible value on its own.

### The post-split check

A split is real only when both halves come out smaller and each still stands alone. One real child plus a trivial leftover means the seam was wrong: the work was relabeled, not divided.

Each child must also be self-contained. If a child needs a decision or a constraint recorded only in the umbrella, inline that one fact in the child, because an implementer frequently starts from the child alone.

## Umbrellas and children

Use an umbrella when a goal needs three or more issues that each stand alone. Two is a dependency, not a group, and an umbrella over it is ceremony. Record that pair as a native blocked-by relationship instead.

The umbrella body follows the same three sections and adds no child-issue section. Its outcomes describe the capability as a whole and never enumerate the children one by one. Attach each child as a native GitHub sub-issue, so GitHub renders the child list, its progress, and a two-way link on both issues. A hand-written checklist only duplicates state that goes stale. A child does not name its umbrella in prose, because the sub-issue link already shows that on both sides.

Set every relationship natively, and set it at creation rather than in a second pass. Create the umbrella first, read its number back from the output, then create each child already carrying its parent link and its real dependencies, in the order the children need to land, since GitHub preserves that order. This assumes `gh` 2.94 or newer (`gh --version`) and a clean checkout. Each command is one create, so a rerun files a duplicate rather than updating anything.

```bash
gh issue create --repo smykla-skalski/harness --title "<umbrella title>" --body-file <tmp>              # note the number, e.g. 100
gh issue create --repo smykla-skalski/harness --title "<skeleton child>" --body-file <tmp> --parent 100 # e.g. 101
gh issue create --repo smykla-skalski/harness --title "<dependent child>" --body-file <tmp> --parent 100 --blocked-by 101
```

`--parent` takes one issue number or URL. `--blocked-by` and `--blocking` take a comma-separated list. For issues that already exist, relate them with `gh issue edit --parent`, `--add-sub-issue`, `--add-blocked-by`, `--add-blocking`, and the matching `--remove-*` flags.

On a `gh` older than 2.94, attach through the REST API and record dependencies as `Depends on #<issue>` prose, which the old CLI cannot set natively. The attach endpoint keys on the child's database id rather than its issue number:

```bash
gh api --method POST repos/smykla-skalski/harness/issues/<umbrella-number>/sub_issues \
  -F sub_issue_id="$(gh api repos/smykla-skalski/harness/issues/<child-number> --jq '.id')"
```

## Issue types

GitHub's issue type field is separate from the `kind/*` label and sits alongside it. Set it after filing:

- Any issue labeled `kind/bug` gets type `Bug`, overriding the rules below even on an umbrella or one of its sub-issues.
- Otherwise, a sub-issue attached to an umbrella gets type `Task`.
- Otherwise, an umbrella whose children are new work gets type `Feature`. Type `Feature` is reserved for umbrellas. A standalone issue that is neither a bug nor a sub-issue gets no type.

Set it with `gh issue create --type <name>` or `gh issue edit <number> --type <name>`.

## What never goes in an issue

- File paths, type names, function names, line numbers
- Checklists that enumerate the implementation
- Instructions to run a particular skill, command, or review workflow
- Anything the implementer can read from the repo themselves
- The same point restated in a second section

These read as helpful and are not. They tell the implementer what to type instead of what to achieve, remove their ability to find a better approach, and go stale the moment something is renamed. A pointer to a starting seam or a prior similar change is allowed as a reference, never as pasted content, and only when it saves a real search.

The bug variant is the exception. `## Steps to reproduce` must name the concrete commands, paths, flags, and inputs the reader runs, because a reproduction that omits them does not reproduce. The ban covers prescribing the implementation, not describing how to hit the bug.

## Length and the readiness gate

Target under 200 words. A draft that needs more is usually more than one issue, so treat overflow as a split signal rather than a formatting problem, and check it against the split tells above.

Before filing, run one gate: could someone who never spoke to the author build this and know when they are done, from the issue alone? If not, the missing piece is an unstated outcome or an unstated constraint. Add that, not prose.

## Language

Every issue body and comment goes through a writing pass before it is shown. Where the `writing-clearly-and-concisely` and `humanize` skills are installed, run them on the draft as the final pass, `humanize` last. Otherwise the rules below are the pass.

Keep each paragraph and each bullet on one physical line, however long it gets, since a wrapped paragraph turns a one-word edit into a multi-line diff. Blank lines separate blocks, and code blocks, tables, and numbered steps keep their own structure.

Write plainly. Active voice, positive form, concrete over abstract, and no needless words. One idea per bullet, so a bullet whose "and" joins two outcomes is two bullets. Put the strongest word at the end of a sentence and end a paragraph on its strongest point. Vary sentence length when three in a row share a shape. Bullets take no trailing period. Prose sentences do. Use straight quotes, sentence case headings, and regular hyphens. No em dashes and no semicolons, since two sentences read clearer than either.

Avoid the vocabulary that signals generated text: `additionally`, `crucial`, `delve`, `enhance`, `furthermore`, `key` as an adjective, `landscape` and `tapestry` used abstractly, `leverage`, `moreover`, `pivotal`, `robust`, `seamless`, `showcase`, `testament`, `underscore`, `valuable`. Cut `in order to` to `to` and `due to the fact that` to `because`.

Avoid these patterns: inline-header bullets of the form `**Header:** description`, negative parallelism such as "not only X but also Y", hedging stacks such as "could potentially possibly", forced groups of three, mechanical boldface on proper nouns and acronyms, decorative emoji, and significance inflation such as "marks a shift" or "serves as a testament".

Name the same thing the same way every time. Synonym cycling makes an issue read as though it covers more ground than it does.

The writing pass changes how the text reads, never what it claims. Do not add a fact the source did not contain, and do not soften a technical statement into vagueness for the sake of flow.

## Improving an existing issue

Fetch the real text before editing it, rather than working from a guess:

```bash
gh issue view <number-or-url> --json number,title,body,labels,state,url
```

Diagnose in three passes. Splitting first, because it changes everything downstream: when the issue is oversized by the tells above, propose the slice set before touching a line. The title second, fixed even when the body is fine. The body last: is the problem stated without a solution, are the outcomes observable and testable, are the edge and error states covered, is anything in there that should not be? Keep the issue's real intent and never invent scope the original did not have.

## Before and after filing

Confirm scope forks with the user before filing when the answer would change which issues exist, how the work slices, or what the model is. Do not confirm choices that have an obvious default. Take the default and say so.

Show the full draft and get an explicit go-ahead before any create, edit, or comment. Pass `--repo smykla-skalski/harness` on every mutating call, since without it the call runs against whatever repo the shell sits in. Pass the body with `--body-file <tmp>` rather than inline, so shell escaping cannot mangle the markdown or the one-line-per-paragraph rule.

Apply `kind/enhancement` or `kind/bug` to every issue. Add `area/api` when the change alters a contract between the daemon and its clients, including the wire protocol, the command line, and the tool interfaces.

Read created issue numbers and URLs back from the command output rather than assuming them, and verify the umbrella shows its sub-issues and that the blocks landed before reporting a split done.
