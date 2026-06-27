# Harness — Focus & Roadmap (living doc)

> Status: DRAFT v0.2 — owner: Bartek. Driven via structured prioritization sessions. This doc overrides feature ambitions when they conflict. If it is not moving the North Star forward, it is secondary or deferred.

## North Star (the one job)

**Point a swarm of AI coding agents at a real task in a repo and get back working, reviewed, shippable code — with minimal babysitting.** Everything else in the codebase (reviews-as-product, task board, policy canvas, voice, watch, mesh/suite) is *supporting* or *deferred* until this is reliable.

Audience: me now, a small team soon (shared daemon + auth in scope, but not ahead of "one swarm actually works").

## Definition of "useful" (acceptance bar)

A single swarm, on Codex, completes this loop **10 times out of 10** without me hand-holding:

1. I give it a goal.
2. Agents spawn, join, and a leader takes control. *(start)*
3. The work is broken into tasks; workers pick them up and produce diffs. *(dispatch)*
4. Reviewers reach consensus or the leader arbitrates — the review loop always terminates. *(review)*
5. The result lands as a branch/PR with the change plus a review trail I can trust. *(land)*

When that is true and repeatable, Harness has crossed from "demo" to "tool."

## Operating principles

- **One increment at a time.** Finish and verify before starting the next. No parallel half-features.
- **Bottom-up, capstone last.** Harden start → dispatch → review → land *as mechanics* before adding the autonomous AI leader on top.
- **One runtime first.** Make Codex's path rock-solid; copy the pattern to Claude Code and others only after.
- **Flags, not deletes.** Unfinished/off-focus surfaces get hidden behind `HARNESS_FEATURE_*` flags (moderate cut), not removed.
- **Verify end-to-end, every time.** Each milestone ships with a reproducible golden-path check that fails loudly on regression.

## Diagnosis (why it isn't useful yet)

The product has been built top-down and broad: autonomous leadership across every runtime, plus reviews, board, canvas, voice, watch, mesh. The substrate it all rests on — start/dispatch/review/land — is unreliable at every layer, so the ambitious top never has solid ground. The fix is sequencing and narrowing, not more features.

**M0 refinement (2026-06-26):** A code trace of the Codex path shows start-up and task-dispatch are actually *implemented and wired* (no `todo!()`/stubs). So for those stages "unfinished" really means "implemented but unreliable" — the work is hardening and verification, not building from scratch. The genuinely thin areas are the *automation glue* in review and land (see M0 findings below).

## Roadmap (sequenced, small increments)

> Each milestone is "done" only when its golden-path check passes repeatably. M5 (autonomous leader) is the capstone — it comes *after* the substrate works.

- **M0 — Ground truth + golden-path harness.** Pick ONE runtime (Codex). Build a reproducible scripted scenario (1 leader + 1 worker + 1 reviewer, trivial task) exercised via the `harness` CLI, asserting each stage. This is the regression net for everything after. Also: surface *where* it breaks today with real output, not guesses. _(In progress — code trace done, scripted scenario pending.)_
- **M1 — Starting up is deterministic.** One path brings a swarm alive: session start → N managed agents spawn → join → leader takes control, on Codex. *Check: 10/10 cold starts reach Active with leader + idle-ready workers.*
- **M2 — Task dispatch works without hand-feeding.** A (scripted/human) leader assigns a task; a worker picks it up, works in its worktree, and hooks/guards do not block it spuriously. *Check: assigned task → worker produces a diff, 10/10.*
- **M3 — Review loop always closes.** Submit-for-review → reviewers → consensus or bounded-round leader arbitration → task reaches Done. No stalls. *Check: review terminates within the round cap, every time, including the dispute path.* _Regression net started (VERIFIED on Linux):_ consensus → `Done` is already covered by the daemon `review_quorum` test; the previously-uncovered **arbitration termination gate** now has three passing tests in `src/session/service/tests/review_arbitration.rs` — arbitration is rejected below round 3, the leader force-closes a round-3 deadlock to `Done` (clearing the block), and a non-leader cannot arbitrate. Remaining for M3 *implementation*: nothing makes a reviewer agent actually review (the verbs are manual today) — that automation is the real M3 work, now sitting on a tested termination floor.
- **M4 — Work lands.** Worktree → branch → PR (or integration-branch merge) with the change plus review trail. *Check: a swarm run yields a reviewable PR artifact.*
- **M5 — Autonomous AI leader (capstone).** Replace the scripted/human coordinator with an AI leader: goal → decomposition → assignment → review → arbitration, on the now-solid substrate. *Check: give a goal, walk away, return to a PR.*
- **M6 — Team/remote (parallelizable after M2-ish).** Make the shared daemon + auth/pairing usable for a second person. Leans on the recent remote-authz work already in `src/daemon`.

## M0 findings — concrete ground truth (Codex path)

> Source: code trace, 2026-06-26. file:function citations live in the session notes; summarized here.

### Start-up (implemented; reliability gaps)

- `harness agents start codex` is a daemon HTTP call, not a client-side spawn. The daemon's `CodexControllerHandle::start_run` validates, probes the websocket, registers the run as a session worker agent, persists a snapshot, and spawns a `CodexRunWorker` that drives `initialize → thread/start → turn/start → event_loop`. The process is `codex app-server --listen stdio://` (or a websocket app-server in sandboxed mode).
- **Gap A — no upfront auth check.** Nothing verifies `OPENAI_API_KEY`/Codex auth at start; an unauthenticated agent "starts" and only fails later inside `turn/start` as a generic IO error. Fix = fail fast with a clear message.

### Task dispatch (automated bridge exists; reliability gaps)

- The "task assigned → Codex receives prompt" bridge is wired: dropping a task emits a start signal whose wake-route `Codex` arm calls `controller.steer(run_id, prompt)`; an idle run gets a fresh `turn/start`, an active run gets same-turn steering.
- **Gap B — steer-into-active-turn.** A run is in `active_runs` from the moment it spawns (during its initial turn), so a task dropped mid-turn is injected as same-turn steering instead of a clean task turn. No "wait until idle, then start turn" gating.
- **Gap C — fire-and-forget delivery for Codex.** The TUI path confirms delivery via an ack loop; the Codex arm only logs a warning on a failed steer. Codex agents have no signal-file polling fallback, so a failed steer silently drops the task until a manual re-drop.

### Review loop (state machine wired; the act of reviewing is not automated)

- The five review verbs (`submit-for-review`, `claim-review`, `submit-review`, `respond-review`, `arbitrate`) are pure state machines. Their only callers are CLI/daemon handlers forwarding a human/agent-supplied verdict. **No code reads a diff, forms a verdict, or auto-submits a review.** A reviewer agent must be told (by prompt or by hand) to run `claim-review` then `submit-review`.
- The only automation is one advisory nudge: when a task goes to review with no reviewer + a leader present, a `spawn_reviewer` signal is written to the leader's runtime. It does not claim or review anything.
- **Termination guard is real:** consensus = 2 distinct runtimes; arbitration gate at round 3 (task `Blocked` → leader `arbitrate`). But rounds only advance if agents keep calling submit/respond — nothing advances them automatically.

### Landing (worktree/branch real; commit→PR real but gated, and nothing commits)

- Per-session worktree + `harness/<sid>` branch creation is real git, but only when session creation goes through the daemon's `session_setup` path (the bare state constructor leaves those fields empty).
- A real branch-push → PR-open → ready/merge pipeline exists and drives `pr_number`/`pr_url` — **but** it is gated behind explicit GitHub project config + token + per-item repo scoping + enabled-automation flags.
- **Gap D — nothing commits the worker's changes.** Harness has no auto-commit; the worker agent is implicitly expected to `git commit` in its worktree. Without that, the publish step parks at `STEP_WAITING_FOR_COMMITS`. The board dispatch/evaluation loop itself has zero git/PR side effects.

### The unifying gap

At every transition harness flips state and emits a *signal*, but whether an agent acts on that signal (receive a task and work, actually review a diff, commit so landing proceeds) is left to the agent's own prompt or to a manual CLI call. The missing primitive is a reliable, **acknowledged** "tell agent X to do action Y now, and confirm it happened" bridge. That single missing primitive is most of why "minimal babysitting" fails today — and it is the spine of M2, M3, and M4.

## M0 build plan (golden-path harness — small slices)

> Builds on the existing seam: the injectable `CodexTransport` trait (`send`/`next_frame`/`shutdown`) and `CodexRunWorker::run_with_transport`, which already has a minimal inline `FakeTransport` in `worker_tests.rs`. We grow that into a reusable scripted app-server plus stage-by-stage golden tests. All verifiable headless via `cargo test` (no real `codex` binary, no Mac).

- **Slice 1 — Scripted Codex app-server + turn-lifecycle golden tests.** _Done & VERIFIED._ A reusable, request-aware `ScriptedCodexServer` test double (responds to initialize → thread/start|resume → turn/start, then enqueues scripted trailing notifications) drives the real `CodexRunWorker::run_with_transport` headless — no `codex` binary, no Mac, no network. Four passing tests in `src/daemon/codex_controller/tests/golden_path.rs` (+ widened `run_with_transport` to `pub(super)`, registered the module in `tests.rs`):
  - `golden_path_delivers_task_prompt_to_turn_start` — the assigned task prompt reaches `turn/start`; run ends `Completed`.
  - `failed_turn_lands_failed_status_and_surfaces_error` — a failed turn lands `Failed` with the error on the snapshot.
  - `agent_final_message_is_captured_from_item_completed` — deltas + `item/completed` final_answer populate `final_message`.
  - `existing_thread_resumes_instead_of_starting` — a run with a thread resumes, never sends `thread/start`.
  **Verified by real compile + run on the Linux remote** (`4 passed; 0 failed`) using temporary, *reverted* macOS shims (see Environment note). Re-confirm on macOS with `cargo test daemon::codex_controller::tests::golden_path`.
- **Slice 2 — M2 spec for delivery (Gaps B + C).** _Done._ Root-caused the defect (`steer` overloaded for steering vs. task delivery; wake-route fires it without awaiting the ack) and wrote the precise M2 spec — decision table, change sites, and acceptance tests T-B1/T-C1/T-C2 — in "M2 spec — reliable Codex task delivery" below. Delivered as a spec rather than red tests so the shared branch / macOS CI stays green; the tests get added and run on macOS during M2 implementation.
- **Slice 3 — Session-level scenario.** Drive session service + controller together: session start → register Codex worker → drop task → assert prompt delivery, using the scripted server. Bridges the worker-level net to the session-level golden path (M1+M2 acceptance).
- **Slice 4 — Review + land stubs in the harness.** Add scripted reviewer behavior and a worktree-commit fixture so M3/M4 work has a regression target before we touch them.

## M2 spec — reliable Codex task delivery (Gaps B + C)

> This is slice 2's deliverable: the precise spec that defines "M2 done." Written as a spec rather than committed-but-failing tests, because a red test on the shared branch breaks macOS CI and cannot be compile-verified from the Linux session anyway. The acceptance tests below get added and run on macOS as M2 is implemented.

**Defect (root cause).** `CodexControllerHandle::steer` (`src/daemon/codex_controller/handle_control.rs`) is overloaded for two different jobs: (1) genuine *same-turn steering* (a human adds context to the turn in flight), and (2) *task delivery* (the wake-route hands a worker its assigned task). It routes by run liveness: `active_run(run_id)` Ok → `CodexControlMessage::Steer` (same-turn inject); else → `start_follow_up_turn` (a clean new turn). The wake-route (`src/daemon/service/mutations_async/mod.rs::try_wake_started_workers_async` and the sync twin in `signals.rs`, `WakeRoute::Codex` arm) calls `steer` for task delivery and only `tracing::warn!`s on failure — fire-and-forget, unlike the TUI arm which awaits `wait_for_task_start_ack_async`.

- **Gap B** — a task dropped on a worker that is still mid-initial-turn is injected as same-turn steering instead of being worked as its own clean turn.
- **Gap C** — if that delivery fails, the task is silently dropped (Codex agents have no signal-file polling fallback); nothing retries or marks it undelivered.

**Target decision table (task delivery, distinct from user steering).**

| Run state at delivery | Required behavior |
|---|---|
| Idle / Queued / Completed (has thread) | Start a clean follow-up turn carrying the task prompt. *(existing good behavior — keep)* |
| Active (mid-turn) | Do NOT same-turn inject. Queue the task; start a clean turn when the current turn completes. |
| Genuine user "steer" (add context now) | Stays same-turn `Steer` — keep as a separate, explicitly-named path/verb. |
| Any delivery failure | Surface it: persist the task as undelivered and/or retry. Never silently drop. |

**Change sites.**
- Separate "deliver task" from "steer" at the controller: a delivery entry point that never same-turn-injects (route active → queue-until-idle → clean turn), leaving `steer` for genuine mid-turn context.
- Wake-route Codex arm: await the delivery ack (mirror the TUI `wait_for_task_start_ack_async` contract); on failure, record the task as undelivered / re-drop, do not just log.

**Acceptance tests to add (run on macOS), extending the golden-path harness.**
- **T-B1** — dropping a task on an *active* Codex run yields exactly one new `turn/start` carrying the task prompt *after* the active turn completes, and no same-turn steer frame containing the task prompt.
- **T-C1** — when delivery fails, the wake path marks the task undelivered / retries; it is observable, not a no-op log line.
- **T-C2** — an idle run receiving a task starts a clean turn with the task prompt (regression-guards the existing good path; natural extension of slice 1's test).

## Environment note (verification)

The Rust crate is **macOS-targeted**: it depends on `security_framework` (Keychain) and has macOS-gated daemon/sandbox code, so a stock `cargo test` does **not** compile on a Linux remote. The Monitor app (Swift/Xcode) is macOS-only by nature.

**However, Rust tests CAN be verified on Linux** via a small set of temporary, *uncommitted* shims that get reverted before commit. The macOS-only blockers are few and localized:
- `src/setup/secrets.rs` — `cfg`-gate the `security_framework` imports and add a tiny non-macOS `SecError`/`*_generic_password` stub module (must `derive(Clone, Copy)` on `SecError`).
- `src/daemon/websocket/parity.rs`, `src/daemon/http/sessions_adopt.rs`, `src/sandbox/migration.rs` — `#[cfg_attr(not(target_os = "macos"), allow(unused_imports))]` on the macOS-only imports.
- `src/mcp/transport.rs` — `#[cfg_attr(not(target_os = "macos"), allow(dead_code))]` on `map_io_error`.
- `src/sandbox/project_input.rs`, `src/daemon/http/sessions_adopt.rs` — gate their `#[cfg(test)] mod tests;` with `#[cfg(all(test, target_os = "macos"))]` (those test modules use macOS-only bookmark helpers).

Process: apply shims → `cargo test --lib <module>` → iterate → `git restore` the shim files → confirm no shim residue → commit only the real test code. Slice 1 was verified exactly this way. Still re-run on macOS as the source of truth, but this gives genuine green/red signal from Linux.

## Cut / defer list (behind flags, not deleted)

- Mesh/suite test harness (`src/run`, `src/setup`, `src/infra`) — already feature-gated.
- Voice capture, Apple Watch / CloudKit complications.
- Policy canvas OCR / clipboard-automation product surface.
- Reviews *as a standalone product dashboard* (keep the GitHub client — M4 needs PR creation — but defer the standalone reviews UX).
- MCP UI-automation server — keep for testing the Monitor, not a user feature.

## Locked decisions

1. **Sequencing: substrate-first.** Harden start → dispatch → review → land with a scripted/human leader; autonomous AI leader is the capstone (M5).
2. **First runtime: Codex via the Codex app-server transport** — the daemon `CodexController` + `CodexRunWorker` driving `codex app-server --listen stdio://` (the injectable `CodexTransport`), **NOT** the `harness-codex-acp` ACP adapter. Pattern gets copied to Claude Code / others after it is solid.
3. **Golden-path task: self-hosted / dogfood** — a real small task from this repo is the acceptance scenario.

## Decision log

- 2026-06-26 — North Star = swarm orchestration (over reviews / board / mesh).
- 2026-06-26 — Audience: me now, small team soon (remote/auth in scope, not ahead of "one swarm works").
- 2026-06-26 — Cut style: moderate (flags, not deletes).
- 2026-06-26 — Sequencing: substrate-first, autonomous leader last.
- 2026-06-26 — First runtime: Codex.
- 2026-06-26 — Golden-path task: dogfood a real Harness task.
- 2026-06-26 — M0 trace: Codex start/dispatch implemented, not stubbed; reframe to hardening (gaps A/B/C).
- 2026-06-26 — Codex path = **app-server transport** (`CodexController`/`CodexRunWorker`/`CodexTransport`), not `harness-codex-acp`. The golden-path harness substitutes a fake `CodexTransport` for `codex app-server`.
- 2026-06-26 — First build increment = golden-path test harness (M0 closeout); validation by code trace for now, live dogfood deferred.
