use super::*;
use crate::task_board::AgentMode;

#[test]
fn planning_and_evaluate_map_to_report_read_only() {
    for mode in [AgentMode::Planning, AgentMode::Evaluate] {
        assert_eq!(
            launch_capability_for_agent_mode(mode),
            Ok(TaskBoardLaunchCapability::ReportReadOnly)
        );
        assert!(
            launch_capability_for_agent_mode(mode)
                .expect("read-only capability")
                .is_read_only()
        );
    }
}

#[test]
fn headless_maps_to_workspace_write() {
    assert_eq!(
        launch_capability_for_agent_mode(AgentMode::Headless),
        Ok(TaskBoardLaunchCapability::WorkspaceWrite)
    );
    assert!(
        !launch_capability_for_agent_mode(AgentMode::Headless)
            .expect("write capability")
            .is_read_only()
    );
}

#[test]
fn interactive_fails_closed() {
    assert_eq!(
        launch_capability_for_agent_mode(AgentMode::Interactive),
        Err(TaskBoardLaunchCapabilityError::InteractiveNotEnforceable)
    );
}

#[test]
fn mismatched_constructed_capability_is_rejected() {
    assert_eq!(
        validate_launch_capability(
            AgentMode::Planning,
            TaskBoardLaunchCapability::WorkspaceWrite,
        ),
        Err(TaskBoardLaunchCapabilityError::CapabilityMismatch {
            mode: AgentMode::Planning,
            expected: TaskBoardLaunchCapability::ReportReadOnly,
            actual: TaskBoardLaunchCapability::WorkspaceWrite,
        })
    );
}
