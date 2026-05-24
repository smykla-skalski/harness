# Confirmation matrix

This document fixes the confirmation rule for every intent. Drift on this matrix changes user-facing safety guarantees, so the table is the contract - new intents pick a row, they do not invent a new rule.

| Intent | Confirmation |
|---|---|
| `OpenPullRequestIntent` | none - navigational, opens the app |
| `OpenReviewsNeedsMeIntent` | none - navigational, opens the app |
| `OpenTaskBoardIntent` | none - navigational, opens the app |
| `GetNeedsMeCountIntent` | none - read-only |
| `SearchPullRequestsIntent` | none - read-only |
| `ListTaskBoardItemsIntent` | none - read-only |
| `RefreshRepositoryIntent` | none - read-only side effects (server cache) |
| `RefreshAllReposIntent` | none - read-only side effects (server cache) |
| `AddLabelToPullRequestIntent` | none - idempotent on GitHub side |
| `RerunChecksIntent` | none - re-triggering CI is cheap and reversible |
| `ApprovePullRequestIntent` | **yes** - `requestConfirmation` with PR title |
| `MergePullRequestIntent` | **yes** - `requestConfirmation` with PR title + merge method |
| `DispatchTaskIntent` | **yes** - `requestConfirmation` before running a Task Board item |
| `ApproveTaskBoardPlanIntent` | **yes** - `requestConfirmation` before approving a plan |
| `PerformReviewActionIntent` | **depends on action** - approve and merge confirm (same wording as the specific intents); rerun checks and add label skip confirmation. The parametric intent inherits the per-verb rule from the row above so the safety guarantee stays identical regardless of which entry point the user picks |

When adding any mutating intent, follow the same shape: any operation that lands code, dispatches a job, sends a message, or commits to an external system goes through `requestConfirmation`. Anything that re-fetches state, toggles a local cache, or surfaces a URL does not.

The dialog string passed to `requestConfirmation` should name the target in the same language a human would use ("Approve \(title)?"), not in the language a robot would use ("Are you sure you want to confirm the approval action?"). Confirmations look identical to system Shortcuts prompts, so the wording is what the user reads.
