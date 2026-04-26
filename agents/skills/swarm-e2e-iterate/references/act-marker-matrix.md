# Act Marker Matrix

The swarm full-flow lane writes `<act>.ready` and `<act>.ack` markers in the sync directory. Use this table to map each act to the side effect, payload, and required Monitor surface.

Derive a wall-clock window from the `<act>.ready` and `<act>.ack` mtimes. The matching frame in `swarm-full-flow.mov` must show the listed identifiers and state. If anything is absent, mislabeled, wrong, or late, file a finding with the act ID and timestamp range.

## Matrix

| Act | Harness side effect | Marker payload | Required Monitor surface |
|----|----|----|----|
| `act1` | `session start` succeeded; leader `claude` joined. | `session_id`, `leader_id` | Selected sidebar row for `session_id`. Cockpit window title. `harness.toolbar.chrome.state` contains `windowTitle=Cockpit`. |
| `act2` | Joined: workers, reviewers, observer, improver. Optional gemini/copilot/vibe joins. | `worker_codex_id`, `worker_claude_id`, `reviewer_claude_id`, `reviewer_codex_id`, `observer_id`, `improver_id` | `harness.session.agents.state` contains every joined ID. Each card shows the right runtime icon. Duplicate claim must be visibly rejected. |
| `act3` | Five tasks created: `task_review`, `task_autospawn`, `task_arbitration`, `task_refusal`, `task_signal`. | `task_review_id`, `task_autospawn_id`, `task_arbitration_id`, `task_refusal_id`, `task_signal_id` | `sessionTaskCard(task_review_id)` visible. Other task cards visible. No stale state. |
| `act4` | `task_review` and `task_autospawn` both assigned and started. | `task_review_id`, `task_autospawn_id` | `task_review` selected in the agents detail pane. `agentsTaskCard.value == task_review_id`. `task_autospawn` reflects in-progress. |
| `act5` | Observer ran `session observe` with heuristic codes. | `observer_id`, `heuristic_code` (`python_traceback_output` for the assertion) | One `heuristicIssueCard.<code>` per injected code. Missing cards or duplicate labels are findings. |
| `act6` | Improver applied `harness/skills/harness/body.md` patch in dry-run mode. | `improver_id` | Improver card in the agents detail pane reflects the dry-run apply. No silent failure banner. |
| `act7` | Optional vibe worker rejoin, sync, and temporary worker join+leave. | `vibe_worker_id` (empty when vibe runtime missing) | Agents card reflects current roster after the rejoin. Temporary worker not present. |
| `act8` | Worker codex submitted `task_review` for review. | `task_review_id`, `worker_codex_id` | `awaitingReviewBadge(task_review_id)` visible inside the review panel of the agents detail pane. Badge must read AwaitingReview. |
| `act9` | Reviewer claude claimed; duplicate claim rejected; reviewer codex claimed; both reviewers approved. | `task_review_id`, `reviewer_runtime` (`claude`) | One of `reviewerClaimBadge(task_review_id, claude)` or `reviewerQuorumIndicator(task_review_id)`. Quorum surface shows two runtimes. |
| `act10` | Both reviewers and the duplicate were removed; worker claude submitted `task_autospawn` for review; signal list inspected. | `task_autospawn_id`, `worker_claude_id` | Auto-spawn-reviewer indicator appears after the removal cascade. `awaitingReviewBadge(task_autospawn_id)` visible after the submit. |
| `act11` | Leader attempted to assign the busy worker claude to `task_refusal`; assign was rejected. | `task_refusal_id`, `worker_claude_id` | `harness.toast.worker-refusal` toast visible OR `agentsTaskCard` reflects rejection. Toast queues; never overlaps a previous toast. |
| `act12` | Two extra reviewers joined; arbitration task assigned and started; first request-changes round submitted on point `p1`. | `task_arbitration_id`, `point_id` (`p1`) | One of `partialAgreementChip(p1)`, `reviewPointChip(p1)`, or `roundCounter(task_arbitration_id)`. Round counter pill at `1`. |
| `act13` | Two more request-changes rounds submitted, then leader arbitrated approve. | `task_arbitration_id` | One of `arbitrationBanner(task_arbitration_id)` or `roundCounter(task_arbitration_id)`. Round counter advanced to `3`; banner stays visible. |
| `act14` | Leader sent a `pause` signal to worker codex twice; second send must collide. | `agent_id` (worker codex) | `harness.toast.signal-collision` toast visible OR `agentsTaskCard` reflects collision. Toast queues with the act11 toast; no overlap. |
| `act15` | Ran `observe scan`, `observe watch --timeout 5`, `observe dump --raw-json`, `observe doctor --json`. | `session_id` | One of `observeScanButton`, `observeDoctorButton`, `harness.session.action.observe`, or the observe summary surface. Daemon-health indicator stays green. |
| `act16` | `session end` submitted by leader. | `session_id` | `harness.session-status.corner` reaches the closed/ended state within 20 s of the act ack. Cockpit window does not hang or beachball. |

## Whole-run invariants

- `task_review` must visibly progress `Open -> AwaitingReview -> InReview -> Done`.
- Daemon-health stays green from `act1` through `act16`.
- Toast queue is append-only across `act11` and `act14`.
- `agentsTaskCard.value` must match the selected task ID.
- The five `act5` heuristic codes must remain visible unless explicitly cleared.
