use super::{
    AgentMode, DispatchBlockReason, DispatchReadiness, PlanApprovalGate, PolicyDecision,
    TaskBoardItem, TaskBoardStatus, TaskBoardWorkflowKind, approval_gate,
};
use crate::task_board::PolicyReasonCode;

pub(super) fn readiness(item: &TaskBoardItem, policy: &PolicyDecision) -> DispatchReadiness {
    if item.is_deleted() {
        return blocked(DispatchBlockReason::Deleted);
    }
    if !item.kind.is_dispatchable() {
        return blocked(DispatchBlockReason::Kind {
            item_kind: item.kind,
        });
    }
    if let Some(work_item_id) = item.work_item_id.as_deref() {
        return blocked(DispatchBlockReason::AlreadyLinked {
            work_item_id: work_item_id.to_string(),
        });
    }
    if let PlanApprovalGate::Blocked { reason } = approval_gate(item) {
        return blocked(DispatchBlockReason::PlanApproval { reason });
    }
    if item.status != TaskBoardStatus::Todo {
        return blocked(DispatchBlockReason::Status {
            status: item.status,
        });
    }
    if is_write_workflow(item.workflow_kind) && item.agent_mode != AgentMode::Headless {
        return blocked(DispatchBlockReason::Policy {
            decision: mode_block(policy),
        });
    }
    if !policy.is_allow() {
        return blocked(DispatchBlockReason::Policy {
            decision: policy.clone(),
        });
    }
    DispatchReadiness::Ready
}

pub(super) fn blocked(reason: DispatchBlockReason) -> DispatchReadiness {
    DispatchReadiness::Blocked { reason }
}

const fn is_write_workflow(kind: TaskBoardWorkflowKind) -> bool {
    matches!(
        kind,
        TaskBoardWorkflowKind::DefaultTask | TaskBoardWorkflowKind::PrFix
    )
}

fn mode_block(policy: &PolicyDecision) -> PolicyDecision {
    let policy_version = match policy {
        PolicyDecision::Allow { policy_version, .. }
        | PolicyDecision::Deny { policy_version, .. }
        | PolicyDecision::RequireHuman { policy_version, .. }
        | PolicyDecision::RequireConsensus { policy_version, .. }
        | PolicyDecision::DryRunOnly { policy_version, .. } => policy_version.clone(),
    };
    PolicyDecision::RequireHuman {
        reason_code: PolicyReasonCode::HumanRequired,
        policy_version,
    }
}
