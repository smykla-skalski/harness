use std::collections::HashSet;

use super::types::SessionRole;

/// Actions that can be permission-gated within a session.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SessionAction {
    EndSession,
    JoinAgent,
    RemoveAgent,
    AssignRole,
    TransferLeader,
    CreateTask,
    AssignTask,
    UpdateTaskStatus,
    ObserveSession,
    ViewStatus,
}

/// All defined session actions.
const ALL_ACTIONS: &[SessionAction] = &[
    SessionAction::EndSession,
    SessionAction::JoinAgent,
    SessionAction::RemoveAgent,
    SessionAction::AssignRole,
    SessionAction::TransferLeader,
    SessionAction::CreateTask,
    SessionAction::AssignTask,
    SessionAction::UpdateTaskStatus,
    SessionAction::ObserveSession,
    SessionAction::ViewStatus,
];

/// Return the set of actions permitted for a given role.
#[must_use]
pub fn permissions_for(role: SessionRole) -> HashSet<SessionAction> {
    use SessionAction::{
        AssignTask, CreateTask, ObserveSession, TransferLeader, UpdateTaskStatus, ViewStatus,
    };

    let actions: &[SessionAction] = match role {
        SessionRole::Leader => ALL_ACTIONS,
        SessionRole::Observer => &[ObserveSession, ViewStatus, CreateTask, TransferLeader],
        SessionRole::Worker => &[CreateTask, UpdateTaskStatus, ObserveSession, ViewStatus],
        SessionRole::Reviewer => &[
            CreateTask,
            AssignTask,
            UpdateTaskStatus,
            ObserveSession,
            ViewStatus,
        ],
        SessionRole::Improver => &[
            CreateTask,
            UpdateTaskStatus,
            AssignTask,
            ObserveSession,
            ViewStatus,
        ],
    };
    actions.iter().copied().collect()
}

/// Check whether a role is permitted to perform an action.
#[must_use]
pub fn is_permitted(role: SessionRole, action: SessionAction) -> bool {
    permissions_for(role).contains(&action)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn leader_has_all_permissions() {
        let perms = permissions_for(SessionRole::Leader);
        for action in ALL_ACTIONS {
            assert!(perms.contains(action), "leader should have {action:?}",);
        }
    }

    #[test]
    fn worker_cannot_end_session() {
        assert!(!is_permitted(
            SessionRole::Worker,
            SessionAction::EndSession
        ));
    }

    #[test]
    fn worker_can_create_tasks() {
        assert!(is_permitted(SessionRole::Worker, SessionAction::CreateTask));
    }

    #[test]
    fn observer_can_transfer_leader() {
        assert!(is_permitted(
            SessionRole::Observer,
            SessionAction::TransferLeader
        ));
    }

    #[test]
    fn observer_cannot_assign_tasks() {
        assert!(!is_permitted(
            SessionRole::Observer,
            SessionAction::AssignTask
        ));
    }

    #[test]
    fn reviewer_can_assign_tasks() {
        assert!(is_permitted(
            SessionRole::Reviewer,
            SessionAction::AssignTask
        ));
    }

    #[test]
    fn improver_can_assign_tasks() {
        assert!(is_permitted(
            SessionRole::Improver,
            SessionAction::AssignTask
        ));
    }

    #[test]
    fn every_role_can_view_status() {
        use clap::ValueEnum;
        for role in SessionRole::value_variants() {
            assert!(
                is_permitted(*role, SessionAction::ViewStatus),
                "{role:?} should be able to view status",
            );
        }
    }

    #[test]
    fn every_role_can_observe() {
        use clap::ValueEnum;
        for role in SessionRole::value_variants() {
            assert!(
                is_permitted(*role, SessionAction::ObserveSession),
                "{role:?} should be able to observe",
            );
        }
    }
}
