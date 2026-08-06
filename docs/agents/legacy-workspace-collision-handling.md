# Legacy Workspace Collision Handling

This document defines the migration contract for replacing Session-owned orchestration with one durable workspace owner per daemon, project, and checkout. It is a design and operator-safety contract; it does not introduce the replacement schema or authorize a migration.

The migration must preserve every legacy record, identify conflicts before mutation, and remain safe to retry after interruption. When the available evidence cannot prove a lossless mapping, the migration stops and leaves the legacy owner authoritative.

## Identity

A durable workspace is identified by this tuple:

```text
(daemon_id, project_scope_id, checkout_id)
```

- `daemon_id` is the daemon's stable identity. It scopes ownership; it is not an app launch identifier.
- `project_scope_id` is the canonical repository identity used to group checkouts of the same repository. For a non-Git directory, it is the canonical project identity.
- `checkout_id` is the canonical identity of the concrete checkout or worktree. Parallel worktrees of one repository must have different values.

Canonical identity comes from persisted project discovery metadata and recorded project origin, using the same path normalization and repository discovery rules as the daemon. Display names, worktree names, branch names, filesystem paths, legacy Session IDs, and provider runtime Session IDs are evidence or correlation metadata, never workspace identity.

The migration must not recompute a different identity from whichever path happens to exist at migration time. If current discovery and recorded provenance disagree after canonicalization, the candidate is malformed.

## Candidate model

Each legacy Session associated with a workspace key is a candidate. Classification has four independent dimensions so that loss of one kind of evidence does not erase another:

| Dimension | Values | Meaning |
| --- | --- | --- |
| Lifecycle | `active`, `stale`, `ended` | Whether the candidate owns live work after read-only liveness evaluation |
| Validity | `valid`, `malformed` | Whether its identity, state, and owned records can be parsed and mapped consistently |
| Checkout | `available`, `missing-worktree` | Whether the checkout currently exists and resolves to the recorded identity |
| Scope | `local`, `cross-daemon` | Whether the candidate belongs to the daemon performing the migration |

These values are not interchangeable. For example, a candidate can be `active`, `valid`, `missing-worktree`, and `local`. Operator reports must include all four dimensions rather than collapsing them into one status.

### Active

A candidate is active when at least one of these conditions remains true after evaluating the daemon's current liveness rules against a read-only snapshot:

- an agent status is `active`, `idle`, or `awaiting_review` after reconciliation;
- a managed agent or terminal has a non-terminal runtime state such as starting or running;
- a managed run or turn is queued, running, or waiting for approval;
- a pending signal or review obligation keeps an otherwise quiet agent alive under current liveness policy.

The evaluator must use the production runtime adapter and liveness policy without persisting their transitions. It must preserve the production exceptions for agents awaiting review and managed agents whose lifecycle is not timer-driven. A timestamp threshold by itself is never enough to declare a candidate stale.

If runtime state cannot be inspected, the migration must fail safe: a candidate whose persisted state claims live work remains active and the inspection failure becomes a blocker. Unknown runtime state must never be converted into stale state.

### Stale

A candidate is stale when it is not ended and the read-only liveness evaluation proves that it has no live agent, managed runtime, active run or turn, pending signal, or outstanding review obligation.

Paused, awaiting-leader, leaderless, disconnected, and idle-looking Sessions are not automatically stale. Their owned records and runtime evidence still decide the classification. Creation, update, and activity timestamps may rank stale candidates only after liveness has been decided.

### Ended

A candidate is ended when its Session status is `ended` and read-only inspection finds no non-terminal agent, runtime, run, turn, signal, or review obligation. It contributes history but cannot supply a live team owner.

`archived_at` is visibility and retention metadata, not a lifecycle classifier. The migration preserves it exactly. An ended Session with live runtime evidence is malformed, and collision handling must not repair the contradiction.

### Malformed

A candidate is malformed when any required source cannot be parsed, its schema version is unsupported, its identity cannot be proven, two authoritative sources disagree, a foreign-key relationship is broken, or an owned record has no lossless destination.

Malformed candidates block the entire workspace key. The migration must not skip them, salvage only readable rows, create a partial workspace, or choose another candidate as if the malformed candidate did not exist.

### Missing worktree

A candidate is `missing-worktree` when its checkout cannot be reached but recorded project origin still proves the exact `project_scope_id` and `checkout_id`. The candidate remains eligible for history preservation and keeps its independently determined lifecycle. The replacement workspace is created as unavailable and cannot dispatch work until discovery confirms that the same checkout is available again.

A missing checkout with insufficient or conflicting recorded provenance is malformed. The migration must not bind it to another checkout with a similar path, branch, display name, or repository remote.

### Cross-daemon

A candidate is `cross-daemon` when its persisted provenance names a stable daemon identity other than the daemon performing the migration. It belongs to a different workspace key and must never be merged with local candidates, even when repository and checkout identities match.

Cross-daemon candidates are reported as excluded from the local collision set. A row stored in the local daemon database that claims a different daemon, or legacy data whose daemon scope cannot be established without ambiguity, is malformed and blocks migration. The migration must not adopt foreign ownership implicitly.

## Read-only preflight

Preflight must complete before the first migration write. It runs from a consistent database snapshot and an immutable inventory of every file-backed and consumer-owned source.

For each workspace key, preflight records:

- the normalized identity and every source used to prove it;
- every candidate Session ID and its four classification dimensions;
- the liveness evidence and production rule that produced each lifecycle result;
- the chosen seed candidate and the exact comparison values used to choose it;
- every owned record count, source key, destination key, and content digest;
- every database table, state file, log, checkpoint, transcript, signal directory, and external consumer store inspected;
- every conflict, missing source, unsupported shape, orphan, and inspection error;
- the proposed authority-switch checkpoint and rollback action.

The inventory must include at least projects, Sessions, agents, tasks or work items, task checkpoints, task reviews and arbitration state, managed agents, managed terminals, managed runs and turns, task-board items and dispatch intents carrying Session correlation, signals and acknowledgements, conversation events, Session logs, timeline entries and timeline state, activity caches, policy state, and Monitor decisions. A new Session-owned or Session-correlated store must be added to this inventory before the migration can run.

Monitor decisions are consumer-owned data even when they are not stored in the daemon database. Preflight must either map every decision with Session, agent, or task correlation to its destination or stop. The same rule applies to any other consumer database or file store discovered during inventory.

Database-only preflight is insufficient because legacy file discovery can resurrect state that a database migration appears to remove. State files and their discovery roots must be included in the manifest and retired only after the authority switch succeeds.

Preflight has three outcomes:

| Outcome | Meaning |
| --- | --- |
| `noop` | No local candidates exist and no migration write is needed |
| `ready` | Every candidate and owned record has a deterministic, lossless mapping |
| `blocked` | At least one conflict, malformed source, ambiguous scope, or incomplete mapping exists |

Only `ready` may proceed. A `blocked` result is an operator report, not a partial migration plan.

## Deterministic selection

The selected candidate supplies only the live owner and mutable workspace defaults. Selection never decides which history survives; every valid local candidate is preserved.

Apply these rules in order to one workspace key:

| Candidates | Result |
| --- | --- |
| Zero | Return `noop`; do not create a workspace as a side effect of migration |
| One valid local candidate | Select it, preserving its lifecycle and checkout availability |
| More than one active candidate | Return `blocked`; do not merge live teams or stop either team |
| Exactly one active candidate | Select the active candidate |
| No active candidates | Select the greatest deterministic freshness tuple described below |

The freshness tuple is compared lexicographically in this order:

```text
(
  lifecycle_rank,
  effective_activity_at,
  updated_at,
  created_at,
  session_id
)
```

`lifecycle_rank` is `stale > ended`. `effective_activity_at` is the greatest valid timestamp among Session last activity, agent last activity, runtime activity, review activity, task activity, and Session update time. Missing timestamps sort before present timestamps. Timestamps compare as UTC instants; `session_id` compares by unsigned UTF-8 byte order. The greatest complete tuple wins.

The final Session ID comparison is a total-order tie-breaker, not an assertion that the later ID is more authoritative. The report must show the full tuple for every candidate so another implementation produces the same result.

## Preservation and conflict rules

Migration copies into replacement-owned shadow records before changing authority. It must not update or delete legacy records in place.

Every destination record carries provenance sufficient to recover its source daemon, source Session ID, source record kind, and source record ID. Legacy Session ID remains optional correlation metadata after cutover; it never becomes the durable workspace key.

Session-scoped identifiers such as agent IDs, task IDs, review IDs, signal IDs, and timeline entry IDs are namespaced by their source Session during migration. Their destination identity must be a deterministic function of `(source_session_id, source_record_kind, source_record_id)`, and the migration ledger must store the exact mapping. This prevents equal local IDs from overwriting unrelated records.

Provider runtime Session IDs and managed-agent IDs stay in their own identity domains. They may be shared only when runtime kind, provider identity, and immutable binding evidence prove they refer to the same entity. Otherwise a duplicate is a conflict and blocks migration.

Two source records may be deduplicated only when their normalized payloads and all ownership relationships are identical. The destination retains both provenance aliases. Equal IDs with different payloads, or equal payloads with incompatible ownership, are conflicts and block migration.

The selected active candidate contributes live membership, leadership, current assignments, pending signals, and mutable workspace defaults. Non-selected candidates contribute immutable history. Their original non-terminal work and decision states remain queryable as historical state, but they do not enter the selected team's executable queue or approval surface. The migration must not reactivate their agents, translate their work to a terminal status, resolve their decisions, resend their signals, or combine their leadership and policy state with the selected live team.

When no candidate is active, the selected candidate supplies display and default policy values only. The replacement workspace starts without a live leader or live agent claim.

An ended candidate's records remain queryable with their original timestamps, outcomes, review decisions, and provenance. `missing-worktree` does not reduce the preservation set.

## Conflict boundary

These conditions block a workspace key before mutation:

- more than one active candidate;
- an unsupported or malformed candidate;
- ambiguous or contradictory daemon, project, or checkout identity;
- an owned record missing from the preflight inventory;
- an orphan whose owner cannot be recovered unambiguously;
- a conflicting session-scoped, managed-agent, or provider identity;
- a liveness or runtime inspection error for a candidate that may be active;
- a source changing between snapshot, copy, and verification;
- inability to snapshot or restore any authoritative source, including consumer-owned decisions and file-backed state.

One blocked workspace key must not contaminate another key's report or mapping. A migration command may continue preflighting other keys, but it must not mutate any key until its own `ready` manifest is complete. A repository-wide invocation should default to audit-only when any key is blocked unless an operator explicitly selects already-ready keys.

## Retry and rollback

Every ready manifest receives an idempotency key derived from:

```text
(migration_version, daemon_id, workspace_key, manifest_digest)
```

The migration journal advances monotonically through these phases:

| Phase | Authority | Allowed recovery |
| --- | --- | --- |
| `preflighted` | Legacy | Re-run preflight or discard the manifest |
| `copied` | Legacy | Resume copy, verify, or discard shadow records |
| `verified` | Legacy | Repeat verification or discard shadow records |
| `committed` | Replacement | Resume compatibility verification or roll authority back when safe |
| `retired` | Replacement | Legacy data remains archived according to retention policy |

A retry with the same idempotency key resumes the first incomplete phase and verifies already-written rows by destination key and digest. It must not append duplicates. If any source digest or mapping input changes, the manifest is obsolete; the run returns to read-only preflight and receives a new idempotency key.

The authority switch is one atomic database transaction or one equally strong compare-and-swap boundary. Replacement reads and writes remain disabled until every shadow record verifies against the manifest. Compatibility dual reads compare normalized results; any disagreement aborts the switch and keeps legacy authoritative.

Before `committed`, rollback removes only shadow records named by the journal and leaves every legacy source untouched. After `committed`, authority may roll back to legacy only when the journal proves that no replacement-only write occurred. If replacement-only data exists, rollback stops for reconciliation rather than discarding that data.

Legacy database rows, state files, and discovery roots must not be deleted at commit. They are marked read-only and protected from file-based resurrection through an explicit authority marker. Physical retirement requires successful compatibility verification and the separate removal policy; it is not part of collision resolution.

## Verification

Before commit, the migration verifies both structure and behavior:

- every manifest source key maps to exactly one destination or an explicitly recorded identical-record alias;
- every destination maps back to at least one manifest source;
- record counts and content digests match by record kind;
- all ownership edges resolve inside the destination workspace;
- selected live agents, work, reviews, decisions, signals, and runtimes retain their state without replaying effects;
- non-selected history remains queryable without appearing as live ownership;
- unavailable workspaces reject dispatch until the same checkout identity is rediscovered;
- compatibility reads return equivalent normalized state from legacy and replacement owners;
- restart and repeated migration do not create another owner or resurrect a legacy one.

Verification failure leaves the journal before `committed`, keeps legacy authoritative, and reports the first mismatched source and destination keys plus their digests. The verifier must continue collecting independent mismatches when doing so cannot mutate state.

## Operator report

The report is durable and machine-readable, with a concise human summary. It must show:

- migration version, daemon ID, workspace key, manifest digest, and idempotency key;
- preflight outcome and journal phase;
- candidate classifications, liveness evidence, freshness tuples, and selection reason;
- checkout availability and the provenance used when a worktree is missing;
- source and destination counts and digests by record kind;
- every identifier remapping and deduplication alias;
- cross-daemon exclusions;
- conflicts and blockers with source locations;
- the current authority and exact retry or rollback action.

The command must exit unsuccessfully for `blocked`, copy failure, verification mismatch, unsafe rollback, or authority-switch failure. It must never describe a partially copied or unverified workspace as migrated.

## Required implementation tests

The schema and migration implementation that follows this contract must cover at least:

- zero, one stale, one ended, and one active candidate;
- one active candidate plus several stale and ended candidates;
- several active candidates with no writes;
- equal timestamps resolved by Session ID byte order;
- quiet interactive, awaiting-review, and managed agents remaining active under production liveness rules;
- runtime inspection failure failing safe;
- available and missing worktrees with matching and conflicting recorded provenance;
- cross-daemon candidates remaining separate;
- colliding agent, task, review, decision, signal, runtime, and timeline identifiers;
- an orphan or malformed source blocking the whole workspace key;
- interruption and retry after every journal phase;
- source mutation invalidating a manifest;
- rollback before commit and guarded rollback after commit;
- dual-read disagreement preserving legacy authority;
- daemon restart and file discovery creating no duplicate owner or resurrected Session state.
