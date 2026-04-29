# Decision Contract

This document is a narrative index.
Canonical operating semantics live on the Swift types and store helpers named below.
This file exists to keep the human-facing map aligned with those concrete owners when the UI shifts.

## Operating Goal

The Decisions system enforces a single operator queue for policy decisions.
Goal is single-queue policy enforcement, not interruption fidelity.
Presentation can change from modal to Decisions window, but queue ownership, auditability, and idempotent resolution must remain stable.

## Canonical Type Map

- `AcpPermissionDecision` in `Models/AcpAgentModels.swift`: approve, deny, and partial-approve semantics for ACP permission batches.
- `AcpPermissionBatch` in `Models/AcpAgentModels.swift`: one queue element carries `1...N` permission items and uses `batchId` as the idempotency key.
- `SupervisorEvent` in `Supervisor/Audit/SupervisorEvent.swift`: current persisted audit-entry carrier, including the payload slot for approve-some request arrays and future `uiAnnotation` race notes.
- `Decision` in `Supervisor/Decision/Decision.swift`: queue-level goal, sticky-selection policy, and toggle-lifetime policy.
- `HarnessMonitorStore.pendingAcpPermissionBatches` and `reconcilePresentedAcpPermissionBatch` in `Stores/HarnessMonitorStore+AcpAgents.swift`: selected-session queue projection and sticky presentation behavior.
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

## Daemon API Stability Budget

UI chunks before UI-6 may lean harder on current daemon payloads, but they do not get to silently expand the daemon surface.
Budget one explicit post-UI-6 re-cut to simplify or rename daemon contracts once the Decisions-first UI path proves stable.
