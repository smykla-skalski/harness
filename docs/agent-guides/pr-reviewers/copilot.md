# Copilot reviewer variant

The `copilot` variant of the `pr with review` mode. `../delivery-workflows.md` owns mode selection, the loop, the ready gate, and closeout. This file answers only the five questions a variant has to answer, and changes nothing else about the mode.

## Contents

- Request
- Read the findings
- Triage
- Clean pass
- Escalate

## Request

Request Copilot immediately after the first push, and use the same command for every re-request:

```bash
gh api --method POST repos/smykla-skalski/harness/pulls/<PR_NUMBER>/requested_reviewers -f 'reviewers[]=copilot-pull-request-reviewer[bot]'
```

## Read the findings

A Copilot review arrives in two halves and the loop needs both. These are read-only and safe to rerun at any point:

```bash
gh api --paginate repos/smykla-skalski/harness/pulls/<PR_NUMBER>/reviews --jq '.[] | select(.user.id == 175728472) | {commit: .commit_id, state: .state, body: .body}'
gh api --paginate repos/smykla-skalski/harness/pulls/<PR_NUMBER>/comments --jq '.[] | {user: .user.login, path, line, original_line, body}'
```

Keep `--paginate` on both. `gh api` returns only the first page otherwise, so a PR that accumulates more than thirty reviews or inline comments over a long loop starts hiding its older ones behind a result that still looks complete.

Keep the author and both line fields on the comments query. That endpoint returns human, Copilot, and other bot comments in one list, so dropping `.user.login` leaves each finding unattributable, and a comment the branch has moved past reports `line: null` while its position survives only in `original_line`.

Select the reviewer by numeric id rather than by name, because this bot's login is not stable across endpoints. `reviews[].user.login` calls it `copilot-pull-request-reviewer[bot]`, while `requested_reviewers`, `comments[].user.login`, and the users API all call it `Copilot`. A filter written from the name one endpoint showed then matches nothing on another and reads as a review that never arrived, which is the same silence as a review that has not run yet. The id is identical everywhere and also keeps other bot reviewers, such as `smyklot[bot]`, out of the result. Treat `175728472` as current rather than permanent, and re-derive it whenever a filter that should match comes back empty:

```bash
gh api 'users/copilot-pull-request-reviewer%5Bbot%5D' --jq '.id'
```

## Triage

Read the review body as well as the inline comments, because the two carry different findings. Copilot withholds anything it is unsure of from the inline threads and collects it in a collapsed `Comments suppressed due to low confidence (N)` block in the body instead, where each entry is a `**<path>:<line>**` heading followed by the finding. Those entries never appear in the review-comments API, so a run that only counts inline threads reads a review that raised real defects as a clean one.

Triage every suppressed finding exactly as you would a posted one, and never treat the block as advisory. Low confidence describes how sure Copilot is that the remark belongs in review, not how small the defect is, and genuine correctness bugs land there. Confirm or refute each entry against the code, fix what is real, and answer what is wrong.

A suppressed finding has no thread to resolve, so answer a wrong one in a single PR comment that names its file and line and gives the same evidence. Fixing a real one needs no reply, because the pushed commit is the record.

## Clean pass

Copilot reviewed the current tree, posted no new comments, and either raised no suppressed findings or raised only ones this loop already fixed or answered.

Read that from the review count and Copilot's own comment count, never from the unresolved-conversation count. Resolving is an action the agent performs, so a zero unresolved count evidences its own work rather than the reviewer's verdict. A genuine pass means the review count went up and the new review added no comments.

A re-request can also answer with a placeholder before the real review lands: `state: COMMENTED` with an empty `body`, roughly a minute ahead of the analysis. Require a non-empty body carrying a real summary. This reads the reviewer's own run, not repository CI, so it does not conflict with the rule against waiting on status checks.

## Escalate

Escalate a request that keeps failing, a review that never arrives for the current tree, or a finding that recurs after this loop already fixed or answered it. Keep the PR a draft while blocked. Retry an ordinary transient API error instead of escalating it.
