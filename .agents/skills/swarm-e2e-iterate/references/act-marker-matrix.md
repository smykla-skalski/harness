# Act Marker Matrix

The swarm full-flow lane writes `<act>.ready` and `<act>.ack` markers in the sync directory. Each marker is the wall-clock anchor for triage. Use this table to map every act to the harness side effect, the marker payload, and the Monitor surface that must be visible in the recording at that timestamp.

Source of truth:

- [SwarmFullFlowOrchestrator.swift](../../../../apps/harness-monitor-macos/Tools/HarnessMonitorE2E/Sources/HarnessMonitorE2ECore/SwarmFullFlowOrchestrator.swift)
- [SwarmRunner.swift](../../../../apps/harness-monitor-macos/Tests/HarnessMonitorAgentsE2ETests/SwarmRunner.swift)
- [HarnessMonitorAccessibility+Review.swift](../../../../apps/harness-monitor-macos/Sources/HarnessMonitorUIPreviewable/Support/HarnessMonitorAccessibility+Review.swift)

## How to use

For every act in the matrix, derive a wall-clock window from the `<act>.ready` mtime and the `<act>.ack` mtime in the run sync directory. The matching frame in `swarm-full-flow.mov` must show the listed accessibility identifiers and the listed state. If any required identifier is absent, mislabeled, in the wrong state, or only appears after the `.ack` window, file a finding with the act ID and the timestamp range.

## Matrix

| Act | Harness side effect | Marker payload | Required Monitor surface |
|----|----|----|----|
| `act1` | `session start` succeeded; leader `claude` joined. | `session_id`, `leader_id` | Selected sidebar row for `session_id`. Cockpit window title. `harness.toolbar.chrome.state` contains `windowTitle=Cockpit`. |
| `act2` | Joined: worker/codex, worker/claude, reviewer/claude, reviewer/codex, reviewer/claude duplicate, observer/claude, improver/codex. Optional gemini observer, copilot improver, vibe worker join when runtime is present. | `worker_codex_id`, `worker_claude_id`, `reviewer_claude_id`, `reviewer_codex_id`, `observer_id`, `improver_id` | `harness.session.agents.state` label contains every joined ID. Each agent card shows the correct runtime icon. Duplicate reviewer claim must be visibly rejected, not silently accepted. |
| `act3` | Five tasks created: `task_review`, `task_autospawn`, `task_arbitration`, `task_refusal`, `task_signal`. | `task_review_id`, `task_autospawn_id`, `task_arbitration_id`, `task_refusal_id`, `task_signal_id` | `sessionTaskCard(task_review_id)` visible. Other task cards visible. No card shows a stale state from a prior run. |
| `act4` | `task_review` and `task_autospawn` both assigned and started. | `task_review_id`, `task_autospawn_id` | `task_review` selected in inspector. `taskInspectorCard.value == task_review_id`. `task_autospawn` reflects in-progress in card label. |
| `act5` | Observer injected ten heuristic codes and ran `session observe`. Codes: `python_traceback_output`, `unauthorized_git_commit_during_run`, `python_used_in_bash_tool_use`, `absolute_manifest_path_used`, `jq_error_in_command_output`, `unverified_recursive_remove`, `hook_denied_tool_call`, `agent_repeated_error`, `agent_stalled_progress`, `cross_agent_file_conflict`. | `observer_id`, `heuristic_code` (`python_traceback_output` for the assertion) | One `heuristicIssueCard.<code>` per injected code. Cards must show distinct codes; missing codes or duplicate labels are findings. |
| `act6` | Improver applied `harness/skills/harness/body.md` patch in dry-run mode. | `improver_id` | Improver card in inspector reflects the dry-run apply. No silent failure banner. |
| `act7` | Optional vibe worker rejoin, sync, and temporary worker join+leave. | `vibe_worker_id` (empty when vibe runtime missing) | Agents card reflects current roster after the rejoin. Temporary worker not present at this timestamp. |
| `act8` | Worker codex submitted `task_review` for review. | `task_review_id`, `worker_codex_id` | `awaitingReviewBadge(task_review_id)` visible inside the inspector. Badge color/label communicates AwaitingReview state distinctly from Open. |
| `act9` | Reviewer claude claimed; duplicate same-runtime claim rejected; reviewer codex claimed; both reviewers approved. | `task_review_id`, `reviewer_runtime` (`claude`) | One of `reviewerClaimBadge(task_review_id, claude)` or `reviewerQuorumIndicator(task_review_id)`. Quorum surface shows two distinct runtimes, not a duplicate. |
| `act10` | Both reviewers and the duplicate were removed; worker claude submitted `task_autospawn` for review; signal list inspected. | `task_autospawn_id`, `worker_claude_id` | Auto-spawn-reviewer indicator appears after the removal cascade. `awaitingReviewBadge(task_autospawn_id)` visible after the submit. |
| `act11` | Leader attempted to assign the busy worker claude to `task_refusal`; assign was rejected. | `task_refusal_id`, `worker_claude_id` | `harness.toast.worker-refusal` toast visible OR `taskInspectorCard` reflects rejection. Toast queues; never overlaps a previous toast. |
| `act12` | Two extra reviewers joined for the round flow; arbitration task assigned and started; first request-changes round submitted on point `p1`. | `task_arbitration_id`, `point_id` (`p1`) | One of `partialAgreementChip(p1)`, `reviewPointChip(p1)`, or `roundCounter(task_arbitration_id)`. Round counter pill at value `1`. |
| `act13` | Two more request-changes rounds submitted, then leader arbitrated approve. | `task_arbitration_id` | One of `arbitrationBanner(task_arbitration_id)` or `roundCounter(task_arbitration_id)`. Round counter advanced to `3`. Arbitration banner visible from round-3 entry through final approve. |
| `act14` | Leader sent a `pause` signal to worker codex twice; second send must collide. | `agent_id` (worker codex) | `harness.toast.signal-collision` toast visible OR `taskInspectorCard` reflects collision. Toast queues with the act11 toast; no overlap. |
| `act15` | Ran `observe scan`, `observe watch --timeout 5`, `observe dump --raw-json`, `observe doctor --json`. | `session_id` | One of `observeScanButton`, `observeDoctorButton`, `harness.session.action.observe`, or the observe summary surface. Daemon-health indicator stays green. |
| `act16` | `session end` submitted by leader. | `session_id` | `harness.session-status.corner` reaches the closed/ended state within 20 s of the act ack. Cockpit window does not hang or beachball. |

## Whole-run invariants

- Every state transition `Open -> AwaitingReview -> InReview -> Done` for `task_review` must be visible across `act4 -> act8 -> act9` boundaries. A badge that skips a state is a render-pipeline finding.
- Daemon-health indicator stays green from `act1` through `act16`. Any flap is a finding.
- Toast queue must be append-only across `act11` and `act14`. Two toasts visually overlapping for more than one frame is a toast-queue finding.
- `taskInspectorCard.value` must match the most recently selected task ID through every `selectTask` call. A drift between selection and inspector value is a selection-binding finding.
- The five heuristic codes injected at `act5` must remain visible through the rest of the run unless explicitly cleared. A card that disappears without a clear action is a state-loss finding.
