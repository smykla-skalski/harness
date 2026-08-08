use std::collections::HashMap;

use crate::daemon::db_handle::AsyncDaemonDbHandle;
use crate::daemon::reviews_store::PolicyGraphQueries;
use crate::task_board::policy_graph::PolicyGraph;
use crate::task_board::{Machine, PolicyAction, PolicyApprovalGrant, TaskBoardItem};
use harness_kernel::errors::CliError;

/// Load the live (unconsumed) spawn approval grant for every item under
/// evaluation, keyed by board item id. Only meaningful when a live enforced
/// graph exists (a grant is keyed to that graph's revision); returns an empty
/// map otherwise so no injection happens on the built-in fallback path.
pub(crate) async fn load_live_spawn_grants(
    db: &AsyncDaemonDbHandle,
    policy: Option<(&str, &PolicyGraph)>,
    kept: &[TaskBoardItem],
    rejected: &[(TaskBoardItem, Machine)],
) -> Result<HashMap<String, PolicyApprovalGrant>, CliError> {
    let mut grants = HashMap::new();
    let Some((_canvas_id, document)) = policy else {
        return Ok(grants);
    };
    let revision = document.revision;
    let items = kept.iter().chain(rejected.iter().map(|(item, _)| item));
    for item in items {
        if let Some(grant) = db
            .live_approval_grant(&item.id, PolicyAction::SpawnAgent, revision)
            .await?
        {
            grants.insert(item.id.clone(), grant);
        }
    }
    Ok(grants)
}

pub(super) fn filter_for_machine(
    items: Vec<TaskBoardItem>,
    machine: Option<&Machine>,
) -> (Vec<TaskBoardItem>, Vec<(TaskBoardItem, Machine)>) {
    let Some(machine) = machine else {
        return (items, Vec::new());
    };
    let mut kept = Vec::with_capacity(items.len());
    let mut rejected = Vec::new();
    for item in items {
        if machine.accepts_any(&item.target_project_types) {
            kept.push(item);
        } else {
            rejected.push((item, machine.clone()));
        }
    }
    (kept, rejected)
}
