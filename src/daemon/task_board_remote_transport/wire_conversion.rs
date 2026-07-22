use crate::daemon::task_board_remote_transport::wire::{
    RemoteHostAdvertisement, RemoteWireError, TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
};
use crate::task_board::{
    TASK_BOARD_REMOTE_PROTOCOL_VERSION, TaskBoardExecutionHostAdvertisement,
    TaskBoardLocalExecutionHostConfig, TaskBoardPhaseCapabilityProfile,
};

pub(super) fn host_wire_advertisement(
    host: &TaskBoardLocalExecutionHostConfig,
    host_instance_id: &str,
    active_assignments: u32,
    sent_at: String,
) -> Result<RemoteHostAdvertisement, RemoteWireError> {
    let advertisement = RemoteHostAdvertisement {
        schema_version: TASK_BOARD_REMOTE_WIRE_SCHEMA_VERSION,
        host_id: host.host_id.clone(),
        host_instance_id: host_instance_id.to_owned(),
        protocol_version: TASK_BOARD_REMOTE_PROTOCOL_VERSION,
        capabilities: host
            .capabilities
            .iter()
            .copied()
            .map(capability_label)
            .map(str::to_owned)
            .collect(),
        runtimes: host.runtimes.iter().cloned().collect(),
        repositories: host
            .repositories
            .iter()
            .map(|repository| repository.repository.clone())
            .collect(),
        capacity: host.capacity,
        active_assignments,
        sent_at,
    };
    advertisement.validate()?;
    Ok(advertisement)
}

pub(super) fn domain_host_advertisement(
    wire: RemoteHostAdvertisement,
) -> Result<TaskBoardExecutionHostAdvertisement, RemoteWireError> {
    wire.validate()?;
    let mut capabilities = wire
        .capabilities
        .iter()
        .map(|value| decode_capability(value))
        .collect::<Result<Vec<_>, _>>()?;
    capabilities.sort_by_key(|capability| capability_rank(*capability));
    Ok(TaskBoardExecutionHostAdvertisement {
        host_id: wire.host_id,
        host_instance_id: wire.host_instance_id,
        protocol_version: wire.protocol_version,
        repositories: wire.repositories.into_iter().collect(),
        runtimes: wire.runtimes.into_iter().collect(),
        capabilities,
        capacity: wire.capacity,
        active_assignments: wire.active_assignments,
        heartbeat_at: wire.sent_at,
    })
}

const fn capability_label(capability: TaskBoardPhaseCapabilityProfile) -> &'static str {
    match capability {
        TaskBoardPhaseCapabilityProfile::PlanningReadOnly => "planning_read_only",
        TaskBoardPhaseCapabilityProfile::ImplementationWrite => "implementation_write",
        TaskBoardPhaseCapabilityProfile::ReviewReadOnly => "review_read_only",
        TaskBoardPhaseCapabilityProfile::EvaluateReadOnly => "evaluate_read_only",
    }
}

fn decode_capability(value: &str) -> Result<TaskBoardPhaseCapabilityProfile, RemoteWireError> {
    match value {
        "implementation_write" => Ok(TaskBoardPhaseCapabilityProfile::ImplementationWrite),
        "review_read_only" => Ok(TaskBoardPhaseCapabilityProfile::ReviewReadOnly),
        "evaluate_read_only" => Ok(TaskBoardPhaseCapabilityProfile::EvaluateReadOnly),
        _ => Err(RemoteWireError::InvalidPhase),
    }
}

const fn capability_rank(capability: TaskBoardPhaseCapabilityProfile) -> u8 {
    match capability {
        TaskBoardPhaseCapabilityProfile::ImplementationWrite => 0,
        TaskBoardPhaseCapabilityProfile::ReviewReadOnly => 1,
        TaskBoardPhaseCapabilityProfile::EvaluateReadOnly => 2,
        TaskBoardPhaseCapabilityProfile::PlanningReadOnly => 3,
    }
}
