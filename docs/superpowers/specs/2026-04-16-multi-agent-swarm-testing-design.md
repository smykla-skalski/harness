# Multi-Agent Swarm Testing Design

## Problem statement

Harness is primarily a multi-agent orchestration system, but the current testing emphasis has leaned toward the app surface rather than the swarm contract itself. The goal of this design is to define an exhaustive, contract-first testing strategy for the core swarm behavior so that any AI agent can execute the plan, prove expected behavior, and identify genuine gaps in the product contract instead of guessing from today's implementation.

## Desired outcome

Produce a single test document that another AI agent can use as both:

1. a **strategy reference** that explains what the swarm must guarantee; and
2. an **execution runbook** that tells the runner exactly what to do, what to capture, and how to decide pass, fail, or blocked.

## Scope

### In scope

- Multi-agent session start and join flows across `claude`, `codex`, `gemini`, `copilot`, and `vibe`
- Both accepted orchestration entry paths:
  - **true in-runtime** actions, where the agent issues swarm commands from inside its own runtime
  - **managed bootstrap/join** actions, where the daemon and CLI launch and steer managed TUIs
- Joining with every supported session role: `leader`, `observer`, `worker`, `reviewer`, `improver`
- Single-leader behavior, explicit leadership transfer, voluntary leader exit, involuntary leader failure, and leaderless degraded recovery
- Task creation, assignment, checkpointing, completion, blocking, and recovery
- Observer-driven triage and open-task creation
- Daemon/TUI transport behavior needed to spawn, attach, and steer runtime TUIs
- Liveness, recovery, repeated joins, concurrency pressure, and failure injection

### Out of scope

- `opencode`
- Harness Monitor app behavior
- Product changes outside the swarm/session/orchestration surface

## Normative contract

The final test plan must treat the following rules as product expectations.

### Runtime contract

- The required runtime set is `claude`, `codex`, `gemini`, `copilot`, and `vibe`.
- `opencode` is explicitly excluded from this test plan.
- Every required runtime must pass both:
  - a **true in-runtime** start flow
  - a **managed bootstrap** start flow
- Every required runtime must pass both:
  - a **true in-runtime** join flow
  - a **managed join** flow
- Runtime-specific plumbing differences are valid, but they must not weaken the contract:
  - `gemini` uses CLI-flag prompt delivery
  - `claude`, `codex`, and `vibe` use CLI positional prompt delivery
  - `copilot` relies on PTY-style interaction and does not provide a native parseable transcript
  - `vibe` lacks a readiness hook and must be validated by successful launch and usable interaction instead

### Role and leadership contract

- The joinable roles are `leader`, `observer`, `worker`, `reviewer`, and `improver`.
- Only one active leader may exist at a time.
- A join request that asks for `leader` while a leader already exists is handled as follows:
  - the join request must carry an **explicit fallback non-leader role**
  - if the fallback role is present, the join succeeds using that fallback role
  - if the fallback role is missing, the join is rejected
  - the downgraded agent does not become leader until an explicit leader transfer occurs
- Leadership transfer may happen in three ways only:
  - explicit user-initiated transfer
  - automatic promotion after graceful leader exit
  - automatic promotion after leader failure or disconnection

### Automatic promotion contract

- Automatic promotion is required for both:
  - voluntary leader leave
  - involuntary leader failure, stall, or liveness-based disconnection
- Promotion precedence is:
  - `improver`
  - `reviewer`
  - `observer`
  - `worker`
- When multiple agents are eligible inside the same highest-priority role, the winner is selected by the **session-level policy or preset** that defines explicit persona/capability priority.
- If no eligible successor exists:
  - the session enters a **leaderless degraded state**
  - the user must be notified
  - the user must be able to recover in either of two ways:
    - use a configurable preset to spawn a managed TUI that joins as leader
    - handle recovery manually

### Task orchestration contract

- Only the leader may assign tasks.
- Only workers may receive assigned tasks.
- Observers may triage and create open tasks, but they do not assign them.
- Reviewers and improvers remain important swarm roles for failover, oversight, and policy, but they are not valid task assignees under this contract.
- Workers must be able to:
  - accept assigned work
  - report status changes
  - record checkpoints
  - move tasks to blocked or done
- If a worker disappears or is removed, its in-progress work must return to an **open, unassigned** state so the leader can reassign it.

### Observer contract

- The observer is allowed to scan and triage swarm activity.
- After triage, the observer may create **open tasks only**.
- Re-running observe against the same underlying issue must not create duplicate persisted work items.
- A read-only observe path must also exist so scanning can happen without task persistence.

## Document shape

The final deliverable should be structured in four layers:

1. **Contract layer** — hard rules the swarm must satisfy
2. **Coverage matrix** — a dense view of runtime, role, path, and failure combinations
3. **Critical runbooks** — step-by-step high-value end-to-end scenarios
4. **Failure and recovery appendix** — concurrency, degradation, and resilience probes

Every individual test entry should use the same schema:

- objective
- prerequisites
- scenario inputs
- actions
- expected state transitions
- evidence to capture
- pass/fail/blocked verdict rules

## Testing architecture

The test plan should split execution into three lanes.

### 1. Contract lane

Fast checks against session/service behavior:

- role permissions
- join validation
- leadership rules
- promotion rules
- task ownership rules
- observe persistence rules
- liveness-driven transitions

This lane proves the swarm rules themselves without depending on every runtime transport detail.

### 2. Managed-orchestration lane

Daemon + CLI + managed TUI scenarios that prove:

- runtime launch
- PTY steering
- join registration
- attach behavior
- prompt delivery
- runtime-specific readiness behavior
- end-to-end orchestration between real runtime agents

### 3. Failure and recovery lane

Scenarios that deliberately induce:

- leader exit
- leader stall
- worker loss
- daemon interruption
- TUI attach loss
- repeated joins
- repeated observe passes
- multi-agent role pressure

This lane proves the swarm survives real operating conditions instead of just nominal flows.

## Execution environment

Each runbook should require the runner to use:

- one isolated project workspace per run
- one explicit swarm session identifier per scenario
- a declared runtime inventory for the run
- a declared session-level policy or preset for:
  - promotion precedence
  - persona/capability priority
  - degraded-state recovery
  - managed leader recovery spawn settings

The plan should prefer shortened test-specific timing where the product exposes configuration for liveness and promotion delays, but the contract must remain the same whether timings are short or default.

## Evidence model

Each scenario should capture a consistent evidence bundle:

- session status before the scenario
- session status after each major transition
- full agent roster, including runtime, role, status, and leader identity
- task list snapshots before and after observe, assignment, completion, and recovery
- daemon/TUI evidence proving launch, attach, input delivery, and stop behavior
- observer output and the resulting persisted task records
- logs or state artifacts that prove promotion, downgrade, rejection, degraded state, or recovery

Runtime-specific evidence rules:

- `copilot` cannot rely on a native transcript, so the plan must rely on harness state, daemon/TUI artifacts, and any harness-owned session ledgers
- `vibe` cannot rely on a readiness hook, so the plan must prove usability via successful interaction
- other runtimes may use both runtime artifacts and harness-owned evidence

## Coverage matrix dimensions

The final test matrix should explicitly cross the following dimensions.

| Dimension | Required values |
| --- | --- |
| Runtime | `claude`, `codex`, `gemini`, `copilot`, `vibe` |
| Start model | true in-runtime, managed bootstrap |
| Join model | true in-runtime, managed join |
| Requested join role | leader, observer, worker, reviewer, improver |
| Leader exit mode | graceful leave, abrupt failure, no-successor degradation |
| Promotion inputs | role precedence, persona/capability priority, missing-successor case |
| Observe mode | read-only, create-open-tasks |
| Task flow | create, assign, checkpoint, block, done, requeue/recover |
| Transport events | start, list/show, attach, input, resize, stop, attach-loss recovery |
| Failure pressure | repeated joins, daemon interruption, liveness sync, duplicate observe, mixed-runtime churn |

## Scenario catalog

The matrix is too large to encode as hand-written prose alone, so the final plan should define case-generation rules plus critical runbooks. The following catalog is the minimum required set.

### A. Session bootstrap matrix

Generate:

- `START-INRUNTIME-{runtime}`
- `START-MANAGED-{runtime}`

For each runtime in `claude`, `codex`, `gemini`, `copilot`, `vibe`.

Required assertions:

- session is created successfully
- leader is registered with the correct runtime
- session leader is observable in status output
- runtime can be attached or otherwise steered when managed
- runtime-specific evidence exists

Minimum case count: **10**

### B. Join matrix

Generate the following for each runtime and join path.

#### Standard role joins

Generate:

- `JOIN-{runtime}-{path}-observer`
- `JOIN-{runtime}-{path}-worker`
- `JOIN-{runtime}-{path}-reviewer`
- `JOIN-{runtime}-{path}-improver`

Where `{path}` is `inruntime` or `managed`.

Required assertions:

- join succeeds
- requested role is persisted exactly
- runtime metadata is correct
- session metrics reflect the new agent

Case count: **40**

#### Leader-request joins

Generate:

- `JOIN-{runtime}-{path}-leader-with-fallback`
- `JOIN-{runtime}-{path}-leader-without-fallback`

Where `{path}` is `inruntime` or `managed`.

Required assertions for `leader-with-fallback`:

- join succeeds
- agent is registered under the explicit fallback role
- existing leader remains leader
- no implicit leadership transfer occurs

Required assertions for `leader-without-fallback`:

- join is rejected
- session leader remains unchanged
- no partial registration survives the failure

Case count: **20**

### C. Role and permission tests

Required cases:

- `ROLE-001` leader can create and assign tasks
- `ROLE-002` non-leader cannot assign tasks
- `ROLE-003` observer can triage and create open tasks only
- `ROLE-004` worker can update only its assigned task state
- `ROLE-005` reviewer cannot assign tasks under the contract
- `ROLE-006` improver cannot assign tasks under the contract
- `ROLE-007` only workers may be selected as task assignees
- `ROLE-008` leader request conflict is downgraded only when explicit fallback is present
- `ROLE-009` leader transfer is required before a downgraded joiner may lead
- `ROLE-010` all roles can observe session state, but only the leader controls assignment

### D. Explicit leadership transfer tests

Required cases:

- `TRANSFER-001` transfer to a downgraded would-be leader succeeds explicitly
- `TRANSFER-002` transfer preserves single-leader invariant
- `TRANSFER-003` transfer refuses invalid or missing target agents
- `TRANSFER-004` transfer honors persona/capability priority only for automatic promotion, not manual transfer
- `TRANSFER-005` transfer leaves task ownership intact unless reassignment is explicitly requested

### E. Graceful leader leave tests

Generate cases for each highest-eligible successor role:

- `LEAVE-GRACEFUL-improver`
- `LEAVE-GRACEFUL-reviewer`
- `LEAVE-GRACEFUL-observer`
- `LEAVE-GRACEFUL-worker`

Required assertions:

- leaving leader exits successfully
- successor is chosen automatically
- successor matches promotion precedence
- successor also matches session-level persona/capability priority when multiple peers share the same role
- session continues without becoming leaderless

Additional required cases:

- `LEAVE-GRACEFUL-no-successor`
- `LEAVE-GRACEFUL-recovery-via-preset`
- `LEAVE-GRACEFUL-recovery-via-manual-path`

### F. Leader failure and liveness tests

Required cases:

- `FAILOVER-001` abrupt leader failure promotes improver
- `FAILOVER-002` abrupt leader failure promotes reviewer when no improver exists
- `FAILOVER-003` abrupt leader failure promotes observer when no improver or reviewer exists
- `FAILOVER-004` abrupt leader failure promotes worker when no higher role exists
- `FAILOVER-005` leader failure with multiple improvers uses session-level persona/capability priority
- `FAILOVER-006` no eligible successor enters leaderless degraded state
- `FAILOVER-007` degraded state notifies the user
- `FAILOVER-008` degraded state recovers through preset-managed leader spawn
- `FAILOVER-009` degraded state recovers through manual leader recovery
- `FAILOVER-010` repeated leader failure after a previous promotion still preserves the contract

### G. Task orchestration tests

Required cases:

- `TASK-001` leader creates a task manually
- `TASK-002` leader assigns a task to a worker
- `TASK-003` leader cannot assign a task to observer
- `TASK-004` leader cannot assign a task to reviewer
- `TASK-005` leader cannot assign a task to improver
- `TASK-006` observer cannot assign a task
- `TASK-007` worker cannot assign a task
- `TASK-008` worker records a checkpoint successfully
- `TASK-009` worker marks task blocked successfully
- `TASK-010` worker marks task done successfully
- `TASK-011` worker disconnect returns its task to an open, unassigned state
- `TASK-012` worker removal returns its task to an open, unassigned state
- `TASK-013` leader can reassign recovered work to a different worker
- `TASK-014` task list stays consistent through promotion and failover events

### H. Observer workflow tests

Required cases:

- `OBSERVE-001` read-only observe reports issues without persisting tasks
- `OBSERVE-002` observer triages and creates open tasks
- `OBSERVE-003` repeated observe does not create duplicate tasks for the same underlying issue
- `OBSERVE-004` leader assigns an observer-created task to a worker
- `OBSERVE-005` observe can scan mixed-runtime sessions
- `OBSERVE-006` observe still works after a leader promotion
- `OBSERVE-007` observe surfaces cross-agent conflict-style issues when multiple agents touch related work

### I. Managed TUI transport tests

Required cases:

- `TUI-001` managed TUI start succeeds for each runtime
- `TUI-002` managed TUI appears in list/show output
- `TUI-003` attach succeeds and streams output
- `TUI-004` text input can steer the runtime
- `TUI-005` paste input can steer the runtime
- `TUI-006` key input can steer the runtime
- `TUI-007` resize succeeds without corrupting the session
- `TUI-008` stop produces the expected runtime/session aftermath
- `TUI-009` attach loss can be recovered

For `TUI-001` through `TUI-008`, expand across all five in-scope runtimes unless a scenario is explicitly runtime-agnostic by contract.

### J. Concurrency and resilience tests

Required cases:

- `RACE-001` repeated non-leader joins from different runtimes preserve session consistency
- `RACE-002` repeated leader-with-fallback joins preserve single-leader behavior
- `RACE-003` observe re-run during active task churn does not duplicate work
- `RACE-004` daemon interruption during managed session can be recovered without corrupting state
- `RACE-005` liveness sync during worker execution preserves task recovery rules
- `RACE-006` leader failure during observe still yields consistent degraded/promotion behavior
- `RACE-007` mixed-runtime swarm with worker churn preserves assignment and promotion rules

## Critical runbooks

The final document should include at least the following fully worked runbooks.

### Runbook 1: managed bootstrap happy path

- start a session via daemon/CLI-managed TUI
- verify leader registration
- attach to the TUI
- steer the runtime successfully
- capture evidence for runtime identity, leader identity, and attach behavior

### Runbook 2: true in-runtime bootstrap happy path

- launch the runtime normally
- issue the session-start command from inside the runtime
- verify leader registration and session visibility
- prove the agent is operating from within the runtime itself

### Runbook 3: managed join matrix slice

- existing leader starts the session
- a worker joins via managed TUI
- an observer joins via managed TUI
- leader assigns work to the worker
- observer triages and opens new tasks

### Runbook 4: leader-request join with fallback and explicit transfer

- a runtime joins asking for `leader`
- the join request includes explicit fallback role
- verify fallback-role registration
- perform explicit leader transfer
- verify single-leader continuity before and after transfer

### Runbook 5: graceful leader leave with automatic promotion

- prepare a session containing at least one improver, reviewer, observer, and worker
- leader leaves gracefully
- verify improver promotion
- repeat the same flow with different role availability to prove precedence order

### Runbook 6: abrupt leader failure with automatic promotion

- kill or disconnect the current leader
- trigger liveness/failure detection
- verify automatic promotion
- verify no task corruption

### Runbook 7: no-successor degraded recovery

- remove all eligible successors
- force leader exit/failure
- verify degraded state and user notification
- recover once via preset-managed leader spawn
- recover once via manual leader handling

### Runbook 8: observer triage to worker execution

- run observe in read-only mode
- run observe in task-creating mode
- verify only open tasks are created
- leader assigns the created work to a worker
- worker checkpoints, blocks, and completes the work

### Runbook 9: managed TUI steering resilience

- attach to a managed TUI
- steer using text, paste, and key input
- force attach loss
- reattach and continue without corrupting the session

### Runbook 10: mixed-runtime swarm under churn

- build a swarm with multiple runtimes
- join agents repeatedly
- create and assign work
- induce worker churn and one leadership transition
- verify the contract still holds end to end

## Pass/fail semantics

Every scenario in the final plan should end with a verdict block.

### Verdict types

- **Pass** — all contract expectations are satisfied and required evidence exists
- **Fail** — a product contract rule is broken
- **Blocked by environment** — the scenario could not execute because the required runtime, credentials, daemon, or preset policy was unavailable

### Priority classes

- **P0** — core swarm viability
  - start
  - join
  - leader continuity
  - leader-only assignment
  - worker-only execution
  - observer-to-open-task flow
- **P1** — resilience
  - promotion
  - degraded recovery
  - daemon/TUI recovery
  - liveness-driven continuity
  - repeated observe and worker churn
- **P2** — concurrency and stress
  - repeated mixed-runtime joins
  - repeated promotions
  - repeated attach loss and recovery
  - wider swarm churn scenarios

## Current implementation drift to watch

This design is contract-first, not implementation-first. The eventual execution plan should explicitly look for current-product drift in at least these areas:

- leader join conflict handling versus the new fallback-role contract
- leader leave behavior versus the new auto-promotion contract
- leader-failure behavior versus the new auto-promotion contract
- assignment permissions, because the current code surface is broader than the intended leader-only assignment rule
- assignee eligibility, because the current code surface is broader than the intended worker-only assignment rule
- degraded-state recovery behavior, because the current product may not yet expose the full preset-driven leader recovery path

## Recommended execution order

The implementation plan derived from this design should execute in this order:

1. contract lane
2. bootstrap and join matrix
3. leadership lifecycle
4. task orchestration
5. observer workflow
6. managed TUI transport
7. recovery and concurrency

This ordering produces fast signal first, then escalates into the expensive mixed-runtime and failure-injection scenarios only after the core contract is stable.
