# Confirmation matrix

This document fixes the confirmation rule for every Reviews intent. Drift
on this matrix changes user-facing safety guarantees, so the table is the
contract — new intents pick a row, they do not invent a new rule.

| Intent | Confirmation |
|---|---|
| `OpenPullRequestIntent` | none — navigational, opens the app |
| `OpenReviewsNeedsMeIntent` | none — navigational, opens the app |
| `GetNeedsMeCountIntent` | none — read-only |
| `SearchPullRequestsIntent` | none — read-only |
| `RefreshRepositoryIntent` | none — read-only side effects (server cache) |
| `RefreshAllReposIntent` | none — read-only side effects (server cache) |
| `AddLabelToPullRequestIntent` | none — idempotent on GitHub side |
| `RerunChecksIntent` | none — re-triggering CI is cheap and reversible |
| `ApprovePullRequestIntent` | **yes** — `requestConfirmation` with PR title |
| `MergePullRequestIntent` | **yes** — `requestConfirmation` with PR title + merge method |

When adding a Task Board mutating intent, follow the same shape: any
operation that lands code, dispatches a job, or sends a message goes
through `requestConfirmation`. Anything that re-fetches state, toggles a
local cache, or surfaces a URL does not.

The dialog string passed to `requestConfirmation` should name the target
in the same language a human would use ("Approve \(title)?"), not in the
language a robot would use ("Are you sure you want to confirm the
approval action?"). Confirmations look identical to system Shortcuts
prompts, so the wording is what the user reads.
