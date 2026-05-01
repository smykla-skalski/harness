# Decision Contract

This document is a narrative index.
Canonical operating semantics live on the Swift types and store helpers named below.
This file exists to keep the human-facing map aligned with those concrete owners when the UI shifts.

## Operating Goal

The Decisions system enforces a single operator queue for policy decisions.
Goal is single-queue policy enforcement, not interruption fidelity.
Presentation can change from modal to workspace window, but queue ownership, auditability, and idempotent resolution must remain stable.

## Canonical Type Map

- `AcpPermissionDecision` in `Models/AcpAgentModels.swift`: approve, deny, and partial-approve semantics for ACP permission batches.
- `AcpPermissionDecisionPayload` in `Supervisor/Decision/AcpPermissionDecision.swift`: deterministic ACP decision ids, semantic payload validation, and non-renderable fallback content for ACP Decisions rows.
- `AcpPermissionDecisionPayload.decisionKind` in `Supervisor/Decision/AcpPermissionDecision.swift`: first-class ACP decision-kind contract marker used during decode/reconciliation, so ACP routing is not only a `ruleID`/payload-shape convention.
- `AcpPermissionBatch` in `Models/AcpAgentModels.swift`: one queue element carries `1...N` permission items and uses `batchId` as the idempotency key.
- `BatchResolutionState` in `Models/BatchResolutionState.swift`: shared per-request toggle and submission state for the Decisions detail pane and the compatibility ACP modal.
- `SupervisorEvent` in `Supervisor/Audit/SupervisorEvent.swift`: current persisted audit-entry carrier, including the payload slot for approve-some request arrays and future `uiAnnotation` race notes.
- `Decision` in `Supervisor/Decision/Decision.swift`: queue-level goal, sticky-selection policy, and toggle-lifetime policy.
- `HarnessMonitorStore.pendingAcpPermissionBatches` and `reconcilePresentedAcpPermissionBatch` in `Stores/HarnessMonitorStore+AcpAgents.swift`: selected-session queue projection and sticky presentation behavior.
- `HarnessMonitorStore.reconcileAcpPermissionDecisions` and `resolveAcpPermissionDecision` in `Stores/HarnessMonitorStore+AcpAgents.swift`: DecisionStore materialization, shared selection-state upkeep, and daemon resolution bridging for ACP decisions.
- `HarnessMonitorStore.applyAcpPermissionBatch`, `removeAcpPermissionBatch`, `shouldReplacePermissionBatch`, and `sortedAcpPermissionBatches` in `Stores/HarnessMonitorStore+AcpAgents.swift`: batch upsert/removal, replay replacement, and oldest-first queue order.
- `HarnessMonitorStore.applyAcpEvents` in `Stores/HarnessMonitorStore+AcpAgents.swift`: Swift-side event application boundary after decode.
- `DaemonPushEvent.Kind.acpPermissionBatchRemoved` in `Models/HarnessMonitorDaemonPushEvent.swift`: resolved, timeout, and daemon-shutdown removals for ACP batches.
- `AcpEventBatchPayload` in `Models/HarnessMonitorTimelineModels.swift`: confirms UI-7 coalescing stays in-process Swift code and does not require a daemon wire-format change.
- `AcpAgentsReconciledPayload` in `Models/HarnessMonitorDaemonPushEvent.swift`: confirms reconcile snapshots already exist in-tree and remain authoritative.

## Front-Hall Channel

Primary signal is the Decisions queue itself.
Later redundant channels such as dock badge, window title/count, sidebar badge, toast, and notification center may degrade without changing the contract.

## UI-6 Authority

Authority for deleting the legacy ACP modal after dogfood sits with the Harness Monitor maintainers owning this plan.
Default schedule is after the UI-0 dogfood kill criteria hold for the planned two-week window.
Override rule: do not delete the modal on calendar grounds alone if abandoned pending decisions, double resolutions, or sub-95 percent Decisions-path resolution appear in the observed data.
Compatibility deletion ledger:

- `presentingAcpPermissionBatch` and `reconcilePresentedAcpPermissionBatch` in `Stores/HarnessMonitorStore+AcpAgents.swift` remain modal-only bridge seams.
- `AcpPermissionModal` and `WorkspaceWindowView+AcpPermissionPresentation.swift` remain compatibility readers over the Decisions-owned ACP state.
- No new ACP behavior may depend on those modal-only seams; new work must attach to deterministic ACP `Decision` ids and shared `BatchResolutionState` instead.

## Daemon API Stability Budget

UI chunks before UI-6 may lean harder on current daemon payloads, but they do not get to silently expand the daemon surface.
Budget one explicit post-UI-6 re-cut to simplify or rename daemon contracts once the Decisions-first UI path proves stable.
