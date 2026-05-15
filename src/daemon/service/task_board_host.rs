use crate::daemon::protocol::{
    TaskBoardHostListResponse, TaskBoardHostLocalResponse, TaskBoardHostSetProjectTypesRequest,
    TaskBoardHostSetProjectTypesResponse,
};
use crate::errors::CliError;
use crate::task_board::{MachineRegistry, default_board_root};

/// Return the local host registry record, creating one on first call.
///
/// # Errors
/// Returns `CliError` when the registry cannot be created or read.
pub fn task_board_host_local() -> Result<TaskBoardHostLocalResponse, CliError> {
    registry().ensure_local()
}

/// List every host registered in the task-board machine registry.
///
/// # Errors
/// Returns `CliError` when the registry directory cannot be enumerated.
pub fn task_board_host_list() -> Result<TaskBoardHostListResponse, CliError> {
    registry().list()
}

/// Replace the declared `project_types` on the local host record.
///
/// An empty `project_types` list clears all declarations, matching the CLI
/// `harness task-board host clear-project-types` behavior.
///
/// # Errors
/// Returns `CliError` when the registry cannot be read or written.
pub fn task_board_host_set_project_types(
    request: &TaskBoardHostSetProjectTypesRequest,
) -> Result<TaskBoardHostSetProjectTypesResponse, CliError> {
    let registry = registry();
    let mut machine = registry.ensure_local()?;
    machine.project_types.clone_from(&request.project_types);
    registry.upsert(&machine)
}

fn registry() -> MachineRegistry {
    MachineRegistry::new(default_board_root())
}
